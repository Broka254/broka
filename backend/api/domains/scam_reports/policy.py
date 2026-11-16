"""The rules for scam reports, restrictions and appeals - plain Python.

A report is information; a restriction is a decision. This module keeps the
two apart, and keeps the decision narrow, temporary and appealable.

WHAT A RESTRICTION CAN DO. Only what stops a suspected scam spreading while a
person looks: no new listings. It never deletes anything,
never touches money, never lowers the trust score (a score is a statistic, a
restriction is a decision - one must not become the other), and it ends by
itself on a date the administrator has to choose, within MAX_DAYS. A
"permanent" punishment is not expressible here; that is a different, slower
process with a human reviewing the whole file.

WHAT REPORTS CAN DO. Count. When several different people report the same
account or website, an administrator is asked to look (should_alert). One
person reporting the same account five times counts once: the threshold is
about independent reporters, not volume, or one angry person could "trigger"
an account. Nothing happens to the reported person as a result.
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta
from typing import Iterable, Optional

# ── What a report can say ─────────────────────────────────────────────────

REASONS = {
    "bypass_escrow": "Asked me to skip escrow or pay outside it",
    "fake_escrow_link": "Sent a fake or look-alike escrow link",
    "requested_otp_or_pin": "Asked for my PIN, an OTP or a password",
    "deposit_to_reserve": "Asked for a deposit to reserve an item",
    "fake_payment_proof": "Sent a fake payment message or screenshot",
    "fake_customer_care": "Pretended to be customer care or an escrow agent",
    "changed_payment_destination": "Changed where to pay at the last minute",
    "non_delivery": "Took payment and did not deliver",
    "not_as_described": "The item or service was not as described",
    "other": "Something else",
}

STATUSES = ("open", "in_review", "actioned", "dismissed", "closed")

MAX_TEXT = 4000
MAX_REF = 120

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_PHONE = re.compile(r"^\+?[0-9][0-9 ()-]{6,19}$")
_HOST = re.compile(r"^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,23}$")


def clean_text(value: object, limit: int, *, newlines: bool = False) -> str:
    text = str(value or "").replace("\x00", "")
    text = _CONTROL.sub("", text)
    if not newlines:
        text = " ".join(text.split())
    return text.strip()[:limit]


def reported_account_kind(ref: str) -> str:
    """What a free-text account reference looks like: "phone", "website" or
    "other". A website reference is reduced to its host so the same fake site
    reported by many people counts as one (host_of)."""
    ref = (ref or "").strip()
    if _PHONE.match(ref):
        return "phone"
    if host_of(ref):
        return "website"
    return "other"


def host_of(ref: str) -> Optional[str]:
    """The lower-case host in [ref] if it names a website, else None."""
    text = (ref or "").strip().lower()
    text = re.sub(r"^https?://", "", text).split("/")[0].split("?")[0].split("#")[0]
    text = text.split("@")[-1].split(":")[0]
    if text.startswith("www."):
        text = text[4:]
    return text if _HOST.match(text) else None


def normalise_account_ref(ref: str) -> str:
    """A stable form of a reported account, for counting reports of the same
    one: digits only for a phone (+254 712 345 678 == 0712345678), the host
    for a website, else lower-case text."""
    text = clean_text(ref, MAX_REF)
    kind = reported_account_kind(text)
    if kind == "phone":
        digits = re.sub(r"\D", "", text)
        if digits.startswith("254") and len(digits) == 12:
            digits = "0" + digits[3:]
        return digits
    if kind == "website":
        return host_of(text) or text.lower()
    return text.lower()


def validate_report(reason_code: object, description: object, *, reported_user_id: object,
                    reported_account_ref: object, reporter_id: str) -> list[str]:
    """Why a report cannot be filed as sent, or []. A report must name
    SOMETHING: a Broka account, or the phone/website/name it is about."""
    problems = []
    if reason_code not in REASONS:
        problems.append(f"reason_code: must be one of {sorted(REASONS)}")
    if len(clean_text(description, MAX_TEXT, newlines=True)) < 10:
        problems.append("description: say what happened (at least a sentence)")
    if reported_user_id and reported_user_id == reporter_id:
        problems.append("reported_user_id: you cannot report yourself")
    if not reported_user_id and len(clean_text(reported_account_ref, MAX_REF)) < 3:
        problems.append("reported_account_ref: name the account, phone number or website this is about")
    return problems


# ── Counting reports ─────────────────────────────────────────────────────

# Distinct reporters of one account or website, inside the window, before an
# administrator is asked to look. Not a threshold for anything else.
ALERT_REPORTERS = 3
ALERT_WINDOW_DAYS = 30


def should_alert(reporter_ids: Iterable[str], *, threshold: int = ALERT_REPORTERS) -> bool:
    """Ask a person to look: enough DIFFERENT people reported it. A repeat
    from one reporter changes nothing."""
    return len({r for r in reporter_ids if r}) >= threshold


def window_start(now: datetime, days: int = ALERT_WINDOW_DAYS) -> datetime:
    return now - timedelta(days=days)


# ── Restrictions ─────────────────────────────────────────────────────────

# What a restriction may stop. Deliberately short: it protects other users
# from a suspected scam in progress, it does not punish. ONLY SCOPES THAT ARE
# ENFORCED BELONG HERE: a restriction that says it blocks offers and does not
# is worse than one that says what it does. Posting a listing is enforced
# (listings/service.create_listing). Adding a scope means wiring its check
# where the action happens and adding a test that the action is refused.
SCOPES = {
    "create_listing": "Post new listings",
}
MAX_DAYS = 14
MIN_DAYS = 1

RESTRICTION_STATUSES = ("active", "lifted", "expired")
APPEAL_STATUSES = ("open", "upheld", "overturned", "withdrawn")
APPEAL_OUTCOMES = ("upheld", "overturned")
MAX_APPEALS_PER_RESTRICTION = 2

RESTRICTION_NOTICE = (
    "Broka has temporarily limited some features on your account while the team reviews a "
    "report. This is not a finding that you did anything wrong. You can appeal, and the "
    "limit ends on its own on the date shown."
)


def validate_restriction(scopes: object, days: object, internal_reason: object,
                         public_reason: object) -> list[str]:
    problems = []
    if not isinstance(scopes, list) or not scopes or not all(s in SCOPES for s in scopes):
        problems.append(f"scopes: a non-empty list from {sorted(SCOPES)}")
    if isinstance(days, bool) or not isinstance(days, int) or not MIN_DAYS <= days <= MAX_DAYS:
        problems.append(f"days: a whole number from {MIN_DAYS} to {MAX_DAYS}. A restriction is "
                        "temporary; there is no open-ended one")
    if len(clean_text(internal_reason, 1000, newlines=True)) < 10:
        problems.append("internal_reason: record why (at least a sentence); it is kept in the audit trail")
    if len(clean_text(public_reason, 300)) < 10:
        problems.append("public_reason: say, in words the person will read, what this is about")
    return problems


def is_active(status: str, expires_at: Optional[datetime], now: datetime) -> bool:
    """Active only if it has not been lifted and its date has not passed. It
    ends by the clock, with nothing needing to run."""
    return status == "active" and expires_at is not None and expires_at > now


def effective_status(status: str, expires_at: Optional[datetime], now: datetime) -> str:
    if status == "active" and (expires_at is None or expires_at <= now):
        return "expired"
    return status


def can_appeal(status: str, expires_at: Optional[datetime], now: datetime, appeals_so_far: int,
               has_open_appeal: bool) -> Optional[str]:
    """None if the person may appeal, else why not. An expired or lifted
    restriction needs no appeal; and a person cannot appeal endlessly."""
    if not is_active(status, expires_at, now):
        return "this restriction is no longer in force"
    if has_open_appeal:
        return "you already have an appeal waiting for a decision"
    if appeals_so_far >= MAX_APPEALS_PER_RESTRICTION:
        return "you have used the appeals available for this restriction"
    return None


def validate_appeal(statement: object) -> list[str]:
    """An appeal needs something to read, not an essay: a frightened person
    who writes one honest sentence has appealed. What is refused is nothing,
    or a word."""
    if len(clean_text(statement, 2000, newlines=True).split()) < 3:
        return ["statement: tell us your side, in a sentence or two"]
    return []


def validate_decision(outcome: object, note: object) -> list[str]:
    problems = []
    if outcome not in APPEAL_OUTCOMES:
        problems.append(f"outcome: one of {list(APPEAL_OUTCOMES)}")
    if len(clean_text(note, 1000, newlines=True)) < 10:
        problems.append("note: explain the decision (the person is told it)")
    return problems


# ── Private evidence ─────────────────────────────────────────────────────

MAX_EVIDENCE_FILES = 3
MAX_EVIDENCE_BYTES = 1_500_000

_MAGIC = (
    (b"\x89PNG\r\n\x1a\n", "image/png", "png"),
    (b"\xff\xd8\xff", "image/jpeg", "jpg"),
)


def sniff_image(data: bytes) -> Optional[tuple[str, str]]:
    """(mime type, extension) from the file's first bytes, or None. The
    client's claimed type and file name are never trusted: PNG, JPEG and
    WebP only, decided by what the bytes are."""
    for magic, mime, ext in _MAGIC:
        if data.startswith(magic):
            return mime, ext
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp", "webp"
    return None


def safe_file_name(name: object, ext: str) -> str:
    """A display name with no path, no control characters and the real extension."""
    stem = re.sub(r"[^A-Za-z0-9._ -]", "", str(name or "").replace("\\", "/").split("/")[-1])
    stem = re.sub(r"\.[A-Za-z0-9]{1,5}$", "", stem).strip(" .-_")[:60] or "evidence"
    return f"{stem}.{ext}"
