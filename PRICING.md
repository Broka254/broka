# BROKA pricing

What BROKA charges, what it costs BROKA to run, and how one follows from the
other. Every price here comes out of the code in `backend/api/domains/pricing/`
(`costs.py`, `categories.py`, `engine.py`, `plans.py`; the payment is
`payments.py`); change a cost there and the prices move with it. Plans are
bought and counted in `backend/api/domains/premium/`.
`tests/test_pricing.py`, `tests/test_listing_fee_payment.py` and
`tests/test_premium.py` hold the promises below to the code: a proven seller
pays less than a new one, the fee never goes under cost, no plan loses money
on its heaviest user, a payment is applied once, for the amount asked, and a
premium feature is paid for before it costs BROKA anything.

Figures are in Kenyan shillings (KES), at **USD 1 = KES 129.5** (late September
2026). Provider prices were checked in September 2026; sources are at the end.

## The prices at a glance

| What | Price |
|---|---|
| **Commission**, negotiated deal | Buyer pays **4.49%** on top of the price: BROKA 3.49% + E-Confirm 1% |
| **Commission**, auction | Buyer pays **5%**: BROKA 4% + E-Confirm 1% |
| **Listing fee** | Monthly, per listing: `f = C × R`. KES 8–1,500 a month depending on category, value, quantity and the seller's record. 1 to 6 months at a time; longer is cheaper per month |
| **Featured placement** | Short-term sellers only: KES 99 for 7 days, KES 350 for 28 days |
| **Plus** | KES 169 / month: voice mode, Zeno's texts, a Buying Agent watch, AI covers for ~2 listings |
| **Pro** | KES 499 / month: Zeno negotiating for you, 3 watches, AI covers for ~7 listings, 2 auctions |
| **Elite** | KES 1,249 / month: volume allowances, AI covers for ~20 listings, priority support |
| **Free** | Buying, selling, typing to Zeno, negotiating, bidding and your own photos - plus 2 AI cover tries |
| **Store** | KES 299 to open (waived on 6+ months), then KES 249 (20 listings) to KES 4,999 (500 listings) a month; store listings pay no listing fee |

---

## 1. What BROKA costs to run

Everything BROKA pays for, per unit, and how BROKA uses it. Usage figures
marked *assumption* are estimates until the app logs the real numbers (see
§10).

### Per use

| Cost | Rate (Sept 2026) | How BROKA uses it | KES |
|---|---|---|---|
| **AI: DeepSeek V4.1 Flash** | $0.15 / 1M input tokens (cache miss), $0.003 (cache hit), $0.60 / 1M output - off-peak. Doubles at peak (04:00-07:00 and 09:00-13:00 EAT, weekdays) | One message in a negotiation runs 2-3 model calls (`api/core/ai_cost.py`): ~5,900 tokens in, ~380 out. *Assumption:* 40% of traffic at peak, half the input cached | **0.12 per message** |
| | | A negotiation thread: ~14 messages (*assumption*) | 1.72 per thread |
| | | Zeno as assistant / Buying Agent: ~3,000 in, 250 out | 0.07 per turn |
| | | Posting a listing: price help, description help, scam check | 0.21 per listing |
| | | Auto-negotiating one seller for a buyer: ~10 exchanges | 1.92 each |
| **SMS** | KES 0.25-0.80 a message in Kenya's bulk market; Mobitech does not publish its rate | Seller nudges, match alerts, OTPs | **0.50** |
| **Push (FCM)** | Free | Every routine notification | 0 |
| **Speech to text** | Deepgram Nova-3 streaming $0.0077/min (a $0.0048 promotion is running); AssemblyAI Universal-Streaming $0.15/hour | Voice mode. Costed at Deepgram's regular rate so switching providers never makes a plan lose money | 1.00 per minute |
| **Text to speech** | Microsoft Edge TTS: free, but an unofficial endpoint. A paid neural voice is ~$16 / 1M characters | Zeno speaking. A reserve is kept in case the free voice goes away | 0.93 per minute (reserve) |
| **Voice mode, all in** | STT + ~3 Zeno turns + TTS reserve | Counted per thing said to Zeno (a *voice request*): the server sees each spoken turn, not the microphone's minutes | **2.14 per minute**, 0.71 per request |
| **Calls (TURN)** | Cloudflare Realtime $0.05/GB after 1,000 GB free a month | Relayed voice ~0.6 MB/min, video ~9 MB/min. The free 1,000 GB is ~110,000 video minutes | < 0.06 per video minute - not priced |
| **AI Showcase image** | fal.ai FLUX.1 Kontext [pro], $0.04 an image | AI cover images, made while posting a listing. ~3 tries per listing (*assumption*: a seller tries a look or two before keeping one) | **5.18 per try**, ~15.5 per listing |
| **Email** | Resend: free for 3,000 a month | Email OTPs | 0 |
| **M-Pesa, collecting a fee** | Tariff of 7 Aug 2026: free to KES 100, KES 3 to 500, KES 5 to 1,000, capped at KES 54 | Charging listing fees and plans | 0-54 per payment |
| **E-Confirm** | 1% of the deal | Holds the buyer's money in escrow and pays the seller | Passed through to the buyer |

