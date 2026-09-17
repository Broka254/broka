"""
Escrow Service v4.0
Hardened: atomic DB operations, audit logs, fraud checks, event publishing.

v4.0 (2026-09) adds E-Confirm API v2 marketplace escrow (see api/core/
econfirm_client.py, api/domains/escrow/providers.py, api/models/
external_escrow.py). Two flows now coexist on purpose:

  • A Deal with NO ExternalEscrow row was (or is being) funded the
    original way — Daraja STK-push for Deal.commission only (see
    api/routers/mpesa.py), goods price settled off-platform. confirm_delivery
    keeps its original direct-release behavior for these unchanged.
  • A Deal WITH an ExternalEscrow row is funded through E-Confirm for the
    FULL agreed price. confirm_delivery calls E-Confirm's release endpoint
    and only marks the deal released once the provider confirms — see
    _confirm_delivery_econfirm.

This is deliberate, not incidental: "do not rewrite the entire payment
system" (integration spec, Phase 18) — deals already in flight on the old
rail finish on the old rail.
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional

from fastapi import HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import (
    Deal, DealStatus, Listing, User, MpesaTransaction, MpesaStatus,
)
from api.core.events import (
    publish, DealFinalized, EscrowFunded, EscrowReleased,
    EConfirmEscrowCreated, EConfirmFundingInitiated, EConfirmEscrowFunded,
    EConfirmReleaseInitiated, EConfirmPayoutCompleted, EConfirmPayoutFailed,
    EConfirmReconciliationRequired,
)
from api.core.audit import record_audit
from api.core.fraud import flag_fraud, compute_trust_score
from api.core.config import settings
from api.core.econfirm_client import EConfirmError, EConfirmConnectionError, EConfirmAPIError
from api.core.secrets_crypto import encrypt_secret, decrypt_secret, SecretCryptoError
from api.models.external_escrow import ExternalEscrow, EConfirmEscrowStatus
from .repository import DealRepository, MpesaRepository, ExternalEscrowRepository
from .providers import get_escrow_provider

logger = logging.getLogger(__name__)


# Mirrors MAX_AGREED_PRICE_KES in api/domains/escrow/router.py.
MAX_AGREED_PRICE_KES = 20_000_000.0


def validate_agreed_price(price) -> float:
    """Reject prices that must never become a money obligation.

    Defence in depth: the router's Pydantic model already enforces this for
    POST /deal/finalize, but finalize_deal() is also reachable from
    api/routers/negotiate.py's deal-acceptance intents, which build their
    price from parsed conversation text rather than from a validated
    request body. A price extracted from "let's do 50k" is exactly the kind
    of input that can arrive as 0, negative, or non-finite, and this is the
    last point before it is written to a Deal row.
    """
    try:
        p = float(price)
    except (TypeError, ValueError):
        raise HTTPException(status_code=422, detail="Agreed price is not a valid number")
    # NaN fails every comparison including against itself, so a plain range
    # check would let it through - it has to be tested for directly.
    if p != p or p in (float("inf"), float("-inf")):
        raise HTTPException(status_code=422, detail="Agreed price is not a valid number")
    if p <= 0:
        raise HTTPException(status_code=422, detail="Agreed price must be greater than zero")
    if p > MAX_AGREED_PRICE_KES:
        raise HTTPException(
            status_code=422,
            detail=f"Agreed price exceeds the maximum supported deal value "
                   f"(KES {MAX_AGREED_PRICE_KES:,.0f})",
        )
    return round(p, 2)


def _commission(price: float) -> float:
    return round(price * settings.commission_rate, 2)


class EscrowService:
    def __init__(self, db: AsyncSession):
        self.db = db
        self.deals = DealRepository(db)
        self.mpesa = MpesaRepository(db)
        self.external_escrows = ExternalEscrowRepository(db)

    # ── Finalize ─────────────────────────────────────────────────────────

    async def finalize_deal(
        self,
        listing_id: str,
        buyer_id: str,
        agreed_price: float,
        current_user_id: str,   # authenticated caller — see note below
        request_ip: Optional[str] = None,
    ) -> dict:
        """
        current_user_id (renamed from this method's old `seller_id` param —
        see api/domains/escrow/router.py's call site) is whoever is
        authenticated and tapped "finalize/accept", which Flutter allows
        for EITHER party (negotiate_screen.dart's _acceptDeal lets buyer OR
        seller accept; negotiation_screen.dart's Finalize button is
        buyer-only) — this endpoint used to hard-require the caller to be
        the listing's seller, which silently 403'd every buyer-side accept.
        Fixed per Phase 17 of the integration spec WITHOUT reviving
        api/routers/deal.py (dead code — imported in main.py but never
        mounted, confirmed by inspecting main.py's app.include_router
        calls) and WITHOUT trusting a client-supplied seller_id: the caller
        must be the listing's real seller (in which case buyer_id comes
        from the request body, same trust level this endpoint always had)
        OR must BE the buyer_id they're claiming (so nobody can finalize a
        deal claiming to be a buyer who isn't them).
        """
        agreed_price = validate_agreed_price(agreed_price)

        r = await self.db.execute(select(Listing).where(Listing.id == listing_id))
        listing = r.scalar_one_or_none()
        if not listing:
            raise HTTPException(status_code=404, detail="Listing not found")

        if current_user_id == listing.seller_id:
            seller_id = listing.seller_id
        elif current_user_id == buyer_id:
            seller_id = listing.seller_id
        else:
            raise HTTPException(
                status_code=403,
                detail="Only the listing's seller, or the buyer accepting it, can finalize this deal",
            )

        # Prevent duplicate deals
        existing = await self.deals.get_by_listing_buyer(listing_id, buyer_id)
        if existing and existing.status not in (DealStatus.cancelled,):
            return {"deal_id": existing.id, "status": existing.status.value, "existed": True}

        commission = _commission(agreed_price)
        deal = await self.deals.create(
            listing_id=listing_id,
            seller_id=seller_id,
            buyer_id=buyer_id,
            agreed_price=agreed_price,
            commission=commission,
            status=DealStatus.agreed,
        )

        # Update listing status
        listing.status = "pending"
        await self.db.commit()
        await self.db.refresh(deal)

        await record_audit(
            self.db, current_user_id, "deal_finalized", "deal", deal.id,
            f"agreed_price={agreed_price} commission={commission}",
            ip_address=request_ip,
        )
        await self.db.commit()

        await publish(DealFinalized(
            deal_id=deal.id,
            listing_id=listing_id,
            seller_id=seller_id,
            buyer_id=buyer_id,
            agreed_price=agreed_price,
            commission=commission,
        ))

        return {
            "deal_id": deal.id,
            "listing_id": listing_id,
            "seller_id": seller_id,
            "buyer_id": buyer_id,
            "agreed_price": agreed_price,
            "commission": commission,
            "amount_to_pay": agreed_price + commission,
            "status": deal.status.value,
        }

    # ── E-Confirm: fee quote (Phase 5 / Phase 14) ──────────────────────────

    async def get_fee_quote(self, deal_id: str, user_id: str) -> dict:
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if user_id not in (deal.buyer_id, deal.seller_id):
            raise HTTPException(status_code=403, detail="Not your deal")
        if deal.status != DealStatus.agreed:
            raise HTTPException(
                status_code=400,
                detail=f"Fee quote is only available while a deal is 'agreed' (current: '{deal.status.value}')",
            )

        try:
            quote = await get_escrow_provider().get_fee_quote(deal.agreed_price)
        except EConfirmConnectionError as exc:
            logger.warning("[escrow] fee quote connection error deal=%s: %s", deal_id, exc)
            raise HTTPException(status_code=503, detail="Payment provider is temporarily unavailable — please try again shortly")
        except EConfirmAPIError as exc:
            logger.warning("[escrow] fee quote rejected deal=%s status=%d", deal_id, exc.status_code)
            raise HTTPException(status_code=502, detail="Could not get a payment quote right now")
        except EConfirmError as exc:
            logger.error("[escrow] fee quote error deal=%s: %s", deal_id, exc)
            raise HTTPException(status_code=502, detail="Could not get a payment quote right now")

        provider_fee = round(quote.fee_amount, 2)
        total = round(deal.agreed_price + deal.commission + provider_fee, 2)
        return {
            "deal_id": deal_id,
            "goods_amount": deal.agreed_price,
            "merchant_commission": deal.commission,
            "provider_fee": provider_fee,
            "total_to_pay": total,
            "currency": quote.currency,
        }

    # ── E-Confirm: create + fund (Phase 6 / Phase 7) ───────────────────────

    async def fund_deal_escrow(
        self, deal_id: str, buyer_id: str, payer_phone: str, request_ip: Optional[str] = None,
    ) -> dict:
        """
        Buyer-facing action fusing Phase 6 (create escrow if one doesn't
        exist yet) and Phase 7 (STK-push funding) into the single call
        Phase 15's Flutter method list implies (fundDealEscrow — there is
        no separate "create escrow" call from the client).

        2026-09 hardening pass: provider.fund_escrow() is now called AT
        MOST ONCE per ExternalEscrow, full stop — tracked via
        escrow.funding_initiated_at, set the moment a real attempt is
        made (a successful send, OR an ambiguous connection failure;
        deliberately NOT a confirmed 4xx rejection, which legitimately
        allows a corrected retry — see the except branches below). Once
        that's set, no repeat /fund call reaches provider.fund_escrow()
        again for this escrow — it triggers a safe, read-only
        reconciliation pass instead and returns whatever that reveals.
        "The buyer tapped Pay again, possibly with a different
        Idempotency-Key" is deliberately not sufficient authorization on
        its own to re-send a real STK push — that used to be possible
        whenever escrow.status was PENDING, which is exactly the state a
        legitimately-already-sent STK push sits in while the buyer is
        still completing it on their phone.
        """
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != buyer_id:
            raise HTTPException(status_code=403, detail="Only the buyer can fund this deal")

        escrow = await self.external_escrows.get_by_deal_id(deal_id)

        if deal.status != DealStatus.agreed:
            if escrow is not None:
                return await self._payment_status_dict(deal, escrow)
            raise HTTPException(status_code=400, detail=f"Cannot fund — deal status is '{deal.status.value}'")

        if escrow is None:
            escrow = await self._create_external_escrow(deal, buyer_id)
            # Freshly created: funding_initiated_at is still None, so this
            # legitimately falls through to the first-ever fund attempt below.

        elif escrow.status == EConfirmEscrowStatus.CREATING and not escrow.provider_transaction_id:
            # create_transaction's outcome is unresolved — no id came
            # back, so unlike a stuck *funding* attempt there is nothing
            # to ask E-Confirm's get_status() about. This codebase has no
            # confirmed E-Confirm v2 idempotency/reference-field support
            # to rely on for a safe automatic retry (see
            # api/core/econfirm_client.py's module docstring on
            # unverified contract details), so — UNLESS the prior attempt
            # was a clean, confirmed rejection rather than an ambiguous
            # one (see the last_error prefix check below, set by
            # _create_external_escrow) — this deliberately does NOT
            # retry automatically past a short grace window. Silently
            # creating a second transaction when the first's outcome is
            # unknown is exactly the duplicate-transaction risk this
            # pass exists to close.
            confirmed_rejection = bool(escrow.last_error) and escrow.last_error.startswith("create_rejected:")
            if confirmed_rejection:
                escrow = await self._create_external_escrow(deal, buyer_id, existing=escrow)
                # Falls through below with funding_initiated_at still None.
            else:
                stuck_for = (datetime.utcnow() - escrow.updated_at).total_seconds()
                if stuck_for < 20:
                    raise HTTPException(
                        status_code=409,
                        detail="Payment setup for this deal is already in progress — please wait a moment and try again",
                    )
                if escrow.status != EConfirmEscrowStatus.UNKNOWN:
                    escrow.status = EConfirmEscrowStatus.UNKNOWN
                    escrow.last_error = "create_transaction outcome unknown (no response/id) — needs manual reconciliation"
                    await self.external_escrows.save(escrow)
                    await record_audit(
                        self.db, "system", "econfirm_reconciliation_required", "deal", deal.id,
                        "create_transaction outcome unknown",
                    )
                    await self.db.commit()
                    await publish(EConfirmReconciliationRequired(
                        deal_id=deal.id, provider_transaction_id="", reason="create_transaction outcome unknown",
                    ))
                raise HTTPException(
                    status_code=409,
                    detail=(
                        "We couldn't confirm whether payment setup for this deal succeeded. "
                        "This needs a quick manual check before trying again — please contact support."
                    ),
                )

        if escrow.status in (
            EConfirmEscrowStatus.FUNDED, EConfirmEscrowStatus.RELEASE_PENDING,
            EConfirmEscrowStatus.COMPLETED, EConfirmEscrowStatus.PAYOUT_FAILED,
        ):
            # Already past funding — never re-fund, just report where
            # things stand.
            return await self._payment_status_dict(deal, escrow)

        if escrow.status in (EConfirmEscrowStatus.PENDING, EConfirmEscrowStatus.UNKNOWN) and escrow.funding_initiated_at is not None:
            # A fund attempt already happened at least once — successful
            # send, or an ambiguous timeout that might have gone through
            # anyway. The repeat call must never trigger another one;
            # reconcile (read-only) instead, so the response reflects
            # whatever actually happened rather than stale local state,
            # and so a payment that quietly completed during an earlier
            # ambiguous attempt is picked up here rather than only on the
            # next poll or worker sweep.
            if escrow.provider_transaction_id:
                refreshed = await self.reconcile_econfirm_escrow(deal.id)
                if refreshed is not None:
                    escrow = refreshed
            fresh_deal = await self.deals.get_by_id(deal.id)
            return await self._payment_status_dict(fresh_deal or deal, escrow)

        # Remaining case: PENDING with funding_initiated_at still None —
        # a legitimate first-ever attempt, whether this is a brand-new
        # escrow or one whose create_transaction succeeded on an earlier
        # request that then crashed/failed before ever reaching
        # fund_escrow() below.
        if not escrow.provider_transaction_id:
            raise HTTPException(status_code=502, detail="Escrow setup has not completed yet — please try again shortly")

        try:
            result = await get_escrow_provider().fund_escrow(escrow.provider_transaction_id, payer_phone)
        except EConfirmConnectionError as exc:
            # Ambiguous — we do NOT know if E-Confirm received this STK
            # request. funding_initiated_at is set regardless (this WAS
            # a real attempt), so any further /fund call reconciles
            # instead of retrying — see the PENDING+funding_initiated_at
            # branch above.
            escrow.payer_phone = payer_phone
            escrow.funding_initiated_at = datetime.utcnow()
            escrow.last_error = f"fund attempt: connection error ({type(exc).__name__})"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            await publish(EConfirmReconciliationRequired(
                deal_id=deal_id, provider_transaction_id=escrow.provider_transaction_id,
                reason="fund_stk_push timed out/network error",
            ))
            raise HTTPException(
                status_code=503,
                detail="We couldn't confirm the payment prompt was sent — checking status, please refresh in a few seconds",
            )
        except EConfirmAPIError as exc:
            # A clean, confirmed rejection (e.g. invalid phone number) —
            # the provider never actually queued an STK push, so
            # funding_initiated_at is deliberately left unset: a
            # corrected retry is legitimate, not a duplicate.
            logger.warning("[escrow] fund_stk_push rejected deal=%s status=%d", deal_id, exc.status_code)
            escrow.last_error = f"fund rejected: HTTP {exc.status_code}"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            raise HTTPException(
                status_code=422,
                detail="The payment provider rejected this request — please check the phone number and try again",
            )

        escrow.payer_phone = payer_phone
        escrow.funding_initiated_at = datetime.utcnow()
        escrow.provider_raw_status = result.raw_status
        if result.status != EConfirmEscrowStatus.UNKNOWN:
            escrow.status = result.status
        escrow.last_checked_at = datetime.utcnow()
        await self.external_escrows.save(escrow)
        await record_audit(
            self.db, buyer_id, "econfirm_funding_initiated", "deal", deal_id,
            f"provider_transaction_id={escrow.provider_transaction_id}",
            ip_address=request_ip,
        )
        await self.db.commit()

        await publish(EConfirmFundingInitiated(
            deal_id=deal_id, provider_transaction_id=escrow.provider_transaction_id, payer_phone=payer_phone,
        ))

        return await self._payment_status_dict(deal, escrow)

    async def _create_external_escrow(
        self, deal: Deal, buyer_id: str, existing: Optional[ExternalEscrow] = None,
    ) -> ExternalEscrow:
        """Phase 6. Two-phase write on purpose (see api/models/
        external_escrow.py + fund_deal_escrow's 'stuck creating' branch
        above): a row is persisted BEFORE calling out to E-Confirm, so a
        crash/restart between the call and the response leaves local
        evidence of the attempt rather than nothing at all."""
        r = await self.db.execute(select(User).where(User.id == deal.buyer_id))
        buyer = r.scalar_one_or_none()
        r = await self.db.execute(select(User).where(User.id == deal.seller_id))
        seller = r.scalar_one_or_none()
        if not buyer or not seller:
            raise HTTPException(status_code=404, detail="Buyer or seller account not found")
        if not buyer.email or not seller.email:
            # Phase 6 point 5: "Verify both required identities/contact
            # details exist." User.email is nullable in this schema
            # (phone is the required login identifier — see
            # api/database.py's User model), so this is a real, expected
            # case, not a defensive-only check.
            raise HTTPException(
                status_code=422,
                detail="Both buyer and seller need an email on file before this deal can be funded through escrow",
            )

        r = await self.db.execute(select(Listing).where(Listing.id == deal.listing_id))
        listing = r.scalar_one_or_none()
        description = f"BROKA deal {deal.id[:8]} - {listing.name if listing else 'marketplace item'}"[:200]

        if existing is not None:
            escrow = existing
        else:
            escrow = await self.external_escrows.create(
                deal_id=deal.id,
                provider="econfirm",
                status=EConfirmEscrowStatus.CREATING,
                amount=deal.agreed_price,
                currency="KES",
                buyer_email=buyer.email,
                seller_email=seller.email,
                receiver_phone=seller.phone,
            )
            await self.db.commit()  # persist the "we attempted this" marker before calling out (Phase 9)

        try:
            result = await get_escrow_provider().create_escrow(
                amount=deal.agreed_price,
                buyer_email=buyer.email,
                seller_email=seller.email,
                receiver_phone=seller.phone,
                description=description,
                commission_amount=deal.commission,
            )
        except EConfirmConnectionError as exc:
            escrow.last_error = f"create attempt: connection error ({type(exc).__name__})"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            raise HTTPException(
                status_code=503,
                detail="Could not reach the payment provider to set up escrow — please try again shortly",
            )
        except EConfirmAPIError as exc:
            logger.warning("[escrow] create_transaction rejected deal=%s status=%d", deal.id, exc.status_code)
            # "create_rejected:" prefix is deliberately parsed by
            # fund_deal_escrow's CREATING branch: a CONFIRMED rejection
            # (E-Confirm answered, and said no) means no provider-side
            # transaction exists, so an immediate retry is legitimate —
            # unlike the connection-error branch above, which is
            # ambiguous and must NOT be retried automatically.
            escrow.last_error = f"create_rejected:HTTP_{exc.status_code}"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            raise HTTPException(status_code=422, detail="The payment provider could not set up this escrow — please contact support")

        if not result.provider_transaction_id:
            escrow.last_error = "create_transaction returned no transaction id"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            raise HTTPException(status_code=502, detail="Escrow setup did not complete correctly — please try again")

        escrow.provider_transaction_id = result.provider_transaction_id
        escrow.provider_raw_status = result.raw_status
        escrow.status = result.status if result.status != EConfirmEscrowStatus.UNKNOWN else EConfirmEscrowStatus.PENDING
        escrow.provider_fee_amount = result.fee_amount
        escrow.merchant_commission_amount = deal.commission
        escrow.last_checked_at = datetime.utcnow()
        if result.confirmation_code:
            escrow.confirmation_code_encrypted = encrypt_secret(result.confirmation_code)
        else:
            # Not documented either way whether E-Confirm v2 always returns
            # this at creation — logged as a soft warning rather than a
            # hard failure so escrow creation (which the buyer is actively
            # waiting on) isn't blocked; release will fail with a clear,
            # specific error later if this is genuinely never obtained
            # (see _confirm_delivery_econfirm's confirmation_code check).
            logger.warning("[escrow] create_transaction for deal=%s returned no confirmation_code", deal.id)
            escrow.last_error = "no confirmation_code returned at creation"
        await self.external_escrows.save(escrow)

        await record_audit(
            self.db, buyer_id, "econfirm_escrow_created", "deal", deal.id,
            f"provider_transaction_id={escrow.provider_transaction_id} amount={deal.agreed_price} commission={deal.commission}",
        )
        await self.db.commit()

        await publish(EConfirmEscrowCreated(
            deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
            buyer_id=deal.buyer_id, seller_id=deal.seller_id, amount=deal.agreed_price,
        ))

        return escrow

    # ── E-Confirm: reconciliation (Phase 8 / Phase 19) ─────────────────────

    async def reconcile_econfirm_escrow(self, deal_id: str) -> Optional[ExternalEscrow]:
        """
        Poll E-Confirm for this deal's real state and apply whatever Deal
        transition results. Safe to call repeatedly and concurrently
        (from a payment-status poll AND the worker sweep at the same
        time): every state change goes through lock_deal_if_status, and
        "already at this state" is explicitly checked before doing
        anything (Phase 8: "If Deal is already paid: do not duplicate
        state transition").
        """
        escrow = await self.external_escrows.get_by_deal_id(deal_id)
        if escrow is None or not escrow.provider_transaction_id:
            return escrow  # nothing to check yet — still 'creating' with no id

        if escrow.status in EConfirmEscrowStatus.TERMINAL:
            return escrow

        try:
            result = await get_escrow_provider().get_status(escrow.provider_transaction_id)
        except EConfirmError as exc:
            logger.warning("[escrow] reconcile get_status failed deal=%s: %s", deal_id, exc)
            escrow.last_error = f"reconcile: {type(exc).__name__}"
            escrow.last_checked_at = datetime.utcnow()
            await self.external_escrows.save(escrow)
            await self.db.commit()
            return escrow

        escrow.provider_raw_status = result.raw_status
        escrow.last_checked_at = datetime.utcnow()
        previous_status = escrow.status

        if result.status == EConfirmEscrowStatus.UNKNOWN:
            logger.warning("[escrow] unrecognized provider status %r for deal=%s", result.raw_status, deal_id)
            await self.external_escrows.save(escrow)
            await self.db.commit()
            await publish(EConfirmReconciliationRequired(
                deal_id=deal_id, provider_transaction_id=escrow.provider_transaction_id,
                reason=f"unrecognized provider status: {result.raw_status}",
            ))
            return escrow

        escrow.status = result.status

        deal = await self.deals.get_by_id(deal_id)
        if deal is None:
            await self.external_escrows.save(escrow)
            await self.db.commit()
            return escrow

        if result.status == EConfirmEscrowStatus.FUNDED and previous_status != EConfirmEscrowStatus.FUNDED:
            await self.external_escrows.save(escrow)
            locked = await lock_deal_if_status(self.db, deal_id, (DealStatus.agreed,))
            if locked is not None:
                locked.status = DealStatus.paid
                escrow.funded_at = datetime.utcnow()
                await self.external_escrows.save(escrow)
                await record_audit(
                    self.db, "system", "econfirm_escrow_funded", "deal", deal_id,
                    f"provider_transaction_id={escrow.provider_transaction_id} amount={escrow.amount}",
                )
                await self.db.commit()
                await publish(EConfirmEscrowFunded(
                    deal_id=deal_id, provider_transaction_id=escrow.provider_transaction_id,
                    buyer_id=deal.buyer_id, seller_id=deal.seller_id, amount=deal.agreed_price,
                ))
                # Publishing the ORIGINAL EscrowFunded event too (exactly
                # once, same as this always did) is what makes
                # deal_hub_subscribers.py write the ledger entry and
                # broadcast over the deal's WebSocket room automatically —
                # see that file's on_escrow_funded. Recording the ledger
                # entry manually here as well would double it.
                await publish(EscrowFunded(
                    deal_id=deal_id, buyer_id=deal.buyer_id, seller_id=deal.seller_id,
                    amount=deal.agreed_price, mpesa_receipt=escrow.provider_transaction_id,
                ))
            else:
                await self.db.commit()  # Phase 8: someone else already moved it — not an error

        elif result.status == EConfirmEscrowStatus.PAYOUT_FAILED and previous_status != EConfirmEscrowStatus.PAYOUT_FAILED:
            escrow.last_error = "provider reported payout_failed"
            await self.external_escrows.save(escrow)
            await record_audit(
                self.db, "system", "econfirm_payout_failed", "deal", deal_id,
                f"provider_transaction_id={escrow.provider_transaction_id}",
            )
            await self.db.commit()
            await publish(EConfirmPayoutFailed(
                deal_id=deal_id, provider_transaction_id=escrow.provider_transaction_id,
                reason="provider reported payout_failed",
            ))
            # Deal deliberately stays 'paid' here — Phase 10: "keep the
            # Deal in paid unless provider explicitly says the funds left
            # escrow". No Deal.status change on this branch.

        elif result.status == EConfirmEscrowStatus.COMPLETED and previous_status != EConfirmEscrowStatus.COMPLETED:
            # Reached here (rather than inline inside
            # _confirm_delivery_econfirm) when a release returned
            # payout_initiated and completion is observed later by a
            # poll/sweep instead of the original release call's response.
            await self.external_escrows.save(escrow)
            locked = await lock_deal_if_status(self.db, deal_id, (DealStatus.paid,))
            if locked is not None:
                locked.status = DealStatus.released
                locked.released_at = datetime.utcnow()
                escrow.released_at = datetime.utcnow()
                await self.external_escrows.save(escrow)
                r = await self.db.execute(select(User).where(User.id == deal.seller_id))
                seller = r.scalar_one_or_none()
                if seller:
                    seller.completed_deals = (seller.completed_deals or 0) + 1
                    await compute_trust_score(seller.id, self.db)
                await record_audit(
                    self.db, "system", "econfirm_payout_completed", "deal", deal_id,
                    f"provider_transaction_id={escrow.provider_transaction_id} amount={deal.agreed_price}",
                )
                await self.db.commit()
                await publish(EConfirmPayoutCompleted(
                    deal_id=deal_id, provider_transaction_id=escrow.provider_transaction_id,
                    seller_id=deal.seller_id, amount=deal.agreed_price,
                ))
                await publish(EscrowReleased(
                    deal_id=deal_id, seller_id=deal.seller_id, buyer_id=deal.buyer_id, amount=deal.agreed_price,
                ))
            else:
                await self.db.commit()
        else:
            await self.external_escrows.save(escrow)
            await self.db.commit()

        return escrow

    async def get_payment_status(self, deal_id: str, user_id: str) -> dict:
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if user_id not in (deal.buyer_id, deal.seller_id):
            raise HTTPException(status_code=403, detail="Not your deal")

        escrow = await self.external_escrows.get_by_deal_id(deal_id)
        if escrow and escrow.provider_transaction_id and escrow.status not in EConfirmEscrowStatus.TERMINAL:
            # Phase 8: "Run reconciliation ... from a controlled backend
            # endpoint for immediate UI refresh" — this is that endpoint.
            escrow = await self.reconcile_econfirm_escrow(deal_id)
            deal = await self.deals.get_by_id(deal_id)  # re-fetch — reconcile may have changed it

        return await self._payment_status_dict(deal, escrow)

    async def _payment_status_dict(self, deal: Deal, escrow: Optional[ExternalEscrow]) -> dict:
        provider_fee = escrow.provider_fee_amount if escrow else None
        return {
            "deal_id": deal.id,
            "deal_status": deal.status.value,
            "escrow_status": escrow.provider_raw_status if escrow else None,
            "payment_status": self._flutter_payment_status(escrow),
            "goods_amount": deal.agreed_price,
            "merchant_commission": deal.commission,
            "provider_fee": provider_fee,
            "total_to_pay": (
                round(deal.agreed_price + deal.commission + provider_fee, 2)
                if provider_fee is not None else None
            ),
            "currency": escrow.currency if escrow else "KES",
            "funded_at": escrow.funded_at.isoformat() if escrow and escrow.funded_at else None,
            "released_at": escrow.released_at.isoformat() if escrow and escrow.released_at else None,
            "can_confirm_delivery": deal.status == DealStatus.paid,
        }

    @staticmethod
    def _flutter_payment_status(escrow: Optional[ExternalEscrow]) -> str:
        """One of: preparing_payment, stk_prompt_sent, secured_in_escrow,
        released, requires_attention.

        Phase 16 also lists "Waiting for M-Pesa confirmation" and "Payment
        timed out" as UI states, but Phase 19's provider-status list has no
        equivalent of "user cancelled/declined the STK prompt" — like
        Daraja, a declined/ignored prompt most likely just stays "pending"
        forever rather than transitioning anywhere. Those two are left as
        Flutter-side, elapsed-time-since-stk_prompt_sent states (same
        pattern flutter_app/lib/screens/mpesa_confirmation_screen.dart
        already used), rather than inventing a backend signal that isn't
        actually there.
        """
        if escrow is None or escrow.status == EConfirmEscrowStatus.CREATING:
            return "preparing_payment"
        if escrow.status == EConfirmEscrowStatus.PENDING:
            return "stk_prompt_sent"
        if escrow.status in (EConfirmEscrowStatus.FUNDED, EConfirmEscrowStatus.RELEASE_PENDING):
            return "secured_in_escrow"
        if escrow.status == EConfirmEscrowStatus.COMPLETED:
            return "released"
        return "requires_attention"  # PAYOUT_FAILED or UNKNOWN

    # ── Confirm delivery / release (Phase 10) ──────────────────────────────

    async def confirm_delivery(
        self,
        deal_id: str,
        buyer_id: str,
        request_ip: Optional[str] = None,
    ) -> dict:
        """Buyer confirms delivery. See module docstring for the
        E-Confirm-vs-legacy branch this makes."""
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != buyer_id:
            raise HTTPException(status_code=403, detail="Only the buyer can confirm delivery")

        escrow = await self.external_escrows.get_by_deal_id(deal_id)
        if escrow is None:
            return await self._confirm_delivery_legacy(deal, buyer_id, request_ip)
        return await self._confirm_delivery_econfirm(deal, escrow, buyer_id, request_ip)

    async def _confirm_delivery_legacy(self, deal: Deal, buyer_id: str, request_ip: Optional[str]) -> dict:
        """Original, unchanged behavior for deals with no E-Confirm
        escrow — see module docstring."""
        if deal.status != DealStatus.paid:
            raise HTTPException(status_code=400, detail=f"Cannot release — deal status is '{deal.status.value}'")

        deal.status = DealStatus.released
        deal.delivery_confirmed_at = datetime.utcnow()
        deal.released_at = datetime.utcnow()

        r = await self.db.execute(select(User).where(User.id == deal.seller_id))
        seller = r.scalar_one_or_none()
        if seller:
            seller.completed_deals = (seller.completed_deals or 0) + 1
            await compute_trust_score(seller.id, self.db)

        await record_audit(
            self.db, buyer_id, "delivery_confirmed", "deal", deal.id,
            f"seller_id={deal.seller_id} amount={deal.agreed_price}",
            ip_address=request_ip,
        )
        await self.db.commit()

        await publish(EscrowReleased(
            deal_id=deal.id, seller_id=deal.seller_id, buyer_id=buyer_id, amount=deal.agreed_price,
        ))

        return {"ok": True, "deal_id": deal.id, "status": "released"}

    async def _confirm_delivery_econfirm(
        self, deal: Deal, escrow: ExternalEscrow, buyer_id: str, request_ip: Optional[str],
    ) -> dict:
        """Phase 10's release flow. NEVER sets Deal.status=released on
        request receipt alone — only once E-Confirm's response says the
        payout is Completed (immediately here, or later via
        reconcile_econfirm_escrow if the response was payout_initiated).

        2026-09 restructure (finalization pass, Section 16): the external
        release call now happens OUTSIDE any held row lock — "avoid making
        external provider calls while holding long database transactions".
        The lock is only held for the short "re-verify FRESH state, mark
        intent, commit" step; duplicate-release protection then comes from
        escrow.status itself (RELEASE_PENDING/COMPLETED block a second
        attempt), re-checked fresh from the DB after the lock rather than
        trusting the `escrow` object passed into this method. That
        distinction mattered: two concurrent requests correctly serialize
        on the Postgres row lock, but the SECOND one used to re-check only
        deal.status, not escrow.status — and deal.status deliberately
        stays 'paid' when a release's immediate response is
        payout_initiated rather than Completed, so the second request
        could still slip through and call release_escrow() a second time
        for the same transaction. Caught by re-reading this against
        Section 10/20's explicit duplicate-release requirement, not
        caught by the original design or its tests.
        """
        if deal.status != DealStatus.paid:
            raise HTTPException(status_code=400, detail=f"Cannot release — deal status is '{deal.status.value}'")
        if escrow.status != EConfirmEscrowStatus.FUNDED or not escrow.provider_transaction_id:
            # Fast, cheap rejection using the passed-in (possibly slightly
            # stale) escrow — good enough for the overwhelmingly common
            # case of "not funded yet" and avoids acquiring a lock for a
            # request that's going to fail anyway. NOT the correctness
            # guarantee against a genuine race — that's the fresh re-check
            # below, after the lock.
            raise HTTPException(
                status_code=409,
                detail="This deal's escrow isn't in a confirmed-funded state yet — please refresh and try again shortly",
            )

        locked = await lock_deal_if_status(self.db, deal.id, (DealStatus.paid,))
        if locked is None:
            fresh_escrow = await self.external_escrows.get_by_deal_id(deal.id)
            fresh_deal = await self.deals.get_by_id(deal.id)
            return await self._payment_status_dict(fresh_deal, fresh_escrow)

        # Authoritative re-check: fresh from the DB, not the `escrow`
        # parameter, and while still holding the lock — this is what
        # actually prevents the double-release described above.
        escrow = await self.external_escrows.get_by_deal_id(deal.id)
        if escrow is None or escrow.status != EConfirmEscrowStatus.FUNDED or not escrow.provider_transaction_id:
            await self.db.commit()
            fresh_deal = await self.deals.get_by_id(deal.id)
            return await self._payment_status_dict(fresh_deal, escrow)
        if not escrow.confirmation_code_encrypted:
            logger.error("[escrow] deal=%s is funded but has no confirmation_code stored", deal.id)
            await self.db.commit()
            raise HTTPException(
                status_code=500,
                detail="This deal is missing its release credential — please contact support rather than retrying",
            )

        try:
            confirmation_code = decrypt_secret(escrow.confirmation_code_encrypted)
        except SecretCryptoError as exc:
            logger.error("[escrow] could not decrypt confirmation_code for deal=%s: %s", deal.id, exc)
            await self.db.commit()
            raise HTTPException(status_code=500, detail="Could not read this deal's release credential — please contact support")

        # Persist intent and commit — releases the row lock here, BEFORE
        # the network call. A second request (whether it was queued on
        # the lock or arrives after) now sees RELEASE_PENDING, not FUNDED.
        escrow.status = EConfirmEscrowStatus.RELEASE_PENDING
        escrow.release_initiated_at = datetime.utcnow()
        await self.external_escrows.save(escrow)
        await record_audit(
            self.db, buyer_id, "econfirm_release_requested", "deal", deal.id,
            f"provider_transaction_id={escrow.provider_transaction_id}",
            ip_address=request_ip,
        )
        await self.db.commit()
        await publish(EConfirmReleaseInitiated(
            deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id, seller_id=deal.seller_id,
        ))

        try:
            try:
                result = await get_escrow_provider().release_escrow(
                    escrow.provider_transaction_id, confirmation_code, notes="Buyer confirmed delivery via BROKA",
                )
            finally:
                confirmation_code = None  # drop the only in-memory reference as soon as the call returns
        except EConfirmAPIError as exc:
            if exc.status_code == 409:
                # Phase 20: "Handle HTTP 409 release-in-progress as a
                # reconciliation case, not as a new payout." escrow.status
                # is already RELEASE_PENDING from above — nothing further
                # to change; a later reconciliation pass resolves it.
                await publish(EConfirmReconciliationRequired(
                    deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
                    reason="release returned 409 (already in progress)",
                ))
                return {
                    "ok": True, "deal_id": deal.id, "status": "release_pending",
                    "detail": "A release for this deal is already being processed — it will show as released once confirmed.",
                }
            logger.warning("[escrow] release rejected deal=%s status=%d", deal.id, exc.status_code)
            escrow.last_error = f"release rejected: HTTP {exc.status_code}"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            raise HTTPException(status_code=422, detail="The payment provider rejected the release request — please contact support")
        except EConfirmConnectionError as exc:
            # Ambiguous per Phase 9/11 — do not assume the release failed
            # OR succeeded. escrow.status is already RELEASE_PENDING,
            # which doubles as the "reconciliation_required" state Section
            # 11 of the finalization spec calls for; reconciliation
            # resolves it rather than this request guessing.
            escrow.last_error = f"release attempt: connection error ({type(exc).__name__})"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            await publish(EConfirmReconciliationRequired(
                deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
                reason="release call timed out/network error",
            ))
            raise HTTPException(
                status_code=503,
                detail="We couldn't confirm the release went through — checking status now, please refresh in a few seconds",
            )
        except EConfirmError as exc:
            logger.error("[escrow] release error deal=%s: %s", deal.id, exc)
            escrow.last_error = f"release error: {type(exc).__name__}"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            raise HTTPException(status_code=502, detail="Could not process the release right now — please try again")

        escrow.provider_raw_status = result.raw_status

        if result.status == EConfirmEscrowStatus.COMPLETED:
            # Second short critical section for the final state
            # transition — again not held across any further network call.
            locked2 = await lock_deal_if_status(self.db, deal.id, (DealStatus.paid,))
            escrow.status = EConfirmEscrowStatus.COMPLETED
            escrow.released_at = datetime.utcnow()
            if locked2 is not None:
                locked2.status = DealStatus.released
                locked2.delivery_confirmed_at = datetime.utcnow()
                locked2.released_at = datetime.utcnow()
                r = await self.db.execute(select(User).where(User.id == deal.seller_id))
                seller = r.scalar_one_or_none()
                if seller:
                    seller.completed_deals = (seller.completed_deals or 0) + 1
                    await compute_trust_score(seller.id, self.db)
                await self.external_escrows.save(escrow)
                await record_audit(
                    self.db, "system", "econfirm_payout_completed", "deal", deal.id,
                    f"provider_transaction_id={escrow.provider_transaction_id}",
                )
                await self.db.commit()
                await publish(EConfirmPayoutCompleted(
                    deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
                    seller_id=deal.seller_id, amount=deal.agreed_price,
                ))
                await publish(EscrowReleased(
                    deal_id=deal.id, seller_id=deal.seller_id, buyer_id=buyer_id, amount=deal.agreed_price,
                ))
            else:
                # deal.status already moved on by something else by the
                # time we re-locked (shouldn't normally happen on this
                # path) — still persist the now-Completed escrow state.
                await self.external_escrows.save(escrow)
                await self.db.commit()
            return {"ok": True, "deal_id": deal.id, "status": "released"}

        if result.status == EConfirmEscrowStatus.PAYOUT_FAILED:
            escrow.status = EConfirmEscrowStatus.PAYOUT_FAILED
            escrow.last_error = "release returned payout_failed"
            await self.external_escrows.save(escrow)
            await record_audit(
                self.db, "system", "econfirm_payout_failed", "deal", deal.id,
                f"provider_transaction_id={escrow.provider_transaction_id}",
            )
            await self.db.commit()
            await publish(EConfirmPayoutFailed(
                deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
                reason="release returned payout_failed",
            ))
            # Phase 10: "keep the Deal in paid unless provider explicitly
            # says the funds left escrow" — Deal.status is untouched here.
            raise HTTPException(
                status_code=502,
                detail="The payout could not be completed right now. Your delivery confirmation was recorded and the deal remains protected — please try again shortly or contact support.",
            )

        # payout_initiated, or an unrecognized status (Phase 19: never
        # guess) — escrow.status is already RELEASE_PENDING from the
        # intent marker above; reconcile_econfirm_escrow finishes the
        # release once E-Confirm reports Completed.
        await self.external_escrows.save(escrow)
        await self.db.commit()
        if result.status == EConfirmEscrowStatus.UNKNOWN:
            await publish(EConfirmReconciliationRequired(
                deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
                reason=f"unexpected release response status: {result.raw_status}",
            ))
        return {
            "ok": True, "deal_id": deal.id, "status": "release_pending",
            "detail": "Delivery confirmed — payout is being finalized, please check back shortly.",
        }

    # ── Read-only ───────────────────────────────────────────────────────

    async def get_deal(self, deal_id: str, user_id: str) -> dict:
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != user_id and deal.seller_id != user_id:
            raise HTTPException(status_code=403, detail="Not your deal")
        return self._deal_dict(deal)

    async def get_my_deals(self, user_id: str) -> list[dict]:
        r = await self.db.execute(
            select(Deal).where(
                (Deal.buyer_id == user_id) | (Deal.seller_id == user_id)
            ).order_by(Deal.created_at.desc())
        )
        return [self._deal_dict(d) for d in r.scalars().all()]

    @staticmethod
    def _deal_dict(deal: Deal) -> dict:
        return {
            "id": deal.id,
            "listing_id": deal.listing_id,
            "seller_id": deal.seller_id,
            "buyer_id": deal.buyer_id,
            "agreed_price": deal.agreed_price,
            "commission": deal.commission,
            "status": deal.status.value,
            "delivery_confirmed_at": deal.delivery_confirmed_at.isoformat() if deal.delivery_confirmed_at else None,
            "released_at": deal.released_at.isoformat() if deal.released_at else None,
            "refunded_at": deal.refunded_at.isoformat() if deal.refunded_at else None,
            "created_at": deal.created_at.isoformat() if deal.created_at else None,
        }


# ── Fund-safety: race-condition guard for release/refund actions ───────────
#
# Module-level, not a method, so every code path that can move money for a
# deal can import this one function - routers/negotiate.py's several
# manual buyer/seller intents and core/workers.py's automated timeout
# sweep are the two currently known to race against each other (both can
# become eligible to refund or release the SAME deal, e.g. a deal sitting
# at awaiting_resolution with an overdue timer is a valid target for both
# the sweep's due_deals query AND negotiate.py's buyer_chooses_refund
# intent). Before this, both paths did a plain SELECT with no lock and no
# re-check, so both could read the deal as still-eligible before either
# committed, and both fire a real M-Pesa B2C payout for the same deal.
#
# EscrowService's own E-Confirm release flow (_confirm_delivery_econfirm)
# and reconcile_econfirm_escrow's Deal transitions use this same guard now
# too, for the same reason.
async def lock_deal_if_status(
    db: AsyncSession, deal_id: str, expected_statuses: tuple,
) -> Optional[Deal]:
    """
    Row-locks the deal (SELECT ... FOR UPDATE) and returns it ONLY if its
    status is still one of expected_statuses at the moment the lock is
    acquired - None if some other transaction already moved it past that
    status. Callers MUST treat None as "already handled elsewhere, do
    nothing" rather than proceeding.

    On Postgres this is a real row lock: a concurrent transaction trying
    to lock the same row blocks until this one commits or rolls back, then
    sees the updated status and correctly gets None. On SQLite (this app's
    local/dev default - see .env.example), SQLAlchemy silently drops the
    FOR UPDATE clause since SQLite has no row-level locking - this
    function still re-checks status either way, so it's correct everywhere,
    just not lock-protected against true concurrent access in dev/test.
    That asymmetry is acceptable: SQLite is never this app's production
    database (validate_startup() in core/config.py refuses to start in
    production with one), so the dialect that matters for real concurrent
    traffic is the one where the lock actually holds.
    """
    result = await db.execute(
        select(Deal).where(Deal.id == deal_id).with_for_update()
    )
    deal = result.scalar_one_or_none()
    if deal is None or deal.status not in expected_statuses:
        return None
    return deal
