# Stores: duplicate fix, store rating, and a real store dashboard

**Date:** 2026-10-19
**Scope:** `backend/api/domains/stores/`, `backend/api/domains/reviews/`,
store-related models, `flutter_app/lib/features/stores/`.

---

## 1. Why some stores appear twice

### 1.1 The directory draws the same shop twice (confirmed)

`store_list_screen.dart` loads **two independent lists**:

* `_nearby` — `GET /stores?lat&lng&max_distance_km=25&nearest_first=true`
* `_stores` — `GET /stores` (no radius)

They render one after the other:

```
'Stores near you'  → _nearby.take(5)
'All stores'       → _stores (every store, including those 5)
```

Nothing removes the nearby ids from the main list, so a shop inside 25 km
appears in both sections. The category screen (`store_category_screen.dart`)
has the identical structure and the identical bug.

**Fix:** the "near you" rail is a shortcut, not a second catalogue.

* While a search or place filter is active, the rail is hidden — the user
  asked for a filtered result set, and a shelf above it would contradict it.
* Otherwise, the main list excludes every id already shown in the rail, so
  each shop appears exactly once on the screen.

### 1.2 Unstable pagination (latent, same symptom)

`list_stores` orders by `Store.created_at DESC` only. Stores created in the
same second (seeding, bulk onboarding, tests) tie, and SQL makes no promise
about ties: page 2 with `OFFSET` can return a row page 1 already showed, or
skip one. The app currently pages in one request, but the endpoint accepts
`offset`, and `nearest_first` sorts a 500-row window.

**Fix:** a deterministic tiebreaker — `created_at DESC, id ASC`. Plus a
defensive de-dupe of the response by store id, so a future join can never
put two rows for one shop in a page.

### 1.3 What is *not* the cause

Checked and ruled out:

* Category filter — uses `IN (subquery)`, not a join, so no row fan-out.
* Search — same `IN` shape.
* Billing visibility — `EXISTS`, not a join.
* `create_store` — row-locks the owner and re-checks "already has a store";
  a client retry after a timeout returns 409, not a second shop.
* `/stores/mine` — `LIMIT 1`, newest.
* The web storefront — one slug resolves to one store.

---

## 2. Store rating

### 2.1 What it is

One number, 0–10, per store, computed from exactly the four signals asked
for — and from nothing invented:

| Signal | Weight | Source |
|---|---|---|
| Reviews (star quality) | 0.55 | `reviews` attributed to the store |
| Response time | 0.30 | store-scoped conversations |
| Time on BROKA | 0.15 | `stores.created_at` |
| Review volume | confidence | how much the review score is trusted |

### 2.2 Why store-scoped response time is a different number

The seller's reply time (`trust/response_time.py`) is measured across every
thread the *person* has ever had. A seller with two shops would get one
number for both. The store rating uses the same pure timing walk, but only
over messages whose `listing.store_id` is this store, so a busy electronics
shop cannot borrow the response record of a quiet furniture shop.

An unanswered inbound still counts (censored at 48 h), a burst of buyer
messages is one wait, and fewer than 3 observations is **unmeasured** —
never "fast".

### 2.3 The formula (pure function, testable)

Normalised components 0..1:

```
review   = (sum(stars) + PRIOR_WEIGHT * PRIOR_STARS) / (count + PRIOR_WEIGHT) / 5
response = exp(-ln2 * minutes / 60)            # 0.5 at one hour
tenure   = min(1, sqrt(days_on_broka / 180))
```

Weights: `0.55 * review + 0.30 * response + 0.15 * tenure`, ×10.

**Prior.** A store with no reviews is *unproven, not bad*. `PRIOR_STARS =
4.0` with `PRIOR_WEIGHT = 5` means "no reviews" scores 0.8, and an
unmeasured response scores 0.7 (the same placeholder the seller rating
uses). A brand-new store therefore starts at exactly **6.5/10** — the same
neutral anchor as `seller_rating.NEUTRAL_RATING`.

**Confidence.** The review term is shrunk toward the prior until there is
evidence: `evidence = min(1, review_count / 10)`. Response time and tenure
are measured facts, so they are not shrunk. Ten 5-star reviews with
10-minute replies and a year of trading ≈ 9.7; five 1-star reviews ≈ 2.5.

The formula, the prior and the weights live in
`backend/api/domains/stores/rating.py` as pure functions with the same
"argue with scenarios in a second" property as `trust/seller_rating.py`.

### 2.4 Review attribution (new column)

`Review` is seller-level today. A store rating cannot use the owner's whole
review history — that would let one good shop lift a second, worse one.

* Add `reviews.store_id` (nullable, indexed).
* `ReviewService.submit_review` sets it from `Deal -> Listing.store_id`.
* Startup backfill fills it for existing deal-backed reviews.
* Chat-only reviews (no deal) stay unattributed: they carry no listing, so
  attributing them would be a guess.

