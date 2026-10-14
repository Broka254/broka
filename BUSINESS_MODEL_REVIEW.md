# BROKA's business model without the commission

Written 2026-10-05. It answers the founder's request: attack the current listing
fee, premium plans and store prices on facts (cost, the quality and uniqueness
of what BROKA does, the Kenyan market), then propose something better.

What it is built on:

- the pricing code (`backend/api/domains/pricing/`), run for every number below
- live usage on Railway
- Kenyan and international market research, with sources at the end

The proposal was then attacked by five independent reviews: a Luthuli Avenue
phone shop, a car yard and property agent, a one-off private seller, a numbers
and loophole auditor, and a marketplace strategist. Their findings changed it;
section 6 lists what was dropped and why. The founder's decisions, and what
is already in the code, are in section 5.

Hard rules it keeps:

- no buyer-to-seller payments through BROKA for now
- everything charged up front, nothing after a deal is agreed
- a listing fee from the start
- the listing fee nudged up, not jumped

---

## 0. The short answer

1. **The listing fee is too cheap for what each sale is worth, and today it is
   not even the fee you think.** Production still runs the old √price formula. The price × quantity fix (commit
   `d21c476`) is on main, but the live API on Railway still runs commit
   `2cd5649`, which is older than the fix. Against the 3.49% commission it replaces, the fee recovers
   1/10 of one phone sale, 1/34 of a car sale and 1/103 of a house sale.
2. **But the fee is not where the money is.** About 70% of listing-fee income
   comes from the ~10% of listings worth KES 300,000 or more (cars, land,
   houses). Raising the phone fee moves revenue very little. It mostly risks
   supply in the one category where every competitor is free.
3. **Some of the "gold" is not built yet.**
   - Zeno today is an impartial go-between. It does not negotiate for the
     seller, there is no floor price, and "is it still available?" goes back
     to the seller.
   - Pro's "hunts and haggles for you" is a single fixed-text message.
   - The storefront tells buyers their money is "held in escrow". BROKA holds
     no money, so a fraudster can use that sentence.
   - The "Verified" badge checks no ID, yet it lifts rank.

   Charging gold prices for iron that is labelled gold is the fastest way to
   lose sellers. Fix the claims now and build the gold:
   - **Zeno on your link:** web chat with no APK.
   - **Floor-price negotiation:** Zeno bargains down to a price the seller
     sets privately.
4. **Early money comes from businesses, not from private listings.**
   - Phone shops, car yards and letting agents pay monthly.
   - Auto Trader UK earns 80% of its revenue from dealers and 3.8% from
     private sellers.
   - Today BROKA cannot bill a store at all, because store billing was never
     built.
5. **Proposed:**
   - **Listing fee:** up about 40% on every listing. A KES 20,000 phone goes
     from 70 to 100, a KES 800,000 car from 820 to 1,120.
   - **"Until sold" for cars, land and houses:** one up-front price that
     keeps the listing up until it sells.
   - **"No buyer, no charge" renewal guarantee.**
   - **Premium:** buyers free, a KES 99 AI cover pack, and Pro sold only
     once Zeno really sells for the seller.
   - **Stores:** priced by item count per trade. Phone shops from KES 599,
     car yards and agents from KES 2,999.

---

## 1. Attack: what is wrong with the current model

### 1.1 The listing fee

The listing fee as the engine charges it today, with payments paused:

| Listing | Fee/month now | % of value | 3.49% of one sale | Commission ÷ fee |
|---|---|---|---|---|
| Phone, KES 20,000 | 70 | 0.35% | 698 | 10× |
| iPhone, KES 180,000 | 310 | 0.17% | 6,282 | 20× |
| Car, KES 800,000 | 820 | 0.10% | 27,920 | 34× |
| Plot, KES 1.5M | 1,380 | 0.09% | 52,350 | 38× |
| House, KES 10M | 3,380 | 0.03% | 349,000 | 103× |
| Shirt, KES 300 | 10 | 3.3% | 20 | 2× |

