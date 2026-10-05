"""Paying a seller safely while BROKA moves no deal money.

With IN_APP_PAYMENTS_ENABLED off, buyers pay sellers directly. BROKA's part
is the advice and where to find an escrow service - never an endorsement:
the providers below are independent businesses BROKA has no agreement with,
and the app says so next to them. Advice comes first and leads with meeting
and inspecting, because that is what protects most buyers: an escrow
service's fee is more than most will pay on a KES 20,000 phone. Escrow is
offered for the deals where it is worth its fee - the seller is far away,
or the item is expensive.

GET /pricing/safe-payment serves it, so the list can change without an app
release. Add a provider only after checking its site and fees yourself.
"""
from __future__ import annotations

from api.core.config import settings
from fastapi import HTTPException

PAYMENTS_OFF_CODE = "IN_APP_PAYMENTS_OFF"
PAYMENTS_OFF_MESSAGE = (
    "Paying through BROKA is paused. Pay the seller directly: meet and check "
    "the item before paying, or use an escrow service for deals at a distance."
)

# Land and cars get their own lines. An M-Pesa payment tops out at
# KES 250,000 (500,000 a day), so M-Pesa escrow can't carry those deals,
# and an escrow service doesn't prove the seller owns what they sell: the
# official search does. Land brokers are the most-reported perpetrators of
# land fraud (NCRC baseline survey, 41%).
ADVICE = [
    "Meet in a busy public place and check the item works before you pay.",
    "Pay only after you have the item. Never send a deposit to 'hold' it.",
    "For a phone or laptop, check the IMEI or serial number and that it isn't locked to an account.",
    "For anything you can't collect, use an escrow service: it holds your money until you confirm you got what you paid for.",
    "Land: do an official search on Ardhisasa or eCitizen before you pay anything, check the seller's ID matches the title, and pay through an advocate or a bank. Never pay a broker in cash.",
    "Car: do an NTSA search on the logbook, match the chassis number on the car, and pay by bank at the transfer.",
    "M-Pesa can't move more than KES 250,000 in one payment, so a big deal goes through a bank or an advocate.",
    "Pay to the name on the seller's BROKA profile. A different name at the M-Pesa prompt is a warning sign.",
    "Keep the conversation and the M-Pesa message: you'll need them if you report the seller.",
]

PROVIDERS = [
    {
        "name": "Kenya Escrow",
        "url": "https://www.kenyaescrow.com",
        "note": "Holds the buyer's payment until delivery is confirmed.",
    },
    {
        "name": "E-Confirm",
        "url": "https://econfirm.co.ke",
        "note": "M-Pesa escrow for buyers and sellers.",
    },
]

DISCLAIMER = (
    "These are independent services. BROKA doesn't run them, isn't paid by "
    "them, and can't get money back from them - check their fees and terms "
    "before you pay."
)


def safe_payment_info() -> dict:
    return {
        "in_app_payments": settings.in_app_payments_enabled,
        "message": PAYMENTS_OFF_MESSAGE,
        "advice": ADVICE,
        "providers": PROVIDERS,
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


# What Zeno must know while payments are off. Appended LAST to Zeno's
# prompts, which were written for escrow ("pay through BROKA", "the buyer
# pays 4.49%"); a model follows the latest, most specific instruction, and
# one paragraph here is easier to keep true than every escrow sentence
# rewritten in two versions.
_AI_POLICY = """

CURRENT PAYMENT POLICY (this overrides anything above about escrow, BROKA's fee or paying through BROKA):
- BROKA does not handle deal payments right now. The buyer pays the seller directly; BROKA charges no commission and holds no money. Never tell anyone to pay through BROKA or into BROKA's escrow, and never quote a 4.49% or 5% fee.
- Sharing a phone number to arrange payment or a meet-up is normal now. Don't discourage it.
- Safety advice to give when payment comes up: meet in a busy public place and check the item before paying; never send a deposit to "hold" an item; for land, a car or anything at a distance, use an independent escrow service (the app lists some under "Paying safely"); they are not run by BROKA.
- Disputes: BROKA can't get money back from a direct payment. Users can still report a seller.""".rstrip()


def ai_payment_policy() -> str:
    """The paragraph above while in-app payments are off, else nothing."""
    return "" if settings.in_app_payments_enabled else _AI_POLICY
