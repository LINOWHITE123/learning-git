from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from goldsmc_service.features import FEATURE_COLUMNS, build_features, build_labels, load_price_csv
from goldsmc_service.model import DirectionalModel, save, train


def synthetic_prices(rows: int = 3000, seed: int = 7) -> pd.DataFrame:
    """Trending random walk with enough structure for the model to learn something."""
    rng = np.random.default_rng(seed)
    index = pd.date_range("2022-01-01", periods=rows, freq="h", tz="UTC")
    drift = np.sin(np.arange(rows) / 180.0) * 0.4
    steps = rng.normal(0.0, 1.2, rows) + drift
    close = 1800.0 + np.cumsum(steps)
    high = close + np.abs(rng.normal(0.0, 0.8, rows))
    low = close - np.abs(rng.normal(0.0, 0.8, rows))
    open_ = np.concatenate([[close[0]], close[:-1]])
    return pd.DataFrame({"open": open_, "high": high, "low": low, "close": close}, index=index)


def test_features_are_complete_and_finite():
    features = build_features(synthetic_prices(600)).dropna()
    assert list(features.columns) == FEATURE_COLUMNS
    assert len(features) > 400
    assert np.isfinite(features.to_numpy()).all()


def test_features_reject_incomplete_frames():
    with pytest.raises(ValueError):
        build_features(pd.DataFrame({"close": [1.0, 2.0]}))


def test_labels_are_binary_and_forward_looking():
    prices = synthetic_prices(1000)
    labels = build_labels(prices, horizon=4, threshold_atr=0.5).dropna()
    assert set(labels.unique()).issubset({0.0, 1.0})
    assert 0.1 < labels.mean() < 0.9


def test_train_and_score_roundtrip(tmp_path):
    prices = synthetic_prices(3000)
    pipeline, report = train(prices, horizon=4, threshold_atr=0.5)
    assert report.samples > 1000
    assert 0.0 <= report.accuracy <= 1.0

    path = tmp_path / "model.joblib"
    save(pipeline, report, path)

    model = DirectionalModel(path)
    assert model.available
    score, confidence = model.score(prices)
    assert -1.0 <= score <= 1.0
    assert 0.0 <= confidence <= 1.0


def test_missing_model_scores_neutral(tmp_path):
    model = DirectionalModel(tmp_path / "absent.joblib")
    assert not model.available
    assert model.score(synthetic_prices(300)) == (0.0, 0.0)


def test_load_price_csv_handles_mt5_headers(tmp_path):
    path = tmp_path / "XAUUSD_H1.csv"
    path.write_text(
        "<DATE>,<TIME>,<OPEN>,<HIGH>,<LOW>,<CLOSE>,<TICKVOL>\n"
        "2024.01.02,10:00:00,2060.1,2065.4,2058.0,2063.2,1500\n"
        "2024.01.02,11:00:00,2063.2,2068.0,2061.5,2067.1,1610\n",
        encoding="ascii",
    )
    frame = load_price_csv(path)
    assert list(frame.columns) == ["open", "high", "low", "close", "volume"]
    assert len(frame) == 2
    assert frame.index.tz is not None
