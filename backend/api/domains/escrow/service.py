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
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, update

from api.database import (
    Deal, DealStatus, Listing, ListingStatus, ListingType, User, MpesaTransaction, MpesaStatus,
)
from api.core.events import (
    publish, DealFinalized, EscrowFunded, EscrowReleased,
    EConfirmEscrowCreated, EConfirmFundingInitiated, EConfirmEscrowFunded,
    EConfirmReleaseInitiated, EConfirmPayoutCompleted, EConfirmPayoutFailed,
    EConfirmReconciliationRequired,
)
from api.core.audit import record_audit
from api.core.reconciliation import report_reconciliation
from api.core.fraud import flag_fraud, compute_trust_score
from api.core.config import settings
from api.core.money import add_money, money, pct_of, to_decimal
from api.core.econfirm_client import EConfirmError, EConfirmConnectionError, EConfirmAPIError
from api.core.secrets_crypto import encrypt_secret, decrypt_secret, SecretCryptoError
from api.models.external_escrow import ExternalEscrow, EConfirmEscrowStatus
from .repository import DealRepository, MpesaRepository, ExternalEscrowRepository
from api.domains.listings.stock import is_stocked, status_for, units_taken, units_total
from .providers import get_escrow_provider
from . import policy

logger = logging.getLogger(__name__)

# Deal statuses that can only be reached AFTER the buyer's money was held.
# A FUNDED report for a deal in one of these is a duplicate of a transition
# already applied; for any other status it is money with no live deal.
_FUNDED_OR_LATER = frozenset({
    DealStatus.paid,
    DealStatus.released,
    DealStatus.refunded,
    DealStatus.disputed,
    DealStatus.awaiting_condition_check,
    DealStatus.awaiting_resolution,
    DealStatus.awaiting_replacement,
    DealStatus.goods_not_arrived,
})


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


def _commission(price: float, listing_type=None) -> float:
    # Decimal-quantized rather than round(price * rate, 2): the float
    # multiply can land a hair either side of a .005 boundary before
    # round() ever sees it, and this number is a real obligation on a real
    # person. See api/core/money.py for why the columns stay Float.
    #
    # An auction sale carries its own rate (5% all-in rather than 4.49%),
    # keyed on the listing rather than on who calls finalize_deal - the
    # auction close and a buyer tapping "finalize" on an auction listing
    # are the same sale and must cost the same.
    #
    # Never under settings.commission_minimum_kes: on a KES 300 item 3.49%
    # is KES 10.47, less than the deal costs BROKA to carry.
    rate = (settings.auction_commission_rate if listing_type == ListingType.auction
            else settings.commission_rate)
    return max(money(settings.commission_minimum_kes), pct_of(price, rate))


# ── Partial payments ───────────────────────────────────────────────────────
#
# A buyer does not have to pay the whole price at once: they pay what they
# choose (never more than the balance), the seller sees what is secured, and
# the buyer adds to it until the balance is cleared. Nobody waits for the
# other party's confirmation before paying - a buyer turned away at the pay
# button may not come back. Each payment is its own E-Confirm transaction
# (ExternalEscrow row, payment_no 0, 1, 2...), so release and refund act on
# every payment the deal holds.

# The deal statuses a top-up may be added in. Only `paid`: in a dispute or
# one of its sub-states the money is frozen while it is sorted out.
_TOP_UP_STATUSES = (DealStatus.paid,)

# Deal statuses in which money arriving for a top-up still has a live deal
# to belong to. Released and refunded deals are over: money arriving for one
# of those is reported, not quietly absorbed.
_LIVE_FUNDED = _FUNDED_OR_LATER - {DealStatus.released, DealStatus.refunded}


def amount_paid(payments) -> float:
    """What the buyer has actually paid into escrow, across every payment."""
    amounts = [p.amount for p in payments if p.status in EConfirmEscrowStatus.MONEY_IN]
    return add_money(*amounts) if amounts else 0.0


def balance_due(deal: Deal, payments) -> float:
    """What is left to pay on the deal's price; never negative."""
    left = money(to_decimal(deal.agreed_price) - to_decimal(amount_paid(payments)))
    return max(left, 0.0)


def validate_payment_amount(amount, balance: float, *, part_payments_allowed: bool) -> float:
    """The goods amount for the next payment: `amount`, or the balance when
    none is given.

    Never more than the balance: the buyer can only overpay by mistake, and
    a part of a payment cannot be refunded on its own through E-Confirm. If
    the price really is higher than the deal says, the seller states it
    (POST /deal/{id}/price, protection.set_price) and the balance grows.
    """
    if amount is None:
        return balance
    try:
        a = float(amount)
    except (TypeError, ValueError):
        raise HTTPException(status_code=422, detail="Payment amount is not a valid number")
    if a != a or a in (float("inf"), float("-inf")) or a <= 0:
        raise HTTPException(status_code=422, detail="Payment amount must be greater than zero")
    a = money(a)
    if a > balance:
        raise HTTPException(
            status_code=422,
            detail=f"That is more than the balance on this deal (KES {balance:,.2f})",
        )
    if a < balance:
        if not part_payments_allowed:
            raise HTTPException(
                status_code=422,
                detail=f"This deal is paid in full in one payment (KES {balance:,.2f})",
            )
        if a < policy.MIN_PART_PAYMENT_KES:
            raise HTTPException(
                status_code=422,
                detail=(f"A part payment must be at least KES {policy.MIN_PART_PAYMENT_KES:,.0f}, "
                        f"or the whole balance (KES {balance:,.2f})"),
            )
    return a


def payment_commission(deal: Deal, payments, amount: float, balance: float) -> float:
    """BROKA's commission carried by a payment of `amount`.

    Proportional to the payment, and the payment that clears the balance
    carries whatever the earlier ones did not - so a deal paid in parts
    costs the buyer the same commission as one paid at once (including the
    minimum, which a proportional split alone would spread thin).
    """
    if amount >= balance:
        carried = [p.merchant_commission_amount or 0.0 for p in payments
                   if p.status in EConfirmEscrowStatus.MONEY_IN]
        rest = money(to_decimal(deal.commission) - to_decimal(add_money(*carried) if carried else 0))
        return max(rest, 0.0)
    return money(to_decimal(deal.commission) * to_decimal(amount) / to_decimal(deal.agreed_price))


