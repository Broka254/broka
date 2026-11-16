"""Zeno as a fraud-prevention assistant - the part that does not depend on a
model behaving.

A language model asked "he wants a deposit to reserve the phone, is that
fine?" will usually say no - and sometimes, when the conversation has made
the seller sound reasonable, say yes. On the one question where a wrong
answer costs someone their money, "usually" is not good enough. So the
known scam patterns are answered here, in fixed words, before any model is
asked; and whatever a model does say is checked on the way out.

TWO PARTS
  rules   (reply_for)   A message that matches a known scam pattern gets a
                        written answer: what the pattern is, what to do,
                        what not to do. No model, so it is the same every
                        time and cannot be talked round. Narrow on purpose:
                        a pattern has to be unmistakable, and everything
                        else goes on to the model, which is given the same
                        guidance as instructions (FRAUD_POLICY).
  guard   (guard_reply) A model's reply is refused if it contains what a
                        model must not produce: a phone, till or paybill
                        number, a web address that is not on the approved
                        list, a fee figure for a provider that publishes
                        none or a different one, or a promise ("guaranteed",
                        "licensed by", "fully safe"). The user gets a safe
                        answer instead. An invented paybill is the exact
                        thing a fraudster would like a trusted assistant to
                        say.

WHAT THIS NEVER DOES
  * It does not call anyone a scammer. It names a PATTERN ("asking for a
    deposit to reserve an item is a common scam") and what to do.
  * It does not say a payment message, screenshot or link is genuine. It
    cannot know, and "looks fine" is the sentence a victim repeats to
    themselves. It sends people to the provider's own transaction page.
  * It does not promise Broka can get money back.

English only for now, like the escrow walkthrough: Zeno's other replies
follow the user's language, but these are written and checked once.
"""
from __future__ import annotations

import re
from typing import Iterable, Optional

from api.domains.escrow_directory import aliases, disclosures

# Said after (nearly) every payment answer: the five rules a victim breaks.
PAYMENT_RULES = (
    "Never share your M-Pesa PIN, an OTP or a password with anyone - not the seller, not a "
    "\"customer care\" caller, not an \"escrow agent\"."
)

REPORT_LINE = "You can report it to Broka from the app so the team can review the account."

_FOOTER_TIP = {
    "otp_pin": "If you already shared a code or your PIN, contact Safaricom (or your bank) right "
               "away, using the number on their official site.",
}


def _reply(title: str, lines: Iterable[str], chips: Optional[list[str]] = None, *,
           report: bool = True) -> dict:
    body = "\n".join(f"• {line}" for line in lines)
    text = f"{title}\n\n{body}"
    if report:
        text += f"\n\n{REPORT_LINE}"
    return {"reply": text, "suggestions": chips or [], "rule": title}


# ── The rules ────────────────────────────────────────────────────────────
# Each: (id, pattern over normalised lower-case text, reply builder). Patterns
# are checked in order; the first that matches answers. They describe what
# the USER reports or asks, because that is what reaches Zeno.

_ASK = r"(?:ask(?:s|ed|ing)?|want(?:s|ed)?|need(?:s|ed)?|request(?:s|ed|ing)?|demand(?:s|ed)?|told me to|tell(?:s|ing)? me to|say(?:s|ing)? i (?:must|should|have to)|insist(?:s|ed)?(?: (?:on|that))?|sent me (?:a )?(?:message|text|sms) (?:asking|saying))"
_SECRET = r"(?:m-?pesa )?(?:pin|otp|one[- ]time (?:pin|code|password)|password|passcode|verification code|release code|confirmation code|security code)"

