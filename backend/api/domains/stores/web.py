"""Public Store web page (spec Phase 5, §14/§31).

Server-rendered HTML at GET /store/{slug} - not a separate React/Next.js
app (spec explicitly rules that out for V1), just FastAPI returning HTML
directly and reusing StoreService for data, exactly like the JSON API
does. This is the "lightweight public Store endpoint/page" the spec
describes: real data, Open Graph tags for social previews, a
Download-the-app CTA - not the complete polished storefront (individual
product pages, deep linking, "Ask this store") which the spec explicitly
defers past V1 (§14: "implement the backend/domain foundation cleanly
even if the complete polished SSR storefront is a separate later phase").

SECURITY: every piece of store/listing text below is user-supplied and
gets rendered into raw HTML for anyone on the internet, unauthenticated.
It is escaped with html.escape() before insertion, without exception -
this is the one place in the codebase user text becomes HTML rather than
a JSON field returned to a client that already treats it as data, so it
is the one place this kind of escaping actually matters.

KNOWN LIMITATION (documented, not silently ignored): listing/store images
are inline base64 data URIs today (spec §8/§33-38's own media-architecture
concern). <img src="data:..."> tags render fine in a browser, but a data
URI is NOT usable as an Open Graph og:image - most social crawlers
(WhatsApp, Twitter, etc.) only fetch a real https:// URL, so link
previews will show no image until real object-storage URLs exist. og:image
is deliberately omitted below rather than set to something that silently
doesn't work.

Each page view is also a store visit for the owner's stats
(api/domains/stores/stats.py), attributed from the link's `?via=` tag or
the Referer header.
"""
from __future__ import annotations

import html as _html
from typing import Optional
from urllib.parse import quote, urlparse

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.database import get_db
from . import stats as store_stats
from .service import StoreService

router = APIRouter()

_APP_DOWNLOAD_URL = "https://broka.co.ke/"  # placeholder until real Play/App Store links exist


def _esc(value: Optional[str]) -> str:
    return _html.escape(value) if value else ""


def _listing_card(listing: dict) -> str:
    # Hardening-pass note: cards here are NOT links. Checked directly (no
    # other HTMLResponse route exists anywhere in this backend besides
    # this file) that there is no public listing-detail web page to link
    # to - inventing one would mean a second, web-only product-display
    # system alongside the app's, which is exactly what's ruled out.
    # Individual product pages are explicitly later-stage work once (if)
    # that public page gets built.
    name = _esc(listing.get("name"))
    price = listing.get("price")
    price_html = f"KSh {price:,.0f}" if isinstance(price, (int, float)) else ""
    # The card image: the listing's cover asset when it has one, else the
    # legacy showcase data URI, else its first legacy base64 photo.
    cover = listing.get("cover") or {}
    image = cover.get("medium") or listing.get("showcase_image_url")
    if not image and listing.get("verified_photos"):
        first = listing["verified_photos"].split(",")[0].strip()
        image = f"data:image/jpeg;base64,{first}" if first else None
    img_html = (
        f'<img src="{_esc(image)}" alt="{name}" loading="lazy">'
        if image else '<div class="ph-noimg">BROKA</div>'
    )
    return f"""
    <div class="card">
      <div class="card-img">{img_html}</div>
      <div class="card-body">
        <div class="card-name">{name}</div>
        <div class="card-price">{price_html}</div>
      </div>
    </div>"""


