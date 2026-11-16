"""The providers BROKA starts with: research inputs, not approvals.

Everything here is what the product owner's preliminary research found on
each provider's own public pages (2026-11), written the way it should be
shown: attributed ("its terms say..."), never as BROKA's own claim. Three
rules held while writing it:

  1. NOTHING IS APPROVED. All four live providers start `under_review`,
     with every review "pending" and no verification date. A date here
     would claim someone had checked a page; nobody has. The first date a
     provider gets is the day an administrator verifies it
     (POST /admin/escrow-providers/{id}/review).
  2. A BLANK IS A BLANK. Where the research gave no figure or rule the
     field is None, and the app says "not documented - check with the
     provider". Nothing is filled in from memory or from another provider.
  3. THE SEED NEVER OVERRIDES A REVIEWED RECORD. A provider's row in the
     database, once an administrator has edited it, wins over this file
     (catalogue.py). Fixing a typo here does not silently change a fee a
     person has already signed off.

`escrowkenya.com` is here only as SUSPENDED, so it is recognised, never
recommended, and never confused with kenyaescrow.com.
"""
from __future__ import annotations

import copy

# Provider domains this deployment accepts by default. The deployment's
# ESCROW_PROVIDER_DOMAINS setting replaces it (config.py); a test keeps the
# two in step.
DEFAULT_PROVIDER_DOMAINS = (
    "econfirm.co.ke",
    "kenyaescrow.com",
    "lipasafe.co.ke",
    "shikilia.co.ke",
    "escrowkenya.com",
)

_KENYA_ESCROW_BANDS = [
    # (min, max, percent, fixed) - KSh the seller receives. Verbatim from
    # https://kenyaescrow.com/pricing as recorded in the research brief.
    (50, 100, "10", "10"),
    (101, 500, "10", "19"),
    (501, 1000, "6", "40"),
    (1001, 5000, "5.4", "46"),
    (5001, 10000, "4.7", "81"),
    (10001, 25000, "4", "151"),
    (25001, 50000, "3.7", "226"),
    (50001, 100000, "3.3", "440"),
    (100001, 150000, "2.8", "955"),
    (150001, 200000, "2.65", "1190"),
    (200001, 240000, "0.3", "5905"),
]


def _trust(sources: list[dict], notes: str) -> dict:
    return {
        "identity_verification": "pending",
        "terms_review": "pending",
        "pricing_review": "pending",
        "operational_test": "not_started",
        "last_verified": None,
        "next_review": None,
        "sources": sources,
        "internal_notes": notes,
        "reviewed_by": None,
    }


def _blank_protection() -> dict:
    return {
        "how_funds_are_held": None,
        "when_funds_locked": None,
        "release_conditions": None,
        "auto_release": {"can_occur": None, "description": None},
        "confirmation_window": None,
        "buyer_protection": None,
        "seller_protection": None,
        "dispute_initiation": None,
        "evidence_required": None,
        "dispute_timeframe": None,
        "refund_conditions": None,
        "cancellation_policy": None,
        "deposit_insurance": None,
        "notable_terms": [],
    }