def payment_rows(payments) -> list[dict]:
    """The deal's payments as the app shows them."""
    return [
        {
            "payment_no": p.payment_no,
            "amount": p.amount,
            "status": EscrowService._flutter_payment_status(p),
            "funded_at": p.funded_at.isoformat() if p.funded_at else None,
        }
        for p in payments
    ]


def protection_fields(deal: Deal, payments, category: Optional[str] = None) -> dict:
    """Partial-payment totals and the buyer-protection clocks, for any
    response describing a deal."""
    auto_at = policy.auto_release_at(deal)
    respond_by = policy.refund_respond_by(deal)
    paid = amount_paid(payments)
    return {
        "amount_paid": paid,
        "balance": balance_due(deal, payments),
        "payments": payment_rows(payments),
        "seller_claimed_delivery_at": (
            deal.seller_claimed_delivery_at.isoformat() if deal.seller_claimed_delivery_at else None),
        "auto_release_at": auto_at.isoformat() if auto_at else None,
        "requires_ownership_transfer": policy.requires_ownership_transfer(category),
        "refund_request": (
            {
                "requested_at": deal.refund_requested_at.isoformat(),
                "reason": deal.refund_reason,
                "outcome": deal.refund_outcome,
                "resolved_at": deal.refund_resolved_at.isoformat() if deal.refund_resolved_at else None,
                "respond_by": respond_by.isoformat() if respond_by else None,
            }
            if deal.refund_requested_at else None
        ),
    }


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
        deal_id: Optional[str] = None,
        quantity: Optional[int] = None,
    ) -> dict:
        """
        quantity is how many of the listing's units the deal is for (None:
        one). A direct listing's units are checked and taken here, under the
        listing's row lock, so two buyers agreeing to the last bag at once
        cannot both get it (api/domains/listings/stock.py). Auctions sell
        one item through their own lifecycle and are not counted.

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
        stocked = is_stocked(listing)
        # Read again under the listing's row lock (PostgreSQL; SQLite
        # serialises writers anyway), so two finalizes on one listing run
        # one after the other. For a direct sale, the units left are counted
        # and then taken. For an auction, the close and a retry of its
        # winner's deal can both reach here at once (auctions/lifecycle.py);
        # without the lock neither saw the other's uncommitted deal and the
        # winner got two. The second now waits, then finds and returns the
        # first's deal below.
        listing = (await self.db.execute(
            select(Listing).where(Listing.id == listing_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )).scalar_one()

        if current_user_id == listing.seller_id:
            seller_id = listing.seller_id
        elif current_user_id == buyer_id:
            seller_id = listing.seller_id
        else:
            raise HTTPException(
                status_code=403,
                detail="Only the listing's seller, or the buyer accepting it, can finalize this deal",
            )

        # Duplicate protection, scoped to the transaction that is actually
        # running. The check used to be "any deal for this (listing, buyer)
        # that is not cancelled", which treated a RELEASED deal - one that
        # completed and paid out months ago - as a reason to refuse a new
        # one. A buyer who buys from the same seller twice, or wins the
        # seller's relisted item at auction, would have been handed the old
        # finished deal's id and told it already existed; for an auction
        # that means the winner is pointed at a deal they have already paid
        # and the win they just made has nothing to pay against.
        #
        # An ACTIVE deal is still reused, which is what makes two
        # simultaneous finalize attempts - or two workers racing to create
        # the winner's deal after a close - converge on one deal instead of
        # two. See TERMINAL_DEAL_STATUSES for where the line sits.
        existing = await self.deals.get_active_by_listing_buyer(listing_id, buyer_id)
        if existing:
            return {"deal_id": existing.id, "status": existing.status.value, "existed": True}

        # Units. Checked after the join above on purpose: a buyer finishing
        # their own live deal is not refused because it took the last unit.
        units = 1
        taken = sold = 0
        if stocked:
            if getattr(listing.status, "value", listing.status) == ListingStatus.cancelled.value:
                raise HTTPException(status_code=409, detail="This listing has been removed by the seller.")
            units = quantity or 1
            taken, sold = await units_taken(self.db, listing_id)
            left = max(units_total(listing) - taken, 0)
            if left <= 0:
                raise HTTPException(status_code=409, detail="This listing is sold out.")
            if units > left:
                raise HTTPException(
                    status_code=409,
                    detail=f"Only {left} left - this deal can be for {left} at most.")

        commission = _commission(agreed_price, listing.listing_type)
        deal = await self.deals.create(
            listing_id=listing_id,
            seller_id=seller_id,
            buyer_id=buyer_id,
            agreed_price=agreed_price,
            commission=commission,
            status=DealStatus.agreed,
            quantity=units,
            # deal_id is normally None and the model generates one. The
            # auction close passes an id it has already CLAIMED on the
            # auction row, so that the claim and the deal it refers to
            # cannot disagree - see domains/auctions/lifecycle.py's
            # _retry_winner_deal. Nothing else supplies it.
            **({"id": deal_id} if deal_id else {}),
        )

        # A direct listing stays in front of buyers while it has units left,
        # and goes when this deal takes the last of them. It used to go on
        # the first agreement, whatever the quantity (listings/stock.py).
        # An auction's one item is in this deal.
        if stocked:
            listing.status = status_for(listing, taken + units, sold) or listing.status
        else:
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
            # Summed through Decimal - this was the one total in the
            # payment path that was not rounded at all, so it could surface
            # as 20600.000000000004 in an API response and in whatever the
            # client rendered from it.
            "amount_to_pay": add_money(agreed_price, commission),
            "status": deal.status.value,
        }

    # ── E-Confirm: fee quote (Phase 5 / Phase 14) ──────────────────────────

    async def get_fee_quote(self, deal_id: str, user_id: str, amount: Optional[float] = None) -> dict:
        """The buyer's total for the next payment: `amount` of goods money
        (the whole balance when not given) plus its share of the commission
        and E-Confirm's fee."""
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if user_id not in (deal.buyer_id, deal.seller_id):
            raise HTTPException(status_code=403, detail="Not your deal")
        payments = await self.external_escrows.list_for_deal(deal_id)
        if deal.status != DealStatus.agreed and not (deal.status in _TOP_UP_STATUSES and payments):
            raise HTTPException(
                status_code=400,
                detail=f"Fee quote is only available while a deal is 'agreed' (current: '{deal.status.value}')",
            )
        balance = balance_due(deal, payments)
        if balance <= 0:
            raise HTTPException(status_code=400, detail="This deal is already paid in full")
        listing_type = (await self.db.execute(
            select(Listing.listing_type).where(Listing.id == deal.listing_id)
        )).scalar_one_or_none()
        goods = validate_payment_amount(
            amount, balance, part_payments_allowed=listing_type != ListingType.auction)
        commission = payment_commission(deal, payments, goods, balance)

        try:
            quote = await get_escrow_provider().get_fee_quote(goods)
        except EConfirmConnectionError as exc:
            logger.warning("[escrow] fee quote connection error deal=%s: %s", deal_id, exc)
            raise HTTPException(status_code=503, detail="Payment provider is temporarily unavailable — please try again shortly")
        except EConfirmAPIError as exc:
            logger.warning("[escrow] fee quote rejected deal=%s status=%d", deal_id, exc.status_code)
            raise HTTPException(status_code=502, detail="Could not get a payment quote right now")
        except EConfirmError as exc:
            logger.error("[escrow] fee quote error deal=%s: %s", deal_id, exc)
            raise HTTPException(status_code=502, detail="Could not get a payment quote right now")

        provider_fee = money(quote.fee_amount)
        total = add_money(goods, commission, provider_fee)
        return {
            "deal_id": deal_id,
            "goods_amount": goods,
            "merchant_commission": commission,
            "provider_fee": provider_fee,
            "total_to_pay": total,
            "currency": quote.currency,
            "agreed_price": deal.agreed_price,
            "amount_paid": amount_paid(payments),
            "balance": balance,
            "min_part_payment": (policy.MIN_PART_PAYMENT_KES
                                 if listing_type != ListingType.auction else balance),
        }

    # ── E-Confirm: create + fund (Phase 6 / Phase 7) ───────────────────────

    async def fund_deal_escrow(
        self, deal_id: str, buyer_id: str, payer_phone: str, request_ip: Optional[str] = None,
        amount: Optional[float] = None,
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

        Partial payments: `amount` is the goods money for this payment (the
        whole balance when not given). A request while the deal's latest
        payment is still open - being set up, or its prompt on the buyer's
        phone - continues THAT payment, whatever amount it names; only once
        it has settled does a request open the next one (a top-up), and
        only on a deal that is `paid` and still has a balance.
        """
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != buyer_id:
            raise HTTPException(status_code=403, detail="Only the buyer can fund this deal")

        payments = await self.external_escrows.list_for_deal(deal_id)
        escrow = payments[-1] if payments else None
        continuing = escrow is not None and escrow.status in EConfirmEscrowStatus.OPEN
        # The first payment turns an agreed deal into a paid one; every later
        # payment adds to a paid one.
        first_payment = escrow is None or (continuing and escrow.payment_no == 0)
        payable = (DealStatus.agreed,) if first_payment else _TOP_UP_STATUSES

        if deal.status not in payable:
            if escrow is not None:
                return await self._payment_status_dict(deal)
            raise HTTPException(status_code=400, detail=f"Cannot fund — deal status is '{deal.status.value}'")

        if not continuing:
            if policy.refund_request_open(deal):
                raise HTTPException(
                    status_code=409,
                    detail="You have asked for a refund on this deal - withdraw the request before paying more",
                )
            balance = balance_due(deal, payments)
            if balance <= 0:
                # Paid in full - a retried Pay tap, not a new payment.
                return await self._payment_status_dict(deal)
            listing_type = (await self.db.execute(
                select(Listing.listing_type).where(Listing.id == deal.listing_id)
            )).scalar_one_or_none()
            # An auction is paid in one payment: its payment-lapse rules
            # (domains/auctions/lifecycle.py) read "paid" as the winning bid
            # secured, and a token part payment would hold the item.
            goods = validate_payment_amount(
                amount, balance, part_payments_allowed=listing_type != ListingType.auction)
            escrow = await self._create_external_escrow(
                deal, buyer_id,
                amount=goods,
                commission=payment_commission(deal, payments, goods, balance),
                payment_no=(escrow.payment_no + 1) if escrow is not None else 0,
            )
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
                    report_reconciliation(
                        "econfirm_create_outcome_unknown", deal_id=deal.id,
                        reason="E-Confirm create_transaction outcome unknown (no response/id) - "
                               "check E-Confirm for a transaction before anyone retries",
                    )
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
            return await self._payment_status_dict(deal)

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
            return await self._payment_status_dict(fresh_deal or deal)

        # Remaining case: PENDING with funding_initiated_at still None —
        # a legitimate first-ever attempt, whether this is a brand-new
        # escrow or one whose create_transaction succeeded on an earlier
        # request that then crashed/failed before ever reaching
        # fund_escrow() below.
        if not escrow.provider_transaction_id:
            raise HTTPException(status_code=502, detail="Escrow setup has not completed yet — please try again shortly")

        # CLAIM the attempt before sending anything. Two things race for
        # this escrow, and both used to read-then-act:
        #
        #   * a second /fund call (a double tap, a retry with a fresh
        #     Idempotency-Key) that also saw funding_initiated_at empty and
        #     would send a second STK prompt;
        #   * an auction payment-lapse cancelling the deal while this STK
        #     prompt is on the buyer's phone.
        #
        # The claim takes the deal row lock - the same lock the lapse takes -
        # re-checks the deal is still payable, and sets funding_initiated_at
        # with a compare-and-swap, all before the provider is called. Exactly
        # one caller can win it, and a lapse that runs after it sees the
        # attempt in flight.
        claimed = await self._claim_funding_attempt(deal.id, escrow, payer_phone, payable)
        if not claimed:
            fresh_deal = await self.deals.get_by_id(deal.id)
            await self.db.refresh(escrow)
            return await self._payment_status_dict(fresh_deal or deal)

        try:
            result = await get_escrow_provider().fund_escrow(escrow.provider_transaction_id, payer_phone)
        except EConfirmAPIError as exc:
            # A clean, confirmed rejection (e.g. invalid phone number) —
            # the provider never actually queued an STK push, so the claim
            # is RELEASED: a corrected retry is legitimate, not a duplicate.
            logger.warning("[escrow] fund_stk_push rejected deal=%s status=%d", deal_id, exc.status_code)
            escrow.funding_initiated_at = None
            escrow.last_error = f"fund rejected: HTTP {exc.status_code}"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            raise HTTPException(
                status_code=422,
                detail="The payment provider rejected this request — please check the phone number and try again",
            )
        except Exception as exc:
            # Ambiguous — we do NOT know if E-Confirm received this STK
            # request (a timeout, a 5xx, an unreadable response). The claim
            # stands (this WAS a real attempt), so any further /fund call
            # reconciles instead of retrying — see the
            # PENDING+funding_initiated_at branch above.
            escrow.last_error = f"fund attempt: connection error ({type(exc).__name__})"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            report_reconciliation(
                "econfirm_fund_outcome_unknown", deal_id=deal_id, level="warning",
                provider_transaction_id=escrow.provider_transaction_id,
                reason=f"STK push outcome unknown ({type(exc).__name__}); reconciliation will "
                       f"poll E-Confirm - act only if this deal stays pending",
            )
            await publish(EConfirmReconciliationRequired(
                deal_id=deal_id, provider_transaction_id=escrow.provider_transaction_id,
                reason="fund_stk_push timed out/network error",
            ))
            raise HTTPException(
                status_code=503,
                detail="We couldn't confirm the payment prompt was sent — checking status, please refresh in a few seconds",
            )

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

        return await self._payment_status_dict(deal)

    async def _claim_funding_attempt(
        self, deal_id: str, escrow: ExternalEscrow, payer_phone: str,
        payable: tuple = (DealStatus.agreed,),
    ) -> bool:
        """Atomically mark a funding attempt as started. True if this caller won.

        Under the deal row lock (see lock_deal_if_status) so it serialises
        with an auction payment-lapse, which takes the same lock; the UPDATE
        itself is a compare-and-swap on funding_initiated_at IS NULL, so it
        also holds on SQLite, where FOR UPDATE is a no-op. Committed before
        returning, so no lock is held while the provider is called.

        `payable` is the deal status the payment needs: `agreed` for the
        first, `paid` for a top-up - which a refund or release that took the
        deal past `paid` meanwhile must stop.
        """
        locked = await lock_deal_if_status(self.db, deal_id, payable)
        if locked is None:
            # Cancelled, lapsed or already paid since this request started.
            await self.db.commit()
            return False
        now = datetime.utcnow()
        claim = await self.db.execute(
            update(ExternalEscrow)
            .where(
                ExternalEscrow.id == escrow.id,
                ExternalEscrow.funding_initiated_at.is_(None),
            )
            .values(funding_initiated_at=now, payer_phone=payer_phone, updated_at=now)
        )
        await self.db.commit()
        # The Core UPDATE bypassed the ORM, and sessions keep their objects
        # across commits (expire_on_commit=False) - resync so later ORM
        # writes to this escrow start from what the row really holds.
        await self.db.refresh(escrow)
        return claim.rowcount > 0

    async def _create_external_escrow(
        self, deal: Deal, buyer_id: str, existing: Optional[ExternalEscrow] = None,
        *, amount: Optional[float] = None, commission: Optional[float] = None,
        payment_no: int = 0,
    ) -> ExternalEscrow:
        """Phase 6. Two-phase write on purpose (see api/models/
        external_escrow.py + fund_deal_escrow's 'stuck creating' branch
        above): a row is persisted BEFORE calling out to E-Confirm, so a
        crash/restart between the call and the response leaves local
        evidence of the attempt rather than nothing at all.

        One call creates one PAYMENT: `amount` of goods money carrying
        `commission` (the whole price and commission when not given), as
        payment number `payment_no`. Retrying a rejected create (`existing`)
        keeps that row's amount and commission."""
        if existing is not None:
            amount = existing.amount
            commission = (existing.merchant_commission_amount
                          if existing.merchant_commission_amount is not None else deal.commission)
            payment_no = existing.payment_no
        else:
            amount = deal.agreed_price if amount is None else amount
            commission = deal.commission if commission is None else commission
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
        description = f"BROKA deal {deal.id[:8]} - {listing.name if listing else 'marketplace item'}"
        if payment_no:
            description += f" (payment {payment_no + 1})"
        description = description[:200]

        if existing is not None:
            escrow = existing
        else:
            try:
                escrow = await self.external_escrows.create(
                    deal_id=deal.id,
                    payment_no=payment_no,
                    provider="econfirm",
                    status=EConfirmEscrowStatus.CREATING,
                    amount=amount,
                    merchant_commission_amount=commission,
                    currency="KES",
                    buyer_email=buyer.email,
                    seller_email=seller.email,
                    receiver_phone=seller.phone,
                )
                await self.db.commit()  # persist the "we attempted this" marker before calling out (Phase 9)
            except IntegrityError:
                # Another request opened this same payment a moment ago (a
                # double tap): (deal_id, payment_no) is unique, so one of
                # them is turned away rather than two transactions created.
                await self.db.rollback()
                raise HTTPException(
                    status_code=409,
                    detail="Payment setup for this deal is already in progress — please wait a moment and try again",
                )

        try:
            result = await get_escrow_provider().create_escrow(
                amount=amount,
                buyer_email=buyer.email,
                seller_email=seller.email,
                receiver_phone=seller.phone,
                description=description,
                commission_amount=commission,
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
        escrow.merchant_commission_amount = commission
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
            f"provider_transaction_id={escrow.provider_transaction_id} payment_no={payment_no} "
            f"amount={amount} commission={commission}",
        )
        await self.db.commit()

        await publish(EConfirmEscrowCreated(
            deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
            buyer_id=deal.buyer_id, seller_id=deal.seller_id, amount=amount,
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

        Every payment on the deal is checked (partial payments: one
        E-Confirm transaction each). Returns the deal's latest payment.
        """
        for escrow in await self.external_escrows.list_for_deal(deal_id):
            if escrow.provider_transaction_id and escrow.status not in EConfirmEscrowStatus.TERMINAL:
                await self.reconcile_payment(escrow)
        return await self.external_escrows.get_by_deal_id(deal_id)

    async def reconcile_payment(self, escrow: ExternalEscrow) -> ExternalEscrow:
        """reconcile_econfirm_escrow for one payment."""
        deal_id = escrow.deal_id
        if not escrow.provider_transaction_id or escrow.status in EConfirmEscrowStatus.TERMINAL:
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
            report_reconciliation(
                "econfirm_unrecognized_status", deal_id=deal_id,
                provider_transaction_id=escrow.provider_transaction_id,
                reason=f"E-Confirm reported a status BROKA does not recognise: {result.raw_status!r}",
                raw_status=result.raw_status,
            )
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
            await self._apply_funded(deal, escrow)

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
            # The deal is released once EVERY payment it holds is paid out.
            escrow.released_at = escrow.released_at or datetime.utcnow()
            await self.external_escrows.save(escrow)
            if not await self._finish_release_if_complete(deal_id):
                await self.db.commit()
        else:
            await self.external_escrows.save(escrow)
            await self.db.commit()

        return escrow

    async def _apply_funded(self, deal: Deal, escrow: ExternalEscrow) -> None:
        """A payment reached escrow. The deal's first money turns it `paid`;
        a top-up on a live deal is recorded against it; money for a deal
        that is over is reported for a human to return."""
        deal_id = deal.id
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
            await self._publish_funded(deal, escrow)
            return

        # The deal was not `agreed` when locked. Usually that is the benign
        # Phase 8 case - a concurrent poller already applied this same
        # FUNDED transition - and the deal is paid or later. A later payment
        # (a top-up) landing on a live deal is expected too, and is recorded
        # once: whoever sets its funded_at first. But money arriving for a
        # deal that is CANCELLED (a lapsed auction win, say), released or
        # refunded is not benign: the buyer has paid into escrow for
        # something they will not get, and nothing would ever notice. That
        # needs a human with the provider's dashboard, so it is recorded as
        # an audit row (the durable record, GET /admin/audit-logs), raised to
        # Sentry through report_reconciliation, and published for any
        # subscriber.
        current = await self.deals.get_by_id(deal_id)
        current_status = current.status if current is not None else None
        if escrow.payment_no > 0 and current_status in _LIVE_FUNDED:
            now = datetime.utcnow()
            won = await self.db.execute(
                update(ExternalEscrow)
                .where(ExternalEscrow.id == escrow.id, ExternalEscrow.funded_at.is_(None))
                .values(funded_at=now, updated_at=now)
            )
            if won.rowcount > 0:
                await record_audit(
                    self.db, "system", "econfirm_payment_funded", "deal", deal_id,
                    f"provider_transaction_id={escrow.provider_transaction_id} "
                    f"payment_no={escrow.payment_no} amount={escrow.amount}",
                )
            await self.db.commit()
            await self.db.refresh(escrow)
            if won.rowcount > 0:
                await self._publish_funded(current, escrow)
                if current.refund_outcome in ("seller_accepted", "seller_silent"):
                    # A prompt opened before the refund was approved, paid
                    # after: the team returning the refund by hand was told
                    # an amount without it.
                    report_reconciliation(
                        "econfirm_funded_after_refund_approved", deal_id=deal_id,
                        provider_transaction_id=escrow.provider_transaction_id,
                        reason=f"payment {escrow.payment_no + 1} (KES {escrow.amount:,.2f}) arrived "
                               f"after the deal's refund was approved - refund it too",
                    )
            return
        if current_status in _FUNDED_OR_LATER and escrow.payment_no == 0:
            await self.db.commit()  # Phase 8: someone else already moved it — not an error
            return
        reason = (
            f"escrow funded but deal is "
            f"{current_status.value if current_status else 'missing'}"
        )
        await record_audit(
            self.db, "system", "econfirm_funded_on_inactive_deal", "deal", deal_id,
            f"provider_transaction_id={escrow.provider_transaction_id} {reason}",
        )
        await self.db.commit()
        report_reconciliation(
            "econfirm_funded_on_inactive_deal", deal_id=deal_id,
            provider_transaction_id=escrow.provider_transaction_id,
            reason=f"{reason} - the buyer's money is in escrow for a deal that "
                   f"will not complete; refund through E-Confirm",
        )
        await publish(EConfirmReconciliationRequired(
            deal_id=deal_id, provider_transaction_id=escrow.provider_transaction_id,
            reason=reason,
        ))

    async def _publish_funded(self, deal: Deal, escrow: ExternalEscrow) -> None:
        await publish(EConfirmEscrowFunded(
            deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
            buyer_id=deal.buyer_id, seller_id=deal.seller_id, amount=escrow.amount,
        ))
        # Publishing the ORIGINAL EscrowFunded event too (exactly once per
        # payment) is what makes deal_hub_subscribers.py write the ledger
        # entry and broadcast over the deal's WebSocket room automatically —
        # see that file's on_escrow_funded. Recording the ledger entry
        # manually here as well would double it. The amount is THIS
        # payment's: the ledger credits what actually arrived.
        await publish(EscrowFunded(
            deal_id=deal.id, buyer_id=deal.buyer_id, seller_id=deal.seller_id,
            amount=escrow.amount, mpesa_receipt=escrow.provider_transaction_id,
        ))
        if escrow.payment_no > 0:
            try:
                from .protection import announce_top_up
                await announce_top_up(self.db, deal.id, escrow.amount)
            except Exception as exc:
                logger.warning("[escrow] top-up announcement failed deal=%s: %s", deal.id, exc)

    async def _finish_release_if_complete(
        self, deal_id: str, *, delivery_confirmed: bool = False,
    ) -> bool:
        """Mark the deal released once every payment it holds is paid out.
        True if this call did it. Commits when it does; the caller commits
        otherwise."""
        payments = await self.external_escrows.list_for_deal(deal_id)
        paid_in = [p for p in payments if p.status in EConfirmEscrowStatus.MONEY_IN]
        if not paid_in or any(p.status != EConfirmEscrowStatus.COMPLETED for p in paid_in):
            return False
        locked = await lock_deal_if_status(self.db, deal_id, (DealStatus.paid,))
        if locked is None:
            return False
        now = datetime.utcnow()
        locked.status = DealStatus.released
        locked.released_at = now
        if delivery_confirmed:
            locked.delivery_confirmed_at = now
        # Nothing left to wait for: a delivery claim's countdown is over.
        if locked.timer_type and locked.timer_fired_at is None:
            locked.timer_cancelled_at = locked.timer_cancelled_at or now
        total = amount_paid(paid_in)
        r = await self.db.execute(select(User).where(User.id == locked.seller_id))
        seller = r.scalar_one_or_none()
        if seller:
            seller.completed_deals = (seller.completed_deals or 0) + 1
            await compute_trust_score(seller.id, self.db)
        last = paid_in[-1]
        await record_audit(
            self.db, "system", "econfirm_payout_completed", "deal", deal_id,
            f"provider_transaction_id={last.provider_transaction_id} payments={len(paid_in)} amount={total}",
        )
        await self.db.commit()
        await publish(EConfirmPayoutCompleted(
            deal_id=deal_id, provider_transaction_id=last.provider_transaction_id,
            seller_id=locked.seller_id, amount=total,
        ))
        await publish(EscrowReleased(
            deal_id=deal_id, seller_id=locked.seller_id, buyer_id=locked.buyer_id, amount=total,
        ))
        return True

    async def get_payment_status(self, deal_id: str, user_id: str) -> dict:
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if user_id not in (deal.buyer_id, deal.seller_id):
            raise HTTPException(status_code=403, detail="Not your deal")

        payments = await self.external_escrows.list_for_deal(deal_id)
        if any(p.provider_transaction_id and p.status not in EConfirmEscrowStatus.TERMINAL
               for p in payments):
            # Phase 8: "Run reconciliation ... from a controlled backend
            # endpoint for immediate UI refresh" — this is that endpoint.
            await self.reconcile_econfirm_escrow(deal_id)
            deal = await self.deals.get_by_id(deal_id)  # re-fetch — reconcile may have changed it

        return await self._payment_status_dict(deal)

    async def _payment_status_dict(self, deal: Deal) -> dict:
        """Where the deal's money stands. The payment fields describe the
        LATEST payment - the one a payment screen is following - and
        amount_paid/balance/payments the deal as a whole."""
        payments = await self.external_escrows.list_for_deal(deal.id)
        escrow = payments[-1] if payments else None
        provider_fee = escrow.provider_fee_amount if escrow else None
        goods = escrow.amount if escrow else deal.agreed_price
        commission = (escrow.merchant_commission_amount
                      if escrow and escrow.merchant_commission_amount is not None else deal.commission)
        balance = balance_due(deal, payments)
        return {
            "deal_id": deal.id,
            "deal_status": deal.status.value,
            "escrow_status": escrow.provider_raw_status if escrow else None,
            "payment_status": self._flutter_payment_status(escrow),
            "goods_amount": goods,
            "merchant_commission": commission,
            "provider_fee": provider_fee,
            "total_to_pay": (
                add_money(goods, commission, provider_fee)
                if provider_fee is not None else None
            ),
            "currency": escrow.currency if escrow else "KES",
            "funded_at": escrow.funded_at.isoformat() if escrow and escrow.funded_at else None,
            "released_at": escrow.released_at.isoformat() if escrow and escrow.released_at else None,
            "can_confirm_delivery": deal.status == DealStatus.paid,
            "payment_no": escrow.payment_no if escrow else None,
            "agreed_price": deal.agreed_price,
            "amount_paid": amount_paid(payments),
            "balance": balance,
            "payments": payment_rows(payments),
            "can_add_payment": (
                deal.status in _TOP_UP_STATUSES and balance > 0
                and not policy.refund_request_open(deal)
                and not (escrow is not None and escrow.status in EConfirmEscrowStatus.OPEN)
            ),
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
        item_received: Optional[bool] = None,
        ownership_transferred: Optional[bool] = None,
    ) -> dict:
        """Buyer confirms delivery. See module docstring for the
        E-Confirm-vs-legacy branch this makes.

        item_received / ownership_transferred are the buyer's answers to the
        app's "has it been delivered?" (and, for land and vehicles, "have
        the ownership documents been transferred?") check. A "no" does not
        stop the release - the app recommends waiting, and the buyer
        decides - but it is written to the audit row, where a later dispute
        can see that the buyer released knowing the item had not arrived.
        """
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != buyer_id:
            raise HTTPException(status_code=403, detail="Only the buyer can confirm delivery")

        def _answer(v: Optional[bool]) -> str:
            return "unanswered" if v is None else ("yes" if v else "no")
        checklist = (f"item_received={_answer(item_received)} "
                     f"ownership_transferred={_answer(ownership_transferred)}")

        escrow = await self.external_escrows.get_by_deal_id(deal_id)
        if escrow is None:
            return await self._confirm_delivery_legacy(deal, buyer_id, request_ip, checklist)
        return await self.release_econfirm_deal(
            deal, buyer_id, request_ip,
            notes="Buyer confirmed delivery via BROKA", audit_detail=checklist,
        )

    async def _confirm_delivery_legacy(
        self, deal: Deal, buyer_id: str, request_ip: Optional[str], checklist: str = "",
    ) -> dict:
        """Original, unchanged behavior for deals with no E-Confirm
        escrow — see module docstring."""
        if deal.status != DealStatus.paid:
            raise HTTPException(status_code=400, detail=f"Cannot release — deal status is '{deal.status.value}'")

        now = datetime.utcnow()
        deal.status = DealStatus.released
        deal.delivery_confirmed_at = now
        deal.released_at = now
        _close_open_requests(deal, now)

        r = await self.db.execute(select(User).where(User.id == deal.seller_id))
        seller = r.scalar_one_or_none()
        if seller:
            seller.completed_deals = (seller.completed_deals or 0) + 1
            await compute_trust_score(seller.id, self.db)

        await record_audit(
            self.db, buyer_id, "delivery_confirmed", "deal", deal.id,
            f"seller_id={deal.seller_id} amount={deal.agreed_price} {checklist}".strip(),
            ip_address=request_ip,
        )
        await self.db.commit()

        await publish(EscrowReleased(
            deal_id=deal.id, seller_id=deal.seller_id, buyer_id=buyer_id, amount=deal.agreed_price,
        ))

        return {"ok": True, "deal_id": deal.id, "status": "released"}

    async def release_econfirm_deal(
        self, deal: Deal, actor_id: str, request_ip: Optional[str] = None, *,
        notes: str, audit_detail: str = "",
    ) -> dict:
        """Phase 10's release flow, for every payment the deal holds. Run
        by the buyer's confirmation and by the delivery claim's automatic
        release (api/core/workers.py). NEVER sets Deal.status=released on
        request receipt alone — only once E-Confirm says EVERY payment's
        payout is Completed (immediately here, or later via
        reconcile_econfirm_escrow if a response was payout_initiated).

        2026-09 restructure (finalization pass, Section 16): the external
        release calls happen OUTSIDE any held row lock — "avoid making
        external provider calls while holding long database transactions".
        The lock is only held for the short "re-verify FRESH state, mark
        intent, commit" step; duplicate-release protection then comes from
        each payment's own status (RELEASE_PENDING/COMPLETED block a second
        attempt), re-read fresh from the DB under the lock rather than
        trusted from an earlier read. That distinction mattered: two
        concurrent requests correctly serialize on the Postgres row lock,
        but the SECOND one used to re-check only deal.status, not the
        escrow's — and deal.status deliberately stays 'paid' when a
        release's immediate response is payout_initiated rather than
        Completed, so the second request could still slip through and call
        release_escrow() a second time for the same transaction.
        """
        if deal.status != DealStatus.paid:
            raise HTTPException(status_code=400, detail=f"Cannot release — deal status is '{deal.status.value}'")
        payments = await self.external_escrows.list_for_deal(deal.id)
        if not any(p.status == EConfirmEscrowStatus.FUNDED and p.provider_transaction_id for p in payments):
            # Fast, cheap rejection - good enough for the overwhelmingly
            # common case of "not funded yet" and avoids acquiring a lock
            # for a request that's going to fail anyway. NOT the
            # correctness guarantee against a genuine race — that's the
            # fresh re-read below, after the lock.
            raise HTTPException(
                status_code=409,
                detail="This deal's escrow isn't in a confirmed-funded state yet — please refresh and try again shortly",
            )

        locked = await lock_deal_if_status(self.db, deal.id, (DealStatus.paid,))
        if locked is None:
            await self.db.commit()
            fresh_deal = await self.deals.get_by_id(deal.id)
            return await self._payment_status_dict(fresh_deal)

        # Authoritative re-read: fresh from the DB while holding the lock —
        # this is what actually prevents the double release described above.
        payments = await self.external_escrows.list_for_deal(deal.id)
        to_release = [p for p in payments
                      if p.status == EConfirmEscrowStatus.FUNDED and p.provider_transaction_id]
        if not to_release:
            await self.db.commit()
            fresh_deal = await self.deals.get_by_id(deal.id)
            return await self._payment_status_dict(fresh_deal)
        if any(not p.confirmation_code_encrypted for p in to_release):
            logger.error("[escrow] deal=%s is funded but a payment has no confirmation_code stored", deal.id)
            await self.db.commit()
            raise HTTPException(
                status_code=500,
                detail="This deal is missing its release credential — please contact support rather than retrying",
            )
        codes: dict[str, str] = {}
        try:
            for p in to_release:
                codes[p.id] = decrypt_secret(p.confirmation_code_encrypted)
        except SecretCryptoError as exc:
            codes.clear()
            logger.error("[escrow] could not decrypt confirmation_code for deal=%s: %s", deal.id, exc)
            await self.db.commit()
            raise HTTPException(status_code=500, detail="Could not read this deal's release credential — please contact support")

        # Persist intent and commit — releases the row lock here, BEFORE
        # the network calls. A second request (whether it was queued on
        # the lock or arrives after) now sees RELEASE_PENDING, not FUNDED.
        now = datetime.utcnow()
        for p in to_release:
            p.status = EConfirmEscrowStatus.RELEASE_PENDING
            p.release_initiated_at = now
            await self.external_escrows.save(p)
        # The buyer releasing ends anything still waiting on them: a refund
        # request of theirs (withdrawn by releasing) and the delivery claim's
        # countdown.
        _close_open_requests(locked, now)
        await record_audit(
            self.db, actor_id, "econfirm_release_requested", "deal", deal.id,
            f"provider_transaction_id={','.join(p.provider_transaction_id for p in to_release)} "
            f"{audit_detail}".strip(),
            ip_address=request_ip,
        )
        await self.db.commit()
        for p in to_release:
            await publish(EConfirmReleaseInitiated(
                deal_id=deal.id, provider_transaction_id=p.provider_transaction_id, seller_id=deal.seller_id,
            ))

        outcomes = []
        for p in to_release:
            code = codes.pop(p.id)
            try:
                outcomes.append(await self._release_payment(deal, p, code, notes))
            finally:
                code = None  # drop the in-memory reference as soon as the call returns
        codes.clear()

        finished = await self._finish_release_if_complete(deal.id, delivery_confirmed=True)
        if not finished:
            await self.db.commit()

        errors = [o for o in outcomes if isinstance(o, HTTPException)]
        if errors:
            raise errors[0]
        if all(o == "completed" for o in outcomes):
            return {"ok": True, "deal_id": deal.id, "status": "released"}
        detail = next(o[1] for o in outcomes if isinstance(o, tuple))
        return {"ok": True, "deal_id": deal.id, "status": "release_pending", "detail": detail}

    async def _release_payment(self, deal: Deal, escrow: ExternalEscrow, confirmation_code: str, notes: str):
        """Ask E-Confirm to pay out one payment, already marked
        RELEASE_PENDING. Returns "completed", ("pending", detail), or an
        HTTPException for the caller to raise once every payment has been
        tried - one payment failing must not leave the others unasked."""
        try:
            result = await get_escrow_provider().release_escrow(
                escrow.provider_transaction_id, confirmation_code, notes=notes,
            )
        except EConfirmAPIError as exc:
            if exc.status_code == 409:
                # Phase 20: "Handle HTTP 409 release-in-progress as a
                # reconciliation case, not as a new payout." escrow.status
                # is already RELEASE_PENDING from above — nothing further
                # to change; a later reconciliation pass resolves it.
                report_reconciliation(
                    "econfirm_release_in_progress", deal_id=deal.id, level="warning",
                    provider_transaction_id=escrow.provider_transaction_id,
                    reason="E-Confirm answered the release with 409 (already in progress); "
                           "reconciliation will finish it",
                )
                await publish(EConfirmReconciliationRequired(
                    deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
                    reason="release returned 409 (already in progress)",
                ))
                return ("pending",
                        "A release for this deal is already being processed — it will show as released once confirmed.")
            logger.warning("[escrow] release rejected deal=%s status=%d", deal.id, exc.status_code)
            escrow.last_error = f"release rejected: HTTP {exc.status_code}"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            return HTTPException(status_code=422, detail="The payment provider rejected the release request — please contact support")
        except EConfirmConnectionError as exc:
            # Ambiguous per Phase 9/11 — do not assume the release failed
            # OR succeeded. escrow.status is already RELEASE_PENDING,
            # which doubles as the "reconciliation_required" state Section
            # 11 of the finalization spec calls for; reconciliation
            # resolves it rather than this request guessing.
            escrow.last_error = f"release attempt: connection error ({type(exc).__name__})"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            report_reconciliation(
                "econfirm_release_outcome_unknown", deal_id=deal.id, level="warning",
                provider_transaction_id=escrow.provider_transaction_id,
                reason=f"release call outcome unknown ({type(exc).__name__}); reconciliation "
                       f"will poll E-Confirm - act only if this deal stays release-pending",
            )
            await publish(EConfirmReconciliationRequired(
                deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
                reason="release call timed out/network error",
            ))
            return HTTPException(
                status_code=503,
                detail="We couldn't confirm the release went through — checking status now, please refresh in a few seconds",
            )
        except EConfirmError as exc:
            logger.error("[escrow] release error deal=%s: %s", deal.id, exc)
            escrow.last_error = f"release error: {type(exc).__name__}"
            await self.external_escrows.save(escrow)
            await self.db.commit()
            return HTTPException(status_code=502, detail="Could not process the release right now — please try again")

        escrow.provider_raw_status = result.raw_status

        if result.status == EConfirmEscrowStatus.COMPLETED:
            escrow.status = EConfirmEscrowStatus.COMPLETED
            escrow.released_at = datetime.utcnow()
            await self.external_escrows.save(escrow)
            await self.db.commit()
            return "completed"

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
            return HTTPException(
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
            report_reconciliation(
                "econfirm_unexpected_release_status", deal_id=deal.id,
                provider_transaction_id=escrow.provider_transaction_id,
                reason=f"E-Confirm answered the release with an unrecognised status: "
                       f"{result.raw_status!r}",
                raw_status=result.raw_status,
            )
            await publish(EConfirmReconciliationRequired(
                deal_id=deal.id, provider_transaction_id=escrow.provider_transaction_id,
                reason=f"unexpected release response status: {result.raw_status}",
            ))
        return ("pending", "Delivery confirmed — payout is being finalized, please check back shortly.")

    # ── Read-only ───────────────────────────────────────────────────────

    async def get_deal(self, deal_id: str, user_id: str) -> dict:
        deal = await self.deals.get_by_id(deal_id)
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != user_id and deal.seller_id != user_id:
            raise HTTPException(status_code=403, detail="Not your deal")
        payments = await self.external_escrows.list_for_deal(deal_id)
        category = (await self.db.execute(
            select(Listing.category).where(Listing.id == deal.listing_id)
        )).scalar_one_or_none()
        return self._deal_dict(deal, payments, category)

    async def get_my_deals(self, user_id: str) -> list[dict]:
        r = await self.db.execute(
            select(Deal).where(
                (Deal.buyer_id == user_id) | (Deal.seller_id == user_id)
            ).order_by(Deal.created_at.desc())
        )
        deals = r.scalars().all()
        payments = await self.external_escrows.list_for_deals([d.id for d in deals])
        listing_ids = list({d.listing_id for d in deals if d.listing_id})
        categories = dict((await self.db.execute(
            select(Listing.id, Listing.category).where(Listing.id.in_(listing_ids))
        )).all()) if listing_ids else {}
        return [self._deal_dict(d, payments.get(d.id, []), categories.get(d.listing_id))
                for d in deals]

    @staticmethod
    def _deal_dict(deal: Deal, payments=(), category: Optional[str] = None) -> dict:
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
            **protection_fields(deal, payments, category),
        }


def _close_open_requests(deal: Deal, now: datetime) -> None:
    """The buyer released the money: an open refund request of theirs is
    withdrawn by it, and any running countdown has nothing left to do."""
    if policy.refund_request_open(deal):
        deal.refund_outcome = "withdrawn"
        deal.refund_resolved_at = now
    if deal.timer_type and deal.timer_fired_at is None and deal.timer_cancelled_at is None:
        deal.timer_cancelled_at = now


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
    # populate_existing is what makes the re-check real. Sessions here use
    # expire_on_commit=False, so a Deal this session loaded earlier (every
    # caller does - they read it first to authorise) sits in the identity
    # map, and a plain SELECT hands back THAT object with its old status
    # even though the row just returned says otherwise. Without this, a
    # transaction that waited on the lock would still see "agreed" after
    # the lock holder committed "paid", and apply the transition a second
    # time.
    result = await db.execute(
        select(Deal).where(Deal.id == deal_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    deal = result.scalar_one_or_none()
    if deal is None or deal.status not in expected_statuses:
        return None
    return deal