### Per month, at planning scale

Fixed costs are spread over the listings they serve. The **planning scale**
is 20,000 active listings and 15,000 monthly active users - a size BROKA can
reach, not today's.

| Cost | Rate | Sizing | KES / month |
|---|---|---|---|
| **Google Cloud Run**, africa-south1 (Johannesburg, the nearest region; Tier 2 pricing) | $0.0000336 / vCPU-s, $0.0000035 / GiB-s, $0.40 / 1M requests, after a free 180,000 vCPU-s, 360,000 GiB-s, 2M requests | Two always-warm instances of 1 vCPU / 1 GiB: call signalling sockets and the 5-minute sweep need a live process. ~1,500 requests per user a month | 25,368 |
| **Cloud SQL (PostgreSQL)** | db-custom-1-3840 ~$49/month in us-central1, SSD $0.22/GB; +30% for Africa (AWS's Cape Town premium over Virginia) | 1 vCPU, 3.75 GB, 50 GB SSD, backups | 10,670 |
| **Redis** | Upstash: $0.20 per 100K commands pay-as-you-go (~$90 at this traffic), so a fixed plan | Rate limits, pub/sub, caches | 2,590 |
| **Cloudflare R2** | $0.015/GB-month after 10 GB free; no egress fees | ~25 GB of listing images | 159 |
| **Internet egress** | $0.12/GB (Premium Tier) | API and sockets, ~20 MB per user; images come from R2 | 4,553 |
| **Vercel Pro** ($20), **Sentry Team** ($26), logging headroom ($10) | | The web storefront (Hobby forbids commercial use); error tracking | 7,252 |
| **App stores and domain** | Apple $99/year, Google Play $25 once, broka.co.ke ~KES 1,500/year | | 1,328 |
| **Infrastructure total** | | | **51,919** |
| **Support and moderation** | One person, KES 40,000 | Reports, listing fixes, seller questions. Disputes are paid for by commission | 40,000 |

Per active listing that is **KES 2.60 of infrastructure and KES 2.00 of
support a month**.

**AWS instead of Google Cloud** comes out about the same: Fargate ~$29.55 per
vCPU-month, RDS db.t4g.micro $15.33/month in Cape Town (31% over Virginia).
Cloud Run is the better start because of its monthly free tier and
scale-to-zero for batch jobs. (AWS App Runner stopped taking new customers
in April 2026.)

### The cost of one listing for a month

```
cost = (AI to post it + chats x 14 messages x KES 0.12 + KES 2.60 infra + KES 2.00 support) x 1.15
```

The **1.15** is a 3% reserve for Turnover Tax (3% of gross receipts between
KES 1M and 25M - confirm with an accountant) and 12% for what averages miss:
fallback models dearer than DeepSeek, failed payments, refunds, spikes.

That gives **KES 6.50 to 10.50 per listing per month**, depending on how many
buyers a category's listings draw. This is the floor: no listing is ever
charged less, whatever its discounts.

### The cold-start gap

At launch - say 2,000 listings and 1,500 users - the bill is about
**KES 22,800 a month** (one Cloud Run instance KES 11,700, a small Cloud SQL
KES 5,500, Vercel KES 2,600, the rest KES 3,000), or **KES 11.40 per
listing**: four times the planning-scale cost. Charging early sellers that
would price BROKA out of the market while it needs supply most, so fees are
set at planning scale and the difference is a launch budget line, not a fee.

It is recovered quickly. At launch the bill is covered by any one of:

- ~450 paid listings at a typical fee (~KES 50 above cost each), or
- ~80 Pro subscribers, or
- ~33 completed KES 20,000 phone deals a month (KES 698 commission each).

To shrink the gap: run one instance with `min-instances=1` only in waking
hours, or start in a Tier 1 region (europe-west1: ~30% cheaper, but further
from Kenya) and move to Johannesburg with traffic.

### Languages

DeepSeek handles English and Kiswahili well. Sheng, Dholuo, Kikuyu and
Luganda stay "coming soon": doing them well needs Gemini, whose price is not
in this model.

---

## 2. The listing fee: f = C × R

A seller pays per listing, per month, for 1 to 6 months at a time. The
monthly price is **C** (what listing this item for a month is worth at full
price) times **R** (the seller's risk coefficient, 0.4 to 1.0).

### C - the list price

```
C = min(category maximum, cost + √price) × quantity factor
```

- **cost** is the listing's cost for a month (above): the floor.
- **√price** is the market-value part. A buyer for a KES 1.5M plot is worth
  far more to its seller than a buyer for a KES 1,500 dress, but not a
  thousand times more: the square root means doubling the price raises the
  fee by 41%. It is also where Zeno's longer negotiations, fraud screening
  and support on expensive items are paid for.
- **Category maximum**: the most one item in the category ever pays a month
  (Fashion KES 100, Electronics 400, Land/Automobiles/Property 1,500).
  Land and cars land in the KES 800-1,500 band the design journal (Part XVI)
  settled on.
- **Quantity factor** `1 + 0.5 × ln(units)`: 2 units ×1.35, 10 units ×2.15,
  100 units ×3.30, 200 units ×3.65. Two hundred phones cost 3.65 times one
  phone, not 200 times. It stops growing at 1,000 units; that seller wants a
  store.
- **Affordability**: a month never costs more than 5% of what the listing is
  worth (a KES 300 shirt lists at KES 15), unless that is under cost.

### R - the risk coefficient

R says how likely a seller's deals are to leave BROKA before the money moves.
It is worked out from one number, the seller's **completion rate**: of the
deals they agreed, how many completed through BROKA's escrow. (A deal only
completes if the money goes through BROKA; one that settled elsewhere is
*leaked* - the nightly job in `trust/completion_rate.py` flags it.)

**The problem with a raw rate.** A new seller with 2 deals, both completed,
has 100%. A seller with 98 completed and 2 leaked has 98%. The raw rate says
the newcomer is the better bet, which is wrong: two deals prove very little.

**Bayesian smoothing, in plain words.** Before anything is known about a
seller, assume they behave like their category: pretend they already have 10
deals, completed at the category's rate. Then add their real deals on top.

```
completion rate = (completed deals + 10 × category rate) / (all deals + 10)
```

With Electronics' rate of 80%:

- newcomer, 2 of 2: (2 + 8) / (2 + 10) = **83%**
- veteran, 98 of 100: (98 + 8) / (100 + 10) = **96%**

The veteran pays less. And the category matters only while a seller's record
is thin: after 100 deals, the category's 10 pretend deals are under a tenth
of the weight. A furniture seller with a strong record is **not** punished
for furniture's rate - with 100 deals, a category rate of 35% versus 80%
moves their completion rate by under five points.

Three refinements:

- **Recent deals count more.** A deal's weight halves every 180 days (every
  360 days for land, cars and property, whose deals are rare). The ranking
  uses 45 days, but a fee that swings with last month's two deals is the
  constantly-moving price sellers resent.