def render_store_page(store: dict, listings: list) -> str:
    name = _esc(store["name"])
    category = _esc(store.get("category"))
    location = ", ".join(p for p in [store.get("subcounty"), store.get("county")] if p)
    location = _esc(location) if location else ""
    description = _esc(store.get("description"))
    listing_count = store.get("listing_count", 0)
    logo = store.get("logo_url")
    initial = _esc((store["name"][:1] or "?").upper())

    subtitle_parts = [p for p in [category, location] if p]
    subtitle = " &middot; ".join(subtitle_parts)

    logo_html = (
        f'<img class="logo-img" src="{_esc(logo)}" alt="{name} logo">'
        if logo else f'<div class="logo-fallback">{initial}</div>'
    )

    # Buyers reach a store through BROKA (chat, offers, checkout), so the
    # page shows no phone numbers; a verified business email is the one
    # direct contact a store can list.
    contacts_html = ""
    if store.get("business_email") and store.get("business_email_verified"):
        contacts_html = (
            f'<div class="contacts"><a href="mailto:{_esc(store["business_email"])}">'
            f'{_esc(store["business_email"])}</a></div>'
        )

    owner = store.get("owner") or {}
    trust_items = []
    if owner.get("verified"):
        trust_items.append("Verified seller")
    if owner.get("completed_deals"):
        n = owner["completed_deals"]
        trust_items.append(f"{n} completed deal{'s' if n != 1 else ''}")
    trust_html = (
        f'<p class="trust">{" &middot; ".join(trust_items)}</p>' if trust_items else ""
    )

    cards_html = "".join(_listing_card(l) for l in listings)
    catalog_html = (
        cards_html if listings else
        '<div class="empty">Nothing listed here yet.</div>'
    )

    description_html = f'<p class="description">{description}</p>' if description else ""
    # A link preview needs an absolute https image URL; data URIs and
    # relative database-served paths don't qualify, so those get no tag.
    preview = (store.get("cover") or {}).get("large") or (store.get("logo") or {}).get("large")
    og_image_html = (
        f'<meta property="og:image" content="{_esc(preview)}">'
        if preview and preview.startswith("https://") else ""
    )
    og_description = subtitle_parts[0] if subtitle_parts else f"{name} on BROKA"

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{name} · BROKA</title>
<meta name="description" content="{_esc(og_description)}">
<meta property="og:type" content="website">
<meta property="og:title" content="{name} · BROKA">
<meta property="og:description" content="{_esc(og_description)}">
<meta property="og:url" content="{_esc(store.get("url"))}">
{og_image_html}
<style>
  :root {{
    --bg:#03040A; --bg-mid:#070B16; --bg-card:#111D35; --gold:#8B5CF6;
    --text-high:#E3D9F7; --text-mid:#8A9BBF; --text-low:#2E3D5A; --border:#1E2D47;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin:0; background:var(--bg); color:var(--text-high);
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  }}
  .wrap {{ max-width:760px; margin:0 auto; padding:20px 16px 60px; }}
  .header {{ display:flex; gap:14px; align-items:flex-start; padding-bottom:16px;
             border-bottom:1px solid var(--border); }}
  .logo-img {{ width:64px; height:64px; border-radius:16px; object-fit:cover; flex-shrink:0; }}
  .logo-fallback {{ width:64px; height:64px; border-radius:16px; background:rgba(139,92,246,0.15);
                     color:var(--gold); display:flex; align-items:center; justify-content:center;
                     font-size:26px; font-weight:800; flex-shrink:0; }}
  h1 {{ margin:0 0 4px; font-size:20px; }}
  .subtitle {{ color:var(--text-mid); font-size:13px; margin:0; }}
  .count {{ color:var(--text-low); font-size:12px; margin-top:4px; }}
  .trust {{ color:var(--gold); font-size:12px; font-weight:600; margin:4px 0 0; }}
  .description {{ color:var(--text-mid); font-size:13.5px; line-height:1.5; margin:16px 0 0; }}
  .contacts {{ margin-top:14px; display:flex; gap:8px; flex-wrap:wrap; }}
  .contacts a {{ color:var(--text-high); text-decoration:none; font-size:12.5px; font-weight:600;
                 background:var(--bg-card); border:1px solid var(--border); border-radius:20px;
                 padding:6px 12px; }}
  .cta {{ display:block; text-align:center; margin:22px 0; background:var(--gold); color:#fff;
          text-decoration:none; font-weight:800; padding:13px; border-radius:14px; font-size:14px; }}
  .section-label {{ color:var(--text-low); font-size:11px; font-weight:700; letter-spacing:0.5px;
                     margin:26px 0 12px; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill, minmax(140px,1fr)); gap:12px; }}
  .card {{ background:var(--bg-card); border:1px solid var(--border); border-radius:14px; overflow:hidden; }}
  .card-img {{ aspect-ratio:1; background:var(--bg-mid); display:flex; align-items:center; justify-content:center; }}
  .card-img img {{ width:100%; height:100%; object-fit:cover; }}
  .ph-noimg {{ color:var(--text-low); font-size:11px; font-weight:700; }}
  .card-body {{ padding:8px 10px 10px; }}
  .card-name {{ font-size:12.5px; font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }}
  .card-price {{ color:var(--gold); font-size:12.5px; margin-top:2px; }}
  .empty {{ color:var(--text-low); font-size:13px; padding:24px 0; text-align:center; }}
  .footer {{ text-align:center; color:var(--text-low); font-size:11px; margin-top:40px; }}
