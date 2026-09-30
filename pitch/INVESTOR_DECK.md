# BROKA — investor deck specification (draft v2, 30 September 2026)

The deck is a Slides artifact: <https://claude.ai/artifact/7qgtJmng7zonM6dSQYWZzC>
(private until shared from its Share menu; PDF and PowerPoint export from the
same menu). This file is its specification: the story, the evidence behind
every claim, a claim-by-claim audit, and what only the founder can supply.

v2 is a fact-first revision of v1. It keeps the thesis, adds an evidence
label to every claim, and states plainly what the next round has to prove.

**How the screens were made.** Apart from one real device screenshot (slide
16), every phone and browser image was recreated from the source code:
colours from `BrokaColors` (`flutter_app/lib/main.dart`), layouts and copy
from the screen files named in `pitch/screens.html`, the constellation from
`web/src/lib/constellation.ts`, and the real logo and Zeno artwork from
`flutter_app/assets/images/`. All names, prices, ratings and counts in them
are **demo data**, and each slide that shows them says so. Regenerate with
`node pitch/render-screens.js` (see its header).

**Scope.** No logistics layer anywhere.

---

## 1. The story

BROKA has built an unusually complete transaction architecture for an
early-stage company: Zeno mediates the negotiation between buyer and seller
through two private channels, while the agreed terms, payment state,
reputation and dispute evidence stay attached to one deal record that the
language model cannot change on its own.

It has not yet proven marketplace liquidity, repeat usage, transaction volume
or revenue.

The next stage is to prove that Zeno-mediated negotiation plus transaction
protection produces repeatable, completed commerce in selected Kenyan
categories. If that loop works, the transaction data, reputation system and
liquidity it creates become the basis for defensibility and expansion.

**The investment question (slide 17):** can Zeno-mediated, protected
transactions produce more completed commerce than ordinary marketplace
conversations?

## 2. Evidence labels