- **Farmed deals count less.** Deals all with one buyer, or all under
  KES 500, are discounted by the quality factor the seller rating already
  uses (`trust/seller_rating.py`): ten deals with one friend buy little.
  Leaked deals are never discounted.
- **No bands.** R follows a smooth S-curve of the completion rate. A band
  ("90% and above pays half") is worth gaming - a seller at 89% farms one
  fake deal to cross it; a curve has no edge.

| Completion rate | 30% | 40% | 50% | 60% | 70% | 80% | 90% | 95% | 100% |
|---|---|---|---|---|---|---|---|---|---|
| **R** | 0.99 | 0.97 | 0.93 | 0.84 | 0.70 | 0.56 | 0.47 | 0.45 | 0.43 |

### The list price and today's price

The seller sees C as the list price, crossed out, and C × R as today's price:
"~~KES 150~~ **KES 84** - 44% off". The list price does not move from day to
day; the discount is the seller's record at work. A seller at KES 60 on a
KES 100 list knows they are getting 40% off, not that the fee "changed to 60".

**Keep the list price honest.** Showing "% off" is only fair if some sellers
really pay the list price. They do: a new land seller pays 98% of it, a
seller who leaks half their deals over 90%. If the category rates are ever raised
so far that nobody pays near list, lower the category maximums instead.

**Rates are locked for the period paid.** A seller who pays for three months
pays that price for three months, whatever their record does meanwhile.

### Months: 1 to 6, longer is cheaper

Six months at most, so a sold item cannot sit on BROKA for more than half a
year. The total grows as months^0.83 - your "100 for one, 180 for two, 250 for
three":

| Months | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| Total, where one month is 100 | 100 | 178 | 249 | 316 | 380 | 442 |
| Saving per month | - | 11% | 17% | 21% | 24% | 26% |

A bundle is never priced under what the listing costs to serve for those
months.

### How long to list: the recommendation

Each category has a typical time to sell. Pricier items take longer (the
price relative to the category's typical price, ^0.3), more units take longer
to clear (units^0.35), and the recommendation covers 20% more than the
expected wait. From KES 250,000 of listing value, a recommendation of 3+
months is **pressed** (`"strength": "strong"`), not merely offered: a land or
car seller who lists for one month and gives up has lost a sale BROKA could
have made. Suggested copy: *"Plots usually take about 4 months to find a buyer
on BROKA. Listing for 6 months keeps you in front of buyers that long, and
costs 26% less per month than renewing."*

### The launch offer (kept from the design journal)

Until a category has real trade, every listing in it is cheaper: 30% off at
the start, fading as the category completes deals (18% after 50, 11% after
100, gone after ~340). This is the journal's cold-start subsidy (Parts
XV-XVI) applied, as Part XVI corrected, to the listing fee - it answers "why
pay when Jiji is free" while BROKA has no track record, without giving the
first sellers a free ride or setting a cutoff date to rush toward. Set
`LAUNCH_DISCOUNT_MAX = 0` in `engine.py` to switch it off.

### Worked examples

After the launch offer has faded. "Proven" is 60 completed and 1 leaked;
"leaky" is 10 completed and 10 leaked.

