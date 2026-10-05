# What a launch discount costs BROKA, and how many sellers it can carry

Written 2026-10-05 to settle the founding-seller offer (PRICING.md §2). Every
cost below is either measured on the live Railway project, a published
provider price, or a constant in `backend/api/domains/pricing/costs.py`.
Anything that is a guess says **assumption**. Figures in KES at
USD 1 = KES 129.5.

## The answer first

1. **The size of the free tier barely matters to survival.** A seller's
   free first listing costs BROKA about **KES 6.50 of real money** (AI,
   SMS, a free AI cover try). Fifty free sellers cost KES 325, a hundred
   KES 650. Both are less than one month of BROKA's fixed bill (KES 773).
2. **Every discount up to about 90% still makes money on a KES 70 fee.**
   Half price on a phone listing brings in KES 34.50 and costs about
   KES 6.50: +KES 28 a seller. Only 100% off loses money.
3. **What decides survival is how many sellers pay after their first
   listing.** BROKA breaks even at about **12 paid phone listing-months a
   month** today, about 18 once traffic grows. A free first listing tells
   you nothing about that; a half-price one does, because the seller has to
   pay.
4. So: **the first 50 sellers get their first listing free for 30 days;
   the next 150 get it at half price; everyone after pays in full. Only the
   first listing is discounted.** Why 50 and 150 is below - the cost side is
   fact, the shelf-filling side is judgement, and it says which is which.

"30 months" in the request is read as **30 days**: 90 days was called too
long, and 30 months is ten times longer.

## 1. What BROKA pays every month (fixed)

