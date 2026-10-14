# BROKA — Listing Posting Review

**Date:** 2026-09-25
**Scope:** posting a listing end to end — the app's seven-step sell wizard
(Photos → Basics → Description → Price → Location → Showcase → Review),
image upload (`POST /media/images`), `POST /listings`, and the seller's
later edits (`PATCH /listings/{id}`).

Every finding marked fixed was reproduced first (against SQLite and
PostgreSQL 16), has a regression test, and each test was run against the
old code and failed there.

---

## 1. Verdict

**As an engineer.** The upload design is good: photos upload one at a time
as they're taken, are decoded and re-encoded server-side, stripped of GPS,
and the listing references them by id. Drafts survive the camera killing
the app. What was weak was the create endpoint itself: it had lost every
input bound the older `ListingCreate` schema carried, so the only check
left was the type — and one of the values that passes a type check is
`NaN`. It was also not safe to retry, which on Kenyan mobile data is the
normal case, not the edge case.

**As a founder.** Three things mattered most, and all three are fixed:

1. **Any signed-in user could take the Home feed down** with one request.
2. **Every listing published the seller's phone position** — roughly their
   front door — on an unauthenticated endpoint. Most listings, meanwhile,
   showed up in central Nairobi whatever county they were in.
3. **A slow connection posted items twice**, and a week-old draft could
   not be published at all.

The biggest product gap left is not a bug: **a seller cannot take a
listing down** (§4.1).

---

## 2. Fixed

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | **Critical** | `{"price": NaN}` was accepted (Python's json parses the bare literal). PostgreSQL stored it, and every response containing the listing failed to serialise — **`GET /listings/` returned 500 for every visitor**. The same through `lat`/`lng`, `reserve_price`, a value inside `attributes`, `PATCH /listings/{id}` and interest offers. On SQLite it was a 500 on create. | Non-finite numbers refused on every listing model; `attributes` values checked. Rows saved before the fix: a startup repair takes non-finite listings off sale, and attributes are read NaN-safe. | `TestNonFiniteNumbers`, `test_a_non_finite_listing_is_taken_off_sale_on_start` |
| 2 | High | The refusal itself was a 500: FastAPI's 422 echoes the input, and the encoder refuses NaN. App-wide, not just listings. | A validation handler in `main.py` makes the echoed input JSON-safe. | `test_nan_price_is_refused_and_the_feed_stays_up` |
| 3 | **High** | `GET /listings` and `/listings/{id}` (no sign-in) returned the seller's coordinates to 7 decimals (~1 cm). Image processing strips GPS from photos for exactly this reason. | A listing is saved at its **county's main town** (47 counties, `listings/location.py`); an unknown county falls back to the sent point rounded to ~1 km. Existing rows are rounded on start. | `TestListingLocation` |
| 4 | High | Signup sends a fixed Nairobi CBD point and GPS detection is dormant, so **nearly every listing sat in central Nairobi** on the map and in distance filters, whatever county it was in. | Same fix as #3: the listing goes where the seller says it is. County names are canonicalised ("mombasa county" → "Mombasa"), so the location filter finds them. | `test_a_known_county_places_the_listing_there` |
| 5 | High | **Duplicate listings.** The create request has a 120 s timeout; if the response was lost, Activate was still there and pressing it again posted the item again. A double tap did the same. | The app sends a per-draft `X-Idempotency-Key`; the server stores it on the listing (`client_ref`, unique per seller) and answers a repeat with the listing it made — durable, no Redis dependency, and safe under concurrent requests. | `TestRetrySafeCreate`, `listing_publish_test.dart` |
| 6 | High | **A week-old draft couldn't be published.** Unused uploads are deleted after 7 days; a restored draft still held their ids, the server said "upload it again", and the app — believing they were uploaded — offered no way to. | The server tags that refusal (`X-Error-Code: IMAGE_GONE`); the app re-uploads the photos from the phone and sends the listing once more. | `test_a_missing_upload_says_so_in_a_header`, `listing_publish_test.dart` |
| 7 | High | Photos (and price) could be **changed after the buyer paid**. A listing's photos are what a "not as described" dispute is judged against. | `PATCH /listings/{id}` refuses every change while a deal on the listing holds the buyer's money (paid, disputed, awaiting_*). Settled deals don't lock it. | `TestEditsWhileMoneyIsHeld` |
| 8 | Medium | Trust score **0** — the lowest — read as 100 (`trust_score or 100`), so the most distrusted accounts passed the gate. A deleted account's token could still post. | `is not None` check, same rule as `permissions.py`; unknown account → 401. | `TestTrustGate` |
| 9 | Medium | No bounds: price 0, −5 or KES 50 billion; latitude 500; a 100,000-character name; any `listing_type` (→ 500); any `condition`; nested/unbounded `attributes`. | Bounds restored and extended (name 3–120, description ≤ 2,000, price ≤ the KES 20,000,000 escrow ceiling — a listing above it could be negotiated but never paid for). Messages are written for the seller. | `TestListingFields` |
| 10 | Medium | An unknown `subcategory_id` (a draft saved before the taxonomy changed) was a **500 on PostgreSQL** (foreign key) and a listing filed under nothing on SQLite. | 400 with "choose it again". | `test_unknown_subcategory_is_a_400` |
| 11 | Medium | No limit on posting: photos are rate-limited, but a listing needs none through the API, so a script could fill the feed. | 30 per hour and 100 per day per seller; a retry of an existing listing isn't counted. | `TestCreateRateLimit` |
| 12 | Medium | An auction could be created **already closed** — the wizard's date picker offered yesterday, and a restored draft kept an old closing time. `PATCH /auctions/{id}/terms` allowed the same. | `validate_terms(now=...)` refuses a past close on both doors; the picker starts today; a stale draft's window is reset. | `test_an_auction_that_already_closed_is_refused`, `test_terms_cannot_move_the_close_into_the_past` |
| 13 | Low | An auction's listing and its window were two commits; a failure between them left an auction with no window. | One transaction. | `test_no_auction_listing_without_its_window` |
| 14 | Low | Two concurrent price edits could both spend the last weekly allowance. | The listing row is locked for the edit. | (PostgreSQL row lock) |
| 15 | Medium (UX) | Server refusals were shown to sellers as **raw JSON** (`Failed to create listing: 400 {"detail": …}`) — structured and validation details were never parsed. | `ApiClient` reads all three `detail` shapes and exposes the error code. | `listing_publish_test.dart` |
| 16 | Low (UX) | Price accepted "NaN"/"Infinity" and rejected "2,500,000"; nothing was capped until the server said no; typed text wasn't in the saved draft until Next; county and area were free text ("Nairobii"); the showcase re-uploaded on every retry; an unbounded gallery pick could exceed the 10 MB upload limit. | Grouped digits-only amount input with the escrow cap; name/description limits as you type; live draft saving; county/area pickers (shared with store setup); showcase uploaded once; gallery picks bounded to 2048 px. | `listing_publish_test.dart` |

---

## 3. Deploying this

- **Startup migrations** (run by `init_db()` on every start, idempotent):
  `listings.client_ref` + a unique index on `(seller_id, client_ref)`;
  existing listings' coordinates rounded to 2 decimals; any listing with a
  non-finite price or position set to `cancelled`.
- **Old app builds keep working.** They don't send a key (so they get the
  old, non-idempotent behaviour) and send free-text counties (canonicalised
  when recognisable). The retry safety, pickers and readable errors arrive
  with the next APK.