`GET /stores/{id}/reviews` becomes store-scoped. The owner's broader seller
record stays where it belongs — `seller_standing` on the same payload.

### 2.5 Persistence and ordering

Recomputing per request would mean scanning conversations on every directory
page. Instead:

* `stores.rating`, `rating_reviews`, `rating_response_minutes`,
  `rating_updated_at` — the current value, written by:
  * `create_store` (initial 6.5-equivalent for its real signals),
  * `ReviewService` after a review (one store, cheap),
  * a daily worker pass (`task_refresh_store_ratings`), covering response
    time drift and tenure.
* Default directory order: `rating DESC, created_at DESC, id ASC`.
  `nearest_first` keeps distance ordering — "near you" means near.
* A `StoreRatingSnapshot` row per store per day, so the dashboard can chart
  the rating and show what moved it. Same argument as
  `SellerMetricSnapshot`: a recency-weighted number cannot be reconstructed.

### 2.6 What is published

The store page and the directory card show the rating, the number of
reviews, the response band and the review average. The component breakdown
is shown to the **owner** (it is a to-do list), not to buyers.

---

## 3. Store dashboard: from counters to a command centre

`GET /stores/{id}/stats` returns visits, shares and their sources. That is
real but thin. The seller dashboard earns its place with trends, a rank, a
breakdown and advice. The store one should too.

### 3.1 New endpoint

`GET /stores/{id}/insights?days=7|30|90` (owner only) returns:

```
store        rating, reviews, response minutes/band, rank, stores_total
period       days, from, to
kpis         current + previous period: visits, product_views, saves, likes,
             interested_buyers, chats, response_minutes
series       daily visits, product views, chats
sources      visit sources, surfaces, share channels
top_products id, name, price, views, likes, saves, interested
rating       components (review/response/tenure), confidence, counts
advice       positives / negatives, each citing a real number
```

All figures come from existing tables:

| Figure | Source |
|---|---|
| Visits / shares | `store_daily_counts` |
| Product views | `Listing.views` + `ListingMetricSnapshot` deltas |
| Saves / likes | `wishlists`, `listing_likes` |
| Interested buyers | `interests` |
| Chats | `negotiation_messages` per store listing |
| Response time | store-scoped timing walk |
| Rating | `stores.rating` + component recompute |

### 3.2 "Realtime"

Two honest layers:

* **Today so far** — `store_daily_counts` for today, updated on every visit.
* **Viewing now** — a Redis sorted set per store (`broka:store:live:<id>`):
  each counted visit adds the visitor with a 5-minute expiry; the endpoint
  returns `ZCARD` after pruning. Without Redis, an in-process equivalent
  with the same TTL. This is a real count of live visitors, not an
  extrapolation.

The dashboard polls the insights endpoint while it is the visible tab
(60 s) and refreshes "viewing now" more often (20 s), stopping when the
screen is not in front.

### 3.3 The screen (My Store → Overview)

Modelled on `seller_dashboard_screen.dart`:

1. **Header** — store rating out of 10, rank ("#4 of 37 stores"), response
   band, review count.
2. **KPI row** — Visitors, Product views, Saves, Chats for the period, each
   with a delta against the previous period.
3. **Live pill** — "3 viewing now", from the live counter.
4. **Trend card** — period switch (7/30/90) and a metric switch
   (Visits · Views · Chats) drawn with the shared `AxisLineChart`.
5. **Rating card** — the number, its three components as bars, confidence,
   and the one-line explanation of what moves it.
6. **Top products** — five rows by views, each opening the product.
7. **Advice cards** — concrete, number-backed, no model call.
8. **Traffic sources** — kept, moved below the performance section.
9. Store status, plan, pictures, setup checklist and share stay as they are.

---

## 4. Tests

Backend:

* Rating ladder (new store 6.5, established 9+, one-star store low).
* Store-scoped response time ignores another store's threads.
* Review attribution: a deal review lands on the right store, and a second
  store's rating does not move.
* Directory order is rating-descending, stable across pages, and contains
  each store once.
* Insights endpoint: owner-only, honest zeros, real deltas, no invented
  numbers when a source is empty.

App:

* The directory renders a nearby shop once, and hides the rail when a
  filter is active.
* The category screen does the same.
* Rating parses and shows on the card and details screen.
* Insights model parses; KPI deltas and series render without overflow.

## 5. Deliberately not changed

* Pausing semantics (STORES_REVIEW §3.1) — still open, unrelated.
* Billing visibility rules.
* Seller rating — untouched; store rating is a sibling, not a replacement.
* Chat-only reviews remain seller-level (no listing to attribute).