def _econfirm() -> dict:
    protection = _blank_protection()
    protection.update(
        dispute_initiation=("Its terms describe escrow, transaction disputes and complaint handling. "
                            "Read them for how a dispute is opened and how long it takes."),
        notable_terms=["Its terms describe the platform as a fully functional beta."],
    )
    return {
        "id": "econfirm",
        "display_name": "eConfirm",
        "status": "under_review",
        "tagline": "M-Pesa escrow · commission plus payout reserve",
        "identity": {
            "legal_entity_name": "Confirm Delegence Solutions",
            "legal_entity_confirmed": False,
            "operator_note": ("Its terms name Confirm Delegence Solutions as the operator. BROKA has "
                              "not yet confirmed the company's exact registered name."),
            "website_url": "https://econfirm.co.ke/",
            "canonical_domain": "econfirm.co.ke",
            "contact_email": None,
            "contact_phone": None,
            "terms_url": "https://econfirm.co.ke/terms-and-conditions",
            "privacy_url": None,
            "countries": ["KE"],
            "confusable_with": [],
            "logo_url": None,
        },
        "pricing": {
            "disclosure": "published_percentage",
            "currency": "KES",
            "basis": "transaction_value",
            # The 1% is the platform commission ONLY. The brief is explicit:
            # never present it as the total fee. The payout reserve below
            # is a separate charge.
            "commission": {"label": "Platform commission", "payer": "not_stated", "percent": "1"},
            "processing_fees": [],
            "payout_fees": [{
                "label": "Estimated M-Pesa payout reserve",
                "payer": "not_stated",
                "estimated": True,
                # Phone payout and till payout have different bands on its
                # tariffs page. The bands were not in the research brief and
                # the page could not be read, so none are loaded: the
                # calculator shows the commission and withholds a total.
                "documented": False,
                "by_destination": {"phone": {}, "till": {}},
            }],
            "absorbs_mpesa_fees": False,
            "additional_fees_may_apply": None,
            "source_url": "https://econfirm.co.ke/tariffs",
            "quote_url": "https://econfirm.co.ke/",
            "last_verified": None,
            "public_note": ("The 1% is the platform commission only, not the total fee. An estimated "
                            "M-Pesa payout reserve is charged as well, and it differs for a payout to "
                            "a phone and a payout to a till."),
        },
        "conditions": {
            "min_amount": 100,
            "max_amount": 500000,
            "amount_basis": "transaction_value",
            "payment_methods": ["mpesa_stk_push"],
            "payout_methods": ["mpesa_phone", "mpesa_till"],
            "registration_required": None,
            "kyc_required": None,
            "categories": None,
            "regions": None,
            "other": ["Its website advertises transaction values from KSh 100 to KSh 500,000."],
        },
        "protection": protection,
        "trust": _trust(
            [{"label": "Tariffs", "url": "https://econfirm.co.ke/tariffs"},
             {"label": "Terms and conditions", "url": "https://econfirm.co.ke/terms-and-conditions"}],
            "Research input only; nothing verified.\n"
            "- Operator name: the brief says 'Confirm Delegence Solutions'. This repository's earlier "
            "list (pricing/safe_payment.py) said 'Confirm Diligence Solutions Ltd'. Read the terms page "
            "and check the business registry; correct this field and tick legal_entity_confirmed.\n"
            "- Payout reserve: phone and till bands are NOT loaded (not in the brief; the tariffs page "
            "could not be fetched from the build sandbox). Load them from the tariffs page with "
            "documented=true, by_destination.phone and .till, and source_url, then verify pricing.\n"
            "- Who pays the commission and the reserve (buyer, seller, either) is not stated in the "
            "research. BROKA's earlier E-Confirm integration treated the 1% as added on top for the "
            "buyer; that is not evidence of what the provider publishes.\n"
            "- Its terms call the platform a 'fully functional beta': shown to users as a risk note.\n"
            "- additional_fees_may_apply is unknown; until it is confirmed false this provider is never "
            "ranked on total fee."),
    }


def _kenya_escrow() -> dict:
    protection = _blank_protection()
    protection.update(
        release_conditions="Its site describes release as controlled by the buyer.",
        dispute_initiation=("Its site advertises a dispute process that is reviewed by people. How a "
                            "dispute is opened is not recorded here: check its FAQ."),
    )
    return {
        "id": "kenyaescrow",
        "display_name": "Kenya Escrow",
        "status": "under_review",
        "tagline": "M-Pesa escrow · no account needed · fee bands published",
        "identity": {
            "legal_entity_name": None,
            "legal_entity_confirmed": False,
            "operator_note": ("The company that operates this service has not yet been independently "
                              "confirmed."),
            "website_url": "https://kenyaescrow.com/",
            "canonical_domain": "kenyaescrow.com",
            "contact_email": None,
            "contact_phone": None,
            "terms_url": None,
            "privacy_url": None,
            "countries": ["KE"],
            # The two names are easy to confuse and are different websites.
            "confusable_with": [{
                "name": "Escrow Kenya",
                "domain": "escrowkenya.com",
                "note": "A different website. BROKA does not list it. Check the address before you pay.",
            }],
            "logo_url": None,
        },
        "pricing": {
            "disclosure": "published_tiered",
            "currency": "KES",
            "basis": "seller_receives",
            "commission": {
                "label": "Escrow fee (percentage plus fixed charge, by amount)",
                "payer": "buyer",
                "tiers": [{"min": lo, "max": hi, "percent": pct, "fixed": fx}
                          for lo, hi, pct, fx in _KENYA_ESCROW_BANDS],
            },
            "processing_fees": [],
            "payout_fees": [],
            "absorbs_mpesa_fees": True,
            "additional_fees_may_apply": None,
            "source_url": "https://kenyaescrow.com/pricing",
            "quote_url": "https://kenyaescrow.com/pricing",
            "last_verified": None,
            "public_note": ("The fee is the seller's amount times the percentage for its band, plus a "
                            "fixed charge. Its pricing page says users pay no additional M-Pesa "
                            "transaction charge."),
        },
        "conditions": {
            "min_amount": 50,
            "max_amount": 240000,
            "amount_basis": "seller_receives",
            "payment_methods": ["mpesa_stk_push"],
            "payout_methods": None,
            "registration_required": False,
            "kyc_required": None,
            "categories": None,
            "regions": None,
            "other": ["No account is required.",
                      "It sends SMS and WhatsApp notifications."],
        },
        "protection": protection,
        "trust": _trust(
            [{"label": "Pricing", "url": "https://kenyaescrow.com/pricing"},
             {"label": "FAQ", "url": "https://kenyaescrow.com/faq"}],
            "Research input only; nothing verified.\n"
            "- NEVER confuse kenyaescrow.com with escrowkenya.com (suspended). Check every link.\n"
            "- Legal operator not identified: find it in the terms/privacy pages or the registry, then "
            "set legal_entity_name and legal_entity_confirmed.\n"
            "- Fee bands are exactly as in the brief. Continuity check: at each band's first amount, "
            "this band's own formula minus the previous band's formula, in KSh, unrounded: "
            "101 +9.00; 501 +0.96; 1,001 -0.01; 5,001 -0.01; 10,001 -0.01; 25,001 -0.00; "
            "50,001 +14.00; 100,001 +15.00; 150,001 +10.00; 200,001 +14.98. A difference near "
            "zero means the two bands meet. The other six (101, 501 and the four from 50,001) do "
            "not, and may be deliberate M-Pesa step costs or transcription slips: compare every "
            "one against the live pricing page before approving.\n"
            "- Earlier BROKA research (2026-10) mentioned a small fee for disputes. If a dispute or "
            "holding fee exists, additional_fees_may_apply must be true and totals are not comparable.\n"
            "- Terms and privacy URLs, contact details and dispute timeframe were not in the brief."),
    }