RULES: list[tuple[str, "re.Pattern[str]"]] = [
    ("otp_pin", re.compile(
        rf"(?:{_ASK}[^.?!]{{0,60}}\b{_SECRET}\b|"
        rf"\b(?:share|send|give|tell|read(?: out)?|forward|type|enter)(?:ing)?\b[^.?!]{{0,30}}\b(?:my |the |your )?{_SECRET}\b[^.?!]{{0,25}}\b(?:to|with|for)\b|"
        rf"\b(?:should|can|do|must|am i|is it (?:ok|okay|safe|fine) to)\b[^.?!]{{0,25}}\b(?:share|send|give|tell|read|forward)\b[^.?!]{{0,25}}\b{_SECRET}\b|"
        rf"\b{_SECRET}\b[^.?!]{{0,30}}\b(?:to (?:release|confirm|verify|receive|get paid|unlock))\b)")),
    ("bypass_escrow", re.compile(
        r"\b(?:skip|avoid|bypass|without|outside|forget|cancel|no need for|don'?t (?:need|use|want)|not use|instead of)\b[^.?!]{0,25}\bescrow\b|"
        r"\bescrow\b[^.?!]{0,30}\b(?:is |are )?(?:not needed|unnecessary|a waste|too (?:slow|expensive)|useless|a scam|fake)\b|"
        r"\b(?:pay|send)\b[^.?!]{0,25}\b(?:directly|direct)\b[^.?!]{0,30}\b(?:instead|not escrow|no escrow|without escrow)\b")),
    ("deposit_to_reserve", re.compile(
        r"\b(?:deposit|booking fee|reservation fee|holding fee|reserve (?:it|the|this|my)|to (?:reserve|hold|book|secure) (?:it|the|this|my|an? )|advance (?:payment|fee))\b[^.?!]{0,60}\b(?:before|first|upfront|up front|to (?:reserve|hold|book|secure|confirm))\b|"
        r"\b(?:send|pay|wants?|asked? (?:me )?(?:for|to (?:send|pay)))\b[^.?!]{0,30}\b(?:a )?(?:deposit|booking fee|reservation fee|holding fee|advance)\b|"
        r"\b(?:send|pay)\b[^.?!]{0,40}\bto (?:reserve|hold|book|secure)\b")),
    ("fake_customer_care", re.compile(
        r"\b(?:customer (?:care|service|support)|support (?:agent|team|desk)|(?:escrow|safaricom|m-?pesa|broka|bank) (?:agent|rep(?:resentative)?|officer|staff|official))\b[^.?!]{0,60}\b(?:called|calls?|rang|phoned|texted|whatsapp(?:ed)?|messaged|contacted|sent|says?|said|told|asked|want)\b|"
        r"\b(?:someone|a man|a woman|a person|he|she|they)\b[^.?!]{0,30}\b(?:called|rang|phoned|messaged|texted)\b[^.?!]{0,30}\b(?:from|as|claiming|pretending)\b[^.?!]{0,30}\b(?:safaricom|m-?pesa|escrow|broka|customer care|the bank)\b|"
        r"\b(?:release|unlock|free|withdraw|clear)\b[^.?!]{0,25}\b(?:my |the |your )?(?:escrow|funds|money|payment)\b[^.?!]{0,30}\b(?:agent|for a fee|if i pay|after i pay|pay(?:ing)? (?:a )?fee)\b|"
        r"\b(?:agent|broker|middleman)\b[^.?!]{0,30}\b(?:will |can |promis\w+ (?:to )?|says? (?:he|she|they) (?:will|can) )(?:release|unlock|free|pay)\b")),
    ("fake_mpesa_message", re.compile(
        r"\b(?:sent|got|received|forward\w*|shows?|showed|show(?:ing)?|has|have)\b[^.?!]{0,30}\b(?:an? )?(?:m-?pesa|mpesa|payment|confirmation|transaction)\b[^.?!]{0,15}\b(?:message|sms|text|confirmation|screenshot|receipt)\b|"
        r"\b(?:wrongly|by mistake|mistakenly|accidentally|in error)\b[^.?!]{0,30}\b(?:sent|paid|transferred)\b[^.?!]{0,40}\b(?:send (?:it )?back|reverse|return|refund)\b|"
        r"\b(?:sent|paid|transferred)\b[^.?!]{0,40}\b(?:by mistake|wrongly|mistakenly|accidentally|in error|too much|extra)\b[^.?!]{0,50}\b(?:send (?:it )?back|reverse|return|refund|give (?:it )?back)\b|"
        r"\b(?:send|return|refund)\b[^.?!]{0,10}\b(?:it |the money |the (?:difference|balance|change) )?back\b[^.?!]{0,40}\b(?:sent|paid)\b[^.?!]{0,20}\b(?:too much|extra|by mistake|wrongly|more)\b|"
        r"\b(?:is|are|looks?|seems?)\b[^.?!]{0,20}\b(?:this|that|the|his|her|their)\b[^.?!]{0,15}\b(?:m-?pesa|mpesa)\b[^.?!]{0,10}\b(?:message|sms|text|confirmation|receipt)\b[^.?!]{0,15}\b(?:real|genuine|fake|legit|true|ok|okay|valid)\b")),
    ("screenshot_proof", re.compile(
        r"\b(?:screenshot|screen shot|screen-shot|photo of (?:the |his |her )?(?:payment|receipt|message)|proof of payment|payment proof|pop)\b[^.?!]{0,80}\b(?:paid|payment|sent|escrow|funded|released|deposit|ship|send|deliver|dispatch|hand|give|proof|enough|genuine|real|fake)\b|"
        r"\b(?:paid|payment|funded|escrow)\b[^.?!]{0,40}\b(?:screenshot|screen shot|proof of payment|payment proof)\b|"
        r"\b(?:should i|can i|do i|is it (?:ok|okay|safe) to)\b[^.?!]{0,25}\b(?:send|ship|deliver|dispatch|hand over|give|release)\b[^.?!]{0,40}\b(?:screenshot|sms|message|he says (?:he )?paid|she says (?:she )?paid|says (?:he|she|they) paid|already paid)\b")),
    ("change_payee", re.compile(
        r"\b(?:change[ds]?|new|different|another|other|updated?|switch(?:ed)?)\b[^.?!]{0,25}\b(?:till|paybill|pay bill|account|number|phone number|payment (?:number|details|destination)|payee)\b[^.?!]{0,50}\b(?:instead|actually|now|at the last minute|just before|after|rather)\b|"
        r"\b(?:pay|send)\b[^.?!]{0,30}\b(?:his|her|their|my|a|the) (?:personal|private|own|other|different|new|friend'?s|brother'?s|sister'?s|cousin'?s|agent'?s)\b[^.?!]{0,15}\b(?:number|phone|till|paybill|account)\b|"
        r"\b(?:personal|private)\b[^.?!]{0,10}\b(?:number|phone|till|account|m-?pesa)\b[^.?!]{0,40}\b(?:instead of|rather than|not|and not|bypass|skip)\b[^.?!]{0,20}\b(?:escrow|checkout|the (?:official|provider))\b|"
        r"\b(?:escrow|official|provider|checkout)\b[^.?!]{0,50}\b(?:link|checkout|page|site)\b[^.?!]{0,10}\b(?:not working|doesn'?t work|is down|failed)\b[^.?!]{0,30}\b(?:pay|send)\b")),
    ("suspicious_link", re.compile(
        r"\b(?:sent|gave|shared|forwarded|texted|whatsapp(?:ed)?|messaged|posted)\b[^.?!]{0,25}\b(?:me )?(?:a |an |his |her |their |the )?(?:escrow )?(?:link|website|site|url|checkout|page)\b|"
        r"\b(?:escrow|payment)\b[^.?!]{0,10}\b(?:link|site|website|page)\b[^.?!]{0,30}\b(?:from|sent by|given by)\b[^.?!]{0,10}\b(?:the |a |my )?(?:seller|buyer|him|her|them|stranger|agent)\b")),
    ("pressure", re.compile(
        r"\b(?:rush(?:es|ed|ing)?|hurry|hurr(?:y|ies|ied)|pressur\w+|urgent(?:ly)?|immediately|right now|asap|quickly|within (?:the )?(?:hour|minutes?|next \d+ ?(?:min|minutes|hours?))|last (?:one|piece|chance)|many (?:other )?(?:buyers|people)|someone else (?:is|wants|will|paying|coming)|before (?:someone|others|the others|tomorrow|today ends))\b[^.?!]{0,70}\b(?:pay|payment|send|deposit|money|transfer|confirm|buy|release|decide)\b|"
        r"\b(?:pay|send|confirm|release|decide)\b[^.?!]{0,40}\b(?:now|today|immediately|right away|urgently|quickly|asap|within (?:the )?(?:hour|minutes?))\b[^.?!]{0,40}\b(?:or|otherwise|else|before|because|since)\b")),
    ("too_cheap", re.compile(
        r"\b(?:too good to be true|(?:very |so |really |suspiciously |extremely )?(?:cheap|low)(?:er)? (?:price|offer|deal)|half (?:the )?(?:price|market)|way (?:below|under|cheaper)|much (?:cheaper|lower)|(?:price|it) (?:is|looks|seems) (?:too|very|so|really) (?:cheap|low|good))\b|"
        r"\b(?:cheaper|lower|below)\b[^.?!]{0,20}\b(?:than (?:everyone|everywhere|any(?:one|where)|the market|others|normal|usual)|market (?:price|rate))\b|"
        r"\b(?:is|are) (?:this|it|that|these)\b[^.?!]{0,25}\b(?:a )?(?:scam|too cheap|suspicious|legit|genuine|fake)\b[^.?!]{0,30}\b(?:price|offer|deal|ad|listing)\b")),
]


