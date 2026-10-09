# Seller metrics — phased build

Spec source: Design Journal Vol. 8 §3.1–§3.3 and Part XVI.

## Phase 1 — the metrics engine ✅ (this round)

Everything else in the brief reads from these numbers, and one piece of it
(history) is unrecoverable if not started now.

| Piece | State |
|---|---|
| DCR, Bayesian-smoothed (§3.2) | already existed, matches the journal exactly |
| Rank score (§3.4) | already existed |
| **Confidence factor (§3.3 + XVI)** | **new** — `seller_rating.quality_factor` |
| **Overall Rating /10** | **new** — `seller_rating.overall_rating` |
| **Daily history snapshots** | **new** — `SellerMetricSnapshot` + nightly job |
| Response-time tracking | **built in Phase 2** |

### The Overall Rating

Weights: DCR 0.45, response 0.25, volume 0.15, backlog 0.10, tenure 0.05.
Tenure is deliberately smallest and saturates at six months — five years
versus six months is worth under half a point.

Two corrections made while building it, both worth keeping in mind:

**Evidence and quality are separate.** The first version collapsed them into
one confidence factor and scored a Sybil farm 8.1/10 — shrinking a farmed
record toward the neutral prior was *protecting* it. Now: thin evidence
shrinks toward neutral (fair to newcomers), bad quality multiplies the score
down (not fair to farmers). Farm now scores 2.5.

**The neutral anchor is 6.5, not 8.0.** Anchoring at §3.2's `Prior_mean`
rescaled put a two-deal newcomer above the 88-of-97 veteran — reintroducing
the exact unfairness the module exists to remove, one level up. DCR's prior
answers "will they complete a deal"; this composite also contains volume and
tenure, which a new seller genuinely lacks.

**Uniqueness is gated, not raw.** A raw unique/deals ratio punishes repeat
customers — 88 deals across 70 buyers means 18 people came back, which is
loyalty, not collusion. Full credit above 50% distinct buyers; real
collusion looks like 10–30%.

Verified ladder:

    9.3  95% DCR, 8min replies, 150 deals
    8.5  88/97 over 2 years, 25min replies
    7.4  no deals yet, 8min replies, 3 months on BROKA
    6.9  2/2 in week one, 25min replies
    6.5  brand new, no deals
    5.0  no deals yet, buyers left waiting two days
    2.5  10 deals, 1 buyer, all under KSh 500

**Reply speed and tenure count from day one (2026-10-09).** Thin evidence
used to shrink the whole rating toward 6.5, reply speed included. With
in-app payments off no deal can complete on BROKA, so every seller had zero
completed deals and every seller was 6.5 - answering in five minutes or
never. Now only the deal record (DCR, volume, backlog) is shrunk toward a
neutral record (`DEAL_RECORD_PRIOR`, set so a brand-new seller is still
exactly 6.5); reply speed and tenure are measured, so they count as they
are. A seller with ten deals is rated exactly as before. Credibility is
unchanged: it is the track-record number, and time alone does not buy it.

### Why snapshots ship before the charts

DCR is recency-weighted on a 45-day half-life, so yesterday's value cannot
be reconstructed from today's deal table. Rank position depends on where
every *other* seller stood at that moment. History only exists if written as
it happens — every day the job does not run is a permanent hole in a graph a
seller will eventually open.

`median_response_min` is written NULL on purpose. Nothing measures response
time yet; a placeholder would draw a flat line at an invented value,
indistinguishable from a real trend.

## Phase 2 — response time + the API ✅ (this round)

**Response time is measured.** The 0.7 placeholder is gone from
`rank_score`. It had been identical for every seller since the function was
written, so a sixth of the ranking signal carried no information — sellers
who answered in minutes and sellers who never answered ranked the same on
the term meant to separate them.

No new instrumentation: every message already carries `listing_id`,
`buyer_id`, `role`, `recipient_role` and `created_at`, so the metric is
derivable from existing history — and therefore works **retroactively**,
from each account's first day, instead of starting at zero on deploy.

Design points worth knowing:

- **Unanswered threads count.** Measuring only answered messages gives a
  seller who ignores everyone *no* response time, and "no data" sorts better
  than "slow" — inverting the whole incentive. An unanswered inbound is a
  censored observation: time-so-far, capped at 48h.
- **A relay to the seller starts the clock; a relay to the buyer does not.**
  In the mediated room the seller's clock starts when Zeno's message reaches
  *them*, not when the buyer typed.
- **A burst of buyer messages is one wait.** Counting each would punish the
  seller for the buyer's typing habits.
- **Average, 30-day window, min 3 observations.** The mean of every wait
  (the median until 2026-10-09, which hid slow replies as long as most were
  quick); the 48h cap keeps one forgotten thread from swamping it. Below
  three observations it returns NULL, which keeps "unmeasured"
  distinguishable from "fast". Still stored and sent as
  `median_response_minutes`, which older app builds read.