def _lipasafe() -> dict:
    protection = _blank_protection()
    protection.update(
        how_funds_are_held=("It states that it holds the funds until the agreed release conditions "
                            "are met."),
        auto_release={"can_occur": True,
                      "description": ("It states that funds may be released automatically when the "
                                      "confirmation period ends without a dispute.")},
        dispute_initiation="Its terms describe evidence-based dispute resolution.",
        deposit_insurance=("It states that funds are not represented as bank deposits and are not "
                           "covered by deposit insurance."),
    )
    return {
        "id": "lipasafe",
        "display_name": "Lipasafe",
        "status": "under_review",
        "tagline": "M-Pesa escrow · account and ID check required",
        "identity": {
            "legal_entity_name": "Holda Fintech Technologies Limited",
            "legal_entity_confirmed": False,
            "operator_note": ("Its terms name Holda Fintech Technologies Limited as the operator. "
                              "BROKA has not yet confirmed this independently."),
            "website_url": "https://lipasafe.co.ke/",
            "canonical_domain": "lipasafe.co.ke",
            "contact_email": None,
            "contact_phone": None,
            "terms_url": "https://lipasafe.co.ke/terms",
            "privacy_url": None,
            "countries": ["KE"],
            "confusable_with": [],
            "logo_url": None,
        },
        "pricing": {
            "disclosure": "quote_required",
            "currency": "KES",
            "basis": "not_stated",
            "commission": None,
            "processing_fees": [],
            "payout_fees": [],
            "absorbs_mpesa_fees": None,
            "additional_fees_may_apply": None,
            "source_url": "https://lipasafe.co.ke/terms",
            "quote_url": "https://lipasafe.co.ke/",
            "last_verified": None,
            "public_note": ("It states that fees, including the escrow and payout charges, are shown "
                            "inside its app before you confirm. No rate is published, so BROKA "
                            "does not estimate one."),
        },
        "conditions": {
            "min_amount": None,
            "max_amount": None,
            "amount_basis": "not_stated",
            "payment_methods": ["mpesa"],
            "payout_methods": None,
            "registration_required": True,
            "kyc_required": True,
            "categories": None,
            "regions": None,
            "other": [],
        },
        "protection": protection,
        "trust": _trust(
            [{"label": "Terms", "url": "https://lipasafe.co.ke/terms"}],
            "Research input only; nothing verified.\n"
            "- Commission: do not invent a rate. Display 'Check live quotation in Lipasafe before "
            "paying' until its pricing schedule is independently confirmed (the owner's instruction).\n"
            "- Operator name taken from its terms; confirm against the registry.\n"
            "- Limits, payout methods, confirmation period length, dispute timeframe, refund rules and "
            "contact details were not in the brief."),
    }