def _answer(rule_id: str) -> dict:
    """The written reply for a rule. Kept apart from the patterns so each is
    read, and reviewed, as the sentence a frightened person will see."""
    if rule_id == "otp_pin":
        return _reply("Never share a PIN, an OTP or a password.", [
            "Nobody who is genuinely helping you with a payment needs your M-Pesa PIN, an OTP or "
            "any password. Not the seller, not \"customer care\", not an \"escrow agent\".",
            "A release code is for you to enter on the provider's own website or app - never to "
            "read out or send to the other person.",
            "Stop the conversation with whoever asked. A genuine provider will never ask you for "
            "these in a chat or on a call.",
            _FOOTER_TIP["otp_pin"],
        ], ["Walk me through paying safely", "How do I report this?"])
    if rule_id == "bypass_escrow":
        return _reply("Be careful: they want you to avoid the escrow.", [
            "Asking you to skip escrow, or to pay outside the provider's own checkout, is one of "
            "the most common scam patterns. The escrow only protects you if the money goes through it.",
            "If you agreed to use an escrow provider, pay only on that provider's official "
            "website. Open the website yourself - never from a link someone sends you.",
            "If they won't use escrow, you can say no, or only deal in person, checking the item "
            "before you pay anything.",
            PAYMENT_RULES,
        ], ["Walk me through paying with escrow", "Compare escrow providers"])
    if rule_id == "deposit_to_reserve":
        return _reply("Asking for a deposit to reserve an item is a common scam.", [
            "A genuine seller can let you inspect an item first, or use an escrow provider so "
            "the money is held under that provider's rules. A \"reservation\" sent straight to a "
            "person's number is gone for good if they don't deliver.",
            "Don't send a deposit, booking fee or \"holding\" payment to a personal number, "
            "whatever the reason given.",
            "If you want to use escrow, agree the item, price and delivery first, then pay "
            "through the provider's own checkout.",
            PAYMENT_RULES,
        ], ["Walk me through paying with escrow", "How do I check the seller?"])
    if rule_id == "fake_customer_care":
        return _reply("Treat unexpected \"customer care\" or \"agent\" contacts as fake.", [
            "Scammers pose as Safaricom, an escrow provider or Broka, and say they can release "
            "or unlock money - often for a fee, a PIN or a code. Genuine providers do not ask "
            "for any of these, and nobody can \"release\" escrow money for a payment to them.",
            "Don't call back a number they give you, and don't pay anyone who says they can "
            "release your funds.",
            "Contact the provider yourself, using the contact details on its official website.",
            PAYMENT_RULES,
        ], ["How do I find a provider's official contacts?", "How do I report this?"])
    if rule_id == "fake_mpesa_message":
        return _reply("An M-Pesa message or screenshot is not proof that escrow is funded.", [
            "Fake M-Pesa messages, and \"I sent it by mistake, send it back\" requests, are "
            "common. A forwarded SMS or a screenshot proves nothing - they are easy to fake, and "
            "I can't tell whether one is genuine.",
            "Sellers: check the real transaction status in your account on the provider's official "
            "website before you dispatch anything.",
            "Never send money \"back\" because someone says they overpaid. Check your own M-Pesa "
            "balance and the provider's page first.",
            "Before you approve an M-Pesa prompt, check the payee, the amount and what it is for.",
        ], ["What should a seller check before dispatching?", "How do I report this?"])
    if rule_id == "screenshot_proof":
        return _reply("Don't send goods on a screenshot or an SMS.", [
            "A screenshot is not proof of payment, and an SMS forwarded by the other person is "
            "not proof that the escrow is funded.",
            "Sellers: check the actual transaction status in the official provider account or "
            "transaction page, yourself. Only dispatch once it shows the funds are locked.",
            "Keep your own proof of delivery: a delivery method that gives a receipt or a "
            "handover record, and photos.",
            "Be wary of anyone who says an \"agent\" will pay you later - release happens "
            "through the provider, not through a person.",
        ], ["What should a seller check before dispatching?", "Walk me through selling with escrow"],
            report=False)
    if rule_id == "change_payee":
        return _reply("A last-minute change of where to pay is a warning sign.", [
            "Paying a personal number, or a different till or paybill from the one on the official "
            "checkout, is a common way money is diverted. Don't pay a personal number given in "
            "chat as an alternative to the official escrow checkout.",
            "If the checkout \"isn't working\", don't pay somewhere else instead. Stop, and "
            "contact the provider on its official contact details.",
            "Confirm the payee name, the amount and what the payment is for before you approve "
            "an M-Pesa prompt. If any of them is not what you agreed, cancel it.",
            PAYMENT_RULES,
        ], ["Walk me through paying with escrow", "How do I report this?"])
    if rule_id == "suspicious_link":
        return _reply("Don't use an escrow link someone sends you.", [
            "Fake escrow sites look real. Open the provider's official website yourself, by "
            "typing the address or using Broka's list, not a link from the other person.",
            "Check the address carefully: one different letter, or a different ending, is a "
            "different company.",
            "If you've already entered details or paid on a site you now doubt, stop, keep the "
            "evidence, and contact the real provider and your payment provider.",
        ], ["Compare escrow providers", "How do I report this?"])
    if rule_id == "pressure":
        return _reply("Being rushed to pay is a warning sign.", [
            "Pressure to pay now, \"someone else is coming\" and a deadline that suddenly "
            "appears are used to stop you checking.",
            "A genuine deal survives a pause. Take your time to check the seller, the item and "
            "the payment route.",
            "Agree the item, price, delivery and who pays the escrow fee in writing first.",
            PAYMENT_RULES,
        ], ["What should I agree before I pay?", "Compare escrow providers"])
    if rule_id == "too_cheap":
        return _reply("A price far below the market deserves a second look.", [
            "Prices that are too good to be true are a common lure. I can't tell you whether "
            "this particular seller is genuine.",
            "Compare with similar listings, ask for the item to be inspected before paying, "
            "and be wary of any request for a deposit or for payment outside the provider's "
            "checkout.",
            "Don't be rushed, and never share a PIN or an OTP.",
        ], ["Is this a fair price?", "What should I agree before I pay?"])
    raise KeyError(rule_id)


