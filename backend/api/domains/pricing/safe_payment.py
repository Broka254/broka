"""Paying a seller safely while BROKA moves no deal money.

With IN_APP_PAYMENTS_ENABLED off, buyers pay sellers directly. No escrow
provider's API can carry BROKA's own payments end to end yet, so for launch
BROKA points buyers and sellers at Kenya's independent escrow services and
Zeno walks them through using one, step by step (zeno_assistant/
escrow_walkthrough.py). Escrow comes first (the owner's call, 2026-10-08):
it is the one way a buyer who can't see the item first is protected, and
the app puts it in front of every deal. Meeting and inspecting is the
advice for everything collected in person.

BROKA's part is the list and the guidance - never an endorsement. The
providers are independent businesses BROKA has no agreement with, and the
app says so next to them, every time: a buyer who thinks BROKA stands
behind a provider will blame BROKA when it fails them.

GET /pricing/safe-payment serves it, so the list can change without an app
release. The PROVIDERS THEMSELVES are not in this file any more (2026-11): the
one authoritative list is the escrow_directory catalogue - each provider's
fees, limits and protection process, who confirmed them and when, whether it
is listed, under review or suspended. This file keeps the advice and the
rules, and presents the catalogue in the shape older app builds read.

The old list here was typed from memory of each provider's site, could not be
corrected without a release, and had no way to say "suspended". It named
escrowkenya.com as an active service. Add or change a provider through the
admin endpoints (ESCROW_PROVIDERS.md), never here.
"""
from __future__ import annotations

from api.core.config import settings
from api.domains.escrow_directory import catalogue, projection
from api.domains.zeno_assistant import fraud_guidance
from fastapi import HTTPException

PAYMENTS_OFF_CODE = "IN_APP_PAYMENTS_OFF"
PAYMENTS_OFF_MESSAGE = (
    "BROKA doesn't take payments itself yet. Pay safely with an escrow "
    "service - Zeno can walk you through it - or meet and check the item "
    "before you pay."
)

# Land and cars get their own lines. An M-Pesa payment tops out at
# KES 250,000 (500,000 a day), so M-Pesa escrow can't carry those deals,
# and an escrow service doesn't prove the seller owns what they sell: the
# official search does. Land brokers are the most-reported perpetrators of
# land fraud (NCRC baseline survey, 41%).
ADVICE = [
    "Can't see the item before you pay? Use an escrow service: it holds your money until you confirm you got what you paid for.",
    "Collecting in person? Meet in a busy public place and check the item works before you pay.",
    "Never send a deposit to 'hold' an item, whatever the reason given.",
    "For a phone or laptop, check the IMEI or serial number and that it isn't locked to an account.",
    "Land: do an official search on Ardhisasa or eCitizen before you pay anything, check the seller's ID matches the title, and pay through an advocate or a bank. Never pay a broker in cash.",
    "Car: do an NTSA search on the logbook, match the chassis number on the car, and pay by bank at the transfer - or through a vehicle escrow that takes bank transfers.",
    "M-Pesa can't move more than KES 250,000 in one payment, so a big deal goes through a bank, an advocate, or an escrow service that takes bank transfers.",
    "Pay to the name on the seller's BROKA profile. A different name at the M-Pesa prompt is a warning sign.",
    "Keep the conversation and the M-Pesa message: you'll need them if you report the seller.",
]

# The rules that make an escrow service protect anyone. The first is the
# one fraudsters exploit: a "seller" who sends their own escrow link runs
# the fake site it opens, and it looks real (escrow fraud's commonest form).
ESCROW_RULES = [
    "Open the escrow service yourself from BROKA's list. Never use an escrow link, paybill or 'agent' the other person sends you - fake escrow sites are a common scam, and they look real.",
    "Buyers: pay the escrow service, never the seller. The M-Pesa prompt or paybill should name the service, not a person.",
    "Sellers: hand over nothing on a screenshot or an SMS. Check on the escrow service itself that the money is held - fake M-Pesa messages are easy to make.",
    "Release the money only once you have the item and it is what you agreed. Never share a release code with anyone, the seller included.",
    "Agree in the BROKA chat which service you'll use, and who pays its fee. It's your record if anything goes wrong.",
]

# How escrow works, whichever service: the four beats the app draws.
HOW_ESCROW_WORKS = [
    {"title": "Agree the deal", "detail": "Price, what's included, delivery - and the escrow service you'll use."},
    {"title": "The buyer pays the escrow service", "detail": "Not the seller. The service holds the money."},
    {"title": "The seller delivers", "detail": "Once the service shows the money is held. The buyer checks the item."},
    {"title": "The buyer releases the money", "detail": "The service pays the seller. A problem? It decides a dispute."},
]

def providers() -> list[dict]:
    """The providers BROKA lists, in the flat shape older app builds read
    (id, name, url, note, tagline, best_for, pay, fees, limits, start,
    release, payout, dispute, company), plus status and review_label. From
    the catalogue as last loaded; suspended, rejected and draft providers
    are not in it."""
    return [projection.legacy_view(r) for r in catalogue.listed(catalogue.current_records())]


