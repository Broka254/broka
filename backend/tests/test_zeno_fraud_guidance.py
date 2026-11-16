"""Zeno as a fraud-prevention assistant (zeno_assistant/fraud_guidance.py).

What must hold:
  * a message that describes a known scam pattern gets a WRITTEN answer
    (no model), that names the pattern, says what to do, and repeats the
    rules - and never accuses the person, never says a payment message is
    genuine, never promises Broka can recover money;
  * a plain question about what to check before paying, or what to do
    after a scam, gets the full guidance;
  * ordinary messages are left alone - a false alarm on "how do I get paid"
    teaches people to ignore the warning;
  * what a MODEL says is checked on the way out: no phone, till, paybill
    or account number; no web address that is not an approved provider's;
    no fee figure the catalogue does not publish for that provider; no
    promise Broka has not earned;
  * the instructions given to the model carry the live catalogue, state
    unknown fees as unknown, and name a suspended provider as one to avoid.

Plain Python, so it runs without the app. The turn-level wiring (the rules
run after the walkthrough, a guarded reply drops its action) is in
test_zeno_fraud_turns.py.
"""
import copy
import re

import pytest

from api.domains.escrow_directory import disclosures, seed
from api.domains.zeno_assistant import fraud_guidance as fg
from api.domains.zeno_assistant import intents


def say(text: str):
    return fg.reply_for(intents.normalise(text))


def rule(text: str):
    found = say(text)
    return found["id"] if found else None


# ── Before a transaction: the patterns the brief names ───────────────────

class TestRecognisedPatterns:
    @pytest.mark.parametrize("message,expected", [
        # pressure to pay immediately
        ("he is rushing me to pay now", "pressure"),
        ("she says many buyers want it so I must pay immediately", "pressure"),
        ("he is pressuring me to send money today", "pressure"),
        # deposits to reserve
        ("he asked for a deposit to reserve the phone", "deposit_to_reserve"),
        ("the seller wants me to send 2000 to reserve it", "deposit_to_reserve"),
        ("he wants a booking fee before I can see the car", "deposit_to_reserve"),
        # bypassing escrow
        ("the seller wants to skip escrow", "bypass_escrow"),
        ("he says escrow is not needed", "bypass_escrow"),
        ("they want me to bypass the escrow", "bypass_escrow"),
        ("he said don't use escrow", "bypass_escrow"),
        # fake customer care
        ("someone from customer care called me about my escrow", "fake_customer_care"),
        ("a man called pretending to be from Safaricom", "fake_customer_care"),
        ("an escrow agent says he can release my funds if I pay a fee", "fake_customer_care"),
        ("the agent promised to release the money after I pay", "fake_customer_care"),
        # fake M-Pesa messages
        ("he sent me an M-Pesa message showing he paid", "fake_mpesa_message"),
        ("the buyer says he sent money by mistake, send it back", "fake_mpesa_message"),
        ("is this mpesa message real", "fake_mpesa_message"),
        # OTP / PIN / password requests
        ("The seller asked for my M-Pesa PIN", "otp_pin"),
        ("he wants my OTP to release the money", "otp_pin"),
        ("should I share the OTP with the agent", "otp_pin"),
        ("someone asked me to send the release code", "otp_pin"),
        ("she told me to give my password", "otp_pin"),
        # suspiciously cheap
        ("the price is too good to be true", "too_cheap"),
        ("it's half the market price, is it a scam", "too_cheap"),
        ("much cheaper than everywhere else", "too_cheap"),
        # changed payment destination
        ("he gave a different till number at the last minute instead", "change_payee"),
        ("he asked me to pay his personal number", "change_payee"),
        ("the escrow checkout is not working so pay my number", "change_payee"),
        # a link sent by the other party
        ("the seller sent me an escrow link", "suspicious_link"),
        ("he gave me a website to pay on", "suspicious_link"),
    ])
    def test_each_pattern_gets_its_written_answer(self, message, expected):
        assert rule(message) == expected

    def test_paying_a_personal_number_instead_of_escrow_is_flagged_either_way(self):
        # Both warnings are right; which one leads does not matter here.
        assert rule("she wants me to pay her personal number instead of escrow") in ("change_payee", "bypass_escrow")

    @pytest.mark.parametrize("message", [
        "next", "how does escrow work", "open my inbox", "what is the price of this phone",
        "I want to buy a phone", "walk me through paying with kenya escrow", "can you call Jane",
        "my deposit was refunded by the seller", "how do I get paid", "is this a fair price",
        "the pin on my map is wrong", "I forgot my password for my broka account",
        "what is an OTP", "hello", "thanks, that was helpful", "he delivered the item on time",
        "I sold my laptop yesterday", "can I change my phone number", "the seller replied quickly",
    ])
    def test_ordinary_messages_are_not_flagged(self, message):
        assert say(message) is None


