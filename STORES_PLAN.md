# Online Stores — build plan (2026-09-23)

A BROKA store is a small business's own mini e-commerce site: its own link
(`https://broka.co.ke/store/clanix`) that the owner shares on TikTok,
WhatsApp groups and Instagram, where anyone can browse the shop's products by
category, add them to a cart and pay with M-Pesa, protected by BROKA's
escrow, without installing the app. Store products keep appearing on BROKA's
Home, search and categories like any other listing.

This plan replaces the current implementation, which was assessed on
2026-09-23: the backend has a sound but thin foundation (store identity,
unique link names, listings grouped by `store_id`, ownership checks, 45
passing tests), while the storefront, the share link, cart and checkout,
stock, and the app screens are missing or unusable. See the assessment in
the session history; the key findings are repeated where they drive a
decision below.

---

## 1. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Where do link visitors shop? | A real **web storefront** at `broka.co.ke`, usable without the app. People who have the app are taken straight into it. |
| 2 | What does the cart do? | **Cart + checkout at the listed prices.** Several items from one store, paid in **one M-Pesa payment** held in escrow. Every product keeps **"Make an offer"**, which goes through Zeno as today. Bundle negotiation comes later. |
| 3 | Can visitors buy without an account? | They sign in **during checkout with phone + SMS code**. New numbers get a buyer account on the spot. |
| 4 | Stock | Store products have a **stock count**. One listing sells many times and shows "Sold out" at zero. |
| 5 | Who can open a store? | **Long-term sellers.** A short-term seller who taps "Open an online store" first switches to long-term by giving their business details. |
| 6 | Images | Move to **Cloudflare R2** file storage with resized copies, **first**. Nothing else is fast or shareable without it. |
| 7 | Link format | **`https://broka.co.ke/store/<name>`.** The seller picks `<name>` during setup with a live "available" check. It **never changes afterwards**: renaming the store doesn't touch the link. |
| 8 | Contacts | Official phone and WhatsApp are **removed** from setup, the API and every page. **Business email** is added, optional to create a store. |

Standing rule: **every new screen uses `ConstellationBackground`**, the
glowing connected-dots background Home and the signup screens use. The web
storefront draws the same effect in the browser.

---

## 2. Architecture

```
  Flutter app ─────────────┐
                           ▼
  Web storefront ──────▶ FastAPI (Render) ──▶ PostgreSQL
  Next.js on Vercel         │
  broka.co.ke/store/*       ├──▶ Cloudflare R2 ──▶ media.broka.co.ke (images)
                            └──▶ E-Confirm (escrow + M-Pesa)
```

- **The web storefront calls the API from its own server**, never from the
  visitor's browser. That means no CORS, and the sign-in token lives in an
  httpOnly cookie that page scripts can't read.
- **Store and product pages are cached at Vercel's edge.** They refresh
  every 60 seconds, and immediately when the owner edits the store. A
  visitor from TikTok gets the page in well under a second even while the
  Render backend is asleep; only checkout needs the backend awake.
- **Images are served from R2's own domain** (`media.broka.co.ke`), in three
  sizes. That gives link previews a real image, and product grids load
  thumbnails of about 20–30 KB instead of the full base64 photos (often a
  megabyte or more per product today).
- **Payments reuse the escrow that already works.** An order becomes one
  `Deal` funded through the existing E-Confirm path. E-Confirm's
  transaction takes one amount and a description, so a multi-item order
  needs no new payment integration. Release, disputes, timers and the
  ledger all carry over.

---

## 3. Phases

Each phase ships on its own: backend, app and web together, with tests,
behind the previous phase's work.

### Phase 1 — Images ✅ (2026-09-23)

Shipped as planned, with these differences and additions:
- Sizes are **480 / 960 / 1600 px** (not 320/800): 320 was soft on a
  two-column grid at phone pixel densities.
- Base64 still sent by older app builds (listings, showcase, store images,
  profile photos) isn't converted inline: the id is left NULL and the
  5-minute backfill converts it, with compare-and-swap writes so an edit
  made during a conversion always wins.
- Listing cards carry a `cover` with `kind` ("showcase" | "photo") so the
  "✨ AI Showcase" badge stays accurate.
