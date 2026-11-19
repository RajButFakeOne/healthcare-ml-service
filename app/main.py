"""Healthcare consultation-duration service.

POST /predict         real-time duration estimate (sub-millisecond)
POST /predict/batch   many estimates in one call (queue recalculation)
POST /train           called when an appointment ends -> model learns immediately
GET  /health          liveness + model stats
GET  /metrics         live accuracy on real appointments (test-then-train MAE)
"""
from __future__ import annotations

import asyncio
import hmac
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .model import OnlineDurationModel, Sample
from .sources import SupabaseSource, age_on, duration_minutes, parse_ts

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("ml")

SEED_CSV = Path(__file__).resolve().parent.parent / "data" / "appointment_training_data.csv"
WEBHOOK_SECRET = os.getenv("WEBHOOK_SECRET", "")
SUPABASE_URL = os.getenv("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY", "")
RECONCILE_MINUTES = float(os.getenv("RECONCILE_MINUTES", "10"))
REAL_SAMPLE_WEIGHT = float(os.getenv("REAL_SAMPLE_WEIGHT", "3.0"))


class State:
    model: OnlineDurationModel
    seen: set[str]  # appointment ids already learned from (idempotency)
    train_lock: asyncio.Lock
    last_sync_end: Optional[str] = None  # newest consultation_end we've absorbed
    source: Optional[SupabaseSource] = None


S = State()


def _to_sample(row: dict) -> Optional[tuple[str, Sample, str]]:
    """Supabase appointment row -> (id, Sample, consultation_end) or None if unusable."""
    mins = duration_minutes(row.get("consultation_start"), row.get("consultation_end"))
    symptom = (row.get("initial_symptom") or "").strip()
    if mins is None or not symptom:
        return None
    patient = row.get("patients") or {}
    if isinstance(patient, list):
        patient = patient[0] if patient else {}
    age = age_on(patient.get("date_of_birth"), row["consultation_start"])
    serial = row.get("queue_serial")
    return (
        str(row["id"]),
        Sample(symptom, mins, age, int(serial) if serial is not None else None),
        row["consultation_end"],
    )


async def _absorb_rows(rows: list[dict]) -> int:
    fresh: list[Sample] = []
    newest = S.last_sync_end
    for row in rows:
        parsed = _to_sample(row)
        if not parsed:
            continue
        appt_id, sample, ended = parsed
        if newest is None or parse_ts(ended) > parse_ts(newest):
            newest = ended
        if appt_id in S.seen:
            continue
        S.seen.add(appt_id)
        fresh.append(sample)
    async with S.train_lock:
        n = await asyncio.to_thread(S.model.learn, fresh, True)
    S.last_sync_end = newest
    return n


async def _reconcile(full: bool = False) -> int:
    """Pull completed appointments from Supabase and learn the ones we haven't seen."""
    if not S.source:
        return 0
    since = None
    if not full and S.last_sync_end:
        since = (parse_ts(S.last_sync_end) - timedelta(hours=1)).isoformat()  # overlap; `seen` dedupes
    rows = await S.source.fetch_completed(since)
    return await _absorb_rows(rows)


async def _reconcile_loop():
    while True:
        await asyncio.sleep(RECONCILE_MINUTES * 60)
        try:
            n = await _reconcile()
            if n:
                log.info("reconcile: learned %d missed appointments", n)
        except Exception:  # never let the loop die
            log.exception("reconcile failed")


