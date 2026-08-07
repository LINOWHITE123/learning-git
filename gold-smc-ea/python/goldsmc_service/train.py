"""Train the directional model from an MT5 price export.

    python -m goldsmc_service.train --csv data/XAUUSD_H1.csv --out models/goldsmc_mlp.joblib

Export the CSV from MetaTrader with the ``ExportBars`` script in ``tools/`` or
with the terminal's own history export.
"""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

from .features import load_price_csv
from .model import save, train

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train the GoldSMC directional model")
    parser.add_argument("--csv", required=True, type=Path, help="OHLC history exported from MT5")
    parser.add_argument("--out", default=Path("models/goldsmc_mlp.joblib"), type=Path)
    parser.add_argument("--horizon", default=4, type=int, help="Forward bars used to build the label")
    parser.add_argument("--threshold-atr", default=0.5, type=float, help="Move size that counts as a signal")
    parser.add_argument("--test-fraction", default=0.2, type=float)
    parser.add_argument("--seed", default=42, type=int)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    prices = load_price_csv(args.csv)
    logging.info("loaded %d bars from %s", len(prices), args.csv)

    pipeline, report = train(
        prices,
        horizon=args.horizon,
        threshold_atr=args.threshold_atr,
        test_fraction=args.test_fraction,
        seed=args.seed,
    )
    save(pipeline, report, args.out)
    print(json.dumps(report.as_dict(), indent=2))

    if report.accuracy < 0.55:
        print(
            "\nOut of sample accuracy is close to a coin flip. Use this model as a "
            "soft filter only (FILTER_SOFT in the EA), not as an entry trigger."
        )


if __name__ == "__main__":
    main()