**`GET /listings/seller/{id}/metrics?days=90`** returns current standing
(with the component breakdown Phase 3's advice panel needs) plus the daily
history series. Own metrics only — response time, backlog and rank position
are competitive information, and rank in particular tells a rival exactly
how far they have to climb. Missing days are gaps, not zeroes.

## Phase 3 — trends + the advice bot ✅ (this round)

**Six banded trend charts.** `FactorTrendChart` draws one metric over time
with two threshold lines cutting the plot into good / acceptable / poor,
as sketched. Direction is per-metric: green sits on top for rating and DCR,
at the BOTTOM for response time, rank position and pending deals — telling a
seller their worsening reply time is an improvement would be worse than
showing no chart at all. Straight segments, not a spline: a curve invents
values between snapshots that were never measured.

**The advice bot is rules, not a model call.** Zeno cannot see a trend — it
receives today's numbers and would infer a direction it has no evidence for,
phrased fluently, which is worse than phrased badly. `seller_advice.py`
compares snapshots 7 days apart and emits cards that each cite a real delta.

Three rules every card obeys: provable (a number behind every adjective),
actionable (what to DO, not a verdict), and honest about direction (a
negative is never softened into a positive).

Deduping matters more than it looks — a falling DCR fires both the trend
rule and the absolute rule, saying one thing twice and costing a slot that
should hold a different problem.

## Phase 4 — listing metrics ✅ backend (this round)

## Phase 4 — listing metrics ✅ backend (this round)

Likes and interested buyers already existed (`Wishlist`, `Interest`, both
timestamped) - in the schema. Nothing wrote to `Wishlist` until 2026-10-09:
no endpoint and no button, so every listing's likes were 0 (see below). Only per-listing **view history** was missing — `Listing.views`
is a bare running counter — so `ListingMetricSnapshot` ships now and starts
accruing, same argument as the seller snapshots.

`GET /listings/{id}/metrics` returns views, likes, like/view ratio,
interested buyers, views-per-day, price vs category median, sell
probability with its component breakdown, daily history, and per-listing
advice. Own listings only: view and like counts tell a competitor exactly
which of your products are moving and which are dead stock.

**Sell probability** is a transparent weighted model, not a trained one —
there is no outcome data to fit yet. Commitment (buyers asking) carries the
most weight because asking costs effort; price fit is asymmetric because
being 30% over is an obstacle while being 30% under is the seller leaving
money behind. Shrunk toward the category base rate by an evidence weight, so
a listing with 3 views and 1 like reports ~38%, not the 90% a naive 33% like
rate would give.

**Rebuilt on what is measured (2026-10-09).** A fifth of the score was the
like rate, and likes were never collected. Now: saves are collected (the
heart on a listing, `POST/DELETE /listings/{id}/save`, `GET /listings/saved`,
a Saved items screen in the Menu); the save rate is smoothed toward 5% over
20 prior views, so a listing nobody could save yet is not "unwanted"; buyers
asking counts everyone who wrote about the listing where the seller can see
it, not only the availability button; the best offer counts (at 90% of the
price or more, full marks); a sixth term scores the listing itself (photos
70%, description 30%); a listing nobody has asked about for three weeks is
marked down, by at most 40%; and evidence counts buyers (x5) and saves (x3)
as well as views. Price and the listing term are left out, their weight
redistributed, when they weren't measured. Both readers - the listing
screen and the nightly snapshot - gather the inputs in one place,
`listings/sell_signals.py`; the snapshot had been skipping the price
benchmark. Views no longer count the seller opening their own listing, and
opening a listing from a list now reaches the server, so it counts.

**The listing screen** (`screens/listing_analytics_screen.dart`, route
`/listing-insights`) is built: chance of selling with its five component
bars, the raw counts, price vs category median, what-to-fix advice, and
three trend charts. Reached from a "View insights" button on every card in
the dashboard's Products tab, which already showed each listing's state
(completed / pending / escrow).

Negatives sort ABOVE positives here, unlike the dashboard. A seller opening
one listing is looking for the thing to fix; a seller opening the dashboard
is taking stock.

## What buyers see (2026-09-29)

A listing's screen shows the seller's **overall rating, deal completion
rate and response time** — the dashboard's first three charts, in the
dashboard's colours (`flutter_app/lib/models/seller_standing.dart` holds the
thresholds both screens use). `GET /auth/user/{id}` carries them as
`seller_standing`, built by `trust/public_standing.py`:

- **From the newest nightly snapshot**, not computed live. A listing is
  opened far more often than a dashboard, and the live response time scans
  every message on the platform from the last 30 days. A snapshot older
  than seven days gives nothing: those are the figures of a job that has
  stopped, not the seller's standing.
- **DCR only after the first funded deal**, marked provisional under ten.
  The 80% prior is not a track record, and a buyer shouldn't be shown one.
- **Response time null when unmeasured**, never a placeholder.
- **Rank position, rank score and backlog stay the seller's.** Rank tells a
  rival how far they have to climb; the backlog can be inflated by anyone
  willing to open conversations.

Zeno is given the same three figures when a buyer asks it about a listing
(ZENO_ACTIONS.md).

## Phase 5 — rank, seller of the week/month, prizes

Not started. `rank_position` is already snapshotted daily, so the leaderboard
has its data source; what's missing is the weekly/monthly award selection and
whatever prize mechanics you land on.

## Known gaps

- **No outcome data yet**, so sell probability is a stated weighted model
  rather than a fitted one. Once listings start resolving sold/expired, the
  weights in `sell_probability.py` are the obvious thing to replace with
  fitted ones — the shape stays, the constants stop being guesses.
- **`category_sell_rate` is never populated** — every listing falls back to
  `DEFAULT_CATEGORY_SELL_RATE` (0.35). Computing real per-category rates
  needs the same resolved-listing data.
- **Market demand per category** (your "electronics have 43.34% demand on
  BROKA") isn't computed anywhere yet.
- **None of the Flutter is compiled.** No toolchain in the build environment
  used for this work.
