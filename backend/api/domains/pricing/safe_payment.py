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
release. Every fact about a provider below is what that provider publishes
about itself (checked 2026-10-08); where it publishes no fee or limit the
entry says to check, rather than guess. Add or change a provider only after
checking its own site. Two names are easily confused - Escrow Kenya
(escrowkenya.com) and Kenya Escrow (kenyaescrow.com) are different
companies - so each entry says so.
"""
from __future__ import annotations

from api.core.config import settings
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

# Each provider, as it describes itself. `note` is what older app builds
# show under the name; the rest is what the escrow screen and Zeno's
# walkthrough use:
#   pay      how the buyer pays in
#   start    how a deal is set up on it
#   release  how the buyer lets the money go to the seller
#   payout   how the seller receives it, said to the seller
#   dispute  what happens when something goes wrong, a sentence of its own
#   fees / limits  as published - or "check" where nothing is
PROVIDERS = [
    {
        "id": "econfirm",
        "name": "E-Confirm",
        "url": "https://econfirm.co.ke",
        "note": "M-Pesa escrow for buyers and sellers: the money is held until both of you confirm.",
        "tagline": "M-Pesa escrow for most deals",
        "best_for": "Most deals paid by M-Pesa, up to KES 500,000.",
        "pay": "an M-Pesa prompt on your phone (STK push)",
        "fees": "A commission on top of the amount, shown in its calculator before you pay.",
        "limits": "It takes KES 100 to 500,000 a deal.",
        "start": "Tap Start Escrow, enter the amount and the deal's details, and follow its steps.",
        "release": "approve the release with the one-time code E-Confirm sends you. Never share that code with anyone - the seller included.",
        "payout": "E-Confirm pays you by M-Pesa once the release is approved.",
        "dispute": "The money stays held, and E-Confirm's dispute team decides whether it is refunded.",
        "company": "Confirm Diligence Solutions Ltd",
    },
    {
        "id": "escrowkenya",
        "name": "Escrow Kenya",
        "url": "https://escrowkenya.com",
        "note": "Escrow with an account and an invoice; pay by M-Pesa or bank. Not the same company as Kenya Escrow.",
        "tagline": "Bigger deals, cars and brokers",
        "best_for": "Bigger deals, cars, and deals with a broker in the middle - it takes bank transfers too.",
        "pay": "the Pay Now button on its invoice - an M-Pesa prompt, the paybill printed on the invoice, or a bank transfer (PesaLink)",
        "fees": "3% of the price (at least KES 200, at most KES 15,000); vehicles 1.5% (at least KES 1,500). You choose who pays it - buyer, seller, or half each.",
        "limits": "M-Pesa carries up to KES 250,000 a payment; above that, pay by bank transfer.",
        "start": "Create an account and fill in the order form: the item, the price, and the other person's email and phone. They get an email and an SMS to accept the deal.",
        "release": "approve the release from your Escrow Kenya account.",
        "payout": "you withdraw it to M-Pesa or a bank - usually within about 20 minutes during support hours.",
        "dispute": "The money stays held while Escrow Kenya looks at what each of you shows it.",
        "company": "",
    },
    {
        "id": "kenyaescrow",
        "name": "Kenya Escrow",
        "url": "https://www.kenyaescrow.com",
        "note": "M-Pesa escrow with no account to create: your number is checked by SMS. Not the same company as Escrow Kenya.",
        "tagline": "Quick M-Pesa escrow, no sign-up",
        "best_for": "A quick deal with no sign-up; it also holds car payments until the logbook is transferred.",
        "pay": "M-Pesa",
        "fees": "It says paying in by M-Pesa is free, with a small fee for holding the money and for disputes - check it for your amount before you pay.",
        "limits": "Check its limit for your amount on the site.",
        "start": "Start a deal with the amount and the details. It checks your phone number with a Safaricom SMS - there's no account to create.",
        "release": "mark the order complete - Kenya Escrow pays the seller straight away.",
        "payout": "you're paid as soon as the buyer marks the order complete.",
        "dispute": "Contact Kenya Escrow before the order is marked complete - it holds the money while the dispute is settled.",
        "company": "",
    },
    {
        "id": "lipasafe",
        "name": "Lipasafe",
        "url": "https://lipasafe.co.ke",
        "note": "M-Pesa escrow for goods and services; every user is ID-checked.",
        "tagline": "Everyone ID-checked",
        "best_for": "Goods and services - a fundi's job too - with everyone ID-checked.",
        "pay": "M-Pesa - the money is locked in escrow, not sent to the seller",
        "fees": "Check its fee for your amount on the site before you pay.",
        "limits": "Check its limit for your amount on the site.",
        "start": "Sign up and verify your ID (Lipasafe checks every user), then create the deal with the amount and the other person's details.",
        "release": "confirm on Lipasafe that you got it - the money goes to the seller's M-Pesa at once.",
        "payout": "the money goes to your M-Pesa as soon as the buyer confirms.",
        "dispute": "Lipasafe's dispute team steps in - upload anything that shows what was agreed.",
        "company": "",
    },
    {
        "id": "shikilia",
        "name": "Shikilia",
        "url": "https://www.shikilia.co.ke",
        "note": "Escrow that runs on WhatsApp: pay by M-Pesa, confirm delivery with a QR code.",
        "tagline": "Escrow on WhatsApp",
        "best_for": "Deals arranged on WhatsApp - it works with any WhatsApp number.",
        "pay": "an M-Pesa prompt on your phone; the seller gets a WhatsApp message that the money is held",
        "fees": "No monthly fee - a fee per deal, shown before you pay.",
        "limits": "Check its limit for your amount on the site.",
        "start": "Start the deal on Shikilia with your WhatsApp number - it's free to register.",
        "release": "confirm delivery with the QR code Shikilia sends you on WhatsApp.",
        "payout": "you're paid out once the buyer confirms delivery.",
        "dispute": "Shikilia says it settles disputes within 48 hours, and refunds the buyer if the seller goes silent.",
        "company": "",
    },
]

PROVIDERS_BY_ID = {p["id"]: p for p in PROVIDERS}

DISCLAIMER = (
    "These are independent services. BROKA doesn't run them, isn't paid by "
    "them, and can't get money back from them. Fees and limits are as each "
    "one publishes them - check on its own site before you pay."
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
        "providers": PROVIDERS,
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
        f"  - {p['name']} ({p['url']}): {p['best_for']} Pay in: {p['pay']}. Fees: {p['fees']} "
        f"Limits: {p['limits']}"
        for p in PROVIDERS
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
    return f"""

CURRENT PAYMENT POLICY (this overrides anything above about escrow, BROKA's fee or paying through BROKA):
- BROKA does not handle deal payments right now. The buyer pays the seller directly; BROKA charges no commission and holds no money. Never tell anyone to pay through BROKA or into BROKA's escrow, and never quote a 4.49% or 5% fee.
- The safe way to pay a seller you can't meet is an independent escrow service from the app's list - the only ones to recommend:
{_provider_lines()}
  They are not run by BROKA. Never recommend any other escrow service, and never one the other party suggests or sends a link for: fake escrow sites are a common scam.
- When a price is agreed or payment comes up, recommend escrow and say Zeno will walk them through it step by step: they tap "Pay with escrow" in the chat, or ask Zeno "walk me through escrow".
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