# ── Guided topics: asked about plainly, answered in full ─────────────────

_TOPICS: list[tuple[str, "re.Pattern[str]"]] = [
    ("before_paying", re.compile(
        r"^(?:what (?:should|do) i (?:agree|confirm|check|settle|discuss)(?: with (?:the )?(?:seller|buyer|them|him|her))?(?: before (?:i |we )?pay(?:ing)?)?|"
        r"what (?:should|must) (?:we|i) (?:agree|settle)(?: on)?|before i pay,? what|checklist (?:before|for) (?:paying|payment)|"
        r"how do i (?:prepare|get ready) to pay|what to agree before (?:paying|escrow))$")),
    ("buyer_guidance", re.compile(
        r"^(?:what should (?:a )?buyer(?:s)? (?:do|check|know)|buyer(?:'s)? (?:tips|guide|guidance|checklist|safety)|"
        r"(?:i'?m|i am) (?:the |a )?buyer,? what (?:should|do) i|when (?:should|can) i (?:release|confirm)|"
        r"how do i (?:inspect|check) (?:the |an? )?(?:item|goods|product)|when is it safe to release)$")),
    ("seller_guidance", re.compile(
        r"^(?:what should (?:a )?seller(?:s)? (?:do|check|know)|what should (?:a )?seller check(?: before dispatching)?|seller(?:'s)? (?:tips|guide|guidance|checklist|safety)|"
        r"(?:i'?m|i am) (?:the |a )?seller,? what (?:should|do) i|when (?:should|can) i (?:dispatch|send|ship|deliver|hand over)|"
        r"how do i know (?:the )?(?:buyer'?s? )?(?:money|payment|escrow) is (?:locked|held|funded|there)|how do i check (?:the )?(?:escrow|payment) is (?:funded|locked|held))$")),
    ("after_incident", re.compile(
        # Someone saying, in the first person or about the other party, that
        # they were scammed - the words are the same however it is phrased,
        # so the pattern is "a first-person opener, then a scam word":
        r"^(?:(?:i|we|i've|we've|i'm|we're|my (?:friend|brother|sister|mother|father|wife|husband)) (?:think |believe |feel |suspect |fear |reckon |am sure |'?m sure )?(?:i |we |he |she |they )?"
        r"(?:might |may |could |must )?(?:have |has |'ve |was |were |got |been |am |are |being |getting |just )*"
        r"(?:been )?(?:scammed|defrauded|cheated|conned|robbed|tricked|duped|swindled|fleeced)\b(?:[^.?!]{0,60})|"
        r"(?:the )?(?:seller|buyer|agent|man|woman|guy|person|someone|they|he|she) (?:has |have |just |had )?(?:scammed|cheated|conned|defrauded|tricked|duped|robbed|swindled) (?:me|us)\b|"
        r"someone (?:scammed|cheated|conned|defrauded|tricked|duped) me|"
        r"(?:i )?(?:sent|paid|lost) (?:money|kes|ksh|\d[\d,]*)[^.?!]{0,40}(?:scam|fraud|fake|stolen|never (?:got|received|delivered))|"
        r"what (?:should|do) i do (?:if|after) (?:i (?:was|got|have been|'ve been) )?(?:scammed|defrauded|cheated|conned)|"
        r"how do i report (?:a |this |the )?(?:scam|fraud|scammer|seller|buyer|user|incident|this)|"
        r"report (?:a |this |the )?(?:scam|scammer|fraud))$")),
    ("official_contacts", re.compile(
        r"^(?:how do i (?:find|get|contact|reach) (?:a |the )?(?:provider|escrow(?: provider)?)(?:'?s)?(?: official)? (?:contacts?|contact details|phone|number|email|website)|"
        r"what(?:'s| is) the (?:official )?(?:website|address|link|url) (?:of|for) (?:the )?(?:escrow )?(?:provider|escrow)|where do i find (?:the )?official (?:escrow )?(?:provider )?(?:contacts?|website))$")),
]


