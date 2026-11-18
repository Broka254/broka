# Store orders

A buyer sends a BROKA store an **order request** from the web storefront, on
any phone, tablet or computer, with no app. The store accepts it or proposes
changes, the buyer confirms the final details, the store prepares and hands it
over, and the buyer confirms they received it.

**BROKA never receives, holds, verifies or releases money for store orders.**
The buyer pays the store directly, or through an independent escrow provider
the buyer chooses from BROKA's escrow directory. BROKA records what the buyer
and the store *report* about paying, labelled as their reports. Nothing in the
code, the API or any screen says a payment was verified.

Switched by `STORE_ORDERS_ENABLED`: on in development and test, **off in
production unless set**. Off, every order endpoint answers `409 ORDERS_OFF`,
the storefront keeps its handoff to the app, and the app shows no Orders tab
and no stock controls.

| Part | Where |
|---|---|
| Backend | `backend/api/domains/store_orders/` (`lifecycle.py`, `pricing.py`, `stock.py`, `service.py`, `notify.py`, `analytics.py`, `messages.py`, `router.py`), `backend/api/models/store_order.py` |
| Web | `web/src/lib/session.ts` (server), `web/src/app/api/stores/{session,orders,conversations,[id]/orders,[id]/enquiries,[id]/cart-events}`, `web/src/components/{WebCheckout,OrderView,OrdersList,EnquiryThread,MessagingWorkspace,ConversationList,SignInPanel}.tsx`, `web/src/lib/{conversations,messages}.ts`, pages `/store/orders`, `/store/orders/<id>`, `/store/<name>/messages`, `/store/account/messages`, `/store/legal/<doc>` |
| App | `flutter_app/lib/features/stores/presentation/{store_orders_tab,store_order_screen}.dart`, `widgets/store_stock_sheet.dart`, `domain/models/store_order.dart` |
| Tests | `backend/tests/test_store_order_rules.py`, `test_store_orders.py`, `test_store_orders_migration.py`, `test_deal_payout_stock.py`; `web/src/**/*{orders,checkout,stores-api,legal,availability}*.test.*`; `flutter_app/test/store_orders_test.dart` |

---

## 1. The lifecycle

One validated state machine (`lifecycle.py`). Every change runs in one
transaction, under the order's row lock, re-checking the status after taking
the lock, and writes a `store_order_events` row.

```
submitted ──accept──▶ awaiting_buyer_confirmation ──confirm──▶ confirmed
    │  └──propose──▶ seller_proposed_changes ──confirm──▶ confirmed
    │                       └──reject_proposal──▶ submitted
    ├──decline──▶ declined
    ├──(clock)──▶ expired
confirmed ──start_preparing──▶ preparing
confirmed/preparing ──mark_ready──▶ ready_for_pickup      (collection)
confirmed/preparing ──dispatch──▶ dispatched              (delivery)
ready_for_pickup/dispatched ──mark_delivered──▶ delivered
ready_for_pickup/dispatched/delivered ──confirm_received──▶ completed
```

