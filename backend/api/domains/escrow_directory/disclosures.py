"""What BROKA must say, wherever it shows an escrow provider.

One place, so the app, the website and Zeno cannot drift into saying
different things about who is responsible for the money. The first
paragraph is the wording the owner specified, verbatim; do not paraphrase it
to fit a screen - shorten the screen's other text instead.
"""
from __future__ import annotations

VERSION = 1

MAIN = (
    "Broka does not operate these escrow services and does not hold, receive or release your "
    "money. The services are provided independently by their respective operators. Broka does "
    "not guarantee their performance or independently control their funds. Review the "
    "provider's current fees, conditions, refund policy and dispute procedures before paying."
)

# Said alongside MAIN where there is room (the detail screen, the website).
POINTS = [
    "Each provider has its own terms and privacy policy. Read them before you use it.",
    "When you use a provider you enter into a separate agreement with it, not with Broka.",
    "A provider's protection applies only according to that provider's own rules.",
    "Broka cannot guarantee that a dispute will end in a refund.",
    "Open the provider's official website yourself, or follow Broka's exact approved https "
    "link. Never use a link, paybill, till or phone number someone sends you in a chat.",
]

# What a provider's page says about BROKA's part - section 11 of the detail
# screen. "Independent referral": BROKA points at providers; it is not paid
# by them, does not process the payment and cannot reverse one.
RELATIONSHIP = [
    "Broka is not a party to your transaction with the provider and has no control over its "
    "funds.",
    "Broka lists providers to help you compare them. A listing is information, not a "
    "recommendation and not a promise about how the provider will behave.",
    "Broka cannot recover money held by, or sent through, a provider, and cannot decide a "
    "dispute that the provider is handling.",
    "Details are taken from the provider's own public pages and checked by Broka on the date "
    "shown. Providers can change them at any time: the provider's own checkout is the "
    "authority on what you will pay.",
]

# The sentence beside any number BROKA calculates.
ESTIMATE = (
    "An estimate from the provider's published pricing. The quotation on the provider's own "
    "checkout is the amount you actually pay."
)

# The text a buyer or seller who thinks they have been defrauded needs first.
INCIDENT_STEPS = [
    "Stop: do not send more money, and do not hand over the goods, if you still can.",
    "Keep everything: the chat, phone numbers, M-Pesa messages, receipts and transaction IDs.",
    "Contact the escrow provider yourself, on the contact details on its official website.",
    "Report it to Broka from the app so the team can review the account involved.",
    "If you sent money through a payment route you now think was fraudulent, contact that "
    "payment provider (for example Safaricom for M-Pesa) straight away.",
    "If you believe a crime was committed, report it to the police.",
]
INCIDENT_LIMIT = (
    "Broka cannot promise to recover money that was sent to a provider or to another person."
)


def as_dict() -> dict:
    return {"version": VERSION, "main": MAIN, "points": list(POINTS),
            "relationship": list(RELATIONSHIP), "estimate": ESTIMATE}
