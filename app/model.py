"""Online ridge-regression model that predicts consultation duration (minutes).

Why this design
---------------
The original model was Ridge regression on TF-IDF + age + queue serial. TF-IDF
needs a fixed vocabulary, so it cannot absorb new data without a full refit.
Here the text is encoded with a *stateless* hashing vectorizer instead, and the
ridge solution is kept as running sufficient statistics:

    A = lambda*I + sum_i w_i x_i x_i^T        b = sum_i w_i y_i x_i
    weights = A^-1 b

Adding one completed appointment is  A += w x x^T ; b += w y x  followed by one
linear solve. The result is *exactly* the ridge fit on all data seen so far:
no learning rate, no drift, and the order of arrival does not matter.
"""
from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Iterable, Optional

import numpy as np
import pandas as pd
from sklearn.feature_extraction.text import HashingVectorizer

N_HASH = 512  # hashed text features; ~120 distinct n-grams in the seed => few collisions


@dataclass
class Sample:
    symptom: str
    minutes: float
    age: Optional[int] = None
    queue_serial: Optional[int] = None
    weight: float = 1.0


class OnlineDurationModel:
    def __init__(
        self,
        l2: float = 1.0,
        real_weight: float = 3.0,
        min_minutes: float = 5.0,
        max_minutes: float = 60.0,
    ):
        self.l2 = l2
        self.real_weight = real_weight
        self.min_minutes = min_minutes
        self.max_minutes = max_minutes

        self._vec = HashingVectorizer(
            n_features=N_HASH,
            ngram_range=(1, 2),
            stop_words="english",
            alternate_sign=False,
            norm="l2",
            lowercase=True,
        )
        # Feature layout: [hashed text | age_z | queue_z | bias]
        self.dim = N_HASH + 3
        self._A = np.zeros((self.dim, self.dim))
        self._b = np.zeros(self.dim)
        self._w = np.zeros(self.dim)

        # Scaling constants are frozen after seeding so features stay consistent
        # across every later update.
        self.age_mean, self.age_std = 40.0, 20.0
        self.queue_mean, self.queue_std = 8.0, 4.3

        self._lock = threading.RLock()
        self.version = 0
        self.seed_count = 0
        self.real_count = 0
        self.last_trained_at: Optional[float] = None
        # Test-then-train error on real appointments: the honest live accuracy.
        self._live_errors: deque[float] = deque(maxlen=200)

    # ---------------------------------------------------------------- features
    def _featurize(self, symptoms, ages, serials) -> np.ndarray:
        text = self._vec.transform(list(symptoms)).toarray()
        n = text.shape[0]
        age = np.array(
            [0.0 if a is None else (a - self.age_mean) / self.age_std for a in ages]
        ).reshape(n, 1)
        q = np.array(
            [0.0 if s is None else (s - self.queue_mean) / self.queue_std for s in serials]
        ).reshape(n, 1)
        return np.hstack([text, age, q, np.ones((n, 1))])

    # ---------------------------------------------------------------- training
    def _solve(self, A: np.ndarray, b: np.ndarray) -> np.ndarray:
        reg = np.full(self.dim, self.l2)
        reg[-1] = 1e-6  # do not shrink the intercept
        return np.linalg.solve(A + np.diag(reg), b)

    def _accumulate(self, samples: list[Sample]):
        X = self._featurize(
            (s.symptom for s in samples),
            (s.age for s in samples),
            (s.queue_serial for s in samples),
        )
        y = np.array([s.minutes for s in samples], dtype=float)
        w = np.array([s.weight for s in samples], dtype=float)
        return (X * w[:, None]).T @ X, (X * (w * y)[:, None]).sum(axis=0)

    def seed_from_csv(self, path: str) -> None:
        df = pd.read_csv(path)
        self.age_mean = float(df["patient_age"].mean())
        self.age_std = float(df["patient_age"].std())
        self.queue_mean = float(df["queue_serial"].mean())
        self.queue_std = float(df["queue_serial"].std())
        samples = [
            Sample(r.initial_symptom, r.actual_duration_minutes, int(r.patient_age),
                   int(r.queue_serial), 1.0)
            for r in df.itertuples()
        ]
        dA, db = self._accumulate(samples)
        with self._lock:
            self._A += dA
            self._b += db
            self._w = self._solve(self._A, self._b)
            self.seed_count += len(samples)
            self.version += 1

    def learn(self, samples: Iterable[Sample], real: bool = True) -> int:
        """Absorb completed appointments. One linear solve for the whole batch.

        Callers must serialise learn() calls (the API does, with a single lock).
        """
        samples = list(samples)
        if not samples:
            return 0
        if real:
            for s in samples:
                s.weight = self.real_weight
                # prequential error: predict BEFORE learning from the sample
                self._live_errors.append(
                    abs(self.predict(s.symptom, s.age, s.queue_serial) - s.minutes)
                )
        dA, db = self._accumulate(samples)
        with self._lock:
            A_new = self._A + dA
            b_new = self._b + db
        w_new = self._solve(A_new, b_new)  # the heavy part runs outside the lock
        with self._lock:
            self._A, self._b, self._w = A_new, b_new, w_new
            if real:
                self.real_count += len(samples)
            self.version += 1
            self.last_trained_at = time.time()
        return len(samples)

    # -------------------------------------------------------------- prediction
    def predict_many(self, items: list[tuple[str, Optional[int], Optional[int]]]) -> list[float]:
        if not items:
            return []
        X = self._featurize((i[0] for i in items), (i[1] for i in items), (i[2] for i in items))
        with self._lock:
            w = self._w
        out = np.clip(X @ w, self.min_minutes, self.max_minutes)
        return [round(float(v), 1) for v in out]

    def predict(self, symptom: str, age: Optional[int] = None, queue_serial: Optional[int] = None) -> float:
        if not symptom or not symptom.strip():
            return 15.0  # same default the app used for empty input
        return self.predict_many([(symptom, age, queue_serial)])[0]

    # ------------------------------------------------------------------ status
    def stats(self) -> dict:
        errs = list(self._live_errors)
        return {
            "model_version": self.version,
            "seed_samples": self.seed_count,
            "real_samples": self.real_count,
            "real_sample_weight": self.real_weight,
            "last_trained_at": self.last_trained_at,
            "live_mae_minutes": round(float(np.mean(errs)), 2) if errs else None,
            "live_mae_window": len(errs),
        }
