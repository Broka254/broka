"""The KES 10 test charge: proves the ZetuPay rail end to end - prompt, PIN,
webhook, settlement - without selling anything.

ZetuPay has no sandbox (every request moves real money), so its own going-
live checklist is a small real payment to your own phone. An admin starts
one with POST /payments/zetupay/test-charge; it is a ZetuPay payment like
any other (reference, ledger, signature check, amount check, settled once),
and paying it buys nothing - the zetupay_payment_settled audit row is the
record. No domain row: target_id is the payment's own reference.
"""
from __future__ import annotations

import logging
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

AMOUNT = 10


async def zetupay_settled(db: AsyncSession, target_id: str, receipt: Optional[str]) -> None:
    logger.info("[zetupay] test charge %s paid, receipt %s", target_id, receipt)


async def zetupay_failed(db: AsyncSession, target_id: str, reason: str) -> None:
    logger.info("[zetupay] test charge %s not paid: %s", target_id, reason)