- **It was designed as a small extra on top of a commission.** Both PRICING.md
  ("next to that the listing fee is small") and the code's comments say so.
  Now there is no commission, and the extra is the whole income.
- **It falls ~100-fold as a share of value, from shirts to houses.** It is
  heaviest where items are cheapest and lightest where BROKA's work and the
  fraud risk are greatest. A registered estate agent's statutory fee on a
  KES 1.5M plot is KES 79,000. BROKA charges 1,380 a month.
- **Cost never limited it.** A phone listing costs BROKA about KES 3-4 a month
  to serve, and the fixed bill is ~KES 773 a month (Railway Hobby plus the
  domain). The KES 9-11 "cost floors" in the code are Azure planning-scale
  figures, not today's bill.
- **It is charged before BROKA can show a buyer.** With fees on, an unpaid
  listing is hidden. Since the move to Railway (1-5 October), production
  has had 3 sign-ups, 20 listings and 12 Zeno negotiation messages. Hiding every unpaid listing on
  that shelf empties it.
- **The machinery is dead weight while payments are off.** The record
  discount (R) and the launch offer are both measured in escrow deals, which
  can't happen. The fee is now just the value bands.
- **There are loopholes that make it optional:**
  - Auctions pay no listing fee, and their length is not capped.
  - A listing posted under the free line and "corrected" upward within
    24 hours stays free.
  - Listings posted while fees are off stay free forever.
  - Rentals are priced on one month's rent: a KES 30,000/month house pays
    KES 85.
- **There is no record of sales.** With payments off, nothing tells BROKA that
  an item sold. Deleting a listing records no reason, and reviews need an
  escrow deal. So BROKA cannot prove it works, which is the founder's own goal.

### 1.2 Premium (Plus 199, Pro 599, Elite 1,499)

- **It sells features the code doesn't have.**
  - "Hunts and haggles for you" is one fixed opening message
    (`buy_agent/actions.py:738`).
  - Zeno's prompt makes it an impartial broker on both sides
    (`negotiate.py:141`).
  - The price check compares only BROKA's ~20 live listings.
- **One plan is sold to two different people.** Buyers buy a phone every year
  or two, so a monthly plan suits them badly. Buyers are also the side BROKA
  most needs, and charging them shrinks it.
- **It is priced against Netflix and Spotify**, with allowances counted in
  model calls. A seller thinks in buyers and sales, not "voice requests".
- **It earns nothing today.** `PREMIUM_ENABLED` is off by default. While it is
  off, AI covers, the most impressive seller feature, are switched off
  entirely.
- **It would cut sellers off from buyers.** Once premium is on, a seller
  without a plan is never texted that a buyer is waiting. The app has no
  Firebase push set up (no `google-services.json`), so the text is the only
  alert that reaches a closed phone.

### 1.3 Stores (KES 499-6,999, by number of listings)

- **Stores can't be billed.** Billing was never built, so every store is free.
- **They are priced per slot, not per value.**
  - 20 cars worth KES 800,000 each pay 16,400 a month as separate listings,
    but would pay 499 in a Starter store.
  - 200 iPhones fit in one slot.
- **The storefront tells buyers things that aren't true now.** "Escrow
  protected" appears in at least 6 places, including "Pay only through BROKA.
  Your money is held in escrow".
- **Web buyers can't reach Zeno.** A buyer arriving from WhatsApp or TikTok
  can browse but must sideload an Android APK from GitHub to ask anything.
  iPhone buyers have no way in.
- **The anchors are wrong for both ends.** Prices were set against Lacesse
  and Shopify, which take orders on the web. For a phone shop the competitor
  is the free WhatsApp catalogue. For car yards and agents the competitors
  charge far more: Househunt KES 10,000-15,000 a month, BuyRentKenya up to
  KES 110,000, car dealers reportedly KES 10,000-40,000 (unverified).

### 1.4 Boosts and the badge