| Listing | Seller | List price | R | Monthly | 3 months | 6 months | Recommended |
|---|---|---|---|---|---|---|---|
| Shirt, KES 300 | new | 15 | 0.70 | 11 | 27 | 49 | 1 month |
| Shirt, KES 300 | proven | 15 | 0.45 | 8 | 22 | 43 | 1 month |
| Dress, KES 1,500 | new | 46 | 0.70 | 32 | 80 | 140 | 1 month |
| Phone, KES 20,000 | new | 150 | 0.56 | 84 | 210 | 370 | 1 month |
| Phone, KES 20,000 | proven | 150 | 0.45 | 67 | 165 | 295 | 1 month |
| Phone, KES 20,000 | leaky | 150 | 0.84 | 125 | 310 | 555 | 1 month |
| 200 phones, KES 15,000 each | new | 480 | 0.56 | 270 | 670 | 1,190 | 4 months |
| Sofa, KES 25,000 | new | 165 | 0.81 | 135 | 335 | 595 | 2 months |
| Sofa, KES 25,000 | proven | 165 | 0.46 | 76 | 190 | 335 | 2 months |
| Car, KES 800,000 | new | 905 | 0.95 | 865 | 2,150 | 3,830 | 3 months |
| Car, KES 800,000 | proven | 905 | 0.48 | 430 | 1,070 | 1,900 | 3 months |
| Plot, KES 1.5M | new | 1,230 | 0.98 | 1,210 | 3,010 | 5,350 | 5 months |
| Plot, KES 1.5M | proven | 1,230 | 0.49 | 600 | 1,490 | 2,650 | 5 months |
| House to let, KES 30,000/month | new | 185 | 0.97 | 180 | 450 | 795 | 1 month |

### The category table: a risk coefficient for every category

There are no completed deals yet, so each category's completion rate is a
starting guess, written down with its reason. It is what a new seller is
priced on, and what every seller's record is smoothed toward.

| Category | Completion rate (guess) | New seller's R | Cost / month | Max fee | Typical price | New seller pays | Why |
|---|---|---|---|---|---|---|---|
| Electronics | 80% | 0.56 | 8.50 | 400 | 20,000 | 84 | Phones are Nairobi's most-scammed item online; escrow answers a real fear |
| Gaming | 80% | 0.56 | 7.91 | 300 | 15,000 | 73 | Same buyers, same fear |
| Baby & Kids | 72% | 0.67 | 7.12 | 150 | 3,000 | 41 | Small, shippable, bought from strangers |
| Sports & Fitness | 72% | 0.67 | 7.12 | 200 | 5,000 | 52 | |
| Books & Education | 72% | 0.67 | 6.52 | 100 | 1,000 | 26 | |
| Music & Instruments | 72% | 0.67 | 7.12 | 300 | 15,000 | 87 | |
| Arts & Crafts | 72% | 0.67 | 6.72 | 150 | 3,000 | 41 | |
| Fashion | 70% | 0.70 | 7.12 | 100 | 1,500 | 32 | Low value; cash on delivery is common |
| Beauty & Personal Care | 70% | 0.70 | 6.72 | 100 | 1,500 | 32 | |
| Health & Medical | 68% | 0.73 | 6.72 | 200 | 3,000 | 45 | |
| Other | 65% | 0.77 | 7.12 | 200 | 3,000 | 48 | Middle of the range |
| Home & Furniture | 62% | 0.81 | 7.51 | 300 | 15,000 | 105 | Bulky; buyers inspect and pay on delivery |
| Food & Beverages | 55% | 0.89 | 7.12 | 100 | 1,000 | 34 | Perishable, local, cash |
| Construction | 55% | 0.89 | 7.51 | 600 | 20,000 | 135 | Site deliveries, paid on arrival |
| Business & Industrial | 55% | 0.89 | 7.51 | 800 | 100,000 | 290 | Invoices and bank transfers |
| Pets & Animals | 55% | 0.89 | 7.51 | 400 | 10,000 | 96 | Seen and paid in person |
| Agriculture | 50% | 0.93 | 7.91 | 600 | 10,000 | 100 | Farm-gate and market-day cash |
| Automobiles | 45% | 0.95 | 10.49 | 1,500 | 800,000 | 865 | Inspection, logbook transfer, bank payment |
| Services | 45% | 0.95 | 7.51 | 300 | 3,000 | 59 | Paid after the job |
| Property | 40% | 0.97 | 10.49 | 1,500 | 3,000,000 | 1,460 | Agents; rent paid straight to landlords |
| Land | 35% | 0.98 | 9.50 | 1,500 | 1,500,000 | 1,210 | Closes through advocates after a title search |

`GET /pricing/categories` serves this table. **Replace a guess with the
measured rate once a category has about 200 completed deals** - one line in
`categories.py`. Chats per listing, days to sell and typical price are guesses
too, and are replaced the same way.

---

## 3. Featured listings: short-term sellers only

A **short-term seller** (a few items, `seller_tier = short_term`) has no
record to earn visibility with, so paid placement is offered with their
listing fee: KES 99 for 7 days, KES 350 for 28 days (`/featured/plans`).

A **long-term seller** gets no featured placement. Their visibility is earned:
their record lowers their fee and lifts their ranking, and a store is their
shop window. Selling them placement too would let money outrank the record
the whole fee system rewards. `POST /featured/boost` now refuses them (403)
before any M-Pesa prompt, and the listing-fee quote tells them why. It also
refuses a listing buyers can't see (409): featuring an unpaid listing would
take the money and show nothing.