DISCLAIMER = (
    "Broka does not operate these escrow services and does not hold, receive or release your "
    "money. The services are provided independently by their respective operators. Broka does "
    "not guarantee their performance or independently control their funds. Review the "
    "provider's current fees, conditions, refund policy and dispute procedures before paying."
)

ZENO_HELP = (
    "Not sure how? Zeno walks you through it, one step at a time - which "
    "service to pick, how to pay in, and when it's safe to release the money."
)


def safe_payment_info() -> dict:
    return {
        "in_app_payments": settings.in_app_payments_enabled,
        "message": PAYMENTS_OFF_MESSAGE,
        "advice": ADVICE,
        "escrow_rules": ESCROW_RULES,
        "how_escrow_works": HOW_ESCROW_WORKS,
        "providers": providers(),
        "zeno_help": ZENO_HELP,
        "disclaimer": DISCLAIMER,
    }


def require_in_app_payments() -> None:
    """Dependency for every route that starts moving a buyer's money.

    A 409 rather than a 404 so older app builds, which still show a pay
    button, get a message they can show (ApiClient reads `message` and
    `code` from a structured detail) instead of a broken screen.
    """
    if not settings.in_app_payments_enabled:
        raise HTTPException(status_code=409, detail={
            "code": PAYMENTS_OFF_CODE,
            "message": PAYMENTS_OFF_MESSAGE,
        })


def _provider_lines() -> str:
    return "\n".join(
        f"  - {p['name']} ({p['url']}): Pay in: {p['pay']}. Fees: {p['fees']} Limits: {p['limits']}."
        + ("" if p["verified"] else " (Broka has not finished reviewing it: say so when you name it.)")
        for p in providers()
    )


# What Zeno must know while payments are off. Appended LAST to Zeno's
# prompts, which were written for escrow ("pay through BROKA", "the buyer
# pays 4.49%"); a model follows the latest, most specific instruction, and
# one paragraph here is easier to keep true than every escrow sentence
# rewritten in two versions. Auctions are in it because those prompts
# describe them too, and none can be held while they are off.
def _ai_policy() -> str:
    auctions = "" if settings.auctions_enabled else (
        "\n- BROKA has no auctions right now: never offer, suggest or describe one. To sell, a "
        "seller lists a direct sale and buyers make offers.")
    # While the app hides payments (ESCROW_GUIDANCE_ENABLED off) there is no
    # "Pay with escrow" button to send anyone to, and escrow isn't pushed at
    # every agreed price - but someone who asks still gets the safe list.
    escrow = f"""- The safe way to pay a seller you can't meet is an independent escrow service from the app's list - the only ones to recommend:
{_provider_lines()}
  They are not run by BROKA. Never recommend any other escrow service, and never one the other party suggests or sends a link for: fake escrow sites are a common scam.
- When a price is agreed or payment comes up, recommend escrow and say Zeno will walk them through it step by step: they tap "Pay with escrow" in the chat, or ask Zeno "walk me through escrow".""" if settings.escrow_guidance_enabled else f"""- When a price is agreed or payment comes up, the buyer pays the seller directly: advise checking the item first. Don't bring up escrow yourself, and never mention an escrow button - the app has none. If the user asks about escrow, these independent services exist - the only ones to name:
{_provider_lines()}
  They are not run by BROKA. Never name any other escrow service, and never one the other party suggests or sends a link for: fake escrow sites are a common scam."""
    return f"""

CURRENT PAYMENT POLICY (this overrides anything above about escrow, BROKA's fee or paying through BROKA):
- BROKA does not handle deal payments right now. The buyer pays the seller directly; BROKA charges no commission and holds no money. Never tell anyone to pay through BROKA or into BROKA's escrow, and never quote a 4.49% or 5% fee.
{escrow}
- Sharing a phone number to arrange payment or a meet-up is normal now. Don't discourage it.
- Collecting in person: meet in a busy public place and check the item before paying; never send a deposit to "hold" an item. Land: an official search and an advocate. A car: an NTSA search, then a bank at the transfer or a vehicle escrow.
- Disputes: BROKA can't get money back from a direct payment; an escrow service decides its own disputes. Users can still report a seller.{auctions}""".rstrip()


def ai_payment_policy() -> str:
    """The paragraph above while in-app payments are off, else nothing
    (with auctions off, just the line about them)."""
    if settings.in_app_payments_enabled:
        return "" if settings.auctions_enabled else (
            "\n\nAUCTIONS: BROKA has no auctions right now - never offer, suggest or describe one.")
    return _ai_policy()


def fraud_prevention_policy() -> str:
    """Zeno's fraud-prevention instructions, with the providers it may talk
    about and the only facts it may state, built from the catalogue now.

    Separate from ai_payment_policy() on purpose: that one is about WHO
    HOLDS THE MONEY and goes away when BROKA takes payments again; this one
    is about not being robbed, and is true in every configuration. It is
    appended after the payment policy wherever Zeno is prompted."""
    return fraud_guidance.fraud_policy(catalogue.current_records())