- **Boosts cost KES 99 a week**, against market prices of KES 450-1,000:
  PigiaMe Gold Boost 500-1,000, Jiji TOP reportedly from 450 a week. Only
  short-term sellers may buy them.
- **The "Verified" badge (KES 299-599) is granted on payment with no ID
  check**, and adds up to 0.05 to a listing's rank score. While the other
  trust signals are frozen, that is money buying rank.

---

## 2. The proposal

### 2.1 Listing fee: the nudge

**The bands rise by roughly a third.** Every listing goes up by about the
same share (35-47%), so no category is singled out:

| Part of the listing's value | Now | Proposed |
|---|---|---|
| First KES 20,000 | 0.35% | **0.50%** |
| KES 20,000-200,000 | 0.15% | **0.20%** |
| KES 200,000-2M | 0.08% | **0.11%** |
| Above KES 2M | 0.02% | **0.03%** |
| Cap per listing per month | 10,000 | **15,000** |

The fee is still charged on **price × quantity**, so 200 iPhones are not
3 iPhones.

| Listing | Now | Proposed | Sales through BROKA needed for the fee to equal the 3.49% |
|---|---|---|---|
| Phone, KES 5,000 | 18 | 25 | 14% a month |
| Phone, KES 20,000 | 70 | **100** | 14% a month |
| Phone, KES 60,000 | 130 | 180 | 9% |
| iPhone, KES 180,000 | 310 | 420 | 7% |
| 3 iPhones | 610 | 835 | |
| 200 iPhones | 8,580 | 12,640 | (a dealer: belongs in a store, 2.3) |
| Sofa, KES 25,000 | 78 | 110 | 13% |
| Car, KES 800,000 | 820 | **1,120** | 4% |
| Car, KES 2.5M | 1,880 | 2,590 | 3% |
| Plot, KES 1.5M | 1,380 | **1,890** | 3.6% |
| House, KES 10M | 3,380 | 4,840 | 1.4% |

Why KES 100 for the phone and not more:

- It is the founder's own example.
- M-Pesa charges nothing to collect KES 100 or less.
- It is half what E-Confirm would charge to escrow that phone (1% = 200).
- Every competitor lists phones for free.

The phone's value ceiling is low. The money is in the high-value rows.

**Rules that come with it:**

- **"No buyer, no charge."** If a paid listing gets no buyer chat or call in
  its paid month, its next month is free. This applies at most twice, and
  only if its price was not raised. It costs BROKA about KES 3.5 per free
  month. It means renewing never depends on a promise; it depends on buyers
  BROKA actually delivered.
- **"Sold? Replace it."** When a seller marks a listing sold, on BROKA or
  elsewhere, its unused paid days move to their next listing. Days move, not
  money. If the new listing's fee is higher, the days shrink in proportion
  (`price_rules.shortened_paid_until` already does this). Electronics sell in
  about 14 days, so without this a shop pays twice a month for one shelf
  space. It also gives sellers a reason to report sales, which is BROKA's
  only sales record (2.6).
- **Items under KES 2,000 are free**, in everyday goods categories only (not
  vehicles, land, property or business equipment). There are at most 5 at a
  time, and raising one past KES 2,000 makes it chargeable. A KES 10 fee on a
  shirt earns nothing and adds an M-Pesa prompt.