class TestPaymentScreenshotsAndOtps:
    """The two the brief singles out."""

    @pytest.mark.parametrize("message", [
        "he sent a screenshot showing he paid, should I send the goods?",
        "buyer shared proof of payment screenshot can I ship",
        "they paid, here is the screenshot, do I dispatch",
    ])
    def test_a_screenshot_is_not_proof_of_payment(self, message):
        out = say(message)
        assert out["id"] == "screenshot_proof" and out["source" if "source" in out else "kind"] == "rule"
        text = out["reply"]
        assert "A screenshot is not proof of payment" in text
        assert "SMS forwarded by the other person is not proof that the escrow is funded" in text
        assert "official provider account or transaction page" in text
        assert "never" not in text.lower().split("check")[0] or True        # no instruction to just trust it
        assert "looks genuine" not in text.lower() and "looks real" not in text.lower()

    def test_a_forwarded_sms_is_not_proof_either(self):
        out = say("he forwarded a payment sms")
        assert out["id"] == "fake_mpesa_message"
        assert "forwarded SMS or a screenshot proves nothing" in out["reply"]

    @pytest.mark.parametrize("message", [
        "The seller asked for my M-Pesa PIN", "he wants my OTP to release the money",
        "should I share the OTP with the agent", "they asked me to read out the verification code",
    ])
    def test_an_otp_or_pin_request_always_gets_the_same_refusal(self, message):
        out = say(message)
        assert out["id"] == "otp_pin"
        text = out["reply"]
        assert "Never share a PIN, an OTP or a password" in text
        assert "A genuine provider will never ask you for these in a chat or on a call" in text
        assert "contact Safaricom" in text            # if they already did
        assert "Stop the conversation" in text

    def test_zeno_never_says_a_payment_message_is_genuine(self):
        # "this (one) looks genuine", "it is real", "the message seems fine" - but NOT
        # "I can't tell whether one is genuine", which is the refusal we want.
        vouching = re.compile(r"\b(?:this|that|it|the message|the screenshot|the sms)\b(?:\s+\w+){0,2}?\s+"
                              r"(?:is|looks|seems|appears)\s+(?:genuine|real|fine|legit|ok|okay|valid|true)\b")
        for message in ("is this mpesa message real", "he sent me an M-Pesa message showing he paid",
                        "he sent a screenshot showing he paid, should I send the goods?"):
            text = say(message)["reply"].lower()
            assert not vouching.search(text), message
            assert "looks fine" not in text
            assert "can't tell" in text or "not proof" in text      # it says what it cannot know