@asynccontextmanager
async def lifespan(_: FastAPI):
    S.model = OnlineDurationModel(real_weight=REAL_SAMPLE_WEIGHT)
    S.model.seed_from_csv(str(SEED_CSV))
    S.seen, S.train_lock = set(), asyncio.Lock()
    log.info("model seeded with %d rows", S.model.seed_count)

    tasks = []
    if SUPABASE_URL and SUPABASE_SERVICE_KEY:
        S.source = SupabaseSource(SUPABASE_URL, SUPABASE_SERVICE_KEY)

        async def _initial():
            try:
                n = await _reconcile(full=True)
                log.info("startup backfill: learned %d real appointments", n)
            except Exception:
                log.exception("startup backfill failed (will retry on the next reconcile)")

        tasks.append(asyncio.create_task(_initial()))
        tasks.append(asyncio.create_task(_reconcile_loop()))
    else:
        log.warning("SUPABASE_URL/SUPABASE_SERVICE_KEY not set: no backfill; learning only from /train")
    yield
    for t in tasks:
        t.cancel()


app = FastAPI(title="Healthcare consultation-duration model", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["GET", "POST"], allow_headers=["*"])


# ------------------------------------------------------------------ schemas
class PredictIn(BaseModel):
    symptom: str = Field(..., max_length=1000)
    age: Optional[int] = Field(None, ge=0, le=120)
    queue_serial: Optional[int] = Field(None, ge=1, le=500)


class PredictOut(BaseModel):
    minutes: float
    model_version: int


class BatchIn(BaseModel):
    items: list[PredictIn] = Field(..., max_length=200)


class TrainIn(BaseModel):
    appointment_id: str
    symptom: str = Field(..., max_length=1000)
    consultation_start: str
    consultation_end: str
    age: Optional[int] = Field(None, ge=0, le=120)
    queue_serial: Optional[int] = Field(None, ge=1, le=500)


def require_secret(x_webhook_secret: str = Header(default="")):
    if not WEBHOOK_SECRET:
        raise HTTPException(503, "WEBHOOK_SECRET is not configured on the server")
    if not hmac.compare_digest(x_webhook_secret, WEBHOOK_SECRET):
        raise HTTPException(401, "bad secret")


# ------------------------------------------------------------------- routes
@app.get("/health")
def health():
    return {"status": "ok", "supabase_sync": S.source is not None, **S.model.stats()}


@app.get("/metrics")
def metrics():
    return S.model.stats()


@app.post("/predict", response_model=PredictOut)
def predict(body: PredictIn):
    return PredictOut(
        minutes=S.model.predict(body.symptom, body.age, body.queue_serial),
        model_version=S.model.version,
    )


@app.post("/predict/batch")
def predict_batch(body: BatchIn):
    mins = S.model.predict_many([(i.symptom, i.age, i.queue_serial) for i in body.items])
    return {"minutes": mins, "model_version": S.model.version}


@app.post("/train", dependencies=[Depends(require_secret)])
async def train(body: TrainIn):
    """Called by the Supabase trigger the moment an appointment is marked Completed."""
    if body.appointment_id in S.seen:
        return {"learned": False, "reason": "already_learned", **S.model.stats()}
    mins = duration_minutes(body.consultation_start, body.consultation_end)
    if mins is None:
        # Not added to `seen`, so a corrected row can still be learned by reconcile.
        return {"learned": False, "reason": "implausible_duration", **S.model.stats()}
    if not body.symptom.strip():
        return {"learned": False, "reason": "empty_symptom", **S.model.stats()}

    S.seen.add(body.appointment_id)
    sample = Sample(body.symptom.strip(), mins, body.age, body.queue_serial)
    async with S.train_lock:
        await asyncio.to_thread(S.model.learn, [sample], True)
    if S.last_sync_end is None or parse_ts(body.consultation_end) > parse_ts(S.last_sync_end):
        S.last_sync_end = body.consultation_end
    log.info("learned appointment %s: %.1f min", body.appointment_id, mins)
    return {"learned": True, "actual_minutes": mins, **S.model.stats()}


@app.post("/admin/reconcile", dependencies=[Depends(require_secret)])
async def admin_reconcile(full: bool = False):
    """Manually pull any completed appointments we haven't learned yet."""
    if not S.source:
        raise HTTPException(503, "Supabase credentials not configured")
    n = await _reconcile(full=full)
    return {"learned": n, **S.model.stats()}
