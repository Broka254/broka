# BROKA — Online Stores UI Review

**Date:** 2026-09-28
**Scope:** how online stores look and feel, as shipped through phase 3 of
`STORES_PLAN.md`: the web storefront (`web/`), the app's store screens
(`flutter_app/lib/features/stores/`), and the store's place on the app's
product screen. The code quality and the backend were reviewed separately
(`STORES_REVIEW.md`); this is about the UI only.

**How:** the web storefront was run against a stand-in API holding one
fully set-up store (cover, logo, description, 11 products, 4 categories)
and one bare store (no images, 2 products), and captured with Chromium as a
Pixel 7 (412×839), an iPhone 13 (390×664) and a 1366×900 desktop. Positions
quoted below were measured on those pages. Flutter isn't installed in the
review environment, so the app screens were assessed from their code; they
follow the web layout closely, so most web findings apply to both.

---

## 1. Verdict

**The idea is a seller's own shop behind a link. The UI is a BROKA page
with a seller's profile on it.** The engineering is careful (fast
server-rendered pages, real link previews, no layout overflow at 320 dp),
but three things make the store feel like BROKA's page rather than the
seller's shop:

1. **The shop window is below the fold.** Someone who taps a store link on
   TikTok or WhatsApp sees BROKA's app banners, a cover, the seller's
   record and a paragraph about the shop, but **not one product**.
2. **There is nothing for a visitor to do.** No buy, no contact, no cart.
   The only action on a product is "Make an offer in the BROKA app", which
   on an iPhone or a computer downloads an Android APK. The loudest button
   on the store page, a green **WhatsApp**, shares the store; it doesn't
   reach the seller.
3. **Every store looks the same, and looks like BROKA.** The same animated
   space background, the same violet, the same cards. Only the cover and
   logo change, and a store without a cover gets the same gradient as
   every other store in its category.

Phase 4 (cart and checkout) fixes most of point 2. Points 1 and 3, and the
parts of 2 that don't need checkout, are UI work that can happen now, and
should, because checkout will be built into these layouts.

---

## 2. What works (keep it)

- **Speed and sharing.** Pages are rendered on the server and cached, link
  previews have a real JPEG image, `?via=` tags are counted, and every
  filter is a shareable URL.
- **The category rail** matches the app's Home rail (same emoji, same
  gradient rings), with product counts. It reads as BROKA and it's useful.
- **The owner's side.** The setup wizard (one question per screen, draft
  kept on the phone, live link check), the "your store is live" screen and
  the share card (six one-tap destinations, QR code) are the strongest
  part of the feature.
- **Honest numbers.** Trust chips and stats show only real counts; nothing
  is invented.
- **Works without JavaScript**, respects reduced motion, and the app has
  no-overflow tests at 320 and 430 dp.

---

## 3. Findings

Severity is about what a shopper or seller loses, not about the code.

### High

**H1. No product in the first screen on a phone.**
Measured on the Clanix page: the first product card starts at **867 px on
a Pixel 7** (screen height 839) and **814 px on an iPhone 13** (664). Above
it, in order: the "Open in the app" banner (54 px), BROKA's header with
"Get the app" (65 px), the cover, logo and name, four trust chips over two
lines, the description (six lines here), the email, the share buttons, the
category rail, the search box, and the sort box on a row of its own
(`store.module.css`, the `max-width: 560px` rule). A visitor arriving from
a social link decides in the first screen whether this is a shop worth
scrolling; today that screen has no goods in it. The app's
`StoreHomeScreen` has the same order (268 dp header, description, search,
rail, then the grid).