| Rule | Detail |
|---|---|
| Who completes | Only the buyer ("I received it"). The store can report delivery, never completion. |
| Accept vs propose | `accept` keeps every quantity and price. `propose` changes quantities (0 = can't supply), prices or handover; it lands in `seller_proposed_changes` only when something material changed, otherwise it counts as an acceptance. |
| Confirming | The buyer confirms one exact offer: `POST /orders/{id}/confirm {revision}`. A stale revision is `409 ORDER_REVISION_STALE`. |
| Cancelling | The buyer may cancel until the store starts preparing (reason optional). The store may cancel from `confirmed` to `dispatched`, and must give a reason (`ORDER_REASON_REQUIRED`). Neither can once it is reported delivered. |
| Declining | Store only, with a reason the buyer sees. |
| Expiry | A request the store hasn't answered expires after `STORE_ORDER_SELLER_RESPONSE_HOURS` (72). An offer the buyer hasn't confirmed lapses after `STORE_ORDER_RESERVATION_HOURS` (48). The 5-minute sweep (`task_store_order_sweep`) expires them; opening a lapsed order, or acting on it, expires it on the spot. Each expiry is its own transaction under the order's lock, re-checked, so two replicas or a buyer acting at the same moment expire it once. A pass takes the 200 most overdue; the rest wait for the next pass. An expiry that fails rolls back whole (the order keeps its units) and the next pass tries it again. A pass that can't take its lease is skipped rather than ending the sweep. |
| Problems | The buyer can report a problem from handover onwards, including after completion. It notifies the store and does not move the order. |

Statuses: `submitted`, `seller_proposed_changes`, `awaiting_buyer_confirmation`,
`confirmed`, `preparing`, `ready_for_pickup`, `dispatched`, `delivered`,
`completed`, `declined`, `cancelled`, `expired`. Each response carries
`allowed_actions` for the caller; the clients show only those, and the API
checks again.

## 2. Submitting

`POST /orders` with `X-Idempotency-Key` (required):

- **Idempotent**: unique on (buyer, key). The same key with the same request
  returns the first order (`replayed: true`); the same key with a different
  request is `409 IDEMPOTENCY_KEY_REUSED`, never merged.
- **One store per order**, products only from that store's live listings.
- **Prices from the server.** The body names listings and quantities; a price,
  total or status in it is a 422 (the model forbids extra fields). Amounts are
  integer cents (`*_minor`, BIGINT), converted with `Decimal(str(price))`.
- Refused: the store's own owner (`ORDER_OWN_STORE`), a paused store
  (`STORE_ORDERS_PAUSED`), a store offline for billing (`STORE_NOT_OPEN`), more
  than `STORE_ORDER_MAX_OPEN_PER_STORE` (5) open orders with one store
  (`ORDER_TOO_MANY_OPEN`), a quantity over what can be asked for
  (`ORDER_ITEM_QUANTITY`, `ORDER_ITEM_OUT_OF_STOCK`).
- Rate limits: 10 submissions per buyer and 40 per address per 10 minutes;
  60 actions per user per minute.
- Attribution: the storefront link's `?via=` and campaign token `?c=` are
  recorded on the order; an unknown campaign token is ignored.

## 3. Stock

**Every product's units are counted**, by one count for both ways a store
product sells: store orders and chat deals (`EscrowService.finalize_deal`).
The count is `backend/api/domains/listings/inventory.py`:

```
available = total - reserved - in deals - sold through orders   (never below 0)
```

- `total`: the listing's quantity. Counted stock (`listings.stock_tracked`)
  uses it exactly. Otherwise it is the stated quantity, NULL or 0 reading as 1.
- `reserved`: `listings.stock_reserved`, what accepted orders hold.
- `in deals`: the units of chat deals that hold stock, by the chat rule
  (`listings/stock.units_taken`): while buyers pay through BROKA, every deal
  from agreement until refunded or cancelled, paid-out ones included; with
  payments off, paid-out ones only.
- `sold through orders`: units store orders handed over
  (`store_order_items.deducted_quantity`). Only a stated quantity subtracts
  them, because counted stock had them taken off `quantity` at handover.

Every path that takes units locks the listing row first (`inventory.lock`,
`SELECT ... FOR UPDATE`, in id order), counts, then writes, in one
transaction: `finalize_deal`, an order's acceptance or proposal, the stock
controls, and a chat deal's payout. Two requests from the two channels for the
last unit run one after the other, and the second is refused. Before this,
`finalize_deal` counted chat deals only, an acceptance counted chat deals
before locking anything, and a product whose seller didn't count it reserved
nothing.

A payout is when a deal's units count as sold, and with payments off the first
moment they count at all. All six payout paths (the buyer's release, the
legacy `/escrow` route, the timer sweep, a dispute decided for the seller, the
chat's "all good", and E-Confirm reporting every payment paid out) lock the
deal, then its listing, count, move the deal and settle the listing's status in
one transaction (`inventory.lock_for_deal_move`, `settle_deal_move`). They used
to commit without the listing's lock, so an order accepted at the same moment
counted the payout's unit as free. The buyer's own release took no deal lock
either, so two taps released a deal twice. No provider, SMS or push call is
made while those locks are held. Refunds take no listing lock: they only give
units back, and two of them make the M-Pesa refund call inside their
transaction.

| Moment | Effect |
|---|---|
| Store accepts or proposes | Under the listing lock, counts and reserves the offered units (one conditional `UPDATE` as a second check), for every product. `ORDER_STOCK_SHORT` when chat deals and other orders left fewer. |
| Chat deal agreed | Under the same lock, refused when orders and other deals left fewer ("This listing is sold out." / "Only N left"). The deal's units are counted from its row; `quantity` is not touched. |
| Declined, cancelled, rejected proposal, expired | Releases what the order held. |
| Delivered or completed (whichever comes first) | Moves the units from reserved to sold, once: counted stock takes them off `quantity`; a stated quantity counts them from the order line. |
| Chat deal paid out | Under the listing lock, after the deal's: counted, its units marked sold, and the listing's status settled at once. Never refused for stock, since the buyer has paid and has the goods. With payments off, if an order was accepted for those units while the paid deal held none, the payout still goes ahead and writes the conflict down: an audit row `deal_stock_over_allocated` on the listing and a reconciliation alert, for a person to settle with the store. |
| Chat deal refunded or cancelled | Its units count again (the chat rule, unchanged). The 5-minute stock sweep puts the listing back on sale. |
| Owner edits stock | `PATCH /stores/{id}/manage/listings/{listing_id}/stock`, below. |

**Counted or not** is how the seller writes the stock down. It no longer
decides whether orders take units.

- **Counted** (`stock_tracked`): the seller keeps an on-hand number and
  restocks it. On hand is `quantity` less the units chat deals sold, since a
  chat sale never changes `quantity`, so setting on hand to N stores
  `N + sold through chat deals`. With nothing available the product stays
  listed as "Out of stock".
- **Not counted** (every product until its owner chooses): the stated
  quantity is everything the listing has, and every unit sold through either
  channel counts against it. With every unit promised the listing goes
  `pending`, and with every unit sold it goes `completed`, the way chat deals
  always moved it. An order's acceptance, release and handover set this at
  once (`inventory.settle_status`), and the 5-minute stock sweep counts
  orders as well as deals.

The stock controls, the product list, the seller's order lines, the product
page and every store product card show figures from the same count:
`available_quantity` (what an order or a deal may take now, for every store
product), `stock_reserved`, `stock_committed_to_deals` (chat deals not yet
paid out), `stock_sold_through_deals`, and `stock_on_hand` (counted stock
only).

The stock controls:

- `quantity`: on hand while counted. Not counted, the stated quantity, stored
  as given (at least 1). Neither can go below what is promised
  (`STOCK_BELOW_RESERVED`, with `reserved`, `in_deals`, `sold`, `minimum`):
  accepted orders plus chat deals under way, and for a stated quantity also
  everything already sold.
- Counting on or off changes how the units are written down, not how many are
  left. Starting from a stated quantity, on hand is what neither channel sold.
  Stopping, the stated quantity becomes on hand plus everything sold.
  Reservations stay where they are in both directions, so orders under way
  keep their units. Stopping with nothing left and no quantity given is
  refused (`STOCK_QUANTITY_REQUIRED`), since a stated 0 reads as one.

`temporarily_unavailable` pauses new orders for one product: it stays visible,
labelled, not orderable. It doesn't stop chat deals.

## 4. Payment records

Kept apart from the lifecycle: a payment record never changes an order's
status.

- **Arrangement** (buyer, `POST /orders/{id}/payment-arrangement`):
  `direct_to_seller`, or `independent_escrow` with a `provider_id` from the
  escrow directory. The provider's name and official address are copied from
  the directory, never from the request. It locks once any report exists.
- **Reports** (`POST /orders/{id}/payment-reports`), one of each kind per
  order, from the right side only:
  - "Buyer reported payment sent"
  - "Seller confirmed receipt" (allowed without a chosen arrangement: recorded as direct)
  - "Buyer reported escrow initiated"
  - "Seller reported escrow release received"
- The summary says "Awaiting external confirmation" until the matching
  confirmation exists. Every report and summary carries `verified: false`, and
  every payment block carries the notice: *BROKA does not receive, hold, verify
  or release payments for store orders. These are reports made by the buyer or
  the store, not confirmations from BROKA or from any payment provider.*
- An escrow provider is always shown as independent of BROKA, with its own
  notice, and its link opens its official site in a new tab
  (`rel="noopener noreferrer nofollow"`). No payment code exists anywhere in
  this feature: no STK push, wallet, payout or refund.

## 5. Notifications

`store_order_notifications` is both the outbox and the in-app updates feed
(`GET /orders/notifications`, `/unread-count`, `POST /orders/notifications/read`).

1. Rows are written in the same transaction as the change they announce,
   unique per (event, recipient).
2. After the commit, each row is **claimed** with a conditional `UPDATE` before
   its push is sent, so a request and a sweep on another replica can't both
   send it. No transaction is open during the FCM call.
3. A transient failure leaves it `pending`; the 5-minute sweep retries up to 5
   times within 24 hours. No phone signed in: `no_device`, not retried.

Push data: `{type: "store_order", order_id, status, event, role,
screen: "store_order", title, body}` on the `broka_updates` channel, tagged
`store_order:<order_id>` so the latest update replaces the one before. The app
opens `/store-order` on tap and draws the update itself while in front.

A buyer who only uses the web gets no push: they see updates on the order page
(it re-reads every 30 seconds while open) and in the updates feed.

## 6. Analytics

`GET /stores/{id}/insights` gains an `orders` block (`analytics.py`):

| Figure | Definition |
|---|---|
| Requests | Order requests buyers sent in the period. **A request is not a sale.** |
| Accepted | Requests the store first answered in the period (accepted or with changes). |
| Confirmed | Orders whose final details the buyer confirmed in the period. |
| Completed | Orders the buyer confirmed receiving in the period. |
| Cart additions | A product put in a cart, once per visitor and product per half hour. Interest, not an order. |
| Completed value | Agreed totals of completed orders. **Not revenue**: payment is outside BROKA and unverified. |

Rates follow the **cohort of requests made in the period**, each returned with
its numerator and denominator (`3 of 8`), never as a bare percentage:
view→request (per 100 product views), request→answered, answered→confirmed,
confirmed→completed, and completion rate. Recent cohorts are still in
progress, and the definitions say so. Event counts use when the event happened.

Marketing Studio counts the order requests, confirmations and completions whose
buyer came through a campaign's link (`StoreOrder.campaign_id`), one per order.

## 7. Web storefront

Shown only when the store payload has `orders_enabled: true`; otherwise every
page keeps the app handoff (the production default).

- **Sign-in by SMS code**, through `POST /auth/otp/sign-in/{request,verify,register}`.
  An existing account is signed in; a new number gets a passwordless buyer
  account after a name and the same legal declarations as the app
  (`OtpPurpose.sign_in` codes can't register or reset a password, and the
  other purposes' codes can't sign in). The Terms and Privacy text shown is
  the app's own (`web/src/lib/legal-text.ts`, checked against
  `flutter_app/assets/legal/` by `legal.test.ts`).
- **Session**: the storefront's server keeps the tokens in httpOnly,
  SameSite=Lax cookies (`broka_at`, `broka_rt`, `broka_pv`), Path
  `/api/stores`, Secure in production. Page scripts never see a token. Calls
  that change anything need `X-Broka-Web: 1` and are refused when
  `Sec-Fetch-Site` is cross-site. An expired access token is renewed once with
  the refresh token.
- **Checkout** sends listings and quantities, handover and contact; one
  idempotency key per attempt, kept in the tab, so a double tap or a retry
  returns the same order. A refusal names the product it is about.
- **Order page** (`/store/orders/<id>`): status, the store's changes in words,
  deadline, actions behind confirmations, payment choice (direct or a listed
  independent provider) and reports, history, and the store it is with -
  its page, its messages, each product's page. **Orders list**
  (`/store/orders`), every store's orders, each naming its store. Both wear
  the buyer's account header (`AccountHeader.tsx`), not a store's. Never
  indexed.
- **Messages** (`/store/<name>/messages`, `?product=`): the same conversation
  the app shows, read from the existing negotiate history endpoints (no Zeno
  notes, no media addresses) and written through the rate-limited
  `POST /stores/{id}/enquiries` (12 per user, 60 per address, per 10 minutes).
  The buyer's own messages carry back the `client_msg_id` they were sent
  with, so a message shown as "Sending..." is replaced by its stored copy
  rather than drawn twice, and a retry is the same message.
- **Conversations** (`GET /api/stores/conversations?user=<id>`, read-only):
  the buyer's side of `GET /negotiate/inbox/{user_id}`, cut down to what a
  store page can open - store threads, and product threads whose listing
  belongs to a store with web messages. The inbox names a product thread's
  listing, not its store, so each listing and store is looked up through
  the cached public reads (at most 40 threads, 6 lookups at a time). Shown
  beside the open conversation on a wide screen, and on the account's
  Messages page (`/store/account/messages`; "account" is a reserved link
  name). No unread counts: the website marks nothing read (`mark-read` would
  also send the seller "seen" receipts), so they would never go down.
- Product pages say "Out of stock" (counted stock, none left) or "not taking
  orders for this product for now" (paused), separately from "no longer
  available" (sold, removed, or every unit of a stated quantity promised).
  Cards and the cart cap use `available_quantity`, the shared count, for
  every store product.
- No "install the Android app" message on iPhone, iPad or desktop when orders
  are on: everything happens on the web.

## 8. App

- **My Store → Orders** (before Settings, so Products and Marketing keep their
  indices): groups To do / Waiting on the buyer / Ready or on the way /
  Completed / Declined, cancelled or expired, with counts.
- **Order screen** (`StoreOrderScreen`, also `/store-order` from a push): the
  actions in `allowed_actions`, each with a confirmation; accept with an
  optional delivery charge; a proposal editor; decline and cancel with a
  reason; preparing, ready, dispatched, delivered; payment lines with who
  reported them and "not verified by BROKA"; "I received the payment" as the
  seller's report. A buyer who opens their order in the app gets their own
  actions and chooses the payment arrangement on the web page.
- **Products**: "Stock and availability" (count it, units on hand, pause new
  orders; not counted, what can be ordered now), and a stock line on each
  counted row. The order screen shows each line's stock, counted or not.
  **Settings**: "Taking new orders",
  with the note buyers see. **Insights**: an orders card. **Marketing
  Studio**: order counts per campaign.

## 9. API

| Method and path | Who |
|---|---|
| `POST /orders` | buyer |
| `GET /orders`, `GET /orders/{id}` | buyer (own) or the store's owner |
| `POST /orders/{id}/accept`, `/propose`, `/decline`, `/preparing`, `/ready`, `/dispatch`, `/delivered` | store owner |
| `POST /orders/{id}/confirm`, `/reject-proposal`, `/received`, `/problem`, `/payment-arrangement` | buyer |
| `POST /orders/{id}/cancel`, `/payment-reports` | either, by their own rules |
| `GET /orders/notifications`, `/notifications/unread-count`, `POST /orders/notifications/read` | the recipient |
| `GET /stores/{id}/orders?group=`, `GET /stores/{id}/orders/summary` | store owner |
| `PATCH /stores/{id}/manage/listings/{listing_id}/stock` | store owner |
| `PATCH /stores/{id}` with `accepting_orders`, `orders_pause_note` | store owner |
| `POST /stores/{id}/enquiries`, `POST /stores/{id}/cart-events` | signed-in buyer; anyone (counted) |
| `GET /auth/legal/current`, `POST /auth/otp/sign-in/request`, `/verify`, `/register` | public |

Errors are `{"detail": {"code", "message", ...}}` with an `X-Error-Code`
header. Order codes: `ORDERS_OFF`, `IDEMPOTENCY_KEY_REQUIRED`,
`IDEMPOTENCY_KEY_REUSED`, `ORDER_ITEM_UNAVAILABLE`, `ORDER_ITEM_OUT_OF_STOCK`,
`ORDER_ITEM_QUANTITY`, `ORDER_STOCK_SHORT`, `ORDER_STATE_CONFLICT`,
`ORDER_ACTION_FORBIDDEN`, `ORDER_FULFILMENT_MISMATCH`, `ORDER_REVISION_STALE`,
`ORDER_EXPIRED`, `ORDER_CHANGED`, `ORDER_REASON_REQUIRED`, `ORDER_OWN_STORE`,
`ORDER_TOO_MANY_OPEN`, `STORE_ORDERS_PAUSED`, `STORE_NOT_OPEN`,
`PAYMENT_PROVIDER_UNKNOWN`, `PAYMENT_ARRANGEMENT_LOCKED`,
`PAYMENT_ALREADY_REPORTED`, `PAYMENT_REPORT_TOO_EARLY`. Stock codes:
`STOCK_BELOW_RESERVED`, `STOCK_QUANTITY_REQUIRED`, `STOCK_QUANTITY_INVALID`.

## 10. Configuration and migration

| Setting | Default |
|---|---|
| `STORE_ORDERS_ENABLED` | unset: on outside production, off in production. `sync: false` in `render.yaml`, so the Render→Railway sync doesn't copy it. |
| `STORE_ORDER_SELLER_RESPONSE_HOURS` | 72 |
| `STORE_ORDER_RESERVATION_HOURS` | 48 |
| `STORE_ORDER_MAX_OPEN_PER_STORE` | 5 |

**Schema revision 19**, additive, applied by `python -m api.migrate` (the
release step; CI runs it twice on PostgreSQL 16):

- new tables `store_orders`, `store_order_items`, `store_order_events`,
  `store_order_payments`, `store_order_payment_reports`,
  `store_order_notifications`;
- `listings.stock_tracked` (false), `stock_reserved` (0),
  `temporarily_unavailable` (false); `stores.accepting_orders` (true),
  `orders_pause_note`;
- `otppurpose` gains `sign_in` (a PostgreSQL `DO` block; a no-op elsewhere).

Every existing listing stays untracked and on sale, and every store keeps
taking orders, until its owner changes them.

The shared stock count (§3) needs no schema change: it reads
`stock_reserved` and `store_order_items.deducted_quantity`, both from revision
19. Orders accepted before it on a product its seller didn't count hold no
units; they finish as they were. Production has never had store orders
switched on, so that only concerns development and test databases.

To switch on in production: set `STORE_ORDERS_ENABLED=true` on the API after
the release step has migrated to revision 19. The web storefront needs no
setting of its own; it follows the store payload.

## 11. Trying it by hand

On a development API (`STORE_ORDERS_ENABLED` on by default):

1. In the app, open a store and add a product. Optionally, in My Store →
   Products → the product → Stock and availability, count its stock (e.g. 3).
2. On another phone or a desktop browser, open `broka.co.ke/store/<name>`, add
   it to the cart and open the cart. Sign in with an SMS code (a test API
   shows the code on screen), create the buyer account, choose delivery or
   collection, and send the order request.
3. The seller gets a push; My Store → Orders → To do shows it. Open it,
   accept with a delivery charge, or propose a change.
4. The buyer's order page updates within 30 seconds. Confirm it (or reject the
   changes), choose how to pay and report the payment.
