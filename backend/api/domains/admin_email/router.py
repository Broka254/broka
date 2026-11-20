"""POST /admin/email/send: the admin dashboard's Email Reply tool.

A sending interface only. It reads no mailbox and lists nothing that was sent;
a reply to a message lands in the admin address's own inbox, outside this API.

The sender is not an input. It comes from BROKA_ADMIN_EMAIL_FROM
(api/core/email.py), the body model refuses a "from", "reply_to" or "html"
(extra="forbid"), and the HTML part is built here from the plain text the
administrator wrote - so a session that is not allowed to speak as BROKA's
admin address cannot be made to by what it posts.

Neither the recipient's address, the subject nor the message is written to a
log, an audit row or an error response. What is recorded is who, when, the
provider's message id, how long each part was and the recipient's domain.
"""
from __future__ import annotations

import json
import logging
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.email import (
    ADMIN_EMAIL_DUPLICATE,
    ADMIN_EMAIL_MESSAGE_MAX,
    ADMIN_EMAIL_NOT_CONFIGURED,
    ADMIN_EMAIL_PROVIDER_LIMIT,
    ADMIN_EMAIL_RECIPIENT_MAX,
    ADMIN_EMAIL_REJECTED,
    ADMIN_EMAIL_SENDER_REFUSED,
    ADMIN_EMAIL_SUBJECT_MAX,
    admin_email_provider_key,
    admin_email_sender,
    clean_admin_message,
    clean_admin_subject,
    normalize_admin_recipient,
    send_admin_email,
)
from api.core.idempotency import IdempotencyResult, idempotency_guard
from api.core.observability import request_id_var
from api.core.permissions import Permission, require_permission
from api.core.rate_limit import admin_email_send_limiter
from api.database import User, get_db, release_connection

router = APIRouter()
logger = logging.getLogger(__name__)


class AdminEmailIn(BaseModel):
    # Anything the model does not name is an error, not a field to ignore:
    # {"from": ...} must fail loudly, not quietly send as the default sender.
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    to: str = Field(min_length=1, max_length=ADMIN_EMAIL_RECIPIENT_MAX)
    subject: str = Field(min_length=1, max_length=ADMIN_EMAIL_SUBJECT_MAX)
    message: str = Field(min_length=1, max_length=ADMIN_EMAIL_MESSAGE_MAX)

    @field_validator("to")
    @classmethod
    def _to(cls, value: str) -> str:
        return normalize_admin_recipient(value)

    @field_validator("subject")
    @classmethod
    def _subject(cls, value: str) -> str:
        return clean_admin_subject(value)

    @field_validator("message")
    @classmethod
    def _message(cls, value: str) -> str:
        return clean_admin_message(value)


class AdminEmailSendOut(BaseModel):
    status: Literal["sent"] = "sent"
    message_id: str
    # The addresses the message actually carried, as the backend holds them.
    sender: str
    reply_to: str


# What each failure is called to the dashboard, and how. The text is ours,
# fixed here: the provider's own error text can echo the recipient and the
# request, so none of it is passed on. 401 and 403 are never used for a
# provider's refusal: the dashboard's proxy treats a 401 as "this administrator
# is signed out" and ends their session.
_FAILURES = {
    ADMIN_EMAIL_NOT_CONFIGURED: (
        503, "email_not_configured",
        "Email sending is not configured on this server.",
    ),
    ADMIN_EMAIL_REJECTED: (
        422, "email_rejected",
        "The email provider rejected this message. Check the recipient address and try again.",
    ),
    ADMIN_EMAIL_SENDER_REFUSED: (
        502, "email_sender_refused",
        "The email provider refused BROKA's sender. Check the Resend API key and that the "
        "sending domain is verified in Resend.",
    ),
    ADMIN_EMAIL_DUPLICATE: (
        409, "email_duplicate_request",
        "This request key is already in use for a message that is still being sent, or for "
        "a different message. Wait a moment, or write the message again.",
    ),
    ADMIN_EMAIL_PROVIDER_LIMIT: (
        429, "email_provider_limit",
        "The email provider's sending limit was reached. Try again later.",
    ),
}
_UNAVAILABLE = (
    502, "email_provider_unavailable",
    "The email provider is unavailable or did not respond, so this message may not have been "
    "sent. Retrying is safe: the same request is never sent twice.",
)