| Cost | Source | KES / month |
|---|---|---|
| Railway (API, PostgreSQL, admin panel) | Hobby plan, $5 a month including $5 of usage ([docs.railway.com/pricing/plans](https://docs.railway.com/pricing/plans)). Measured last 7 days: API avg 0.15 GB RAM, 0.002 vCPU; database 0.05 GB RAM, 0.12 GB disk; admin ~0.01 GB RAM; ~19 GB egress a month. At $10/GB-month RAM, $20/vCPU-month, $0.05/GB egress, $0.15/GB-month volume that is **~$3.10 of usage**, inside the $5 | **648** |
| Domain broka.co.ke | ~KES 1,500 a year (PRICING.md §1) | 125 |
| SMS, email, push, images, video calls | Mobitech pay-as-you-go; Resend free to 3,000 emails; FCM free; Cloudflare R2 free to 10 GB; Cloudflare TURN free to 1,000 GB | 0 fixed (per use below) |
| **Total today** | | **773** |

Assumptions: the account is on Hobby, not Pro ($20, KES 2,590) - check the
Railway billing page. Railway runs in `sfo` (California); that costs nothing
extra but adds latency for Kenyan users. The `zetupay-docs-fetch-temp`
service in the same project is a leftover and can be deleted.

As usage grows, RAM is what moves: at ~1,500 monthly users the API might
need ~0.5 GB and ~30 GB egress, about **$8 (KES 1,040)**, so fixed costs
rise to ~KES 1,165 (**assumption**, scaled from the idle measurement).

One-off costs not in the table: Mobitech sender ID KES 7,800 (Safaricom),
if not paid yet ([mobitechtechnologies.com/pricing](https://mobitechtechnologies.com/pricing)).
The app ships as an APK, so there is no Play Store or App Store fee.

## 2. What one seller and one listing cost (variable)

| Cost | Source | KES |
|---|---|---|
| Sign-up OTP by SMS | Mobitech KES 0.35 a message; ~1.5 messages per sign-up (**assumption**: one resend in two) | 0.53 per seller |
| Free AI cover try | 1 free try (`plans.FREE_TRIAL`) at KES 5.18 (`costs.AI_SHOWCASE_IMAGE`); 60% use it (**assumption**) | 3.11 per seller |
| Posting a listing (price help, description, scam check) | DeepSeek, `costs.AI_PER_NEW_LISTING` + `AI_LISTING_DESCRIPTION` | 0.29 per listing |
| Zeno negotiating with buyers for a month | 1.5 buyer threads × 14 messages × KES 0.12 (`costs.py`, Electronics; **assumption** until tokens are logged) | 2.59 per listing-month |
| Collecting the fee | ZetuPay 1.5% of each successful payment, no fixed fee ([pay.zetupay.co.ke/pricing](https://pay.zetupay.co.ke/pricing)) | 1.05 on KES 70 |

So:

- **A free first listing for 30 days costs KES 6.50** (0.53 + 3.11 + 0.29 + 2.59).
- **A paid phone listing (KES 20,000, fee KES 70) leaves KES 66** after
  ZetuPay and its own AI costs.

A side finding: ZetuPay's 1.5% costs KES 1.05 on a KES 70 fee, where
Safaricom's own paybill tariff charges nothing up to KES 100 (PRICING.md §1).
Most listing fees are under KES 100, so Daraja is cheaper for them, if you
have a paybill.

## 3. What each discount level earns or loses on a first phone listing

| Discount | Seller pays | BROKA keeps after costs |
|---|---|---|
| 100% | 0 | **-6.50** |
| 80% | 14 | +7.30 |
| 60% | 28 | +21.10 |
| 50% | 35 | +28.00 |
| 40% | 42 | +34.90 |
| 20% | 56 | +48.70 |
| 0% | 70 | +62.70 |

The fee never goes under the listing's cost floor (KES 11 here), so a
discount between 85% and 99% would charge KES 11 anyway.

## 4. How many free sellers BROKA can carry

| Free first listings | Real cost, once | Months of fixed costs it equals |
|---|---|---|
| 20 | 130 | 0.2 |
| 50 | 325 | 0.4 |
| 100 | 650 | 0.8 |
| 200 | 1,300 | 1.7 |
| 500 | 3,250 | 4.2 |

Cash is not what limits the free tier: even 500 free sellers cost less than
a sender ID. The real cost is the fee those sellers would have paid - KES 70
each, KES 3,500 for 50 - and that only counts if they would have paid at all
on a platform with no buyers yet, which most would not.

## 5. Break-even

Fixed costs ÷ what a paid listing leaves:

- Today: 773 ÷ 66 = **12 paid phone listing-months a month**.
- At ~1,500 users: 1,165 ÷ 66 = **18**.

What that needs, depending on how many sellers keep paying after their first
listing (**assumption** - nobody knows this yet; it is what the launch
will measure), with each paying seller keeping 1.5 listings up:

| Sellers who keep paying | Sellers needed to break even today | At ~1,500 users |
|---|---|---|
| 10% | 80 | 120 |
| 20% | 40 | 60 |
| 30% | 27 | 40 |

## 6. Why 50 free and 150 at half price

- **Why not 0 free:** the first sellers list onto an app with no buyers.
  Charging them for that buys almost nothing (a few KES 70 fees) and costs
  the listings that make buyers stay. Free costs KES 6.50 a seller.
- **Why not more than ~50 free (judgement):** a free listing never shows
  whether sellers will pay, and §5 shows that's the number that decides
  whether BROKA survives. Fifty listings is about ten each in the five
  categories most listings land in (phones, electronics, fashion,
  furniture, cars) - enough that a first buyer finds something. Twenty
  would be about four each. Past 50, each extra free seller costs a fee
  that, by then, someone might pay.
- **Why half price for the next 150:** each one is +KES 28 instead of
  -6.50, and every payment is proof that sellers will pay to list. Two
  hundred founding sellers is also the range where §5 says BROKA breaks
  even at a 10-20% paying rate. Half price, rather than 80% off, is chosen
  because 80% off (KES 14) is barely over the cost floor and teaches
  sellers a price BROKA can't keep.
- **Why only the first listing, for 30 days:** a dealer with 30 listings
  would otherwise get all of them free. A month is enough for most phone
  and electronics listings to sell (`categories.py` expects ~14 days).
- **Total cost of the offer:** 50 × 6.50 = **KES 325 of real money**, and
  the half-price band *earns* ~150 × 28 = KES 4,200 if all 150 pay.

## 7. What would change these numbers

- **Free AI cover tries** are the biggest per-seller cost (KES 3.11 of the
  6.50). If cash is tight, `plans.FREE_TRIAL` can drop them.
- **The Railway plan.** On Pro (KES 2,590 a month) break-even rises to
  ~41 paid listings a month.
- **Real conversion.** Once the first 50 have had their month, the share
  who paid for a second listing replaces the 10/20/30% guesses in §5. Change
  `FOUNDING_SELLER_TIERS` then, without a release.
- **Fees on cheaper items.** A KES 1,500 dress pays the KES 10 floor; most
  of BROKA's income will come from phones, electronics, cars and land.