5. The seller starts preparing, dispatches (or marks it ready for
   collection), records "I received the payment" if paid directly, and reports
   it delivered.
6. The buyer confirms receipt: the order is completed, its units are sold,
   and My Store's insights count one request and one completion.
7. Try the edges: a double tap on "Send order request" (one order), a second
   buyer for the last unit (`ORDER_STOCK_SHORT`), a chat deal for a unit an
   accepted order holds ("This listing is sold out."), pausing new orders in
   Settings (the cart says so), and letting an offer lapse (units released).

## 12. Known limits

- An order past its deadline holds its units until it is marked expired: by
  the next 5-minute sweep (200 per pass, most overdue first), or at once when
  someone opens it or acts on it. A sweep pass also runs once at start-up.
- With payments off, a deal paid before payments were switched off holds no
  units until it is paid out (the chat rule, `listings/stock.deals_hold_stock`).
  Its payout now counts under the listing lock, so it can no longer slip past
  an acceptance. But an order may still be accepted for those units while the
  paid deal holds none. The payout then goes ahead and records the conflict
  (`deal_stock_over_allocated`) for a person to settle. Preventing it means
  counting paid deals while payments are off, which is a business decision.
- Pausing a product (`temporarily_unavailable`) stops new orders, not chat
  deals.
- Web-only buyers get no push notifications (the page and the feed show
  updates).
- The app's own cart still hands each product to its deal room; in-app buyers
  order through the web storefront.
- Terms §7 still says "Where BROKA offers escrow, the buyer's payment is held
  by our licensed..." That sentence is about deal escrow, not store orders,
  and the escrow directory store-order buyers choose from lists the same
  company. A proposed wording, and the versioning steps to apply it, is in
  `LEGAL_STORE_ORDERS_PROPOSAL.md` for legal review. The Terms are unchanged
  (revision `2026-10-12`) until it is approved; store orders should not go
  live in production before then.