- Fixed on the way: the product page's Zeno verdict never actually sent the
  listing photo (it only accepted data URIs, and listing photos were bare
  base64). It now sends the stored image, and the server labels images by
  their real type instead of always JPEG.
- CI now runs `flutter test`.

Tests: `backend/tests/test_media_assets.py` (37),
`flutter_app/test/image_upload_test.dart` (14).

The original Phase 1 plan follows.

The foundation for everything after it. Today listing photos are raw
base64 joined with commas and sent in full on every list request (up to 6
photos plus videos per listing). Store logos and photos are the same, and
the create-store request uploads up to 13 images in one body.

**Backend**
- `api/core/storage.py`: an image store with two drivers.
  - `R2ImageStore`: S3-compatible calls to Cloudflare R2 (boto3, run off
    the event loop).
  - `DatabaseImageStore`: bytes in a `media_blobs` table, served by
    `GET /media/i/{key}` with long-lived cache headers. Used in tests and
    until R2 credentials are set, so nothing is blocked on setup.
- `media_assets` table: `id`, `owner_id`, `purpose` (`listing_photo`,
  `store_logo`, `store_cover`, `store_photo`), `width`, `height`,
  `sha256`, `variants` (JSON: storage key per size), `created_at`,
  `deleted_at`.
- `POST /media/images` (multipart, signed in, 30 uploads/min, 10 MB cap).
  Pillow confirms the file really is an image, rotates it upright,
  **strips all metadata** (phone photos carry GPS coordinates), and
  re-encodes to WebP at 320 px (thumb), 800 px (medium) and 1600 px
  (large). Returns `{id, urls: {thumb, medium, large}}`.
- Listings and stores point at assets:
  - listings: `listings.photo_ids` (ordered JSON list, max 6);
  - stores: `stores.logo_id`, `stores.cover_id` and `stores.photo_ids`.

  Responses carry URLs. The old base64 fields keep working for app builds
  already installed.
- **Slim list responses.** List endpoints (Home, categories, search, store
  catalogue) send a `cover` image URL pair and `photo_count` instead of
  every photo and video. The detail endpoint sends the full gallery.
- **Backfill**: a resumable, idempotent batch job converts existing base64
  photos, logos and store photos into assets.

**App**
- `ImageUploadService`: compresses, uploads each photo as soon as it's
  picked (with progress and retry), and returns asset ids. The sell flow
  and store setup send ids, not image bodies.
- `NetImage` widget on `cached_network_image` (already a dependency), with
  a placeholder. `ProductCard`, the product screen, the profile and
  listing analytics read URLs when present and base64 otherwise; 11 files
  read photos today.

**Done when:** new listings and stores store no base64, a 20-product page
is under ~200 KB of JSON plus thumbnails, and existing listings are
backfilled.

### Phase 2 — Store setup and "My Store" ✅ (2026-09-24)

Shipped as planned, with these differences and additions:
- **No new upgrade endpoint.** `POST /auth/upgrade-to-seller` already
  turns a buyer or short-term seller into a long-term seller with business
  name, category and location, so the wizard's first step (shown only to
  those sellers) calls it.
- **The link's base is a setting**, `STORE_LINK_BASE` (default
  `https://broka.co.ke/store`). Until broka.co.ke serves `/store/*`
  (phase 3), point it at the API's own `/store` page so links shared now
  open; the link *name* never changes either way.