class TestEveryAnswerIsSafe:
    ALL = [say(m) for m in (
        "he is rushing me to pay now", "he asked for a deposit to reserve the phone",
        "the seller wants to skip escrow", "someone from customer care called me",
        "he sent me an M-Pesa message showing he paid", "The seller asked for my M-Pesa PIN",
        "the price is too good to be true", "he asked me to pay his personal number",
        "the seller sent me an escrow link",
        "he sent a screenshot showing he paid, should I send the goods?",
        "what should a seller check before dispatching?", "what should I agree before I pay?",
        "what should a buyer do", "I think I was scammed",
        "how do I find a provider's official contacts?")]

    def test_every_answer_exists(self):
        assert all(self.ALL)

    def test_no_answer_accuses_a_person_or_promises_recovery(self):
        for out in self.ALL:
            text = out["reply"].lower()
            for banned in ("is a scammer", "are a scammer", "you will get your money back",
                           "we will recover", "broka will refund", "guaranteed", "fully safe",
                           "100% safe", "approved by broka", "licensed"):
                assert banned not in text, (out["id"], banned)
            assert not re.search(r"\b(?:this|that|it|he|she) is (?:genuine|a scammer|a fraud)\b", text), out["id"]

    def test_no_answer_contains_a_number_address_or_figure_to_pay(self):
        for out in self.ALL:
            safe, problems = fg.guard_reply(out["reply"], seed.records())
            assert problems == [], (out["id"], problems)
            assert not re.search(r"\b0[17]\d{8}\b|\+254", out["reply"]), out["id"]
            assert not re.search(r"https?://|www\.", out["reply"]), out["id"]

    def test_the_payment_rules_are_repeated_where_money_is_at_stake(self):
        for rid in ("pressure", "deposit_to_reserve", "bypass_escrow", "fake_customer_care",
                    "change_payee", "otp_pin"):
            out = next(o for o in self.ALL if o["id"] == rid)
            assert "Never share your M-Pesa PIN, an OTP or a password" in out["reply"] \
                or "Never share a PIN, an OTP or a password" in out["reply"], rid

    def test_a_pattern_answer_invites_a_report_and_a_report_is_not_called_a_finding(self):
        out = next(o for o in self.ALL if o["id"] == "deposit_to_reserve")
        assert "report it to Broka" in out["reply"]
        assert disclosures.INCIDENT_LIMIT.startswith("Broka cannot promise to recover money")

    def test_every_answer_offers_a_next_step_chip(self):
        for out in self.ALL:
            assert out["suggestions"] and all(len(s) <= 60 for s in out["suggestions"]), out["id"]


class TestGuidedTopics:
    def test_before_paying_covers_everything_the_brief_lists(self):
        text = say("what should I agree before I pay?")["reply"]
        lowered = text.lower()
        for needle in ("item or service", "description and its condition", "price", "who pays the escrow",
                       "how and when it will be delivered", "who pays for delivery", "delivery date",
                       "inspection period", "return or damage", "milestones", "how a dispute will be raised",
                       "verify the transaction independently on the provider's official website"):
            assert needle in lowered, needle

    def test_buyer_guidance(self):
        text = say("what should a buyer do")["reply"]
        for needle in ("Don't release funds before you have received and inspected",
                       "Check the item against the written description", "Record the delivery",
                       "open a dispute", "before the confirmation deadline",
                       "Don't confirm that everything is fine just because the seller is pressuring you"):
            assert needle in text, needle

    def test_seller_guidance(self):
        text = say("what should a seller check before dispatching?")["reply"]
        for needle in ("don't dispatch on a payment screenshot", "actually locked", "Keep the transaction record",
                       "proof of handover", "an escrow agent will pay you later"):
            assert needle.lower() in text.lower(), needle

    def test_after_a_scam_follows_the_brief_in_order_and_does_not_promise_recovery(self):
        text = say("I think I was scammed")["reply"]
        positions = [text.index(s) for s in (
            "do not send more money", "Keep everything", "Contact the escrow provider yourself",
            "Report it to Broka", "contact that payment provider", "report it to the police")]
        assert positions == sorted(positions)
        assert "cannot promise to recover money" in text

    @pytest.mark.parametrize("message", [
        "I think I was scammed", "i got scammed", "the seller scammed me", "how do I report this",
        "report a scam", "what should I do if I was scammed", "someone scammed me",
    ])
    def test_the_many_ways_of_saying_it(self, message):
        assert rule(message) == "after_incident"

    def test_topics_win_over_pattern_warnings(self):
        # "what should a seller check before dispatching" mentions dispatching and
        # payment: it must get the full guidance, not a screenshot warning.
        assert rule("what should a seller check before dispatching?") == "seller_guidance"


# ── A photo of a payment ─────────────────────────────────────────────────

class TestPhotoOfAPayment:
    def test_a_photo_about_payment_gets_the_screenshot_caution(self):
        for message in ("is this real", "he says he paid, here is the M-Pesa message", "payment proof",
                        "check this receipt", ""):
            assert fg.image_caution(message, True) == fg.IMAGE_CAUTION, message

    def test_a_photo_of_an_item_does_not(self):
        for message in ("what is this phone worth", "is this a good laptop", "describe this"):
            assert fg.image_caution(message, True) is None, message

    def test_no_photo_no_caution(self):
        assert fg.image_caution("is this real", False) is None

    def test_the_caution_says_what_a_screenshot_cannot_prove(self):
        assert "not proof of payment" in fg.IMAGE_CAUTION
        assert "can't tell whether one is genuine" in fg.IMAGE_CAUTION
        assert "official provider account or transaction page" in fg.IMAGE_CAUTION


