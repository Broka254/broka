# BROKA — Listing Flow Overhaul

**Date:** 2026-09-25
**Scope:** the sell wizard end to end — every step a seller goes through to
post a listing — plus what the new answers change on Home, the product
screen, Zeno, the SMS nudge and the AI cover image service.

Every bug fix below has a test that fails on the code before it (checked by
running the new tests against the old code); the new features have tests of
their own.

---

## 1. The flow now

Ten steps, one place that defines their order (`flutter_app/lib/screens/sell_flow.dart`).
Every step sits on Home's glowing constellation backdrop
(`SellStepScaffold` → `ConstellationBackground`), which stands still when the
phone asks for reduced motion.

| # | Step | What it asks | New? |
|---|---|---|---|
| 1 | Photos | Camera-verified photos, now taken with BROKA's own camera | camera is new |
| 2 | Category | A vertical, searchable list of 21 categories / 177 subcategories | new step |
| 3 | Details | Name, **land size (required for Land)**, the category's details, condition, direct/auction | reworked "Basics" |
| 4 | Description | **Required** (20+ characters), with tap-to-add prompts per category | now required |
| 5 | Price | Amount, **what it's for** (whole item / per bag / per kg / per plot…), **fixed or open to offers** | unit + negotiable new |
| 6 | Stock & delivery | **How many** ("100 bags"), **can you arrange delivery** (+ where) | new step |
| 7 | Location | County and area | — |
| 8 | Cover image | AI cover in a chosen look, a gallery cover, or skip | redesigned |
| 9 | Review | Everything, checked again | — |
| 10 | Go live | **Zeno asks: "should I SMS you when a buyer shows up?"**, then publishes | new step |

---

## 2. "The app closes and I land on Home" while adding photos

### What was really happening

Listing photos were taken with the **phone's own camera app** (image_picker,
`ImageSource.camera`). That hands the whole screen to another app, and while
it is open Android is free to kill BROKA to reclaim memory — on the 2–3 GB
phones most sellers use, it often does. Coming back from the camera is then a
cold start: the splash screen, exactly as if the app had crashed.

### What the earlier fix did (assessment)

The earlier fix made that kill **recoverable**, not rarer:

| Measure | Verdict |
|---|---|
| Draft saved before every camera launch (`SellDraftStore`) | Good — kept |
| Splash screen reopens the sell flow when a draft exists | Good — kept |
| `retrieveLostData()` recovers the in-flight shot | Good — kept, but see the bug below |
| Root cause (BROKA leaving the foreground) | **Not addressed** — the kill still happened every time memory was tight |
| Draft reopened at step 1 | The seller clicked through every step again |
| Photos left in the OS cache directory | Android may empty it; a restored draft then had no photos |
| **Bug:** a cover picked from the gallery (Cover step) that was lost to a kill came back through the same `retrieveLostData()` channel and was **added as a camera-verified listing photo** | Fixed |
| The chosen cover lived only in memory (a multi-MB base64 string) | Lost on every kill |
| Photo tiles decoded full-size images for 90 px thumbnails | Memory pressure — the very thing that gets an app killed |

### What changed

1. **In-app camera** (`listing_camera_screen.dart`, the `camera` plugin the
   selfie screen already uses). BROKA stays the foreground app, so it is not
   the process Android reclaims. Multiple shots per session, tap-to-focus,
   flash, rule-of-thirds grid, a counter, and each photo saved to the draft and
   uploading the moment it is taken. The camera is released when the app is
   backgrounded and reopened on return.
2. **Fallback kept**: if the in-app camera can't start (permission refused,
   an unusual camera driver), the seller can use the phone's camera — with the
   draft saved first, the lost-shot recovery, and the splash redirect.
3. **A pending-pick marker** in the draft (`pendingPick: camera | showcase`)
   says what a recovered image was for; a gallery cover can no longer become
   a "verified" photo.
4. **Resume at the step**: a draft saved in the last 30 minutes reopens at the
   step the seller was on — never past a step that isn't complete. An older
   draft opens at Photos with "Start over", since it was left on purpose.
5. **Photos kept in the app's own storage** (`SellPhotoStore`), removed after
   publishing or "Start over".
6. **Thumbnails decoded at thumbnail size** (`cacheWidth`).
7. **The cover is now saved with the draft** (an image id, or a kept file).

Honest limit: Android can still kill any app in the background (a phone call,
switching to M-Pesa). What changed is that taking photos no longer puts BROKA
in the background, and any kill now resumes where the seller was.

---

## 3. Categories