- **Business email** codes come from `POST /stores/email/request-code` and
  `/stores/email/verify` (signup's email step refuses addresses that
  already have an account, and the owner's own address usually does). The
  owner's already-verified account email needs no code. An unproven
  address is refused, not saved unverified; app builds before phase 2
  still send `official_email`, saved as unverified, and nothing is sent to
  an unverified address.
- **Visits**: counted once per visitor per store per 30 minutes (Redis
  `SET NX`, in-process fallback), never for the owner, and never for
  crawlers or link-preview fetchers (WhatsApp and Facebook fetch every
  shared link to draw its preview). Sources: whatsapp, tiktok, instagram,
  facebook, x, qr, direct, other. Days are Kenyan days (UTC+3).
- **Sharing** uses a small Android share bridge in `MainActivity.kt`
  rather than a share plugin, since CI builds on a pinned Flutter/AGP:
  WhatsApp (or WhatsApp Business) directly, Facebook directly or its web
  sharer, X's web intent, Instagram's share target with the link also
  copied, TikTok copies the link and opens the app, and "More" opens the
  system sheet. The QR code (`qr_flutter`, pure Dart) carries `?via=qr`.
- **Subcounties** are the 290 constituencies, with "My area isn't listed"
  for free text.
- **Old stores** get a category from their `specialization` at startup,
  so the directory's category filter finds them.
- **Settings** reuse the wizard's own pages, one section at a time; the
  link is shown locked.
- My Store's orders and revenue wait for checkout (phase 4): nothing is
  shown in their place.
- Found on the way: `list_listings`'s "newest" sort was really BROKA's
  ranking; the store catalogue's "Newest" uses a new strict `recent` sort.

Tests: `backend/tests/test_store_setup.py` (67),
`flutter_app/test/store_setup_test.dart` (27, including no-overflow at
320 and 430 dp for every wizard page and store screen).

The original Phase 2 plan follows.

**Backend**
- Store fields:
  - `category`: one of BROKA's 16 real categories, replacing the separate
    11-item "specialization" list;
  - `business_email`: reuses the `official_email` column;
  - image ids from Phase 1.

  `official_phone` and `official_whatsapp` stop being accepted or
  returned; the columns stay, with no reader.
- **Link names**:
  - 3–30 characters: a–z, 0–9 and hyphens, no leading or trailing hyphen;
  - a reserved list (`admin`, `api`, `app`, `broka`, `cart`, `checkout`,
    `help`, `login`, `orders`, `store`, `stores`, `support`, `zeno`, ...);
  - `GET /stores/name-available?name=` (rate-limited) for the live check;
  - chosen once at creation, then fixed.
- **Who can create**: `POST /stores` returns 403 unless the account is a
  long-term seller. `POST /auth/upgrade-to-long-term` collects business
  name, category and location from a short-term seller.
- **Store payload** adds the owner's real trust facts (verified badge,
  rating, completed deals, member since), the product count, and the
  business email.
- `GET /stores/{name}/categories`: the categories this store actually has
  products in, with counts, from the listings' category ids.
- The store catalogue endpoint gains search, category filter, sort and the
  slim card format.
- **Visit counting**: a `store_visits` daily counter per store, split by
  surface (app or web) and by where the visitor came from (WhatsApp,
  TikTok, Instagram, Facebook, direct, other; read from a `?via=` tag the
  share buttons add, falling back to the referrer). Share-button taps are
  counted too.

**App**
- **`WizardScaffold`**: a shared step screen matching the signup look:
  `ConstellationBackground`, step progress bar, large title, content, and
  Back/Continue buttons. It's extracted from `auth_screen.dart`'s private
  helpers rather than copied.
