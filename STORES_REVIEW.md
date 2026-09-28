# BROKA — Online Stores Review

**Date:** 2026-09-28
**Scope:** online stores as shipped through phase 3 (`STORES_PLAN.md`):
the stores backend (`backend/api/domains/stores/`), the store side of
listings, the web storefront (`web/`), and the app's store screens and
store links (`flutter_app/lib/features/stores/`, `deep_link_service.dart`).
Phase 4 (stock, cart, checkout, orders) isn't built and isn't reviewed.

Every finding marked fixed was reproduced first, has a regression test,
and each test was run against the old code and failed there. The store
tests pass on SQLite and on PostgreSQL 16.

---

## 1. Verdict

**The design is sound and the code is careful.** The layering is right:
thin routes, one service that owns the rules, and a store's catalogue that
*is* its listings (`Listing.store_id`) served by `ListingService`, so a
store product can't drift from the same product on Home. The things that
usually go wrong in a feature like this were handled up front:

- **Ownership** is checked on the server against the signed-in user for
  every change, and on both sides when a listing moves into a store.
- **Links** are strict, case-insensitive, fixed once chosen, and refuse
  names that would pass for BROKA ("support", "mpesa"). One store per
  account is serialised with a row lock rather than a schema constraint,
  so several stores per owner stays a UI change.
- **Visit counting** can't be inflated by the caller: it's limited by user
  or real IP (the web storefront forwards the visitor's address under a
  shared key), de-duplicated per visitor, skips crawlers and link-preview
  fetchers, and never fails the page it rides on.
- **Images** are assets referenced by id, checked for owner and purpose;
  legacy fields take only inline images or the owner's own uploads.
- **The web storefront** calls the API only from its server, validates
  every path and query value, caches reads for a minute, returns real
  404s and 308s, escapes its JSON-LD, and gives WhatsApp a JPEG preview.

What was wrong was at the edges where two parts meet: the category rail
and the category filter disagreed about what "Other" means, the store
directory's search didn't use the escaping the listing search already
had, and a link tag one surface shortens another refused.

---

## 2. Fixed

| # | Severity | Finding | Fix | Test |
|---|---|---|---|---|
| 1 | Medium | **A store's "Other" category showed no products.** The rail (`GET /stores/{id}/categories`) counts every product whose category isn't one of BROKA's named ones as "Other" — free text from older app builds and API clients. Tapping it filtered on the word "Other", which found only products literally filed as "Other". In the app and on the web: "Other · 3", then "No products match". | "Other" filters on every listing outside the named categories (`categories.named_listing_categories`, `list_listings(outside_categories=…)`), the same rule the rail counts with. | `test_the_other_shelf_holds_what_the_rail_counts_there` |
| 2 | Low | **Store directory search treated `_` and `%` as wildcards**: searching "_" listed every store. The listing search had this fixed already (`api/core/text_search.py`). | The directory uses `term_matches`, which escapes them. | `test_directory_search_matches_the_text_not_wildcards` |
| 3 | Low | **A `?via=` tag over 32 characters lost the visit.** The app passes on the tag of whatever link opened it; the API refused the visit with a 422, and the app swallows errors, so it was never counted. On the API's own store page it was a JSON error instead of the page or its redirect to the web storefront. | The tag is shortened, not refused (`stats.short_via`); an unknown tag counts as "other" as before. | `test_a_long_link_tag_is_still_a_visit` |

---

## 3. Still open

None of these is a bug in the sense of code doing something other than
what it says; each needs a decision first.

1. **What pausing a store means.** Pausing empties the storefront and the
   web store page says "its products will be back soon", but the products
   stay on Home, in search and category zones, and open normally in the
   app; only the web product page redirects to the paused store. If paused
   should mean "not for sale", `list_listings` needs to leave out listings
   of paused stores (a join on `stores.is_active`), and the app's product
   screen should say so. If it only means "storefront closed", the web
   banner's wording should change.
2. **The owner's Products tab hides some of the owner's products.** My
   Store lists them through the public feed (`GET /listings?store_id=`),
   which shows only active, paid-up listings. A product in a deal, sold,
   or waiting for its listing fee disappears from the screen where the
   owner manages the store. An owner-only endpoint returning every status
   with its `fee_state` would fix it.
   **Done (2026-09-28):** `GET /stores/{id}/manage/listings` (owner only)
   lists every product with its state and fee, and My Store's Products tab
   uses it (`CHANGES.md`).
3. **Store display names aren't checked for impersonation.** The link
   can't be `safaricom`, but the store can be *named* "Safaricom Official".
   Apply the reserved-name list (or a review queue) to names too.
4. **Store counties are saved as typed.** Listings canonicalise counties
   (`canonical_county`); stores don't, and the directory filters by exact
   match, so a store saved by an older app build as "nairobi county" is
   missing from "Nairobi".
5. **Product links in the app don't check the store.** The web product
   page returns 404 unless the listing belongs to the store in the link,
   and redirects when the store is paused; the app opens the listing by
   id whatever the link's store says.
6. **Smaller:** the owner's own web visits are counted (the web page can't
   tell who's visiting; the app can and doesn't count them), and web
   product views are counted once per cache refresh (at most once a
   minute), not per visitor, because the API counts a view on each
   `GET /listings/{id}`.

Before phase 4, the open items in `STORES_PLAN.md` §6 (E-Confirm's email
requirement and sandbox run, the regulatory check, Render's plan) matter
more than anything above.
