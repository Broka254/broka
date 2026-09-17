"""
BROKA - ML Prediction Service (Volume 2 §4.2, §4.3, §4.4)
─────────────────────────────────────────────────────────────────────────────
predict_price() / predict_leak_risk() are heuristic-only right now, exactly
per §4.4's explicit instruction: "Build the ml/ package ... but only switch
... over from heuristic to learned-model implementations once each category
has accumulated enough completed deals." Both methods already check for a
trained artifact first and will use it automatically once train.py has
produced one for a category that crosses MIN_DEALS_PER_CATEGORY_FOR_ML - no
code change needed when that day comes, just an artifact appearing on disk.

One deviation from §4.3's wording: "MLPredictionService ... exposes
SYNCHRONOUS predict_price(), predict_leak_risk()." That's the right shape
once a category has a loaded model (pure in-memory inference, genuinely
synchronous, no DB needed). It isn't possible for the heuristic fallback
today - the heuristic needs a live category-average query, and this
codebase is async SQLAlchemy throughout, with no synchronous DB path
anywhere to reuse. Both methods are async here; the day the first category
crosses the ML threshold, its predictions stop touching the DB at request
time at all (artifact load happens once, at process start - see
_load_artifacts), so this converges toward §4.3's intent rather than
permanently working around it.
"""
from __future__ import annotations

import logging
import statistics
from pathlib import Path
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession

from api.core.ml.feature_extraction import (
    MIN_DEALS_PER_CATEGORY_FOR_ML,
    count_completed_deals_by_category,
    extract_pricing_examples,
)

logger = logging.getLogger(__name__)

MODELS_DIR = Path(__file__).parent / "models"

# Heuristic leak-risk weights - hand-set, not learned (that's precisely what
# §4.2's "leakage-risk classifier" will later replace once labelled examples
# exist - see train.py). Deliberately simple and legible rather than tuned.
_LEAK_RISK_SOLICITATION_WEIGHT = 0.55
_LEAK_RISK_LONG_DELAY_WEIGHT   = 0.30
_LEAK_RISK_LONG_DELAY_HOURS    = 48.0   # avg response gap beyond this counts as "long"
_LEAK_RISK_BASE                = 0.10   # every negotiation carries some baseline risk


class MLPredictionService:
    """
    One instance per process (see domains/ai_broker/service.py for how it's
    constructed and reused, mirroring how that file already holds gemini_key/
    groq_key/openrouter_key as instance state rather than re-reading config
    on every call).
    """

    def __init__(self):
        # Populated lazily per-category the first time a trained artifact is
        # looked for - see _load_artifact_for_category. Empty dict today,
        # since nothing has been trained yet (§4.4).
        self._loaded_artifacts: dict = {}

    def _load_artifact_for_category(self, category: str):
        """
        Returns a loaded joblib model for this category, or None if no
        artifact exists yet (the normal case today - falls through to the
        heuristic). Cached in-process after the first successful load so
        repeat predictions for the same category don't re-hit disk.
        """
        if category in self._loaded_artifacts:
            return self._loaded_artifacts[category]

        artifact_path = MODELS_DIR / f"price_{category}.joblib"
        if not artifact_path.exists():
            self._loaded_artifacts[category] = None
            return None

        try:
            import joblib
            model = joblib.load(artifact_path)
            self._loaded_artifacts[category] = model
            logger.info("[ml] loaded trained price model for category=%s", category)
            return model
        except Exception as exc:
            logger.warning("[ml] failed to load artifact for category=%s: %s", category, exc)
            self._loaded_artifacts[category] = None
            return None

    async def predict_price(
        self, category: str, condition: str, listing_price: float, db: AsyncSession,
    ) -> dict:
        """
        Returns {min_price, max_price, recommended_price, confidence, source}.
        source is "model" or "heuristic" - domains/ai_broker/service.py
        surfaces this so Zeno's copy can (honestly) hedge more on a
        heuristic estimate than a model-backed one.
        """
        counts = await count_completed_deals_by_category(db)
        deal_count = counts.get(category, 0)

        if deal_count >= MIN_DEALS_PER_CATEGORY_FOR_ML:
            model = self._load_artifact_for_category(category)
            if model is not None:
                try:
                    return self._predict_price_from_model(model, condition, listing_price)
                except Exception as exc:
                    logger.warning(
                        "[ml] model inference failed for category=%s, falling back to heuristic: %s",
                        category, exc,
                    )
        return await self._predict_price_heuristic(category, condition, listing_price, db)

    def _predict_price_from_model(self, model, condition: str, listing_price: float) -> dict:
        # Feature order must match train.py's training matrix exactly.
        condition_code = {"new": 2, "refurbished": 1, "used": 0}.get(condition, 0)
        predicted = float(model.predict([[listing_price, condition_code]])[0])
        return {
            "min_price":          round(predicted * 0.9),
            "max_price":          round(predicted * 1.1),
            "recommended_price":  round(predicted),
            "confidence":         "model",
            "source":             "model",
        }

    async def _predict_price_heuristic(
        self, category: str, condition: str, listing_price: float, db: AsyncSession,
    ) -> dict:
        examples = await extract_pricing_examples(db, category=category)
        same_condition = [e["agreed_price"] for e in examples if e["condition"] == condition]
        prices = same_condition or [e["agreed_price"] for e in examples]

        if not prices:
            # No comparable deals at all yet (brand-new category, or the
            # very first listings BROKA has ever seen in it) - fall back to
            # the seller's own asking price with a wide band rather than
            # returning nothing. Wide band signals low confidence honestly.
            return {
                "min_price":          round(listing_price * 0.75),
                "max_price":          round(listing_price * 1.25),
                "recommended_price":  round(listing_price),
                "confidence":         "low_no_comparable_data",
                "source":             "heuristic",
            }

        median_price = statistics.median(prices)
        # Wide band on purpose - a category-average heuristic with a handful
        # of comparable deals should read as a rough estimate, not a precise
        # model output. Narrows naturally once a real model takes over.
        return {
            "min_price":          round(median_price * 0.8),
            "max_price":          round(median_price * 1.2),
            "recommended_price":  round(median_price),
            "confidence":         "low" if len(prices) < 10 else "medium",
            "source":             "heuristic",
        }

    async def predict_leak_risk(
        self, message_count: int, avg_response_delay_hours: Optional[float],
        had_solicitation_flag: bool,
    ) -> float:
        """
        Returns 0-1 risk score. Hand-weighted heuristic (see module
        docstring) - §4.2's learned classifier replaces this body once
        domains/trust/completion_rate.flag_leaked_deals() has produced
        enough labelled examples (extract_leak_risk_examples in
        feature_extraction.py is already collecting them).
        """
        risk = _LEAK_RISK_BASE
        if had_solicitation_flag:
            risk += _LEAK_RISK_SOLICITATION_WEIGHT
        if avg_response_delay_hours is not None and avg_response_delay_hours > _LEAK_RISK_LONG_DELAY_HOURS:
            risk += _LEAK_RISK_LONG_DELAY_WEIGHT
        return round(min(risk, 1.0), 3)


# Module-level singleton, not something callers instantiate themselves.
# domains/ai_broker/service.py's AIBrokerService is created fresh on every
# request (see its router: `svc = AIBrokerService()` per call) - if
# MLPredictionService lived as an AIBrokerService instance attribute
# instead, _loaded_artifacts would reset every request and the whole
# point of caching a loaded model in memory would be lost. Importing this
# instance is the intended usage everywhere in the app.
ml_prediction_service = MLPredictionService()
