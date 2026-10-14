"""
BROKA - Model Training (Volume 2 §4.2, §4.3, §4.4)
─────────────────────────────────────────────────────────────────────────────
Real, runnable training code - but §4.4 is explicit that BROKA almost
certainly doesn't have enough data yet ("a few hundred, at minimum") and
that this should be stood up and start logging early, not switched on
early. train_all() enforces that itself: it checks
MIN_DEALS_PER_CATEGORY_FOR_ML per category and skips (logging why) any
category below it, rather than training a model on a handful of examples
that would generalise badly. Safe to call from day one - on an empty or
near-empty database, per §4.4's actual current state, this predictably
trains nothing and says so.

lightgbm/joblib are imported lazily inside train_price_model(), not at
module level: neither is in backend/requirements.txt yet (added as a
comment there instead - see that file), so importing them eagerly here
would break every other import of this package, including predict.py's
heuristic path, which is the one actually in use today and has zero
dependency on either library.
"""
from __future__ import annotations

import logging
from pathlib import Path

from sqlalchemy.ext.asyncio import AsyncSession

from api.core.ml.feature_extraction import (
    MIN_DEALS_PER_CATEGORY_FOR_ML,
    count_completed_deals_by_category,
    extract_pricing_examples,
)

logger = logging.getLogger(__name__)

MODELS_DIR = Path(__file__).parent / "models"


def train_price_model(category: str, examples: list) -> None:
    """
    Trains one LightGBM regressor for `category` and writes
    models/price_{category}.joblib. Caller (train_all) is responsible for
    the MIN_DEALS_PER_CATEGORY_FOR_ML check - this function trusts its
    input and trains on whatever examples it's given.

    Feature order [listing_price, condition_code] must match
    predict.py's _predict_price_from_model exactly.
    """
    try:
        import lightgbm as lgb
        import joblib
    except ImportError as exc:
        raise RuntimeError(
            "lightgbm/joblib not installed - add them to backend/requirements.txt "
            "(see the commented-out lines there) before training real models. "
            "The heuristic path in predict.py has no dependency on either and "
            "keeps working regardless."
        ) from exc

    condition_code_map = {"new": 2, "refurbished": 1, "used": 0}
    X = [[e["listing_price"], condition_code_map.get(e["condition"], 0)] for e in examples]
    y = [e["agreed_price"] for e in examples]

    model = lgb.LGBMRegressor(
        n_estimators=100, max_depth=4, learning_rate=0.1, min_child_samples=10,
    )
    model.fit(X, y)

    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    artifact_path = MODELS_DIR / f"price_{category}.joblib"
    joblib.dump(model, artifact_path)
    logger.info(
        "[ml] trained price model for category=%s on %d examples -> %s",
        category, len(examples), artifact_path,
    )


async def train_all(db: AsyncSession) -> dict:
    """
    §4.3's weekly retrain entry point (called from
    core/workers.task_retrain_ml_models). Returns {category: status} for
    logging/observability - status is "trained", "skipped_insufficient_data",
    or "error: ...".
    """
    counts = await count_completed_deals_by_category(db)
    results = {}

    for category, count in counts.items():
        if count < MIN_DEALS_PER_CATEGORY_FOR_ML:
            results[category] = (
                f"skipped_insufficient_data ({count}/{MIN_DEALS_PER_CATEGORY_FOR_ML})"
            )
            continue
        try:
            examples = await extract_pricing_examples(db, category=category)
            train_price_model(category, examples)
            results[category] = "trained"
        except Exception as exc:
            logger.error("[ml] training failed for category=%s: %s", category, exc)
            results[category] = f"error: {exc}"

    if not counts:
        logger.info("[ml] train_all: no categories with any funded deals yet - nothing to do")
    elif all(v.startswith("skipped") for v in results.values()):
        logger.info(
            "[ml] train_all: every category below the %d-deal threshold - "
            "still heuristic-only, as expected at this data volume (§4.4)",
            MIN_DEALS_PER_CATEGORY_FOR_ML,
        )

    return results
