"""
BROKA — E-Confirm API v2 Client
─────────────────────────────────────────────────────────────────────────────
Thin, explicit async wrapper around E-Confirm's marketplace-escrow API.
This is the ONLY file in the codebase allowed to hold an httpx client that
talks to api.econfirm.co.ke — everything above it (providers.py, then
EscrowService) goes through this class, never raw httpx, so there is one
place that knows the wire format, one place that redacts secrets from logs,
and one place the circuit breaker wraps.

Endpoint paths used below come directly from the E-Confirm v2 spec this
integration was built against: POST /transactions, POST /transactions/
{id}/fund/stk-push, GET /transactions/{id}, POST /transactions/{id}/
release, and GET /fee-quote?amount=<int> (corrected 2026-09 from an
earlier, explicitly-flagged POST assumption — see fee_quote()'s
docstring). Response bodies are normalized in one place (_unwrap_envelope)
to handle both a flat shape and a {"success": bool, "data": {...}} wrapper
without every caller needing to know which one a given response used —
see that method's docstring for exactly what it does and doesn't assume.

None of this — the corrected fee-quote path, the envelope shape — has
been independently verified against a live E-Confirm v2 environment or
its real developer-portal docs; both are applied here exactly as
specified by whoever provided this integration's requirements. Treat
"API CONTRACT VERIFIED" as still open until someone with real portal
access or a live sandbox confirms it.

Security (non-negotiable, see api/domains/escrow/ for how callers must
also behave):
  • The API key never appears in a log line, an exception message, or a
    response to Flutter — only in the Authorization header of the actual
    outbound request.
  • confirmation_code is never logged, in either direction — not the value
    the caller passes in, not anything echoed back in a provider response.
  • Provider error bodies ARE preserved on EConfirmAPIError (status_code +
    message + raw provider_detail) for internal diagnostics — it is the
    CALLER's job (EscrowService) to decide what subset, if any, is safe to
    hand back to an API response. This client never makes that call itself.
"""
from __future__ import annotations

import logging
from typing import Any, Optional

import httpx

from api.core.circuit_breaker import CircuitOpenError, econfirm_breaker

logger = logging.getLogger(__name__)


# ── Exceptions ──────────────────────────────────────────────────────────────

class EConfirmError(Exception):
    """Base class for every error this client raises. Catch this in
    EscrowService/providers.py rather than httpx exceptions directly —
    nothing above this file should import httpx at all."""


class EConfirmConnectionError(EConfirmError):
    """Network-level failure (timeout, DNS, connection refused, breaker
    open, or a 5xx from E-Confirm's own infrastructure). The provider's
    actual state is UNKNOWN here, not failed — per Phase 9, callers must
    treat this as ambiguous (query get_transaction() and reconcile) rather
    than assume the operation didn't happen and retry it blindly."""


class EConfirmAPIError(EConfirmError):
    """E-Confirm responded with a 4xx — the request itself was rejected
    (bad input, not-found, conflict, rate limit, validation error). Unlike
    EConfirmConnectionError, the provider DID process the request and DID
    answer, so this is not an ambiguous/retry-safe case the same way."""

    def __init__(self, status_code: int, message: str, provider_detail: Optional[dict] = None):
        self.status_code = status_code
        self.message = message
        self.provider_detail = provider_detail or {}
        super().__init__(f"E-Confirm API error {status_code}: {message}")


class _EConfirmServerError(Exception):
    """Internal-only: signals a 5xx to the circuit breaker so a genuine
    provider outage counts toward tripping it, without also counting a
    client-side 4xx (our own bad request) as a provider-health failure —
    see _request()'s docstring for why those are handled separately."""

    def __init__(self, status_code: int):
        self.status_code = status_code


# ── Client ────────────────────────────────────────────────────────────────