def _topic_reply(topic: str) -> dict:
    if topic == "before_paying":
        return _reply("Agree these with the other person before anyone pays.", [
            "Exactly what is being sold: the item or service, its description and its condition.",
            "The price, and who pays the escrow provider's fee.",
            "How and when it will be delivered, who pays for delivery, and the delivery date.",
            "The inspection period: how long the buyer has to check it, and what happens if it "
            "is wrong, damaged or not as described.",
            "Return or damage conditions.",
            "For services or big purchases: milestones, with what is delivered at each.",
            "How a dispute will be raised, and who each side contacts.",
            "Then verify the transaction independently on the provider's official website. Open "
            "it yourself, never from a link in the chat.",
            "Keep this agreement in the Broka chat. It is your record.",
        ], ["Compare escrow providers", "Walk me through paying with escrow"], report=False)
    if topic == "buyer_guidance":
        return _reply("Buyers: protect yourself before you release.", [
            "Don't release funds before you have received and inspected what was agreed.",
            "Check the item against the written description, in the condition agreed.",
            "Record the delivery: photos or video of the packaging and the item, and any "
            "delivery receipt.",
            "If something is wrong, open a dispute with the provider before the confirmation "
            "deadline - after it, funds may be released automatically.",
            "Don't confirm that everything is fine just because the seller is pressuring you.",
            PAYMENT_RULES,
        ], ["What should I agree before I pay?", "I think I was scammed"], report=False)
    if topic == "seller_guidance":
        return _reply("Sellers: don't dispatch on a payment screenshot.", [
            "Check, yourself, on the provider's official website or app that the funds are "
            "actually locked in the escrow transaction. A screenshot or a forwarded SMS is not "
            "proof.",
            "Keep the transaction record and your delivery evidence.",
            "Use a delivery method that produces proof of handover.",
            "Don't hand over goods because someone says an escrow agent will pay you later. "
            "Release happens through the provider, not through a person.",
            PAYMENT_RULES,
        ], ["What should I agree before I pay?", "I think I was scammed"], report=False)
    if topic == "after_incident":
        steps = list(disclosures.INCIDENT_STEPS) + [disclosures.INCIDENT_LIMIT]
        return _reply("If you think you've been scammed", steps,
                      ["Report this to Broka", "How do I find a provider's official contacts?"], report=False)
    if topic == "official_contacts":
        return _reply("Always use the provider's own contact details.", [
            "Open the provider's official website yourself, from Broka's list or by typing the "
            "address. Its contact details are on that site.",
            "Never use a phone number, link or WhatsApp contact that someone sends you in a chat.",
            "Check the web address carefully: one different letter or a different ending is a "
            "different company. Some provider names are easy to confuse.",
        ], ["Compare escrow providers", "I think I was scammed"], report=False)
    raise KeyError(topic)


def topic_for(text: str) -> Optional[str]:
    for topic, pattern in _TOPICS:
        if pattern.search(text):
            return topic
    return None


def rule_for(text: str) -> Optional[str]:
    """The id of the first scam rule [text] triggers, else None."""
    for rule_id, pattern in RULES:
        if pattern.search(text):
            return rule_id
    return None


def reply_for(text: str) -> Optional[dict]:
    """Zeno's written answer to [text] (already normalised), or None.

    A topic question ("what should a seller check before dispatching?") wins
    over a pattern match, so the answer to a plain question is the full
    guidance, not a warning."""
    topic = topic_for(text)
    if topic is not None:
        return {**_topic_reply(topic), "kind": "topic", "id": topic}
    rule = rule_for(text)
    if rule is not None:
        return {**_answer(rule), "kind": "rule", "id": rule}
    return None


# ── A photo of a payment ─────────────────────────────────────────────────

_PAYMENT_CONTEXT = re.compile(
    r"\b(?:m-?pesa|mpesa|paid|payment|pay(?:ing)?|receipt|proof|escrow|transaction|sent (?:the )?money|"
    r"deposit|confirm(?:ation|ed)?|screenshot|real|genuine|fake|legit)\b")

IMAGE_CAUTION = (
    "A reminder about payment screenshots: a screenshot or photo of an M-Pesa message is not "
    "proof of payment, and I can't tell whether one is genuine. Before you dispatch or release "
    "anything, check the real transaction status in the official provider account or "
    "transaction page yourself. " + PAYMENT_RULES
)


