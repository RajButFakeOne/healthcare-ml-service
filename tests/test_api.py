import asyncio
import os

os.environ["WEBHOOK_SECRET"] = "s3cret"
os.environ.pop("SUPABASE_URL", None)

import pytest
from fastapi.testclient import TestClient

from app import main

FEVER = "High-grade fever with chills, generalized body ache and severe fatigue"
H = {"X-Webhook-Secret": "s3cret"}


def train_body(i, start="2026-11-19T09:00:00+00:00", end="2026-11-19T09:35:00+00:00", **kw):
    return {"appointment_id": f"appt-{i}", "symptom": FEVER, "consultation_start": start,
            "consultation_end": end, "age": 40, "queue_serial": 1, **kw}


@pytest.fixture()
def client():
    with TestClient(main.app) as c:  # runs lifespan -> seeds a fresh model
        yield c


def test_health_and_predict(client):
    h = client.get("/health").json()
    assert h["status"] == "ok" and h["seed_samples"] == 850 and h["real_samples"] == 0
    r = client.post("/predict", json={"symptom": FEVER, "age": 40, "queue_serial": 1}).json()
    assert 14 <= r["minutes"] <= 24
    assert client.post("/predict", json={"symptom": "   "}).json()["minutes"] == 15.0


def test_batch(client):
    r = client.post("/predict/batch", json={"items": [{"symptom": FEVER}, {"symptom": "routine checkup"}]}).json()
    assert len(r["minutes"]) == 2


def test_train_requires_secret(client):
    assert client.post("/train", json=train_body(1)).status_code == 401
    assert client.post("/train", json=train_body(1), headers={"X-Webhook-Secret": "nope"}).status_code == 401


def test_training_changes_predictions_immediately(client):
    before = client.post("/predict", json={"symptom": FEVER, "age": 40, "queue_serial": 1}).json()
    for i in range(30):  # 35-minute real consultations
        r = client.post("/train", json=train_body(i), headers=H).json()
        assert r["learned"] is True and r["actual_minutes"] == 35.0
    after = client.post("/predict", json={"symptom": FEVER, "age": 40, "queue_serial": 1}).json()
    assert after["minutes"] > before["minutes"] + 8
    assert after["model_version"] > before["model_version"]
    assert client.get("/metrics").json()["real_samples"] == 30


def test_idempotent(client):
    assert client.post("/train", json=train_body(1), headers=H).json()["learned"] is True
    again = client.post("/train", json=train_body(1), headers=H).json()
    assert again["learned"] is False and again["reason"] == "already_learned"
    assert client.get("/metrics").json()["real_samples"] == 1


@pytest.mark.parametrize("start,end", [
    ("2026-11-19T09:00:00+00:00", "2026-11-19T18:00:00+00:00"),  # forgot to press End: 9h
    ("2026-11-19T09:00:00+00:00", "2026-11-19T09:00:20+00:00"),  # 20s accidental tap
    ("2026-11-19T09:30:00+00:00", "2026-11-19T09:00:00+00:00"),  # end before start
])
def test_rejects_implausible_durations(client, start, end):
    r = client.post("/train", json=train_body(9, start=start, end=end), headers=H).json()
    assert r["learned"] is False and r["reason"] == "implausible_duration"
    assert client.get("/metrics").json()["real_samples"] == 0


def test_reconcile_picks_up_missed_rows_and_dedupes(client, monkeypatch):
    rows = [
        {"id": 101, "initial_symptom": FEVER, "queue_serial": 2,
         "consultation_start": "2026-11-19T10:00:00+00:00", "consultation_end": "2026-11-19T10:30:00+00:00",
         "patients": {"date_of_birth": "1980-05-01"}},
        {"id": 102, "initial_symptom": FEVER, "queue_serial": 3,
         "consultation_start": "2026-11-19T10:30:00+00:00", "consultation_end": "2026-11-19T10:50:00+00:00",
         "patients": None},
    ]

    class Fake:
        async def fetch_completed(self, since=None):
            return rows

    main.S.source = Fake()
    assert client.post("/admin/reconcile", headers=H).json()["learned"] == 2
    assert client.post("/admin/reconcile", headers=H).json()["learned"] == 0  # no double count
    # the webhook for an already-reconciled appointment is a no-op too
    assert client.post("/train", json=train_body(101).copy() | {"appointment_id": "101"}, headers=H).json()["learned"] is False
    main.S.source = None