- **21 top-level categories, 177 subcategories**, in a curated order (most
  common first, "Other" last) instead of alphabetical — on Home's rail too.
  New categories: **Land**, Food & Beverages, Health & Medical, Baby & Kids,
  Arts & Crafts. Many new subcategories (Pickups, Tuk-Tuks, Tyres & Rims,
  Solar & Power Backup, Cereals & Grains, Fruits & Vegetables, Dairy & Eggs,
  Fertilizers, Irrigation & Water Tanks, Wigs, Uniforms, Short Stays &
  Airbnb, Warehouses & Godowns, and more — see `seed.py`).
- **"Vehicles" is now "Automobiles"**, renamed *in place*: the row keeps its
  id, so every listing, subcategory, filter and store follows. The listing,
  store and buy-agent rows that stored the name "Vehicles" are updated on
  start, and an old name sent by an older app build or draft is read as the
  new one (listing create, the category filter, the buy agent, the store
  directory). "Motorcycles" became "Motorcycles & Boda Bodas" the same way.
- **Land** is a category of its own. The old Property → Land subcategory was
  moved (same id) to Land → Residential Plots, and its listings moved with it.
  **A Land listing must give its size** (`land_size` + unit: acres, 50×100
  plots, hectares, m², ft²), checked on the server; the server also stores
  `land_size_acres` so the Land zone's size filter (0–50 acres) compares
  plots of any unit on one scale. Cards on Home show it: "📐 ⅛ acre", "📐 2 plots (50×100)".
- **Mtumba (Second-hand Clothes)** is the first subcategory of Fashion — so
  it leads the Fashion zone's subcategory rail on Home, highlighted ♻️ — with
  its own details (grade incl. "Grade 1 (Camera)", sold as piece/bundle/bale,
  clothing type, bale weight). Choosing it sets the condition to Used.
- **The picker**: a vertical list of categories, each with its emoji and a
  sample of what's inside, opening in place to its subcategories; a
  "Filed under Automobiles › Cars" banner; and a **search across every
  subcategory in the words sellers use** — "mahindi", "boda", "shamba",
  "mitumba", "iphone", "mabati" (`category_search.dart`). One request loads
  the whole taxonomy: new `GET /categories/tree`.

---

## 4. The AI cover image

### Weaknesses and production bugs found — all fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | **High** | Every generation failure was a **bare 500**: `FalGenerationError` was never translated, so "not configured", "photo refused" and "try again" all read as "generation failed" | Mapped to 503 / 422 / 502 with a code (`SHOWCASE_UNAVAILABLE`, `_REJECTED`, `_FAILED`) and a sentence for the seller; the operator's text stays in the log |
| 2 | **High (cost)** | **No rate limit** on a paid API — one signed-in script could spend the fal.ai budget | 12 per hour, 40 per day per seller (`SHOWCASE_LIMIT`) |
| 3 | **High (cost)** | Any bytes behind `data:image/` were forwarded to fal.ai and paid for, at any size | Decoded, validated and re-encoded (≤1600 px JPEG) first; not-an-image is a 400 that never reaches fal |
| 4 | High | **One seller's refused photo could switch generation off for everyone**: fal's 4xx for a bad input counted toward the circuit breaker | Rejected inputs don't count |
| 5 | High | **A dropped status poll threw away a finished, billed generation** | Transient poll errors are retried until the deadline |
| 6 | Medium | **The price was in the prompt**, and image models draw text — price stickers that go stale | Removed; plus an explicit "no text, logos, watermarks" instruction |
| 7 | Medium | The result came back as a **1–2 MB base64 data URI**: slow on mobile data, held in memory, re-decoded on every rebuild (flicker), lost on a kill, **and uploaded again at Activate** | Stored server-side as the seller's image; the app gets an id + URLs, previews the medium size, and publishing just references the id |
| 8 | Medium | The seller's photo was **re-sent as base64 on every generation** | The app names the photo by the id it already uploaded (ownership checked) |
| 9 | Medium | A result arriving after the seller left the step called `setState` on a disposed screen | Results are matched to the request; cancelled or stale ones are dropped |
| 10 | Low | Cover generated in the photo's own shape; cards show 4:3, so portrait photos lost their top and bottom | Generated at 4:3, JPEG |
| 11 | Low | Download had no size cap or type check; inputs (description, name) unbounded | Capped at 15 MB, must be `image/*`; inputs bounded |
| 12 | Low | App timeout (120 s) shorter than the server's worst case | 150 s |

### The new cover step

- **Six looks, chosen by picture, not by name**: Clean Studio, Luxury Night,
  Warm Wood, Fresh Outdoors, Neon Tech, Pastel Pop — each painted as a small
  animated scene (light sways, bokeh drifts, neon flickers, gold sparkles)
  in `cover_theme_art.dart`. The look most sellers of the category would pick
  is marked **Zeno's pick** and shown first. The prompt for each look lives
  on the server (`showcase.THEMES`); the app only sends its id.
