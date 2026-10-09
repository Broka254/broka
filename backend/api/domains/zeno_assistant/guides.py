"""Zeno's guides: "how do I open a store?", "how do I sell faster?" -
answered with steps built from the user's own situation, and a button on
each step that takes them to the screen where it is done.

No model call. How to open a store on BROKA is the same answer every time
it is asked; the parts that differ from one user to the next - whether
they are a business seller yet, whether their store is missing a logo,
which listing has two photos and is priced a fifth above everything like
it - come from the database, not from a model's guess. That makes the
most-asked questions free and instant, and makes their answers true.

Every figure in a guide is computed (knowledge.listing_facts); nothing is
estimated or invented - no "listings with photos sell 3x faster".

Guides are English for now; Zeno's own replies follow the user's language.
"""
from __future__ import annotations

from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.database import Listing, ListingStatus, User
from . import knowledge

GUIDES: dict[str, str] = {
    "open_store": "opening and running an online store on BROKA",
    "sell_faster": "selling faster - tips from the user's own listings",
    "get_verified": "getting verified",
    # Not a card any more: asking for it starts Zeno's step-by-step
    # escrow walkthrough (escrow_walkthrough.py, service.py).
    "escrow": "walking them through paying - or getting paid - with an escrow service, step by step",
    "first_listing": "posting a first listing",
    "stay_safe": "staying safe from scams",
    "negotiate": "negotiating a good price",
    "find_item": "getting the Buying Agent to find something",
}


def available() -> dict[str, str]:
    """GUIDES this server offers now: no "getting verified" while the badge
    isn't sold (VERIFIED_BADGE_ENABLED) - its guide ends on a purchase the
    server would refuse."""
    if settings.verified_badge_enabled:
        return GUIDES
    return {k: v for k, v in GUIDES.items() if k != "get_verified"}


def _step(title: str, detail: str = "", destination: Optional[str] = None) -> dict:
    step = {"title": title, "detail": detail}
    if destination:
        step["destination"] = destination
    return step


def _kes(v: float) -> str:
    return f"KES {v:,.0f}"


async def _open_store(db: AsyncSession, user_id: str) -> dict:
    from api.models.store import Store

    store = (await db.execute(
        select(Store).where(Store.owner_id == user_id, Store.is_active.is_(True))
        .order_by(Store.created_at.desc()).limit(1)
    )).scalar_one_or_none()
    if store is not None:
        in_store = (await db.execute(
            select(func.count(Listing.id)).where(Listing.store_id == store.id,
                                                 Listing.status == ListingStatus.active)
        )).scalar_one()
        steps = []
        missing = [what for what, have in (("a logo", store.logo_id or store.logo_url),
                                           ("a description", store.description),
                                           ("photos", store.photo_ids or store.photos)) if not have]
        if missing:
            steps.append(_step("Finish its look", f"It has no {', no '.join(m.replace('a ', '') for m in missing)} yet - "
                               "a logo and a line on what you sell make it look like a real shop.", "my_store"))
        steps.append(_step("Fill the shelves" if in_store < 5 else "Keep the shelves fresh",
                           f"{in_store} active listing(s) in it now. Stores with more to browse keep buyers "
                           "looking; add something new every week.", "sell"))
        steps.append(_step("Share your link", f"broka.co.ke/store/{store.slug} - put it on WhatsApp, "
                           "your status and your socials.", "my_store"))
        steps.append(_step("Reply fast", "Quick answers turn browsers into buyers.", "inbox"))
        return {"id": "open_store", "title": "Make the most of your store",
                "intro": f"Your store \"{store.name}\" is live. Here's how to get more from it.",
                "steps": steps}

    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    tier = getattr(getattr(user, "seller_tier", None), "value", getattr(user, "seller_tier", None))
    business = tier == "long_term"
    steps = [
        _step("Open store setup",
              "You're a business seller, so it goes straight to your store." if business else
              "It asks a few business questions first - a store is for business sellers.",
              "store_setup"),
        _step("Name it and brand it", "A clear name, a logo, a cover photo and one line on what you sell."),
        _step("Add your listings", "Everything you sell shows on your store page."),
        _step("Share your link", "You get broka.co.ke/store/your-name to send to customers."),
    ]
    return {"id": "open_store", "title": "Open your online store",
            "intro": "A store gives your business its own page on BROKA. Four steps:",
            "steps": steps}


