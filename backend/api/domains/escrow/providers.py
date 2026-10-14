"""EscrowProvider abstraction (Phase 3 of the E-Confirm integration).

api/domains/escrow/service.py depends on EscrowProvider, never on
EConfirmClient or httpx directly. This is the seam that lets BROKA add a
second provider (Rapyd/Fereji/etc, per the integration spec) later without
touching Deal lifecycle logic in service.py - a new file here implementing
the same four methods, wired in at get_escrow_provider(), is the whole
change.

Every method returns EscrowProviderResult - a provider-agnostic shape.
EscrowService is written against that shape only; nothing above this file
should touch a raw E-Confirm response dict except EConfirmProvider itself.
"""
from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Optional

from api.core.econfirm_client import EConfirmClient
from api.models.external_escrow import EConfirmEscrowStatus

logger = logging.getLogger(__name__)


@dataclass
class FeeQuote:
    fee_amount: float
    currency: str = "KES"
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class EscrowProviderResult:
    """Provider-agnostic outcome of a single escrow operation."""
    provider_transaction_id: str
    status: str            # one of EConfirmEscrowStatus's constants
    raw_status: str         # exact provider string, verbatim (Phase 19)
    confirmation_code: Optional[str] = None  # only ever set by create_escrow()
    fee_amount: Optional[float] = None
    raw: dict[str, Any] = field(default_factory=dict)


class EscrowProvider(ABC):
    """What EscrowService is allowed to depend on for provider money-movement."""

    @abstractmethod
    async def get_fee_quote(self, amount: float) -> FeeQuote: ...

    @abstractmethod
    async def create_escrow(
        self, *, amount: float, buyer_email: str, seller_email: str,
        receiver_phone: str, description: str, commission_amount: float,
    ) -> EscrowProviderResult: ...

    @abstractmethod
    async def fund_escrow(self, provider_transaction_id: str, payer_phone: str) -> EscrowProviderResult: ...

    @abstractmethod
    async def get_status(self, provider_transaction_id: str) -> EscrowProviderResult: ...

    @abstractmethod
    async def release_escrow(
        self, provider_transaction_id: str, confirmation_code: str, notes: Optional[str] = None,
    ) -> EscrowProviderResult: ...


def _first_present(data: dict, keys: list[str]) -> Any:
    for k in keys:
        if k in data and data[k] is not None:
            return data[k]
    return None


class EConfirmProvider(EscrowProvider):
    """EscrowProvider backed by E-Confirm API v2 (api/core/econfirm_client.py)."""

    def __init__(self, client: Optional[EConfirmClient] = None):
        self._client = client or EConfirmClient()

    @staticmethod
    def map_status(raw_status: Optional[str]) -> str:
        """Phase 19's exact provider -> BROKA status mapping, case/space
        normalized. Anything not in this table maps to UNKNOWN on purpose
        (Phase 19: "Never map unknown provider strings automatically") —
        callers must not guess a Deal transition for a status they don't
        recognize."""
        if not raw_status:
            return EConfirmEscrowStatus.UNKNOWN
        key = raw_status.strip().lower().replace(" ", "_").replace("-", "_")
        mapping = {
            "pending":          EConfirmEscrowStatus.PENDING,
            "stk_initiated":    EConfirmEscrowStatus.PENDING,
            "escrow_funded":    EConfirmEscrowStatus.FUNDED,
            "payout_initiated": EConfirmEscrowStatus.RELEASE_PENDING,
            "completed":        EConfirmEscrowStatus.COMPLETED,
            "payout_failed":    EConfirmEscrowStatus.PAYOUT_FAILED,
        }
        mapped = mapping.get(key)
        if mapped is None:
            logger.warning("[econfirm] unrecognized provider status %r -> UNKNOWN", raw_status)
            return EConfirmEscrowStatus.UNKNOWN
        return mapped

    def _to_result(self, data: dict[str, Any], expect_confirmation_code: bool = False) -> EscrowProviderResult:
        provider_tx_id = _first_present(data, ["id", "transaction_id", "transactionId"])
        raw_status = _first_present(data, ["status", "state"])
        fee = _first_present(data, ["econfirm_fee", "provider_fee", "fee", "fee_amount"])
        confirmation_code = None
        if expect_confirmation_code:
            confirmation_code = _first_present(data, ["confirmation_code", "confirmationCode"])
        return EscrowProviderResult(
            provider_transaction_id=str(provider_tx_id) if provider_tx_id is not None else "",
            status=self.map_status(raw_status),
            raw_status=str(raw_status) if raw_status is not None else "",
            confirmation_code=confirmation_code,
            fee_amount=float(fee) if fee is not None else None,
            raw=data,
        )

    async def get_fee_quote(self, amount: float) -> FeeQuote:
        data = await self._client.fee_quote(amount)
        fee = _first_present(data, ["fee", "fee_amount", "econfirm_fee", "amount"])
        currency = _first_present(data, ["currency"]) or "KES"
        return FeeQuote(fee_amount=float(fee) if fee is not None else 0.0, currency=str(currency), raw=data)

    async def create_escrow(
        self, *, amount: float, buyer_email: str, seller_email: str,
        receiver_phone: str, description: str, commission_amount: float,
    ) -> EscrowProviderResult:
        # E-Confirm's create endpoint wants the commission as a percentage
        # (Phase 5's example payload), but Deal.commission (what BROKA
        # actually computed and already trusts) is a flat KES amount - see
        # mpesa.py's STK-push, which uses it directly as an STK amount.
        # Re-deriving a percentage from commission_rate would risk drifting
        # from the deal's *actual* stored commission if that setting ever
        # changes; deriving it FROM commission_amount instead is exact by
        # construction (percent × amount reproduces commission_amount).
        commission_percent = round((commission_amount / amount) * 100, 4) if amount else 0.0
        data = await self._client.create_transaction(
            amount=amount,
            buyer_email=buyer_email,
            seller_email=seller_email,
            receiver_phone=receiver_phone,
            description=description,
            merchant_commission_value=commission_percent,
            merchant_commission_type="percent",
            merchant_commission_payer="sender",
            econfirm_fee_payer="sender",
        )
        return self._to_result(data, expect_confirmation_code=True)

    async def fund_escrow(self, provider_transaction_id: str, payer_phone: str) -> EscrowProviderResult:
        data = await self._client.fund_stk_push(provider_transaction_id, payer_phone)
        return self._to_result(data)

    async def get_status(self, provider_transaction_id: str) -> EscrowProviderResult:
        data = await self._client.get_transaction(provider_transaction_id)
        return self._to_result(data)

    async def release_escrow(
        self, provider_transaction_id: str, confirmation_code: str, notes: Optional[str] = None,
    ) -> EscrowProviderResult:
        data = await self._client.release_transaction(provider_transaction_id, confirmation_code, notes)
        return self._to_result(data)


def get_escrow_provider() -> EscrowProvider:
    """Single seam EscrowService calls through. Always E-Confirm today;
    a deal-aware selection (by currency/region/provider column) would
    only need to change here."""
    return EConfirmProvider()