**Later:** the flat 99/350 ignores what a placement is worth: a shirt seller
will not pay 350 to feature a KES 300 item, and a land seller gets a bargain.
Once the app's Boost screen reads prices from the server (it has them
hard-coded today), price placement at 2.5× the listing's list price for 30
days (minimum KES 150, maximum 3,000) and a third of that for 7 days
(minimum KES 50).

---

## 4. Premium: Plus, Pro, Elite

**What is premium.** The features that cost BROKA money every time they are
used, or that are worth real money to the user: voice mode, texts from Zeno,
the Buying Agent's watches and Zeno negotiating for a buyer, **AI cover
images while posting a listing**, and hosting auctions. **Bidding on auctions
stays free for everyone** - buyers are an auction's liquidity, and gating
them would starve the sellers who pay. Typing to Zeno, negotiating yourself,
dictating a message, and uploading your own cover photo stay free.

**How the prices were set.** Each plan's price is at least **1.25× what it
costs BROKA when its holder uses every allowance to the last unit**. No
subscriber, however heavy, is served at a loss; a typical subscriber (about a
third of the allowances) leaves ~74%. The allowances are fair-use caps, not
"unlimited": voice and AI covers cost money per use, and an unlimited plan
priced for the average user is one the heaviest users make unprofitable.

| | **Plus** | **Pro** | **Elite** |
|---|---|---|---|
| **Price / month** | **KES 169** | **KES 499** | **KES 1,249** |
| For | Buyers who want Zeno on their side, occasional sellers | People who buy or sell every week | People who trade for a living |
| AI cover tries (≈ listings) | 6 (≈ 2) | 20 (≈ 7) | 60 (≈ 20) |
| Voice requests (≈ minutes) | 90 (≈ 30) | 180 (≈ 60) | 360 (≈ 120) |
| Texts from Zeno (a buyer waiting, a message you asked it to send) | 30 | 80 | 150 |
| Buying Agent watches, at once | 1 | 3 | 10 |
| Negotiations Zeno opens for you | - | 25 | 50 |
| Auctions hosted | - | 2 | 5 |
| Priority support | - | - | 15 minutes |
| Cost to BROKA, every allowance used | 130 | 394 | 988 |
| Cost to BROKA, typical use | 43 | 131 | 329 |
| Margin, typical use | 74% | 74% | 74% |

**Why the prices went up from 149 / 399 / 999: AI covers.** The first
version of this table forgot that the cover image made while posting a
listing is a premium feature. It is the most expensive allowance per use
after a support minute (KES 5.18 a try), and a seller rarely keeps the first
try. Sized in listings - about three tries each - covers for a week of
listings on Pro alone cost ~KES 104 at full use. At the old prices the 1.25×
rule left room for only **4 / 7 / 28 tries** (one or two listings on Pro),
which is not a feature a weekly seller can use. The alternative, if the old
prices matter more than the covers, is to keep 149 / 399 / 999 with those
4 / 7 / 28 tries; every other allowance is unchanged either way. Prepaying a
year brings the new prices back to **135 / 399 / 999 a month**.

**Free tries.** Someone without a plan gets **2 AI cover tries, once** -
about KES 10, an acquisition cost, and the only way a seller learns what a
cover does to a listing before paying for more. Nothing else is on trial.

Voice requests are the next most expensive (KES 0.71 each, a third of it the
text-to-speech reserve). If the free voice keeps working, they can go up
~75% at the same price.

**Prepaying:** 3 months 8% off, 6 months 15%, 12 months 20% (Pro: 1,379 /
2,539 / 4,789). Shallower than the listing-fee curve on purpose: a plan's
allowances renew every month, so its cost grows with every month prepaid.
Even 12 months prepaid never goes below the maxed-out cost.

Premium does **not** lower the listing fee. The listing fee rewards a seller's
record; letting money buy that discount would undo it.

### How a plan is bought and counted

**Switched off until the app can sell it.** `PREMIUM_ENABLED` (default
`false`). Off, every premium feature is free and uncounted, as before plans
existed, `GET /premium/me` says `enabled: false`, and nothing can be bought.
It replaced `SHOWCASE_AI_REQUIRE_PREMIUM`. Turn it on once an app build with
the Premium screen has shipped: older builds show the refusals' words but
have no way to buy.

**Buying** is the listing fee's M-Pesa flow (§8) on its own tables
(`subscriptions`, `subscription_payments`): `POST /premium/subscribe` sends a
prompt for the catalogue price of the plan and months - never an amount the
app sends - and the callback or the status poll settles it once, under a row
lock. A callback claiming another amount buys nothing and raises a
reconciliation alert. What a payment does:

| Paying for... | ...while | does |
|---|---|---|
| any plan | no plan runs | starts it now; its months count from now |
| the same plan | it runs | extends it from where it ends - renewing early loses nothing. Up to a year ahead |
| a dearer plan | a cheaper one runs | upgrades now: the unused days become days of the new plan at the ratio of the prices (10 Plus days ≈ 3.4 Pro days), then the months bought are added. Allowances start afresh |
| a cheaper plan | a dearer one runs | refused (409) until it ends. If one is paid anyway (the plan changed while the prompt was open), the money becomes time on the plan in force, at the same ratio |