**H2. BROKA's chrome comes before the store.**
The top 119 px of a phone screen are two separate prompts to install
BROKA (`OpenInApp` banner and `SiteHeader`'s "Get the app"), and the
header shows BROKA's logo, not the store's. The page title is the store's,
but the frame is BROKA's. A seller sharing "my shop" gets a page that
advertises someone else first.

**H3. The product page's only action fails for most visitors.**
`AppButton` sends every non-Android visitor to `APP_DOWNLOAD_URL`, the APK
file (`web/src/components/AppButton.tsx:13`). On an iPhone or a computer,
"Make an offer in the BROKA app" downloads a file that can't be installed.
It also sits below the fold (922 px on a Pixel 7, 846 px on an iPhone 13)
and doesn't stay on screen. With phone and WhatsApp contacts removed
(`STORES_PLAN.md` decision 8) and checkout not built, a non-Android visitor
can only share the page.

**H4. The green "WhatsApp" button means the opposite of what shoppers
expect.** In the store header it's the brightest element on the page
(`StoreHero.tsx:50`, `ShareButtons.tsx:53`). On a Kenyan shop page, a green
WhatsApp button means "chat with the seller"; here it opens WhatsApp to
send the store's link to someone else. Sharing is the owner's action (and
the owner has a better share card in the app); on the buyer's page it
should be a small share icon, as the app's store screen already does.

### Medium

**M1. The product page is a dead end.** After the seller card comes the
footer. There's no "More from Clanix Electronics", no other products at
all, so a shopper who opened one shared product has to find the small
"← More from…" link at the top to see anything else.

**M2. Shop photos are collected and never shown.** The wizard's "Store
photos" step ("Optional - show buyers your shop", up to 6) uploads them,
but neither the web nor the app displays them; they're only a fallback for
a missing cover (`web/src/lib/storefront.ts:26`, the app's
`Store.coverSource`). A seller who adds photos of their stall sees them
nowhere.

**M3. Stores have no identity of their own.** Everything but the cover and
logo is BROKA's: background, colours, card style, typeface (the web uses
the system font). A store with no cover gets a flat gradient taken from
its category, so every food store is the same orange block. The dark
neon-space look suits BROKA and Zeno; it suits a phone shop, but not
necessarily a bakery, a boutique or a salon, whose photos read better on a
lighter, calmer page. A seller can't make the page feel like theirs.

**M4. The animated background runs behind the text.** The constellation's
lines and glowing dots pass under the description, prices and product
details (visible in every screenshot). On a marketing page that's
atmosphere; on a shop page it's noise behind the words people need to
read, and one more thing that makes the shop look like BROKA.

**M5. Controls don't scale with the catalogue.** The bare store (2
products, 1 category) still shows an "All · 2" pill beside a "Food &
Beverages · 2" pill, a full-width search box and a full-width sort box:
about 300 px of controls above two products. A rail with one real category
adds nothing; search and sort are for catalogues that don't fit on a
screen.

**M6. Product cards repeat what doesn't change and leave out what does.**
On the web every card in a store carries the store's location ("Starehe,
Nairobi" on all 11 cards, `ProductCard.tsx:32`), while the condition
(New / Used / Refurbished, which matters most for electronics) is only on
the product page. In the app the store grid reuses the marketplace
`ProductCard` (`store_home_screen.dart:258`), which puts the seller row
(avatar, name, badge, rating) and the store's own name on every card
inside the store: rows meant for the mixed Home feed, identical on every
card here.

**M7. The escrow promise is the faintest text on the page.** "Pay through
BROKA and your money is held safely…" is 12.5 px in `--text-low`
(`store.module.css:640`): 3.5:1 contrast on the background, below the 4.5:1
WCAG AA asks of small text. It's BROKA's reason for a stranger to trust a
store they found on TikTok, and it reads as a footnote. Card locations use
the same colour on a card surface: 2.9:1.

### Low