| Label | Meaning | BROKA today |
|---|---|---|
| **BUILT** | Exists in the product or codebase | End to end: marketplace, Zeno, escrow flow, disputes, stores |
| **TESTED** | Passes automated tests; not customer-validated | 1,056 backend tests (SQLite + Redis), 1,057 on PostgreSQL 16, 228 Flutter, 51 web (`REPO_REVIEW.md`, 25 Sep 2026) |
| **LIVE / VERIFIED** | Works in real production conditions | Partial: the Android build runs on a real device (founder's screenshot). Escrow is **not** verified live |
| **OBSERVED** | Shown by real users, transactions or measured behaviour | Nothing yet: no reported users, deals or revenue |
| **ASSUMPTION** | A modelling input, not validated | Price acceptance, volumes, deal frequency and value, cost inputs |
| **THESIS** | A belief about the future | Data moats, expansion, voice commerce |

Two further tags are used where needed: **PENDING** (built, awaiting live
verification) and **EXTERNAL DATA** (a sourced statistic about Kenya, not
about BROKA). **DEMO DATA** marks recreated screens.

---

## 3. Slides

Type scale 120 / 72 / 44 / 32 / 24 px on 1920×1080. Headings Georgia (the
app's typeface), body DM Sans. Palette from `BrokaColors`. Glow effects from
v1 were removed; the dimmer constellation background is used throughout, so
the deck reads as commerce infrastructure, not an AI-chatbot pitch. Speaker
notes for every slide are in the deck.

| # | Title | Purpose | Evidence status | Key sources |
|---|---|---|---|---|
| 1 | An AI broker in every deal. | What BROKA is, what Zeno does, how the deal model differs, and the stage | Stage stated: built and tested, pre-launch | `README.md`, `ARCHITECTURE.md` |
| 2 | Built and tested; not yet proven. | Defines the six evidence labels and where BROKA sits on each | BUILT, TESTED; LIVE partial; OBSERVED none | `REPO_REVIEW.md`, founder screenshot |
| 3 | The deal is scattered across channels. | Problem = fragmentation: no single shared record across negotiation, terms, payment, delivery and disputes | EXTERNAL DATA; markup ILLUSTRATIVE | TransUnion (9 Jun 2026), KNBS 2026, founder's example |
| 4 | A broker's real value is coordinating the deal between two people. | Insight: broker functions become transparent software workflows; escrow on a partner, escalations to people | Find/Vouch/Negotiate/Settle BUILT; Hold PENDING | Domain code under `backend/api/domains/` |
| 5 | Two private channels. Only facts cross. | Zeno's mechanism and its limits | BUILT, TESTED; not measured with users | `routers/negotiate.py`, `PRIVACY.md`, `tests/test_message_visibility_guard.py` |
| 6 | The record decides, not the model. | Architecture: what the model may do vs what only the record and people decide | BUILT; escrow step PENDING | `negotiate.py` intents, `escrow/service.py` (`finalize_deal`, `lock_deal_if_status`) |
| 7 | One thread, from question to payout. | Six stages with status per stage | Stages 1–4 BUILT; 5–6 PENDING | `api/domains/escrow/`, `ESCROW_AUDIT.md` |
| 8 | What BROKA looks like today. | Product exists; no claim of scale | BUILT; DEMO DATA | Screen files in `flutter_app/lib` |
| 9 | Designed to reduce fraud, not remove it. | Trust mechanisms, each with its status | Escrow BUILT + PENDING; record, leaks, disputes BUILT + TESTED | `ARCHITECTURE.md`, `SELLER_METRICS.md`, `api/core/text_guard.py`, `DISPUTE_AUDIT.md` |
| 10 | A shop, a link, and a measured record. | Seller tools; fee incentive as a proposed model | Stores/stats/Zeno BUILT; fees PROPOSED (off, unvalidated) | `STORES_PLAN.md`, `PRICING.md` §2 |
| 11 | Kenya is digitally reachable. | Infrastructure indicators, explicitly not demand | EXTERNAL DATA | CA, FinAccess 2024, DataReportal 2026, KNBS 2026 |
| 12 | An illustrative scenario, not a forecast. | How commission scales under stated assumptions (three scenarios) | ASSUMPTION | Arithmetic below; DataReportal for the 4% reference |
| 13 | Four planned revenue lines. | Revenue lines, modelled variable costs, and what is not yet included | Revenue PLANNED; costs ASSUMPTION; exclusions NOT YET | `PRICING.md`, `api/domains/pricing/` |
| 14 | AI inside the transaction, not beside it. | Transaction-model comparison by category | THESIS; competitor cells category-level | Qualitative; see audit rows 32–33 |
| 15 | A foundation, not yet a moat. | Engineering maturity vs the path to defensibility | Foundation BUILT, TESTED; moats THESIS | `graphify.md`, `REPO_REVIEW.md` |
| 16 | Built vs unproven. | Product readiness (renamed from "traction") | BUILT, TESTED; NOT YET list; real screenshot | Repository; founder screenshot |
| 17 | What this round must prove | The investment question and seven proofs with their metrics | TO BE PROVEN | — |
| 18 | First, prove the loop in Kenya. | Vision with NOW dominant; NEXT planned; LATER thesis | NOW objective; NEXT planned; LATER THESIS | `STORES_PLAN.md`, README roadmap |
| 19 | Who builds BROKA. | Founder, and execution evidence from the repository | Name as given by the founder; the rest [MISSING] | Founder input |
| 20 | Raising [amount] to prove the transaction loop. | The round and the transaction milestones it buys | All values [TO SET BY FOUNDER] | Founder input |

### What changed from v1, slide by slide

- **1 (cover):** the subtitle says what BROKA is, what Zeno does and what's different about the deal record; a stage line says "built and tested, pre-launch". Glow effects removed.
- **2 (new):** evidence ladder, so no reader confuses "we built it" with "the market wants it".
- **3 (problem):** "no referee" replaced by fragmentation, with the shared-record problem statement. TransUnion wording now matches the source's denominators. KNBS labelled as scale, not users. The markup card is stamped ILLUSTRATIVE.
- **4 (insight):** "software can do each of them" replaced by "turns broker functions into transparent software workflows"; the Zeno portrait was removed; each function has a status tag.
- **5–6 (Zeno):** now two slides. The second shows the architecture (private channels → deal record → escrow → delivery → completion or dispute) and splits what the model may do from what only the record and people decide. It says plainly that the model is not immune to error or manipulation.
- **7 (journey):** pay and complete are tagged PENDING; the footer says architecture is not market validation.
- **8 (product):** DEMO DATA tag; "not real activity" in the footer.
- **9 (trust):** the headline is "Designed to reduce fraud, not remove it."; each mechanism is tagged built, tested or pending. E-Confirm is no longer described as holding money today.
- **10 (sellers):** `f = C × R` replaced by "performance lowers fees", defines performance, gives a worked example, and says it is proposed and unvalidated.
- **11–12 (market):** split into infrastructure indicators and an illustrative scenario with three cases, each input labelled an assumption, and the 1M ceiling explained.
- **13 (business model):** "all above cost" removed; shows revenue, modelled variable costs, and what is not included; cloud-cost coverage is not break-even.
- **14 (competition):** transaction-model table using words ("Varies", "Limited", "One side only") where a tick would not be defensible; no claim that competitors lack protection.
- **15 (technology):** renamed "technology foundation and path to defensibility"; endpoints, tables and tests are called engineering maturity, not a moat.
- **16 (readiness):** renamed from "traction"; the footer says this is product progress, not commercial traction.
- **17 (new):** the investment question and seven proofs with metrics.
- **18 (vision):** NOW dominates: prove the loop in Kenya.
- **19 (team):** "Xxavier — Founder & CEO", the name you supplied, plus execution evidence from the repository; the other fields are marked missing.
- **20 (ask):** transaction milestones; every value marked for the founder to set.

---

## 4. Claim-by-claim audit

Checked on 30 September 2026. "Wording check" confirms the slide says no more
than the source measured.

| # | Claim (slide) | Type | Source | Wording check / status |
|---|---|---|---|---|
| 1 | 39% of Kenyans reporting digital-fraud losses named third-party seller scams on legitimate sites (3) | External | TransUnion newsroom, 9 Jun 2026: "Among Kenyans who reported losing money to digital fraud in the past year, nearly four in ten (39%) said it was via third-party seller scams on legitimate websites" | Matches; denominator kept |
| 2 | KES 108,132 median reported loss among Kenyans who lost money to scams in the past year (3) | External | Same release: among those "who reported losing money through email, online, phone call or text message scams over the past year" | Matches; channels shortened to "scams" |
| 3 | TransUnion: 2.3% of Kenyan transaction attempts suspected fraudulent in 2025, vs 3.8% globally (3, notes only) | External | Same release | Included in the notes for balance |
| 4 | 83.8% of employment informal, 18.1M workers (3, 11) | External | KNBS Economic Survey 2026 (2025 data), via Eastleigh Voice and Nairobi Leo | Labelled scale of activity, not BROKA users. Verify against KNBS PDF |
| 5 | KES 200,000 → 250,000 markup (3) | Illustration | Founder's example | Stamped ILLUSTRATIVE; "not observed market data" |
| 6 | 84.1M active mobile subscriptions, 157.7% penetration, Jan–Mar 2026 (11) | External | CA Sector Statistics Q3 FY2025/26, via Citizen Digital / Telecom Review Africa | "SIMs, not people". Verify against the CA PDF (CA's site was unreachable from the build environment) |
| 7 | 82.3% of adults used mobile money, 22.9M (11) | External | 2024 FinAccess Household Survey (CBK, KNBS, FSD Kenya) | Matches. v1's "52.6% daily" was dropped: secondary sources leave its denominator unclear |
| 8 | 23.4M internet users; 18.4M social media identities (11, 12) | External | DataReportal, Digital 2026: Kenya | "Identities, not unique people" |
| 9 | Kenyan B2C e-commerce ≈ US$2.6bn, 2025 (11 footer) | External, low confidence | ResearchAndMarkets databook (GlobeNewswire, Jan 2026) | Labelled third-party estimate; context only |
| 10 | 1M active traders ≈ 4% of internet users (12) | Assumption | 1M ÷ 23.4M = 4.3% | Called a round-number ceiling, not a measured population |
| 11 | Scenario A/B/C GMV and commission (12) | Assumption | 100k×2×15,000 = KES 3.0bn → ×3.49% = KES 104.7M ≈ US$0.81M; 250k → 7.5bn → 261.8M ≈ US$2.02M; 1M → 30bn → 1.047bn ≈ US$8.08M (KES 129.5/US$) | Arithmetic checked; every input labelled |
| 12 | Commission 3.49% (min KES 20; 4% at auction); E-Confirm 1% (7, 13) | Built, not charged | `PRICING.md` §6; `settings.commission_rate` | Designed prices; nothing charged yet |
| 13 | Listing fees KES 9–3,000/month; store plans KES 499–6,999; subscriptions 199/599/1,499 (13) | Built, switched off | `PRICING.md`; `LISTING_FEES_ENABLED`, `PREMIUM_ENABLED` default false | "Planned"; store billing not built |
| 14 | Phone listing KES 150 list; 85 new seller; 67 proven (10) | Built, unvalidated | `PRICING.md` §2 worked examples ("Monthly" column) | Labelled proposed |
| 15 | ~KES 0.12 AI per negotiation message (13) | Assumption | `PRICING.md` §1 (token counts × DeepSeek rates; half cached, 40% at peak) | Labelled modelled |
| 16 | KES 698 revenue vs ~KES 13 modelled direct cost on a KES 20,000 deal (13) | Assumption | `PRICING.md` §6 | "Modelled"; footer says cloud coverage is not break-even |
| 17 | M-Pesa KES 0–54; SMS 0.35; voice ~2.14/min; AI images 5.18 (13) | Assumption | `PRICING.md` §1 | Provider prices checked Sept 2026 by PRICING.md |
| 18 | 181 endpoints, 41 tables (15) | Built | `graphify.md` (generated 30 Sep 2026; 41 tables counted) | Called maturity, not a moat |
| 19 | ~1,050 backend tests on SQLite and PostgreSQL; 228 app; 51 web (2, 15) | Tested | `REPO_REVIEW.md` §0 (1,056 / 1,057 / 228 / 51) | Rounded down; re-run CI before quoting |
| 20 | 21 categories (16) | Built | `web/src/lib/categories.ts` (21 entries, checked against the backend seed by its tests) | Matches |
| 21 | Android build runs on a real device (2, 16) | Live (partial) | Founder's screenshot | Only claim at LIVE level |
| 22 | Escrow built to E-Confirm's API spec; live verification pending (4, 6, 7, 9, 14, 16) | Built, pending | `ARCHITECTURE.md` ("Neither correction … verified against live E-Confirm v2 docs or a real sandbox") | Never described as operational |
| 23 | Automated refunds on E-Confirm deals not built (9, 16) | Not built | `REPO_REVIEW.md` §2 item 2; `negotiate.py` `_econfirm_holds_funds` | Fails closed and raises an alert |
| 24 | Deal created when a party taps Finalize; server-validated (6) | Built | `escrow/service.py` `finalize_deal` (caller must be the seller or the named buyer; price validated) | Known gap in notes: a seller can finalize naming a buyer who never agreed (`ESCROW_AUDIT.md`, still open) |
| 25 | Fund-moving steps only through explicit, state-driven intents, never parsed from model text (6) | Built | `negotiate.py` intents; `negotiate_screen.dart` ("Action buttons are driven entirely by the deal's DB state") | Matches |
| 26 | Neither side reads the other's private messages (5) | Tested | `tests/test_message_visibility_guard.py`, `PRIVACY.md` | "Rules enforced in code and tests"; not a guarantee against model error |
| 27 | Zeno doesn't share budget ceilings or opinions (5) | Built | Prompt rules in `negotiate.py`; Buying Agent auto-opener fix (`buy_agent_subscribers.py`) | Stated as design rule |
| 28 | Actions Zeno proposes wait for a person (5, 6) | Built, tested | `ZENO_ACTIONS.md` ("No action auto-executes") | Matches |
| 29 | Seller record: rating/10, completion, reply time, daily (9) | Built, tested | `SELLER_METRICS.md` | "Not meaningful until there are deals" |
| 30 | Leak scanning lowers rank; leak rate not measured (9) | Built, tested | `api/core/text_guard.py`, `trust/completion_rate.py` | Matches |
| 31 | Store link previews in WhatsApp; visits by source (10) | Built | `README.md` (2026-09-24), `stores/stats.py` | Matches |
| 32 | Competitor cells (14) | Qualitative | Category-level description | "Varies"/"Limited" used wherever a product in the category could disprove a yes/no. Verify current Jiji and Facebook Marketplace protection offerings in Kenya before presenting |
| 33 | "AI assistants: advise one side; one side only" (14) | Qualitative | General knowledge of general-purpose assistants | They don't mediate two parties in a deal; wording avoids claiming they can't negotiate |
| 34 | Moats: none at meaningful scale (15) | Thesis | — | Stated plainly |
| 35 | Languages: English and Kiswahili good; others wired (5 notes, 18) | Built | `PRICING.md` §1 "Languages" | Others "not at claimable quality" |
| 36 | Traction: users, listings, deals, GMV (16) | Missing | — | Kept as [MISSING DATA — DO NOT INVENT] |

**Checks from the brief, answered:**
- *Every number's origin:* rows 1–20 above.
- *Built, tested, live or planned:* every product claim carries a label on the slide.
- *Could a competitor disprove it?* The v1 claim that classifieds lack protection is gone; category cells use "Varies" or "Limited".
- *Observed data or our model?* Slide 11 is external data; slide 12 is labelled a model on every line.
- *Does BROKA already have this moat at scale?* No; slide 15 says so.
- *Do financials include all variable costs?* No; slide 13 lists what is excluded.
- *Is there transaction evidence behind a traction claim?* There are no traction claims.

## 5. Metric hierarchy (what the deck will report once there is data)

| Group | Metrics |
|---|---|
| Marketplace | Active buyers · active sellers · active listings, per category |
| Transaction | Deals initiated · deals agreed · escrow-funded deals · completed deals · GMV |
| Conversion | Listing → conversation → negotiation → agreement → funded → completed |
| Trust | Completion rate · dispute rate · refund rate · off-platform (leak) attempt rate |
| Retention | Buyer repeat rate · seller repeat rate |
| Economics | Revenue per transaction · variable cost per transaction · contribution margin |
| Zeno | Agreement rate and time to agreement, Zeno-mediated threads vs direct chat · Zeno action proposals vs acceptances |

Instrumentation already in the codebase that feeds these: the deal state
machine and ledger, `seller_metric_snapshots` (daily), leak findings in the
audit log, store visit/share counts, `feature_usage`, and per-call AI cost
logging recommended in `PRICING.md` §10.

## 6. Still needed from the founder

The deck keeps these as visible placeholders. Nothing was estimated.

1. **Team (slide 19):** background, previous products and experience, time commitment, whether solo, other team members, advisors (only if agreed). Confirm the spelling of the name: the slide uses "Xxavier" as you wrote it; `CHANGES.md` spells "Xavier".
2. **The ask (slide 20):** amount (KES/US$), instrument, runway, use-of-funds split, and the numeric targets for each milestone.
3. **Real numbers, if any exist (slide 16):** users, listings, conversations, deals, GMV, with dates.
4. **E-Confirm:** agreement status and the date of live verification.
5. **Legal:** opinion on the escrow model (CBK), Data Protection Act registration.
6. **Go-to-market:** the two launch categories and how supply will be acquired (a slide for this should be added once decided).
7. **Contact details** for slide 20.

## 7. Investor red-team (updated for v2)

1. *"Where's the traction?"* None, and slides 2 and 16 say so. The round is framed around proving it (slide 17).
2. *"Why would buyers pay 4.49% when cash on delivery is free?"* Unproven; slide 17 row 3 measures willingness to transact; add a pricing test to the pilot.
3. *"Why would sellers pay listing fees when classifieds are free?"* The fee model is labelled proposed and unvalidated (slide 10); measure conversion once fees are switched on.
4. *"What stops deals leaving for WhatsApp?"* Leak scanning plus completion-rate-based ranking and fees (slide 9); leak rate not yet measured.
5. *"Isn't this a wrapper?"* Slide 6: the model cannot change deal or payment state; slide 15: models are interchangeable, and the moat is not claimed yet.
6. *"Are you an unlicensed escrow business?"* E-Confirm holds funds; a legal opinion is a milestone (slide 20).
7. *"What if Zeno gets it wrong?"* Slide 5 admits it can; slide 6 shows why money doesn't depend on it; add an adversarial evaluation set.
8. *"Which category first?"* Not yet in the deck (section 6, item 6).
9. *"Unit economics?"* Slide 13: one-deal contribution is modelled; CAC, fraud losses and overhead excluded and stated.
10. *"Can this team execute?"* The repository is the evidence; slide 19 needs the founder's details.

## 8. Quality review (honest, out of 10)

| Dimension | v1 | v2 | Note |
|---|---|---|---|
| Clarity | 8 | 8.5 | Investment question and evidence labels make the stage unmistakable |
| Storytelling | 7.5 | 8 | Built → what's unproven → what the round proves |
| Product credibility | 8 | 8.5 | Architecture slide explains why the model doesn't set financial state |
| Visual quality | 7.5 | 7.5 | Less glow; still recreated screens with emoji placeholder photos; not visually QA'd in the renderer |
| Market evidence | 5.5 | 6 | Correctly labelled; still no BROKA-specific demand evidence |
| Business model clarity | 7 | 7.5 | Cost inclusions and exclusions explicit |
| Defensibility | 4.5 | 4.5 | Honestly framed as thesis; unchanged in substance |
| Traction | 2 | 2 | None; now clearly framed as product readiness |
| Investor readiness | 4 | 5 | Team and ask still need the founder's inputs |

## Appendix — sources

- TransUnion newsroom, "Suspected Digital Fraud in Kenya Falls Below Global Rate in 2025 as Consumers Report Third-Party Seller Scams Drove the Most Losses" (9 Jun 2026)
- KNBS Economic Survey 2026 (2025 data), reported by Eastleigh Voice and Nairobi Leo
- Communications Authority of Kenya, Sector Statistics Q3 FY2025/26, reported by Citizen Digital and Telecom Review Africa
- 2024 FinAccess Household Survey (CBK, KNBS, FSD Kenya)
- DataReportal, Digital 2026: Kenya
- ResearchAndMarkets, Kenya B2C Ecommerce Databook (GlobeNewswire, 29 Jan 2026)
- Repository documents: `README.md`, `ARCHITECTURE.md`, `PRICING.md`, `REPO_REVIEW.md`, `ESCROW_AUDIT.md`, `DISPUTE_AUDIT.md`, `ZENO_ACTIONS.md`, `SELLER_METRICS.md`, `STORES_PLAN.md`, `PRIVACY.md`, `graphify.md`

Asset ids in the Slides artifact: backgrounds bg1/bg2; phones home, neg-buyer,
neg-seller (v2), listing, zeno, voice, pay, deal, mystore, dash; browser web;
crops j1–j6, crop_fee, crop_standing; real device real_zone; brand broka_icon,
broka_logo_transparent, zeno_full, zeno_icon.