def _configured_sender() -> Optional[tuple[str, str]]:
    """(From header, Reply-To) when this server can send, else None.

    The key is read through api.core.email's own `settings` (not an import of
    it here) so there is exactly one place the answer comes from.
    """
    from api.core import email as email_module
    if not email_module.settings.resend_api_key:
        return None
    return admin_email_sender()


def _request_id() -> str:
    rid = request_id_var.get("-")
    return rid if rid and rid != "-" else uuid.uuid4().hex[:12]


def _failure_response(failure: Optional[str]) -> JSONResponse:
    status, code, detail = _FAILURES.get(failure or "", _UNAVAILABLE)
    return JSONResponse(status_code=status, content={"detail": detail, "code": code})


async def _audit(
    db: AsyncSession, request: Request, admin: User, *, request_id: str,
    message_id: Optional[str], failure: Optional[str], provider_status: Optional[int],
    to: str, subject: str, message: str,
) -> None:
    """One audit row for the attempt, success or failure. Never raises: the
    provider has already answered, and a message that was sent must not be
    reported as failed because the audit write could not land.

    record_audit also writes the first 120 characters of `detail` to the
    application log. So `detail` never holds the address, the subject or the
    message - only the recipient's DOMAIN, which is enough to see a pattern
    (one organisation being written to repeatedly) and is the one piece of the
    recipient that does reach that log line.
    """
    sent = message_id is not None
    detail = {
        "request_id": request_id,
        "status": "sent" if sent else "failed",
        "to_domain": to.rpartition("@")[2],
        "subject_chars": len(subject),
        "message_chars": len(message),
    }
    if sent:
        detail["message_id"] = message_id
    else:
        detail["failure"] = failure
        if provider_status is not None:
            detail["provider_status"] = provider_status
    try:
        await record_audit(
            db, admin.id,
            "admin_email_sent" if sent else "admin_email_failed",
            "admin_email", message_id or request_id,
            detail=json.dumps(detail, separators=(",", ":"), sort_keys=True),
            ip_address=client_ip_or_none(request),
        )
        await db.commit()
    except Exception as exc:
        try:
            await db.rollback()
        except Exception:
            pass
        logger.error(
            "[admin-email] audit write failed request_id=%s message_id=%s err=%s",
            request_id, message_id or "-", type(exc).__name__,
        )


@router.post("/send", response_model=AdminEmailSendOut)
async def send_email(
    body: AdminEmailIn,
    request: Request,
    # The permission comes first, so a caller who may not send never reaches
    # the idempotency guard (and Redis) at all.
    admin: User = Depends(require_permission(Permission.SEND_ADMIN_EMAIL)),
    idempotency: IdempotencyResult = Depends(idempotency_guard),
    db: AsyncSession = Depends(get_db),
):
    if idempotency.cached:
        # The same request, already sent: the first answer, no second email
        # and no second audit row.
        return idempotency.response

    # A server that cannot send is told so before a slot in the hourly limit
    # is spent, a connection is released or an audit row is written for a
    # message that was never going to go out.
    # Resolved once: the answer below reports the addresses the message
    # carried, which must be the ones it was sent with.
    sender = _configured_sender()
    if sender is None:
        return _failure_response(ADMIN_EMAIL_NOT_CONFIGURED)

    await admin_email_send_limiter.check_and_record(admin.id)

    # No pooled connection is held while the provider answers (AGENTS.md).
    # The permission check above left a read transaction open.
    await release_connection(db, before="admin_email_send")

    request_id = _request_id()
    # Resend remembers this key for 24 hours and answers a repeat with the
    # first response, so retrying after a timeout cannot send a second email.
    provider_key = (
        admin_email_provider_key(admin.id, idempotency.key) if idempotency.key else None
    )
    result = await send_admin_email(
        to=body.to, subject=body.subject, message=body.message, provider_key=provider_key,
    )

    await _audit(
        db, request, admin, request_id=request_id,
        message_id=result.message_id if result.ok else None,
        failure=result.failure, provider_status=result.provider_status,
        to=body.to, subject=body.subject, message=body.message,
    )

    if not result.ok:
        return _failure_response(result.failure)

    out = AdminEmailSendOut(
        message_id=result.message_id, sender=sender[0], reply_to=sender[1],
    ).model_dump()
    await idempotency.store(out)
    return out
