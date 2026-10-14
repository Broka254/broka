"""Store link names: the `clanix` in https://broka.co.ke/store/clanix.

The owner picks the name while setting the store up, and it never changes
afterwards - it ends up on flyers, in TikTok bios and in WhatsApp groups,
where a changed link is a dead link. So the rules are strict up front:

  - 3 to 30 characters;
  - lowercase letters, digits and single hyphens between them (no leading,
    trailing or doubled hyphen) - it reads cleanly when spoken or typed;
  - not a reserved word. Reserved words are paths BROKA's website uses or
    may use, and names that would pass for BROKA itself ("support",
    "official"...) - a store called broka.co.ke/store/help would look like
    BROKA's own help desk.

`check_link_name` says whether a name may be used at all; whether another
store already has it is the caller's question (StoreService).
"""
from __future__ import annotations

import re
from typing import Optional

from api.models.store import slugify

MIN_LENGTH = 3
MAX_LENGTH = 30

_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")

RESERVED = frozenset({
    # BROKA's website and API paths
    "about", "account", "accounts", "admin", "api", "app", "apps", "assets",
    "auth", "blog", "buy", "cart", "categories", "category", "checkout",
    "contact", "dashboard", "download", "explore", "faq", "help", "home",
    "img", "index", "legal", "listing", "listings", "login", "logout",
    "media", "new", "offers", "order", "orders", "pay", "payment",
    "payments", "privacy", "profile", "register", "search", "sell",
    "seller", "sellers", "settings", "shop", "shops", "signin", "signup",
    "static", "store", "stores", "terms", "track", "user", "users", "www",
    # Names that would pass for BROKA or its staff
    "broka", "brokaapp", "broka-app", "broka-kenya", "brokake", "zeno",
    "xxeno", "official", "support", "customer-care", "customercare",
    "helpdesk", "security", "staff", "team", "moderator", "verified",
    "mpesa", "m-pesa", "safaricom", "econfirm", "e-confirm",
})


def normalize(raw: Optional[str]) -> str:
    """What the user typed, as a candidate link name: trimmed and
    lowercased. Deliberately does NOT slugify - "Clanix Shop" is reported
    as invalid rather than silently becoming "clanix-shop", so what the
    owner approves is exactly what gets saved."""
    return (raw or "").strip().lower()


def check_link_name(name: str) -> Optional[str]:
    """None if `name` (already normalized) may be used as a link name,
    otherwise a message that tells the owner what to change."""
    if len(name) < MIN_LENGTH:
        return f"Use at least {MIN_LENGTH} characters."
    if len(name) > MAX_LENGTH:
        return f"Use at most {MAX_LENGTH} characters."
    if not _PATTERN.fullmatch(name):
        if name.startswith("-") or name.endswith("-"):
            return "It can't start or end with a hyphen."
        if "--" in name:
            return "Use one hyphen at a time."
        return "Use only letters, numbers and hyphens - no spaces."
    if name in RESERVED:
        return "That name is reserved. Try another one."
    return None


def suggest_base(text: Optional[str]) -> str:
    """A valid link name derived from a store or business name - the
    starting suggestion in the setup wizard, and the name given to stores
    created by app builds that don't choose one."""
    base = slugify(text)[:MAX_LENGTH].strip("-")
    if len(base) < MIN_LENGTH:
        base = f"{base}-store" if base and base != "store" else "my-store"
    if base in RESERVED:
        base = f"{base}-shop"[:MAX_LENGTH]
    return base


def numbered(base: str, n: int) -> str:
    """`base` with a numeric suffix, trimmed so the result still fits."""
    suffix = f"-{n}"
    return f"{base[:MAX_LENGTH - len(suffix)].rstrip('-')}{suffix}"