- **"Until sold" for cars, land and houses (private sellers).**
  - One up-front payment equal to the months BROKA's own engine expects the
    item to take to sell. After that the listing stays up until it sells
    (capped at 6 months for vehicles, 12 for land and houses).
  - The seller confirms "still for sale?" every 14 days.
  - The listing is tied to the number plate, chassis number or LR number, so
    one payment can't be reused for another car.

  | Item | Until sold | % of price |
  |---|---|---|
  | Car, KES 800,000 | **2,790** (3 months' worth) | 0.35% |
  | Car, KES 2.5M | 8,180 | 0.33% |
  | Plot, KES 1.5M | **7,190** (5 months' worth) | 0.48% |
  | House, KES 10M | 18,410 | 0.18% |

  Auto Trader UK and Carsales charge private sellers 0.7-1.5% for the same
  "until sold" product, but they already bring the buyers.

  The monthly fee stays available. A seller with no buyer contact in 45 days
  gets the fee back as BROKA credit.
- **Lettings: a flat fee per vacancy, "until let" (at most 60 days).** This
  replaces pricing rent as if it were a sale price.

  | Monthly rent | Up to 20k | 20-60k | 60-150k | Over 150k |
  |---|---|---|---|---|
  | Fee | 299 | 499 | 999 | 1,499 |

  The top band is at or below BuyRentKenya's KES 1,500 per 30 days. An
  agent's letting fee is one month's rent. This needs a required "For sale /
  To let" field on property. It is a much bigger rise than the nudge (a
  KES 30,000 let goes from 85 to 499), so it is the founder's separate call.
- **The founding-seller offer stays**: the first 50 sellers' first listing is
  free, the next 150 pay half. Three changes:
  - It applies to the first listing that has a fee, and the 30 days start
    when that listing goes live.
  - The discount is capped at KES 500, so a farmed account can't take a free
    plot.
  - It is one offer per ID-checked seller.
- **Close the loopholes before fees go on:**
  - Cap auctions at 7 days (14 for vehicles, land and property). While
    payments are off, an auction pays the listing fee for its days.
  - Listings posted before fees start stay free until sold, or until 60 days
    after fees go on, whichever comes first. Announce this as "list now".
  - A quantity cut is free. More than 10 units of one item belongs in a
    store.

### 2.2 Premium: split by who pays

| Who | What | Price |
|---|---|---|
| **Buyers** | Zeno chat, the Buying Agent (up to 3 watches), voice up to 10 requests a month | **Free.** Buyers are the side BROKA lacks, and they buy too rarely for a monthly plan |
| **Every seller** | The "a buyer is waiting" text, up to 30 a month | **Free, always.** It costs KES 0.35 each and is the only alert that reaches a closed phone |
| **Any seller** | **AI cover pack**: 4 cover tries on one listing, plus the cover as an image for WhatsApp status with an "on BROKA" mark | **KES 99 per listing.** Replaces Plus. Costs BROKA ~25. It works with zero BROKA buyers |
| **Sellers** | **Zeno credits**: Zeno handles a buyer conversation for you (answers from the listing, negotiates to your private floor price, calls you in when there is a deal) | **KES 99 per 10 conversations**, once Zeno can do it. A credit counts only a phone-verified buyer who sends 2+ messages, once per buyer per listing. When credits run out, Zeno goes back to free relaying, so the seller never loses a buyer |
| **Sellers** | **Seller Pro**: 40 Zeno-handled conversations, covers for ~7 listings, 120 voice requests, descriptions, price checks, 50 extra texts | **KES 599/month**, sold only once Zeno really sells for the seller (gate: it answers at least 30% of buyer questions without the seller, across 50+ threads). What BROKA keeps after VAT is 1.50× its cost at full use; the code's floor is 1.25× |
| Elite | | Folded into store plans |

Fix now: Pro's pitch, which promises haggling that doesn't exist.

The cheapest honest premium sells what works with no BROKA buyers today: AI
covers, voice and descriptions. Zeno credits are what turn BROKA's AI into
money that grows with demand (2.5).

### 2.3 Stores: any size the owner picks, priced per trade

Decided 2026-10-06 and in the code (`plans.STORE_RATE_CARDS`,
`GET /pricing/store-plan`). The founder's change is that KES 599 covers
30 listings, not 20, and the owner picks any size: 40, 500, anything in
between. Each listing past the base adds a little, less as the store grows.
One more listing never jumps the price, the way the old fixed plans did:
listing 21 moved a store from 499 to 999.

Stock value was tried and dropped (section 6). The value of the stock is
whatever the seller types, and tiers on it had cliffs: one more phone moved a
shop from 499 to 1,499. Count is something BROKA can see. Kenyan portals
already price by count, and the big value differences between trades are
carried by separate rate cards.

**Shops** (phones, electronics, fashion, home and everything but vehicles,
property and land):

| Listings | 30 | 40 | 50 | 100 | 250 | 500 | 1,000 |
|---|---|---|---|---|---|---|---|
| Price/month | **599** | 759 | 919 | 1,719 | 3,819 | 6,819 | 12,819 |
| The fixed plan it replaces | 499 (20) | 999 (50) | 999 | 1,799 | 3,999 | 6,999 | by hand |

That is 599 for up to 30, then KES 16 a listing to 100, 14 to 250, 12 to
1,000. Above 1,000, priced by hand. A phone shop with 15 phones pays 599; the
same phones listed one by one cost ~1,890 a month.

**Car yards** (vehicles only, at least 5 live): KES 2,999 for up to 10, then
200 a car to 25 (5,999), 114 to 60 (9,989), 100 to 200.

- That is KES 120-300 a car a month.
- A KABA member pays ~866 a car a month to show it at Jamhuri on Sundays; a
  private seller pays 4,330.
- A private KES 800,000 car pays 1,120 as a listing.

**Agents** (property and land only, at least 5 live): KES 2,999 for up to
10, then 150 a listing to 30 (5,999), 57 to 100 (9,989), 50 to 300.

- This is below Househunt (10,000 for 20, 15,000 unlimited) and BuyRentKenya
  (5,000-110,000), because BROKA doesn't have their buyers yet.
- Move toward their prices once enquiries per listing are measured.

**Every store, once store billing is built:**

- includes the listing fees for its listings, the storefront at
  `broka.co.ke/store/<name>`, the free buyer texts, and a free ID and business
  check (2.4)
- keeps the setup fee (299, waived on 6 months prepaid)
- shops can't hold vehicles, land or property, so nobody opens a "store" to
  dodge a car's listing fee
- a listing holding more than 10 units counts as one listing per 10 units, so
  200 iPhones aren't priced like 3 in a store either
- "No buyer, no charge" for stores: fewer than 5 different buyers enquiring
  (10 for yards and agents) in a paid month makes the next month free
- **the first 20 businesses** get 50% off, locked for 12 months. They are
  billed by hand through an M-Pesa till until store billing is built at
  store 21.
- yards and agents get eTIMS invoices, so they can claim the cost

Every size of every card clears the code's margin rule, prepaid periods
included: what BROKA keeps after VAT is at least 1.25× its cost at full use.
Shops come out at 1.28× (1,000 listings) to 1.76× (30); yards and agents at
4.8× or more.

**Before any store is charged:**

1. Remove the escrow claims from the storefront.
2. Add a "WhatsApp this shop" button.
3. Then ship "Zeno on your link" (2.6).

### 2.4 Boosts and ID checks

- **Boosts**
  - Priced by value, per 7 days: KES 149 (up to 50k), 299 (up to 300k),
    599 (up to 1.5M), 999 (above). 30 days costs 3×.
  - Open to every seller. A boost moves to another listing if the item sells.
  - Sold in a category only once it has at least 200 live listings and at
    least half of new listings get a buyer chat within 7 days, for 4 weeks
    running. Placement in an empty room is worth nothing; that is the
    complaint about Jiji: KES 2,500 paid for 23 views.
- **ID check**
  - Free for every seller (Didit: KES 39 a check, 500 free a month).
  - Required for listings worth KES 300,000 or more.
  - The badge reads **"ID checked"**, not "Verified".
  - On cars, land and houses it adds: "BROKA checked who this seller is, not
    the logbook or title. Search on NTSA / Ardhisasa before paying."
  - The rank lift goes to sellers who passed a real check. Existing paid
    badges are renamed or refunded.
  - Later: an optional "Search seen" badge for land at KES 999 once. A person
    matches an official search no older than 30 days to the ID-checked
    seller.

### 2.5 How the 3.49% comes back, without touching the money

- **Up-front fees track the commission.** An up-front fee equals the old
  commission when fee = 3.49% × price × the share of listings that sell
  through BROKA each month. At the nudged prices, the phone fee equals the
  commission if 14% of phones sell through BROKA each month, a car 4%, a plot
  3.6%. **Raise a category's price only toward that line, as measured**
  (2.6), and publish the number to sellers ("38% of phones listed on BROKA
  sold within 30 days"). That is a price rise sellers can't argue with.
- **Above KES 250,000 the commission was never collectable.** M-Pesa caps a
  payment at 250,000 and a day at 500,000; cars and land close through
  advocates and banks. Up-front fees there are new money, not a replacement.
- **Zeno credits are the commission's honest heir.** They are paid up front,
  but used up by buyer conversations, so income rises with demand, and so
  with sales.
- **Stores and dealers are where classifieds make their money** (Auto Trader
  80%, Jiji's packages).
- **An escrow referral is unverified.** Ask E-Confirm and the others for a
  share of fees on deals BROKA sends them. The partner pays, not the user.

### 2.6 What pricing depends on: build and fix, in order

1. **Deploy main to production.** The price × quantity fix isn't live.
2. **Honesty fixes (a day):**
   - storefront escrow copy
   - Pro pitch
   - no rank for unchecked badges
   - `plans.py` store comment
   - land and car safety advice: official search, logbook check, and advocates
     or banks instead of M-Pesa escrow for amounts over 250k
3. **Free buyer-waiting texts.**
4. **The sale record:**
   - "Did it sell? On BROKA / elsewhere / not sold" when a listing closes,
     and every 14 days
   - buyer confirmation
   - a weekly count per category of listings with a buyer chat within 7 days,
     and of confirmed sales

   Base price reviews on buyer-side numbers, not on what sellers report.
5. **Zeno on your link:**
   - every listing and store gets a web page that sellers share on WhatsApp
     and TikTok
   - buyers chat with Zeno after an SMS code, with no APK
   - Zeno answers availability from the still-for-sale tap, and price,
     delivery and condition from the listing
   - then, in month 2, it negotiates to the seller's private floor price

   This is the single best investment. It works with zero BROKA buyers
   because sellers bring their own, it is something Facebook's auto-reply
   doesn't do, and it is what Pro and Zeno credits sell. Land and property
   negotiation waits until a lawyer has checked the Estate Agents Act.
6. **Store billing, eTIMS invoices, the "For sale / To let" field, and plate
   or LR number capture.**

---

## 3. What it earns: honest ranges

- **Listing fees, same number of listings:** +0% to +40% over today. +40% if
  no seller leaves at the higher price, about +18% if some do, about 0% if
  sellers leave in proportion to the rise. The nudge is safe. It is not what
  grows BROKA.
- **Early income** at today's ~0.6 sign-ups a day, where 300 sellers is more
  than a year away:
  - Listing fees bring a few thousand shillings a month for the next few
    months.
  - 20 founding businesses would bring ~KES 18,000 a month at half price and
    ~36,000 at full price: 10 shops at 599, 6 yards and 4 agents at 2,999.
  - That is the realistic early income, and it is sold in person.
- **Costs:** ~KES 773 a month fixed. One paid car listing covers the bill. VAT
  (16%) starts at about KES 417,000 a month of turnover. ZetuPay takes 1.5% of
  each payment.

---

## 4. Next 30 days

| When | What |
|---|---|
| Day 1 | Deploy main (fees and premium still off) |
| Days 1-2 | Honesty fixes (2.6, item 2) |
| Days 2-3 | Buyer-waiting texts free for every seller |
| Days 3-6 | The sold tap, buyer confirmation, and the weekly numbers |
| From day 4 | "List before fees start, free until sold": post links daily in Nairobi buy-and-sell groups and on TikTok |
| Days 7-14 | In person: Luthuli and Moi Avenue phone shops, the Jamhuri Sunday bazaar, 2-3 letting agents. Sign 5 founding businesses, paid up front by till |
| Days 8-10 | Free ID checks, then `PREMIUM_ENABLED` on with the KES 99 cover pack |
| Days 8-27 | Zeno on your link |
| ~1 November | Listing fees on: the nudged bands, the guarantee, loopholes closed |
| Day 30 | Review against 150 live listings, 5 paying businesses, KES 10,000 collected, 10 confirmed sales |

**Rollback rule:** if new listings per week fall more than 40% for two weeks
after fees go on, or fewer than 10% of fee-eligible listings pay within
60 days, put that category back to free while Zeno on your link catches up.

---

## 5. Decisions (founder, 2026-10-06)

| # | Question | Decision | In the code? |
|---|---|---|---|
| 1 | The nudge | **The bands in 2.1** (+35-47% on everything), not the lighter option | **Yes**: `engine.VALUE_BANDS`, cap 15,000 |
| 2 | Lettings: a flat fee per vacancy (85 → 499 for a KES 30,000 let) | Agreed | Not yet: needs a "For sale / To let" field |
| 3 | "Until sold" for private car, land and house sellers | Agreed | Not yet: needs the still-for-sale tap and plate / LR binding |
| 4 | Store rate cards per trade, founding businesses at half price | **Agreed, with a change:** KES 599 covers 30 listings, and the owner picks any size | **Yes** (prices): `plans.STORE_RATE_CARDS`, `GET /pricing/store-plan`. Store billing is still to build |
| 5 | Premium: hold Pro until Zeno sells; KES 99 cover pack now | Agreed | Not yet |
| - | Fix the storefront's escrow claims | **Done** | Web storefront, app and the paying-safely advice |
| 6 | Optional, if supply stalls: one free goods listing under KES 300,000 per ID-checked seller (`FREE_LISTINGS_PER_SELLER=1`); the norm on Jiji, OLX and Avito | Held in reserve | Setting exists, off |

The rest of section 2 is agreed and is built in the order of 2.6.

---

## 6. What was considered and dropped

- **A "handshake fee" when a deal is agreed through Zeno.** The founder
  rejected it: nobody pays a fee after agreeing a deal off the app, and BROKA
  can't enforce it.
- **Store tiers by stock value (this proposal's first draft).** The reviews
  showed four problems:
  - The tiers tripled a real phone shop's bill: 15 phones went from 499 to
    1,499.
  - They had cliffs: the 16th phone cost 1,000 a month more.
  - They rested on a quantity the seller types.
  - A single plot was cheaper as a one-item "store" than as a listing.

  Replaced by counts per trade.
- **+66-88% on cars, land and houses (first draft).** That is not a nudge,
  and those are the categories with the longest sale times and the least
  proof. Replaced by the same +35-47% for everyone, plus "until sold".
- **Value-tiered cliffs, 12× rent for lettings, the KES 99 pack with a boost,
  and SMS inside paid plans.** The reviews showed each one could be gamed, or
  would quietly stop free sellers hearing from buyers.
- **Charging a private seller's first listing only when the first buyer
  arrives.** It is clever, and still up front, but it makes buyers wait while
  the seller decides to pay. Kept in reserve if supply stalls.
- **Display ads.** Kenya's ad rates are among the lowest in the world, and
  ads cheapen the trust pitch.

---

## Sources

Code and live numbers:

- `backend/api/domains/pricing/` (engine, costs, plans), run for every fee and
  margin above
- `LAUNCH_DISCOUNT_MODEL.md` (Railway bill)
- Railway `broka-api` deployment history and request counts, 2026-10-01 to 05
- Code findings: `negotiate.py:141` and `:1953-1980`,
  `buy_agent/actions.py:738`, `verify.py:255-260`, `workers.py:1155-1164`,
  `listings/paid.py:37-47`, `auctions/lifecycle.py:215`,
  `listings/price_rules.py`, `web/src/components/` (escrow copy)

Market (read via search extracts on 2026-10-05; the proxy blocked direct
reads, so treat single-source figures as indicative):

- **Jiji**
  - [Jiji FAQ: premium services](https://jiji.co.ke/faq/48)
  - [Jiji FAQ: posting limits](https://jiji.co.ke/faq/113)
  - [Jiji Pro Sales](https://jiji.co.ke/faq/144)
- **Classifieds and portals**
  - [Kai & Karo: sell your car](https://kaiandkaro.com/sell-your-car)
  - [BuyRentKenya: list privately](https://www.buyrentkenya.com/list-privately)
  - [Househunt](https://www.househuntkenya.com/faq/where-do-real-estate-agents-list-properties-with-no-fees-in-kenya)
  - [PigiaMe: sell online](https://www.pigiame.co.ke/sell-online)
- **Commission marketplaces**
  - [Jumia Kenya commissions](https://vendorhub.jumia.co.ke/commissions-copy/)
  - [Kilimall fees](https://helpcenter.kilimall.com/help-center/detail/2340?cid=1&aid=33)
- **Store builders**
  - [Lacesse Duka](https://lacesse.co.ke/duka/)
  - [Shopify in Kenya](https://truehost.co.ke/shopify-price-in-kenya/)
- **Rules and fees**
  - [Estate Agents (Remuneration) Rules 1987](https://new.kenyalaw.org/akn/ke/act/ln/1987/36/eng@2022-12-31)
  - [Escrow Kenya charges](https://escrowkenya.com/view/charges)
  - [E-Confirm terms](https://econfirm.co.ke/terms-and-conditions)
  - [M-Pesa limits](https://www.safaricom.co.ke/main-mpesa/m-pesa-for-you/tariffs-limits/consumer-tariffs-limits)
  - [Buy Goods tariff, Aug 2026](https://tech-ish.com/2026/08/01/mpesa-pochi-buy-goods-tariff-cuts-2026/)
- **Fraud and ID**
  - [TransUnion 2026 fraud trends](https://newsroom.transunionafrica.com/suspected-digital-fraud-in-kenya-falls-below-global-rate-in-2025-as-consumers-report-third-party-seller-scams-drove-the-most-losses)
  - [NCRC land-crime survey](https://www.crimeresearch.go.ke/wp-content/uploads/2022/06/Baseline-Survey-on-Land-Related-Crimes-in-Kenya-1.pdf)
  - [Didit Kenya ID](https://didit.me/solutions/countries/kenya/)
- **Cars**
  - [Jamhuri bazaar fees](https://www.businessdailyafrica.com/bd/lifestyle/motoring/kenya-s-open-air-car-market-revs-through-the-tough-economy-5060772)
  - [Car broker commissions](https://www.businessdailyafrica.com/bd/corporate/shipping-logistics/coast-car-dealers-clash-with-brokers-over-commissions-2256872)
- **History and benchmarks**
  - [OLX Kenya paid adverts](https://www.businessdailyafrica.com/bd/corporate/companies/olx-starts-paid-adverts-option-to-increase-income-2128196)
  - [OLX exit](https://www.the-star.co.ke/news/2018-02-07-olx-shutting-down-kenya-nigeria-outlets)
  - [Auto Trader FY26](https://www.marketscreener.com/news/earnings-flash-auto-l-autotrader-group-reports-fy26-revenue-gbp624-3m-ce7f5ad9d081f724)
  - [Carsales private ads](https://help.carsales.com.au/hc/en-gb/articles/203860479)
  - [OLX Poland paid electronics ads](https://spidersweb.pl/2018/07/olx-oplaty-elektronika.html)
  - [Facebook Marketplace AI replies](https://techcrunch.com/2026/03/12/facebook-marketplace-now-lets-meta-ai-respond-to-buyers-messages)