def image_caution(message: str, has_image: bool) -> Optional[str]:
    """The note to add under a model's reply to a photo, when the photo is
    probably a payment: the model can read what it says, not whether it is
    true. None when it is a photo of an item."""
    if not has_image:
        return None
    text = (message or "").lower()
    return IMAGE_CAUTION if (not text or _PAYMENT_CONTEXT.search(text)) and (
        not text or re.search(r"\b(?:m-?pesa|mpesa|paid|payment|receipt|proof|escrow|transaction|deposit|"
                              r"screenshot|confirm|fake|genuine|real|legit)\b", text)) else None


# ── The guard on what a model says ───────────────────────────────────────

_PHONE = re.compile(r"(?<![\d])(?:\+?254|0)[\s-]?[17]\d(?:[\s-]?\d){7}(?![\d])")
_LONG_DIGITS = re.compile(r"(?<![\d.,])\d{9,}(?![\d])")
_TILL = re.compile(r"\b(?:till|buy goods|paybill|pay bill|account|acc(?:ount)? (?:no|number)|a/c)\b[^.\n]{0,25}?\b\d{4,}\b", re.I)
_URL = re.compile(r"(?:https?://|www\.)[^\s<>\"')\]]+|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|co\.ke|ke|org|net|io|app|me|info|biz|xyz)\b(?:/[^\s<>\"')\]]*)?", re.I)
_PROMISE = re.compile(
    r"\b(?:guarantee[ds]?|100\s?%\s?(?:safe|secure|protected)|fully (?:safe|secure|protected|insured|licensed)|"
    r"completely (?:safe|secure)|risk[- ]free|broka[- ]approved|approved by broka|"
    r"(?:licen[sc]ed|regulated|authori[sz]ed|registered|supervised) (?:by|with) (?:the )?(?:cbk|central bank|capital markets|cma|ca\b|communications authority|safaricom|government|kenya)|"
    r"(?:cbk|central bank)[- ](?:licen[sc]ed|regulated|approved)|you (?:will|'ll) (?:definitely |certainly )?(?:get|receive) (?:your )?(?:money|refund) back|"
    r"your money is (?:safe|secure|protected|guaranteed)|(?:can|will) (?:recover|get back) (?:your )?(?:money|funds))\b", re.I)
_PERCENT = re.compile(r"(\d+(?:\.\d+)?)\s?%")
# A percentage that is a price: "charge around 3%", "a 2% fee" - not "a 70% chance".
_FEE_WORDS = re.compile(r"\b(?:fees?|charg\w*|commission|cost\w*|pric\w*|takes?|deduct\w*|rate)\b", re.I)
_KSH = re.compile(r"(?:ksh?s?\.?|kes|shillings?)\s?(\d[\d,]*(?:\.\d+)?)|(\d[\d,]*(?:\.\d+)?)\s?(?:ksh?s?|kes|shillings?)\b", re.I)

# Hosts BROKA itself uses, and the official sources it sends people to. A
# model may name these; any other address is refused.
_OTHER_OFFICIAL_HOSTS = frozenset({
    "broka.co.ke", "safaricom.co.ke", "ardhisasa.lands.go.ke", "ecitizen.go.ke", "ntsa.go.ke",
})

GUARD_FALLBACK = (
    "I can't give specific payment details, fees or contact numbers myself, because I could get "
    "them wrong. For exact figures, open the provider's official website yourself - from Broka's "
    "list, never from a link someone sends you - and check its own pages. Broka's escrow "
    "comparison shows the fees each provider has published, and which ones need a live quotation."
)


def _host_ok(host: str, records: Iterable[dict]) -> bool:
    host = host.lower().strip(".")
    host = host[4:] if host.startswith("www.") else host
    if host in _OTHER_OFFICIAL_HOSTS or any(host.endswith("." + h) for h in _OTHER_OFFICIAL_HOSTS):
        return True
    return any(host == r["identity"]["canonical_domain"] for r in records
               if r["status"] in ("approved", "under_review"))


def _figures(record: dict) -> tuple[set[str], set[str]]:
    """Percentages and shilling amounts a provider's record publishes - the
    only ones Zeno may attribute to it."""
    pcts: set[str] = set()
    amounts: set[str] = set()

    def walk(value) -> None:
        if isinstance(value, dict):
            for k, v in value.items():
                if k == "percent" and v is not None:
                    pcts.add(_norm_number(str(v)))
                elif k in ("fixed", "min", "max", "min_amount", "max_amount") and v is not None:
                    amounts.add(_norm_number(str(v)))
                else:
                    walk(v)
        elif isinstance(value, list):
            for item in value:
                walk(item)
    walk(record["pricing"])
    for key in ("min_amount", "max_amount"):
        if record["conditions"].get(key) is not None:
            amounts.add(_norm_number(str(record["conditions"][key])))
    return pcts, amounts


def _norm_number(text: str) -> str:
    text = text.replace(",", "").strip()
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text


# What the M-Pesa network itself limits - a fact about M-Pesa, not a provider's fee.
_MPESA_LIMIT_AMOUNTS = {"250000", "500000", "150000"}


_DIGIT_WORDS = {"zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                "six": "6", "seven": "7", "eight": "8", "nine": "9", "sifuri": "0", "moja": "1", "mbili": "2",
                "tatu": "3", "nne": "4", "tano": "5", "sita": "6", "saba": "7", "nane": "8", "tisa": "9"}
