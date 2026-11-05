"""The catalogue of everything BROKA can be billed for.

This is reference data, not dashboard output: it says which external
services exist, what they are billed in, and how their cost is derived. It
is seeded idempotently so a fresh database, an existing production database
and every test run agree on the same service keys.

Keys are stable identifiers written by instrumentation code. Renaming one
would orphan its usage history, so a key is added, never repurposed. The
descriptive columns (name, provider, notes, active) may be edited.

Costs are deliberately NOT seeded for services whose real rate BROKA does
not know (hosting, Redis, image generation, speech). Those start unpriced -
which the dashboard shows as "unpriced", never as zero - until an
administrator records a price or an invoice.
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.models.service_cost import (
    CostConfidence,
    PricingModel,
    ServiceCatalog,
    ServiceCategory,
    ServicePricing,
)

logger = logging.getLogger(__name__)

#: The earliest effective date for BROKA's initial known rates. Not a claim
#: about when a provider started charging - only the floor for the first
#: pricing row, so a report for any past period resolves to a known rate
#: rather than to nothing.
INITIAL_PRICING_FROM = datetime(2026, 1, 1)

# Each entry: the catalogue row, plus an optional initial unit price.
# `confidence` says whether that price is billed (exact) or assumed.
SEED: tuple[dict, ...] = (
    # ── Messaging ───────────────────────────────────────────────────────────
    {
        "service_key": "sms.texin",
        "service_name": "SMS — Texin BulkSMS",
        "provider": "Texin",
        "category": ServiceCategory.MESSAGING,
        "usage_unit": "sms_segment",
        "pricing_model": PricingModel.PER_UNIT,
        "is_billable": True,
        "cost_confidence": CostConfidence.EXACT,
        "reporting_notes": (
            "Confirmed KES 0.29 per GSM-7 segment. Texin reports units_used and "
            "cost per accepted send; the per-send figure is recorded when "
            "present and the segment count x rate otherwise."
        ),
        "initial_price_minor": 29,
        "initial_price_confidence": CostConfidence.EXACT,
        "initial_price_source": "PRICING.md — Texin confirmed rate",
    },
    {
        "service_key": "sms.africas_talking",
        "service_name": "SMS — Africa's Talking",
        "provider": "Africa's Talking",
        "category": ServiceCategory.MESSAGING,
        "usage_unit": "sms_segment",
        "pricing_model": PricingModel.PER_UNIT,
        "is_billable": True,
        "cost_confidence": CostConfidence.ESTIMATED,
        "reporting_notes": (
            "Fallback provider. BROKA has no verified rate for its own account, "
            "so the configured default (KES 0.80, top of Kenya's bulk band) is an "
            "estimate. Replace it with the account's real rate when confirmed."
        ),
        "initial_price_minor": 80,
        "initial_price_confidence": CostConfidence.ESTIMATED,
        "initial_price_source": "SMS_COST_MINOR_AT default — unconfirmed",
    },
    {
        "service_key": "sms.mobitech",
        "service_name": "SMS — Mobitech (deprecated)",
        "provider": "Mobitech Technologies",
        "category": ServiceCategory.MESSAGING,
        "usage_unit": "sms_message",
        "pricing_model": PricingModel.PER_UNIT,
        "is_billable": True,
        "cost_confidence": CostConfidence.EXACT,
        "reporting_notes": (
            "Deprecated provider kept live for in-flight delivery reports. Bills "
            "KES 0.35 per message regardless of length, so its unit is a message, "
            "not a segment."
        ),
        "initial_price_minor": 35,
        "initial_price_confidence": CostConfidence.EXACT,
        "initial_price_source": "PRICING.md — Mobitech per-message rate",
    },
    {
        "service_key": "push.fcm",
        "service_name": "Push notifications — FCM",
        "provider": "Firebase Cloud Messaging",
        "category": ServiceCategory.PUSH,
        "usage_unit": "push_message",
        "pricing_model": PricingModel.FREE,
        "is_billable": False,
        "cost_confidence": CostConfidence.EXACT,
        "reporting_notes": "Firebase Cloud Messaging is free at BROKA's volume.",
        "initial_price_minor": 0,
        "initial_price_confidence": CostConfidence.EXACT,
        "initial_price_source": "Firebase free tier",
    },
    # ── AI inference ────────────────────────────────────────────────────────
    {
        "service_key": "ai.deepseek",
        "service_name": "AI inference — DeepSeek",
        "provider": "DeepSeek",
        "category": ServiceCategory.AI_INFERENCE,
        "usage_unit": "request",
        "pricing_model": PricingModel.PER_TOKEN,
        "is_billable": True,
        "cost_confidence": CostConfidence.ESTIMATED,
        # Peak-hour pricing is exactly double off-peak; the estimate is
        # priced at off-peak, so the maximum is twice it.
        "max_cost_multiplier_bps": 20000,
        "reporting_notes": (
            "Token counts come from DeepSeek's response usage block. Priced at "
            "off-peak PRICING.md rates with a configurable FX rate; peak "
            "multiplier, cache-hit ratio and FX movement are not observed "
            "per call, so every figure is an estimate. The estimated maximum "
            "applies DeepSeek's 2x peak multiplier."
        ),
    },
    {
        "service_key": "ai.gemini",
        "service_name": "AI inference — Gemini",
        "provider": "Google Gemini",
        "category": ServiceCategory.AI_INFERENCE,
        "usage_unit": "request",
        "pricing_model": PricingModel.PER_TOKEN,
        "is_billable": False,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Used on the free tier path. No verified paid rate is configured, so "
            "requests and real token counts are recorded but the cost is "
            "unpriced rather than zero."
        ),
    },
    {
        "service_key": "ai.groq",
        "service_name": "AI inference — Groq",
        "provider": "Groq",
        "category": ServiceCategory.AI_INFERENCE,
        "usage_unit": "request",
        "pricing_model": PricingModel.FREE,
        "is_billable": False,
        "cost_confidence": CostConfidence.EXACT,
        "reporting_notes": "Configured free provider (AI_FREE_PROVIDERS); billed zero.",
        "initial_price_minor": 0,
        "initial_price_confidence": CostConfidence.EXACT,
        "initial_price_source": "AI_FREE_PROVIDERS",
    },
    {
        "service_key": "ai.openrouter",
        "service_name": "AI inference — OpenRouter",
        "provider": "OpenRouter",
        "category": ServiceCategory.AI_INFERENCE,
        "usage_unit": "request",
        "pricing_model": PricingModel.FREE,
        "is_billable": False,
        "cost_confidence": CostConfidence.EXACT,
        "reporting_notes": (
            "Configured free provider; the current model id ends in :free. If a "
            "paid model is configured, remove this service from "
            "AI_FREE_PROVIDERS so its cost stops being recorded as zero."
        ),
        "initial_price_minor": 0,
        "initial_price_confidence": CostConfidence.EXACT,
        "initial_price_source": "AI_FREE_PROVIDERS",
    },
    # ── Image generation ────────────────────────────────────────────────────
    {
        "service_key": "image.huggingface_fal",
        "service_name": "AI cover images — Hugging Face / fal-ai",
        "provider": "Hugging Face Inference Providers (fal-ai)",
        "category": ServiceCategory.IMAGE_GENERATION,
        "usage_unit": "image",
        "pricing_model": PricingModel.PER_UNIT,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "HF routes the model call to fal-ai and bills BROKA's HF account. "
            "The provider response carries a request id but no price, so "
            "completed generations are counted exactly and their cost stays "
            "unpriced until an administrator records a per-image price or the "
            "HF invoice total."
        ),
    },
    # ── Email ───────────────────────────────────────────────────────────────
    {
        "service_key": "email.resend",
        "service_name": "Transactional email — Resend",
        "provider": "Resend",
        "category": ServiceCategory.EMAIL,
        "usage_unit": "email",
        "pricing_model": PricingModel.FREE,
        "is_billable": False,
        "cost_confidence": CostConfidence.EXACT,
        "reporting_notes": (
            "Resend's free plan covers BROKA's verification mail (3,000 "
            "emails/month). Record a pricing row if the account moves to a paid "
            "plan; accepted sends are counted exactly."
        ),
        "initial_price_minor": 0,
        "initial_price_confidence": CostConfidence.EXACT,
        "initial_price_source": "Resend free plan",
    },
    # ── Voice ───────────────────────────────────────────────────────────────
    {
        "service_key": "stt.openai_whisper",
        "service_name": "Speech to text — OpenAI Whisper",
        "provider": "OpenAI",
        "category": ServiceCategory.VOICE,
        "usage_unit": "audio_request",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Billed per audio minute by OpenAI, but the transcription response "
            "does not report duration. Upload bytes are recorded; cost remains "
            "unpriced until a billing-period invoice is entered."
        ),
    },
    {
        "service_key": "stt.deepgram",
        "service_name": "Streaming speech to text — Deepgram",
        "provider": "Deepgram",
        "category": ServiceCategory.VOICE,
        "usage_unit": "voice_session",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "BROKA mints a short-lived client token; the audio then streams "
            "from the phone straight to Deepgram, so the minutes billed are not "
            "visible to the backend. Token grants are counted as sessions, and "
            "cost comes from a Deepgram invoice entry."
        ),
    },
    {
        "service_key": "stt.assemblyai",
        "service_name": "Streaming speech to text — AssemblyAI",
        "provider": "AssemblyAI",
        "category": ServiceCategory.VOICE,
        "usage_unit": "voice_session",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Short-lived streaming tokens only; the audio does not pass through "
            "BROKA. Sessions are counted, minutes are not observable."
        ),
    },
    {
        "service_key": "tts.deepgram",
        "service_name": "Text to speech — Deepgram Aura",
        "provider": "Deepgram",
        "category": ServiceCategory.VOICE,
        "usage_unit": "tts_request",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": "English fallback voice; priced from a Deepgram invoice.",
    },
    {
        "service_key": "tts.assemblyai",
        "service_name": "Text to speech — AssemblyAI Voice Agent",
        "provider": "AssemblyAI",
        "category": ServiceCategory.VOICE,
        "usage_unit": "tts_request",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": "Primary English voice; priced from an AssemblyAI invoice.",
    },
    {
        "service_key": "tts.edge",
        "service_name": "Text to speech — Microsoft Edge",
        "provider": "Microsoft Edge Read Aloud",
        "category": ServiceCategory.VOICE,
        "usage_unit": "tts_request",
        "pricing_model": PricingModel.FREE,
        "is_billable": False,
        "cost_confidence": CostConfidence.EXACT,
        "reporting_notes": (
            "Free, unofficial endpoint. No key and no bill; catalogued so its "
            "usage is visible beside the paid fallbacks."
        ),
        "initial_price_minor": 0,
        "initial_price_confidence": CostConfidence.EXACT,
        "initial_price_source": "No charge (unofficial endpoint)",
    },
    {
        "service_key": "tts.hf_space",
        "service_name": "Text to speech — Kokoro (HF Space)",
        "provider": "Hugging Face Spaces",
        "category": ServiceCategory.VOICE,
        "usage_unit": "tts_request",
        "pricing_model": PricingModel.FREE,
        "is_billable": False,
        "cost_confidence": CostConfidence.EXACT,
        "reporting_notes": "BROKA's own free Hugging Face Space for Sheng and other languages.",
        "initial_price_minor": 0,
        "initial_price_confidence": CostConfidence.EXACT,
        "initial_price_source": "BROKA-owned free Space",
    },
    # ── Payments / escrow ───────────────────────────────────────────────────
    {
        "service_key": "payments.daraja",
        "service_name": "M-Pesa collections — Daraja",
        "provider": "Safaricom Daraja",
        "category": ServiceCategory.PAYMENTS,
        "usage_unit": "payment",
        "pricing_model": PricingModel.TIERED,
        "is_billable": True,
        "cost_confidence": CostConfidence.ESTIMATED,
        "reporting_notes": (
            "STK prompts are counted when Daraja accepts them. The collection "
            "fee depends on the settled amount (tariff bands) and is derived "
            "in /admin/revenue from settled payments; use a cost entry for a "
            "Safaricom invoice if the banded figure differs."
        ),
    },
    {
        "service_key": "payments.zetupay",
        "service_name": "M-Pesa collections — ZetuPay",
        "provider": "ZetuPay",
        "category": ServiceCategory.PAYMENTS,
        "usage_unit": "payment",
        "pricing_model": PricingModel.PER_UNIT,
        "is_billable": True,
        "cost_confidence": CostConfidence.ESTIMATED,
        "reporting_notes": (
            "ZetuPay publishes no fee schedule; the settled fee is a 1.5% "
            "assumption (ZETUPAY_FEE_PCT) and every such figure is estimated. "
            "Counted when a payment settles."
        ),
    },
    {
        "service_key": "escrow.econfirm",
        "service_name": "Marketplace escrow — E-Confirm",
        "provider": "E-Confirm",
        "category": ServiceCategory.ESCROW,
        "usage_unit": "escrow_payment",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": False,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "E-Confirm holds deal money, not BROKA income. No provider fee is "
            "charged in code, so this is catalogued for completeness and can "
            "carry a manual invoice entry if E-Confirm bills BROKA."
        ),
    },
    # ── Storage / infrastructure ────────────────────────────────────────────
    {
        "service_key": "storage.r2",
        "service_name": "Image storage — Cloudflare R2",
        "provider": "Cloudflare R2",
        "category": ServiceCategory.STORAGE,
        "usage_unit": "byte",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Bytes written per object are measured exactly. R2 bills storage "
            "per GB-month (and Class A/B operations); storage and egress cost "
            "come from a Cloudflare invoice entry, not from these writes."
        ),
    },
    {
        "service_key": "storage.database_blobs",
        "service_name": "Image storage — database fallback",
        "provider": "BROKA PostgreSQL",
        "category": ServiceCategory.STORAGE,
        "usage_unit": "byte",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": False,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Used when R2 is not configured. Its cost is part of the database "
            "bill, so it is catalogued separately for volume visibility only."
        ),
    },
    {
        "service_key": "infra.render_api",
        "service_name": "Backend hosting — Render",
        "provider": "Render",
        "category": ServiceCategory.HOSTING,
        "usage_unit": "month",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Instance, bandwidth and runtime charges are not exposed to the "
            "application. Enter the monthly Render invoice as a cost entry."
        ),
    },
    {
        "service_key": "infra.postgres",
        "service_name": "Database — PostgreSQL (Render)",
        "provider": "Render PostgreSQL",
        "category": ServiceCategory.DATABASE,
        "usage_unit": "byte",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Database size is sampled hourly from pg_database_size on "
            "PostgreSQL (the SQLite fallback records nothing). Storage, "
            "connections and compute are billed by plan, so cost is entered "
            "from the Render invoice."
        ),
    },
    {
        "service_key": "infra.redis",
        "service_name": "Cache / queue — Redis (Upstash)",
        "provider": "Upstash",
        "category": ServiceCategory.CACHE,
        "usage_unit": "command",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Upstash's free plan covers current usage. Command and memory "
            "figures are sampled from Redis INFO when the server allows it; "
            "the plan cost is entered manually."
        ),
    },
    {
        "service_key": "infra.vercel",
        "service_name": "Web storefront — Vercel",
        "provider": "Vercel",
        "category": ServiceCategory.HOSTING,
        "usage_unit": "month",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": "Storefront hosting and bandwidth; enter the Vercel invoice.",
    },
    {
        "service_key": "infra.sentry",
        "service_name": "Error monitoring — Sentry",
        "provider": "Sentry",
        "category": ServiceCategory.MONITORING,
        "usage_unit": "month",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": False,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": "Free tier covers 5,000 errors/month; enter a plan cost if upgraded.",
    },
    {
        "service_key": "calls.cloudflare_turn",
        "service_name": "Call relay — Cloudflare Realtime TURN",
        "provider": "Cloudflare",
        "category": ServiceCategory.VOICE,
        "usage_unit": "turn_session",
        "pricing_model": PricingModel.MANUAL,
        "is_billable": True,
        "cost_confidence": CostConfidence.UNKNOWN,
        "reporting_notes": (
            "Credentials are issued per call; relayed bytes are not visible to "
            "the backend. Sessions are counted and priced from a Cloudflare "
            "invoice (TURN bills per GB relayed)."
        ),
    },
)


async def ensure_catalog(
    db: AsyncSession, *, commit: bool = True
) -> dict[str, ServiceCatalog]:
    """Insert any missing catalogue rows; never touches an existing row's
    operator-editable state (active, names, notes). Returns key -> row.

    `commit=False` is used when this runs inside another transaction (a
    payment settlement): seeding reference data must not commit money early.
    """
    rows = (await db.execute(select(ServiceCatalog))).scalars().all()
    by_key = {row.service_key: row for row in rows}
    created = False
    for item in SEED:
        if item["service_key"] in by_key:
            continue
        row = ServiceCatalog(
            service_key=item["service_key"],
            service_name=item["service_name"],
            provider=item["provider"],
            category=item["category"],
            usage_unit=item["usage_unit"],
            pricing_model=item["pricing_model"],
            is_billable=item["is_billable"],
            cost_confidence=item["cost_confidence"],
            max_cost_multiplier_bps=item.get("max_cost_multiplier_bps", 10000),
            reporting_notes=item.get("reporting_notes"),
            active=True,
        )
        db.add(row)
        await db.flush()
        by_key[row.service_key] = row
        created = True
        price = item.get("initial_price_minor")
        if price is not None:
            db.add(
                ServicePricing(
                    service_id=row.id,
                    pricing_unit=row.usage_unit,
                    unit_price_minor=int(price),
                    currency="KES",
                    effective_from=INITIAL_PRICING_FROM,
                    effective_until=None,
                    pricing_source=item.get("initial_price_source") or "catalogue seed",
                    cost_confidence=item.get(
                        "initial_price_confidence", CostConfidence.ESTIMATED
                    ),
                    created_by="system",
                )
            )
    if created:
        if commit:
            await db.commit()
        else:
            await db.flush()
        # The rows were just written; re-read so callers get ids and the
        # same instances every other session will see.
        rows = (await db.execute(select(ServiceCatalog))).scalars().all()
        by_key = {row.service_key: row for row in rows}
        logger.info("[service-costs] catalogue seeded (%d services)", len(by_key))
    return by_key


async def seed_service_catalog() -> int:
    """Idempotent startup seed. Never raises: a seed failure must not stop
    the API, and instrumentation will retry the lookup on first use."""
    from api.database import AsyncSessionLocal

    try:
        async with AsyncSessionLocal() as db:
            return len(await ensure_catalog(db))
    except Exception as exc:  # pragma: no cover - defensive startup path
        logger.error("[service-costs] catalogue seed failed: %s", type(exc).__name__)
        return 0


def initial_unit_price_minor(service_key: str) -> Optional[int]:
    """The seeded rate, for tests and for explaining a catalogue row."""
    for item in SEED:
        if item["service_key"] == service_key:
            return item.get("initial_price_minor")
    return None


def configured_fx_rate() -> float:
    """The recorded conversion rate used when an admin supplies a USD price.

    Returned for display only: this module never converts a stored amount
    behind a report. A conversion must be explicit and recorded.
    """
    return float(settings.ai_usd_to_kes)
