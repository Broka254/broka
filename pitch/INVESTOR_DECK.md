# BROKA — investor deck specification (draft v1, 30 September 2026)

The deck itself is a Slides artifact: <https://claude.ai/artifact/7qgtJmng7zonM6dSQYWZzC>
(private until shared from its Share menu). This file is its specification:
what each slide says and why, the speaker notes, where every claim comes from,
what is missing, and how an investor is likely to attack it.

**How the screens were made.** No device screenshots were available except one
(the Construction Zone, slide 13). Every other phone and browser image was
recreated from the source code: colours from `BrokaColors`
(`flutter_app/lib/main.dart`), layouts and copy from the screen files named in
`screens.html`, the constellation from `web/src/lib/constellation.ts`, and the
real logo and Zeno artwork from `flutter_app/assets/images/`. Names, prices,
ratings and visit counts inside the screens are **demo data**, and the deck
says so on every slide that shows them. `pitch/screens.html` is the source;
`node pitch/render-screens.js` renders it (see the file's header). Replace the
recreations with real screenshots once the app has real listings (section E).

**Scope.** The logistics layer is excluded throughout, as briefed.

---

## 0. What the repository shows (the basis for every claim)

- **Product thesis in code.** Zeno sits inside the buyer–seller thread
  (`backend/api/routers/negotiate.py`): a cheap classifier decides whether a
  message needs relaying; relayed facts are rewritten for the other side, in
  that side's language; each side gets private replies; every reply is
  grounded in the message record so Zeno cannot claim a reply that never
  happened; `tests/test_message_visibility_guard.py` enforces that neither side
  reads the other's copy. Actions Zeno proposes (call, SMS draft, direct chat)
  come from a closed list and wait for a tap (`ZENO_ACTIONS.md`).
- **Zeno beyond negotiation.** The assistant tab (`/zeno/assistant/turn`),
  voice mode that follows the user across screens, "Ask Zeno about this
  listing", guides built from the user's own data, and the Buying Agent: a
  conversational search that asks at most two questions and reports near
  misses honestly, plus standing "watches" that match new listings; it only
  opens a negotiation with a seller if the buyer pre-authorised it, and never
  leaks the buyer's budget (`api/domains/buy_agent/`, `api/core/buy_agent_subscribers.py`).
- **Money.** E-Confirm escrow for the full agreed price, M-Pesa (Daraja) for
  BROKA's own fees, a double-entry ledger, row-locked status changes,
  idempotency keys, reconciliation alerts, and a dispute engine with evidence,
  timers and escalation. Audited and fixed for double-payout races
  (`ESCROW_AUDIT.md`, `DISPUTE_AUDIT.md`). **Not verified against E-Confirm's
  live sandbox** (`ARCHITECTURE.md`); automated refunds on E-Confirm deals are
  not built (they fail closed and alert a person, `REPO_REVIEW.md`).
- **Trust signals.** Seller overall rating out of 10, deal completion rate,
  response time, measured daily with history (`SELLER_METRICS.md`); a Rust
  contact-leak scanner whose findings mark a deal as leaked and lower the
  seller's rank (`api/core/text_guard.py`, `backend/native/`).
- **Sellers.** Online stores with a fixed link `broka.co.ke/store/<name>`, a
  Next.js web storefront, link previews, visit and share counts by source, My
  Store, the Seller Dashboard with trend charts and rule-based advice.
- **Pricing.** Fully specified and implemented in `api/domains/pricing/`
  (`PRICING.md`): commission 3.49% + E-Confirm 1% paid by the buyer; monthly
  listing fee `f = C × R`; store plans; Plus/Pro/Elite. **Listing fees and
  premium are switched off** (`LISTING_FEES_ENABLED`, `PREMIUM_ENABLED`
  default false); store billing is not built. PRICING.md states there are no
  completed deals yet, and sizes its costs at a planning scale "BROKA can
  reach, not today's".
- **Engineering.** 181 endpoints, 41 tables (`graphify.md`); 1,056 backend
  tests on SQLite + Redis and 1,057 on PostgreSQL 16, 228 Flutter tests, 51
  web tests (`REPO_REVIEW.md`, 25 Sep 2026). Android APK from CI; iOS not
  released. Backend on Render, with an Azure migration audited but not done.
- **Traction.** Nothing in the repository reports users, listings, deals or
  revenue. The founder's screenshot shows a live build with an empty
  Construction category. Traction is therefore shown as product progress plus
  an explicit gap.

**The strongest narrative** is not "an AI marketplace". It is: *the broker's
job (find, vouch, negotiate, hold the money, settle) can be done by software,
for both sides at once, with the money in escrow and a record that makes
reputation real.* BROKA has built that end to end; what it has not yet shown
is that people use it.

---

## Slides

Type scale used throughout: 120 / 72 / 44 / 32 / 24 px on a 1920×1080 canvas.
Headings in Georgia (the app's typeface), body in DM Sans (close to the web
storefront). Palette from `BrokaColors`: near-black `#03040A`, card
`#111D35`, violet `#8B5CF6` (text accent `#AE8DF8`), blue `#3B82F6`, cyan
`#22D3EE`, green `#10B981`, amber `#FBBF24`, text `#E3D9F7` / `#8A9BBF`.
Backgrounds are the app's constellation, rendered with the web storefront's
own algorithm and seed.

### SLIDE 1
**TITLE:** BROKA — An AI broker in every deal.

**PURPOSE:** Establish identity and the one-line idea; show the product
immediately.

**MAIN MESSAGE:** BROKA is a marketplace where Zeno brokers each deal and the
money waits in escrow.

**EXACT ON-SLIDE COPY:**
- BROKA
- INTELLIGENT COMMERCE · KENYA FIRST
- An AI broker in every deal.
- A marketplace where Zeno helps buyers and sellers find, negotiate and close, while the money waits in escrow until delivery.
- Investor presentation · Draft for discussion · September 2026
- Footer: Screens recreated from the BROKA source code (Flutter app, Next.js storefront). Names, prices and numbers in screens are demo data.

**VISUAL DIRECTION:** Constellation background; logo tile and gradient
wordmark (violet→blue, as on Home); two layered phones on the right.

**BROKA UI / SCREENSHOT REQUIRED:** Home screen; Zeno negotiation room (buyer
view). Replace with real device screenshots when real listings exist.

**DATA / CHART:** None.

**DIAGRAM:** None.

**SPEAKER NOTES:** Open with the one-line idea: every deal gets a broker, and
the broker is software, Zeno. Point at the negotiation room. Say the money is
held by an escrow partner (E-Confirm) until the buyer confirms delivery. Say
the screens are recreated from the codebase with demo data, and offer to show
the real Android app. No "future of commerce", no traction claims here.

**SOURCE / EVIDENCE:** `README.md`, `ARCHITECTURE.md`; screens from
`screens/home_screen.dart`, `screens/negotiate_screen.dart`.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** What is this, in one sentence?

---

### SLIDE 2
**TITLE:** Today's deal has no referee.

**PURPOSE:** Make the problem concrete and painful, with evidence.

**MAIN MESSAGE:** Finding, haggling and paying are split across channels, so
nobody keeps the record and nobody holds the money; fraud is common and
costly.

**EXACT ON-SLIDE COPY:**
- THE PROBLEM
- Today's deal has no referee.
- Finding, haggling and paying happen in different places, and nobody holds the money.
- Chain: Buyer — Searches groups and classifieds — *Scattered* → Middleman — Adds a markup nobody sees — *Opaque price* → Chat & calls — Haggling that leaves no record — *No record* → Pay first — Sends M-Pesa before delivery — *Scam risk* → Seller — Can't prove a good record — *No reputation*
- 39% — of Kenyans who lost money to fraud were hit by third-party seller scams — TransUnion, Jun 2026
- KES 108k — median loss per fraud victim, the highest of the African markets studied — TransUnion, Jun 2026
- 83.8% — of Kenyan employment is informal: 18.1 million workers — KNBS Economic Survey 2026
- +25% — a KES 200,000 item offered at KES 250,000 through a middleman — Illustration, not market data
- Footer: Sources: TransUnion fraud report, Kenya (9 Jun 2026); KNBS Economic Survey 2026.

**VISUAL DIRECTION:** Five-step chain of cards with arrows, each tagged with
its friction in words (colour never carries the meaning alone); four stat
cards below; the illustration card dashed to set it apart from data.

**BROKA UI / SCREENSHOT REQUIRED:** None.

**DATA / CHART:** Stat cards (see copy).

**DIAGRAM:** Buyer → Middleman → Chat & calls → Pay first → Seller.

**SPEAKER NOTES:** Walk the chain. Cite TransUnion (39% of Kenyans who lost
money to digital fraud lost it to third-party seller scams on legitimate
sites; median loss ~KES 108,000, highest of the African markets studied) and
KNBS (84% informal employment). Present the +25% as your own example of
broker markup, not an average. If asked whether fraud or friction is the
real pain: both, and user research will show which changes behaviour. Never
say BROKA eliminates fraud.

**SOURCE / EVIDENCE:** TransUnion newsroom, "Suspected Digital Fraud in Kenya
Falls Below Global Rate in 2025…" (9 Jun 2026); KNBS Economic Survey 2026
(2025 data, via press coverage); founder's anecdote.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Is the problem real and painful?

---

### SLIDE 3
**TITLE:** What if the intermediary was software?

**PURPOSE:** The conceptual turn: decompose the broker's job.

**MAIN MESSAGE:** A broker does five jobs; each can be done in software, in
the open, for both sides at once.

**EXACT ON-SLIDE COPY:**
- THE INSIGHT
- What if the intermediary was software?
- A broker does five jobs. Software can do each of them in the open, for both sides at once.
- Find — Search and the Buying Agent · Vouch — A measured seller record · Negotiate — Zeno in the thread · Hold — Escrow via E-Confirm · Settle — Release, or a dispute

**VISUAL DIRECTION:** Accent statement slide (violet-to-navy gradient), the
largest type in the deck, Zeno's character art in a glowing circle, five job
cards along the bottom.

**BROKA UI / SCREENSHOT REQUIRED:** `zeno_full.png` (real asset).

**DATA / CHART:** None.

**DIAGRAM:** Five jobs mapped to five BROKA components.

**SPEAKER NOTES:** Pause on the question. Map each job to what exists in the
code. Keep the claim narrow: we make the broker's functions available to both
sides with a record; we don't claim to replace every human broker. "Intelligent
transaction layer" is our thesis, not an established category. If asked "why
now": model costs have fallen to about KES 0.12 of AI per negotiation message
(PRICING.md estimate), mobile money is universal, and most phones are
smartphones.

**SOURCE / EVIDENCE:** Components: search/Buying Agent (`api/domains/buy_agent/`),
seller metrics (`api/domains/trust/`), negotiation (`routers/negotiate.py`),
escrow (`api/domains/escrow/`), disputes (`api/domains/disputes/`).

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Why does AI materially change this?

---

### SLIDE 4
**TITLE:** Buyer ↔ Zeno ↔ Seller

**PURPOSE:** Show the mechanism in under 30 seconds.

**MAIN MESSAGE:** One deal, two private channels; only facts cross, and Zeno
never moves money.

**EXACT ON-SLIDE COPY:**
- THE SOLUTION
- Buyer ↔ Zeno ↔ Seller
- One deal, two private channels. Only facts cross.
- Zeno does: Relays facts: availability, offers, delivery · Rewrites each message in each side's language · Coaches each side privately, on its side · Keeps the whole deal on one record
- Zeno never: Shares one side's opinions or budget · Claims a reply the record doesn't show · Moves money: people confirm, escrow settles
- Footer: Two private views of one thread, recreated from source. Names and prices are demo data.

**VISUAL DIRECTION:** Buyer's phone left, seller's phone right, Zeno's avatar
and the rules between them. Each phone carries a "YOUR PRIVATE ZENO · BUYER /
SELLER" label.

**BROKA UI / SCREENSHOT REQUIRED:** Negotiation room, buyer and seller views
of the same deal (recreated).

**DATA / CHART:** None.

**DIAGRAM:** The two-channel layout itself.

**SPEAKER NOTES:** Explain the relay classifier, fresh drafts in each side's
language, grounding in the record, and pre-authorised openers that never leak
the buyer's budget. Actions wait for a tap; money moves only on a person's
confirmation through escrow. "Isn't this a chatbot?" — a chatbot answers one
person; Zeno holds two private channels with tested rules about what crosses.
Languages: English and Kiswahili work well; Sheng, Dholuo, Kikuyu and Luganda
are wired in but not at claimable quality (PRICING.md §1).

**SOURCE / EVIDENCE:** `routers/negotiate.py` module docstring and prompts;
`PRIVACY.md`; `ZENO_ACTIONS.md`; `tests/test_message_visibility_guard.py`;
`api/core/buy_agent_subscribers.py`.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Can I understand the solution in 30 seconds?

---

### SLIDE 5
**TITLE:** One thread, from question to payout.

**PURPOSE:** The transaction journey with real UI elements.

**MAIN MESSAGE:** Discover → Ask → Negotiate → Agree → Pay → Complete, in one
thread, with the deal's state protected.

**EXACT ON-SLIDE COPY:**
- HOW BROKA WORKS
- One thread, from question to payout.
- 1 · DISCOVER — Search, browse zones, or tell Zeno
- 2 · ASK — Ask Zeno about price, seller, delivery
- 3 · NEGOTIATE — Zeno relays offers, coaches each side
- 4 · AGREE — Both sides finalize; the price locks
- 5 · PAY — M-Pesa in; E-Confirm holds the price
- 6 · COMPLETE — Buyer confirms, seller is paid
- States: Agreed → Paid, held in escrow → Released to seller · or · Disputed: funds stay frozen
- Footer: Every status change happens under the deal's row lock and is written to a double-entry ledger.

**VISUAL DIRECTION:** Six cards, each topped with a zoomed crop of the real UI
element for that step; a state strip beneath.

**BROKA UI / SCREENSHOT REQUIRED:** Crops: Home search + rail; "Ask Zeno about
this listing" card; negotiation bubbles; seller's Finalize button; payment
breakdown; escrow timeline.

**DATA / CHART:** None.

**DIAGRAM:** Deal state strip (agreed → paid → released, dispute branch).

**SPEAKER NOTES:** One sentence per step. The listing context is loaded by id
on the server, so a client can't feed Zeno a fake price. The buyer pays 4.49%
on top (3.49% BROKA, 1% E-Confirm). For technical investors: row locks,
idempotent payment prompts, double-entry ledger, hardened in audits. Don't
overclaim: E-Confirm is built to its API spec but not yet exercised live.

**SOURCE / EVIDENCE:** `api/domains/escrow/`, `api/core/ledger.py`,
`api/core/idempotency.py`, `ESCROW_AUDIT.md`, `DISPUTE_AUDIT.md`,
`api/domains/zeno_assistant/listing_context.py`, `PRICING.md` §6.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** How does a deal actually happen?

---

### SLIDE 6
**TITLE:** Built, with Zeno in every screen.

**PURPOSE:** Prove the product exists and is coherent.

**MAIN MESSAGE:** Five surfaces of a working Android app, each with Zeno in it.

**EXACT ON-SLIDE COPY:**
- THE PRODUCT
- Built, with Zeno in every screen.
- Home: search, zones, and Zeno one tap away
- Listing: deal terms and the seller's measured record
- Zeno: ask, search, or set a Buying Agent watch
- Voice mode: talk to Zeno across screens
- My Store: link, visits by source, what needs you
- Footer: Recreated from flutter_app/lib (Android build via CI). Listings, names and counts are demo data.

**VISUAL DIRECTION:** Five phones in a row with captions; staggered rise-in.

**BROKA UI / SCREENSHOT REQUIRED:** Home, Listing, Zeno assistant + Buying
Agent, Voice mode, My Store (recreated).

**DATA / CHART:** None.

**DIAGRAM:** None.

**SPEAKER NOTES:** One line per phone. The listing's seller standing replaced a
made-up "credibility" score and nothing on it is self-reported. Assistant
actions: open a screen, search, start the Buying Agent, open a chat, propose a
call (always a tap). Voice stops listening after a minute of silence because
speech is billed per minute. Say Android-only; iOS isn't released.

**SOURCE / EVIDENCE:** `screens/home_screen.dart`, `screens/product_screen.dart`,
`screens/zeno_screen.dart`, `features/zeno_assistant/`,
`features/stores/presentation/my_store_screen.dart`.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Is there a real product?

---

### SLIDE 7
**TITLE:** Money waits. Reputation is measured.

**PURPOSE:** Show the trust infrastructure without overclaiming.

**MAIN MESSAGE:** Escrow for the full price, a record buyers can check, deals
kept on the platform, and disputes with evidence.

**EXACT ON-SLIDE COPY:**
- TRUST
- Money waits. Reputation is measured.
- Escrow for the full price — E-Confirm holds the buyer's money. The seller is paid when the buyer confirms delivery.
- A record buyers can check — Rating out of 10, completion rate and reply time, computed daily from real deals and chats.
- Deals kept on BROKA — Every message is scanned for phone numbers, handles and tills, even disguised ones. Leaks lower the seller's rank.
- Disputes with evidence — Funds freeze, both sides add evidence, timers run, and a person decides escalated cases.
- Footer: Designed to reduce fraud, not remove it. E-Confirm integration awaits live verification.

**VISUAL DIRECTION:** Payment and Deal Status phones on the left; four
icon-led mechanisms on the right.

**BROKA UI / SCREENSHOT REQUIRED:** Complete Payment (STK prompt, fee
breakdown); Deal Status (escrow timeline, Confirm Delivery, Open Dispute).

**DATA / CHART:** Fee breakdown inside the payment screen (demo amounts that
follow the real rates: KES 32,000 + 1,117 + 320 = 33,437).

**DIAGRAM:** None.

**SPEAKER NOTES:** BROKA never holds the goods money in the E-Confirm flow,
which matters for regulation (counsel still needed). The rating's weights,
smoothing and anti-farming; the Rust scanner and how findings affect rank;
disputes audited for double payouts. Say "designed to reduce fraud"; E-Confirm
live verification and automated E-Confirm refunds are outstanding.

**SOURCE / EVIDENCE:** `ARCHITECTURE.md` (E-Confirm section),
`SELLER_METRICS.md`, `api/core/text_guard.py`, `backend/native/rules/contact_leaks.json`,
`DISPUTE_AUDIT.md`, `REPO_REVIEW.md` §2.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Why would anyone trust a stranger here?

---

### SLIDE 8
**TITLE:** A shop, a link, and a record that pays.

**PURPOSE:** Explain why sellers join and stay.

**MAIN MESSAGE:** Sellers get a storefront link for the channels they already
use, stats by channel, fees that fall with a good record, and Zeno covering
the chat.

**EXACT ON-SLIDE COPY:**
- THE SELLER ECONOMY
- A shop, a link, and a record that pays.
- Your own storefront — broka.co.ke/store/your-name works without the app and shows a preview in WhatsApp.
- See which channel sells — Visits and shares are counted per day and per source.
- A record that lowers fees — The monthly listing fee is f = C × R. A proven seller pays about half the list price.
- Zeno covers the chat — It answers buyers at any hour and nudges you when one is waiting.
- Footer: Storefront recreated from web/src (Next.js); My Store from my_store_screen.dart. Visit numbers are demo data.

**VISUAL DIRECTION:** Layered composition: browser frame of the web
storefront, My Store phone overlapping it, and a zoomed listing-fee card
("KES 150 → KES 85, 43% off").

**BROKA UI / SCREENSHOT REQUIRED:** Web storefront (`/store/<name>`); My
Store; listing-fee card from the Seller Dashboard.

**DATA / CHART:** Visits by source (demo data, labelled).

**DIAGRAM:** None.

**SPEAKER NOTES:** Stores meet sellers where they already sell (WhatsApp,
TikTok, Instagram). The fee: C is the list price, R comes from the seller's
completion rate; proven sellers pay ~43–57% below list, leaky sellers near
full; money can't buy the discount. Zeno nudges a seller when a buyer has
waited five minutes. Not built: store checkout and store billing; fees off.

**SOURCE / EVIDENCE:** `STORES_PLAN.md`, `web/src/`, `api/domains/stores/stats.py`,
`PRICING.md` §2–§5, `core/interest_arming.py`, `ZENO_ACTIONS.md` (availability reminder).

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Why would sellers use BROKA, and stay?

---

### SLIDE 9
**TITLE:** Kenya already trades on its phones.

**PURPOSE:** Size the opportunity credibly: behaviour first, bottom-up
arithmetic second, top-down as context only.

**MAIN MESSAGE:** The rails exist (mobile, mobile money, social, informal
trade); a bottom-up illustration shows how commission scales.

**EXACT ON-SLIDE COPY:**
- MARKET · KENYA FIRST
- Kenya already trades on its phones.
- 84.1M — mobile subscriptions; 157.7% penetration — CA, Jan–Mar 2026
- 82.3% — of adults use mobile money; 52.6% daily — FinAccess 2024
- 23.4M — internet users; 18.4M social media identities — DataReportal 2026
- 18.1M — informal workers: 83.8% of employment — KNBS 2026
- Sizing it bottom-up: an illustration, not a forecast
- Active traders 1M × Deals each a year 2 × Average deal KES 15k × BROKA's take 3.49% = Commission a year KES 1.05bn (≈ US$8M at KES 129.5)
- 1M traders ≈ 4% of Kenya's internet users. Listing fees, stores and plans come on top.
- Footer: Context: B2C e-commerce ≈ US$2.6bn (2025, third-party estimate) misses most informal trade.

**VISUAL DIRECTION:** Four stat tiles; a formula card with the result
highlighted.

**BROKA UI / SCREENSHOT REQUIRED:** None.

**DATA / CHART:** Stat tiles; formula. Arithmetic: 1,000,000 × 2 × 15,000 =
KES 30bn GMV × 3.49% = KES 1.047bn ≈ US$8.08M at KES 129.5/US$.

**DIAGRAM:** Formula row.

**SPEAKER NOTES:** Lead with behaviour. The top-down e-commerce number misses
informal and social trade, so it's context. Every bottom-up input is an
assumption to be replaced by pilot data (share of internet users who trade in
our categories, deal frequency, average value). East Africa belongs on the
vision slide.

**SOURCE / EVIDENCE:** CA sector statistics Q3 FY2025/26 (via Citizen Digital,
Telecom Review Africa); FinAccess 2024 (CBK/KNBS/FSD Kenya); DataReportal
Digital 2026 Kenya; KNBS Economic Survey 2026; ResearchAndMarkets Kenya B2C
Ecommerce Databook (Jan 2026 release); USD/KES from `PRICING.md`.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** How big can this get, and how do you know?

---

### SLIDE 10
**TITLE:** Four revenue lines, all above cost.

**PURPOSE:** Who pays, why, when, and what it costs to serve.

**MAIN MESSAGE:** Commission (buyer-paid), listing fees, store plans and
premium, each priced above a costed floor; nothing is charged yet.

**EXACT ON-SLIDE COPY:**
- BUSINESS MODEL
- Four revenue lines, all above cost.
- Table — Revenue line | Who pays, and when | Price (VAT included) | Cost to serve
  - Commission | Buyer, when a deal completes in escrow | 3.49% (min KES 20); 4% at auction; E-Confirm's 1% passed through | ~KES 13 to carry a deal
  - Listing fee | Seller, monthly, from day one | KES 9–3,000 a month: f = C × R, less for a better record | KES 7.45–11.36 per listing-month
  - Store plan | Long-term seller, monthly | KES 499–6,999 for 20–500 listings; no listing fees inside | KES 203–4,395 at full use
  - Premium | Buyers and sellers who want Zeno working for them | Plus 199 · Pro 599 · Elite 1,499 KES a month | Priced ≥1.25× cost at maximum use
- KES 698 — BROKA's share of one KES 20,000 phone deal
- KES 0.12 — estimated AI cost of one negotiation message
- ~48 deals — a month cover the ~KES 33,200 launch cloud bill
- Footer: Status: pricing built and switched off until launch; store billing not built; no revenue yet.

**VISUAL DIRECTION:** One table, three stat cards; status in the footer.

**BROKA UI / SCREENSHOT REQUIRED:** Optional: Listing fee screen, Premium screen.

**DATA / CHART:** Table and stat cards as above.

**DIAGRAM:** None.

**SPEAKER NOTES:** All prices are designed and in code; none charged yet.
Commission is in line with buyer-protection fees abroad (eBay UK, Vinted,
Depop ~4.5–5%). Listing fees bring income before any deal closes; the launch
bill is covered by ~48 phone deals or ~590 phone listings a month. Metrics to
measure: realised take rate, escrow completion vs leakage, fee conversion, AI
cost per completed deal, dispute cost per deal. Biggest risk: Jiji is free.

**SOURCE / EVIDENCE:** `PRICING.md` §1–§8 and `api/domains/pricing/`
(`costs.py`, `engine.py`, `plans.py`); `backend/api/core/config.py` flags.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** How does BROKA make money, and can it at the unit level?

---

### SLIDE 11
**TITLE:** Each alternative solves one part.

**PURPOSE:** A fair, category-level landscape.

**MAIN MESSAGE:** Classifieds, retail, social, brokers and AI assistants each
solve a piece; BROKA's bet is the whole deal in one mediated thread, and its
gap is liquidity.

**EXACT ON-SLIDE COPY:**
- COMPETITIVE LANDSCAPE
- Each alternative solves one part.
- Table — Category | Examples | Built for | Where the deal closes | What a safe deal still lacks
  - Classifieds | Jiji, Facebook Marketplace | Reach; free listings | Off-platform: calls, cash | Payment protection; a record
  - Retail e-commerce | Jumia, Kilimall | Fixed-price catalogue | Checkout | Negotiation; used and informal goods
  - Social commerce | WhatsApp, TikTok, Instagram | Reach through your network | DMs, then M-Pesa to a number | Verified sellers; protection
  - Informal brokers | Dalali (middlemen) | Local knowledge, haggling | In person, in cash | A visible price; accountability
  - AI assistants | General chatbots, retailer bots | Answers and discovery | Somewhere else | Representing a side in a live deal
  - BROKA | Zeno + E-Confirm escrow | A completed, protected deal | One mediated thread | Liquidity: still to be earned
- Footer: A chatbot can be bolted on; a mediator has to be built into the deal. E-Confirm is a partner.

**VISUAL DIRECTION:** One table; the BROKA row highlighted, with its own gap
in amber.

**BROKA UI / SCREENSHOT REQUIRED:** None.

**DATA / CHART:** None (no scores, no checkmarks).

**DIAGRAM:** None.

**SPEAKER NOTES:** Be fair to each category. "Why can't Jiji/Jumia add a
chatbot?" They can; what's harder is rebuilding the deal around a mediator
(two private channels, deal states, escrow, reputation that prices fees, leak
detection), and records only matter where deals happen. Never say "no
competition".

**SOURCE / EVIDENCE:** Category descriptions are qualitative; Jumia commission
context in `PRICING.md` sources. Verify any competitor fact before quoting it.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Who else does this, and why can't they just add a chatbot?

---

### SLIDE 12
**TITLE:** More than a chatbot on a marketplace.

**PURPOSE:** Technical credibility for a non-technical audience; separate
current advantages from moats to earn.

**MAIN MESSAGE:** The AI is wired into deal state, escrow and reputation; the
models are interchangeable; data moats are goals, not assets yet.

**EXACT ON-SLIDE COPY:**
- TECHNOLOGY & DEFENSIBILITY
- More than a chatbot on a marketplace.
- SURFACES — Flutter app (Android) · Next.js storefront at broka.co.ke/store
- ZENO — Relay classifier → a private draft per side → checked against the record → closed action list
- DEAL CORE — FastAPI · 181 endpoints · 41 tables · deal states under row locks · double-entry ledger
- MONEY, TRUST — E-Confirm escrow · M-Pesa Daraja · seller metrics · Rust scanner for off-platform contacts
- AI MODELS — Gemini → DeepSeek → OpenRouter with circuit breakers; no single model is a dependency
- Advantages today: AI wired into deal state, escrow and reputation, not a text box · Rules before models: common turns cost no model call · Tested: 1,056 backend tests, 1,057 on PostgreSQL, 228 app, 51 web
- Moats still to earn: Seller records that set fees and ranking; they matter only at volume · Negotiation outcomes that sharpen Zeno's coaching · Liquidity in the first categories
- Footer: Counts from graphify.md and REPO_REVIEW.md (25 Sep 2026). Moats listed are goals, not current advantages.

**VISUAL DIRECTION:** Layered stack diagram, colour-coded with labels; two
short lists on the right, green and amber titles.

**BROKA UI / SCREENSHOT REQUIRED:** None.

**DATA / CHART:** None.

**DIAGRAM:** Five-layer stack.

**SPEAKER NOTES:** Read the stack bottom-up; models are swappable, the layers
above are BROKA's. Mention audits that found and fixed real money races with
regression tests. A funded competitor could copy features; not a seller's
record, once records exist.

**SOURCE / EVIDENCE:** `graphify.md`, `REPO_REVIEW.md` §0, `ARCHITECTURE.md`,
`AI_AUDIT.md`, `ZENO_ACTIONS.md`, `backend/native/README.md`.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Why is this more than a thin AI wrapper? What is defensible?

---

### SLIDE 13
**TITLE:** Built, and not yet proven.

**PURPOSE:** Honest traction: what exists, what doesn't, with a real
screenshot.

**MAIN MESSAGE:** The product is broad and tested; usage, revenue and live
escrow are not yet proven; supply is the next problem.

**EXACT ON-SLIDE COPY:**
- TRACTION & PRODUCT PROGRESS
- Built, and not yet proven.
- Built and tested: Marketplace: 21 categories, search, zones · Zeno negotiation room, private per side · Zeno assistant: text, voice, guides, actions · Buying Agent: conversational search, watches · Escrow (E-Confirm, full price) and M-Pesa · Deal state machine, double-entry ledger · Disputes: evidence, timers, escalation · Seller metrics: rating, completion, reply time · Online stores: setup, web storefront, stats · Auctions, in-app calls, AI cover images · Pricing engine: fees, plans, commission
- Not proven yet: Users, listings, completed deals, GMV: [MISSING DATA — DO NOT INVENT] · Revenue: none yet. Fees are switched off until launch. · E-Confirm escrow: built to spec; live sandbox test pending. · Not built: iOS release, store cart and checkout, E-Confirm automation in disputes.
- Real device, live build: no Construction listings yet
- Footer: Checked against the repository (README roadmap, REPO_REVIEW 25 Sep 2026). Screenshot supplied by the founder.

**VISUAL DIRECTION:** Checklist with icons, an amber "not proven" column, and
the founder's real screenshot in a device frame.

**BROKA UI / SCREENSHOT REQUIRED:** The real Construction Zone screenshot
(supplied). Add real metrics screenshots (admin summary) when available.

**DATA / CHART:** Replace the placeholder with the real funnel (section D).

**DIAGRAM:** None.

**SPEAKER NOTES:** Say the gaps before an investor finds them. Fill in real
numbers before any meeting, however small. What would move this slide: a
pilot in one or two categories with a few hundred real listings and the first
escrow-completed deals.

**SOURCE / EVIDENCE:** `README.md` roadmap; `REPO_REVIEW.md`; `ARCHITECTURE.md`
(E-Confirm verification note); `IOS_CALLING_SETUP.md`; `STORES_PLAN.md`
phases 4–5; config flags.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** What has actually been built, and what evidence says users want it?

---

### SLIDE 14
**TITLE:** Where Zeno goes next.

**PURPOSE:** Vision beyond the first market, without logistics and labelled
by certainty.

**MAIN MESSAGE:** Now: Zeno in every BROKA deal. Next: Zeno as every store's
salesperson. Later: voice-first, local-language commerce across East Africa.

**EXACT ON-SLIDE COPY:**
- VISION
- Where Zeno goes next.
- NOW · BUILT — Zeno in every deal on BROKA — Android app and web stores in Kenya · Negotiation, assistant, voice, Buying Agent · Escrow through E-Confirm
- NEXT · PLANNED — Zeno as every store's salesperson — Store cart and checkout, paid into escrow · "Ask this store" on each shop's own link · Multi-item bundle negotiation · An iOS release
- LATER · THESIS — Commerce by voice, in local languages — Sheng, Dholuo, Kikuyu, Luganda at full quality · More East African markets, each with a payment partner · A seller's record as trust that travels
- Footer: NEXT is in STORES_PLAN.md. LATER is thesis. GSMA 2025: ~1bn Africans don't yet use mobile internet.

**VISUAL DIRECTION:** Three horizon cards (green / violet / blue) and the
voice-mode phone.

**BROKA UI / SCREENSHOT REQUIRED:** Voice mode (recreated).

**DATA / CHART:** GSMA usage-gap figure in the footer.

**DIAGRAM:** Three horizons.

**SPEAKER NOTES:** Label each horizon for what it is. No market-share claims,
no Africa-wide timelines, nothing about logistics. The long-term question:
can software be the broker both sides trust? Kenya is where we prove it.

**SOURCE / EVIDENCE:** `STORES_PLAN.md`, `README.md` roadmap, `PRICING.md`
(languages), GSMA Mobile Economy Africa 2025.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** How big can this become beyond the first market?

---

### SLIDE 15 (added)
**TITLE:** Who builds BROKA.

**PURPOSE:** Team. Not in the brief; added because investors ask it first.

**MAIN MESSAGE:** [To be written by the founder.]

**EXACT ON-SLIDE COPY:**
- TEAM
- Who builds BROKA.
- [Founder name] — Founder & CEO — [Background, what you built before, why this problem is yours]
- [Co-founder or key hire] — [Role] — [Background; or the role this round will hire]
- [Advisors] — Payments, legal, growth — [Escrow and CBK regulation, marketplace growth in Kenya]
- What the repository shows: an Android app, an API with a Rust extension, a web storefront and payment integrations, all tested in CI on every push.
- Footer: [MISSING DATA — DO NOT INVENT]: names, backgrounds, team size, time in market.

**VISUAL DIRECTION:** Three dashed placeholder cards (dashed = unfinished).

**BROKA UI / SCREENSHOT REQUIRED:** Founder photos.

**DATA / CHART:** None.

**DIAGRAM:** None.

**SPEAKER NOTES:** Who you are, why you, team size and roles, hires funded by
the round. Point to the repository as evidence of execution. Don't overstate
team size or advisors.

**SOURCE / EVIDENCE:** Founder input required.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** Can this team execute?

---

### SLIDE 16
**TITLE:** Raising [amount] to prove the loop in Kenya.

**PURPOSE:** The ask, tied to milestones that retire the biggest risks.

**MAIN MESSAGE:** The round buys proof of one loop: listing → buyer → Zeno →
escrow → completed deal → better record.

**EXACT ON-SLIDE COPY:**
- THE ASK
- Raising [amount] to prove the loop in Kenya.
- Use of funds: Supply and buyers in launch categories [__%] · Product: store checkout, iOS, Zeno quality [__%] · Payments verification and legal [__%] · Team [__%]
- Instrument: [__] · Runway: [__ months] · Close: [__]
- Milestones this round should buy: 1. E-Confirm verified live; first [__] deals completed end to end 2. Two launch categories where most new listings get a buyer chat within 7 days 3. Listing fees switched on: [__] paying sellers 4. Completion and leak rates measured per category 5. Legal opinion on the escrow model; dispute refunds automated
- Proposed milestones: the founder confirms targets and dates.
- Footer: [Contact email] · broka.co.ke · [MISSING DATA — DO NOT INVENT]: amount, instrument, runway, allocation.

**VISUAL DIRECTION:** Accent gradient (matches slide 3), two panels.

**BROKA UI / SCREENSHOT REQUIRED:** None.

**DATA / CHART:** Use-of-funds split once known (a single stacked bar).

**DIAGRAM:** None.

**SPEAKER NOTES:** Frame the round around the loop. Milestones are proposals
to confirm. Pick launch categories from where you have supply (electronics is
a natural first: phones are the most-scammed item, per PRICING.md's category
notes). Have valuation answers ready; keep them off the slide. End on the
thesis.

**SOURCE / EVIDENCE:** Founder input required; milestones derived from the gaps
in sections B–D.

**INVESTOR QUESTION THIS SLIDE ANSWERS:** What do you need, and what will it prove?

---

## A. Executive story summary

Kenyan commerce runs on phones and mobile money, but a deal between strangers
still has no referee: discovery, haggling and payment are split across
classifieds, WhatsApp and M-Pesa, middlemen add markups nobody sees, and
fraud by fake sellers is common and expensive. BROKA's thesis is that the
broker's five jobs (find, vouch, negotiate, hold the money, settle) can be
done by software for both sides at once. Zeno, BROKA's AI broker, sits inside
each deal with a private channel to each side, relays only facts, and never
moves money; E-Confirm escrow holds the full price until the buyer confirms
delivery, and every deal feeds a measured seller record that also sets the
seller's fees. The product is built end to end and tested: marketplace,
negotiation room, assistant with voice, Buying Agent, escrow and disputes,
seller metrics, and online stores with a web storefront. Revenue comes from a
buyer-paid 3.49% commission, monthly listing fees that fall as a seller's
record improves, store plans and premium, all priced above costed floors but
switched off until launch. What is not yet proven is usage: there are no
reported users, deals or revenue, and the escrow integration still needs live
verification. The round should buy proof of one loop in one or two Kenyan
categories: listings that get buyers, deals that complete through escrow, and
sellers who pay.

## B. Missing information (needed before the deck is investor-ready)

1. **Traction:** registered users (buyers/sellers), active listings by
   category, weekly actives, conversations, finalized deals, escrow-completed
   deals, GMV, any revenue. Include dates.
2. **Team:** founders' names, backgrounds, roles, team size, time in market,
   advisors, hires planned.
3. **The ask:** amount, instrument, valuation expectations (off-slide),
   runway, use-of-funds split, target close.
4. **Go-to-market:** launch categories and why; how supply is acquired (e.g.
   stores from existing WhatsApp/TikTok sellers); how buyers arrive; budget
   and channels. The deck has no GTM slide yet; add one once decided.
5. **User evidence:** interviews or surveys on broker markups, fraud
   experience, willingness to pay 4.49% for protection, sellers' willingness
   to pay listing fees vs free classifieds.
6. **Partnerships and compliance:** E-Confirm agreement status and terms;
   sandbox/live verification date; legal opinion on the escrow model (CBK);
   Data Protection Act registration (ODPC); KRA/VAT status.
7. **Deployment status:** which backend is live (Render or Azure), uptime,
   whether the Play Store listing exists or only the APK.
8. **Unit economics once live:** measured AI cost per message and per
   completed deal; support cost per deal; CAC by channel.
9. **Founder's broker-markup example:** the real case behind the
   KES 200,000 → 250,000 illustration, if it can be described.
10. **Contact details** for the final slide.

## C. Claims that require verification

| # | Claim in the deck | Where | Verify with |
|---|---|---|---|
| 1 | 84.1M mobile subscriptions, 157.7% penetration (Jan–Mar 2026) | Slide 9 | CA Q3 FY2025/26 sector statistics PDF (quoted here from Citizen Digital / Telecom Review Africa; CA's site was not reachable from the build environment) |
| 2 | 82.3% of adults use mobile money; 52.6% daily | Slide 9 | 2024 FinAccess Household Survey main report (CBK/KNBS/FSD Kenya) |
| 3 | 23.4M internet users; 18.4M social media identities | Slide 9 | DataReportal Digital 2026: Kenya |
| 4 | 83.8% informal employment; 18.1M informal workers | Slides 2, 9 | KNBS Economic Survey 2026 (checked via press coverage) |
| 5 | 39% of fraud-loss victims hit by third-party seller scams; median loss KES 108,132 | Slide 2 | TransUnion newsroom release, 9 Jun 2026, and its methodology (survey sample) |
| 6 | Kenyan B2C e-commerce ≈ US$2.6bn (2025) | Slide 9 footer | ResearchAndMarkets databook; a commercial estimate, low confidence |
| 7 | ~1bn Africans not using mobile internet | Slide 14 footer | GSMA Mobile Economy Africa 2025 |
| 8 | +25% broker markup (KES 200,000 → 250,000) | Slide 2 | Founder's example; keep labelled as illustration |
| 9 | Buyer-protection fees of ~4.5–5% elsewhere (eBay UK, Vinted, Depop) | Slide 10 notes | Sources listed in `PRICING.md` |
| 10 | E-Confirm charges 1% and holds funds under an appropriate licence | Slides 5, 7, 10 | E-Confirm agreement; counsel |
| 11 | KES 0.12 AI cost per negotiation message; ~KES 13 to carry a deal; ~48 deals cover KES 33,200 | Slides 10, 12 notes | `PRICING.md` assumptions; replace with logged usage |
| 12 | 181 endpoints, 41 tables | Slide 12 | Regenerate `graphify.md` before the meeting |
| 13 | 1,056 / 1,057 backend tests, 228 app tests, 51 web tests | Slide 12 | Re-run CI; quote the current numbers |
| 14 | English and Kiswahili work well; other languages not yet | Slide 4 notes, 14 | Test Zeno conversations in each language |
| 15 | The app runs on Android from CI releases | Slides 1, 6, 13 | Live demo on a device |
| 16 | Leak findings lower the seller's rank; proven sellers pay ~half the list fee | Slides 7, 8 | Code paths exist (`completion_rate.py`, `engine.py`); effect unmeasured, fees off |
| 17 | Zeno never shares a side's opinions or budget | Slide 4 | Prompt rules + visibility tests; add an evaluation set of adversarial threads |
| 18 | Recreated screens match the app | All UI slides | Compare against device screenshots; replace recreations |

## D. Data collection checklist

**Funnel (weekly, by category):**
- installs; sign-ups split buyer / short-term seller / long-term seller
- listings created, listings live (paid where fees apply), listings with ≥1 buyer conversation within 7 days
- conversations started; Zeno messages per thread; share of messages relayed
- deals finalized; deals funded in escrow; deals completed (released); refunds; disputes opened and how they ended
- time from listing to first conversation, and to completed deal

**Money:**
- GMV and average deal value; realised take rate (commission ÷ GMV)
- completion rate per category (replace the guesses in `PRICING.md`'s category table at ~200 completed deals)
- leak rate: contact-leak findings per thread and per seller
- listing-fee conversion and renewal (once switched on); premium and store conversion
- payment failures and reconciliation alerts

**Cost:**
- AI tokens per call, per message, per completed deal (log from week one, as `PRICING.md` §10 asks)
- SMS, speech-to-text and AI-cover usage per plan
- support minutes per dispute; infra bill per active user

**Quality and trust:**
- Zeno action proposals vs acceptances; corrections or complaints about Zeno replies
- seller response time distribution; buyer repeat rate; 30/60/90-day retention for buyers and sellers
- buyer and seller trust surveys (e.g. "would you pay 4.49% for escrow?")
- fraud reports and outcomes

**Qualitative (before the next meeting):** 15–20 buyer and 15–20 seller
interviews in the launch categories: last purchase, channel used, markups
paid, fraud experienced, willingness to pay.

## E. Visual asset checklist

**Used in this draft (recreated from source unless noted):**
- BROKA icon and transparent logo, Zeno full art and icon (real, `flutter_app/assets/images/`)
- Constellation backgrounds (web storefront algorithm)
- Home; Listing; Negotiation room buyer + seller; Zeno assistant + Buying Agent; Voice mode; Complete Payment; Deal Status; My Store; Seller Dashboard with listing-fee card; Web storefront
- Six journey crops (search/rail, Ask Zeno card, negotiation bubbles, Finalize, payment breakdown, escrow timeline)
- Construction Zone empty state (**real device screenshot**, supplied by the founder)

**Needed for the investor-ready version:**
- Real device screenshots of every screen above, with real (or clearly staged) listings and real photos
- A 30–60 s screen recording: a negotiation from both phones, through payment
- A real web storefront (`broka.co.ke/store/<name>`) with a real seller's permission
- Real Seller Dashboard and My Store screenshots with real numbers
- Founder/team photos
- Funnel chart, weekly actives, completion rate by category, cohort retention (once data exists)
- Use-of-funds bar for the ask
- Optional: Play Store badge or APK QR code for the cover or closing slide

## F. Investor red-team

1. **"Where's the traction?"** The deck has none to show. Slide 13 says so
   and shows an empty category. Before sending the deck, fill in real
   numbers, however small, and show a pilot plan with weekly targets.
2. **"Why would a buyer pay 4.49% on top when cash on delivery and WhatsApp
   are free?"** Slides 2 and 7 give the fraud case and the protection.
   Evidence of willingness to pay is missing; run a pricing test in the first
   category and bring the result.
3. **"Why would a seller pay a listing fee when Jiji is free?"** Slide 8: the
   fee falls with a good record, the launch discount, and store links for
   social selling. The real answer is buyer quality; measure conversion per
   listing against free classifieds.
4. **"Zeno even offers direct chat. What stops the deal leaving for
   WhatsApp?"** Direct chat stays in the app and every message is scanned;
   leaks lower rank and raise fees; the buyer loses escrow protection
   off-platform. Unmeasured until there's volume: bring the leak rate.
5. **"Is this a thin wrapper? What if Google or OpenAI builds it?"** Slide 12:
   the models are interchangeable; the value is the deal core, escrow,
   reputation and privacy rules around them, and local payment rails. Be
   honest that data moats are future.
6. **"Are you running an unlicensed escrow or payment business?"** E-Confirm
   holds the goods money; BROKA collects only its own fees via M-Pesa. A legal
   opinion is a milestone on slide 16. Bring the E-Confirm agreement.
7. **"What happens when Zeno gets it wrong?"** Replies are grounded in the
   message record; actions need a tap; money moves only on a person's
   confirmation; disputes exist. Missing: an error-rate evaluation and a
   support process for AI mistakes. Build an adversarial test set.
8. **"Which category first, and how do you get supply?"** Not in the deck.
   Add a go-to-market slide with the first category, the seller acquisition
   channel (e.g. converting WhatsApp/TikTok sellers to stores) and the budget.
9. **"What does a completed deal cost you, and what does a user cost to
   acquire?"** Slide 10 shows designed costs (~KES 13 per deal, KES 0.12 per
   message). CAC is unknown. Log costs from day one.
10. **"Why now, and why you?"** Now: model costs low enough for KES-level
    unit economics, mobile money everywhere, most phones smartphones. You:
    slide 15 is a placeholder; the repository is strong evidence of execution,
    but the team story must be told.

**Biggest risk:** the cold start: enough listings in one category that buyers
find what they want, and enough buyers that sellers stay, while charging both
sides more than free alternatives. Leakage off-platform is the close second.

**What changed in the deck because of this red-team:**
- Added a Team slide (15) and labelled every missing input.
- Replaced a "future of intelligent commerce" tagline with a concrete one.
- Labelled the broker markup as an illustration; led the market slide with
  behaviour, used bottom-up arithmetic marked "not a forecast", and demoted
  the top-down e-commerce figure to context.
- Put "no revenue yet" and "fees switched off" on the business-model slide,
  "live verification pending" on the trust slide, and a real empty-category
  screenshot on the traction slide.
- Split "advantages today" from "moats still to earn"; gave BROKA's own row in
  the landscape table its gap (liquidity).
- Removed all logistics content.

## G. Final deck quality review (honest scores out of 10)

| Dimension | Score | Why |
|---|---|---|
| Clarity | 8 | One idea per slide; the mechanism (two private channels, escrow) is understandable in 30 s. |
| Storytelling | 7.5 | Problem → insight → mechanism → proof flows; weakened by missing GTM and team. |
| Product credibility | 8 | Deep, tested, end-to-end build; screens are faithful recreations rather than device captures; Android only. |
| Visual quality | 7.5 | Inherits the app's palette, type and constellation; product "photos" are the app's emoji placeholders; layout not visually QA'd in the slide renderer. |
| Market evidence | 5.5 | Credible, dated national statistics; no BROKA-specific demand evidence; sizing is illustrative. |
| Business model clarity | 7 | Clear, costed and implemented; nothing charged, take rate and willingness to pay unproven. |
| Defensibility | 4.5 | Real engineering depth; data and network moats are hypotheses until there is volume. |
| Traction | 2 | No users, deals or revenue reported; honestly flagged. |
| Investor readiness | 4 | Missing traction, team, ask and GTM. Share only after filling them. |

---

## Appendix 1 — Evidence table

| Claim | Source | Date | Confidence | Used on |
|---|---|---|---|---|
| 84.1M mobile subscriptions; 157.7% penetration | Communications Authority of Kenya, Sector Statistics Q3 FY2025/26, as reported by Citizen Digital and Telecom Review Africa | Jan–Mar 2026 | Medium (secondary) | 9 |
| 82.3% of adults use mobile money (22.9M); 52.6% daily | 2024 FinAccess Household Survey (CBK, KNBS, FSD Kenya) | Dec 2024 | High | 9 |
| 23.4M internet users (40.5%); 18.4M social media identities | DataReportal, Digital 2026: Kenya | End 2025 / Oct 2025 | Medium (modelled estimates) | 9 |
| 83.8% informal employment; 18.1M informal workers | KNBS Economic Survey 2026 (2025 data), via press | 2025 data | High (secondary citation) | 2, 9 |
| 39% of fraud-loss victims via third-party seller scams; median loss KES 108,132 | TransUnion newsroom (Top Fraud Trends, Kenya) | Published 9 Jun 2026 (2025 survey) | Medium–high (company survey) | 2 |
| Kenyan B2C e-commerce ≈ US$2.6bn in 2025 | ResearchAndMarkets Kenya B2C Ecommerce Databook (GlobeNewswire, Jan 2026) | 2025 | Low (commercial estimate) | 9 (context) |
| ~1bn Africans not using mobile internet; mobile = 7.8% of Africa's GDP | GSMA, The Mobile Economy Africa 2025 | Oct 2025 | Medium–high | 14 |
| Prices, costs, fee formula, VAT, launch cost | `PRICING.md`, `api/domains/pricing/` | Sep 2026 | High for design; assumptions flagged in PRICING.md §10 | 8, 10 |
| USD 1 = KES 129.5 | `PRICING.md` | Late Sep 2026 | Medium | 9 |
| Escrow design; E-Confirm not verified live | `ARCHITECTURE.md` | Sep 2026 | High | 5, 7, 13 |
| Endpoint and table counts | `graphify.md` (generated) | 30 Sep 2026 | High | 12 |
| Test counts | `REPO_REVIEW.md` §0 | 25 Sep 2026 | High at that date | 12 |
| Fees and premium switched off | `backend/api/core/config.py` (`LISTING_FEES_ENABLED`, `PREMIUM_ENABLED`), `PRICING.md` §4, §8 | Sep 2026 | High | 10, 13 |
| No completed deals yet | `PRICING.md` §2 ("There are no completed deals yet") | Sep 2026 | High | 13 |
| Empty Construction category | Founder's device screenshot | Sep 2026 | High | 13 |

Not used, deliberately: competitor traffic figures (third-party and
unverifiable), any market "TAM" presented as BROKA's, any projection presented
as traction, and all logistics material.

## Appendix 2 — Assets and blob ids in the Slides artifact

The deck references uploaded images by id; regenerate from `screens.html` and
re-upload to change them. Backgrounds: `bg1` (cover, vision) and `bg2`
(content slides). Phones: home, neg-buyer, neg-seller (v2), listing, zeno,
voice, pay, deal, mystore, dash; browser: web; crops: j1–j6, crop_fee,
crop_standing; real: real_zone; brand: broka_icon, broka_logo_transparent,
zeno_full, zeno_icon.