**L1. Unreadable text in the app.** `BrokaColors.textLow` (#2E3D5A) is
1.9:1 on the background and 1.5:1 on cards. The store screens use it 17
times, including "Takes about 3 minutes", "Print this QR code for your
shop counter", the store directory's location line and the review step's
field labels. (Home's product card was already moved off it for this
reason, `widgets/product_card.dart`, "Polish pass" comment.)

**L2. The cover is cropped differently everywhere.** Picked at 16:9 in the
wizard (`store_setup_steps.dart:705`), previewed at 16:7 on the review step
(`:902`), shown at about 1.5:1 in the app header (268 dp), 2.4:1 on a phone
browser (170 px tall) and 3.5:1 on a desktop (1120×320). The seller can't
know what buyers will see of their photo.

**L3. The gallery is tap-only.** No swipe between photos on a phone, no
full-screen or zoom; thumbnails are 64 px buttons.

**L4. The app's product screen doesn't know about stores.** A store
product opened in the app, including from a shared product link, shows the
seller section linking to the personal profile
(`screens/product_screen.dart:497`), never "Sold by Clanix Electronics →
visit the store". The listing model already has `storeId`, `storeName` and
`storeSlug` (`models/listing.dart:60`).

**L5. Nowhere to find stores on the web.** `broka.co.ke` itself says "Have
a store link? Open it" and nothing else; there's no directory or search.
In the app, the directory (`store_list_screen.dart`) is a plain list: a
round logo (the store page uses a rounded square), no cover, no product
previews, and "11 listings" where every other screen says "products".

**L6. Emoji and text glyphs as icons on the web.** The search icon is the
character ⌕, the email is ✉, trust chips use 🤝 and 📅. They render
differently on every phone and look unfinished next to the app's Material
icons.

**L7. Four trust chips wrap to two lines** on a phone, and "On BROKA since
2026" on a brand-new store is a weak signal given equal weight. One line
("✓ Verified · ★ 4.7 · 38 deals") would say the same in half the space.

---

## 4. Proposed upgrade

Three stages. The first needs no backend change and fixes everything
marked High; the second gives stores an identity; the third is phase 4's
cart and checkout, dropped into layouts already built for it.

### Stage A - The shop window (web and app, UI only)

- **Store-first frame.** A slim sticky header with the store's logo and
  name, a share icon and (later) the cart. BROKA shrinks to a "Protected
  by BROKA" badge and the footer. One install prompt, not two, and only on
  Android.
- **Compact store header.** A fixed-ratio cover (one ratio everywhere, with
  the wizard showing the crop), logo, name, and one trust line. The
  description collapses to a couple of lines with "More", as the app's
  `_Description` already does. Target: the first row of products visible
  on a 390×664 screen.
- **Controls that scale.** No category rail with fewer than two
  categories; search and sort only when the catalogue doesn't fit on a
  screen or so; sort as a compact button beside search on phones (the
  app's layout).
- **Cards for a shop.** Drop the repeated location; add a condition badge;
  in the app, a store variant of `ProductCard` without the store and
  seller rows.
- **Product page.** Swipeable gallery with full-screen view; a sticky
  bottom bar with the price and the main action; "More from this store"
  below the details; the escrow promise as a visible block with an icon,
  not a footnote.
- **An action that works on every device.** Android: open in the app, as
  now. iPhone and desktop: never the APK. Until checkout, say plainly that
  buying opens with the app on Android and web checkout is coming; on a
  desktop show a QR code to open the product on a phone.
- **Share moves out of the way.** A share icon in the header and on the
  product page's action bar; no big green WhatsApp button on the buyer's
  page.
- **Readable text.** Raise `--text-low` and the app's `textLow` to at
  least 4.5:1 on cards; keep the constellation behind the store header
  only, with a calm surface behind the catalogue and product details.
- **An icon set on the web** (inline SVG) in place of emoji and glyphs;
  emoji stay where they carry meaning, in the category rail.
- **App parity:** the same changes in `StoreHomeScreen`, a "Sold by
  <store>" link on the product screen, and the directory card showing the
  cover and a strip of products.

### Stage B - The store's own look (small backend additions)

- **Store accent colour** (chosen in setup, suggested from the logo) that
  tints prices, buttons and the category rail; stored as a new `stores`
  column through `init_db()`'s migrations list.
- **Light or dark page**, chosen by the seller. Dark stays the default for
  BROKA's identity; light suits food, fashion and beauty photos.
- **Featured products**: the owner picks up to six for a row at the top.
- **Shop photos shown** as a "Visit the shop" section with the landmark
  and location.
- **An announcement line** ("Free delivery in Nairobi this week").

### Stage C - With phase 4

Cart badge in the header, "Add to cart" and "Buy now" in the product
page's action bar, "Sold out" and "Only 2 left" on cards. Stage A's
sticky bar and header are where these go, so nothing is laid out twice.

---

## 5. Decisions needed before building

1. **Dark only, or a light option per store?** Recommendation: build
   Stage A on the current dark theme but with colour tokens, so a light
   theme in Stage B is a token set rather than a rewrite.
2. **What iPhone and desktop visitors do before checkout exists.**
   Recommendation: an honest message and a QR code, not a download. If
   E-Confirm and the rest of phase 4 are close, this may not be worth
   building separately.
3. **Order.** Recommendation: Stage A before phase 4, because checkout's
   buttons need the sticky bar and header that Stage A introduces.