class EConfirmClient:
    """One instance per call is fine (cheap — httpx.AsyncClient is created
    per-request below, matching this codebase's existing mpesa.py style)
    or it can be constructed once and reused; it holds no per-request state."""

    def __init__(
        self,
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        timeout_seconds: Optional[float] = None,
    ):
        from api.core.config import settings
        self._api_key = api_key if api_key is not None else settings.econfirm_api_key
        self._base_url = (base_url or settings.econfirm_base_url).rstrip("/")
        self._timeout = timeout_seconds if timeout_seconds is not None else settings.econfirm_timeout_seconds

    def _headers(self) -> dict:
        if not self._api_key:
            # Deliberately its own error, not EConfirmConnectionError — this
            # is a configuration problem, not a transient/ambiguous one, so
            # callers (Phase 20) should map it to a 502/503 and NOT
            # reconcile-and-retry, just surface "not configured".
            raise EConfirmError("ECONFIRM_API_KEY is not configured")
        return {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    async def _raw_call(self, method: str, url: str, json_body: Optional[dict], params: Optional[dict], headers: dict) -> httpx.Response:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.request(method, url, json=json_body, params=params, headers=headers)
        if resp.status_code >= 500:
            raise _EConfirmServerError(resp.status_code)
        return resp

    async def _request(
        self,
        method: str,
        path: str,
        json_body: Optional[dict] = None,
        params: Optional[dict] = None,
        sensitive: bool = False,
    ) -> dict[str, Any]:
        """
        sensitive=True (used by release_transaction): suppresses the
        provider's error message from the log line entirely, logging only
        the status code. release is the one call whose REQUEST body
        contains confirmation_code — some APIs echo request fields back
        inside a validation-error body, so the safest rule is "don't log
        this call's error detail at all", not "hope the provider never
        echoes it back".

        Circuit breaker scope: only transport failures and 5xx responses
        count as a breaker failure (see _raw_call/_EConfirmServerError).
        A 4xx means E-Confirm is healthy and simply rejected THIS request
        — that must never trip the breaker and block unrelated, valid
        calls for other deals.
        """
        url = f"{self._base_url}{path}"
        try:
            resp = await econfirm_breaker.call(
                self._raw_call, method, url, json_body, params, self._headers(),
            )
        except CircuitOpenError as exc:
            logger.warning("[econfirm] circuit open — rejecting %s %s", method, path)
            raise EConfirmConnectionError("E-Confirm circuit breaker is open (recent failures)") from exc
        except _EConfirmServerError as exc:
            logger.warning("[econfirm] server error %s %s -> %d", method, path, exc.status_code)
            raise EConfirmConnectionError(f"E-Confirm server error (HTTP {exc.status_code})") from exc
        except (httpx.TimeoutException, httpx.ConnectError, httpx.NetworkError) as exc:
            logger.warning("[econfirm] network error %s %s: %s", method, path, type(exc).__name__)
            raise EConfirmConnectionError(f"Network error calling E-Confirm: {type(exc).__name__}") from exc
        except EConfirmError:
            raise
        except Exception as exc:
            logger.error("[econfirm] unexpected error %s %s: %s", method, path, type(exc).__name__)
            raise EConfirmError("Unexpected error calling E-Confirm") from exc

        if resp.status_code >= 400:
            try:
                body = resp.json()
            except Exception:
                body = {}
            message = (
                body.get("message") or body.get("detail") or body.get("error")
                or f"HTTP {resp.status_code}"
            )
            if sensitive:
                logger.warning("[econfirm] %s %s -> %d (detail suppressed)", method, path, resp.status_code)
            else:
                logger.warning("[econfirm] %s %s -> %d %s", method, path, resp.status_code, message)
            raise EConfirmAPIError(resp.status_code, message, body)

        try:
            body = resp.json()
        except Exception as exc:
            raise EConfirmError("E-Confirm returned a non-JSON response") from exc

        if not isinstance(body, dict):
            raise EConfirmError(f"E-Confirm returned an unexpected response shape ({type(body).__name__})")

        return self._unwrap_envelope(body, method, path, sensitive)

    @staticmethod
    def _unwrap_envelope(body: dict[str, Any], method: str, path: str, sensitive: bool) -> dict[str, Any]:
        """
        Normalizes E-Confirm v2's response shape to one predictable
        internal dict, in this one place, so nothing above this file
        (providers.py, EscrowService) has to know or care whether a given
        response was wrapped. Handles two shapes:

          1. Flat: {"id": ..., "status": ..., ...} — returned as-is.
          2. Enveloped: {"success": true/false, "data": {...}} — unwrapped
             to just the inner "data" dict on success; a false "success"
             (even on an HTTP 200 — some APIs signal failure this way
             rather than via status code) is treated as a provider error,
             same as a 4xx response.

        Deliberately tolerant rather than strict: a response with neither
        a "success" nor a "data" key is assumed flat rather than rejected,
        since the exact v2 contract wasn't independently confirmed against
        live E-Confirm docs (see this module's docstring) and refusing to
        parse a legitimately-flat response would be worse than a no-op here.
        """
        if "success" in body:
            if body.get("success") is False:
                message = (
                    body.get("message") or body.get("error") or body.get("detail")
                    or "E-Confirm reported failure"
                )
                if sensitive:
                    logger.warning("[econfirm] %s %s -> success:false (detail suppressed)", method, path)
                else:
                    logger.warning("[econfirm] %s %s -> success:false %s", method, path, message)
                raise EConfirmAPIError(200, message, body)
            if "data" in body and isinstance(body["data"], dict):
                return body["data"]
        elif "data" in body and isinstance(body["data"], dict) and len(body) <= 2:
            # No explicit "success" key, but a "data" wrapper with at most
            # one sibling key (e.g. just "meta" or "message") strongly
            # implies the same envelope pattern minus the flag — unwrap it.
            # A flat response that legitimately happens to have its own
            # "data" field with other real fields alongside it (len(body)
            # > 2) is left alone rather than guessed at.
            return body["data"]
        return body

    # ── Public API ────────────────────────────────────────────────────────

    async def fee_quote(self, amount: float) -> dict[str, Any]:
        """Get E-Confirm's current fee for moving `amount` through escrow,
        so Flutter can show the buyer a real total before they commit.

        GET /fee-quote?amount=<integer> — corrected from an earlier POST
        assumption. amount is sent as an integer: KES/M-Pesa STK amounts
        don't carry sub-shilling precision, and the query-string form is
        what this correction specifies explicitly.
        """
        return await self._request("GET", "/fee-quote", params={"amount": int(round(amount))})



    async def create_transaction(
        self,
        *,
        amount: float,
        buyer_email: str,
        seller_email: str,
        receiver_phone: str,
        description: str,
        merchant_commission_value: float,
        merchant_commission_type: str = "percent",
        merchant_commission_payer: str = "sender",
        econfirm_fee_payer: str = "sender",
    ) -> dict[str, Any]:
        """Create a marketplace escrow transaction. `amount` is the GOODS
        price only (Deal.agreed_price) — never BROKA's commission added in,
        see api/domains/escrow/service.py's commission handling."""
        body = {
            "amount": amount,
            "buyer_email": buyer_email,
            "seller_email": seller_email,
            "receiver_phone": receiver_phone,
            "description": description,
            "merchant_commission": {
                "type": merchant_commission_type,
                "value": merchant_commission_value,
            },
            "merchant_commission_payer": merchant_commission_payer,
            "econfirm_fee_payer": econfirm_fee_payer,
        }
        return await self._request("POST", "/transactions", json_body=body)

    async def fund_stk_push(self, transaction_id: str, payer_phone: str) -> dict[str, Any]:
        """Trigger the M-Pesa STK push E-Confirm sends to the buyer."""
        return await self._request(
            "POST", f"/transactions/{transaction_id}/fund/stk-push",
            json_body={"payer_phone": payer_phone},
        )

    async def get_transaction(self, transaction_id: str) -> dict[str, Any]:
        """Poll current provider status — the only source of truth for
        reconciliation (Phase 8); E-Confirm callbacks are not exposed to us."""
        return await self._request("GET", f"/transactions/{transaction_id}")

    async def release_transaction(
        self, transaction_id: str, confirmation_code: str, notes: Optional[str] = None,
    ) -> dict[str, Any]:
        """Release escrowed funds to the seller. confirmation_code must come
        from EscrowService's decrypted-in-memory read of the stored,
        encrypted value — never from a client request. sensitive=True below
        ensures no provider error detail from this specific call is logged,
        since the request body contains the release credential."""
        body: dict[str, Any] = {"confirmation_code": confirmation_code}
        if notes:
            body["notes"] = notes
        return await self._request(
            "POST", f"/transactions/{transaction_id}/release", json_body=body, sensitive=True,
        )
