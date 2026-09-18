from __future__ import annotations

import logging
from decimal import Decimal
from typing import Optional

from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.money import money_decimal
from api.models.escrow_ledger import LedgerEntry, LedgerAccount, LedgerDirection

logger = logging.getLogger(__name__)


class LedgerError(Exception):
    """Raised when a ledger operation would produce incoherent books."""


class EscrowLedger:
    """Double-entry ledger for escrowed funds.

    Two properties this has to hold, and previously did not:

    **1. Release must debit exactly what was credited.** The release entry
    used to be built from `deal.agreed_price` regardless of what had
    actually been escrowed. Correct for the E-Confirm flow (which escrows
    the full goods price); wrong for the legacy M-Pesa flow, where the STK
    push charges the COMMISSION ONLY (api/routers/mpesa.py:
    `amount = max(1, int(round(deal.commission)))`) because the goods
    settle off-platform. Every legacy deal therefore credited
    escrow_holding ~1,500 and then debited it ~50,000, leaving that account
    short by 97% of the goods price on every completed legacy deal.

    **2. The safety net has to be able to see that.** It couldn't.
    `trial_balance()` compares total debits to total credits across the
    whole table - but every helper here writes matched pairs, so that
    equality holds *by construction* however wrong the individual amounts
    are. The books could be arbitrarily broken and the only check that
    existed would still report `balanced: true`.

    Both are fixed by deriving the released/refunded amount from the ledger
    itself (`escrow_balance`) instead of from a caller-supplied figure, and
    by adding a per-deal check that can actually fail.
    """

    async def _entry(self, db, deal_id, account, direction, amount, description, ref_id=None):
        # Quantized to the column's own scale (Numeric(18,2)) rather than
        # left for the database to round: SQLAlchemy's Numeric degrades to
        # float on SQLite, so an over-precise input would be stored as one
        # number in CI and another in production. money_decimal() also
        # routes floats through repr(), so 0.1+0.2 lands as 0.30 and not
        # 0.30000000000000004.
        amt = money_decimal(amount)
        if amt < 0:
            # A negative amount silently flips a debit into a credit and
            # corrupts every balance derived from it. Reversals here are
            # done with compensating entries - see LedgerEntry's docstring:
            # append-only, never update or delete.
            raise LedgerError(
                f"refusing to write a negative ledger amount ({amt}) for deal={deal_id} "
                f"account={account}; use a compensating entry instead"
            )
        e = LedgerEntry(deal_id=deal_id, account=account, direction=direction,
                        amount_kes=amt, description=description, ref_id=ref_id)
        db.add(e)
        return e

    async def _already_recorded(self, db, deal_id: str, account, direction) -> bool:
        """True if this deal already has an entry on this account/direction.

        The event bus driving these writes (core/deal_hub_subscribers.py)
        is at-least-once: a redelivered EscrowFunded or EscrowReleased used
        to append a second full set of entries, doubling a deal's recorded
        money while keeping the global trial balance perfectly "balanced".
        Each operation below happens at most once per deal, so the presence
        of its signature entry is enough to recognise a replay.
        """
        q = select(func.count(LedgerEntry.id)).where(
            LedgerEntry.deal_id == deal_id,
            LedgerEntry.account == account,
            LedgerEntry.direction == direction,
        )
        return ((await db.execute(q)).scalar() or 0) > 0

    async def record_escrow_funded(self, db, deal_id, buyer_id, amount, mpesa_receipt):
        """Money received and held. `amount` is what was ACTUALLY received -
        the full goods price on the E-Confirm flow, the commission only on
        the legacy M-Pesa flow."""
        amt = Decimal(str(amount))
        if amt <= 0:
            logger.error("[ledger] refusing a non-positive funding amount (%s) deal=%s", amt, deal_id)
            raise LedgerError(f"escrow funding amount must be positive, got {amt}")
        if await self._already_recorded(db, deal_id, LedgerAccount.escrow_holding,
                                        LedgerDirection.credit):
            logger.info("[ledger] funding already recorded for deal=%s - ignoring replay", deal_id)
            return
        await self._entry(db, deal_id, LedgerAccount.buyer_wallet, LedgerDirection.debit,
                          amt, f"Buyer payment via M-Pesa {mpesa_receipt}", mpesa_receipt)
        await self._entry(db, deal_id, LedgerAccount.escrow_holding, LedgerDirection.credit,
                          amt, f"Escrow funded for deal {deal_id}", mpesa_receipt)
        logger.info("[ledger] escrow funded deal=%s amount=%.2f", deal_id, amount)

    async def record_escrow_released(self, db, deal_id, amount, commission, mpesa_receipt=None):
        """Release whatever this deal actually holds, split into commission
        and seller payout.

        `amount` is now a cross-check, not the source of truth: the figure
        debited is `escrow_balance(deal_id)` - what this deal's escrow
        account actually holds according to the ledger. That makes the
        operation self-balancing: it cannot leave a residue however wrong
        the caller's idea of the amount is, which is exactly the failure
        the legacy M-Pesa path produced on every completed deal.
        """
        held = await self.escrow_balance(db, deal_id)
        if held <= 0:
            logger.warning("[ledger] release for deal=%s with nothing held (balance=%s)",
                           deal_id, held)
            return
        if await self._already_recorded(db, deal_id, LedgerAccount.escrow_holding,
                                        LedgerDirection.debit):
            logger.info("[ledger] release already recorded for deal=%s - ignoring replay", deal_id)
            return

        comm = Decimal(str(commission or 0))
        if comm < 0:
            comm = Decimal("0")
        # Commission can never exceed what is actually held. On the legacy
        # flow the held amount IS the commission, so this clamp is what
        # makes that path fall out correctly with no seller-payout leg:
        # BROKA only ever held its own fee, the goods money never touched
        # this ledger, and crediting seller_wallet for it would be
        # recording a payout that never happened.
        if comm > held:
            comm = held
        net = held - comm

        expected = Decimal(str(amount or 0))
        if expected > 0 and abs(expected - held) > Decimal("0.01"):
            # Not fatal - the ledger is the authority and we proceed with
            # `held` - but a caller disagreeing with the books is worth
            # seeing in the logs.
            logger.warning(
                "[ledger] release amount mismatch deal=%s: caller said %.2f, ledger holds %.2f "
                "- using the ledger", deal_id, float(expected), float(held))

        await self._entry(db, deal_id, LedgerAccount.escrow_holding, LedgerDirection.debit,
                          held, "Escrow released on delivery confirmation", mpesa_receipt)
        if net > 0:
            await self._entry(db, deal_id, LedgerAccount.seller_wallet, LedgerDirection.credit,
                              net, "Seller payout (net of commission)", mpesa_receipt)
        if comm > 0:
            await self._entry(db, deal_id, LedgerAccount.broka_revenue, LedgerDirection.credit,
                              comm, "BROKA commission", mpesa_receipt)
        logger.info("[ledger] escrow released deal=%s held=%.2f net=%.2f comm=%.2f",
                    deal_id, float(held), float(net), float(comm))

    async def record_escrow_refunded(self, db, deal_id, amount, dispute_id):
        """Refund whatever this deal actually holds back to the buyer.
        Same self-balancing rule as release."""
        held = await self.escrow_balance(db, deal_id)
        if held <= 0:
            logger.warning("[ledger] refund for deal=%s with nothing held (balance=%s)",
                           deal_id, held)
            return
        if await self._already_recorded(db, deal_id, LedgerAccount.refund_payable,
                                        LedgerDirection.credit):
            logger.info("[ledger] refund already recorded for deal=%s - ignoring replay", deal_id)
            return

        expected = Decimal(str(amount or 0))
        if expected > 0 and abs(expected - held) > Decimal("0.01"):
            logger.warning(
                "[ledger] refund amount mismatch deal=%s: caller said %.2f, ledger holds %.2f "
                "- using the ledger", deal_id, float(expected), float(held))

        await self._entry(db, deal_id, LedgerAccount.escrow_holding, LedgerDirection.debit,
                          held, f"Escrow refunded - dispute {dispute_id}", dispute_id)
        await self._entry(db, deal_id, LedgerAccount.refund_payable, LedgerDirection.credit,
                          held, f"Buyer refund pending - dispute {dispute_id}", dispute_id)
        logger.info("[ledger] escrow refunded deal=%s amount=%.2f dispute=%s",
                    deal_id, float(held), dispute_id)

    async def escrow_balance(self, db, deal_id):
        credits_q = select(func.coalesce(func.sum(LedgerEntry.amount_kes), 0)).where(
            LedgerEntry.deal_id == deal_id,
            LedgerEntry.account == LedgerAccount.escrow_holding,
            LedgerEntry.direction == LedgerDirection.credit)
        debits_q = select(func.coalesce(func.sum(LedgerEntry.amount_kes), 0)).where(
            LedgerEntry.deal_id == deal_id,
            LedgerEntry.account == LedgerAccount.escrow_holding,
            LedgerEntry.direction == LedgerDirection.debit)
        c = (await db.execute(credits_q)).scalar() or Decimal("0")
        d = (await db.execute(debits_q)).scalar() or Decimal("0")
        return Decimal(str(c)) - Decimal(str(d))

    async def trial_balance(self, db):
        """Whole-table debits vs credits, PLUS a per-deal escrow check.

        The global figure alone is close to worthless as an alarm: every
        helper above writes matched debit/credit pairs, so debits ==
        credits holds by construction whatever the amounts are. It can
        catch a half-written transaction and essentially nothing else -
        which is why the release-by-agreed_price bug sat under a green
        "balanced: true" on every legacy deal.

        `negative_escrow_deals` is the check with teeth. A deal's
        escrow_holding balance may be positive (funds still held) or zero
        (settled); it can never legitimately be negative, because that
        means more money left the deal than was ever paid into it.
        """
        total_credits = (await db.execute(
            select(func.sum(LedgerEntry.amount_kes)).where(
                LedgerEntry.direction == LedgerDirection.credit))).scalar() or Decimal("0")
        total_debits = (await db.execute(
            select(func.sum(LedgerEntry.amount_kes)).where(
                LedgerEntry.direction == LedgerDirection.debit))).scalar() or Decimal("0")

        # Per-deal escrow balances. Done as one grouped query rather than a
        # balance call per deal so this stays usable as a routine health
        # check rather than something nobody dares run.
        credits_by_deal = dict((await db.execute(
            select(LedgerEntry.deal_id, func.sum(LedgerEntry.amount_kes))
            .where(LedgerEntry.account == LedgerAccount.escrow_holding,
                   LedgerEntry.direction == LedgerDirection.credit)
            .group_by(LedgerEntry.deal_id))).all())
        debits_by_deal = dict((await db.execute(
            select(LedgerEntry.deal_id, func.sum(LedgerEntry.amount_kes))
            .where(LedgerEntry.account == LedgerAccount.escrow_holding,
                   LedgerEntry.direction == LedgerDirection.debit)
            .group_by(LedgerEntry.deal_id))).all())

        negative = []
        for deal_id in set(credits_by_deal) | set(debits_by_deal):
            bal = (Decimal(str(credits_by_deal.get(deal_id) or 0))
                   - Decimal(str(debits_by_deal.get(deal_id) or 0)))
            if bal < 0:
                negative.append({"deal_id": deal_id, "escrow_balance_kes": float(bal)})

        return {
            "total_credits_kes": float(total_credits),
            "total_debits_kes": float(total_debits),
            "balanced": total_credits == total_debits,
            "discrepancy_kes": float(abs(total_credits - total_debits)),
            # An empty list here is the assertion that actually matters.
            "negative_escrow_deals": negative,
            "escrow_integrity_ok": not negative,
        }


ledger = EscrowLedger()