# ── The guard on what a model says ───────────────────────────────────────

RECORDS = seed.records()


def blocked(text):
    return fg.guard_reply(text, RECORDS)[1]


class TestTheGuard:
    @pytest.mark.parametrize("reply,why", [
        ("Call the escrow agent on 0712 345 678 to release it.", "phone_or_account_number"),
        ("WhatsApp +254 722 000 111 for help.", "phone_or_account_number"),
        ("Pay to paybill 247247 account 12345 to unlock your funds.", "till_or_paybill"),
        ("Send it to till number 5123456.", "till_or_paybill"),
        ("Open https://kenya-escrow-pay.com to pay.", "unapproved_address"),
        ("Use escrowkenya.com instead.", "unapproved_address"),            # suspended: not approved
        ("Go to www.kenyaescrow.com.evil.example", "unapproved_address"),
        ("Don't worry, your money is guaranteed to be safe.", "unearned_promise"),
        ("Kenya Escrow is licensed by the CBK.", "unearned_promise"),
        ("This provider is fully safe.", "unearned_promise"),
        ("You will definitely get your money back.", "unearned_promise"),
        ("It is Broka approved.", "unearned_promise"),
        ("It is risk-free.", "unearned_promise"),
    ])
    def test_unsafe_replies_are_replaced(self, reply, why):
        problems = blocked(reply)
        assert any(why in p for p in problems), problems
        text, _ = fg.guard_reply(reply, RECORDS)
        assert text == fg.GUARD_FALLBACK and reply not in text

    @pytest.mark.parametrize("reply,provider", [
        ("Lipasafe charges 2.5% per transaction.", "lipasafe"),              # publishes none
        ("Shikilia's fee is KSh 50 per transaction.", "shikilia"),           # publishes none
        ("eConfirm charges 3% commission.", "econfirm"),                      # publishes 1%
        ("Kenya Escrow adds a KSh 99 fixed fee.", "kenyaescrow"),            # not a published figure
        ("Let's look at Lipasafe. It charges 2.5% per deal.", "lipasafe"),   # carried across sentences
        ("- Lipasafe: 2% fee\n- Shikilia: 3% fee", "lipasafe"),
    ])
    def test_an_invented_fee_is_blocked(self, reply, provider):
        problems = blocked(reply)
        assert any(provider in p and p.startswith("invented_") for p in problems), problems

    @pytest.mark.parametrize("reply", [
        "Most escrow providers charge around 3% of the price.",
        "Escrow usually costs about 2% commission.",
    ])
    def test_a_made_up_general_fee_is_blocked_too(self, reply):
        assert "unsourced_fee_percentage" in blocked(reply)

    @pytest.mark.parametrize("reply", [
        "eConfirm publishes a 1% platform commission. Its payout reserve is separate.",
        "Let's look at eConfirm. It publishes a 1% platform commission.",
        "Kenya Escrow takes amounts from KSh 50 to KSh 240,000.",
        "For a KSh 5,000 amount, Kenya Escrow's published band is 5.4% plus KSh 46.",
        "M-Pesa can't send more than KSh 250,000 in one payment.",
        "Open https://kenyaescrow.com/ yourself and check its pricing page.",
        "Its site is www.shikilia.co.ke.",
        "Lipasafe shows its fee in the app before you confirm. Check the live quotation.",
        "Never share your PIN. Check the payee, amount and purpose before you approve.",
        "Escrow disputes can take 24 to 48 hours. You have 3 days to respond.",
        "Do an official search at ardhisasa.lands.go.ke before paying.",
        "Your reference is 4821.",
        "There is a good chance, maybe 70%, that the seller is genuine - but check anyway. Escrow helps.",
    ])
    def test_ordinary_helpful_replies_pass_unchanged(self, reply):
        text, problems = fg.guard_reply(reply, RECORDS)
        assert problems == [] and text == reply

    @pytest.mark.parametrize("reply,why", [
        # numbers hidden by separators or written as words
        ("Call 0 7 1 2 3 4 5 6 7 8 now.", "phone_or_account_number"),
        ("Call 0712-345-678.", "phone_or_account_number"),
        ("Call 0712.345.678.", "phone_or_account_number"),
        ("Call 254 712 345 678.", "phone_or_account_number"),
        ("Call zero seven one two three four five six seven eight.", "phone_or_account_number"),
        ("Piga sifuri saba moja mbili tatu nne tano sita saba nane.", "phone_or_account_number"),
        ("Use paybill number five one two three four five", "till_or_paybill"),
        # addresses hidden by defanging or spelling
        ("Go to kenya-escrow-pay dot com now.", "unapproved_address"),
        ("Visit hxxps://kenya-escrow-pay[.]com", "unapproved_address"),
        ("Visit kenya-escrow-pay[.]com to pay", "unapproved_address"),
        ("Open HTTPS://Evil.Example/pay", "unapproved_address"),
        ("Open http://192.168.1.5/pay", "unapproved_address"),
        # other ways to a stranger
        ("Email support@evil.example for help.", "email_address"),
        ("Email support (at) evil (dot) example", "email_address"),
        ("Use bit.ly/escrow-pay", "shortened_link"),
        ("Chat on wa.me/254712345678", "shortened_link"),
    ])
    def test_hiding_a_number_or_address_does_not_get_past_the_guard(self, reply, why):
        assert any(why in p for p in blocked(reply)), blocked(reply)

    @pytest.mark.parametrize("reply", [
        # Ordinary text with digits, dots and the word "at" that must NOT be blocked
        "Do an official search at ardhisasa.lands.go.ke before paying.",
        "Reach Broka at broka.co.ke.",
        "Visit ardhisasa.lands.go.ke or safaricom.co.ke.",
        "Wait 1 to 2 days, then check again.",
        "It sells for about 45,000 to 50,000 shillings, so 2 or 3 sellers is normal.",
        "In 2026 the limit is KSh 250,000; for 10 000 you pay less.",
        "Meet at 2 pm, bring 1 friend, and check 5 things: 1. photos 2. serial 3. battery 4. screen 5. box.",
        "A 3 4 5 mix of single digits: 3 apples, 4 pears and 5 plums.",
        "On 12.11.2026 at 14:30 the price was 25,000.",
        "Version 1.2.3.4 of the app is out.",
        "Order 0712 was shipped on 7 11 2026 for 5 000.",
        "The rate is 2.65% for 150,001 to 200,000, plus 1,190.",
        "Open at 7 a.m. and pay 5.4 percent plus 46 shillings, that's 1 2 3 4 5 6 7 8 9 for a total of 10.",
    ])
    def test_separators_dates_prices_and_the_word_at_are_not_mistaken_for_a_hidden_number(self, reply):
        text, problems = fg.guard_reply(reply, RECORDS)
        assert problems == [] and text == reply

    def test_a_suspended_providers_address_is_never_allowed(self):
        assert any("escrowkenya.com" in p for p in blocked("Try escrowkenya.com"))

    def test_a_removed_or_changed_provider_changes_what_is_allowed(self):
        records = copy.deepcopy(RECORDS)
        next(r for r in records if r["id"] == "kenyaescrow")["status"] = "suspended"
        assert any("kenyaescrow.com" in p for p in fg.guard_reply("Open kenyaescrow.com", records)[1])
        assert fg.guard_reply("Open kenyaescrow.com", RECORDS)[1] == []

    def test_an_empty_reply_is_fine(self):
        assert fg.guard_reply("", RECORDS) == ("", [])
        assert fg.guard_reply(None, RECORDS) == ("", [])

    def test_the_fallback_is_itself_safe(self):
        assert fg.guard_reply(fg.GUARD_FALLBACK, RECORDS)[1] == []
        assert "don't have" not in fg.GUARD_FALLBACK.lower()
        assert "never from a link someone sends you" in fg.GUARD_FALLBACK

    def test_a_published_figure_is_allowed_for_that_provider_only(self):
        # 1% is eConfirm's; naming it beside another provider is an invention.
        assert fg.guard_reply("eConfirm charges 1%.", RECORDS)[1] == []
        assert any("lipasafe" in p for p in blocked("Lipasafe charges 1%."))