def _shikilia() -> dict:
    protection = _blank_protection()
    protection.update(
        release_conditions="Its website describes delivery being confirmed with a QR code.",
        buyer_protection="Its website describes a 24-hour buyer protection window.",
        dispute_timeframe="Its website advertises a dispute review within 24 to 48 hours.",
    )
    return {
        "id": "shikilia",
        "display_name": "Shikilia",
        "status": "under_review",
        "tagline": "M-Pesa escrow on WhatsApp",
        "identity": {
            "legal_entity_name": None,
            "legal_entity_confirmed": False,
            "operator_note": ("Its homepage names Jeno-tech Solutions and Jo-Jo Mani Investment "
                              "Limited, and its footer identifies Jo-Jo Mani Investment Ltd and "
                              "refers to Travel Pay and Jeno-Tech. Which company is responsible for "
                              "the escrow transaction has not been confirmed."),
            "website_url": "https://www.shikilia.co.ke/",
            "canonical_domain": "shikilia.co.ke",
            "contact_email": None,
            "contact_phone": None,
            "terms_url": None,
            "privacy_url": None,
            "countries": ["KE"],
            "confusable_with": [],
            "logo_url": None,
        },
        "pricing": {
            "disclosure": "not_disclosed",
            "currency": "KES",
            "basis": "not_stated",
            "commission": None,
            "processing_fees": [],
            "payout_fees": [],
            "absorbs_mpesa_fees": None,
            "additional_fees_may_apply": None,
            "source_url": "https://www.shikilia.co.ke/checkout",
            "quote_url": "https://www.shikilia.co.ke/checkout",
            "last_verified": None,
            "public_note": ("Its website advertises no monthly fee and a per-transaction fee. No "
                            "percentage or fixed charge is published, so BROKA does not estimate one."),
        },
        "conditions": {
            "min_amount": 10,
            "max_amount": None,
            "amount_basis": "not_stated",
            "payment_methods": ["mpesa"],
            "payout_methods": None,
            "registration_required": None,
            "kyc_required": None,
            "categories": None,
            "regions": None,
            "other": ["The deal runs on WhatsApp.",
                      "Its checkout currently shows a KSh 10 minimum."],
        },
        "protection": protection,
        "trust": _trust(
            [{"label": "Checkout", "url": "https://www.shikilia.co.ke/checkout"},
             {"label": "Protection", "url": "https://www.shikilia.co.ke/protection"}],
            "Research input only; nothing verified.\n"
            "- The responsible legal entity is unresolved: homepage and footer name different "
            "companies. Do not approve until the entity responsible for the escrow transaction is "
            "confirmed from its terms and the registry.\n"
            "- shikilia.com is an unrelated project (a cash-transfer programme); only shikilia.co.ke is "
            "this provider.\n"
            "- Fee: not publicly specified. Display 'Fee not publicly specified - confirm before "
            "paying' (the owner's instruction). Do not infer one.\n"
            "- An earlier BROKA list said it 'refunds the buyer if the seller goes silent'. That is NOT "
            "in the current research and has not been carried over; confirm from its terms before "
            "saying it."),
    }


def _escrowkenya() -> dict:
    return {
        "id": "escrowkenya",
        "display_name": "Escrow Kenya",
        "status": "suspended",
        "tagline": None,
        "identity": {
            "legal_entity_name": None,
            "legal_entity_confirmed": False,
            "operator_note": None,
            "website_url": "https://escrowkenya.com/",
            "canonical_domain": "escrowkenya.com",
            "contact_email": None,
            "contact_phone": None,
            "terms_url": None,
            "privacy_url": None,
            "countries": None,
            "confusable_with": [{
                "name": "Kenya Escrow",
                "domain": "kenyaescrow.com",
                "note": "A different website.",
            }],
            "logo_url": None,
        },
        "pricing": {
            "disclosure": "under_review",
            "currency": "KES",
            "basis": "not_stated",
            "commission": None,
            "processing_fees": [],
            "payout_fees": [],
            "absorbs_mpesa_fees": None,
            "additional_fees_may_apply": None,
            "source_url": None,
            "quote_url": None,
            "last_verified": None,
            "public_note": None,
        },
        "conditions": {
            "min_amount": None, "max_amount": None, "amount_basis": "not_stated",
            "payment_methods": None, "payout_methods": None, "registration_required": None,
            "kyc_required": None, "categories": None, "regions": None, "other": [],
        },
        "protection": _blank_protection(),
        "trust": _trust(
            [],
            "SUSPENDED per the product owner's brief ('the previously suspended escrowkenya.com'). "
            "No incident record, date or reason exists in this repository: attach the original "
            "decision here when it is found. Earlier BROKA releases listed this provider as active "
            "(pricing/safe_payment.py, the app's offline list, web/src/lib/safety.ts); those lists "
            "are removed. Do not reinstate except through review."),
        # Neutral on purpose: it says what BROKA lists, not why. A statement
        # about a company's conduct needs evidence BROKA has not published.
        "public_notice": ("Escrow Kenya (escrowkenya.com) is not on Broka's list. It is a different "
                          "website from Kenya Escrow (kenyaescrow.com)."),
    }


def records() -> list[dict]:
    """A fresh copy of every seed record. Callers may modify the result."""
    return copy.deepcopy([_econfirm(), _kenya_escrow(), _lipasafe(), _shikilia(), _escrowkenya()])