- **Store setup wizard.** The draft is saved after every step, so leaving
  loses nothing. Values are pre-filled from the seller's signup details
  (`/auth/me`).
  1. **Store name**: pre-filled with the business name.
  2. **Store link**: `broka.co.ke/store/` plus a suggestion from the name,
     with a live ✓/✗ as they type and a clear note that it can't change
     later.
  3. **What you sell**: BROKA category chips (pre-selected from the signup
     business category) and a short description (pre-filled).
  4. **Location**: county picker (all 47), subcounty picker, and an
     optional landmark (the signup's location text as a hint).
  5. **Logo**: upload with progress and a square preview.
  6. **Store photos**: one wide cover photo and up to 6 photos of the shop.
  7. **Business email (optional)**: verified with the same email-code step
     signup uses. It's where order notifications go, and it can stand in
     for the seller email E-Confirm needs (see §6).
  8. **Review** everything, then **Launch**.
  9. **Your store is live**: the link, a QR code, share buttons for
     WhatsApp, TikTok, Instagram and more (system share sheet, each tagged
     with `?via=`), and "Add your first products".
- **My Store dashboard** (replaces `StoreManagementScreen`):
  - header with cover and logo;
  - live/paused switch;
  - share card (link, QR, share buttons);
  - stats (7-day visits, where visitors came from, orders, revenue);
  - **Products** tab: thumbnails, price and stock inline, **Add product**
    (the sell flow with this store pre-selected), and **Add existing
    listings** (multi-select);
  - **Orders** tab (Phase 4);
  - **Settings**: edit any part through the same wizard pages.
- **Entry points**:
  - Profile shows "My Store" for long-term sellers, or "Open an online
    store" for short-term sellers, which leads to the upgrade step and
    then the wizard;
  - the seller dashboard's store action leads there too;
  - the explainer screen is shown once, as the introduction.
- `CreateStoreScreen` and the old contact fields are removed.

### Phase 3 — The storefront (app and web), browsing

**App**
- **`StoreHomeScreen`** (replaces `StoreViewScreen`), on
  `ConstellationBackground`:
  - collapsing header (cover, logo, name, category, location, trust row);
  - search;
  - **category chips built like Home's**, using the same `CategoryVisual`
    registry, showing only this store's categories and their counts;
  - sort;
  - product grid of thumbnails with "Sold out" / "Only 2 left";
  - share, and the cart (Phase 4).
- **Deep links.** `https://broka.co.ke/store/<name>` (and `/p/<id>`) open
  this screen when the app is installed:
  - Android App Links (`autoVerify` intent filter, with `assetlinks.json`
    served by the web project);
  - iOS Universal Links (Associated Domains, with
    `apple-app-site-association`).

**Web (`web/`, Next.js App Router + TypeScript, deployed to Vercel)**
- `/store/[name]`: the store home, same layout and colours as the app,
  with the connected-dots background drawn on a canvas. It pauses when
  off-screen and when the visitor's system asks for reduced motion.
- `/store/[name]/p/[listingId]`: the product page, with gallery, price,
  stock, description, the seller's trust facts, "Add to cart"/"Buy now"
  (Phase 4) and "Make an offer in the BROKA app".
- **Link previews**: title, description and a real `og:image` (store cover
  or logo; the product photo on product pages).
- An "Open in the app" banner on Android.
- Visits are recorded with the source tag.
- A store that doesn't exist or is paused gets a proper page, not an error.
- The old HTML page served by FastAPI at `/store/{name}` redirects to the
  web URL.

### Phase 4 — Stock, cart, checkout, orders

**Backend**
- `listings.stock_quantity`. NULL means a one-off item, exactly as today.
  - Placing an order reserves stock with a single compare-and-swap update
    (`... SET stock = stock - :q WHERE stock >= :q`), the same technique
    auctions use for bids.
  - Unpaid orders give their stock back.
  - At zero the product shows as sold out; it isn't deleted.
- A negotiated deal on a stocked listing takes one unit instead of hiding
  the whole listing.
- **Fix: refunded deals re-list the product.** Today a deal refunded in
  chat, by the dispute process or by the auto-refund timer leaves its
  listing hidden (`pending`) forever; only an auction lapse re-lists.
  Refunds and cancellations now restore stock or set the listing active
  again.
- **`orders` and `order_items` tables.**
  - An order belongs to one store: one seller, so one escrow.
  - Items snapshot the name, price and thumbnail when ordered.
  - **Prices always come from the server.** A total sent by the client is
    never used.
- **Payment**: each order creates one `Deal` (`order_id` set, `listing_id`
  NULL) for the order's subtotal with the usual 3% commission. It's funded
  through the existing `POST /deal/{id}/fund` (one STK push), released when
  the buyer confirms delivery, and disputable through the existing dispute
  engine. Before this ships, the ~60 places in 11 files that read
  `deal.listing_id` are audited and covered by tests for order deals.
- **Endpoints**:
  - `POST /orders` (`X-Idempotency-Key`; checks stock, store active,
    checkout enabled);
  - `GET /orders/{id}`, `GET /orders/mine`, `GET /stores/{id}/orders`
    (owner only);
  - `POST /orders/{id}/cancel` (buyer before payment; seller before
    dispatch);
  - `POST /orders/{id}/dispatched` (seller).
- **Unpaid orders expire** in the 60-second loop, reusing the auction
  lapse's check for a payment already in flight, so a buyer who pays in the
  last minute is never cancelled.
- **Web sign-in by SMS code**: `POST /auth/otp/request` with purpose
  `sign_in` works for new and existing phone numbers. Verifying returns a
  session for an existing account, or creates a buyer account from name and
  phone (they can set a password later in the app). The same OTP rate
  limits apply.
- **Notifications** through the existing event subscribers:
  - seller: push and SMS for a paid order;
  - buyer: push or SMS when the order is dispatched.

**App**
- Cart per store, saved on the device, with a badge in the store header.
- Checkout: items and quantities, delivery details, M-Pesa number, email
  if E-Confirm still needs one, and the total with commission. Payment
  status reuses the existing E-Confirm payment screen. Then order tracking
  and "Confirm delivery".
- Product screen: **Add to cart** and **Buy now** for store products in
  stock; **Make an offer** stays.
- Seller **Orders** tab: new → paid → dispatched → completed, "Mark as
  dispatched", and message the buyer.

**Web**
- Cart saved in the browser.
- Checkout with phone and SMS-code sign-in, the M-Pesa prompt, live payment
  status, and an order page with status and "Confirm delivery".
- **Session**: the refresh token stays in an httpOnly, Secure, SameSite
  cookie on the web server's side; the access token never reaches page
  scripts. Every state-changing request is CSRF-protected.

### Phase 5 — Seller tools and finish

- Store stats screen: visits by day and by source, top products, orders
  and revenue.
- QR code poster for the shop counter (image to print or share).
- Bulk add and bulk stock edit.
- Store directory: filter by category and county.
- End-to-end tests: Playwright on the web store (browse → cart → checkout
  against a fake E-Confirm), plus a page-weight check.
- `STORES.md` replaces this plan as the description of what exists.

---

## 4. Quality bar (every phase)

- **Tests:** backend tests for ownership, races, limits and old-app
  compatibility; Flutter widget tests for each new screen; web component
  and end-to-end tests. CI gains `flutter test`, which it doesn't run
  today, and the web build and tests.
- **Security:**
  - ownership is checked on the server for every change;
  - uploaded images are re-encoded and stripped of metadata;
  - uploads, name checks, OTP and orders are rate-limited;
  - prices always come from the server;
  - order creation and payment are idempotent;
  - web sessions use httpOnly cookies with CSRF protection;
  - reserved store names are refused.
- **Compatibility:** app builds already installed keep working, with the
  base64 fields kept until the backfill finishes and a new build is out.
  Checkout switches on with a `STORE_CHECKOUT_ENABLED` flag.
- **Docs:** each phase updates the README and this file.

---

## 5. What I need from you, and when

| When | What |
|---|---|
| Before Phase 1 goes live | **Cloudflare R2**: create a bucket (e.g. `broka-media`), connect a public custom domain (e.g. `media.broka.co.ke`), and create an API token for it. Set `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET` and `MEDIA_PUBLIC_BASE_URL` on Render. Until then the database fallback works, so development isn't blocked. |
| Before Phase 3's web store | Tell me what `broka.co.ke` shows today (open `https://broka.co.ke/store/test` on your phone). In the Vercel project that owns the domain, point it at this repo with root directory `web/`, and set `BROKA_API_URL` to the Render URL. |
| Before Phase 3's deep links | An **Android release signing key**. App Links only verify against a fixed key, and CI currently falls back to the debug key. Add it to the GitHub repo as CI secrets. If you ship iOS, your **Apple Team ID**. |
| Before Phase 4 goes live | Ask **E-Confirm** whether buyer and seller email can be optional (it's required today). Decide on **Render's paid plan**: browsing is covered by the cached web pages, but checkout needs the backend awake. |

---

## 6. Risks and open items

- **E-Confirm needs both parties' emails** to create an escrow today. Until
  they confirm otherwise:
  - checkout asks the buyer for an email;
  - a store without a business email (and whose owner has no account
    email) shows "Add an email to accept payments" instead of "Buy now".
- **E-Confirm's API details are still unverified** against their live
  sandbox (noted in `backend/api/core/econfirm_client.py`). Phase 4 needs a
  sandbox run before launch.
- **Regulation**: taking payment for goods directly makes the Central Bank
  of Kenya note in `ARCHITECTURE.md` more pressing. Check with counsel
  before launch.
- **Render free plan**: covered for browsing by the cached pages; not for
  checkout (see §5).