</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    {logo_html}
    <div>
      <h1>{name}</h1>
      <p class="subtitle">{subtitle}</p>
      <p class="count">{listing_count} listing{'s' if listing_count != 1 else ''}</p>
      {trust_html}
    </div>
  </div>
  {description_html}
  {contacts_html}

  <a class="cta" href="{_APP_DOWNLOAD_URL}">Download the BROKA App to message or negotiate</a>

  <div class="section-label">PRODUCTS</div>
  <div class="grid">{catalog_html}</div>

  <div class="footer">Powered by BROKA</div>
</div>
</body>
</html>"""


def render_not_found_page(slug: str) -> str:
    safe_slug = _esc(slug)
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Store not found · BROKA</title>
<style>
  body {{ background:#03040A; color:#8A9BBF; font-family:-apple-system,sans-serif;
          display:flex; align-items:center; justify-content:center; height:100vh; margin:0;
          text-align:center; padding:20px; }}
  a {{ color:#8B5CF6; }}
</style></head>
<body><div>
  <p>No store found for &ldquo;{safe_slug}&rdquo;.</p>
  <p><a href="{_APP_DOWNLOAD_URL}">Open BROKA</a></p>
</div></body></html>"""


@router.get("/{slug}", response_class=HTMLResponse, response_model=None)
async def store_public_page(
    slug: str,
    request: Request,
    via: Optional[str] = Query(None, max_length=32),
    db: AsyncSession = Depends(get_db),
):
    """{STORE_LINK_BASE}/{slug} - the public storefront. Public,
    unauthenticated, and deliberately tolerant: a bad/unknown slug renders
    a friendly HTML page (still 404 status) rather than a raw JSON error,
    since a browser - not the app - is the caller here."""
    # The storefront lives on the web project ({STORE_LINK_BASE}); this
    # page is only a fallback for a deployment whose link base is this
    # service itself. A redirect only ever goes to another host, so it
    # can't loop. 302 rather than 301: browsers keep a 301 forever, and a
    # mistaken link base must stay correctable.
    target = urlparse(settings.store_link_base)
    forwarded_host = (request.headers.get("x-forwarded-host") or "").split(",")[0].strip()
    serving_host = forwarded_host or request.url.netloc
    if target.netloc and target.netloc.lower() != serving_host.lower():
        location = f"{settings.store_link_base}/{quote(slug.lower(), safe='-')}"
        if request.url.query:
            location += f"?{request.url.query}"
        return RedirectResponse(location, status_code=302)

    svc = StoreService(db)
    try:
        store = await svc.get_store_by_slug(slug)
    except HTTPException:
        return HTMLResponse(content=render_not_found_page(slug), status_code=404)

    listings = await svc.list_store_listings(store["id"], limit=24)
    user_agent = request.headers.get("user-agent")
    if request.method == "GET" and not store_stats.is_bot(user_agent):
        await store_stats.record_visit(
            db, store["id"], "web",
            store_stats.visit_source(via, request.headers.get("referer")),
            store_stats.anonymous_visitor_key(
                request.client.host if request.client else None, user_agent,
            ),
        )
    return HTMLResponse(content=render_store_page(store, listings))