_DIGIT_WORD_RUN = re.compile(r"\b(?:" + "|".join(_DIGIT_WORDS) + r")(?:[\s,.-]+(?:" + "|".join(_DIGIT_WORDS) + r")){3,}\b", re.I)
# A "double"/"triple" before a digit word, as people read numbers aloud.
_EMAIL = re.compile(r"[A-Za-z0-9._%+-]+\s?(?:@|\(at\)|\[at\])\s?[A-Za-z0-9-]+(?:\s?(?:\.|\(dot\)|\[dot\])\s?[A-Za-z0-9-]+)+", re.I)
_SHORTENERS = re.compile(r"\b(?:bit\.ly|tinyurl\.com|t\.co|goo\.gl|is\.gd|cutt\.ly|rb\.gy|shorturl\.at|wa\.me|t\.me|linktr\.ee)\b", re.I)


_DIGIT_RUN = re.compile(r"\d(?:[\s.\-]{0,2}\d){7,}")


def _hides_a_phone_number(text: str) -> bool:
    """A run of digits joined by spaces, dots or dashes that, with the
    separators taken out, is a Kenyan phone number (07/01 + 8 digits, or 254
    + 9). Judged by the digits alone, so "0 7 1 2 3 4 5 6 7 8" and
    "0712.345.678" are caught and a date, a price or "1 to 3 days" is not:
    it must be 10 digits starting 07/01, or 12 starting 254."""
    for run in _DIGIT_RUN.finditer(text):
        digits = re.sub(r"\D", "", run.group(0))
        if (len(digits) == 10 and digits[:2] in ("07", "01")) or (len(digits) == 12 and digits.startswith("254")):
            return True
    return False


def _normalise_reply(text: str) -> str:
    """The reply with the tricks that hide an ADDRESS or a SPELLED-OUT NUMBER
    undone, so the checks see what a person would read: "dot" is a dot, a
    defanged link ("hxxps", "[.]") is a link again, and digits written as words
    ("seven one two ...", "saba moja ...") are digits. Digits hidden by
    separators are NOT rewritten here (that mangled "192.168.1.5" and real
    prices): _hides_a_phone_number judges those from their digits alone. Used
    for CHECKING only - what is shown is the original, or the fallback."""
    t = text
    t = re.sub(r"hxxp", "http", t, flags=re.I)
    t = re.sub(r"\s?(?:\[\.\]|\(\.\)|\{\.\})\s?", ".", t)
    t = re.sub(r"\s+(?:dot|\(dot\)|\[dot\])\s+", ".", t, flags=re.I)

    def spell(m: "re.Match[str]") -> str:
        return "".join(_DIGIT_WORDS[w.lower()] for w in re.findall(r"[A-Za-z]+", m.group(0)))
    t = _DIGIT_WORD_RUN.sub(spell, t)
    return t


def guard_reply(reply: str, records: list[dict]) -> tuple[str, list[str]]:
    """[reply] if it is safe to show, else (GUARD_FALLBACK, why).

    Checks, in order: a phone/till/paybill/long number; a web address that
    is not an approved provider's or a known official site; a promise BROKA
    has not earned; and a fee figure next to a provider that does not
    publish that figure. Returns (text, violations); violations is empty
    when the reply passed unchanged."""
    problems: list[str] = []
    text = reply or ""
    seen = _normalise_reply(text)
    for view in (text, seen):
        if _PHONE.search(view) or _LONG_DIGITS.search(view) or _hides_a_phone_number(view):
            problems.append("phone_or_account_number")
        if _TILL.search(view):
            problems.append("till_or_paybill")
    if _EMAIL.search(seen):
        problems.append("email_address")
    if _SHORTENERS.search(seen):
        problems.append("shortened_link")
    for m in _URL.finditer(seen):
        host = re.sub(r"^https?://", "", m.group(0).lower()).split("/")[0].split(":")[0]
        if "." in host and not _host_ok(host, records):
            problems.append(f"unapproved_address:{host}")
    if _PROMISE.search(text):
        problems.append("unearned_promise")

    # Fee figures. A figure is judged against the provider it is about: the
    # one the sentence names, or - "Lipasafe is simple. It charges 2.5%" -
    # the one most recently named before it. A model that spreads a made-up
    # fee over two sentences must not slip past a check that reads one.
    # Figures that belong to no provider at all are general knowledge
    # ("M-Pesa tops out at KSh 250,000") and left alone, EXCEPT a percentage
    # in a reply about escrow providers: "most charge around 3%" is, to the
    # person reading it, a fee, and BROKA has no source for it.
    listed = [r for r in records if r["status"] != "draft"]
    current: list[dict] = []
    about_providers = bool(re.search(r"\bescrow\b", text, re.I)) or bool(aliases.mentions(text, listed))
    for sentence in re.split(r"(?<=[.!?\n])\s+", text):
        named = aliases.mentions(sentence, listed)
        if named:
            current = named
        pcts = [_norm_number(m.group(1)) for m in _PERCENT.finditer(sentence)]
        amounts = [_norm_number(next(g for g in m.groups() if g)) for m in _KSH.finditer(sentence)]
        if not pcts and not amounts:
            continue
        if not current:
            if about_providers and pcts and _FEE_WORDS.search(sentence):
                problems.append("unsourced_fee_percentage")
            continue
        for record in current:
            known_pcts, known_amounts = _figures(record)
            if any(p not in known_pcts for p in pcts):
                problems.append(f"invented_percentage:{record['id']}")
            if any(a not in known_amounts and a not in _MPESA_LIMIT_AMOUNTS for a in amounts):
                problems.append(f"invented_amount:{record['id']}")
    if problems:
        return GUARD_FALLBACK, sorted(set(problems))
    return text, []