**Counting.** Allowances are per plan month: month *n* runs from the start +
*n* × 30 days (`feature_usage`, one row per user, feature and month). Every
feature spends before it does the costly thing, with one guarded `UPDATE`
(`used + n <= allowance`) so two requests racing for the last try cannot both
get it, and gives it back if the thing did not happen - a cover the model
failed to make, a text that did not send, a negotiation already open.

**Refusing.** A 402 with `{code, message, feature, plan, upgrade_to}`:
`PREMIUM_REQUIRED` when no plan includes it, `ALLOWANCE_USED` when this
month's is spent. The message says what to do in words, because older app
builds show it as it is. Background work has nobody to show a 402 to:

| Feature | Refused in the app | Refused in the background |
|---|---|---|
| AI cover | The cover step says how many tries are left and, with none, offers the plans; the gallery stays free | - |
| Voice mode | Zeno says why, stops listening, offers the plans; typing still works | - |
| Buying Agent watch | 402 (the Zeno tab's action: `FAILED` with the plan code) and the plans | - |
| Zeno negotiating for you | 402 and the plans | The automatic opener on a new match skips the buyer |
| Text from Zeno | Go live says, before "SMS me", that texts need a plan | The availability nudge is cancelled for that buyer; the in-app notification still goes |
| Hosting an auction | 402 when the auction listing is created | - |

**In the app:** Menu → BROKA Premium (`/premium`): the plan, what is left
this month, and Plus / Pro / Elite with 1, 3, 6 or 12 months. Any refusal's
"See plans" opens it with the suggested plan picked.

---

## 5. Stores

**Recommendation: a store is its own subscription, not a premium feature.**
Premium plans are for any user (most Buying Agent users are buyers); a store
is for long-term sellers, and what they want to pay for is shelf space. So:
a one-off opening fee, then a monthly plan sized by how many listings the
store holds - and **listings in the store pay no listing fee**.

- **Opening fee: KES 299**, once. Covers reviewing the store and an onboarding
  call (~25 minutes of a person, ~KES 120), and puts a price on a store name
  so names are not squatted. **Waived** when the first payment covers 6
  months or more.

| Plan | Listings | SMS alerts | Price / month | Per listing | Cost at full use |
|---|---|---|---|---|---|
| Starter | 20 | 20 | **KES 249** | 12.45 | 189 |
| Standard | 50 | 50 | **KES 549** | 10.98 | 433 |
| Growth | 100 | 100 | **KES 1,049** | 10.49 | 839 |
| Business | 250 | 200 | **KES 2,549** | 10.20 | 2,032 |
| Wholesale | 500 | 300 | **KES 4,999** | 10.00 | 3,981 |

Prepaying uses the premium discounts (8% / 15% / 20%). A store listing costs
**KES 10-12.50 a month**, against KES 84 for a new seller listing one phone
on its own - the considerate price that makes a long-term seller choose a
store. "Cost at full use" assumes every slot filled and drawing a negotiation
a month; most stores will sit well under it. Beyond 500 listings, price it
by hand.

---

## 6. Commission

| Deal | Buyer pays on top | BROKA | E-Confirm |
|---|---|---|---|
| Negotiated | **4.49%** | 3.49% | 1% |
| Auction | **5%** | 4% | 1% |

`settings.commission_rate` is now 0.0349 and `settings.auction_commission_rate`
0.04; a deal on an auction listing takes the auction rate whichever way it is
finalised. E-Confirm quotes its own 1%, so it is never computed by BROKA and
never discounted. A deal keeps the rate it was agreed at (`Deal.commission`).

On a KES 20,000 phone BROKA earns KES 698; on a KES 800,000 car sold at
auction, KES 32,000. Next to that the listing fee is small. It matters most
where commission rarely arrives: land and cars mostly close off BROKA, so for
them the fee is most of what BROKA earns from the listing.

---

## 7. The API

| Endpoint | Auth | What |
|---|---|---|
| `GET /pricing/listing-fee/quote?category=&price=&quantity=` | signed in | The caller's monthly fee for a listing not yet made: list price, discount (record and launch parts), R and what went into it, 1-6 month options with the recommended one marked, featured options for short-term sellers, and `fees_enabled` |
| `GET /pricing/listing-fee/listings/{id}/quote` | owner | The same for one of the caller's listings, with only the months that still fit under six ahead (`months_available`) and where its paid time stands (`listing_fee`) |
| `POST /pricing/listing-fee/pay` | owner | `{listing_id, months, phone_number, featured_plan?}`: sends the M-Pesa prompt for the server's total. Takes `X-Idempotency-Key` |
| `GET /pricing/listing-fee/payments/{id}` | owner | pending / success / failed; asks Safaricom itself when the callback is late |
| `GET /pricing/listing-fee/mine` | signed in | The caller's listings buyers can't see until paid, or won't within a week |
| `POST /pricing/listing-fee/callback/{MPESA_CALLBACK_SECRET}` | Safaricom | The prompt's result |
| `GET /pricing/plans` | public | Plus / Pro / Elite with allowances and prepaid prices, the free trial, store plans, commission |
| `GET /premium/me` | signed in | `enabled`; the plan, paid until, when this month's allowances renew; per feature `{allowance, used, left}`; free tries left |
| `POST /premium/subscribe` | signed in | `{plan_id, months, phone_number}`: sends the M-Pesa prompt for the catalogue price. Takes `X-Idempotency-Key` |
| `GET /premium/payments/{id}` | owner | pending / success / failed, and `paid_until`; asks Safaricom itself when the callback is late |
| `POST /premium/callback/{MPESA_CALLBACK_SECRET}` | Safaricom | The prompt's result (`MPESA_PREMIUM_CALLBACK_URL` overrides the address) |
| `GET /pricing/categories` | public | The category table above |

`price` is the price of one unit; `quantity` the units in the listing.

---

## 8. Paying the listing fee

**Switched off until the app can pay.** `LISTING_FEES_ENABLED` (default
`false`) decides everything. Off, listings go live as they always have and
the app shows no fee. On, a new listing is created **hidden** and waits for
its first payment - so switch it on only once the app build with the Listing
fee screen is the one sellers must have: an older build posts listings it
has no way to pay for.

**How a listing is paid for.** One column, `Listing.paid_until`
(`api/domains/listings/paid.py` reads it for everyone):

| `paid_until` | Meaning | Buyers see it? |
|---|---|---|
| empty | No fee applies: posted before fees were on, or an auction | yes |
| = the listing's creation time | Never paid - "pay to publish" | no |
| in the future | Paid until then | yes |
| in the past | Its paid time ran out | no |

Every public read - the feed, search, a listing's own page, "I'm
interested", trending, store catalogues and counts, the Buying Agent -
skips a listing that isn't live. Its seller still sees it: its private page
says where its fee stands, and the Seller Dashboard lists it under "Listings
buyers can't see" with **Pay** or **Renew**.

**The payment** (`api/domains/pricing/payments.py`):

- The amount is the server's quote at the moment of paying, never the app's.
  Featured placement (short-term sellers only) can ride on the same prompt.
- Paid months are added **from the end of the time already paid**, so
  renewing early loses nothing - and never past six months ahead.
- A new listing is announced to the Buying Agent (`ListingCreated`) when it
  is first paid for, not when it was created: buyers are never told about a
  listing they can't open.
- Settled once. Safaricom's callback and the app's status poll (which asks
  Safaricom itself after 20 seconds) both settle under a row lock; whichever
  is second finds the payment done. A callback reporting a different amount
  settles nothing, and raises a reconciliation alert.
- A payment is never written off for being slow - a late callback must still
  be able to land.
- Money for a listing sold or withdrawn while its prompt was open is kept on
  record, and a person is told (audit log + reconciliation alert) to refund
  it.
- One prompt per listing at a time; at most three prompts per seller a
  minute (the number is the payer's to type, so without a limit it is a way
  to pester someone else's phone).

**The app.** Go live says what listing will cost before the seller presses
it ("Listing fee KES 84 a month (44% off) - choose 1 to 6 months next"). A
listing created unpaid goes straight to the **Listing fee** screen: the list
price crossed out, the seller's price and why, the recommended months
already chosen, featured for short-term sellers, and Pay with M-Pesa. Paid,
Go live celebrates as before; left unpaid, the listing is saved and waits in
the Seller Dashboard. The same screen renews a listing that is ending.

**Decide before switching on:**

- **Listings posted before fees stay free** (`paid_until` empty). To start
  charging them too, give them a grace period first, e.g.
  `UPDATE listings SET paid_until = <switch-on date + 14 days> WHERE status =
  'active' AND paid_until IS NULL AND listing_type <> 'auction'` - and tell
  those sellers before it bites.
- **Store listings pay the listing fee for now.** Once store plans are
  billed (below), listings in a paid-up store should be exempt.
- **Unused months when an item sells** are not refunded automatically.
  Credit toward the seller's next listing is the friendliest answer.
- **No reminder is sent before paid time runs out** yet; the dashboard shows
  "ending" a week ahead. A push three days before would save renewals.

## 9. What is not built yet

1. **Store billing**, on the premium payment flow, with store listings
   exempt from the listing fee.
2. **Premium revenue and reminders.** Nothing sums `subscription_payments`
   for the admin screens, and nothing reminds a subscriber before their plan
   ends; a push three days before would save renewals.
3. **Anti-farming before big discounts.** The design journal (Part XVI) wants
   device, M-Pesa and location clustering before completion-rate discounts go
   live. The quality factor already discounts one-buyer and under-KES-500
   farms; clustering closes multi-account farms.
4. **The legacy M-Pesa paths** (`routers/negotiate.py`, `domains/disputes/`,
   `core/workers.py`) still compute payouts with a hard-coded 3%. Correct for
   the old deals that use them (they were agreed at 3%), but they should read
   `Deal.commission` instead.
5. **Listing-fee revenue in the admin summary.** Payments are in
   `listing_payments`; nothing sums them for the admin screens yet.

## 10. Assumptions to replace with data

| Assumption | Used for | Replace with |
|---|---|---|
| ~5,900 input / 380 output tokens a message, half cached, 40% at peak | AI cost | Log tokens per call from week one |
| 14 messages a thread; 0.5-2.5 threads per listing a month | Listing cost | Count them per category |
| KES 0.50 an SMS | Plans | Mobitech's invoice |
| Category completion rates | R for new sellers | Measured rates at ~200 completed deals per category |
| Days to sell, typical prices | Recommendation | Median listing-to-deal time per category |
| 20,000 listings / 15,000 users | Infra per listing | Re-run at each order of magnitude |
| A third of allowances used | Plan margins | Allowance use per plan |
| ~3 AI cover tries per listing; ~3 voice requests a minute | Sizing cover and voice allowances | `feature_usage` per plan month, against listings posted |

## 11. What was kept from the design journal, and what was not

**Kept:** the Bayesian completion rate (§3.2), with Part XVI's ten-deal bar as
the prior weight; the confidence factor against farming (§3.3, Part XVI
thresholds); a smooth discount curve instead of bands (§2.5, Weakness 3);
the cost floor no discount may breach (Fee_min, §2.6); longer memory for
land and cars (§14.12, Part XVI); the cold-start subsidy on the listing fee,
decaying with completed deals, never with sign-ups (§15.4, Part XVI item 9);
land and car fees in the KES 800-1,500 band (Part XVI item 3); the
commission split where only BROKA's share is discountable (§1.1); trader
subscriptions (Part IV), as store plans.

**Superseded:** the 14-day auto-archive and the KSh 10 relist fee (§11.6) -
the monthly listing fee does both jobs. The per-category Base_c (§2.2) - the
square root of the price and the category maximum replace it.

**Left for later, when there is data or a lawyer:** Kalman-filtered DCR,
Thompson-sampling who pays the fee, copula-based cost floors, the dispute
insurance pool, float yield, B2C batching (Parts XII-XIV). None can be tuned
before BROKA has a few thousand deals.

---

## Sources (checked September 2026)

- DeepSeek V4.1 Flash rates and peak hours: [DeepSeek API docs](https://api-docs.deepseek.com/quick_start/pricing/), [aipricing.guru](https://www.aipricing.guru/deepseek-pricing/), [BenchLM](https://benchlm.ai/deepseek/api-pricing)
- Cloud Run rates, tiers, free tier, africa-south1: [Cloud Run pricing](https://cloud.google.com/run/pricing), [Cloud Run locations](https://docs.cloud.google.com/run/docs/locations)
- Cloud SQL: [Cloud SQL pricing](https://cloud.google.com/sql/pricing), [Bytebase comparison](https://www.bytebase.com/blog/postgres-hosting-options-pricing-comparison/)
- Google Cloud egress: [Network Service Tiers pricing](https://cloud.google.com/network-tiers/pricing)
- AWS: [Fargate pricing](https://aws.amazon.com/fargate/pricing/), [RDS db.t4g.micro](https://instances.vantage.sh/aws/rds/db.t4g.micro), [App Runner successor](https://tech-insider.org/aws-app-runner-vs-cloud-run-vs-container-apps-2026/)
- Upstash Redis: [pricing](https://upstash.com/pricing/redis)
- Cloudflare R2: [pricing](https://developers.cloudflare.com/r2/pricing/); Cloudflare Realtime TURN/SFU: [pricing](https://developers.cloudflare.com/realtime/sfu/pricing)
- Deepgram Nova-3: [pricing guide](https://brasstranscripts.com/blog/deepgram-pricing-per-minute-2025-real-time-vs-batch); AssemblyAI Universal-Streaming: [pricing](https://www.assemblyai.com/pricing)
- fal.ai FLUX.1 Kontext [pro]: [fal.ai](https://fal.ai/models/fal-ai/flux-pro/kontext)
- Kenyan bulk SMS: [Safaricom bulk SMS tariff](https://www.safaricom.co.ke/images/Downloads/Resources_Downloads/VAS/Bulk_SMS_Tariff_Guide_updated.pdf), [Mocky SMS guide](https://mocky.co.ke/blog/bulk-sms-marketing-in-kenya-costs-compliance-and-roi-guide-for-smes-in-2026)
- M-Pesa tariffs from 7 August 2026: [The Kenya Times](https://thekenyatimes.com/business/safaricom-reduces-m-pesa-business-charges-list-of-new-charges/), [tech-ish](https://tech-ish.com/2026/08/01/mpesa-pochi-buy-goods-tariff-cuts-2026/)
- Vercel: [pricing](https://vercel.com/pricing); Resend: [pricing](https://resend.com/pricing); Sentry: [pricing](https://docs.sentry.io/pricing/)
- App stores: [publishing costs 2026](https://axonbuild.com/blog/cost-to-publish-an-app-to-the-app-stores)
- USD/KES: [exchange-rates.org](https://www.exchange-rates.org/exchange-rate-history/usd-kes-2026)
- Store-builder benchmarks (Lacesse Duka KES 499/month, Shopify Basic ~KES 3,770): [Lacesse](https://lacesse.co.ke/blog/post/shopify-pricing-in-kenya-2026-what-it-actually-costs-and-a-better-option/)
