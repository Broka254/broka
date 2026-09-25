"""The address a request really came from.

Rate limits keyed per IP (login, signup, OTP, store visit counting) and the
IPs written to audit rows are only as good as this answer. The TCP peer is
rarely the caller in production:

  * On Render, requests pass through Cloudflare and then Render's own
    proxies, so the peer is a Render proxy shared by every user. Cloudflare
    puts the caller's address in CF-Connecting-IP (see CLIENT_IP_HEADER in
    api/core/config.py). Keying limits on the peer made each one a single
    bucket for the whole platform: three signups per five minutes, for
    everyone.
  * The web storefront (web/, on Vercel) forwards store visits and shares
    from its own servers, so the edge sees Vercel, not the visitor. It says
    who the visitor is in X-Broka-Client-IP, and proves it is the storefront
    with X-Broka-Storefront-Key (STOREFRONT_API_KEY). The header is ignored
    without the right key - anyone else could put any address in it.

Resolution order: storefront (authenticated) -> CLIENT_IP_HEADER ->
TRUSTED_PROXY_HOPS entries from the right of X-Forwarded-For -> TCP peer.
Every candidate must parse as an IP address; a malformed value is skipped,
never trusted.
"""
from __future__ import annotations

import hmac
import ipaddress
from typing import Optional

from starlette.requests import HTTPConnection

from api.core.config import settings

STOREFRONT_KEY_HEADER = "x-broka-storefront-key"
STOREFRONT_CLIENT_IP_HEADER = "x-broka-client-ip"

UNKNOWN = "unknown"


def _valid_ip(value: Optional[str]) -> Optional[str]:
    """`value` as a normalised IP address string, or None."""
    if not value:
        return None
    candidate = value.strip()
    # "[2001:db8::1]:443" / "203.0.113.7:51234" - some proxies add a port.
    if candidate.startswith("[") and "]" in candidate:
        candidate = candidate[1:candidate.index("]")]
    elif candidate.count(":") == 1:
        candidate = candidate.split(":", 1)[0]
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        return None


def is_storefront(conn: HTTPConnection) -> bool:
    """True when the request carries the web storefront's shared key."""
    expected = settings.storefront_api_key
    if not expected:
        return False
    sent = conn.headers.get(STOREFRONT_KEY_HEADER, "")
    return bool(sent) and hmac.compare_digest(sent.encode(), expected.encode())


def _from_forwarded_for(conn: HTTPConnection, hops: int) -> Optional[str]:
    """The entry `hops` places from the right of X-Forwarded-For: the
    address the outermost trusted proxy saw. Entries further left were
    written by whoever sent the request and can't be trusted."""
    raw = ",".join(conn.headers.getlist("x-forwarded-for"))
    entries = [e.strip() for e in raw.split(",") if e.strip()]
    if len(entries) < hops:
        return None
    return _valid_ip(entries[-hops])


def resolve(conn: HTTPConnection) -> tuple[str, str]:
    """(address, where it came from). The source is one of "storefront",
    "header", "forwarded-for", "peer" or "unknown" - for diagnostics."""
    if is_storefront(conn):
        ip = _valid_ip(conn.headers.get(STOREFRONT_CLIENT_IP_HEADER))
        if ip:
            return ip, "storefront"

    header = settings.client_ip_header
    if header:
        ip = _valid_ip(conn.headers.get(header))
        if ip:
            return ip, "header"

    hops = settings.trusted_proxy_hops
    if hops > 0:
        ip = _from_forwarded_for(conn, hops)
        if ip:
            return ip, "forwarded-for"

    peer = conn.client.host if conn.client else None
    if peer:
        return peer, "peer"
    return UNKNOWN, "unknown"


def client_ip(conn: HTTPConnection) -> str:
    """The caller's IP address, or "unknown". Works for HTTP requests and
    WebSockets alike."""
    return resolve(conn)[0]


def client_ip_or_none(conn: HTTPConnection) -> Optional[str]:
    """client_ip() for places that store the address: None, not "unknown",
    when there is none."""
    ip = client_ip(conn)
    return None if ip == UNKNOWN else ip
