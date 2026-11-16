"""Which web addresses may appear in a provider record - and so be sent to
every buyer's phone as "the official site".

Fake escrow sites are the commonest escrow scam: a look-alike domain that
takes the buyer's money. The provider list is therefore the highest-value
thing in this feature for an attacker to tamper with, and the rule here is
strict on purpose. A URL is official only when it is

  * https, with no user-info ("https://kenyaescrow.com@evil.example" shows
    the bank-style name first and sends the browser to evil.example),
  * on the provider's own canonical domain, or "www." in front of it - an
    exact match, never "ends with" ("kenyaescrow.com.evil.example" ends in
    a name it does not own, and "evilkenyaescrow.com" ends in the string),
  * plain ASCII with no punycode label ("xn--" is how a look-alike
    "kenyaescrow.com" written with a Cyrillic "e" is spelt on the wire),
  * on the default port.

The canonical domain itself must be in the deployment's allowlist
(ESCROW_PROVIDER_DOMAINS). That list is configuration, not data: an admin
account can edit a provider's details through the API, but cannot make the
app link to a domain nobody put in the deployment's settings.
"""
from __future__ import annotations

import re
from typing import Iterable, Optional
from urllib.parse import urlsplit, urlunsplit

MAX_URL_CHARS = 300

# A DNS name: dot-separated labels of letters, digits and inner hyphens, at
# least two labels, a letters-only final label. Lower case only.
_HOST = re.compile(r"^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,23}$")
# Anything that has no business in a URL we will hand to a browser.
_BAD_CHARS = re.compile(r"[\s\\<>\"'`\x00-\x1f\x7f]")


def is_domain(value: object) -> bool:
    """A lower-case ASCII host name, without "www." and without punycode."""
    if not isinstance(value, str) or not _HOST.match(value):
        return False
    if value.startswith("www."):
        return False
    return not any(label.startswith("xn--") for label in value.split("."))


def domain_allowed(domain: str, allowlist: Iterable[str]) -> bool:
    """[domain] is exactly one of the deployment's approved provider domains."""
    return is_domain(domain) and domain in {d.strip().lower() for d in allowlist}


def official_url(url: object, canonical_domain: str) -> Optional[str]:
    """[url] cleaned up, when it is an official address of the provider on
    [canonical_domain]; otherwise None. The fragment is dropped; nothing
    else is rewritten, so what an admin entered is what a buyer is sent to."""
    if not isinstance(url, str) or not url or len(url) > MAX_URL_CHARS:
        return None
    if _BAD_CHARS.search(url) or not is_domain(canonical_domain):
        return None
    try:
        parts = urlsplit(url)
        host = parts.hostname
        port = parts.port
    except ValueError:
        return None
    if parts.scheme != "https" or not host:
        return None
    if parts.username is not None or parts.password is not None:
        return None
    if port not in (None, 443):
        return None
    if host != canonical_domain and host != f"www.{canonical_domain}":
        return None
    # urlsplit lower-cases the scheme and host; the netloc is rebuilt from
    # the host alone so a ":443" or an upper-case host cannot survive.
    return urlunsplit(("https", host, parts.path or "/", parts.query, ""))


def is_official_url(url: object, canonical_domain: str) -> bool:
    return official_url(url, canonical_domain) is not None


def host_of(url: object) -> Optional[str]:
    """The lower-case host of an https URL, or None."""
    if not isinstance(url, str) or _BAD_CHARS.search(url):
        return None
    try:
        parts = urlsplit(url)
        host = parts.hostname
    except ValueError:
        return None
    return host if parts.scheme == "https" and host else None
