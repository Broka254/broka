"""Platform cost ledger — record what BROKA spends, honestly.

Every writer passes estimated explicitly. A row is estimated=True when its
rate is assumed rather than billed: the Africa's Talking per-SMS rate (no
account of ours to read it from), the ZetuPay collection fee (a 1.5%
assumption — ZetuPay's docs state no fee schedule), and any AI row (model
prices move, and peak multipliers plus cache-hit ratios are not tracked per
call). Revenue math sums estimated rows separately so estimates never pose
as actuals.

Rates live on Settings (config.py) with backend/.env.example entries so an
operator corrects them without a deploy-time code change.

Collection fees (payment_fee) are DERIVED at report time in api/core/
revenue.py from settled payments — never stored. A stored payment_fee row
would double-count against the derived figure, so revenue.py excludes
stored payment_fee rows by definition (see its header comment).
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Optional

from sqlalchemy.ext.asyncio import AsyncSession

from api.models.platform_cost import CostKind, PlatformCost

_log = logging.getLogger(__name__)


async def record_cost(
    db: AsyncSession,
    *,
    kind: str,
    amount_minor: int,
    currency: str = "KES",
    provider: Optional[str] = None,
    ref_type: Optional[str] = None,
    ref_id: Optional[str] = None,
    estimated: bool = False,
    meta: Optional[dict] = None,
) -> PlatformCost:
    """Append one cost row. Does not commit — the caller owns the
    transaction, so the row lands atomically with the payment or send it
    describes (a cost row without its payment would overstate spend)."""
    if kind not in CostKind.ALL:
        raise ValueError(f"unknown cost kind {kind!r}")
    row = PlatformCost(
        kind=kind,
        amount_minor=int(amount_minor),
        currency=currency,
        provider=provider,
        ref_type=ref_type,
        ref_id=ref_id,
        estimated=bool(estimated),
        meta=meta or {},
        created_at=datetime.utcnow(),
    )
    db.add(row)
    await db.flush()
    return row


async def record_cost_detached(
    *,
    kind: str,
    amount_minor: int,
    currency: str = "KES",
    provider: Optional[str] = None,
    ref_type: Optional[str] = None,
    ref_id: Optional[str] = None,
    estimated: bool = False,
    meta: Optional[dict] = None,
) -> Optional[PlatformCost]:
    """record_cost for call sites that hold no session (SMS providers).

    Opens, commits and closes its own session. Best-effort by design: cost
    accounting must never fail an OTP send, so every error is logged and
    swallowed and the caller gets None.
    """
    from api.database import AsyncSessionLocal

    try:
        async with AsyncSessionLocal() as db:
            row = await record_cost(
                db,
                kind=kind,
                amount_minor=amount_minor,
                currency=currency,
                provider=provider,
                ref_type=ref_type,
                ref_id=ref_id,
                estimated=estimated,
                meta=meta,
            )
            await db.commit()
            return row
    except Exception as exc:
        _log.warning("[costs] detached record failed (non-fatal): %s", exc)
        return None


async def record_sms_cost(*, provider: str) -> Optional[PlatformCost]:
    """One row per message actually handed to an SMS provider.

    Called by each provider's send() only after the provider accepted the
    message, so a failed attempt costs nothing and a fallback chain that
    hands the same text to two providers logs two rows — one per handoff,
    which is what was billed. The dev/CI ConsoleSMS logs nothing: no
    provider was handed anything, so nothing was spent.
    """
    try:
        from api.core.config import settings

        if provider == "mobitech":
            # PRICING.md: Mobitech bills KES 0.35 a message whatever its length.
            amount = int(settings.sms_cost_minor_mobitech)
            estimated = False
        else:
            # No Africa's Talking rate was verified against our account; the
            # Kenyan bulk market runs KES 0.25-0.80 (PRICING.md), so the
            # default sits at the top of that band and every such row is
            # flagged estimated until the real rate is configured.
            amount = int(settings.sms_cost_minor_at)
            estimated = True
        return await record_cost_detached(
            kind=CostKind.SMS,
            amount_minor=amount,
            provider=provider,
            estimated=estimated,
            meta={"rate_source": "settings"},
        )
    except Exception as exc:
        _log.warning("[costs] sms record failed (non-fatal): %s", exc)
        return None


def _extract_tokens(
    provider: str, response_data: Optional[dict]
) -> tuple[Optional[int], Optional[int]]:
    """(input_tokens, output_tokens) from a provider response body.

    OpenAI-compatible bodies (DeepSeek, Groq, OpenRouter) carry
    usage.{prompt_tokens,completion_tokens}; Gemini carries
    usageMetadata.{promptTokenCount,candidatesTokenCount}. Either side is
    None when the provider omitted it — the row still lands (the call
    happened) with tokens_unknown in meta.
    """
    if not isinstance(response_data, dict):
        return None, None
    if provider == "gemini":
        usage = response_data.get("usageMetadata") or {}
        in_tokens = usage.get("promptTokenCount")
        out_tokens = usage.get("candidatesTokenCount")
    else:
        usage = response_data.get("usage") or {}
        in_tokens = usage.get("prompt_tokens")
        out_tokens = usage.get("completion_tokens")
    try:
        in_tokens = int(in_tokens) if in_tokens is not None else None
    except (TypeError, ValueError):
        in_tokens = None
    try:
        out_tokens = int(out_tokens) if out_tokens is not None else None
    except (TypeError, ValueError):
        out_tokens = None
    return in_tokens, out_tokens


def ai_cost_minor(
    provider: str,
    input_tokens: Optional[int],
    output_tokens: Optional[int],
) -> tuple[int, bool, dict]:
    """Price one LLM call in KES minor units.

    Returns (amount_minor, estimated, meta). Pricing rules, in order:
      1. Providers on AI_FREE_PROVIDERS (Groq + OpenRouter's :free model
         today) cost nothing — amount 0, estimated False.
      2. A provider with configured per-1M-token USD rates
         (ai_<provider>_input/output_per_1m_usd; only DeepSeek ships with
         PRICING.md rates) is priced from real tokens at the off-peak
         rate — estimated True, because peak doubling, cache-hit ratios
         and FX are not tracked per call.
      3. Anything else is unpriced: amount 0, estimated True, with the
         real token counts in meta so the spend is visible even though no
         verified rate exists. To price a provider later, add its two
         rate settings — no code change needed.
    Unknown token counts price to 0 with tokens_unknown in meta rather
    than guessing.
    """
    from api.core.config import settings

    meta: dict[str, Any] = {}
    if input_tokens is not None:
        meta["input_tokens"] = input_tokens
    if output_tokens is not None:
        meta["output_tokens"] = output_tokens
    free = {
        p.strip().lower()
        for p in str(getattr(settings, "ai_free_providers", "") or "").split(",")
        if p.strip()
    }
    if provider.lower() in free:
        meta["free_tier"] = True
        return 0, False, meta
    rate_in = getattr(settings, f"ai_{provider}_input_per_1m_usd", None)
    rate_out = getattr(settings, f"ai_{provider}_output_per_1m_usd", None)
    if (
        rate_in is None
        or rate_out is None
        or input_tokens is None
        or output_tokens is None
    ):
        meta["unpriced"] = rate_in is None or rate_out is None
        meta["tokens_unknown"] = (
            input_tokens is None or output_tokens is None
        )
        return 0, True, meta
    usd = (input_tokens / 1_000_000) * float(rate_in) + (
        output_tokens / 1_000_000
    ) * float(rate_out)
    kes_minor = int(round(usd * float(settings.ai_usd_to_kes) * 100))
    meta["rate"] = "off-peak PRICING.md; peak/cache/FX untracked"
    return kes_minor, True, meta


async def record_ai_cost(
    *,
    provider: str,
    response_data: Optional[dict] = None,
    model: Optional[str] = None,
    call_site: str = "",
) -> Optional[PlatformCost]:
    """One row per successful LLM call, priced by ai_cost_minor().

    Called by each provider function only after a usable reply was parsed,
    so failed attempts and fallthroughs cost nothing and each fallback hop
    that actually answered logs its own row. Best-effort like SMS costs:
    accounting must never fail a chat reply.
    """
    try:
        in_tokens, out_tokens = _extract_tokens(provider, response_data)
        amount, estimated, meta = ai_cost_minor(
            provider, in_tokens, out_tokens
        )
        if model:
            meta["model"] = model
        if call_site:
            meta["call_site"] = call_site
        return await record_cost_detached(
            kind=CostKind.AI,
            amount_minor=amount,
            provider=provider,
            estimated=estimated,
            meta=meta,
        )
    except Exception as exc:
        _log.warning("[costs] ai record failed (non-fatal): %s", exc)
        return None


def mpesa_fee_minor(amount_kes: float) -> tuple[int, bool]:
    """M-Pesa collection fee for one payment, in minor units.

    Bands from PRICING.md (tariff of 7 Aug 2026): free to KES 100, KES 3 to
    500, KES 5 to 1,000, capped at KES 54. Above KES 1,000 the schedule
    names no band, so the cap is used and the row must be estimated.
    """
    amount = float(amount_kes or 0)
    if amount <= 100:
        return 0, False
    if amount <= 500:
        return 300, False
    if amount <= 1000:
        return 500, False
    return 5400, True


def zetupay_fee_minor(amount_kes: float) -> tuple[int, bool]:
    """ZetuPay collection fee, in minor units.

    ZetuPay's published docs state no fee schedule, so this is a 1.5%
    assumption (configurable via ZETUPAY_FEE_PCT) and every such row is
    estimated until the real schedule is confirmed.
    """
    from api.core.config import settings

    pct = float(settings.zetupay_fee_pct)
    # amount × pct/100 KES × 100 minor/KES = amount × pct minor.
    return round(float(amount_kes or 0) * pct), True