- **New limits** a seller can hit: 30 listings/hour, 100/day, price ≤
  KES 20,000,000, and no edits while a buyer's money is held.

---

## 4. Still open — recommendations, not changed

In order of what I'd do next.

1. **Sellers can't take a listing down.** There is no close, mark-as-sold
   or delete endpoint. An item sold elsewhere stays live forever; buyers
   and Zeno keep negotiating for it. A `POST /listings/{id}/close`
   (refused while a deal holds money) plus a button in the seller
   dashboard is small and closes the largest gap in the flow.
2. **"Verified photos" is a client-side promise.** Camera-only is enforced
   by the app; the server can't tell a camera photo from any other image
   (and strips EXIF), and an API client can upload anything. Either soften
   the wording or add real signals — e.g. flag a photo whose `sha256`
   already appears on another seller's listing (the hash is already stored
   per asset), a common scam pattern.
3. **No moderation.** Listings go live instantly with no prohibited-items
   check and no review queue. Fine for a small launch; plan it before
   growth.
4. **Photos aren't required by the server.** The app requires one; the API
   doesn't. Enforcing it means updating ~80 test fixtures, so it was left
   as a deliberate follow-up.
5. **Legacy `verified_video` / `advert_video`** accept up to the 32 MB body
   limit of arbitrary text and are served on the public detail endpoint.
   No current client sends or shows them — stop accepting them.
6. **Buyer-only accounts can post** — the server doesn't check
   `account_type`; only the app gates Sell. Decide whether that gate means
   anything and enforce it server-side if so.
7. **Money is stored as `Float`** (price, reserve). Escrow already quantises
   with `Decimal`; moving the columns to `NUMERIC` is the durable fix.
8. **Map precision is county-level** now. When a "near me" feature returns,
   add subcounty points (or opt-in GPS, rounded) rather than the phone's
   raw position.

---

## 5. Checks

| Check | Result |
|---|---|
| Backend, SQLite + real Redis | **1108 passed**, 2 skipped (`alembic` CLI; one PostgreSQL-only test) |
| Backend, PostgreSQL 16 | **1110 passed** |
| New backend tests (`test_listing_posting.py`) on the old code | 43 fail on SQLite, plus the 5 PostgreSQL-specific ones there; the 8 that pass are the allowed-case controls |
| Flutter `analyze` (CI flags) | 0 errors, 0 warnings (21 infos, unchanged) |
| Flutter `test` | **252 passed** (16 new in `listing_publish_test.dart`) |
| Web | untouched |