# ── The paragraph every Zeno prompt gets ─────────────────────────────────

# For prompts built ONCE at import (negotiate.py's chat prompts): the scam
# rules and nothing that depends on the catalogue. A provider list baked in at
# import would keep naming a provider after an administrator suspended it, until
# the next deploy - so providers are never named here; the assistant's own
# prompt, rebuilt every turn, carries them (fraud_policy below).
STATIC_POLICY = """

FRAUD PREVENTION (applies on top of everything above):
- Never invent or estimate an escrow fee, a phone number, a paybill, till or account number, a licence, or what an escrow provider can do. If you do not have the figure from this conversation's own context, say you do not know and tell the user to check the provider's own website, which they open themselves - never from a link someone sends them. Never give a web address.
- You cannot say any provider is safe, approved, licensed or guaranteed, and BROKA cannot recover money held by or sent through a provider. Never promise a refund.
- Repeat when money comes up: never share an M-Pesa PIN, an OTP or a password with anyone; never pay a personal number given in chat in place of the provider's official checkout; a screenshot or a forwarded SMS is not proof of payment or that escrow is funded, so check the real status on the provider's own account or page; before approving an M-Pesa prompt check the payee, the amount and the purpose; an unofficial "agent" who promises to release escrow money is a scammer.
- Name these patterns calmly, without accusing the person: pressure to pay at once; a deposit to reserve an item; a request to bypass escrow; unexpected "customer care"; a fake or forwarded M-Pesa message; a request for an OTP, PIN or password; a price far below the market; a changed payment destination.
- Buyers: do not release before receiving and inspecting; keep delivery evidence; open a dispute before the confirmation deadline. Sellers: do not dispatch on a screenshot; check the real escrow status yourself; keep evidence of delivery.
- After a suspected scam: stop the payment or delivery if possible, keep messages, numbers, receipts and transaction IDs, contact the provider on its official details, report it to BROKA in the app, contact the payment provider promptly, and report crime to the police.""".rstrip()


def fraud_policy(records: Iterable[dict]) -> str:
    """Instructions for the model: the facts about each provider it may use,
    and the rules it must keep. Built from the catalogue each time, so a
    suspended provider is told off as one, and a fee the catalogue does not
    have is stated as unknown rather than left for the model to fill."""
    shown, not_listed = [], []
    for r in records:
        if r["status"] in ("approved", "under_review"):
            shown.append(r)
        elif r["status"] == "suspended" or r.get("public_notice"):
            not_listed.append(r)
    lines = []
    for r in shown:
        from api.domains.escrow_directory import projection
        status = ("reviewed by Broka" if r["status"] == "approved"
                  else "Broka has NOT finished reviewing it: say so when you mention it")
        lines.append(
            f"  - {r['display_name']} - official site https://{r['identity']['canonical_domain']}/ - "
            f"{status}. Fee: {projection.fee_summary(r)} Limits: {projection.limits_summary(r['conditions'])}.")
    unlisted = "".join(
        f"\n  - {r['display_name']} ({r['identity']['canonical_domain']}) is NOT on Broka's list: never "
        "recommend it, and never mix it up with a similarly named provider." for r in not_listed)
    return f"""

FRAUD PREVENTION - you are the user's first defence against scams (this applies on top of everything above):
- Escrow providers you may discuss, with the only facts you may state about them:
{chr(10).join(lines)}{unlisted}
  If a figure, limit, licence, contact or capability is not above, say you do not know and tell the user to check the provider's own website. NEVER invent or estimate a fee, a phone number, a paybill or till number, an account number, a licence, or what a provider can do. NEVER give a web address that is not one above.
- Broka does not hold money, run escrow or guarantee any provider. You can compare providers' published costs and limits; you cannot say one is safe, approved, licensed or guaranteed, and you must not say a provider will definitely refund anyone. Never rank providers by cost unless every figure you compare is stated above; "fee not published" is not cheaper or dearer.
- Teach these before anyone pays, and repeat them whenever money comes up: never share an M-Pesa PIN, an OTP or a password with anyone; never pay a personal number given in chat as an alternative to the provider's official checkout; a screenshot or a forwarded SMS is not proof of payment or that escrow is funded - check the real status on the provider's own account or page; before approving an M-Pesa prompt, check the payee, the amount and the purpose; an unofficial "agent" who promises to release escrow money is a scammer.
- Watch for and name these patterns, calmly, without accusing the person: pressure to pay at once; a deposit to reserve an item; a request to bypass escrow; a "customer care" or "escrow agent" contact nobody asked for; a fake or forwarded M-Pesa message; a request for an OTP, PIN or password; a price far below the market; a changed payment destination or a personal number replacing the official checkout.
- Buyers: do not release before receiving and inspecting; compare against the written description; keep delivery evidence; open a dispute before the confirmation deadline; do not confirm because of pressure. Sellers: do not dispatch on a screenshot; check the real escrow status yourself; keep evidence; use a delivery method with proof of handover; do not hand over goods because someone says an agent will pay later.
- Before paying, help both sides agree: the exact item or service, its condition, the price, delivery method and date and who pays it, the inspection period, return or damage conditions, milestones for services and big purchases, how a dispute is raised, and who pays the escrow fee. Encourage both to verify the deal on the provider's official site, opened by themselves.
- After a suspected scam: stop the payment or delivery if they still can; keep messages, numbers, receipts and transaction IDs; contact the provider on its official contact details; report it to Broka in the app; contact the payment provider (for example Safaricom) quickly if money went by a fraudulent route; report crime to the police. Never promise Broka can recover money held by or sent through a provider.""".rstrip()
