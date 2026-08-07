"""Neural directional model.

A small multi layer perceptron over the engineered features. It is trained with
a walk forward split (never shuffled) so the reported accuracy is out of sample,
and it outputs a directional score in -1..+1 together with a confidence.
"""

from __future__ import annotations

import logging
from dataclasses import asdict, dataclass
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.metrics import accuracy_score, roc_auc_score
from sklearn.neural_network import MLPClassifier
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

from .features import FEATURE_COLUMNS, build_features, build_labels

log = logging.getLogger(__name__)


@dataclass
class TrainingReport:
    samples: int
    train_samples: int
    test_samples: int
    accuracy: float
    auc: float
    positive_rate: float
    horizon: int
    threshold_atr: float

    def as_dict(self) -> dict:
        return asdict(self)


def _build_pipeline(seed: int = 42) -> Pipeline:
    return Pipeline(
        steps=[
            ("scaler", StandardScaler()),
            (
                "mlp",
                MLPClassifier(
                    hidden_layer_sizes=(64, 32),
                    activation="relu",
                    alpha=1e-3,
                    learning_rate_init=1e-3,
                    max_iter=600,
                    early_stopping=True,
                    n_iter_no_change=20,
                    validation_fraction=0.15,
                    random_state=seed,
                ),
            ),
        ]
    )


def train(
    prices: pd.DataFrame,
    horizon: int = 4,
    threshold_atr: float = 0.5,
    test_fraction: float = 0.2,
    seed: int = 42,
) -> tuple[Pipeline, TrainingReport]:
    features = build_features(prices)
    labels = build_labels(prices, horizon=horizon, threshold_atr=threshold_atr)

    dataset = features.join(labels.rename("target")).dropna()
    if len(dataset) < 500:
        raise ValueError(f"not enough usable rows to train: {len(dataset)}")

    split = int(len(dataset) * (1.0 - test_fraction))
    train_set, test_set = dataset.iloc[:split], dataset.iloc[split:]

    pipeline = _build_pipeline(seed)
    pipeline.fit(train_set[FEATURE_COLUMNS], train_set["target"])

    probabilities = pipeline.predict_proba(test_set[FEATURE_COLUMNS])[:, 1]
    predictions = (probabilities >= 0.5).astype(float)

    try:
        auc = float(roc_auc_score(test_set["target"], probabilities))
    except ValueError:
        auc = float("nan")

    report = TrainingReport(
        samples=len(dataset),
        train_samples=len(train_set),
        test_samples=len(test_set),
        accuracy=float(accuracy_score(test_set["target"], predictions)),
        auc=auc,
        positive_rate=float(dataset["target"].mean()),
        horizon=horizon,
        threshold_atr=threshold_atr,
    )
    return pipeline, report


def save(pipeline: Pipeline, report: TrainingReport, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump({"pipeline": pipeline, "report": report.as_dict(), "features": FEATURE_COLUMNS}, path)
    log.info("model saved to %s", path)


class DirectionalModel:
    """Loads a trained pipeline and scores the most recent bar."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._pipeline: Pipeline | None = None
        self._report: dict = {}
        self.load()

    @property
    def available(self) -> bool:
        return self._pipeline is not None

    @property
    def report(self) -> dict:
        return dict(self._report)

    def load(self) -> bool:
        if not self._path.exists():
            log.warning("no model at %s, the model score will stay neutral", self._path)
            return False
        try:
            blob = joblib.load(self._path)
            self._pipeline = blob["pipeline"]
            self._report = blob.get("report", {})
            return True
        except Exception as exc:  # noqa: BLE001 - a broken artefact must not kill the service
            log.error("could not load the model: %s", exc)
            self._pipeline = None
            return False

    def score(self, prices: pd.DataFrame) -> tuple[float, float]:
        """Return ``(directional_score, confidence)`` for the latest closed bar."""

        if self._pipeline is None:
            return 0.0, 0.0

        features = build_features(prices).dropna()
        if features.empty:
            return 0.0, 0.0

        latest = features.iloc[[-1]][FEATURE_COLUMNS]
        probability = float(self._pipeline.predict_proba(latest)[0, 1])
        score = float(np.clip(2.0 * probability - 1.0, -1.0, 1.0))
        confidence = float(min(1.0, abs(score) * 1.5))
        return score, confidence