async def _sell_faster(db: AsyncSession, user_id: str) -> dict:
    facts = await knowledge.listing_facts(db, user_id)
    verified = (await db.execute(select(User.is_verified).where(User.id == user_id))).scalar_one_or_none()
    if not facts:
        steps = [
            _step("Post a listing", "Clear photos from every side, a title with brand and model, "
                  "and a fair price.", "sell"),
            _step("Price it like the market", "Search for the same item and see what it goes for.", "search"),
        ]
        if not verified and settings.verified_badge_enabled:
            steps.append(_step("Get verified", "Buyers trust the badge.", "verify"))
        return {"id": "sell_faster", "title": "Selling faster on BROKA",
                "intro": "You have no active listings yet - here's how to start strong.", "steps": steps}

    steps: list[dict] = []
    for f in facts:
        name = f"\"{f['name']}\""
        if f["median"] and f["price"] > f["median"] * 1.15:
            above = (f["price"] - f["median"]) / f["median"] * 100
            steps.append(_step(f"Check the price of {name}",
                               f"{_kes(f['price'])} is {above:.0f}% above the median {_kes(f['median'])} of "
                               f"{f['compared_with']} similar {f['category']} listings. Come down, or say in the "
                               "description why it's worth more.", "seller_dashboard"))
        if f["photos"] < 4:
            steps.append(_step(f"More photos on {name}",
                               f"It has {f['photos']}. Show every side, and any marks - buyers ask fewer "
                               "questions and trust it more.", "seller_dashboard"))
        if f["description_chars"] < 80:
            steps.append(_step(f"Say more about {name}",
                               "Condition, age, what's included, why you're selling.", "seller_dashboard"))
        if (f["days_listed"] or 0) >= 7 and f["views"] < 10:
            steps.append(_step(f"Get {name} seen",
                               f"{f['views']} views in {f['days_listed']} days. A boost puts it in front of more "
                               "buyers; a title with brand and model helps search find it.", "seller_dashboard"))
        if f["enquiries"]:
            steps.append(_step(f"Answer the buyers of {name}",
                               f"{f['enquiries']} buyer(s) asked about it - a quick reply closes deals.", "inbox"))
    if not verified and settings.verified_badge_enabled:
        steps.append(_step("Get verified", "Buyers trust the badge on every listing.", "verify"))
    if not steps:
        return {"id": "sell_faster", "title": "Selling faster on BROKA",
                "intro": "Your listings look in good shape - prices in line, photos and descriptions there.",
                "steps": [_step("Keep replies quick", "Most deals go to the seller who answers first.", "inbox"),
                          _step("Refresh what's been up longest", "New photos or a sharper title bring it back "
                                "into view.", "seller_dashboard")]}
    return {"id": "sell_faster", "title": "Selling faster: your listings",
            "intro": "From your own listings, the changes most likely to help:",
            "steps": steps[:6]}