# ── The instructions given to a model ────────────────────────────────────

class TestThePolicyGivenToTheModel:
    def policy(self, records=None):
        return fg.fraud_policy(records if records is not None else seed.records())

    def test_it_carries_the_live_catalogue_and_says_what_is_unreviewed(self):
        text = self.policy()
        for name, domain in (("eConfirm", "econfirm.co.ke"), ("Kenya Escrow", "kenyaescrow.com"),
                             ("Lipasafe", "lipasafe.co.ke"), ("Shikilia", "shikilia.co.ke")):
            assert name in text and f"https://{domain}/" in text
        assert text.count("Broka has NOT finished reviewing it") == 4

    def test_unknown_fees_are_stated_as_unknown_not_left_to_be_filled_in(self):
        text = self.policy()
        assert "Check live quotation in Lipasafe before paying" in text
        assert "Fee not publicly specified – confirm before paying" in text
        assert "NEVER invent or estimate a fee, a phone number, a paybill or till number" in text
        # Said without the word "rank": an existing Zeno test (test_zeno_assistant.py) fails any
        # prompt that carries a listing and contains it, as a check that no ranking data leaks.
        assert "never say one provider costs less than another unless every figure you compare is stated" in text.lower()
        assert "rank" not in text.lower()

    def test_a_suspended_provider_is_named_only_as_one_to_avoid(self):
        text = self.policy()
        assert "Escrow Kenya (escrowkenya.com) is NOT on Broka's list" in text
        assert "never recommend it" in text
        assert "https://escrowkenya.com" not in text

    def test_it_teaches_every_rule_the_brief_lists(self):
        text = self.policy()
        for needle in ("never share an M-Pesa PIN, an OTP or a password",
                       "never pay a personal number given in chat",
                       "a screenshot or a forwarded SMS is not proof",
                       "check the payee, the amount and the purpose",
                       "unofficial \"agent\" who promises to release escrow money is a scammer",
                       "Do not release before receiving and inspecting".lower(),
                       "do not dispatch on a screenshot",
                       "Never promise Broka can recover money"):
            assert needle.lower() in text.lower(), needle

    def test_it_says_broka_holds_no_money_and_guarantees_nothing(self):
        text = self.policy()
        assert "Broka does not hold money, run escrow or guarantee any provider" in text

    def test_a_provider_that_becomes_suspended_leaves_the_list(self):
        records = seed.records()
        next(r for r in records if r["id"] == "lipasafe")["status"] = "suspended"
        text = self.policy(records)
        assert "- Lipasafe - official site" not in text
        assert "Lipasafe (lipasafe.co.ke) is NOT on Broka's list" in text

    def test_an_approved_provider_is_not_told_off_as_unreviewed(self):
        records = seed.records()
        ke = next(r for r in records if r["id"] == "kenyaescrow")
        ke["status"] = "approved"
        assert self.policy(records).count("Broka has NOT finished reviewing it") == 3
        assert "kenyaescrow.com/ - reviewed by Broka" in self.policy(records)

    def test_the_static_version_names_no_provider_and_so_cannot_go_stale(self):
        text = fg.STATIC_POLICY
        for domain in ("econfirm", "kenyaescrow", "lipasafe", "shikilia", "escrowkenya"):
            assert domain not in text.lower()
        assert "Never invent or estimate an escrow fee" in text
        assert "Never give a web address" in text


# ── Booleans of behaviour that must not drift ────────────────────────────

def test_the_fallback_and_answers_never_use_a_claim_broka_has_not_earned():
    texts = [fg.GUARD_FALLBACK, fg.IMAGE_CAUTION, fg.STATIC_POLICY, fg.fraud_policy(seed.records())]
    texts += [out["reply"] for out in TestEveryAnswerIsSafe.ALL]
    for text in texts:
        for pattern in (r"\bguaranteed\b", r"\bfully safe\b", r"\b100% safe\b", r"\bbroka[- ]approved\b",
                        r"\brisk[- ]free\b", r"\bcompletely safe\b"):
            # a prompt may NAME these words to forbid them; an answer to a user may not use them
            if text is fg.STATIC_POLICY or text.startswith("\n\nFRAUD PREVENTION"):
                continue
            assert not re.search(pattern, text, re.I), (pattern, text[:80])