- A holographic frame with a scanning line around the seller's photo, a
  shimmering generate button, a full-screen "Zeno is creating your cover"
  sequence (counter-rotating rings, orbiting sparks, live stage messages,
  Cancel), a **circular reveal** of the result and a **before/after slider**
  that sweeps once on its own.
- Gallery upload and "skip — use my photo" remain.

---

## 5. The new questions

| Question | Stored as | Where it shows / what it does |
|---|---|---|
| Description (required) | `description` | Required on the server too; the product screen now **shows it** (it showed a fixed placeholder before) |
| Price is for… | `price_unit` ("bag", "90kg bag", "plot"…) | "KES 3,500 / bag" on cards and the product screen; Zeno is told the price is for one unit |
| Fixed or open to offers | `price_negotiable` | Product screen chip; Zeno tells buyers the price is final instead of inviting offers |
| How many | `quantity` | "100 bags" badge on the card; product screen; Zeno |
| Can you arrange delivery (+ where) | `delivery_available`, `delivery_note` | Product screen; Zeno answers "can you deliver?" with the seller's answer |
| SMS when a buyer shows up | `sms_alerts` (owner-only) | The availability SMS (a buyer messaged, the seller hasn't replied in ~5 min, once per buyer, never at night) is sent only if yes. It used to be sent to everyone with no way to decline |

**The "100 bags of maize" case**: rather than a free-text field next to the
price, the price stays a number (escrow, sorting and filters need one) and the
unit is a choice — suggestions that fit the category (Cereals & Grains offers
90kg bag, 50kg bag, kg, tonne; Mtumba offers piece, bundle, bale; Land offers
plot, acre, hectare) or the seller's own word. The quantity step then asks
"How many bags do you have?", and buyers see **"KES 3,500 / 90kg bag · 100
bags"**. Escrow is unchanged: a deal holds whatever total the buyer and seller
agree.

---

## 6. Deploying this

- **Startup migrations** (`init_db()`, idempotent, SQLite and PostgreSQL):
  six listing columns — `price_unit`, `quantity`, `price_negotiable` (NOT NULL
  DEFAULT TRUE), `delivery_available`, `delivery_note`, `sms_alerts` (NOT NULL
  DEFAULT TRUE).
- **Category seed** on start: renames Vehicles → Automobiles and Motorcycles →
  Motorcycles & Boda Bodas in place, moves Property/Land → Land/Residential
  Plots, retires that row's old free "acreage" field, adds the new categories,
  subcategories and fields, and brings stored category names in line.
  Verified by building a database with the **old** code, then starting the
  new code on it, twice (SQLite and PostgreSQL 16): ids preserved, listings
  moved, nothing changed on the second start.
- **Older app builds**:
  - keep working for everything except one deliberate change: **a listing
    with no description is refused** ("Describe the item in at least 20
    characters…"). Builds from before the readable-errors fix show that as a
    raw error; those sellers need the update.
  - can list Land: its size fields are ordinary form fields for them.
  - get the old AI cover response (a data URI) — with the fixes above.
  - get `sms_alerts` on, as before.
- The Home rail order changes (curated, not alphabetical).

---

## 7. Checks

| Check | Result |
|---|---|
| Backend, SQLite + Redis | **1146 passed**, 2 skipped (1108 before; 38 new in `test_listing_overhaul.py`) |
| Backend, PostgreSQL 16 + Redis | **1148 passed**, none skipped |
| New backend tests on the old code | all 38 fail there |
| Flutter `analyze` (CI flags) | 0 errors, 0 warnings (21 infos, down from 22) |
| Flutter `test` | **285 passed** (252 before; 30 new in `sell_wizard_overhaul_test.dart`, 3 new in `listing_publish_test.dart`), including a run of every new screen with animations on |
| Web `typecheck`, `lint`, `test`, `build` | pass (52 tests); the store pages' prices say what they're for too ("KES 3,500 / bag") |
| Upgrade from an old database | SQLite and PostgreSQL, as above |

Not verified here: the in-app camera on a real phone (the plugin has no test
double; its capture, lifecycle and error paths are written to the same
pattern as the selfie camera, which is in production). **Test it on a
low-memory Android before release.**

---

## 8. Still open — recommendations, not changed

1. **Buying part of a lot.** A listing can now say "KES 3,500 / bag, 100
   bags", but a deal is still one agreed total. A quantity on the deal
   (buyer picks 20 bags → total computed) would make per-unit listings fully
   self-serve.
2. **Let sellers change the SMS choice later** (`sms_alerts` on
   `PATCH /listings/{id}` plus a toggle in the seller dashboard).
3. **Real photos for the cover looks** would be richer than the painted
   scenes once the design team produces them (the tiles take any widget).
4. The splash screen still opens the sell flow for **any** saved draft, however
   old (unchanged behaviour); consider expiring drafts after a few weeks.