def _static(guide_id: str) -> dict:
    return {
        "get_verified": {
            "title": "Getting verified",
            "intro": "Verified accounts show a badge buyers and sellers trust.",
            "steps": [
                _step("Open verification", "It takes a couple of minutes.", "verify"),
                _step("Have your ID ready", "And good light for the selfie."),
                _step("That's it", "The badge shows on your profile and every listing."),
            ],
        },
        # The card a guide request still gets from an older path; the
        # model's GUIDE "escrow" starts the walkthrough instead (service.py).
        "escrow": {
            "title": "Paying safely with escrow",
            "intro": "BROKA doesn't take payments itself yet. An escrow service holds the money "
                     "until the buyer has the item - ask me to walk you through it.",
            "steps": [
                _step("Pick an escrow service", "E-Confirm, Escrow Kenya, Kenya Escrow, Lipasafe or "
                      "Shikilia - independent, not run by BROKA.", "escrow_services"),
                _step("Pay the service, never the seller", "Open it yourself - never from a link "
                      "the other person sends."),
                _step("Release once you have it", "Only when it's what you agreed."),
                # Not M-Pesa escrow: an M-Pesa payment can't carry more
                # than KES 250,000, and only the official search shows who
                # owns it.
                _step("Land or a car?", "Do the official search first (Ardhisasa, or NTSA for the "
                      "logbook) and pay through a bank or an advocate."),
            ],
        } if not settings.in_app_payments_enabled else {
            "title": "How escrow keeps you safe",
            "intro": "BROKA holds the money until the buyer has what they paid for.",
            "steps": [
                _step("The buyer pays into escrow", "The seller sees it's paid; nobody can touch it yet."),
                _step("The seller delivers", "Or the buyer collects and inspects."),
                _step("The buyer confirms", "The money is released to the seller."),
                _step("Something wrong?", "Open a dispute - the money stays frozen until it's settled.",
                      "how_broka_works"),
            ],
        },
        "first_listing": {
            "title": "Posting your first listing",
            "intro": "About three minutes, start to finish.",
            "steps": [
                _step("Open Sell", "", "sell"),
                _step("Photos first", "Every side, in daylight, and any marks."),
                _step("Say what it is", "Brand, model, condition, what's included."),
                _step("Price it", "Check similar listings first.", "search"),
            ],
        },
        "stay_safe": {
            "title": "Staying safe on BROKA",
            "intro": ("Nearly every scam starts by moving the money or the chat off BROKA."
                      if settings.in_app_payments_enabled else
                      "Nearly every scam starts with money sent before the item is in your hands."),
            "steps": [
                _step("Pay through escrow, always", "Never send money by M-Pesa outside BROKA, whatever "
                      "the reason given.") if settings.in_app_payments_enabled else
                _step("Pay through escrow, or once you have it", "An escrow service holds the money "
                      "until you have the item; never send a deposit first.", "escrow_services"),
                _step("Check who you're dealing with", "Rating, completed deals, the verified badge."),
                _step("Inspect before you confirm", "Meet somewhere public; confirm delivery only once "
                      "you have it."),
                _step("How BROKA protects you", "", "how_broka_works"),
            ],
        },
        "negotiate": {
            "title": "Negotiating a good price",
            "intro": "A good offer is one the other side can say yes to.",
            "steps": [
                _step("Know the market", "See what the same item goes for.", "search"),
                _step("Open with a reason", "\"Similar ones go for 70K\" beats a bare number."),
                _step("Let Zeno broker it", "In the chat, Zeno negotiates for you and keeps it civil.", "inbox"),
            ],
        },
        "find_item": {
            "title": "Getting something found for you",
            "intro": "The Buying Agent searches, compares and can keep watching.",
            "steps": [
                _step("Tell it what you want", "Rough is fine - it asks what matters.", "buying_agent"),
                _step("Pick from what it finds", "It says what each one falls short on."),
                _step("Ask it to keep watching", "It tells you the moment something new fits."),
            ],
        },
    }[guide_id] | {"id": guide_id}


async def build(db: AsyncSession, user_id: str, guide_id: str) -> Optional[dict]:
    """The guide, built for this user, or None for an id that isn't one."""
    if guide_id == "open_store":
        return await _open_store(db, user_id)
    if guide_id == "sell_faster":
        return await _sell_faster(db, user_id)
    if guide_id in available():
        return _static(guide_id)
    return None
