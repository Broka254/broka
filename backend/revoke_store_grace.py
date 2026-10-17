"""One-off script: take back the free month (stores/billing grace) from
stores that hold it and shouldn't keep it.

Why this exists: while `ensure_grace_subscriptions` ran on every startup,
switching STORE_BILLING_ENABLED on gave every store with no subscription
row a `paid_until` a month out - including stores created afterwards. That
sweep is now one-time (the store_billing_meta marker) and new stores open
with their own unpaid row, but the grace already granted is still in the
database. This script clears `paid_until` on rows that are grace and
nothing else: plan_id NULL and setup_fee_paid False. A row carrying a plan
(or one whose opening fee was paid) is refused, never touched.

Clearing paid_until is enough: the row stays, so neither the new one-time
round nor the old per-startup sweep finds a rowless store and grants the
grace back.

Usage:
    python backend/revoke_store_grace.py                         # report: who holds grace
    python backend/revoke_store_grace.py --store tokyo-electronics   # dry run
    python backend/revoke_store_grace.py --store tokyo-electronics --apply

--store takes a store slug or id, repeatable. Safe to re-run: a store
already without grace is reported and left alone.
"""
import argparse
import asyncio
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import AsyncSessionLocal
from api.models.store import Store
from api.models.store_billing import StoreSubscription


async def report(db: AsyncSession) -> None:
    rows = (await db.execute(
        select(Store, StoreSubscription)
        .join(StoreSubscription, StoreSubscription.store_id == Store.id)
        .where(
            StoreSubscription.paid_until.is_not(None),
            StoreSubscription.plan_id.is_(None),
            StoreSubscription.setup_fee_paid.is_(False),
        )
        .order_by(Store.name)
    )).all()
    if not rows:
        print("No store currently holds grace.")
        return
    print(f"{len(rows)} store(s) currently hold grace:")
    for store, sub in rows:
        print(f"  {store.slug:<32} {store.name!r:<34} until {sub.paid_until:%Y-%m-%d}")


async def revoke(db: AsyncSession, key: str, apply: bool) -> bool:
    """Clears grace on one store. Returns True when it was (or would be)
    cleared. Locked and re-checked after the lock: a payment may settle
    between the lookup and the update, and clearing paid_until on a row
    that just bought a plan would erase paid-for time."""
    store = await db.get(Store, key)
    if store is None:
        store = (await db.execute(
            select(Store).where(Store.slug == key)
        )).scalar_one_or_none()
    if store is None:
        print(f"  {key}: no such store (slug or id).")
        return False
    sub = (await db.execute(
        select(StoreSubscription).where(StoreSubscription.store_id == store.id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if sub is None:
        print(f"  {store.slug}: no subscription row - nothing to revoke.")
        return False
    if sub.paid_until is None:
        print(f"  {store.slug}: no grace (paid_until already clear) - nothing to do.")
        return False
    if sub.plan_id is not None or sub.setup_fee_paid:
        print(f"  {store.slug}: carries a paid plan until {sub.paid_until:%Y-%m-%d} "
              "- refusing to touch it.")
        return False
    if not apply:
        print(f"  {store.slug}: grace until {sub.paid_until:%Y-%m-%d} - would be cleared (dry run).")
        return True
    sub.paid_until = None
    sub.updated_at = datetime.utcnow()
    await db.commit()
    print(f"  {store.slug}: grace cleared.")
    return True


async def main(keys: list[str], apply: bool) -> None:
    async with AsyncSessionLocal() as db:
        if not keys:
            await report(db)
            print("\nNothing targeted. Pass --store <slug|id> (repeatable), "
                  "then --apply to write.")
            return
        print(f"{'Revoking' if apply else 'Dry run - would revoke'} grace for "
              f"{len(keys)} store(s):")
        changed = 0
        for key in keys:
            if await revoke(db, key, apply):
                changed += 1
        if not apply and changed:
            print(f"\n{changed} store(s) would change. Re-run with --apply to write.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Clear store-billing grace (paid_until on plan-less rows).")
    parser.add_argument("--store", action="append", default=[], metavar="SLUG|ID",
                        help="store slug or id to revoke grace from (repeatable)")
    parser.add_argument("--apply", action="store_true",
                        help="write changes (default: dry run)")
    args = parser.parse_args()
    asyncio.run(main(args.store, args.apply))
