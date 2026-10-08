# Paying with escrow services, and no auctions for launch (2026-10-08)

Raised by the owner: no escrow provider's API can carry BROKA's payments or
its auctions end to end, so for launch there is no in-built escrow and no
auctions - kept in the code, out of the user's sight. Kenya's escrow
services take their place, impossible to miss, and Zeno walks people
through them step by step.

**Escrow services** (`api/domains/pricing/safe_payment.py`,
`GET /pricing/safe-payment`). E-Confirm, Escrow Kenya, Kenya Escrow,
Lipasafe and Shikilia, each with how a buyer pays in, its fees and limits
*as it publishes them* (or "check on its site" where it publishes none),
how a deal starts, how the money is released and paid out, and disputes.
TrustPay, ExWadda and JointPesa were left out: too little published to
confirm they operate. Escrow Kenya and Kenya Escrow are two companies, and
each entry says so. With them, the rules a fake-escrow scam needs broken:
open the service yourself, never from a link the other side sends; buyers
pay the service, never the seller; sellers trust the service, never a
screenshot or an SMS.

**Loud in the app** (`features/safe_payment/`). A Pay with escrow screen
(`/escrow-services`: what escrow is, the rules, every service with its fees
and "Zeno, guide me"), and a glowing callout on every listing, in both deal
chats (sellers: "Get paid with escrow"), the store cart, the Menu and How
BROKA works, plus a pill on Home's feed heading - on the heading's own row,
so the feed still starts in the top half. Every pay button opens the escrow
sheet, which leads with "Let Zeno guide me". The web store shows the same
services on the cart, product and store pages (`web/src/components/
EscrowBox.tsx`); a test fails if its list drifts from the server's.

**Zeno's walkthrough, as a conversation**
(`api/domains/zeno_assistant/escrow_walkthrough.py`). "Help me pay with
escrow" (Zeno's first opener now) or "walk me through paying with
Shikilia": Zeno asks whether you are buying or selling and which service,
then gives one step at a time - "Step 3 of 7 · Buying with E-Confirm" -
with replies to tap ("Done - what's next?", "Repeat this step", "Back") and
an Open button for the service's own site. No model call; where the user is
comes from Zeno's own last step in the transcript. A question in the middle
goes to the model with that step and the service's published facts, and
the reply brings the way back. The model's own escrow guide starts the
walkthrough; the negotiation broker is told to offer it once a price is
agreed, and never to recommend any other escrow service. Zeno's welcome
says it helps with paying. English only for now, like the guides.

**Auctions off** (`AUCTIONS_ENABLED`, default off; `api/domains/auctions/
paused.py`). Creating, changing or bidding on one answers 409
`AUCTIONS_OFF` with a message older builds show; no feed, search, store or
the Auction House lists one (`listings/paid.live_clause` - with `IS NULL`
kept, or every untyped legacy listing would have vanished); plans stop
selling them and `/premium/me` shows none left; no "ending soon" reminder.
An auction opened by its link still reads. The app hides the rail tile,
the sell wizard's choice (a saved auction draft posts as a direct sale)
and the plan allowance behind `kAuctionsEnabled`
(`--dart-define=AUCTIONS_ENABLED=true` brings them back).

**How BROKA works**, rewritten: buying and selling step by step, paying
with escrow, what Zeno does, then the seller's numbers. Fixed on the way:
it described BROKA's own escrow ("BROKA holds it") until the server
answered, and for good when it couldn't be reached; it now assumes the
launch setup until told otherwise. It said there was "no featured
placement and no paid badge" - boosts and the Verified badge are both
sold - and the completion rate now says why it isn't moving.

**Weak spots fixed while here.**
- The Verified badge was sold with "priority search placement", "appear
  higher in search results", a verified-seller filter, a featured-seller
  section, a "fraud-protection guarantee" and "40% more trust". None
  exists: nothing in the listing order reads the badge, and BROKA holds no
  money to guarantee. A seller who pays for an unkept promise is owed a
  refund. The tiers now say what a badge does (`verification_screen.dart`,
  `routers/verify.py`).
- A question passed to Zeno from another screen (`initialQuery`) was
  dropped unless it was the Buying Agent's or a listing's.
- "Payment receipts" in the Menu listed receipts of BROKA's own escrow,
  which nobody can make while it is paused; it shows only with payments on.

Noticed, not changed: the store cart's per-product deal rooms can't take a
whole cart in one escrow payment (one escrow deal per product); voice mode
counts a plain command as a voice request; Swahili users get the
walkthrough in English.

# Shop by category, by type of item, and by brand (2026-10-08)

Raised by the owner: a type of item had nowhere of its own. Phones were one
chip among thirteen in the Electronics Zone, so there was no way to look at
phones by brand, and a phone seller competed with every laptop and charger.
The website's category pages (`broka-website`) were the reference: photo
cards for categories and types, a page per type, its brands to filter by.

**Home's category rail is photo cards** (`home_screen.dart`,
`features/categories/presentation/widgets/category_art_card.dart`): the
website's own pictures, bundled as 640px WebP under
`flutter_app/assets/category_art/` (about 5 MB, every category and all 177
types). "Shop by category · See all" opens every category as a grid.
Trending, Auctions, Traders and Stores stay at the end of the same row. The
feed still starts in the top half of the screen.

**A category's types of item are cards, and each type is a screen of its
own** (`subcategory_screen.dart`). The Zone leads with the category's
picture and its types ("See all" lays them out), with the whole category's
listings under them. A type's screen leads with its brands as one-tap
filters (makes, for vehicles; a type without brands leads with its first
list of choices, like a title deed), and its filter sheet holds that type's
own details. Which picture belongs to which type is in
`subcategory_visual.dart`, keyed by parent and name ("Accessories" is in
three categories). `category_visual_test.dart` reads `seed.py` and fails if
a type has no picture or a picture isn't bundled.

**Brands are a list, not a box** (backend `categories/seed.py`
`BRAND_SUGGESTIONS`). Every brand or make field a type's sellers fill in now
carries the brands Kenyans list most, served as that field's `options`. It
stays a text field, so older app builds keep the box they had. The seed
brings a database seeded before the lists up to date on every start. That is
the one place it changes rows that already exist, and it never touches a
closed `select` list. In the sell wizard the brand comes first in Details,
one tap per brand, with Other for one that isn't listed.

**A typed brand is filed under its listed spelling** (`listings/
validation.py` `canonical_suggestion`, applied in `create_listing`).
"samsung", "Samsung Galaxy A54" and "iPhone 13" were three brands to an
exact-match filter, so the Samsung and Apple filters missed them. Now
they're "Samsung", "Samsung" and "Apple", whoever sends them (an old build, a
seller's Other, Zeno). The longest brand wins ("Mitsubishi Fuso Canter" is
Mitsubishi Fuso), and an alias only applies where its brand is offered ("mi"
is Xiaomi among phones and nothing among cars). A brand BROKA doesn't list
is kept as typed. Listings created before today keep the brand they were
saved with.

# One call at a time, and every missed call and message announced (2026-10-08)

Reported after the push work: calls still rang only with BROKA open, a
second call rang over a call in progress, and "only missed call was
displayed despite there being an unread text message".

**No push yet: a configuration problem, not code.** The APK being used
was built by `Xxavier-ml/broka`, which has no `GOOGLE_SERVICES_JSON`
secret; it was set on `Broka254/broka`. No phone ever registered, so the
API (Railway, from `Broka254/broka`) had nowhere to push. The release
notes now open with a warning when an APK has no Firebase, and Settings →
Notifications says whether this phone can be reached while BROKA is
closed. NOTIFICATIONS.md §6.

**One call at a time** (CALLING.md). `/calls/initiate` answers 409 when
either person is on a call; a redial replaces the caller's ringing call
instead of adding one; two people calling each other get one call; Accept
moves the call out of "ringing" at once (`POST /calls/{room}/answer`). The
app never rings over a call under way, never rings again for the call it
is on, and shows the server's reason when a call cannot be placed.

**A missed call and the message before it are both announced.** The
inbox names the unread message and missed call the last row can hide; the
app announces each once. The message push stops counting call cards, and
an install's first sweep no longer announces every thread but one.

**Main's CI.** `test_concurrent_sweeps_close_each_auction_exactly_once`
failed about one run in twelve: on SQLite, which has no row locks, a sweep
retrying an auction's deal while the closing sweep was still creating it
made a second deal. Winner deals are now created one at a time in each
process (`auctions/lifecycle.py`); across processes PostgreSQL's row lock
already did it.

# Calls and messages with the app closed (2026-10-07)

Raised by the owner: a call rang only while the app was open, the caller
assumed anyone not "active" couldn't be reached, and messages sent while
someone was away weren't there until they opened BROKA. NOTIFICATIONS.md
has the review and the design.

**Why nothing reached a closed app.** Released APKs were built without
`google-services.json` (CI never wrote it), so Firebase never started. And
`POST /calls/register-token` returned 500 on every call (it treated the
user dict as a `User` row), so the server never had a token. CI now writes
the file from the `GOOGLE_SERVICES_JSON` secret. The endpoint stores one
row per phone (`push_devices`), takes a phone away from the account that
had it before, and unregisters on sign-out.

**Messages are pushed** (`api/core/message_push.py`). Every committed chat
message goes to whoever `/history` says may see it, debounced per thread,
as one notification per conversation ("3 new messages · ..."), drawn by
Android with the app closed.

**Calls ring every phone and report back.** The callee's phone
acknowledges the ring (`POST /calls/{room}/alerted`), which turns the
caller's "Calling…" into "Ringing…" instead of a guess from presence. A
call nobody answered and no phone reported becomes a missed call
(`ring_watchdog_tick`). The caller's ring is no longer cut off at 30
seconds as a failure, and `GET /calls/incoming` replaces the per-thread
call polling.

**App.** The poller stops in the background once pushes work. There is a
white status-bar icon, an Updates channel for deal alerts, and a one-time
prompt to be left out of battery optimisation.

# Zeno's listing descriptions: lines a buyer scans, and questions for the seller (2026-10-06)

Raised by the owner: the description Zeno wrote from a listing's photo read
like a long report ("It has a RAM of 4 GB and storage of 128 GB"), and what
the photo couldn't show was left as blanks instead of asked about.

**Lines, not a report** (`api/domains/ai_broker/service.py`). The
description is now one fact per line, `Label: value` - `RAM: 4 GB`,
`Storage: 128 GB`, `Condition: Used - light scratches on the back` - with
no introduction, summary or sales talk. What it covers comes from the
fields buyers filter that category on (the Buying Agent's list from
`categories/seed.py`) plus what buyers of that kind of item always ask.
`selling.clean_description` strips the markdown and bullets models add.

**A conversation** (`POST /zeno/listing-draft/describe/turn`,
`lib/features/zeno_assistant/presentation/zeno_describe_screen.dart`).
Zeno's look at the photo now also returns `questions` - the essentials it
couldn't see (battery health, mileage, a title deed), at most five, never
a guess. The app asks them in a chat in the Zeno screen's look; each answer
goes back with the description so far and comes back folded in as lines.
Those turns are text only and free once the plan has descriptions: only the
look at the photo is counted. "Use this description" (or Back) puts it in
the seller's box, any question still open as a blank `Label: ` line.

**Older builds** don't send `conversation: true`, so their questions come
back inside the description as blank `Label: ` lines - what those builds
already tell the seller to fill in.

# Changing a listing's price, a fee that follows it, land that isn't delivered (2026-10-05)

Raised by the owner: a seller couldn't change a listing's price, though it
was meant to be allowed within limits; the platform assumed everything can
be delivered, land and property included; and the fee should follow the
listing's price and quantity.

**Changing the price** (`lib/screens/seller_dashboard_screen.dart`,
`lib/features/listings/presentation/change_price.dart`). The rules existed
on the server (two changes a week, 12 hours apart, none while a deal stands)
but only a store product had a way to use them. Every listing on the seller
dashboard now has a Price button; store products share the same dialog.

**How far a change may go** (`api/domains/listings/price_rules.py`). Once
buyers have seen a price, one change raises it by at most 25%
(`PRICE_RAISE_TOO_LARGE`): a bigger jump on a listing buyers saved is a bait
and switch. A new listing, or one buyers can't see yet, can be corrected
freely. Cuts are not limited.

**The fee follows the price.** The listing fee was already priced on the
listing's price, category and quantity (`pricing/engine.py`, PRICING.md §2),
but only when paid: a listing paid for at KES 10,000 could be raised to any
price for the months paid. Now a raise on a listing with paid time left
shortens that time in proportion to the new monthly fee. The server answers
`PRICE_RAISE_SHORTENS_PAID_TIME` with the numbers, the app asks, and the
change goes through with `accept_shorter_paid_time`. Quantity can't be edited
after posting, so it can't be gamed the same way.

**Land and property aren't delivered** (`api/domains/listings/handover.py`,
`lib/utils/handover.dart`). The sell wizard no longer asks their seller
about delivery; the server drops any answer an older app sends; the listing
screen says "Viewed on site" instead of "Delivery not stated"; and Zeno is
told it stays where it is and passes by a title transfer, even for older
rows that carry a delivery answer. Listings carry `handover`
(`"delivery"` or `"in_place"`). The escrow release already asks a land or
property buyer about the title documents (`escrow/policy.py`).

# Forgotten passwords, selfies on the Menu and listings, a sky that stays put (2026-10-03)

Reported from a phone, with screenshots: the starry background squashed
whenever the keyboard opened; the Menu and a listing's seller card showed an
initial instead of the person's selfie; a business seller's card gave only
the business name; there was no way to change or recover a password; and
four of Zeno's six languages should say "coming soon".

**The background no longer squashes** (`lib/widgets/constellation_background.dart`).
Stars sat at fractions of the box the background was given, and a Scaffold
shortens its body by the keyboard's height - so on the chat, Zeno, search
and every other screen on the constellation, the whole sky slid up and
squeezed into what was left above the keyboard. The sky is now drawn on a
canvas the size of the box with the keyboard down, and the keyboard only
covers its bottom. Fixed in the widget, so every screen gets it.

**Selfies instead of initials** (`lib/widgets/broka_image.dart`). BrokaImage
treated any value starting with "/" as a server path. Bare base64 of a JPEG
starts "/9j/" - and every selfie is one - so the photo was fetched from the
API as a URL, failed, and the initial showed. Only "/media/..." (the
backend's own image route) is a path now. The chat header decoded the photo
itself, which is why it was right there and wrong on the Menu and the
listing. The listing's seller card also falls back to the stored avatar.

**A business and the person behind it** (`lib/models/seller_names.dart`,
`lib/screens/product_screen.dart`). A long-term seller's card shows the
business name and, under it, their official name, from the public profile
(`business_name` and `name`). Someone selling as themselves has one name.

**Forgotten and changed passwords** (`api/domains/auth/`, `api/security.py`;
`lib/features/auth/presentation/`). "Forgot password?" on the login screen
was a label with nothing behind it. It now opens an SMS-code reset:
`POST /auth/password/forgot` texts a code (purpose `login_recovery`, so a
signup code can't reset a password and a reset code can't verify a signup),
`/forgot/verify` swaps it for a `password_reset` token, and `/reset` sets
the new password, marks the number verified and signs the phone in. The
token carries a fingerprint of the password hash it was issued against, so
it works once. Settings has Change password (`POST /auth/password/change`,
current password required, rate-limited like login), with the SMS reset for
a forgotten current one. Both revoke every refresh token on the account and
issue a fresh session to the phone that made the change.

**Languages** (`lib/screens/settings_screen.dart`). English and Kiswahili
can be chosen; Dholuo, Kikuyu, Luganda and Sheng are shown as coming soon.

# The call screen names who you're calling; a call history; the Inbox opens the chat you were using (2026-10-02)

Reported from a phone, with a screenshot of a seller's call screen headed
"Buyer": show the person's name, bring the call screen onto the rest of the
app's design, add a call history, and stop the Inbox putting someone who had
moved to the direct chat back in Zeno's room every time.

**The call screen** (`lib/screens/voip_call_screen.dart`). On Home's visual
system - the constellation, a glow in the call's state colour, the chat
gradient on the person's ring, the controls in a card - with the hint and
button labels in a readable colour (they were in `textLow`). It shows the
person's name and which side of the deal they are on, next to the listing.
The direct chat passed the word "Buyer" as a seller's peer name; it passes
the buyer's name now (its header and call prompt said "Buyer" too), and
every call site passes `peerId`, so a placeholder name is looked up. The
call logic is unchanged. See CALLING.md.

**Call history** (`GET /calls/history` in `api/routers/calls.py`;
`lib/features/calls/`, route `/call-history`). Every call with a buyer or
seller, newest first, by day, with a Missed filter; read from the call cards
already in each thread. Opens from the Inbox's header and the Menu. A call
opens its chat; its button calls back.

**The Inbox opens the screen you were on** (`lib/services/chat_screen_memory.dart`,
`lib/screens/inbox_screen.dart`). Each thread remembers, on the phone,
whether the user was last in Zeno's room or the direct chat, and the Inbox
opens that one - unless only the other has something new. The direct chat's
news was already in the inbox (`unread`); Zeno's was not, so each inbox
thread now carries `zeno_unread` (Zeno's messages to this viewer since they
were last in Zeno's room) and the room reports what it has shown with
`POST /negotiate/{listing_id}/zeno-read` - its own watermark row
(`zeno_buyer` / `zeno_seller` in `thread_read_state`), which marks nothing of
the other person's read and is never shown to them. A thread from before
falls back to the direct chat's watermark. A thread never opened on the
phone opens Zeno's room as before, unless only the direct chat has news. A
notification about a Zeno message now opens Zeno's room (it opened the direct
chat, where the message isn't shown).

Also: a seller's Zeno room loaded the history without the buyer's id, so the
server answered with the latest buyer's room - a seller who opened an earlier
buyer from the Inbox read someone else's negotiation. It sends the id now.

Tests: `tests/test_call_history.py`, `tests/test_inbox_zeno_unread.py`;
`test/voip_call_screen_test.dart`, `test/call_history_screen_test.dart`,
`test/chat_screen_memory_test.dart`. `test/inbox_screen_test.dart`'s thread
with two unread direct messages now opens the direct chat.

**Not device-verified**: the Android build was not run here; the screens
were checked in widget tests and rendered to images.


# Chat messages show once, ticks move, missed calls notify, Zeno sees photos (2026-10-02)

Reported from a phone: the last messages in a chat showed twice until it was
reopened, a message the buyer had read still showed one grey tick, missed
calls produced no notification, and Home gave no sign of unread messages.
Asked whether Zeno can look at images: it could not.

**One bubble per message** (`lib/screens/negotiation_screen.dart`,
`api/routers/negotiate.py`, `api/routers/media.py`). The chat socket closed
itself after a minute in which nobody typed (`wait_for(..., 60)` broke out of
its loop), and the app never reconnected, so chats ran on the 4-second
history poll - which delivered a just-sent message as "new" while the send
was still answering, beside the copy already on screen that had no id to
match it by. Each message now carries the phone's own id for it
(`NegotiationMessage.client_msg_id`, unique per sender); the server stores
it, returns the stored message from `POST /negotiate/direct-message` (it
returned only `{"ok": true}`), echoes it on `/history` and the socket, and a
resend under the same id returns the first copy instead of storing a second.
The socket pings both ways and the app reconnects with backoff, renewing an
expired token first. Sends go out in order from a queue; a failed one says
"Not sent" and is tapped to try again or delete (it used to fail silently).
A message typed while the history loaded is no longer lost.

**Ticks** (`api/routers/negotiate.py`, `lib/services/api_service.dart`).
A seller who reached the chat without a buyer id got no receipts at all
(read-status answered "no thread"), no socket (refused 4003), and - worse -
their messages were stored with `buyer_id` NULL, which every buyer on the
listing is shown. Those endpoints now use the thread `/history` shows that
seller (the latest buyer). Reading or receiving a thread now pushes a
`receipt` event to the other side's open chat, so "seen" arrives at once; a
failed read-status poll no longer resets every tick to grey (watermarks only
move forward); and a chat left open in the background marks messages
delivered, not read. The chat's requests renew an expired session (access
tokens last 15 minutes) instead of failing until something else did.

**Missed calls** (`api/routers/calls.py`, `lib/services/global_poller_service.dart`,
`lib/services/notification_service.dart`, `lib/main.dart`). Nothing pushed a
missed call: the only notice was the inbox poller, alive only while the app
is. `log-result` with `missed` or `cancelled` now sends the callee a
notification push the phone draws itself, which also takes down the call's
still-ringing notification. The poller decided "already notified" by the
last message's text, so a second missed call (or a second "ok") from the
same person was never announced; it goes by the message id now
(`last_message_id` on the inbox), without re-announcing old threads on
update. A chat open behind the home screen no longer silences its thread.
Push, poller and foreground share one Android tag
(`NotificationService.missedCallTag`), so one missed call is one notification.

**Home's Inbox tab shows the unread count** (`lib/screens/home_screen.dart`),
from the poller's sweep, refreshed on return from the inbox.

**Zeno looks at photos** (`api/core/vision.py`, `api/core/gemini.py`,
`api/domains/zeno_assistant/`, `api/domains/ai_broker/service.py`,
`lib/screens/zeno_screen.dart`, `lib/screens/negotiate_screen.dart`). See
ZENO_ACTIONS.md. Gemini was pinned to `gemini-2.0-flash`, shut down on
2026-06-01, in four modules; every Gemini call has been failing over to the
next provider since. The model is now `GEMINI_MODEL` (default
`gemini-flash-latest`). The damaged-goods report read its "photo" from the
message text, so no report was ever analysed.

Tests: `tests/test_chat_delivery.py`, `tests/test_zeno_vision.py`;
`test/direct_chat_delivery_test.dart`, `test/missed_call_notification_test.dart`,
`test/home_inbox_badge_test.dart`, `test/zeno_photo_test.dart`.

**Not device-verified**: the Android build was not run here. The missed-call
push needs Firebase configured on the server (FCM_SETUP_REMAINING.md); the
poller covers an open app without it.


# Calls to a closed app show up; voice notes say when they fail (2026-10-02)

**Incoming-call notification from FCM** (`lib/services/notification_service.dart`).
`initialize()` asked for the notification permission inside the same `try`
that marks the service ready. The FCM background isolate - the one that posts
the call when the app is closed - has no Activity, the plugin throws when
asked for a permission without one, so the service never became ready and
`showIncomingCall` posted nothing. The permission is now asked for after the
service is ready, a failure there leaves it ready, and the background handler
doesn't ask at all. (This path only runs once Firebase is configured; see
FCM_SETUP_REMAINING.md.) `test/notification_init_test.dart`.

**Voice notes in the chat** (`lib/screens/negotiation_screen.dart`). A recorder
that refused to start (microphone held by a call or another app) threw
unhandled and the mic button did nothing; a stop or cancel that threw left the
recording bar on screen with nothing behind it. Each now says what failed and
returns to the input bar; a second tap while the recorder is starting no
longer starts a second recording; leaving the chat mid-start no longer calls
`setState` on a disposed screen. `test/negotiation_screens_test.dart`
("Voice notes").


# The app no longer closes when a call starts (2026-10-01)

**Calls** (`flutter_app/lib/screens/voip_call_screen.dart`,
`android/.../CallForegroundService.kt`, `MainActivity.kt`). Placing or
answering a voice or video call closed the app; MIUI then said "BROKA should
be granted Microphone access". The call's foreground service, declared with
the microphone type, was started before the app had asked for the
microphone, and Android 14+ kills an app whose microphone service runs
without that permission. It now starts once the microphone is granted and
open, claims the camera only when the camera is in use, and the native side
refuses or stops instead of crashing if a permission is still missing. See
CALLING.md. `test/voip_call_permissions_test.dart`.

Two more ways the app could close on its own:

- **Fingerprint sign-in on Android 7 and 8** (`res/values/styles.xml`). The
  fingerprint prompt there is an AppCompat dialog, and the app's themes
  were not AppCompat themes, which local_auth documents as a crash. Both
  themes are now `Theme.AppCompat.NoActionBar` (still dark, no title bar),
  with `androidx.appcompat` declared in `app/build.gradle`.
- **The SMS code reader** (`SmsRetrieverBridge.kt`). Its receiver is
  exported, so any app can send it a broadcast, and anything thrown while
  reading one killed BROKA; it now logs and ignores what it can't read.
  It also stops using Android 13's buggy typed `getParcelable`.

**Not device-verified**, and the Android build itself was not run (no
Android SDK in the environment this was written in): the Kotlin was
compiled against the Android 15 framework and the Flutter embedding, with
stand-ins for the androidx and Play Services classes.


# The OTP reader, photos taken the listing way, and the stores on BROKA's colours (2026-09-30)

**The SMS code fills itself again** (`flutter_app/lib/screens/auth_screen.dart`).
The SMS Retriever delivered the code, and the sign-up wizard threw it away:
it only took a code on step 2, which stopped being the verify step when the
account-type and seller questions went in front of the phone number (it is
step 4). The check now names the step. A code that arrives before the verify
step is showing - the server texts before it answers, so on a slow
connection it often does - or while a resend is in flight is held and filled
once the step can take it, and a request sent before the app signature was
read waits for it rather than asking for a plain SMS the retriever can't
match. `test/sms_otp_autofill_test.dart`.

**Every photo is taken the way listing photos are**
(`flutter_app/lib/services/photo_capture.dart`):

- Store logo, cover and shop photos, chat photos and the damaged-goods report
  used BROKA's own camera screen (`listing_camera_screen.dart`) instead of
  the phone's camera app, which Android could kill BROKA behind; the phone's
  camera is the fallback, at the sell wizard's size and quality, and a gallery
  pick is sized as the cover step's is. Shop photos can be taken several at
  a time, each uploading as the next is framed.
- Store images are kept in the app's own storage (`KeptPhotos('store_draft')`,
  beside the sell wizard's folder, never sharing it) until the store is
  saved, not in the picker's cache Android may empty under a draft.
- **Chat photos are processed like listing photos** (`api/routers/media.py`):
  `POST /media/upload` stored an image exactly as sent - never checked to be
  an image, EXIF intact, so a camera shot carried where it was taken to the
  other side of the chat. It now goes through `process_image` (validated,
  upright, metadata stripped) and is kept at the largest listing size, as
  WebP. `tests/test_chat_media_images.py`.

**Online stores**: the directory's store card is on Home's product-card
system (gradient edge, taller picture, the logo as the shop's sign, the
record as chips), and Visit store is a pill beside the product count instead
of a bar across the whole card. A store's own page has the app's search field
(the old 44px pill was the last one left) with a matching filter button,
BROKA's violet, blue and cyan in place of the category's colours and pink,
Home's card edge on its products, and more of the screen for them: 8dp sides
instead of 12 and a photo 0.95 of the card's width (`ProductGridView.itemImageShare`).

# The listing screen: the seller's standing, the deal's terms, and Zeno about it (2026-09-29)

**The listing screen** (`flutter_app/lib/screens/product_screen.dart`) is on
Home's visual system: the constellation, Home's header (the category's badge
and glowing name), cards with the product card's gradient edge, and the brand
gradient on the one button.

- **Deal terms**, as two tiles near the top: fixed price or negotiable, and
  whether the seller delivers (with their note), picks up, or hasn't said.
  They were two of ten small chips. A fixed price reads "Contact Seller"
  rather than "Start Negotiation".
- **The seller's standing**: the seller dashboard's overall rating, deal
  completion rate and response time, in the dashboard's colours, from
  `seller_standing` on `GET /auth/user/{id}` (`trust/public_standing.py`,
  last night's snapshot; rank and backlog stay the seller's; SELLER_METRICS.md).
  It replaces a "credibility" score the screen made up, and the seller card's
  "10.0/10", which every new seller showed (the rating's default of 5.0,
  doubled).
- **Zeno Insight** opens Zeno about the listing, where the buyer asks what
  they need to know. It replaces a panel that asked the model for a one-off
  verdict and a price comparison from `/listings/{id}/price-comparison` - an
  endpoint in `api/routers/listings.py`, which is never mounted, so it always
  said there was nothing to compare. The matatu fare estimate moved to the
  map.

**Zeno, asked about a listing** (ZENO_ACTIONS.md): `listing_id` on
`POST /zeno/assistant/turn`. The server reads the listing - BROKA's facts
apart from the seller's fenced words - and when it doesn't fit, Zeno offers a
search the buyer takes with a tap (`requires_confirmation`, a
**[Not now] [Find it]** card) instead of one that just happens.

# Rust in the backend, and password hashing off the event loop (2026-09-28)

**A Rust extension, `backend/native/`** (PyO3, built with maturin), for the
jobs Python is the wrong tool for. The backend stays Python; the reasoning,
measurements and what was deliberately left alone are in
`backend/native/README.md`.

- **Chat scanning for off-platform contact details** (`api/core/text_guard.py`).
  Every message is scanned for phone numbers, WhatsApp/Telegram, emails,
  M-Pesa tills and "pay me directly". It used to be five regexes that
  matched only "0712345678" written plainly; the text is now normalized
  first, so "0712 345 678", "+254 (0) 712...", "zero seven one two...",
  "sifuri saba...", a Cyrillic "о" or a zero-width space inside "whatsapp"
  are caught too. It runs on Rust's linear-time regex engine: Python's
  backtracks, and one careless rule could hold the event loop for seconds on
  a crafted message. The rules are data (`native/rules/contact_leaks.json`),
  read by both engines. Everything the five old patterns caught is still
  caught (`tests/test_text_guard.py`).
- **Direct chat is scanned too.** Only messages sent through Zeno were;
  switching AI assist off to talk directly is exactly where a number gets
  passed. The audit row records which kinds were found, never the number.
  These rows mark a deal as leaked (`domains/trust/completion_rate.py`), so
  the rules are kept precise and their near misses are tested.
- **One distance function** (`api/core/geo.py`) instead of six copies in two
  variants; the "near me" filter computes a whole candidate list in one call.
- Every function has a **Python fallback** with identical output, held to it
  by `tests/test_native_parity.py` (thousands of generated messages, every
  assigned BMP character). `BROKA_NATIVE`: `auto` (default), `required`
  (what the Docker image sets: no extension, no start) or `off` (the kill
  switch). `GET /ready` reports `"native": "rust"` or `"python"`.
- The Docker images compile it in a build stage (rustup pinned and
  checksum-verified, `Cargo.lock` enforced); the runtime image has no
  compiler. CI gains a Rust job (fmt, clippy, tests); the SQLite job runs
  the suite on the extension and the PostgreSQL job on the fallback.
- The auction leaderboard's hook for a C++ engine (`broka_engine`), which
  was never built, is gone; the database does the ordering.

**Password hashing** (`api/security.py`):
- Passwords were cut at 72 characters, but bcrypt reads 72 bytes and
  bcrypt 5 raises past that: signing up with a long non-ASCII password was a
  500. The cut is in bytes now; every stored hash still verifies.
- Each hash (~250 ms of CPU) ran on the event loop, stalling every other
  request on the worker during every login. It runs in a thread now.
- A login for a phone with no account answered in a millisecond and a wrong
  password in 250 ms, which told anyone which numbers have accounts. Both
  now cost one bcrypt check.

Tests: `test_text_guard.py`, `test_native_parity.py`,
`test_password_hashing.py`, `test_auction_leaderboard.py`, and the Rust
unit tests (`cargo test` in `backend/native`).

# My Store: every product, and what needs the owner (2026-09-28)

**The Products tab shows every product in the store.** It listed them
through the public feed, which shows only what buyers can see, so a product
left its owner's screen the moment it went into a deal, sold, or waited for
its listing fee (`STORES_REVIEW.md`, open item 2). A new owner-only
endpoint, `GET /stores/{id}/manage/listings`, returns them all, each with
its state (live, hidden until its fee is paid, in a deal, sold) and listing
fee, plus how many are in each state.

- Filter chips with those counts, and a search.
- Each product says what its state means ("Not paid for yet, so buyers
  can't see it", "Listing time ends 2 Oct"), with **Pay** or **Renew**
  beside it.
- Tapping a product: pay or renew; change the price (the dialog states the
  two-a-week limit, and the server's refusals are shown as they are);
  share the product's own link; see how it's doing; see it as buyers do;
  take it out of the store.

**The Overview:**
- **Needs your attention:** products hidden from buyers and products in a
  deal, each opening the Products tab on them.
- **Finish setting up your store:** logo, cover photo, description, three
  products and a business email, each a tap from the page that does it;
  gone once all are done.

**Fixed on the way:**
- Taking a product out of the store reloaded the whole screen and put the
  owner back on Overview. Changes made inside My Store now fetch the store
  again without replacing the dashboard.
- Once the header had collapsed, the top of every tab (Add product, the
  search) sat under the pinned bar and tabs, out of reach.

Tests: `backend/tests/test_store_setup.py` (`TestOwnerProducts`),
`flutter_app/test/store_setup_test.dart` (9 more).

# Zeno stays with you, and guides (2026-09-27)

**Zeno stays active across screens.** "Open my dashboard" used to open the
dashboard and end the conversation. Voice mode now belongs to the app, not
the Zeno tab (`flutter_app/lib/features/zeno_assistant/zeno_session.dart`,
mounted above the Navigator by `ZenoSessionHost` in `main.dart`): opening a
screen shrinks it into a pill over that screen that **keeps listening**. On
the dashboard, "start a listing search for a PS5" searches; then "switch to
my inbox" opens the inbox, and Zeno is still there.

- A screen Zeno opened is swapped for the next one it opens, not stacked:
  back goes to where the user was before Zeno started.
- **The pill:**
  - its orb and a turning ring that brightens with the voice;
  - what it hears as it hears it, then what Zeno says;
  - a longer reply in a bubble above it;
  - the keyboard to type to Zeno from any screen, and X to end;
  - tap the orb for the full view again;
  - drag it to the top or the bottom.
- **Holding the Zeno tab** opens voice mode over Home instead of switching
  tabs.
- **One conversation.** Everything said in the session lands in the Zeno
  tab's chat, live when the tab is open and saved when it isn't.
- **Where the microphone goes:**
  - one voice session at a time (a voice note or the negotiation room's
    voice card takes the mic, and the pill says "Tap to talk");
  - a call, signing out, or the app leaving the foreground ends the session;
  - a minute with nothing said stops the mic, because the speech provider
    bills by the minute;
  - handing a request to the Buying Agent ends it too, since the agent has
    its own voice.

**Guides.** "How do I open a store?", "tips to sell faster", "how do I get
verified", "how does escrow work", "how do I spot a fake listing". Zeno
answers with steps, each with a **Take me there** button to where it is done
(`zeno_guide_card.dart`). In the session, the guide folds above the pill
with its progress and goes along from screen to screen.

- Steps are built on the server from the user's own account
  (`backend/api/domains/zeno_assistant/guides.py`):
  - whether they are a business seller yet;
  - what their store is missing;
  - which listing is priced 40% above the median of similar ones, has two
    photos, or has had 3 views in 10 days.
- Every figure is computed; none is the model's.
- The common questions are recognised by rules and cost **no model call**.

**Questions about the user's own account.** "What do you think of my
rating?" is now answerable. The account is split into topics (profile,
listings, sales, store, watch), and a question gets only the ones it is
about (`knowledge.py`), picked by rules from its words at no extra cost. If
the rules miss, the model can ask for a topic once (`NEED_INFO`): at most
**two model calls a turn**, never more. "Hi" costs what it always did.

- No other user's words enter the prompt: ratings go in as numbers and a
  spread, never review text.
- Each reply says which topics were read and how many model calls it took
  (`facts`, `model_calls`).

## Fixed on the way

- **Opening voice again just after closing it gave a deaf "Listening".** The
  speech provider ignores a start while its last socket is still closing,
  and the controller went on to say it was listening. Reachable before
  today with the voice card's X and then the mic; the pill's "Tap to talk"
  made it common. `open()` now waits for the last close's teardown, which is
  bounded. The test in `zeno_assistant_test.dart` fails on the old code.

Tests:
- `backend/tests/test_zeno_assistant.py`: 37, also run on PostgreSQL;
- `flutter_app/test/zeno_assistant_test.dart`: 31, covering the
  dashboard -> search -> inbox flow over a fake Deepgram socket, the pill,
  guides, the microphone arbiter, the quiet timeout and the app going to the
  background.

# Zeno, the assistant - talk to it, and it does things (2026-09-27)

The Zeno tab was a chat that could only talk. It is now an assistant, one on
one, typed or spoken, that can also act in the app:

- **Open a screen** - "open my inbox", "take me to Sell", "show my deals",
  "fungua mipangilio": Home, Inbox, Sell, Menu, Profile, Settings, Search,
  the Buying Agent, the seller dashboard, deals, verification, market
  insights, How BROKA works.
- **Search** - "search for a Toyota Axio" opens the search on those words.
- **Find it for me** - "find me a laptop under 50k" hands the request to the
  Buying Agent, already asked.
- **Open a chat / call someone** - "message Jane", "video call the Axio
  seller". Only people the user already has a thread with, resolved on the
  server from their own conversations. **A call never starts until Call is
  tapped** - typed or spoken; "yes" said out loud is not a confirmation.
  "Call Mary" when there are two Marys asks which one.
- **Just talk** - prices, escrow, negotiating, anything else.

How it works: `POST /zeno/assistant/turn` (`backend/api/domains/zeno_assistant/`).
Plain commands are recognised without a model call (instant, and still
working when every AI provider is down); everything else is one model call
that returns a reply and at most one proposed action. The proposal is cut
down to a closed vocabulary; the model never writes an id and never sees
another user's name or listing title. See ZENO_ACTIONS.md.

**Voice mode.** The microphone on the Zeno tab now opens a full-screen voice
mode (`flutter_app/lib/features/zeno_assistant/presentation/`): it grows out
of the microphone button; an orb of layered plasma swells with the user's
voice while a spectrum ring round it dances to the microphone and particles
are drawn in; it knots and spins with orbiting comets while Zeno thinks, and
pulses and throws ripples while Zeno speaks; a shockwave when it acts. Live
captions of what it hears and what it says; "try saying" examples; the call
confirmation as a card; keyboard, stop and close. Holding the Zeno tab on
Home opens straight into it. Reduce-motion: the same layout, still. The
Buying Agent and the negotiation room keep the compact voice card.

## Fixed on the way

Each with a test that failed on the code before it.

- **Zeno's own voice was sent back to Zeno as the user's.** The voice
  session keeps the microphone open while Zeno speaks through the speaker;
  whatever it transcribed then landed in the box and, with auto-send, went
  to Zeno as the user's next turn. What is heard while Zeno speaks, and for
  700ms after, is now dropped (`ZenoVoiceController`). Part of the same
  bug: `BrokaTts.speak` returns when playback STARTS, and the Zeno screen
  awaited it as if it returned at the end, so "speaking" ended at the first
  syllable. `BrokaTts.speakToEnd` waits for the end (bounded, and Stop hands
  the microphone back at once). The drop is tested; `speakToEnd` itself is
  not - the audio plugin isn't faked in tests - and rests on audioplayers'
  contract: `play()` sets the player's state before it returns, and the
  state stream is broadcast.
- Not a test-reproduced bug, but found while building this: ending a voice
  session could wait indefinitely on the socket's close handshake (the
  controller documents it). Nothing awaited it before; the assistant does,
  before it navigates or calls, so that wait is bounded.

Tests: `backend/tests/test_zeno_assistant.py` (20, also run on PostgreSQL),
`flutter_app/test/zeno_assistant_test.dart` (19, including the spoken loop
end to end over a fake Deepgram socket). `zeno_chat_test.dart` now talks to
the new endpoint; an older server without it still gets an answer through
`/negotiate/chat`.

# The Buying Agent, in motion (2026-09-26)

The Buying Agent's screen showed the agent's work as one more chat: an
italic caption while it searched, results stacked 210px tall down the
conversation, a text button for the watch. It now shows the work
(`flutter_app/lib/features/buy_agent/presentation/widgets/agent_motion.dart`):

- **Before the first message**, Zeno at the centre of an animated core -
  radar rings, a dashed orbit and a comet turning, the categories orbiting
  it - with "Tell me -> I hunt -> I negotiate" under it, a light running
  along the steps. It bursts open on arrival and collapses away as the
  first message goes.
- **Zeno's brief**: what Zeno has gathered (item, category, budget,
  condition, place, specs) as chips under the header, each popping in as
  Zeno learns it and again when it changes - a misheard budget is on
  screen at once instead of turning up as a wrong search.
- **Searching** is a radar card: a sweep with blips lighting as it passes,
  the caption shimmering, a beam running along the bottom. Still a timer's
  show of work - it never marks a step done.
- **Results** are a deck to swipe through: a verdict badge ("1 exact · 2
  close") and a count, cards dealt in from the right, turning in 3D as they
  move, a page indicator. Confetti when every result is an exact match.
- **The watch** is a card with a pinging radar orb; setting it flips it
  over with a burst to "On watch" and a live dot, with confetti.
- Bubbles arrive (the buyer's spring up from the composer, Zeno's slide
  in), a light runs round Zeno's bubble while it writes, the openers fly
  in, and the header's dot and status follow what Zeno is doing
  (Thinking..., Hunting..., On watch).
- Home: Zeno flies from the CTA into the agent's header (a shared Hero), a
  glint crosses the CTA once every six seconds, and the "Zeno is watching"
  card has the same live orb, a tint, and legible "days left" and controls.

Everything honours the OS reduce-motion setting: same layout, no motion.

## Weak spots fixed on the way

Each has a test in `flutter_app/test/buy_agent_ui_test.dart` ("weak
spots") that failed on the code before it.

- **A reply to a conversation that was started over landed in the new
  one**, bringing the old conversation's criteria, which the next turn sent
  back as the new search's. Replies now carry which conversation they
  belong to, and "New chat" frees the composer at once.
- **The "searching" caption fired into the wrong turn.** It waited on a
  `Future.delayed` nothing could cancel, so a quick turn's delay announced
  a search 2.2s after the earlier message. Now a cancellable Timer.
- **The budget question closed silently** on anything but a plain number
  (nothing typed, "cheap"): no watch, no error. It now uses the sell
  wizard's amount field (digits only, grouped as typed) and says what it
  needs. Its controller was also never disposed.
- **Budget before category.** A watch can't be made without a category,
  but the budget was asked for first and the answer then thrown away.
- **"I'll keep watching" after the watch was gone.** "Watching" was
  remembered on the phone; after the watch was stopped from Home or ran
  out, Zeno still said so and offered nothing. Checked against GET
  /buy-agent-requests/me when the conversation is picked up again.
- **Two searches returning the same listing broke opening it.** Every card
  carries a Hero tagged with its listing id; two on one screen is an
  assertion (and, in release, a photo flying from the wrong card). Only
  the newest card for each listing flies now.
- **A failed turn had to be retyped**, and the retyped message went to Zeno
  twice (the unanswered one was still in the context). The error now has
  Try again, which replaces the failed exchange.

# Zeno watches end after 30 days (2026-09-26)

A watch used to run for ever: a year-old one with negotiation authorised
kept messaging sellers for a buyer who had long since bought elsewhere.

- A watch now ends `BUY_AGENT_WATCH_DAYS` (default 30) after it was made
  or last changed; changing it (a new budget, say) starts its time again.
  New column `buy_agent_requests.expires_at`. Watches from before it are
  aged by when they were made, so the ones already older than 30 days end
  on the first sweep after deploy.
- The matcher, the one-watch limit, GET /buy-agent-requests/me, update and
  cancel all go by the date, so a watch is over the moment it expires. The
  5-minute sweep then marks it `expired` and pushes the buyer "Zeno
  stopped watching", once, even with several instances sweeping.
- Home's watch card says how long is left ("12 days left").
- The column's startup migration says `TIMESTAMP`. 23 older entries in
  `init_db()` say `DATETIME`, which PostgreSQL has no type for; their
  failures are swallowed, so on a PostgreSQL table that predates one of
  those columns it was never added (`deals.*` timers and timestamps,
  `auction_meta.*`, `interests.nudge_*`, `users.last_seen`,
  `thread_read_state.last_delivered_at`). Not changed here - worth checking
  against the production schema.

Tests: `backend/tests/test_buy_agent.py::TestWatchExpiry` (including one
that drops the column and runs `init_db()`, which fails with `DATETIME` on
PostgreSQL), `flutter_app/test/home_buy_agent_watch_test.dart`.

# Buying agent review (2026-09-26)

A pass over the Buying Agent (backend `buy_agent/`, the standing-request
matcher, Zeno's buying screen and Home's watch card) for weaknesses and
points of failure. Every fix has a test that failed on the code before it.

## Fixed

- **A buyer could put words in Zeno's mouth.** START_NEGOTIATION's optional
  `message` replaced Zeno's opener and was stored as `role="broker"`, so a
  hand-made request could have "Zeno" tell a seller to pay a "verification
  fee" to some number. Zeno's opener is now always the fixed text; the
  buyer's words go into the thread as the buyer's own direct message.
- **Watches nobody could see or stop.** A matched request keeps matching
  but didn't count against the one-request cap, so after a first match a
  buyer could start a second watch; GET /me, update and cancel only reach
  the newest row, and the first went on pushing matches and opening
  negotiations. Matched requests now count. And nothing in the app could
  cancel a watch at all - Zeno said "cancel that one from the home screen",
  which had no such control. Home's watch card has a Stop watching button,
  Zeno offers to replace the current watch, and Home reloads the card on
  the way back from Zeno.
- **Two creates at once got past the cap on PostgreSQL** (the re-count
  after the flush never sees the other transaction's row). The buyer's
  `users` row is locked for create, update, cancel and START_NEGOTIATION's
  one-opener check (`lock_buyer`); the last two could also race - an update
  could revive a just-cancelled watch, and a double tap sent two openers.
- **Watches matched things they weren't watching for.** The matcher
  ignored the `query` and `attributes` Zeno stores, so a "Pixel 8" watch
  fired on any Electronics listing under budget. Every query word must now
  appear (the rule listing search uses), and a listing that states a spec
  short of the ask is skipped. Condition is normalised to the listings'
  lower-case values on write (an unknown one is refused) and compared
  case-insensitively; before, "Used" never matched anything.
- **Posting a listing waited on every watcher's push.** The matcher runs
  inside POST /listings and sent one push per matched buyer in turn, 15
  seconds allowed each. Tokens are read in one query and pushes go out in
  the background, eight at a time. The already-opened check is one query
  instead of one per watch.
- **Lost match counts.** `match_count` was incremented in Python; two
  listings matching at once both wrote the same number. It is incremented
  in SQL, and only while the request is still watching.
- **The conversation trusted the client's `slots`.** They went whole into
  the billed prompt (the one unbounded client text there) and, when the
  model was down, straight into scoring: a list for a category or a string
  for a budget was a 500. They are cleaned by the same rules as the model's
  output (`clean_buy_agent_slots`); `/parse-intent`'s `existing_filters`
  too.
- **The conversational search could miss the item it was asked for.** Its
  pool was the category's top 200 by ranking, whatever the buyer said -
  in a busy category, or with no category, the exact listing could fall
  outside it. Listings with every word of the query are fetched first; the
  ranked pool is still added for near misses.
- **No bounds on what a watch stores.** Query, location, features and
  attributes on CREATE/UPDATE_BUYING_REQUEST (and feature length on
  POST /buy-agent-requests) had no limits; a negative distance was a watch
  that could never match.
- `buy_agent_requests` had no index but its key; GET /me (every Home load)
  and the matcher now have `(buyer_id, status)` and `(status,
  lower(category))`.

Tests: `backend/tests/test_buy_agent.py::TestBuyAgentReview`,
`backend/tests/test_buy_agent_conversation.py::TestConversationReview`
(the concurrent-create test runs on PostgreSQL only),
`flutter_app/test/home_buy_agent_watch_test.dart`, and a replace-the-watch
test in `flutter_app/test/zeno_chat_test.dart`.

## Still open

- Matching reacts to new listings only. A listing whose price later drops
  under a buyer's budget, or that comes back to active, is never matched.
- Auction listings match watches like any other, and an authorised watch
  sends their sellers "would you be open to a conversation?".
- Buyers who already have two live requests (possible before this change)
  keep them; Stop watching now reaches each in turn, newest first. A
  one-off cleanup would need a decision about which to keep.

# The Inbox on Home's look (2026-09-26)

The Inbox was the last tab on a flat grey app bar over a plain background.
It now matches the Menu beside it in the bottom bar: the constellation, the
shared collapsing header (with the unread count as a "3 new" pill in the
brand gradient), listing groups as cards like Home's (lit with the brand
glow when they hold unread messages), the offline notice as a card rather
than a strip, and the shared empty and error states. Nothing about loading,
caching or opening a conversation changed. `test/inbox_screen_test.dart`
(the Inbox had no tests), including 320dp at 1.3x text.

# A store needs a business seller first; Zeno's replies at a readable pace (2026-09-26)

## Opening a store no longer makes a buyer a seller on the side

The server has always refused a store to anyone but a long-term seller, but
the store setup got round it: its first step, "Your business", sent a
buyer's business name, category and location to `/auth/upgrade-to-seller`
and carried on opening the store - a second way of becoming a seller that
skipped the question signup and Start selling ask, used a different
category list and had no preview. The Menu offered buyers "Open a store"
straight into it.

- The store setup makes no one a seller. For an account that isn't a
  business seller it stops before the first store step and says why, with
  "Set up my business": Start selling's business steps (the "a few items or
  a business?" question is already answered - a store needs a business),
  then back to the store setup, prefilled from the business just set up.
  A 403 from `POST /stores` (the account changed meanwhile) returns there
  too.
- The Menu's store card, for a buyer or a short-term seller, says stores are
  for businesses and its button is "Set up my business", leading to the
  same steps and then on to the store.
- Removed with it: the wizard's business step, its draft fields and
  `StoresRepository.upgradeToLongTerm`.
- `test/store_setup_test.dart` (the wizard never calls
  `/auth/upgrade-to-seller`; a 403 goes back to the gate),
  `test/start_selling_test.dart` (buyer -> business -> store setup, end to
  end), `test/menu_test.dart`.

## Zeno writes at a readable pace

Replies were written out one to three words at a time every 35-105ms -
about twice a comfortable reading pace, and in lumps. Now one word at a
time, about 13 a second with a slight unevenness, a beat after commas and
sentence ends, each word fading in over a little longer than the gap so the
line flows, a steady caret, and the bubble easing open line by line; the
chat follows it smoothly every frame (never while you're scrolling). Long
replies speed up per word rather than arriving in lumps, so they still take
about seven seconds at most. The new test in `test/zeno_chat_test.dart`
(one word per frame at most, 1.3-3.5s for a 23-word reply) failed on the old
pacing.

# Voice input connects or says why; Start selling asks what signup asks; the negotiation screens on Home's look; Zeno writes its replies out (2026-09-26)

## Voice input stuck on "Connecting…"

When the speech provider refused the connection (a rejected token comes
back as HTTP 401) or couldn't be reached, each provider closed the failed
socket and waited for the close to finish. web_socket_channel never
finishes closing a socket whose handshake failed, so the voice card said
"Connecting…" until the manager's 45-second watchdog gave up on Deepgram -
and then again for AssemblyAI. A socket that never opened is now not waited
for, and a live one gets two seconds (`closeSocketWithoutHanging` in
`services/realtime_stt.dart`). The card now says within seconds that voice
couldn't connect, with a small reference underneath
(`DEEPGRAM_HANDSHAKE_FAILED`, `ASSEMBLYAI_NETWORK_UNREACHABLE`...) - the
diagnostics are printed in debug builds only, so on a phone that line is the
only trace of why. `test/stt_refused_connection_test.dart` runs the real
WebSocket client against a local server that refuses the upgrade; all three
tests hung on the old code.

What makes the providers refuse on the phone is not something the app can
see - the reference on the card says which provider and which stage.

## Start selling replaces Become a Seller

A buyer who opens the Seller Dashboard (from the Menu, their profile, or a
restored last screen) or taps "Start selling" in the Menu now answers what
signup asks: a few items - nothing more to fill in - or a business, which
goes on to the business name, what it sells, location, description and a
preview (`screens/start_selling_screen.dart`). The one-form "Become a
Seller" screen, which demanded a business from everyone, is deleted. Signup
and Start selling share their widgets (`widgets/seller_setup.dart`).

`POST /auth/upgrade-to-seller` takes `seller_tier`: `short_term` needs no
business details; `long_term` (the default, for older clients and the store
wizard) needs name, category and location - blank ones are now a 422 rather
than a display name of " · ". Answering "a few items" never downgrades an
account already set up as a business. `backend/tests/test_seller_signup.py`
(`TestStartSellingLater`; three of its four tests failed on the old
endpoint), `test/start_selling_test.dart`.

## The negotiation screens on Home's look

The Zeno negotiation room and the one-on-one chat were on
ChatAmbientBackground under opaque bars, with gold "composing..." italics
and role-coloured blue and green bubbles. Both now have the constellation,
Home's header language (bare back chevron, square header buttons), cards
like Home's, your messages on the brand gradient, and Zeno's composer -
Home's search pill with the actions inside it and a send button that takes
no room until there is something to send. The composer, send button, typing
dots and bubble frames are shared (`widgets/chat_parts.dart`) by these two
and Zeno's own screen. `test/negotiation_screens_test.dart` (both screens,
including 320dp at 1.3x text).

## Zeno writes its replies out

On Zeno's screen and in the negotiation room, a new reply arrives a few
words at a time, each word surfacing from Zeno's violet, with a caret at
the end - the way a language model's does (`ZenoStreamingText` in
`widgets/zeno_streaming_text.dart`, sharing its pacing with the sell
wizard's streaming bubble). Replies restored from earlier are simply there;
the Buying Agent's listings appear once its sentence is finished; long
replies stream in bigger bursts; reduced motion shows the reply at once, and
screen readers always get the whole reply. `test/zeno_chat_test.dart`.

# Category rail hint, Zeno and the Seller Dashboard restyled, Zeno remembers, no robotic voice (2026-09-26)

## Home: the category rail says there is more

People saw the first few categories and never realised the rail scrolls.
Once per app launch it now glides far enough to bring about two more
categories into view, pauses and glides back (`_playRailHint` in
`home_screen.dart`). A touch on the rail stops it, reduced motion skips it,
and it doesn't run when everything fits. A chevron at the rail's right edge
moves it on a page and stays until the end has been seen.
`test/home_rail_hint_test.dart`.

## Zeno: Home's look, and the conversation is kept

- On the constellation with Home's header language (bare back chevron,
  Home's Zeno avatar, a glowing title, square controls), brand-gradient
  bubbles, openers as chips over the background, and Home's search pill as
  the composer - instead of flat grey bars over a different background.
- The conversation is saved on the phone after every turn
  (`services/zeno_chat_store.dart`) and comes back when Zeno opens, for 30
  days after the last message - per account, and separately for the market
  assistant and the Buying Agent (whose budget, specs and question count
  come back too). "New chat" starts over. Arriving from Home's search with a
  request starts a fresh Buying Agent conversation.
- Fixed on the way: every message was sent to Zeno twice (once as the new
  message, once at the end of the history - both endpoints add the new
  message themselves); a kept conversation would have passed
  `/negotiate/chat`'s 100-entry history limit, so only the recent context is
  sent (20 entries; 40 for the Buying Agent); the typing dots faded in once
  and then stood still.
- `test/zeno_chat_test.dart`; the persistence and double-send tests failed
  on the old screen.

## Seller Dashboard: Home's look

The constellation, the shared header (back chevron, badge, glowing title,
refresh as a header button) and a pill switcher in the brand gradient for
Overview / Products / Deals, which follows a swipe between tabs. The "LIVE"
pill is gone (the dashboard loads once; nothing on it is live). Labels drawn
in `textLow` (about 1.6:1) now use `textMid`. Five overflows on small phones
or at large text sizes are fixed (metric cards, pipeline labels, escrow
chips, deal summary). `test/seller_dashboard_shell_test.dart` runs at 320dp
and 1.3x text with Roboto's real glyph widths.

## Zeno's voice

- `flutter_tts` is removed. It was the fallback whenever the backend's
  voices failed: the phone's own engine, robotic, and usually without
  Swahili or any Kenyan language, so it read them with an English accent.
  Zeno now stays silent and says once that replies are text only.
- The Microsoft English voice reads English only
  (`backend/api/routers/tts.py`). It was the default for any language
  without a voice, and read whatever it was given - a user on the English
  setting who chatted in Swahili heard Zeno's Swahili in an American accent.
  Text sent as English that reads as Swahili (or Sheng) goes to the Swahili
  voice; a language with no voice is a 422 and the app stays silent.
  `backend/tests/test_tts_voices.py` (the two behaviour tests failed on the
  old router).

# Home search is listings only; Trader search; the Menu (2026-09-25)

Every bug fix has a regression test that failed on the old code (the
search and feed tests were run against the old Home in a separate
worktree; each failed for the bug it names).

## Home search: listings only

Home's search box used a `SearchDelegate` that searched listings and
traders together. It is now `ListingSearchScreen`
(`flutter_app/lib/screens/listing_search_screen.dart`), listings only, on
the constellation background. Bugs in the old search:

- **The keyboard closed mid-word.** Every live search ended in
  `showResults()`, which unfocuses the field; tapping the field to carry on
  searched again and closed it again.
- **Old answers replaced new ones.** A slow response for "ip" overwrote the
  results for "iphone". Each query is now its own grid.
- **Half-typed words filled the history** ("iph", "ipho"...). Only a
  submitted search, or one whose result was opened, is remembered
  (`services/search_history.dart`), and duplicates differing only by case
  are merged.
- **"Clear" didn't clear** the recent searches on screen.
- **A failed request read "No listings for ..."**; it now offers a retry.
- **Every keystroke called `/auth/search`**, which returns whole user
  records - email and phone included.
- Results are paginated, counted, and sortable (best match, newest, price).

Server side (`api/core/text_search.py`): every word of a search must match,
in any order, in the title, category or description ("samsung a54" finds
"Galaxy A54 (Samsung)"); title matches come first in the default order;
`%` and `_` are no longer wildcards (a search for "_" matched every
listing). The location filter escapes them too.

## Trader search

On the Traders screen, through `GET /traders?search=` (business or display
name, never email or phone; at most 100 characters). The unreachable
`/search` "Find Traders" screen, which used `/auth/search`, is removed.

## Home feed

- The untouched price slider sent `max_price=5000000`, hiding every car,
  plot and house above KES 5M. Its top end now means "any price".
- A failed page showed "No listings yet - be the first to post!" and ended
  pagination; it now shows a retry. Same in the Category Zones.
- Featured listings were pinned above a price sort; only the default order
  pins them now.
- "Newest" sent the ranked order. Relabelled "Top ranked", and "Newest" is
  the real newest-first order (the Zones' "Most Recent" had the same bug).
- A stray Seller Dashboard button sat inside the location filter dialog.
- The filter button shows a dot while any filter applies; the panel has
  "Reset filters".

## Category Zones, Traders, Stores: a search box you can read

`widgets/broka_search_field.dart`: 50-54px tall with 16px text (was 42-44px
and 13px). A Zone's result count can no longer be set by a previous
search's slower answer.

## The Menu (was the Profile tab)

`screens/menu_screen.dart`: a profile card (active listings, deals,
rating), Selling (Seller Dashboard or Become a seller), Online store
(`features/stores/presentation/widgets/menu_store_section.dart`: status,
link, products, 7-day visits and shares, Manage / Preview / Share; or what
a store is and how to open one - shown to buyers too, as the setup wizard
takes them), Account (Settings, payment receipts, help) and Sign out.

- **Profile** (`screens/profile_screen.dart`) is just the profile now. Its
  "Listings" and "Traded" figures read fields `/auth/me` never sent - always
  0; Listings is the real active count and Traded is gone. A profile photo
  stored as a BROKA image URL crashed the screen (`base64Decode` of a URL).
  A rating shows "New" until a deal is rated.
- **Settings** (`screens/settings_screen.dart`): language, location
  visibility (it always opened as ON, whatever the account said; a failed
  change is now undone and explained), notifications (opens the phone's
  settings - the old switch did nothing), startup sound, and **sign out of
  all devices** (`POST /auth/token/revoke-all`). The "Dark mode" and "coming
  soon" rows are gone.
- **Sign-out revokes the refresh token on the server** - it used to only
  forget it on the phone.

## Other people's accounts are no longer readable

`GET /auth/search` and `GET /auth/user/{id}` returned the full account
record for anyone, to any signed-in user: email, phone, trust score, fraud
flag, admin bit, language and security settings. Search also matched on
email, so "@gmail" listed who had an account with which address.

- Other people get `AuthService._public_user_dict`: name, preferred and
  business names, rating, deals, verification, photo, presence, member
  since - what the chat header, product page and profile screen read. Your
  own id still returns everything (the Seller Dashboard reads its trust
  score and DCR there); DCR and rank are owner-only.
- Search matches name, preferred name and business name, word by word, and
  never lists the caller; the query is capped at 100 characters.
- Coordinates are rounded to two decimals (about 1 km), as "Show my
  location" promises an approximate location, and the business location is
  hidden with it. `distance_km` is measured to that approximate point: the
  caller chooses the viewer coordinates, so a distance from the exact GPS
  fix, asked from three made-up places, pinpointed the user.
- Tests: `backend/tests/test_user_privacy.py` (8 of its 10 failed on the old
  code; the other 2 pin what must not change).

## Noticed, not changed

- `GET /traders` computes `distance_km` from the trader's exact position
  with caller-chosen viewer coordinates, the same pinpointing risk as above.
- Another user's profile screen (`user_profile_screen.dart`) draws
  "Reliability", "Trust Score" and "Response Rate" bars from fields no
  endpoint sends, so they show the rating or a default of 85%. "Trust Score"
  used the owner-only trust score and read 10/10 for nearly everyone; it
  now falls back to the rating like the others.

# Hardening after the 2026-09-25 review; Postgres in CI; repository map (2026-09-25)

Every item has a regression test that failed on the old code. The full
account, with the reproductions, is `REPO_REVIEW.md` section 0.

## Production bugs that only PostgreSQL shows

The backend suite had only ever run on SQLite, which doesn't enforce
foreign keys and accepts timezone-aware values in naive columns.

- **Signup and login returned 500 on Postgres**: the refresh-token row's
  expiry was timezone-aware. Stored as naive UTC now.
- **`audit_logs.actor_id` referenced users**, yet sweeps and payment
  callbacks write `"system"`: the audit insert failed and took the payment
  update in the same transaction with it. No longer a foreign key; existing
  databases drop it on start (`_drop_foreign_key_sql` in `init_db`).
- **`auction_meta.deal_id` referenced deals**, yet a deal-creation retry
  claims the id before the deal exists. Same fix.
- CI now runs the whole suite on PostgreSQL 16 as well
  (`backend/tests/postgres_plugin.py`, job `backend-test-postgres`).

## Security and abuse

- Client addresses: `api/core/client_ip.py`. Behind Render every per-IP
  limit keyed on Render's proxy; now `CF-Connecting-IP` (`CLIENT_IP_HEADER`),
  `TRUSTED_PROXY_HOPS`, or the web storefront's authenticated
  `X-Broka-Client-IP` (`STOREFRONT_API_KEY`). `GET /admin/diagnostics/client-ip`.
- The app no longer stores the account password (and deletes old copies);
  Android backups exclude app data; a refused refresh token returns the user
  to sign-in. Refresh tokens slide (exchanged after 7 days of use); signup
  keeps its refresh token.
- Store visit/share counting: limited by user or real IP, never by the
  body's visitor id; capped per caller per store.
- Idempotency keys scoped to user, method and path.
- Legacy image fields accept only inline images or the user's own BROKA
  image URLs.
- Request bodies capped at `MAX_REQUEST_BODY_MB` (32).

## Reliability

- An image header declaring a giant canvas is a 422 (was a 500), and one bad
  legacy image no longer stops every media backfill pass; a lost
  compare-and-swap no longer breaks the rows after it.
- Uploads nothing used are removed after 7 days (`api/domains/media/cleanup.py`,
  `media_assets.attach_state`); 300 uploads per user per day.
- A paused store's product links redirect to the store; unverified business
  emails are shown only to the owner.

## For coding agents

`AGENTS.md` (+ `CLAUDE.md`, `GEMINI.md`) and `graphify.md`, generated by
`scripts/graphify.py` and kept current by the `repo-map` CI job.

# Deal lifecycle, fake metrics, store explainer (2026-09-17)

## The last of the fabricated numbers

- **"80% of your deals"** shown to a seller with ZERO completed deals. That
  is §3.2's Bayesian prior - a sensible starting estimate - presented as
  "a strong track record buyers can see". Now gated on
  `completed_deals > 0`, with 1-9 deals marked provisional, since the
  smoothing still dominates the figure there.
- **"+12% vs last week"** was hardcoded. Nothing computes a week-over-week
  delta; the snapshot table will support one once it has two weeks in it.
  Replaced with the count, which is a fact.
- **"SELLER 4.0"** removed - a version number taking the line under the
  title on every dashboard screen.

## Pending deals: the fairness problem

`status == agreed` counted every open thread as the seller's backlog.
That punishes a seller for:

  * a buyer who asked one question and vanished,
  * a buyer who found it cheaper elsewhere and never said so,
  * and a competitor who worked out that opening threads on a rival's
    listings costs them ranking.

**Most of this needs no AI.** The brief proposed model classification on a
message-count or elapsed-time trigger; that is the right shape for the hard
cases and the wrong tool for the common ones. The message record already
answers the question that matters - who spoke last, and how long ago. If the
last message was inbound and unanswered, the seller is the blocker. If the
seller spoke last, the buyer is. That is a timestamp comparison: free,
instant, and auditable, which a model's opinion is not.

So `deal_lifecycle.py` follows the shape `negotiation_actions.detect_action_fast`
already established - resolve what is cheap, reserve the model for the
remainder. `needs_model_review` fires only when both parties are recently
active with no escrow, there are 6+ messages, and the deal has not been
reviewed in 24h. Everything else is settled for nothing.

Attribution takes **only (role, timestamp)** - never message content. That
keeps it cheap, testable, and outside the rules governing message bodies.

Verified across nine scenarios: exactly one counts against the seller, the
case where a buyer has genuinely been waiting days for a reply. Sabotage,
ghosting, abandonment, active negotiation and funded deals all correctly do
not. 11 tests, all executed and passing.

Two bugs caught while building it: a seller who replied two hours ago was
being told their buyer had "gone quiet", and funded deals in escrow were
running through message attribution and reported as stalled.

The endpoint now also returns `open_deals` and a per-deal breakdown, so the
screen can say "8 open, 1 waiting on you" rather than implying all eight are
the seller's fault.

## Store recommendation

Card cut to a hook plus a "See how it works" button - the previous version
delivered two paragraphs of pitch inside a card the seller had not asked to
read. The argument moved to `store_explainer_screen.dart`, where someone who
opted in will actually read it, and the card now appears on the LISTING
screen too: a seller staring at one item that is not moving is in exactly
the frame of mind the feature answers.

Copy leads with the problem rather than the feature. "Create an online
store" describes the button; "stop posting one item at a time" describes
what the seller is already tired of. The preview area is a labelled stub
rather than a mock - a fabricated screenshot would set an expectation the
product then has to meet.

## Deal pipeline scrolls

Four stages plus arrows do not fit a phone without squeezing each to ~70px,
where the counts stop being readable. Now on the same drifting rail as the
insights, as one wide sliding unit rather than four reflowing cards - the
arrows only mean anything between adjacent stages.

---

# Price comparison was circular; plus photos, edit limits, receipts (2026-09-17)

## The router priced at KES 30,000 was told it was competitive

The category median was computed from active listings in the category -
INCLUDING the listing being judged. With one listing in the category, the
median was its own price: 0% off, "your price is competitive". The only
thing being measured was the seller's own guess, handed back to them as
confirmation.

Three fixes, and the third is the one that matters:

1. **Exclude the listing itself** from the median.
2. **Exclude the same seller's other listings.** Otherwise anyone sets their
   own benchmark by posting the same item five times - a cheaper attack than
   it sounds.
3. **Require 5 comparables before saying anything at all.** Below that there
   is no benchmark, and inventing one is worse than silence. The screen now
   says "no other listings in this category yet - nothing to compare
   against".

The price term is also REDISTRIBUTED out of the probability when there is no
benchmark, rather than filled with a neutral 0.6. A fabricated 0.6 on 15% of
the score is a fabricated 9% of the answer, and it moves toward "this
listing is fine".

Verified against the exact case: KES 30,000 with no comparables now reports
no delta and no price advice; the same listing against 12 real comparables
at KES 2,000 correctly reads "priced 1400% above similar listings".

## Listing photos

Cover plus the rest, at the top of the insights screen. The screen judged a
listing on views, saves and price without ever showing the thing being
judged - and when the numbers say "20 views, no saves", the photos are
usually the cause. Decoding mirrors product_card exactly, because the two
photo fields have different shapes and getting that wrong is what produced
the "XB" avatar bug.

## Price edits, regulated

New `PATCH /listings/{id}`. Photos are unrestricted; price is not.

- **Blocked outright while a deal is open on the listing.** This is the rule
  that actually protects buyers: a buyer who agreed KES 3,000 yesterday and
  opens the thread to find 3,800 has no reason to believe the next number
  either.
- **Two changes per rolling week, 12 hours apart.** Enough to fix a mistake
  and respond to the market once; a third inside seven days is oscillation,
  which teaches buyers to wait for the next drop instead of buying.

Every rejection explains why, in wording meant to be shown to the seller
as-is - a limit nobody understands feels like a bug. `ListingPriceChange` is
append-only, because the point is that a price which moved cannot un-move.

## Payment receipts

The screen the dashboard button has been promising. '/receipt-history' was
referenced and registered nowhere, so tapping it threw - in the original
too.

Provider-neutral in shape, not just in copy: the API returns generic
`provider` and `reference` fields rather than `mpesa_receipt`, so a payment
over a different rail appears without a client change. The error state also
distinguishes "could not load" from "no payments" - an empty list after a
failed request would tell a seller they have never been paid.

---

# Insights, recommendations, education — and the last of paid placement (2026-09-17)

## Background

Links and nodes brightened (0.13/0.11 -> 0.20/0.16 and 0.42/0.38 ->
0.58/0.42), dashboard intensity 0.55 -> 0.85, and the field added to the
listing insights screen, which had none.

The command header's gradient had two TRANSLUCENT stops, so stars drifted
through the middle of the card and the seller's name sat on top of them.
`BoxDecoration` asserts `color == null || gradient == null`, so an opaque
base cannot simply be added underneath - the tint had to be flattened into
the stops with `Color.alphaBlend`. Same appearance against a plain
background, fully opaque against the field. The constellation belongs in the
gaps between sections, not inside them.

## Zeno insights: a way out of the rail

A drifting rail is right for a glance and wrong for a seller who has decided
to read them - waiting for a card to come round, or swiping back because one
went past, is a poor way to read twenty things. "See all 21" opens the full
list at the seller's own pace.

New card: showing the item on a video call instead of the buyer travelling
to see it. That is what the feature is for, and nothing in the app said so.

## Recommendations

Third panel, after the two diagnosis ones. "Working for you" and "needs
attention" say what the numbers ARE; this says what to do about them and
which part of the app does it - an instruction without a mechanism is a nag.

The online store is always last and always present. Not an upsell - it is
free. The copy leads with what the seller gets rather than what the platform
wants, because here they are the same thing: a store link shared on WhatsApp
status is the seller advertising their own business, and that it also brings
their audience to BROKA is a consequence, not the pitch. Leading with the
platform's interest would be both less persuasive and less honest.

## Charts on day one

Six cards reading "No history yet" taught a new seller nothing - but the
numbers exist from day one, and the BANDS are useful immediately regardless
of history. Charts now plot today's value against them with "Tracking starts
today". No trace is drawn: a horizontal line would read as "stable", which
one day cannot support.

## Learn how BROKA works

New screen. Escrow, completion rate, response time, rating, credibility,
ranking, the store, and calls - each in plain language with no statistics,
because the moment a number appears someone has to keep it honest.

It exists because everything on the dashboard assumes the seller already
knows what DCR is. A number nobody understands is a number nobody acts on: a
seller who does not know that off-platform deals cost them ranking has no
reason to stop, and every metric on the screen is then decoration.

## Paid placement: the last two

`_buildProductFeaturedCTA` and a "Renew" button survived the earlier
removal - the same mechanic, one screen deeper. Both gone. Leaving them
would have contradicted the explainer two taps away that says position
cannot be bought.

Caught while removing them: my first edit left the parens unbalanced (a
`PressableScale(` wrapper removed without its closer). Fixed, and the
delimiter check against the unmodified original is what caught it.

## Flagged, not fixed

`/receipt-history` is referenced by the Payment Receipts button and
registered nowhere - in the original too, so it is pre-existing. Tapping it
throws. It needs either a screen or the button removed; both are decisions
rather than fixes.

---

# Constellation background on the seller dashboard (2026-09-17)

The same ambient field the Zeno and negotiation screens use, now behind the
whole dashboard.

**Wrapped around the Scaffold, not placed inside `body`.** Inside the body
it would stop at a hard line under the tab strip, which reads as a panel
rather than as depth. Wrapping runs it behind the app bar and tabs too, so
it is continuous from the status bar down.

**Not `extendBodyBehindAppBar`.** That was the first attempt and it is the
obvious-looking one, but it makes the body start at y=0 - so the first card
of every tab hides under the app bar unless each scroll view gets manual top
padding matched to the bar height, on three tabs with different scroll
widgets. Wrapping gets the same look with the layout untouched.

**App bar is translucent (0.55), not transparent.** The title and tab labels
need a stable surface to stay legible against a field that moves under them;
fully clear would leave them sitting on whatever node happened to drift
past.

**Intensity 0.55 rather than the chat screens' 1.0.** There the field is the
only thing on a near-empty surface. Here it sits under dense cards, charts
and numbers, and at full strength the nodes compete with the data -
particularly the trend lines, which are thin strokes in the same blue. The
parameter scales both link and node opacity, so this genuinely dims it
rather than being decorative.

Inherits the keyboard fix from earlier: the field paints against the window
size inside a ClipRect + OverflowBox, so it crops rather than rescaling.

---

# CI: two Dart errors, both mine (2026-09-17)

First build with the Phase 1-4 Flutter work. `flutter analyze` found exactly
two errors; the rest of its output was pre-existing warning noise, which the
workflow already tolerates (`--no-fatal-warnings --no-fatal-infos`).

## 1. A mangled escape in seller_insights.dart:170

    'Check your trend, not today\\'s number'

Backslash-backslash-apostrophe: Dart reads the `\\` as an escaped backslash
and then the `'` terminates the string, so the rest of the line became code.
One bad apostrophe produced eleven cascading errors - undefined name 's',
undefined name 'number', a String passed where a Color was expected, and an
unterminated literal.

The escape was doubled by the generator that wrote the file. Fixed by
switching to a double-quoted string, where the apostrophe needs no escape at
all: an escape that has to survive a generator is an escape that will be
mangled again.

## 2. `_insightCard` defined twice

The new insight card builder collided with the AI-era one, which took named
parameters and was left behind when the section above it was replaced. Its
39 lines are gone, along with a stale `// Global Zeno Analysis` header
pointing at a widget that no longer exists.

## Cleaned while in there

`_staticTips` was the dead fallback list behind the old AI insights. Two
reasons to remove it beyond being unused: it still advertised "Get
verified", which no longer exists, and every entry quoted a multiplier
nobody measured - 4x more views, 60% better deal chances, 3x more deals. The
replacements in `data/seller_insights.dart` state mechanisms the platform
actually applies rather than statistics it cannot support.

Also dropped the now-unused `models/models.dart` import.

## Guarding the next round

Added a static pre-check over the changed files for the two classes that
just failed - mangled string escapes and duplicate member definitions in a
class - plus unreferenced local imports. It runs clean now. It is a grep,
not a compiler, so it catches these shapes and not much else; the real fix
for the Dart side is still a Flutter job that can actually build.

---

# Dashboard: merit over money, and no AI where it earned nothing (2026-09-16)

## Zeno Live Analysis is gone

It asked the model for dashboard tips on every load and every refresh tap,
and returned generic marketplace advice - price against a benchmark, get
your first deal - because it was never given the seller's objectives, plans
or constraints. It assumed what the seller needed to know and billed for the
assumption, on a $2 balance.

Removed with it: `_loadZenoGlobal()`, its two state fields and its call
site. A real advisory conversation - one that knows the seller's goals and
can be reasoned with - is a separate, deliberate feature and these cards
never pretended to be it.

## Zeno Insights: same section, no model

20 fixed cards in `data/seller_insights.dart`, each explaining a lever the
seller controls and the consequence the platform actually applies, so they
stay true for whoever reads them - which is the guarantee generated advice
could not make.

They are also the monetisation argument. BROKA earns when deals settle
through escrow; so does the seller, because completion rate lifts rank, rank
lifts listings, and visible listings close faster. "Route this through
BROKA" and "get more buyers" are the same instruction, so none of the cards
has to nag.

Presented on a self-scrolling rail (~22px/sec) with Zeno's avatar in the
header. Twenty cards behind a swipe are twenty cards nobody reads. Touching
it stops the drift permanently for that visit - content that keeps moving
while you are reading it is worse than static content - and reduce-motion
stops it starting at all.

## Pay-to-win removed

"Get Verified Badge" and "Feature a Listing" are deleted. Both sold
position, which is incompatible with everything else on the screen: there is
no reason to work on completion rate or reply speed if a listing can be
pinned to the top for KES 99, and no reason to earn trust if a badge can be
bought. Rank comes from DCR, response time and credibility - all earned -
and a paid bypass would have made every number above them decorative.

One of the new insight cards says so out loud: "There is no paid placement
on BROKA."

## Credibility score

New, `seller_rating.credibility_score()`. Track record rather than current
form: DCR 0.55, tenure 0.30, volume 0.15, saturating at two years.

Deliberately the inverse of the Overall Rating's treatment of tenure, which
damps it to 0.05 so longevity cannot carry a bad seller. Here it is heavy,
because "has traded here two years" is exactly the evidence credibility
asks about and a Sybil account can fake a week, not a year. DCR still leads
by more, so a two-year seller who routes everything off-platform (6.1) still
loses to a careful six-month account (7.4).

## The radar is a triangle now

Four axes became three, all earned: completion, rating, credibility.

The two that went were not carrying anything. "Deals" was a made-up
saturation curve over the deal count; "Trust" was the raw trust_score, which
is 0-100 on the backend and clamped to a flat 10/10 for every seller above
6. Three real numbers beat four where one is invented and another is broken.

Animated: the shape sweeps out from the centre on load, vertices glow on the
dashboard's existing pulse controller rather than a second rhythm of its
own, gradient fill, and each score printed beside its label so the shape
need not be read against a grid to mean anything.

## Provider-neutral receipts

Six strings said "M-Pesa" where they meant escrow. Airtel Money and anything
added later settle into the same escrow, and naming one provider in the UI
makes the others look unsupported.

---

# Seller brief complete: the listing screen (2026-09-16)

`screens/listing_analytics_screen.dart`, route `/listing-insights`, reached
from a "View insights" button on every card in the dashboard's Products tab.

Answers a different question from the dashboard. The dashboard says "how am
I doing", which a seller can rarely act on today; this says "what is wrong
with THIS one", which they can. A seller seeing 180 views, 22 saves and
nobody asking knows the price is the problem and can change it in thirty
seconds.

Contents: chance of selling with its five component bars (views / saves /
buyers asking / your service / price), raw counts, saves-per-view, price
against the category median, what-to-fix advice, and three trend charts.

Two deliberate choices:

**Negatives sort above positives**, unlike the dashboard. Someone opening
one listing is looking for the fix; someone opening the dashboard is taking
stock.

**The headline says how much to trust itself.** Below 60% confidence it
reads "early estimate" or "still firming up" beside the number. A listing
posted this morning does not have a knowable answer, and presenting a
confident figure built on four data points is how a seller drops a price
that was never the problem.

## Caught before packaging

`models/models.dart` IMPORTS `listing.dart` rather than exporting it, so
`import '../models/models.dart'` would not have brought `Listing` into
scope. Every other screen imports `models/listing.dart` directly; this one
now does too. Would have been a compile error rather than a silent bug, but
it would have been found by CI rather than by reading.

## State of the brief

Phases 1-4 done: the rating engine, response-time measurement, the seller
dashboard trends and advice, listing analytics, and the calculator.

Phase 5 (rank, seller of the week/month) is not started — `rank_position` is
already snapshotted daily so the data source exists, but award selection and
prize mechanics are undecided.

Three things stay honest about what they cannot know yet: sell probability
is a stated weighted model, not a fitted one; `category_sell_rate` always
falls back to 0.35 because no listings have resolved; and per-category
market demand is not computed anywhere. All three need outcome data that
only accrues with use - which is the same reason the snapshot tables shipped
first.

---

# Seller metrics Phase 4: listing analytics + a calculator that calculates (2026-09-16)

## Most of the data already existed

Likes are `Wishlist` and interested buyers are `Interest`, both timestamped,
so both are reconstructable. Only per-listing view history was missing -
`Listing.views` is a bare running counter - so `ListingMetricSnapshot` ships
now and starts accruing. It stores the CUMULATIVE count, not a daily delta:
a delta written directly would be wrong for any missed day, attributing two
days of traffic to one with nothing downstream able to tell.

## Sell probability

A transparent weighted model, not a trained one - there is no outcome data
to fit yet, and the honest version today is one whose every term can be
explained to the seller, which is also what makes per-listing advice
possible.

Commitment (buyers asking about availability) carries the most weight:
asking costs effort and exposes the buyer to a reply. Price fit is
deliberately asymmetric - 30% over the category median is a real obstacle,
30% under is not a symmetric advantage but the seller leaving money behind,
and a score that rewarded it without limit would push every listing toward
the floor.

Same shrinkage as the seller rating: 3 views and 1 like is a 33% like rate
that naively reads as extraordinary demand. Shrunk toward the category base
rate, it reports 38% instead of ~90%.

## Two bugs caught while building

**`Listing.status == "active"`** - status is an Enum column. Comparing it to
a bare string matches nothing on Postgres while quietly working on SQLite,
so this would have produced an empty snapshot table in production and a
green suite locally.

**The calculator's `%` was infix.** "3500*15%" returned Error - the single
commonest question a trader has, what is 15% off. Now postfix: 15% becomes
0.15, so 3500*15% is 525 and 3500-3500*15% is 2975. 13/13 arithmetic cases
verified against a faithful port of the shipped Dart.

## The calculator

Replaced. The old one asked for average price, monthly volume, conversion
rate, profit margin and per-unit acquisition cost - five inputs, four of
which a market trader does not track and cannot answer honestly, and a
projection built on guessed inputs is a guess with a chart around it. Its
defaults gave it away: KES 49.99 average price and 1,200 units, which is
nobody selling sandals in Juja.

What a seller needs mid-negotiation is arithmetic. So: a plain calculator,
with %, correct operator precedence, and live results as you type.

Removed with it: five state fields, three TextEditingControllers and five
derived getters, plus their dispose call.

---

# Seller dashboard Phase 3: trends + the advice bot (2026-09-16)

## Six banded trend charts

`widgets/factor_trend_chart.dart` — one metric over time, two dashed
thresholds cutting the plot into good / acceptable / poor regions, as in the
sketch. The bands are the point: a bare line answers "am I going up", the
bands answer "is this OK", which is the question a seller actually has. 82%
means nothing until you know the platform expects 90.

Direction is an explicit per-chart flag, not inferred. Green on top for
rating, DCR and completed deals; green at the BOTTOM for response time, rank
position and pending deals, where smaller is better. Verified the geometry
both ways, including the case where every value sits below the poor line —
the threshold lines still render, or a struggling seller would see no
context at all.

Straight segments rather than a spline: a curve invents values between
snapshots that were never measured, and on a chart whose job is honesty
about a trend that is the wrong trade. Fewer than two real points says so
instead of drawing a flat line, which would read as "stable" — a claim one
day cannot support.

## The advice bot is deterministic, deliberately

`domains/trust/seller_advice.py`. Zeno cannot see a trend: it would receive
today's numbers and infer a direction it has no evidence for, then phrase
the guess fluently — worse than phrasing it badly. It is also billed, on a
$2 balance, for what amounts to a handful of comparisons.

So: rules over snapshot deltas 7 days apart, every card citing a number the
seller can check. Three constraints on each — provable, actionable, honest
about direction. A negative is never softened into a positive; a panel that
only shows green teaches nothing.

Caught while testing: a falling DCR fires both the trend rule and the
absolute rule, saying the same thing twice in different words and costing
one of four slots that should hold a different problem. Same for response
time. Both now dedupe.

Also pinned: rank improvement is a DECREASE (#12 beats #19). Every other
metric improves by going up, so the sign is easy to invert — and inverting
it would congratulate a seller for sinking.

9 advice tests, all executed and passing. Backend compiles; privacy guard
still passes. Dart checked structurally — no toolchain here.

## Next

Phase 4: the per-listing screen (views, likes, like/view ratio, interested
buyers, price vs market, sell probability). Needs a likes table and
per-listing view history first, neither of which exists yet.

---

# Seller metrics Phase 2: response time is measured (2026-09-16)

## The placeholder is gone

`completion_rate.py` scored every seller's response term at a hardcoded 0.7
from the day it was written. That was 15% of `rank_score` - which orders
listings for every buyer - and 25% of the new Overall Rating. Identical for
everyone, so a sixth of the ranking signal carried no information at all:
sellers who answered in minutes and sellers who never answered ranked the
same on the term that was supposed to separate them.

## No new instrumentation, and it works retroactively

Every message already carries listing_id, buyer_id, role, recipient_role and
created_at. A response time is the gap between a message the seller owed an
answer to and their next message in that thread, so the whole metric comes
out of history that already exists - meaning it measures each account from
its first day rather than starting at zero on deploy.

## The trap it is built around

Measuring only ANSWERED messages gives a seller who ignores everyone no
response time, and "no data" sorts better than "slow". The seller who
replies in three days would look worse than the one who never replies -
exactly backwards. Unanswered inbounds are counted as censored observations:
time-so-far, capped at 48h, which is a lower bound on the true wait and the
honest figure to use when it is the seller's own silence producing it.

Three more rules, each with a test:

- A Zeno relay addressed to the SELLER starts the clock; one addressed to
  the buyer does not, or every relay would time a seller against a message
  they were never shown.
- Five buyer messages in a row is one wait, not five - otherwise the seller
  is punished for the buyer's typing habits.
- Median over 30 days, minimum 3 observations, NULL below that. One
  forgotten thread should not define a month, and "unmeasured" has to stay
  distinguishable from "fast".

Found while testing: a fixture sharing listing ids across sellers
interleaved their threads and scrambled attribution entirely. Listings are
seller-unique in production, but it is a sharp edge worth the comment it now
carries.

## API

`GET /listings/seller/{id}/metrics?days=90` - current standing plus the
daily history series. Own metrics only: response time, backlog and rank
position are competitive information, and rank tells a rival exactly how far
they have to climb. Returns the rating's component breakdown too, which is
what lets Phase 3's advice panel cite a cause rather than guess one. Missing
days are omitted rather than zero-filled - a gap is honest about a job that
did not run; a zero is a false claim.

8 new tests on response time, 12 on the rating. Privacy guard still passes
with the new message query, which is marked and reads no content.

---

# Seller dashboard Phase 1: the metrics engine (2026-09-16)

Working from Design Journal Vol. 8 §3.1-§3.3 and Part XVI. Phase plan in
SELLER_METRICS.md; this is the engine every later phase reads from.

Found already built and correct: §3.2's Bayesian DCR (Prior_mean 0.80,
Prior_weight 5, 45-day half-life) and the §3.4 rank score. Built now: the
§3.3 confidence factor, the Overall Rating, and daily history snapshots.

## The Overall Rating

DCR 0.45, response 0.25, volume 0.15, backlog 0.10, tenure 0.05. Tenure is
smallest and saturates at six months, per the brief.

Two corrections during construction, both of which reintroduced the bug the
module exists to fix:

**Collapsing evidence and quality scored a Sybil farm 8.1/10.** One
confidence factor meant a farmed record got *shrunk toward the neutral
prior* - the prior was protecting it. Split: thin evidence shrinks toward
neutral, bad quality multiplies down. Farm now 2.5.

**Anchoring unproven sellers at 8.0 put a newcomer above the veteran.**
§3.2's Prior_mean rescaled looked right and was wrong - DCR's prior answers
"will they complete a deal", but this composite also contains volume and
tenure that a new seller genuinely lacks. Anchor is 6.5.

**A raw uniqueness ratio punished repeat customers.** 88 deals across 70
buyers is 18 people coming back. Gated at 50% distinct instead.

12 tests pin each fairness claim; all 13 assertions verified against the
shipped module.

## Snapshots ship first, deliberately

DCR is recency-weighted on a 45-day half-life, so yesterday's value is not
reconstructable. Rank position depends on where every other seller stood
that day. Every day the job does not run is a permanent hole in a graph. So
the table and the nightly writer land now and accumulate while the screens
are built.

`median_response_min` writes NULL rather than a placeholder - a flat line at
an invented value is indistinguishable from a real trend.

## Blocker for Phase 2

Nothing measures response time. `completion_rate.py` has used a hardcoded
0.7 for the response term since it was written and says so in its own
docstring - so 25% of the new rating and 15% of ranking currently run on a
constant. Response time is the lever the brief leans on hardest and the one
a seller can move today; it needs real measurement before the dashboard can
honestly show it.

---

# DeepSeek V4.1-Flash, from the official announcement (2026-09-15)

Now working from DeepSeek's own 2026-09-10 page rather than a summary of it,
which corrected one thing and unlocked another.

## Correction: the model string is `deepseek-flash`

Last round I set `deepseek-v4.1-flash`. **That string appears nowhere in
DeepSeek's documentation.** Their announcement says plainly: "Set your model
to `deepseek-flash`."

The versioned aliases are explicitly a shim, not an API - "deepseek-v4-flash
and deepseek-v4-flash-vision-exp TEMPORARILY route to V4.1-Flash." Pinning a
temporary alias means the pin outlives the routing and starts 400ing on a
day nobody chose. So neither the old string nor my guess was right; the
unversioned one is.

Worth noting the 400/404 branch added last round would have caught this -
`DeepSeek rejected model='deepseek-v4.1-flash'` at ERROR, instead of a
silent fallthrough to OpenRouter with the bill quietly moving. It just
should not have needed to.

## Unlocked: Zeno can see photos again

V4.1-Flash ships "native visual understanding". That closes the gap found
last round, where `image_base64` reached `_call_gemini` and nothing else -
so on a Gemini-less deployment the photo was discarded and Zeno answered as
though the user had sent plain text.

`_call_deepseek` now attaches the image to the last user turn using the
OpenAI multimodal content-parts shape, since that endpoint is
OpenAI-compatible throughout. `_call_ai` passes `image_base64` through to
it, and the "I cannot see it" prompt injection now fires only when NEITHER
vision provider is configured.

This is the feature the whole route-ordering saga existed to protect - the
legacy `/negotiate/chat` is mounted first precisely because "only the legacy
implementation supports image attachments". It has a working provider behind
it for the first time on this deployment.

The exact payload shape is the one uncertainty left. If DeepSeek wants
something other than `image_url` parts the request returns 400, which is now
logged by name and falls through - the photo is lost, which is where it was
before, not worse.

## Gemini stays exactly where it is

Untouched and still first in the chain. It takes over automatically the
moment `GEMINI_API_KEY` is set - no code change needed then - and the
startup log now says so rather than implying vision is missing:

    [ai] GEMINI_API_KEY unset - DeepSeek(deepseek-flash) is the primary
         model. Gemini remains first in the chain and takes over
         automatically once a key is set (best multilingual coverage for
         African languages).

## Operational note

Off-peak API rates are 50% of peak. Nothing in the code schedules around
that, but on a small prepaid balance it is the largest lever available
without touching a line.

---

# Running DeepSeek-only: what that actually means (2026-09-15)

Learned this session that there is no Gemini billing account, so
`GEMINI_API_KEY` is unset and **DeepSeek has been the model powering Zeno
all along** - on a $2 prepaid balance. The code is written Gemini-first with
DeepSeek labelled "Fallback 1", which describes a deployment that does not
exist here. Three consequences, none of them visible before.

## 1. Zeno cannot see photos, and does not say so

`image_base64` is only ever passed to `_call_gemini`. With no Gemini key
that block is skipped entirely, the image is discarded, and Zeno answers as
though the user sent plain text - confidently, about nothing, because it
never saw anything.

This is the exact capability the route-ordering guard exists to protect:
the legacy `/negotiate/chat` is mounted first specifically because "only the
legacy implementation supports image attachments". The path is wired end to
end, tested, and fought over — and inert in the live configuration.

Not fixable without a vision provider, so it is now honest instead: when an
image arrives and no vision-capable provider is configured, the system
prompt tells the model it cannot see it and to say so plainly and ask for a
description. A confident non-answer becomes an accurate one.

(If the multimodal claim for V4.1-Flash holds, this closes properly by
routing images down the DeepSeek path. Still unverified - worth checking,
because it would restore a feature that is currently dead.)

## 2. Credit exhaustion was a WARNING among transient failures

DeepSeek returns **HTTP 402 Insufficient Balance** when the prepaid balance
runs out. That had no branch of its own: generic bucket, WARNING level,
falls through to OpenRouter's free tier - which answers. Nothing visibly
breaks. Zeno keeps replying on a different model and the only symptom is
that the answers quietly get worse.

On a $2 balance that is not a warning, it is *the* event. It now logs at
ERROR, names both models, and says where to top up.

## 3. The startup log now states the chain that is actually live

Every step is key-guarded, so what runs depends entirely on which env vars
are set, and nothing said so out loud. An operator reading the code sees
"Primary: Gemini" and reasonably assumes that is what answered - then asks
every question about latency, cost and output quality about the wrong model.

On this deployment it now prints:

    [ai] live provider chain: DeepSeek(deepseek-v4.1-flash) -> OpenRouter(nvidia/nemotron-3-ultra:free)
    [ai] GEMINI_API_KEY unset: DeepSeek(...) is the primary model, and image
         analysis is UNAVAILABLE

## Worth knowing about the cost work

`AI_AUDIT.md`'s cost controls cut *classifier* calls ~60% and deliberately
left the two prose calls users read untouched, on the reasoning that
classifiers are the cheap-to-degrade ones. That reasoning assumed a frontier
primary with a cheap fallback beneath it. With DeepSeek as the only paid
provider the ratio shifts - `prefer_cheap` now routes classifiers to the
same model serving the prose, so the saving is smaller than the audit
implies. Not changed; flagged, because a $2 ceiling makes the number matter.

---

# DeepSeek: V4-Flash -> V4.1-Flash (2026-09-15)

`DEEPSEEK_MODEL` default changed in all six places it appeared:
`routers/negotiate.py`, `core/config.py`, `.env.example`, the two tests that
pin the string, and the stale comments in `negotiate.py` and
`ai_broker/service.py`. Still env-overridable; nothing else in the call path
changed.

## The change is probably cosmetic, and still worth making

DeepSeek reportedly routes `deepseek-v4-flash` calls to V4.1 automatically,
so the runtime behaviour may already be V4.1 regardless. Pinning it
explicitly is right anyway: config that names the model you are actually
getting is the difference between a deliberate choice and a coincidence
that survives until the provider stops redirecting.

## The real risk, and what was done about it

Neither string has ever been verified end to end. CHANGES.md:1637 records
that whoever set `deepseek-v4-flash` could not confirm it existed, and the
tests only assert the string is passed through - not that the API accepts
it. Switching to a second unverified string doubles that exposure.

The failure mode is what makes it dangerous. A rejected model name returns
**400**, which fell into the generic `!= 200` branch, raised, was caught
upstream, logged at WARNING among ordinary transient failures, and fell
through to OpenRouter - which answers normally. From the outside a wrong
model string is indistinguishable from `DEEPSEEK_API_KEY` being unset: both
mean DeepSeek never replies, the bill goes to the fallback provider, and
nothing says why. The whole point of putting DeepSeek in that slot was
latency and cost; both are silently lost.

400 and 404 now get their own branch, logged at ERROR, naming the model,
saying the config is likely wrong, and naming the provider the traffic is
going to instead.

## How to confirm the switch actually took

Grep production logs after deploy:

    "Using DeepSeek fallback (deepseek-v4.1-flash)"   <- attempted
    "DeepSeek rejected model="                        <- name is wrong
    "Using OpenRouter fallback"                       <- what it cost you

If the first appears and the third does not follow it, the switch is live.

## Unverified claims

The performance and pricing figures quoted for V4.1 (asymmetric MoE, CSA2,
FP4 KV caching, ~60% cached-input price drop) are past this session's
knowledge cutoff and were not independently checked. They do not affect the
code - the only thing the codebase asserts is a model string - but they are
worth confirming against DeepSeek's own pricing page before any capacity or
cost planning leans on them.

One claim WOULD matter if true: native multimodal support. `/negotiate/chat`
accepts `image_base64` and that path currently depends on Gemini. If V4.1
handles vision natively, image requests could use the same fallback chain as
text instead of failing over. Not built - it needs verifying first, and a
wrong guess there degrades Zeno's photo analysis silently, exactly like the
model string does.

## Timeout left alone

DeepSeek keeps its 15s timeout against 25-30s for the others. If the
speculative-decoding claims hold, it has more headroom than before, not
less.

---

# Seller dashboard: UI pass (2026-09-15)

Scoped to the seller dashboard. The motion system from the previous entry is
the vocabulary; this is the screen that uses it.

## Loading

The method was named `_buildLoadingShimmer` and was a centred spinner. A
spinner says "something is happening somewhere" and leaves the page empty,
so the entire layout appeared at once when data landed and everything
jumped. Replaced with a real skeleton in the shape of the Overview tab -
command header, stat pair, chart, pipeline, insight card - so the page is
already the right shape before the data arrives. Same wait, shorter-feeling,
and nothing moves when it ends.

## Choreography

Eleven stacked sections arriving simultaneously gives the eye no order to
read them in. Each Overview section now enters on a 45ms cascade, capped at
8 beats so the tail of the page is never held behind an animation the user
has not scrolled to. Products list staggers the same way, with the header
counting as the first beat so the first card follows it rather than arriving
beside it.

## Numbers arrive instead of appearing

`_CountUpText` animates the leading number of an already-formatted string
and leaves prefixes, suffixes and separators alone - so it never needs to
know each caller's formatting rules, and a value it cannot parse (the "—"
placeholder for absent data) renders as given. Verified against every format
the screen produces: `1.2K`, `KES 4500.00`, `87%`, `5.0/10`, `—`.

Keyed on the value, so a refresh that changes a figure animates to the new
one rather than restarting from zero.

A dashboard's whole job is its numbers; having them count up is what draws
the eye to them in the order they matter.

## Press feedback everywhere

15 tappables were `GestureDetector` + `Container` with no feedback between
the tap and the result - on a slow connection that reads as a dead button
and gets tapped again. All 15 are now `PressableScale`. Checked first that
none of them used a gesture callback `PressableScale` lacks, so the swap
cannot silently drop a handler.

## Two bugs the pass turned up

**The Deals refresh spinner was lying.** `onRefresh` ran an un-awaited loop
over every listing, so `RefreshIndicator` dismissed the instant the gesture
ended while up to 100 requests were still in flight. "Refreshed" appeared
before any data came back. Now `_loadStatuses`, which batches at 6 and
returns when the work is actually done.

**`_miniStat` labels were unreadable.** `textLow` on the dashboard
background is the same 1.88:1 failure found in the message receipts.
Moved to `textMid` (7.33:1).

## Reduce-motion

Every piece above degrades to a plain cut or a static block when the OS
reduce-motion switch is on - the cascade, the count-up, the press scale and
the skeleton sheen.

---

# UI foundation: a motion system, page transitions, shared elements (2026-09-15)

Started with a survey rather than a restyle, and it changed the plan.

The app already runs **76 AnimationControllers** across 13 screens. It is
not short on animation — it is short on agreement. Every screen picks its
own durations and curves inline, so two cards fading at 200ms and 350ms
beside each other read as jank rather than as style, and none of the motion
says "BROKA" because no two pieces of it move the same way.

Two things were conspicuously absent:

- **Zero `Hero` widgets in the entire app.** Tapping a product cut to a new
  screen and re-decoded the same photo from scratch, so the one image the
  user was looking at visibly vanished and came back.
- **No `pageTransitionsTheme`.** Every route used the bare platform default
  except three hand-rolled PageRouteBuilders — navigation looked like a
  stock Android app on a product that looks like nothing else.

## What landed

**`theme/motion.dart`** — four durations chosen by the SIZE of the change
rather than by screen, three curves with stated jobs (`easeOutCubic`
arriving, `easeInCubic` leaving, `easeOutBack` for accents only — overshoot
everywhere is how an interface starts to feel like a toy), and
`BrokaMotion.reduced()` reading the OS reduce-motion switch. That is not
politeness: vestibular disorders make large slide-and-scale transitions
genuinely unpleasant, and the platform setting is how those users say so.

**`BrokaPageTransition`** — shared-axis rise-and-fade, wired into
`ThemeData.pageTransitionsTheme`. Every existing `Navigator.push` in the app
picks it up with zero call-site changes. 24 logical pixels of travel,
deliberately: a screen transition is punctuation, not a sentence.

**Hero on the product flow** — card photo flies into the detail view, with a
`flightShuttleBuilder` that unrounds the corner during flight so it does not
pop square mid-transition. Tagged by listing id, and only the first photo in
the gallery claims the tag — two widgets with one tag in a subtree is an
assertion failure, not a nicer animation.

**`widgets/motion_widgets.dart`** — three primitives covering most of what
screens were hand-rolling controllers for:

- `FadeSlideIn`, with stagger by list index. TweenAnimationBuilder rather
  than a controller, because a one-shot entrance has no business holding a
  ticker for the life of the screen. Stagger caps at 8 items — without a cap
  item 40 waits 1.8s to appear, which is latency, not polish.
- `PressableScale`. The app's tap targets are mostly GestureDetector +
  Container with no feedback between the tap and the result, which on a slow
  connection reads as a dead button and gets tapped again.
- `ShimmerBox`. A spinner says "something is happening somewhere"; a
  skeleton says "this is what is coming and roughly how much", and stops the
  layout jumping when content lands.

All three degrade to a plain cut under reduce-motion.

## Deliberately not done yet

No per-screen restyle. 25k lines of screen code with no Flutter toolchain
here means a broad speculative visual pass is a lot of Dart I cannot
compile, and the last few rounds have shown what unverifiable UI changes
cost. The foundation above lifts every screen at once and is small enough
to check by reading; the deep visual pass wants one screen at a time.

---

# Seller dashboard: deep review (2026-09-15)

Eight bugs. The worst class: the dashboard showed sellers invented numbers
about their own performance, styled identically to real ones.

## 1. Every seller saw a perfect trust score

`_toTen` guessed the source scale from the value:
`(d <= 5 ? d * 2 : d).clamp(0, 10)`.

`trust_score` is **0-100** on the backend (`fraud.trust_band`: >=80 trusted,
>=50 standard, >=20 at_risk). So every value from 6 to 100 fell through the
else branch and clamped straight to 10. Measured across the real range: a
seller at **15/100 - "high_risk", the band that suppresses their ranking -
was shown 10.0/10.** The one number that would explain why nobody is buying
was guaranteed to say everything is fine.

`_toTen(null)` was worse: null -> 5.0 -> doubled -> 10. A brand new account
opened to three perfect scores.

Each field now converts from its own known scale, and absent data returns
null rather than a flattering default.

## 2. Three metrics read keys the API has never returned

- `response_rate` -> `?? 85.0`. Every seller saw an identical invented
  "85% response", on two separate tiles and as a radar spoke. Removed; the
  slot now shows deal completion rate, which is real and is what the
  platform actually ranks on.
- `reliability_score` -> fell back to `rating`, so the dashboard showed the
  same number twice under two labels and called one of them reliability.
  Now deal completion rate.
- `main_category` -> `?? 'general goods'`. This feeds Zeno's seller
  coaching, a **billed** call whose entire value is being specific to what
  you sell. Every seller was having a generic trader coached about nothing
  in particular. Now `business_category`.

`tests/test_client_invariants.py` gained a contract test that extracts every
`_profile['key']` from the dashboard and asserts the auth service emits it.
It found all three, plus a dead `total_views` read.

## 3. Deal status could never load for the session

The tab listener set `_dealsTabLoaded = true` *before* looping. Opening the
Deals tab during the initial load marked it done against an empty
`_listings` - the loop did nothing, the flag stayed true, and deal status
never appeared again. Every listing showed plain "Active" regardless of what
was in escrow. The flag is now set only after a non-empty run, and `_load`
catches up if the user is already sitting on that tab.

## 4. 100 simultaneous requests

Opening Deals fired `_loadDealStatus` + `_loadBoostStatus` for all 50
listings at once. Now batched at 6 listings in flight.

## 5. Billed AI calls fired in duplicate

Neither Zeno call had an in-flight guard. `_load()` is also the
pull-to-refresh handler, so refreshing three times bought three answers and
displayed the last. The per-listing one cached on *result*, so tapping twice
while it was thinking bought two.

## 6. The funnel mixed populations

`_pipeDone` read all-time `completed_deals` from the profile while the
stages beside it counted current listings - so a seller with history and few
live listings saw COMPLETE exceed LISTED, at over 100%. All stages now count
the same population, and the funnel says "Checked N of M" while status is
still loading instead of letting provisional numbers read as final.

## 7. Catalogue truncated at 50, silently

`_pipeListed` and `_totalViews` derive from the loaded list, so a seller
with more than 50 products saw a truncated business presented as the whole
thing. Raised to 200 with a `_catalogueTruncated` flag.

## 8. Unbounded query parameter

`GET /listings` took `limit: int = 20` with no ceiling - any caller could
ask for `limit=1000000` and have the database assemble it. Now
`Query(20, ge=1, le=200)`, with `offset` bounded too.

## Verification

Backend compiles; the scale bug was quantified against the real 0-100 range
rather than assumed; Dart checked structurally against the unmodified
original. Nothing executed - no Flutter toolchain here. The contract test
and the client invariants run in CI.

---

# Message receipts: make the four states actually visible (2026-09-15)

## The ticks were below the contrast floor

`sent` and `delivered` were drawn in `BrokaColors.textLow` (#2E3D5A) on the
chat background (#03040A). Measured: **1.88:1**, against a 3:1 minimum for a
UI component that carries meaning. The two states a user checks most often
were the two closest to invisible, so the honest four-state ladder built
underneath was being discarded at the last step.

- muted states -> `textMid` (#8A9BBF, **7.33:1**)
- icons 12px -> 15px; a tick is a glyph, not a dot
- double tick spacing 5px -> 7px. At 12px/5px the second check hid behind
  the first, so "delivered" and "sent" differed only by a thickened edge.
- `read` keeps the violet (4.84:1) at +1px, so "seen" is what catches the
  eye when scanning a thread
- every state now carries a `Semantics` label

## `failed` was unreachable

The render site never passed `failed:`, and `negotiation_screen`'s send path
catches errors and leaves the optimistic bubble untouched. So a message that
never left the device showed a clock icon **indefinitely** - the exact
ambiguity this ladder exists to remove, with "still going" and "gone
forever" rendering identically.

`receiptFor` now flips a pending message to `failed` after 20s. Long past a
normal round trip on a slow link, short enough that the user finds out while
they still remember sending it. Worst case it reads "Not sent" and corrects
to a tick when a slow response lands - a recoverable wrong answer, unlike a
clock that never resolves.

Verified against all eight input combinations of the ladder.

## Two things I caught while building it

**No phantom retry.** The failed label started as "Not sent · tap to
retry". Nothing in `negotiation_screen` retries. Promising a retry the app
does not implement would be a worse lie than the silent grey tick it
replaces, so it reads "Not sent".

**No no-op emphasis.** `read` was going to be emphasised with `Icon.weight`.
That parameter only applies to variable icon fonts (Material Symbols); with
the default MaterialIcons font it is silently ignored. It would have looked
like emphasis had been added while changing nothing on screen - the same
failure as `Image.network` on a base64 photo. Emphasis is a size bump, which
renders.

Both are now guarded in `tests/test_client_invariants.py`, along with the
contrast rule.

---

# Privacy enforcement, not another patch (2026-09-15)

Prompted by three bugs landing in the most load-bearing parts of the app:
the map, calls, and message privacy. The common shape is the same in all
three — **the code asserted something it had not verified.** A position it
had not measured. A ringing phone it had not observed. An audience it had
not checked.

## Audit: I scanned every NegotiationMessage read

18 queries across `api/`. One real leak remained beyond the inbox fixed
earlier:

**`disputes.py` arbitration context** loaded every message on the listing —
no buyer scoping, no recipient filter — and passed it to the model whose
written verdict both parties read. Two leaks in one query: other buyers'
threads (a listing keeps one per interested buyer), and Zeno's one-sided
coaching, which is advice given in confidence to one party and should never
shape a ruling against them. Now scoped to the deal's own buyer, keeping
both parties' messages and broker messages addressed to both.

The other 13 turned out to be safe — ids only, counts, or filtered in
Python — but nothing recorded that, so every future reader had to re-derive
it.

## The mechanism: `tests/test_message_visibility_guard.py`

Every `select()` naming NegotiationMessage must constrain `recipient_role`
or carry `# visibility-ok: <reason>`. AST-scanned across `api/`, failing
with file:line, rejecting markers too short to be a real sentence.

Static, not runtime: a runtime assertion only fires on a path someone
exercises, while this fails in CI on a query nobody has called yet.

18 scanned, 4 filtered in SQL, 14 marked, 0 unaccounted for. Plus pinned
tests naming the two surfaces that actually leaked, so a refactor cannot
quietly drop them and leave only a generic failure.

Contract documented in `PRIVACY.md`, including what it does NOT cover: it
checks a constraint exists, not that it is correct, and WebSocket pushes are
outside the scanner.

## Client invariants: `tests/test_client_invariants.py`

The Dart side has no test runner in CI, so a Dart test asserting these is a
test nobody runs. These are text checks on the client source executed by
pytest, which does run. Narrow by design — they cannot verify a map shows
the right position, only refuse three specific expensive regressions:

1. `Image.network` on a `profile_photo` (base64, not a URL — fails silently
   through errorBuilder, which is how "XB" survived a release).
2. The map treating the registration coordinate as the user's position.
3. The call screen claiming a phone is ringing without checking presence.

Plus: both chat screens must register AND deregister with the poller.

The first version of this file failed on its own documentation — the
comments explaining each bug quote the exact strings being searched for.
It strips comments now, which is the small lesson that a grep-based guard
needs to know the difference between code and prose about code.

## Honest limits

The visibility guard is strong: it is structural, it runs on every commit,
and it fails closed on new queries. The client invariants are weak by
comparison — they are greps, and they only know about bugs that already
happened. The real fix for the Dart side is a Flutter test job in CI, which
is a build-infrastructure change rather than a code one.

---

# Inbox privacy leak, stale map position, dishonest ring state (2026-09-15)

## 1. PRIVACY: the seller's inbox showed the buyer's private Zeno message

Reported from a screenshot: the seller's inbox read
**"Clinton Henry - No problem. Shout if you need anything else."** Clinton
never wrote that. Zeno wrote it TO Clinton.

Zeno writes a DIFFERENT message to each side of a relay, tagged with
`recipient_role`. `get_inbox` selected the newest row in the thread with no
such filter, in both the buyer and seller branches - so whichever copy
happened to sort last became the preview for both parties.

`get_history` has always filtered this correctly, and `test_thread_privacy`
covers the AI-context path. The inbox was the third surface reading the same
table and the only one nobody filtered.

**This also explains the missing broker notifications.** Both copies are
written in the same commit with near-identical `created_at`. When the
buyer's copy sorted first, the seller's inbox row never changed to the
seller's own copy - so `GlobalPollerService` saw no new signature and never
fired. One root cause, two symptoms: the seller saw a message meant for the
buyer, and never got told about the one meant for them.

## 2. The map was showing where you registered, not where you are

`ApiService.currentUserLat/Lng` are read from SharedPreferences and written
at REGISTRATION. They never move. A user who signed up in Nairobi CBD and is
now in Juja got a "You" pin on Kenyatta Avenue and "0 m away" - because the
stored point sits next to the seller's stored point.

The map now takes a live fix via `Geolocator.getCurrentPosition` (same
permission dance `home_screen` already uses), without blocking first paint,
and clears the server-computed distance when it lands - that figure was
derived from the same stale coordinate.

## 3. "Their phone is ringing" when the peer is offline

`calling` means our offer is out. It does not mean anyone received it. The
screen asserted a ringing phone regardless, so a caller held the phone to
their ear for 45 seconds waiting on someone the app already knew was
offline. Presence is now passed at dial time: offline shows "Trying to reach
them… / They were last seen offline - they may not pick up", and the avatar
ring stays gold instead of going blue, since blue is the signal that the far
end was alerted. Unknown presence keeps the optimistic label.

## 4. The selfie on the call screen - my bug, not done the first time

Shipped as `Image.network(peerPhoto)`. `profile_photo` is **inline base64**,
not a URL - every other avatar in the app decodes it with `base64Decode`.
So it failed on every call and fell silently through `errorBuilder` to the
initials. From outside that is indistinguishable from the change never
having been made, which is exactly how it was reported. Fixed here and in
the `negotiation_screen` header, which I had broken the same way.

## 5. Notification for a message you are reading

`markScreenActive` / `markScreenInactive` were called from the direct-chat
screen and NOT from the Zeno negotiation room - the screen the report came
from. Reading a Zeno reply left the thread unregistered, so the next 7s
sweep notified about it.

Now registered from both. Two further fixes while wiring it: the skip
records the message signature instead of bare-`continue`ing (otherwise
closing the screen fires a notification for something already read - trading
a notification during reading for one just after it), and the key is
(listing, buyer) rather than listing alone, since a seller has one thread
per buyer on the same listing and suppressing by listing would silence every
other buyer.

## Still open - I could not pin this one down

The "assumption that Zeno has already informed the buyer" needs one more
detail. The relay does write a buyer-directed row (`broker_msg_other`), so
the news does reach the buyer's thread. What I cannot tell from the
screenshots is whether the buyer's copy carried the availability answer or a
generic sign-off, because the two rooms were captured a minute apart either
side of the seller replying. The inbox leak above also means what was
on-screen was not necessarily what each party's thread actually held.

Worth re-checking on this build with the leak fixed. If it persists, the
buyer's thread text at the moment the seller answers is what to capture.

---

# The isolation bug my own test introduced (2026-09-15)

463 passed, 1 failed. The clock fix worked - `test_sweep_sends_sms_when_seller_silent`
and the new `test_sweep_defers_during_quiet_hours` both pass. But
`test_sweep_cancels_when_seller_already_replied` now fails:

    AssertionError: Expected 'send' to not have been called. Called 1 times.
    Calls: [call('+254733111000', "Good afternoon Nudge. Zeno from BROKA:
            Nudge asked me one thing about your **Quiet Hours Phone** ...")]

"Quiet Hours Phone" is the listing from the test I added last round. The
cancellation logic is fine; my test leaked state into it.

## Cause

`set_test_db` and `setup_db` are module-scoped, so every test in this class
shares one database - and `task_check_interest_nudges` is a GLOBAL sweep. It
processes every due interest in that database, not only the one the calling
test created.

That was survivable purely by accident. Each existing test left its interest
terminal: the first sets a deadline five minutes in the FUTURE so the sweep
never touches it, and the next two end sent or cancelled. Nothing was ever
left still-due when the following test swept.

`test_sweep_defers_during_quiet_hours` breaks the accident by design. Its
whole point is asserting that a deferred nudge stays **neither sent nor
cancelled** so a later pass retries it - "deferred" not silently becoming
"dropped". That leftover row was then picked up by the next test's sweep and
sent at the class's pinned 14:00.

So the assertion I added created exactly the condition it was written to
protect, and the next test was the one that noticed.

## Fix

An autouse async fixture clears leftover interests before each test in the
class, so every sweep sees only its own data.

Clearing before rather than cleaning up after is deliberate: a test that
fails partway through cannot then poison the rest of the file, which is the
failure mode that makes a suite's first red test lie about where the problem
is.

`mock_sms.assert_not_called()` stays global. It is the right assertion - a
sweep that texts somebody it should not is worth failing on however the row
got there. What was missing was the isolation that makes it mean what it
says.

Verified by simulating the class in file order with and without the fixture,
modelling due-vs-future deadlines and the quiet-hours window: without it the
fourth test sends "Quiet Hours Phone" and fails, exactly as CI reported;
with it, all four behave.

## Standing note

Two consecutive rounds of failures in this file were both isolation
problems rather than logic problems - first a shared wall clock, now shared
database rows. Anything else in the suite that calls a global sweep against
a module-scoped database has the same shape of exposure and is currently
relying on the same kind of luck.

---

# The suite ran. 462 passed, 1 failed - and the failure was a clock (2026-09-15)

First green-ish run in the project's history: **462 passed, 1 failed, 71.77s**.
Collection completed, every module imported, nothing aborted.

## The route-ordering mystery is settled

All five ground-truth tests passed:

    test_chat_endpoint_is_registered          PASSED
    test_chat_resolves_to_legacy_free_chat    PASSED
    test_chat_schema_is_the_legacy_one        PASSED
    test_ai_broker_own_routes_still_reachable PASSED
    test_collision_still_exists               PASSED

So `POST /negotiate/chat` was registered, routable, bound to
`negotiate.free_chat`, and carrying `negotiate.ChatIn` the entire time.
**Both import-time guards were wrong, and the route they claimed was
missing had never stopped working.** Two CI outages and a suite that could
not run, over a route that was fine.

Demoting the guard to log-only was the right call, and the reasoning
generalises: an assertion that runs at import gets exactly one chance to be
correct and takes everything down with it when it isn't. The same property
asserted in a test cost one red test to be wrong.

## The one real failure: `test_sweep_sends_sms_when_seller_silent`

    AssertionError: Expected 'send' to have been called once. Called 0 times.

Not a regression. `_fire_availability_nudge` calls `is_quiet_hours()` and
defers between 21:00 and 07:00 EAT - correct, deliberate, and documented in
`nudge_templates.py` ("a 3am SMS about a second-hand fridge is not urgency,
it is a nuisance"). The test asserts an SMS *was* sent, so it can only pass
during Kenyan daytime.

The run started at **20:24 UTC = 23:24 EAT**. Inside quiet hours. The same
commit would have passed a few hours earlier, and will pass on a re-run
between 04:00 and 18:00 UTC.

This is a latent flake, not new - it was simply never observable, because
the suite had never executed.

`test_sweep_cancels_when_seller_already_replied` is the worse half of the
same problem: it asserts `mock_sms.assert_not_called()`, which at night
passes **vacuously** - quiet hours suppress the SMS whether or not the
cancellation logic works at all. It was green for the wrong reason.

### Fix

An autouse fixture pins the class's clock to 14:00 EAT, patching
`now_eat` rather than `is_quiet_hours` so the real quiet-hours logic stays
under test and the templates' greeting is deterministic too.

Added `test_sweep_defers_during_quiet_hours`: pins 23:30 EAT, asserts no
SMS, and asserts the interest is left **neither sent nor cancelled** so the
next sweep after 07:00 retries it. That behaviour was silently deciding the
outcome of the two tests around it while being covered by neither, and
"deferred" quietly becoming "dropped" is the failure worth guarding
against.

---

# Seller-side bugs + counterparty map (2026-09-15)

## Zeno told a seller to wait for a reply to their own answer

Screenshot: seller says "Yes it's still available", Zeno answers "I've let
them know - I'll update you the moment they reply. Anything else on your
mind while we wait?"

The relay acknowledgement in `_system_for_sender_reply` was written from
one point of view only - someone who ASKED something and is waiting. It
fired identically when the sender ANSWERED. A seller confirming
availability is not waiting on anybody and is owed no reply, so Zeno was
telling them to sit tight for a response to their own answer.

`is_availability_confirmation` already existed on the relay classifier and
was being used for the buyer-side switch offer; it just was not passed to
this prompt. Now it is, as `sender_answered`, and the acknowledgement
branches: answering gets "passed it on", full stop, with explicit
instructions not to promise an update or ask what else is on their mind.
The asking branch now also only promises an update when the sender is
genuinely waiting, judged against the factual record it already has.

## A seller's negotiation room showed "Seller" as the counterparty

`_loadCounterparty()` only ever fetched the SELLER's profile, and returned
early when the viewer *was* the seller. So a seller got no counterparty
data at all: the header fell through to the literal string "Seller" with an
"S" avatar, permanently offline, no distance, no rating - while the person
they were talking to was the buyer, whose id was in `_buyerId` the whole
time.

One line to fix, but it was wrong for everything downstream at once:
`_counterName`, `_counterIsOnline`, `_distKm`, the rating and deal counts
on the card, and the `peerPhoto` handed to the call screen yesterday - all
read that same map. They are all correct on both sides now.

## "Where" button: the counterparty on a map

`ListingMapScreen` already had a map, a privacy offset, haversine distance,
a travel estimate and a directions launcher. Three things were wrong with
it as an answer to "where is the other person":

- **Unreachable.** A bare 14px `map_outlined` glyph with no label, well
  under the ~44px minimum hit target, and nothing saying what it did. Now a
  labelled "Where" chip.
- **Wrong subject for a seller.** The route only ever accepted a `Listing`,
  so the screen computed "me -> my own listing" and showed a seller a map of
  their own sandals. It now accepts a map naming the actual counterparty
  and their coordinates, with the `Listing` shape kept for existing callers.
- **No direction.** Added an 8-point compass bearing ("North-east of you").
  Deliberately coarse: the pin it measures from is offset up to ~330m for
  privacy, so a precise bearing would be false precision.

Travel time now picks its mode from the distance - under 2km it reports a
walk, because "~2 min drive" for a neighbour three streets away is useless
in Juja - applies a 1.3x detour factor, and stays labelled as an estimate.
There is no routing service wired up, and a confident "12 min" derived from
a crow-flies number would be worse than admitting the approximation.
Distance prefers the server-computed value over recomputing from the
offset pin, so it matches what the rest of the app shows.

## Worth knowing: the privacy offset is cosmetic

The ~330m offset is applied **client-side**, to coordinates the client
already holds in full - `Listing.sellerLat/sellerLng` ship exact seller
coordinates to every buyer who opens a listing, and the user profile
endpoint returns raw `lat`/`lng` whenever `location_visible` is true. The
pin is fuzzed; the data behind it is not. Anyone reading the API response
sees the exact point.

Not fixed here - doing it properly means computing the approximate point
server-side and never sending the real one, which is an API change across
listings and profiles. Flagging it because "approximate position" currently
describes the rendering, not the privacy guarantee.

---

# Zeno's voice: stop parroting, cut the length (2026-09-15)

## "Right away." was in the prompt

`_system_for_sender_reply` handed the model three literal examples — the
strings "Right away", "OK, on it", and a complete sample reply ("Right
away." / "I've let them know - I'll update you the moment they reply.
Anything else on your mind while we wait?"). A model copies a concrete
example far more reliably than it follows an abstract style rule, so it
reproduced the sample nearly verbatim on every single relay. The example
meant to demonstrate a shape *became* the output, which is precisely what
makes a conversation read as automated.

All example wording is gone. The instruction now describes the two beats
and adds an anti-repetition rule that points at the factual record — which
is already in context and contains Zeno's own earlier messages, so it is
something the model can actually check rather than an aspiration.

## Length

Three separate causes, all fixed:

- **The relay instruction asked for three things** — acknowledge, confirm
  sent, invite more questions — while the length rule four lines below said
  "1-2 sentences". The instruction won. Cut to two beats; "anything else
  while we wait?" is what a person types occasionally, not every turn.
- **The availability/switch-offer block explained its own reasoning** to
  the model ("many new users don't realise...", "either is fine", "just
  make sure they know the option exists") and the model wrote that
  reasoning out loud. That is how one piece of good news became a
  four-sentence paragraph opening with "Just to be straight with you". The
  rationale now lives in a code comment for whoever maintains the prompt;
  the model gets the two facts and a word budget.
- **The budget was in sentences, not words.** A "sentence" absorbs
  unlimited filler. Now: one sentence is the default, under 25 words is the
  target, with named examples of the filler to cut.

## Human register

`BROKER_BASE_PROMPT` opened with "You are Zeno - an AI-powered, impartial
marketplace broker", which primes assistant register from the first token.
Reworded to prime a person who does this for a living, with explicit bans
on "I'd be happy to", narrating what it's about to do, and offering a menu
when one option will do. Also added: don't ask a follow-up question purely
to keep the conversation going.

Brevity does most of the work here. Nobody texting a friend writes four
sentences to say one thing, so the length fixes above are also the tone fix.

**One thing I did not do:** make Zeno claim to be human if asked directly.
The prompt now says to write like a person AND to answer honestly if
someone asks whether they're talking to a bot. The screen header says
"AI-MEDIATED · ESCROW PROTECTED" — denying it would contradict the app's
own UI, and in a negotiation with escrowed money the trust cost of being
caught would outweigh anything the pretence buys. Say the word if you want
that changed; it's one line.

## Unrelated inconsistency, noticed while in here

`ZENO_PROMPT` (the separate persona behind zeno_screen and product_screen)
still tells the model "You are DIFFERENT from the AI Broker (which mediates
specific deals)." Now that the negotiation room labels its assistant "Zeno"
too, that distinction no longer exists in the UI. Left alone — it changes
behaviour on two other screens and wasn't asked for.

---

# Label: "AI BROKER" -> "ZENO" on the negotiation room (2026-09-15)

`negotiate_screen.dart` was the one screen that called the assistant
something other than Zeno. The splash says "BOOTING ZENO", zeno_screen's
header says "Zeno", and the assistant introduces itself as Zeno in its own
dialogue — only the per-message badge and the typing indicator here said
"AI Broker".

- message badge: `🤖 AI BROKER` -> `🤖 ZENO`
- typing indicator: `AI Broker composing...` -> `Zeno is composing...`

The wire value is untouched: messages still carry `role == 'broker'`, which
`Message.isBroker`, the history filter in `_loadHistory` and the backend all
depend on. Only the two display strings changed.

`broker_screen.dart` and `auction_screen.dart` also contain "AI Broker"
strings. Left alone — different screens, and not what was asked for.

## Checked while in here: the direct-chat handoff

The screenshot that prompted this shows Zeno replying "Done — you two can
take it from here directly" while the buyer is still sitting in the
negotiation room. With the auto-navigate added earlier today that prose
becomes true; before it, Zeno was claiming a handoff that had not happened,
which is the "never claim success when execution failed" rule being broken
one step earlier than the buy agent applies it.

Confirmed the auto-navigate will fire for that exact message:

- This screen posts to `/negotiate/message` whenever a listing is attached
  (it was — "Sandals · Asking KES 150"), and that is the endpoint that
  attaches `zeno_action`. The `/negotiate/chat` branch, used only for
  listing-less conversation, does not — correctly, as there is no thread to
  hand off to.
- `detect_action_fast` matches "one on one" in `_DIRECT_CHAT_HINTS` and
  returns SWITCH_TO_DIRECT_CHAT before any model call, so detection here is
  deterministic rather than model-dependent. Replayed against the real hint
  tuples: "let's move to one on one chats" -> SWITCH_TO_DIRECT_CHAT.

Worth noting for later: "yes connect us directly" does NOT match any hint
and falls through to the model classifier, which is prompted to choose NONE
unless the message "clearly and directly asks". Phrasings that accept an
offer without restating it are the weak spot in this detection, not the
ones that name it.

---

# Calls: system ringtone, single ring owner, camera-mute signal (2026-09-15)

Assessment of the audio/video call path plus the ringtone change. Full
detail in CALLING.md; summary:

**Ringtone is now the user's own.** The bundled chime played on every
device regardless of settings, ignored silent/vibrate mode, and never
vibrated. Android now plays `RingtoneManager.getActualDefaultRingtoneUri(
TYPE_RINGTONE)` via a new platform channel, looping, with the standard
vibrate cadence, silent when the phone is silent. Notification channel
carries the same sound (`content://settings/system/ringtone`) for the
app-killed case; ID bumped to `broka_calls_v3` because channel sound is
immutable once created. No new pub dependency — deliberately, given the
pubspec's unverified pins and the CI failure one already caused.

**Two sounds at once, and none elsewhere.** `negotiation_screen` fired the
notification sound and the in-app loop on the same event; the global poller
fired only the notification, which does not loop, so a call arriving
anywhere else was one chirp. `showIncomingCall` now owns the ring and posts
silent when it started one. `cancelIncomingCall` stops it symmetrically.

**Camera mute was invisible to the peer.** `track.enabled = false` keeps
sending black frames, so no `onEnded` reaches the other side and nothing
else in the protocol says so — the peer sat on a frozen frame for the rest
of the call. New relayed `video_state` signal, re-announced after a
signalling reconnect, defaulting to on for older peers.

**Also:** `VIBRATE` permission (the vibrator call was a silent no-op
without it); `timeoutAfter` on the call notification; an `onTimeout` race
in `RingtoneService` where two starters for the same ring could drop the
screen's teardown callback and leave a dead dialog behind.

**Assessed and left alone.** The WebRTC core is in good shape and I did not
churn it: generation-guarded native callbacks, offer resend on reconnect
rather than renegotiation, ICE restart with a disconnect grace period,
communication-mode audio session, send-side bitrate caps, remote video
gated on decoded dimensions rather than track arrival. Those are the right
calls and I found no defect in them.

**Verification.** Backend compiles; Dart and Kotlin checked structurally
(delimiter balance against the unmodified originals), manifest parses.
Nothing executed — no Flutter toolchain here. The ringtone work is
platform code and wants a real device: silent, vibrate and normal modes, a
custom ringtone, and an API 27-or-below device for the loop watchdog.

---

# Chat background, availability SMS, notifications, call screen (2026-09-15)

Six user-reported items. Five had a single identifiable cause; the
notification one had three.

## 1. Constellation background shrank when the keyboard opened

`ChatAmbientBackground` positions every node as a FRACTION of the
painter's bounds. All three conversation screens use
`resizeToAvoidBottomInset: true`, so focusing the composer took ~45% of the
body height away and every fraction re-evaluated against the smaller box:
the field compressed upward and the gaps between nodes closed, then sprang
back on dismiss. It read as the background being animated by the keyboard.

Now painted against `MediaQuery.size` — the window, which the keyboard does
not change — inside `ClipRect` + `OverflowBox`, so the keyboard crops the
field from the bottom instead of rescaling it. Affects the three screens
that use it: `zeno_screen`, `negotiate_screen`, `negotiation_screen`.
Splash untouched.

## 2. The 5-minute availability SMS never fired

The sweep was correct and had no trigger. `nudge_deadline` was only ever
set by `POST /listings/{id}/interest`, and the client's `expressInterest`
is declared twice and called from nowhere. Full account in
ZENO_ACTIONS.md. Armed server-side from the buyer's own message now, and
the check moved to its own 60s loop.

## 3. Direct-chat handoff required a tap

`SWITCH_TO_DIRECT_CHAT` now navigates on arrival. Calls and SMS keep their
confirm step — those ring a phone or send under the user's name, and are
not reversible with a back button.

## 4. Notifications missed everything that happened while offline

Three separate causes:

- **First sighting of a thread was discarded.** `if (lastSeenSignature ==
  null) return;` skipped the first observation of any thread, to avoid
  announcing old history. But "a thread we have not seen before" is exactly
  what every thread looks like after being offline long enough to be
  killed, after a reinstall, or when someone messages about a listing the
  user has never opened. Suppression is now per-install (one flag, set
  once) rather than per-thread.
- **Missed calls had no notification path at all.**
  `_checkThreadForIncomingCall` only fires for a call ringing *right now*,
  so a call that came and went while offline left nothing behind. Missed
  and cancelled calls now notify from the call-history row. That row stores
  the outcome verb as its content, so the inbox payload gained
  `last_msg_type` / `last_call_type` — without them the notification body
  would have been the single word "missed".
- **No catch-up on resume.** The 7s timer only runs while the OS schedules
  the isolate; on resume it saw the current world and nothing about the
  gap. `GlobalPollerService.catchUp()` now runs from
  `AppLifecycleState.resumed`, above the idle-threshold check — that
  threshold governs whether to redirect the user's screen, which is a far
  heavier intervention than posting a notification.

Also fixed in passing: the poller read `thread['unread_count']` and the
backend only sent `unread`, so the read yielded null on every thread and
the delivered receipt it gates was never sent from the poller. The payload
now sends both.

## 5. Call screen showed initials instead of a face

`peerPhoto` threaded through all three push sites and rendered in the
avatar ring, with initials as the fallback for users who have no picture.
`negotiation_screen` was already fetching the counterpart profile and
never reading `profile_photo` off it; its chat header had the same problem
and got the same fix.

## 6. "Calling…" covered two different states

`webrtc_service` already distinguishes `connecting` (offer not sent) from
`calling` (offer sent, waiting on an answer — their phone is ringing), and
the UI flattened both to "Calling…". So a caller whose call never landed
could not tell whether it had ever reached the other person.

Now: "Connecting… / Setting up the call", then "Ringing… / Their phone is
ringing", with the avatar ring going gold to blue at the transition.
Callee still reads "Incoming call" in both pre-accept states.

## Verification

Backend changes compile. Dart changes were checked structurally
(delimiter balance against the unmodified originals, render sites read
back) — there is still no Flutter toolchain and no pytest here, so none of
this has been executed. Items 1, 5 and 6 are visual and want a device
before they are believed; item 2 wants a real buyer message followed by
five quiet minutes; item 4 wants a genuine offline stretch, not a
simulator backgrounding.

---

# CI fix #2 — the route guard is no longer allowed to raise (2026-09-15)

The previous round's fix did not work. The replacement guard ran (traceback
moved to `main.py:370`) and still raised "POST /negotiate/chat is not
registered at all", taking out 14 test modules this time instead of 13 —
including the new `test_route_ordering.py`. Still 0 of 325 tests run.

What the second failure tells us that the first did not: the new resolver
used Starlette's own `route.matches(scope)` and successfully resolved
FastAPI's `/openapi.json` on the same pass that found nothing at
`/negotiate/chat`. So route matching works; something about how this FastAPI
(0.141.1) exposes router-included routes does not match either assumption.

**I do not yet know whether the endpoint is genuinely unmounted or merely
invisible to introspection, and I have stopped guessing.** Two theories,
two failed CI runs, and the suite has still never executed once.

Changed:

- `_assert_route_ordering()` → `_check_route_ordering()`. It logs and
  returns. It cannot raise, under any input. An import-time raise runs
  before every test module and before boot, so a guard that is wrong takes
  down everything — including every unrelated failure you would otherwise
  be reading. Two outages, zero true positives.
- `tests/test_route_ordering.py` rewritten to ask the only question with an
  unambiguous answer: **it sends the request.** No route objects, no
  internals. A 404 means the endpoint really is gone; anything else means
  both guards were wrong and the route has been serving all along.
- Handler identity is established by two network-free discriminators, both
  of which fail request validation before any handler body runs, so nothing
  reaches an AI provider: an unauthenticated empty POST returns 422 from
  the no-auth legacy handler and 401/403 from the authenticated broker one;
  and a wrong-typed `image_base64` is named in the validation error only if
  the bound model is `negotiate.ChatIn`.
- Failures print `_router_inventory()` — route count, route classes, and
  every discoverable `/negotiate/*` path with its handler — so the next run
  diagnoses itself rather than costing another round-trip.

Verified by executing the shipped functions verbatim against six mock
router layouts, including the two that broke CI: the guard returns in all
six and raises in none.

**This unblocks collection; it does not make CI green.** The suite is about
to run for the first time, against a codebase with weeks of unexecuted
changes in it, and `flutter analyze` is now blocking on errors. Expect real
failures. That is the point — they have been invisible behind an import
error.

---

# CI fix — the route-ordering guard was bricking every test (2026-09-15)

`_assert_route_ordering()` in `main.py`, added in the 2026-09-14
implementation audit, raised `RuntimeError: POST /negotiate/chat is not
registered at all` on its first CI run. The route was mounted and working
the whole time — only the guard's detection was wrong.

It hand-rolled its own route matching, scanning `app.routes` for
`path == "/negotiate/chat" and "POST" in route.methods`. That found nothing
on the FastAPI/Starlette CI resolves from the unpinned `fastapi>=0.115.0`
in `requirements.txt` (0.141.1 / 0.52.1). Because the guard runs at import
of `main.py`, all 13 test modules that do `from main import app` failed
during collection, pytest interrupted with **0 of 325 tests run**, and the
APK job never started. Boot imports the same module, so a deploy would
have failed the same way.

The guard was written and never executed — it could not have passed on the
version CI installs.

Fixed:

- Resolution now goes through Starlette's own `route.matches(scope)`, the
  primitive the router dispatches with, descending into mounted
  sub-routers. It no longer depends on the names or shapes of `path` and
  `methods`.
- The endpoint is compared by identity via `inspect.unwrap`, not by
  `__module__` string, so moving `free_chat` is caught too.
- Three outcomes instead of two: wrong handler → raise; nothing resolved
  while the router is otherwise introspectable → raise; router not
  introspectable at all → log an error and continue. A guard against a
  silent bug must not be able to become an outage of its own.
- `tests/test_route_ordering.py` (new) asserts the same property in CI,
  where "could not determine" is a failure rather than a skip. It includes
  a resolver self-test, so the ordering assertions cannot pass vacuously,
  and a test that fails if ai_broker's `/chat` ever disappears — at which
  point the collision is gone and the guard can be retired rather than
  maintained.

Verified by executing the new functions verbatim against mock route
layouts: correct order passes; misordered raises; unmounted raises;
Mount-nested layouts (which the old flat scan could not see) resolve
correctly; unintrospectable routers log and continue.

**Not done — flagged.** Every pin in `requirements.txt` is `>=` with no
upper bound, so CI is not reproducible: the same commit resolved
`fastapi 0.141.1`, `pydantic 2.13.5`, `pytest 9.1.1` today and may resolve
something else tomorrow. That is the upstream reason a guard written
against one version met another. Left alone deliberately — pinning to a
ceiling that has not actually been tested against this codebase trades a
known failure for an unknown one.

Collection was interrupted before any test ran, so this fix unblocks the
suite rather than proving it green. Anything the 325 tests were going to
say is still unsaid.

---

# Zeno negotiation actions (2026-09-14)

The buy agent's structured-action pattern applied to negotiation threads:
Zeno can now offer SWITCH_TO_DIRECT_CHAT, START_AUDIO_CALL,
START_VIDEO_CALL and DRAFT_SMS. Costs zero extra AI calls - the existing
single-purpose `_classify_wants_direct_chat` boolean was replaced by one
vocabulary classifier, plus deterministic fast paths for unambiguous
phrasing.

Every action is a PROPOSAL the user confirms, never an execution. The
other party's messages are in Zeno's context, so auto-execution would let
one party trigger a call or SMS on the other's device by typing an
instruction. This also fixed an existing case: suggestDirectChat used to
auto-navigate with no confirmation.

Calls reuse POST /calls/initiate rather than getting a new path, so one
place in the codebase can ring a phone. SMS is rate-limited 5/hour and
draft/send are separate calls. See ZENO_ACTIONS.md.

---

# AI audit + cost controls (2026-09-14)

Gemini - the primary provider, tried first on every call - was the only
tier with no circuit breaker, so a degraded Gemini made every request pay
a full timeout. Fixed. `max_tokens` was globally 400 including for
classifiers emitting ~30 tokens of JSON; now per-call.

Cost: the relay classifier ran on every message including "ok" and "👍",
carrying ~700 tokens of fixed policy text. Added a deterministic
pre-filter (only ever suppresses a relay - the same direction the
classifier already fails in), a 7-day cache keyed on the only three
inputs the prompt receives, and cheap-first routing for machine-read
output. 18 classifier calls -> 7 on a representative thread.

The two prose calls users actually read are untouched. See AI_AUDIT.md.

---

# Availability-nudge SMS: system-generated, not AI (2026-09-14)

`_fire_availability_nudge` no longer calls the LLM. New
`api/core/nudge_templates.py` composes the message from 10 deterministic
variants, chosen by a stable hash of the Interest id so a retry reproduces
the identical text rather than a differently-worded second copy.

Greeting now derives from Africa/Nairobi (UTC+3), not the server's UTC
clock — 4 of 6 sampled hours would otherwise have greeted wrongly (14:00
EAT reads as 11:00 UTC and would have said "Good morning"). No "good
night": it is a farewell in English.

Quiet hours 21:00–07:00 EAT: a nudge coming due overnight is deferred,
not sent.

`User.gender` added ("male" | "female" | "prefer_not_to_say" | NULL) with
registration and Flutter client wired through. NULL and
"prefer_not_to_say" resolve identically everywhere, so the message can
never leak who declined to answer. Pronoun sets carry verb agreement, and
a regression test enforces that no template pairs a proper noun with
pronoun-derived agreement.

---

# Dispute engine audit (2026-09-14)

Three critical fund-safety defects on the M-Pesa B2C payout path:
concurrent executes both paid (no claim before spending); the `version`
"optimistic lock" compared an object to itself and could never fire; and
the engine never checked `deal.status`, so it could refund a buyer on a
deal already released to the seller. All three fixed and verified by
simulation. See DISPUTE_AUDIT.md.

---

# Implementation audit — Store, events, legacy routers (2026-09-14)

Store: directory N+1 removed (21 queries -> 2 per page), unbounded slug
suffix search capped, one-store rule serialized with a row lock (was
check-then-act with no constraint behind it), public pagination bounded.

Events: `events.publish()` skipped in-process dispatch entirely when Redis
was enabled, writing instead to a stream that has no consumer - a
production-only silent failure for anyone using this module's own
documented `@subscribe` API. Zero real subscribers today, so it was a
loaded trap rather than a live fault; fixed at the mechanism. Handler
tasks now strongly referenced (were GC-eligible mid-execution).

Legacy: five confirmed-dead routers quarantined with DEAD headers, not
deleted. See EVENT_ARCHITECTURE.md.

---

# Constellation background — corrected (2026-09-14)

The first pass undershot badly and missed a screen.

- **Far too dim.** Edge opacity ran 0.035-0.065 against the splash's
  0.14-0.26, and nodes 0.10-0.21 against 0.55-1.0 - 4-5x below the
  reference, so what reached the screen was faint smudges, not stars.
  Now tracks the splash: edges 0.13-0.24, nodes 0.42-0.80.
- **No white cores.** The splash draws bloom -> coloured star -> white
  centre. Dropping that third pass was the single biggest reason the dots
  read as dust: a real point of light blows out to white at the centre and
  keeps colour only in the falloff.
- **Aspect-ratio bug in the link metric.** Node positions are fractions of
  the painter's bounds, but a phone is ~2.2x taller than wide, so one unit
  of dy is 2.2x more pixels than one of dx. Comparing them raw let the
  nearest-neighbour search link stars that are visually far apart -
  producing long lines striping across the thread, a network diagram
  rather than a constellation. Measured in screen space now: longest link
  dropped from ~210px to ~97px.
- **Too sparse.** 30 mesh nodes with 2 links each at a short reach gave 34
  edges - isolated pairs, no structure. Now 46 nodes, 3 links, 86 edges.
- **Vertical falloff crushed the middle.** The old linear taper dimmed the
  whole body of the thread; it now only bites in the bottom fifth where
  the composer sits.
- **negotiate_screen.dart (the AI-mediated Negotiation Room) was missed
  entirely** in the first pass - the one conversation surface with no
  field behind it, which is where the mediated negotiation actually
  happens. Its opaque blue composer gradient is now translucent and
  violet-leaning so the field reads through and doesn't seam against it.

Verified by rendering the painter's exact arithmetic offscreen rather than
eyeballing values: body text holds 11-15:1 contrast over the densest third
of the field (WCAG AA is 4.5:1).

---

# Escrow audit (2026-09-14)

Ledger release/refund now derive their amount from the ledger itself rather
than `deal.agreed_price`, fixing a ~97%-of-price shortfall in
`escrow_holding` on every completed legacy M-Pesa deal; `trial_balance()`
gained a per-deal check that can actually fail (the old debits==credits
comparison was true by construction) and is now reachable at
`GET /admin/ledger-integrity`; ledger writes are idempotent against an
at-least-once event bus; `agreed_price` is validated (negative, zero,
Infinity/NaN all previously accepted); the M-Pesa callback verifies the
reported amount against the requested one and guards the deal status
transition; automatic seller-rating inflation and double-counted
`completed_deals` removed. Full findings in ESCROW_AUDIT.md.

---

# Conversation UI pass (2026-09-14)

- **Language chips removed from direct chat.** They set `_selectedLang` and
  `ApiService.currentUserLanguage`, and nothing in that screen ever read
  either — direct chat sends your literal text to the other party, so there
  was nothing for a language choice to act on. Six permanently-visible
  controls doing nothing, in the most valuable strip of a chat screen. They
  remain on Zeno's screen, where replies really are generated in the chosen
  language. "Finalize" was the one live control in that row and moved into
  the header as a proper action.
- **Composer rebuilt on both conversation screens.** Attachment and mic now
  sit *inside* the input pill (as in WhatsApp/Telegram/Gemini) rather than
  as two standalone bordered squares beside it — three competing bordered
  boxes in one row was what made the input read as casual. Send scales in
  only when there's a draft; mic hides once you start typing; focus ring on
  the pill; `maxLines` 3 → 6 so a real negotiation message fits.
- **Constellation background** (`widgets/chat_ambient_background.dart`) on
  both the buyer↔seller thread and Zeno's screen, matching the splash.
  Retuned for readability: spread rather than corner-clustered, ~1/5 the
  splash's opacity, and faded toward the composer.
- **Per-frame subtree rebuild fixed** in `widgets/particle_field.dart`. It
  drove its animation with `setState`, rebuilding `widget.child` 60×/sec.
  Unused today, but it is the obvious widget to reach for when adding a
  background to a list — the new background widget avoids the same trap by
  construction (AnimatedBuilder + RepaintBoundary, painter only).
- Direct-chat empty state redesigned: haloed emblem, who you're talking to,
  an explicit "Zeno is not in this thread and cannot read it" line, and the
  keep-payments-on-BROKA reminder.

---

# Communications audit (2026-09-14)

Cross-party leak in `_build_messages_for_party` closed (private Zeno chat
was entering the other party's draft context); unread counts no longer
count — or leak the existence of — private messages; `/history` thread
bleed on the seller's own messages fixed; chat WebSocket accept/register
race fixed. WhatsApp-style delivery + read receipts added on a second
watermark, plus a BROKA-specific `relayed` state for messages Zeno passed
on in its own words. Full findings in COMMUNICATIONS_AUDIT.md.

---

# Calling audit — bugs found and fixed (2026-09-14)

A full read of the audio/video calling stack (backend `calls.py` +
`call_state.py`, Flutter `webrtc_service.dart` + call screen + notification/
poller/ringtone services, Android manifest + foreground service). Everything
below was found by reading the code and confirmed with standalone
simulations of the two state machines and the SDP tuner; nothing has been
run on a physical device (no Flutter toolchain, no Redis/Cloudflare/FCM in
this environment). See CALLING.md's device-testing checklist.

## Call-breaking

1. **Decline and missed calls did nothing at all.** A callee's
   `WebRtcService` sits at `idle` until they tap Accept, but the client
   transition table only allowed `idle → connecting`. Decline called
   `hangup() → _setState(ended)`, which was rejected as illegal — and the
   rejection is a silent no-op, so `onStateChange` never fired. The result
   was never logged, the screen never closed, and the caller kept ringing.
   The 45s no-answer timeout took the identical path, so missed calls were
   never recorded either. `idle` now allows `ended`/`failed`.

2. **A transient drop on one side instantly killed the call on the other.**
   The backend told the surviving peer `{"type":"hangup","reason":
   "peer_disconnected"}`, and the client's hangup handler tears down
   unconditionally. That defeated every piece of recovery machinery on the
   dropping side — bounded WS reconnect, offer/answer resend-on-`ready`,
   ICE restart — because the survivor had already hung up. Replaced with a
   distinct `peer_state` message; `hangup` now means only what its name
   says. The survivor holds the call (media keeps flowing peer-to-peer
   without signaling) and is told `peer_state: reconnected` when the peer
   returns.

3. **ICE restart could never complete.** `_handleAnswer` bailed on
   `_remoteDescriptionSet` with no restart exception, unlike `_handleOffer`
   which has always had one. The restart offer went out, the callee
   answered correctly, and the caller discarded that answer as a duplicate
   — so recovery from an ordinary Wi-Fi/cell handoff always failed, burned
   both attempts, and ended the call.

4. **Unbounded reconnect loop.** `_connectWs()` reset the retry budget
   immediately after `WebSocketChannel.connect()`, but that call is lazy
   and `sink.add()` buffers — both succeed against a server that's
   unreachable. Every failed reconnect zeroed the counter moments before
   `onDone` bumped it back to 1, so `_maxReconnectAttempts` was never
   reached. Budget now resets only on the first frame the *server* sends.

5. **Stale sockets triggered spurious reconnects.** `_ws` was reassigned
   without invalidating the old subscription, so the old socket's
   `onDone`/`onError` kept firing against the new healthy one, each
   scheduling another reconnect. Sockets are now epoch-tagged.

6. **Buyers were never rung by the polling fallback.**
   `GlobalPollerService` gated the incoming-call check on
   `my_role == 'seller'`. Since `/calls/pending/{listing_id}` already
   scopes its answer to the authenticated callee, the gate only guaranteed
   that a buyer called by a seller was never polled for — and with FCM not
   yet live, seller→buyer calls had no delivery mechanism at all.

7. **Seller "Call back" was a dead button.** It built a client-side
   `room_id`, never called `/calls/initiate`, and navigated with no call
   token, so the WebSocket was rejected instantly and the buyer was never
   notified. Its comment blamed a "buyer-initiates-only" backend, which
   stopped being true when `initiate_call()` gained `callee_id` support.

## Performance and correctness

8. **FCM blocked the event loop.** `firebase_admin`'s `messaging.send()` is
   synchronous blocking HTTP, called bare from async code in both
   `calls.py` and `workers.py`. On this single-process deployment it
   stalled every other in-flight request for the round trip — including the
   heartbeat and relay loops of calls already in progress. Both moved to
   `asyncio.to_thread`. Permanently-dead tokens are now cleared.

9. **`receive_text()` was cancelled every 15s** by `asyncio.wait_for` just
   to send a ping. Cancelling a Starlette receive mid-flight can abandon a
   delivered frame, and it spawned a timeout task per interval per
   participant. Replaced with one background ping task and an activity
   timestamp.

10. **Sessions could expire under a long call.** The TTL was only extended
    on a transition *into* `connected`, so a call that connected once and
    stayed up counted down from that single moment. The heartbeat now calls
    `renew_session()`.

11. **`disconnected` couldn't reach `connecting`/`accepted`** — exactly the
    path a reconnect takes — so every reconnect logged two rejected
    transitions and left the session stuck.

12. **The relay forwarded arbitrary message types verbatim**, letting either
    participant forge `ready`/`busy`/`hangup` at the other, and pointlessly
    relaying the client's `join`. Now whitelisted to `offer`/`answer`/`ice`/
    `hangup`, with a 128KB frame cap.

## Audio quality, bandwidth and UX

13. **No audio session configuration at all.** Calls ran in Android's
    default MEDIA mode: volume keys adjusted media volume instead of call
    volume, audio routed through the media stream, and the hardware echo
    canceller/noise suppressor (communication-mode only) stayed off. Now set
    to communication mode, with voice starting on earpiece and video on
    speaker rather than whatever the platform happened to pick.

14. **Opus was untuned.** Added DTX (stop transmitting during silence),
    explicit in-band FEC, mono, and a 24kbps voice / 32kbps video ceiling,
    plus a 24fps capture cap — meaningful on congested East African mobile
    data. Falls back to the original SDP untouched if it doesn't parse as
    expected.

15. **The quality badge was fabricated** — derived purely from elapsed
    seconds, so a call dropping 40% of its packets through a TURN relay
    reported "Excellent" at 31 seconds. Now measured from inbound packet
    loss and jitter via `getStats()`, and shows nothing when genuinely
    unknown.

16. **Incoming-call notifications were never cancelled**, so answered,
    declined, cancelled and timed-out calls left permanently useless
    entries in the tray. Also added `onlyAlertOnce` — the 7s poller was
    re-firing the channel alert roughly six times per ring, producing a
    stuttering ringtone.

17. **Answering took two taps.** Both the notification tap and the in-chat
    Answer button landed on the call screen's own Accept/Decline prompt —
    silent by then, because the ringtone had already stopped. Added
    `autoAccept`.

18. Renderers are detached before disposal and cleanup is awaited (a known
    flutter_webrtc native-crash shape); the hangup frame is flushed before
    the socket closes; the pending-ICE queue is bounded; the audio route is
    handed back on teardown; `showWhenLocked`/`turnScreenOn` added so the
    full-screen intent can actually take over a locked screen.

---

# BROKA — Store: second-pass engineering hardening

A code-level review pass, not a rebuild — audited the actual current
Store implementation (not the original spec) and fixed what the audit
actually found. No new migrations, no architecture changes, no
speculative features.

## Confirmed bugs, fixed

- **`listing_count` used Python `len()` over every fetched listing id**,
  not a SQL count. Now a real `SELECT COUNT(*)`.
- **Slug allocation had a TOCTOU race** between the uniqueness check and
  the insert/update — two concurrent requests for the same store name
  could both pass the check before either committed, surfacing as an
  unhandled `IntegrityError`. Both `create_store` and `update_store` now
  retry (bounded, 3 attempts) on the DB's own conflict rejection.
- **No server-side size limit on Store media** — `logo_url`/`photos`
  accepted arbitrary-size base64. Now capped at 10MB per image (matching
  `api/routers/media.py`'s existing `MAX_IMAGE_MB`, not a new number),
  rejected with 413.
- **`owner_id` was exposed on every Store response**, public or not, with
  no actual consumer anywhere in the app (verified by checking Flutter
  usage — the "is this my store" check compares store ids, never
  owner_id). Removed.
- **`migrations_guide.py` and the README's "Database Migrations" section
  both claimed the opposite of what actually happens** — "never call
  create_all() in production" is false; that's the real mechanism, every
  startup. Both corrected in place; a new `backend/migrations/README.md`
  added since that's the first place anyone finds the unused Alembic
  scaffolding.
- **README test-coverage claim (60%+) didn't match the CI gate's actual
  threshold (35%, `--cov-fail-under=35`)**, and its "10 test files" was
  stale (25 exist). Corrected to describe the enforced floor, not a
  number to chase.
- **README's AI-provider claim ("Gemini 2.0 Flash primary") didn't match
  the actual multi-provider fallback chain** in `ai_broker/service.py`
  (Gemini, DeepSeek, Groq all present; effective primary depends on which
  API keys are configured). Softened to describe the real chain rather
  than assert a specific always-current default.
- **README title said v4.0**; the app's own health endpoint reports
  `"version": "6.0.0"`. Corrected to match what the code says about
  itself.

## Product decision made, enforced

- **One store per user.** The schema always allowed multiple; only the
  UI pretended otherwise. Decided V1 intends one, enforced server-side in
  `create_store` (409 on a second attempt) — no DB constraint added, the
  schema stays open for a real future multi-store decision.

## Built (spec gaps the code, not the spec, revealed)

- **Store Management's two listing lists were hard-capped** (100 / 50)
  with no way to see past that. Now paginated with load-more, loading/
  error/retry states, dedup-guarded against a double-tap.
- **Logo/photo upload was entirely missing from the Flutter form** despite
  the backend accepting both. Built using this app's existing
  `image_picker` + base64 pattern; a new `StoreMediaImage` widget renders
  it everywhere (Management, public View, discovery cards) with a
  graceful fallback on missing/invalid data rather than a crash — catching
  one bug of its own along the way (a first attempt used `NetworkImage`,
  which cannot render a base64 data URI at all).

## Legacy code quarantined (not deleted)

Verified which of several old/new implementation pairs are actually
mounted (checked `main.py`'s real imports, not assumed): `api/routers/
{admin,auth,disputes,reviews,listings}.py` are dead — never imported —
superseded by their `api/domains/*/router.py` equivalents. Each now has a
clear header pointing to the canonical file rather than being silently
left to look like live code. `api/routers/escrow.py`'s "legacy_escrow" IS
still mounted (at `/escrow`, alongside the new router at `/deal`) — this
is intentional, already self-labeled, and left alone. `api/models/{user,
listing}.py`'s re-export-shim pattern was already well-documented from
earlier work; verified, not touched.

## Tests added

4-case cross-user Store/Listing integrity matrix, `listing_count`
accuracy, single-store-per-user rejection, oversized-media rejection
(and a reasonable-size acceptance check alongside it), and a concurrent-
same-name-store-creation test. All reviewed carefully; **not executed** —
this sandbox has no network and none of the project's actual dependencies
installed, same limitation as every prior round.

---

# BROKA — Store / Business Layer: discovery + public web page (Phases 4-5 of 5)

Completes the spec's original 5-phase roadmap. Builds on both entries
directly below this one.

## What changed

- **Backend**: `GET /stores` (list/browse) — public, active stores only,
  optional `search`/`specialization`/`county` filters, same `with_total`
  pagination shape as `GET /listings/`. An inactive store is excluded
  from this directory the same way its own catalog is empty while
  paused, but a direct link to it still resolves - being unlisted isn't
  the same as being deleted.
- **Backend**: the public SSR page itself, `GET /store/{slug}`
  (`api/domains/stores/web.py`, registered at the `/store` prefix -
  singular, separate from the `/stores` JSON API). Plain FastAPI
  `HTMLResponse` with inline CSS matching the app's own color tokens, no
  Jinja2 or other new templating dependency, no separate web app - the
  spec's own "lightweight... from the existing backend" instruction taken
  literally. Open Graph tags for title/description/url; **og:image is
  deliberately omitted** - store/listing images are inline base64 today,
  and a data URI isn't a URL a social crawler can fetch, so setting it
  would silently not work. Every piece of store/listing text is
  `html.escape()`d before being written into the page - this is the one
  endpoint in the whole codebase where user-supplied text becomes raw
  HTML for an unauthenticated visitor rather than a JSON field, so it's
  the one place that escaping is load-bearing rather than a formality.
  Covered by a test asserting a `<script>` in a store description renders
  as inert escaped text, not executable markup.
- **Flutter**: `StoreListScreen` (Phase 4) — a 1-column browse/search
  list, modeled directly on the existing `TraderListScreen` (same reason
  that screen isn't `ProductGridView`-based: a list layout for one screen
  is a smaller change than adding a layout mode to a grid four other
  screens share). Shows only real fields — name, specialization, location,
  a real listing count - no rating or deal count, since Store has neither.
  Reached from Home's existing discovery rail, as one more pill alongside
  Trending/Auctions/Traders - not a new Home section, not a new tab, per
  the spec's own repeated instruction not to redesign Home for this.
- **`StoresRepository.listStores()`** added to back the new screen.

## Deliberately still deferred

- Individual product pages on the public web (`/store/{slug}/product/...`)
  and Android/iOS deep linking - explicitly later-stage per the spec
  itself, not blocking V1.
- Store logo/photo upload in the create/edit form - still text-fields-only.
- Store Intelligence ("Ask this store"), merchant AI negotiation limits,
  and multi-item bundle negotiation - explicitly out of scope for this
  entire 5-phase pass per the spec's own repeated instruction.

---

# BROKA — Store / Business Layer: Flutter foundation (Phase 3 of 5)

Builds the Flutter side on top of the backend foundation entry directly
below this one. Phase 4 (a dedicated Store discovery surface beyond the
listing-card badge) and Phase 5 (the public SSR `/store/{slug}` web page)
are still not in this entry.

Audited the Flutter app before writing anything, per the spec's own
instruction, and found two things worth recording so they aren't
rediscovered the hard way later:

- **Two parallel `Listing` models exist.** `lib/models/listing.dart` is
  imported by the most call sites, but `home_screen.dart` and
  `widgets/product_card.dart` — the actual Home feed and the card every
  listing renders through — use the other one,
  `lib/features/listings/domain/models/listing.dart`. Both needed the new
  store fields; this was already a known, commented pattern in that
  second file ("kept in sync across both Listing models", next to the
  existing showcase-image fields), not something invented for this change.
- **`ProductScreen` doesn't recognize the newer `BrokaListing` type** —
  only the older `Listing` model or a `{'listingId': ...}` argument map.
  Passing a `BrokaListing` straight through as route arguments silently
  fails to load. Every new/edited screen that navigates to a listing from
  a `BrokaListing` uses the `{'listingId': ...}` form, matching
  `home_screen.dart`'s and `category_zone_screen.dart`'s existing (and in
  the latter case, already-commented) handling of the same issue.

## What changed

- **Both `Listing` models** (`lib/models/listing.dart` and
  `lib/features/listings/domain/models/listing.dart`): added
  `storeId`/`storeName`/`storeSlug`, parsed from the fields the backend
  already returns.
- **`lib/features/stores/`** (new): `Store` model, and a
  `StoresRepository` covering the full `/stores` API (create, get by id/
  slug, update, activate/deactivate, `/mine`, and a store's listing
  catalog) — same `Result<T>`/`ApiClient` conventions as
  `ListingsRepository`/`TradersRepository`.
- **`ListingsRepository`**: `storeId` filter added to `getListings`/
  `getListingsPage`; `setListingStore`/`removeListingStore` added for
  moving an existing listing in/out of a store.
- **Sell wizard** (`sell_wizard_data.dart` + `sell_review_screen.dart`):
  a `[No Store] / [My Store]` picker on the Review step, shown only when
  the seller has a store (checked via `GET /stores/mine`); `store_id`
  included in the submission payload and persisted in the draft.
- **`ProductCard`** gained an optional `onViewStore` callback and renders
  a small store badge (spec's own "Clanix Electronics [View Store]"
  example) when a listing has one; personal listings render exactly as
  before. The shared **`ProductGridView`** widget passes this callback
  through, and it's wired at every screen that uses that widget to browse
  listings — Home, Trending, Category zones, and a trader's profile — so
  the affordance works everywhere a store-associated listing can appear,
  not just in one place.
- **Three new screens** under `lib/features/stores/presentation/`:
  `CreateStoreScreen` (doubles as the edit form when given an existing
  store), `StoreViewScreen` (the public-facing profile + catalog, reusing
  `ProductGridView` rather than a second grid implementation), and
  `StoreManagementScreen` ("Store Mode" — profile, activate/deactivate,
  share link via clipboard, the store's own catalog, and adding an
  existing personal listing into the store or removing one). Deliberately
  no Deals/Negotiations/Reviews/Analytics tabs here — nothing on the
  backend scopes those to a Store yet, and the spec is explicit about not
  faking that data.
- **Navigation**: the three screens registered as named routes in
  `main.dart`; a "My Store" entry added to the profile screen, shown once
  the account is a seller — the natural next step after "Become a
  Seller", not shown before.
- **No `flutter analyze`/`dart analyze` available in this environment**
  (no network, no Flutter SDK installed) — verified instead with a
  brace/paren/bracket balance check and a script that resolves every
  relative import in every touched file against the real filesystem, both
  passing across all 18 touched files. This is a lighter bar than a real
  analyzer and doesn't catch type errors — worth an actual `flutter
  analyze` pass before shipping.

## Deliberately deferred

- A dedicated Store discovery surface (spec Phase 4) — for now, a store
  is reached via a listing's badge or from Profile once you own one, not
  from its own Home/nav entry.
- The public SSR `/store/{slug}` page (Phase 5) — the "Copy Link" buttons
  already build this URL, so it goes live the moment that ships.
- Store logo/photo upload in the create/edit form — every other field is
  there; wiring the sell wizard's image-capture flow into the Store form
  is a scoped-out follow-up, not a silent gap.

---

# BROKA — Store / Business Layer: backend foundation (Phases 1-2 of 5)

Implementing the Store feature spec's first two phases only, in this pass:
database foundation + backend APIs. Phase 3 (Flutter), Phase 4 (discovery
entry point) and Phase 5 (public web storefront) are **not** in this
entry — flagged explicitly rather than implied-done, given how large the
full spec is.

Audited first, per the spec's own instruction, before writing anything:
confirmed `api/domains/traders/` is a read-only view over `User`
("Trader == User", Design Journal Vol.6 Ch.5) and is a genuinely
different concept from Store, so it's untouched by this work. Also
confirmed this repo's Alembic setup (`backend/migrations/`,
`alembic.ini`) is dead code — nothing in `main.py`, any CI workflow, or
`render.yaml` ever invokes it; the actual schema-evolution mechanism is
`Base.metadata.create_all()` for new tables plus a manual `ALTER TABLE`/
`CREATE INDEX` list inside `api/database.py`'s `init_db()` for columns/
indexes on tables that already exist. This work follows that same
mechanism — **no migration files were added.**

## What changed

- **`api/models/store.py`** (new): `Store` model + a small `slugify()`
  helper. Follows the same "new domain gets its own file under
  `api/models/`, imports `Base` from `api.database`" convention already
  established by `api/models/dispute.py` and `api/models/escrow_ledger.py`
  — not shoved into the giant `database.py` file, and not a second,
  competing model system.
- **`api/database.py`**: `Listing` gained one new nullable, indexed
  column — `store_id` (FK to `stores.id`). `seller_id` is untouched.
  A matching `ALTER TABLE listings ADD COLUMN store_id VARCHAR` /
  `CREATE INDEX IF NOT EXISTS ix_listings_store_id` pair was added to
  `init_db()`'s existing manual migration lists, same pattern as every
  other column this function has ever added to an existing table.
- **`api/domains/stores/`** (new domain — `router.py` + `service.py` +
  `media.py`): `POST /stores`, `GET /stores/{id}`,
  `GET /stores/slug/{slug}`, `PATCH /stores/{id}`,
  `POST /stores/{id}/status` (activate/deactivate),
  `GET /stores/{id}/listings` (a store's public catalog — delegates to
  the existing `ListingService` filtered by `store_id`, so there is no
  second Listing/Product system), and `GET /stores/mine` (added beyond
  the spec's literal endpoint list — needed so the future Flutter Store
  Mode entry point can check "does this user have a store yet" without
  already knowing its id). Ownership is checked server-side on every
  mutation against the JWT-derived user id, never trusted from the
  client. Slug collisions on a duplicate store name get `-2`, `-3`, ...
  suffixes rather than silently overwriting another store. No invented
  reputation numbers anywhere in the response — `listing_count` is a
  real `COUNT`, and that's the only "reputation-adjacent" field this V1
  exposes.
- **`api/domains/listings/`** (router + service): `store_id` accepted on
  listing creation (store ownership verified server-side before the
  listing is created inside it); `store_id` added as a filter on
  `GET /listings/`; two new endpoints, `POST`/`DELETE /listings/{id}/store`,
  to move an *existing* listing in/out of a store — mirroring the
  existing `POST`/`DELETE /listings/{id}/showcase` pattern rather than
  inventing a generic listing-PATCH endpoint (this codebase has never
  had one). Listing responses now include `store_id`/`store_name`/
  `store_slug` (batch-fetched per page, same one-`IN(...)`-query pattern
  already used for sellers — never N+1) so a listing card can show a
  "belongs to a store" affordance without an extra request.
- **`backend/tests/test_stores.py`** (new): store CRUD, auth, ownership,
  duplicate-slug, public-read, activate/deactivate, and the full
  listing↔store integration (personal listings unaffected, store-owned
  creation, cross-owner rejection, `store_id` filtering, attach/detach).
  Written against this repo's existing `httpx`/`pytest-asyncio` fixture
  conventions; **reviewed, not executed** — this sandbox has no network
  and none of the project's actual dependencies installed, same
  limitation as the VoIP call-hardening test rounds.

## Deliberately deferred (not overlooked)

- Flutter: Store models, repository/service, create/edit screens, Store
  Mode, listing-creation store toggle, Home/nav entry point — spec
  Phase 3/4, a separate large pass.
- The lightweight public SSR `/store/{slug}` web page — spec Phase 5.
- Store-level reputation derived from real Deal/Review data (spec §7/§19
  explicitly says not to fake this, and nothing yet computes a
  store-scoped, as opposed to seller-scoped, trust signal to reuse).
- A dedicated `StoreCreated`-style event in `api/core/events.py` — no
  current subscriber needs one yet, so one wasn't speculatively added.

---

# BROKA — Round 23: DeepSeek V4 Flash direct API integration (Zeno AI provider)

A different kind of task from the calling-hardening rounds above: adding
DeepSeek V4 Flash as a DIRECT DeepSeek API provider (not via OpenRouter)
in the Gemini→OpenRouter/Nemotron fallback chain, with zero database
changes. First step was verifying "DeepSeek V4 Flash" / model ID
`deepseek-v4-flash` actually exist — genuinely unfamiliar (released after
this assistant's knowledge cutoff) rather than assumed fabricated - a
live web search against DeepSeek's own API docs confirmed the model,
the exact endpoint (`https://api.deepseek.com/chat/completions`), and
critically the real, documented `"thinking": {"type": "disabled"}`
parameter for non-thinking mode, rather than guessing or inventing one.

**Scope finding worth flagging explicitly**: the task named
`ai_broker/service.py` and `negotiate.py` as the files to change. Auditing
first (as always) turned up that BROKA actually has *four* independent,
hand-duplicated copies of the same Gemini→OpenRouter→Groq fallback logic
- those two, plus `api/domains/disputes/service.py` and
`api/routers/disputes.py`, neither of which the task mentioned. DeepSeek
was added to exactly the two named files; the other two were left
untouched and are flagged here rather than silently expanded into or
silently left inconsistent without a mention.

## What changed

- **`circuit_breaker.py`**: new `deepseek_breaker` (same threshold/timeout
  as the existing Gemini/OpenRouter/Groq breakers) - shared by both
  `ai_broker/service.py` and `negotiate.py`'s independent DeepSeek calls,
  so both back off together if DeepSeek is unhealthy rather than having
  two disconnected breaker states for the same provider.
- **`config.py`**: `deepseek_api_key`, `deepseek_model`
  (default `deepseek-v4-flash`), `deepseek_base_url`
  (default `https://api.deepseek.com`), and `deepseek_timeout_seconds`
  (default 15 - deliberately shorter than the other providers' 25-30s,
  since the point of this migration is conversational latency) - same
  env-driven style as the existing OpenRouter settings.
- **`ai_broker/service.py`**: new `_call_deepseek()` between
  `_call_gemini()` and `_call_openrouter()` - full error handling
  (timeout, connection error, 401/403, 429, 5xx, malformed JSON, missing
  choices/message/content, each with its own log line and none of them
  logging the key), latency measurement/logging, inserted into `_call_ai`'s
  chain and `circuit_stats()`. Skipped entirely (not a fatal error) when
  `DEEPSEEK_API_KEY` is unset.
- **`negotiate.py`**: the same addition, adapted to this file's own
  distinct existing convention (module-level `os.getenv` constants,
  `system` passed as a separate argument, `ValueError`-based failure
  signaling, turn-merging like its existing `_call_groq`/`_call_openrouter`)
  rather than copying `ai_broker/service.py`'s class-based shape in
  wholesale. Docstring and fallback-chain comments updated to match.
- **`.env.example` / `render.yaml`**: `DEEPSEEK_API_KEY` (secret,
  `sync: false` in render.yaml - never a real key committed),
  `DEEPSEEK_MODEL`, `DEEPSEEK_BASE_URL` added using the exact same safe
  pattern already used for the other providers.
- **`ARCHITECTURE.md`**: fallback chain, breaker list, and deployment
  checklist updated so they no longer describe OpenRouter/Nemotron as the
  immediate fallback after Gemini now that DeepSeek sits between them.
- **Tests**: `test_ai_broker_deepseek.py` (new) - all 11 scenarios the
  task asked for (success, missing key, timeout, 401, 429, 500, malformed
  response, missing choices/message/content, fallback to Nemotron,
  Gemini→DeepSeek→Nemotron ordering, existing OpenRouter/Groq/cache paths
  unaffected), plus a request-shape test verifying the exact endpoint/
  model/auth-header/non-thinking-mode contract. `test_negotiate_deepseek.py`
  (new) - a smaller, equivalent set for `negotiate.py`'s own
  implementation (this file had no AI-provider test coverage at all
  before this round). `test_ai_broker_v4.py`'s existing circuit-stats
  test extended to check for `deepseek` too. All HTTP calls mocked using
  real `httpx.Response` objects (so `.raise_for_status()` behaves exactly
  as it would against a real reply) rather than hand-rolled fakes or an
  added mocking dependency - no real DeepSeek call, no real key, anywhere
  in the test suite.

## Verified

- Zero database/migration/model files anywhere in the diff (grepped for
  it explicitly, not just assumed).
- Zero secrets anywhere in the diff (grepped explicitly for key-shaped
  strings across every changed file).
- Nemotron/OpenRouter/Groq/cache code paths are untouched other than
  moving one step later in the chain - covered by tests asserting each
  still works.
- Every changed Python file compiles clean (`py_compile`).

## Not verified (same limitation as every round in this file)

No network access and no installed Python dependencies in this sandbox -
`pytest` itself was never actually run, so "all tests pass" is asserted
from careful manual tracing plus real `httpx.Response` semantics, not
green CI output. Xavier needs to run the real suite to confirm.



Xavier's final ask for calling: incoming calls must work reliably for
both roles including backgrounded/terminated app states, "to the extent
supported by the target platform" - not just sophisticated WebRTC code.
Same verification discipline as every round before it, with one
important difference to be upfront about: this round's core deliverable
(real FCM client integration) has a hard external dependency this
sandbox cannot satisfy or verify - a real Firebase project and its
`google-services.json`, which only Xavier can create and which must
never be committed. Everything below was written and reasoned through as
carefully as static review, syntax/compile checks, and (for the backend
half) an actual executable test allow; **none of it has been compiled,
run, or verified on a device**. See the final status at the end.

## Backend

**FCM push is now sent data-only.** The `/calls/initiate` push included
both an FCM `notification` block and a `data` block. A `notification`
block gets auto-displayed by the OS using generic system styling
whenever the app isn't foregrounded - for an incoming call, that means a
plain banner instead of the app's own rich notification (full-screen
intent, custom ringtone, call-specific styling), completely bypassing
it. `_send_fcm()` gained an opt-in `data_only` parameter (default
preserves the exact existing behavior for its other three call sites in
`workers.py`, which are unrelated reminder/nudge notifications, not
calling); the `/initiate` call site now passes `data_only=True`. Added
`test_incoming_call_push_is_data_only` to verify this, mocking
`_send_fcm` to inspect the call rather than requiring a real Firebase
project.

## Flutter - full FCM client integration

**`pubspec.yaml`**: added `firebase_core`/`firebase_messaging`. Versions
are a best-effort estimate from training knowledge, compatible with this
project's Flutter/Dart SDK constraint - **not verified against a live
pub.dev**, since this sandbox has no network access. Run `flutter pub
get` to confirm/resolve.

**Android Gradle**: the Google Services plugin is declared in
`settings.gradle` (matching this project's existing plugins-DSL
convention exactly - the same style already used for the Android/Kotlin
plugins there) and applied *conditionally* in `app/build.gradle`, only
if `google-services.json` exists - mirroring the identical
conditional-file pattern this project already uses for its release
signing keystore. The app builds exactly as it does today until that
file is added; nothing breaks in the meantime. `.gitignore` updated so
that file can never be accidentally committed once it exists.

**`main.dart`**: `Firebase.initializeApp()` wrapped in try/catch - without
a real Firebase project this throws, and the catch means the app runs
exactly as it always has (local notifications via polling only) rather
than crashing on startup for every user until Xavier's project exists.
Inside that guard: the background message handler
(`firebaseMessagingBackgroundHandler` - a top-level
`@pragma('vm:entry-point')` function, as FlutterFire requires for it to
survive tree-shaking and run as its own isolate entry point),
`onMessage` (foreground), `onMessageOpenedApp` (tap while backgrounded),
`getInitialMessage()` (cold-start tap - stashed since no navigator
exists yet at this point in `main()`, consumed by `SplashScreen` once it
does), and `onTokenRefresh`.

**One shared call-routing mechanism, not a second system**:
`notification_service.dart` gained `handleForegroundFcmMessage()`, which
calls the exact same `showIncomingCall()` the poller already calls -
foreground behavior is identical no matter which mechanism detected the
call. `navigateFromPayload()` (already fixed in an earlier round) now
serves local-notification taps, `onMessageOpenedApp`, and
`getInitialMessage` alike.

**Removed the dormant `lib/core/notifications/`** (a complete but never-
imported parallel Firebase implementation, flagged in earlier rounds).
With real FCM now wired into the actually-used files, keeping it around
would have been exactly the duplicate/unused Firebase code this pass was
asked to look for and remove.

**Token lifecycle**: `api_service.dart` already had a correct, unused
`registerFcmToken()` (dead code from earlier FCM-readiness work, never
wired up). It's now called from `GlobalPollerService.start()` - already
the one function every login/registration/biometric-reauth/session-
restore path calls, so registering there covers all of them without
duplicating the call at each site, and naturally re-associates the token
with whichever user is now authenticated on a given device. Also wired
to `onTokenRefresh` for the case of a token changing under an
already-running session.

**Two-different-calls notification gap fixed along the way**: every
incoming-call notification previously shared one fixed notification ID
- a second distinct call (rare, but possible) would have silently
replaced the first rather than getting its own slot. The ID is now
derived from `room_id`, so different calls get distinct notifications
while the *same* call detected through both FCM and polling still
correctly collapses into one.

## Final Self-Audit (done explicitly, not assumed)

Checked for: duplicate notification handlers (found and removed the
dormant system above), stale imports (none left dangling), hardcoded
credentials (none - `google-services.json` is referenced only by a file-
existence check, never embedded), token value logging (none - only
non-value log lines like `TOKEN_ISSUED` existed already), role-specific
incoming-call assumptions (already fixed in an earlier round; re-
confirmed clean here), navigation races (the cold-start path clears its
pending state immediately on read, before acting on it, so a
theoretical re-entry is a safe no-op), and one now-stale doc comment in
`notification_service.dart` referencing a symbol that didn't actually
exist anywhere in the file (a leftover from before this round - removed).

## Final status

**Code hardening complete for what a sandboxed environment can produce
and verify — physical device verification and Xavier's own external
Firebase setup are both still required before this is actually
"working" in the sense the objective describes.** More precisely, three
distinct things are true simultaneously:

- Every piece of Flutter/Gradle code needed for FCM client integration
  is now written, follows the platform's required patterns as I
  understand them, and is defensively guarded so it cannot break the
  app for anyone building it before Firebase is configured.
- **None of it has been compiled.** No `flutter pub get`, no `flutter
  analyze`, no `flutter build`, in this sandbox - no network, no Flutter
  toolchain. The package versions are a best estimate, not a
  verification.
- **None of it has been run.** Real FCM delivery - foreground,
  backgrounded, fully terminated - requires Xavier's own Firebase
  project, a real device, and an actual push round-trip. Nothing here
  confirms an incoming call actually wakes a terminated app; it
  confirms the code that's supposed to make that happen is in place and
  reads correctly.

The backend half (`data_only` push) is the one piece of this round
covered by an executable, passing-by-inspection test
(`test_incoming_call_push_is_data_only`) rather than reasoning alone.



Xavier's ask started narrow (backend tests failing in CI, then a Flutter
build failure) and grew into the full "final production-hardening pass
for calling" spec he provided partway through - 19 phases, an explicit
exit-criteria checklist, and an explicit rule not to declare it complete
without real verification. Same discipline as every other round in this
file: every finding checked against the actual current code (not the
prior summary of work Xavier provided, which was treated as a claim to
verify, not a fact to build on - most of it held up; a few things it
didn't mention or got slightly wrong are called out below), nothing
shipped without at least a syntax/compile check, and every genuinely
untestable claim marked as such rather than asserted. No Flutter/Dart
toolchain, no physical device, no live Redis/Cloudflare/FCM, and no
network access existed in the sandbox this round was done in - see
**What's still open** at the end for exactly what that means.

## Backend CI unblock (the original ask)

Two independent bugs, both in `call_state.py`, were failing 13/13 tests
in `test_call_state.py`:

1. **Event-loop mismatch.** `_store` is a module-level singleton whose
   Redis client was cached forever once created. `asyncio_mode = auto`
   gives every test function its own fresh event loop, so the cached
   client's connections - bound to whichever loop created them - broke
   the moment a different test reused them, producing the exact
   `Future ... attached to a different loop` / `Event loop is closed`
   errors in the failing run, with a alternating pass/fail pattern
   (redis-py silently discards a broken connection and reconnects fresh
   on the next call). Fixed by rebuilding the client whenever the running
   loop differs from the one it was built on - a no-op in production,
   which never changes loops. Verified with a standalone asyncio
   simulation reproducing the exact failure pattern before the fix and
   all-pass after, since the real dependency wasn't installable here.
   The identical pattern existed in `rate_limit.py` (its own docstring
   calls out sharing "the same shape") - fixed pre-emptively, though it
   wasn't causing visible failures since that class already fails open on
   Redis errors.

2. **Invalid Redis TTL.** Two expiry tests use `ttl_seconds=0` to
   simulate an already-expired session; `_RedisCallStore.create()` passed
   that straight through to Redis's `SET ... EX 0`, which Redis rejects
   outright. `_write()` and `set_pending()` in the same class already
   clamped this to `max(ttl_seconds, 1)` - `create()` just missed it.
   One test (`test_sweep_removes_expired_sessions`) also assumed
   in-memory-only sweep semantics that the Redis backend's *documented*
   no-op `sweep_expired()` (Redis's own key TTL handles it) can never
   satisfy - made that one assertion backend-aware instead of asserting
   something structurally impossible for the Redis path.

Separately, the next CI run surfaced a Flutter build failure:
`webrtc_service.dart:882` assigned a `Map<dynamic, dynamic>` (from
`flutter_webrtc`'s `StatsReport.values`) directly into a
`Map<String, dynamic>?` variable, which Dart's compiler rejects even
though every key is always a string in practice. Fixed with an explicit
`Map<String, dynamic>.from()` conversion.

## Full calling-system audit

With CI green, Xavier provided the full hardening spec and confirmed the
uploaded release zip matches `main`. What follows is organized by the
spec's own phase numbers.

**Phase 2 (incoming-call pipeline) - one real bug the prior summary
hadn't caught.** The *live* notification tap handler
(`notification_service.dart`'s `navigateFromPayload`) sent every
incoming-call notification tap to `/direct-chat` with a **hardcoded
`role: 'seller'`**, instead of the actual call screen - a tapped
incoming-call notification never opened the call UI at all, and
misidentified the recipient's role whenever a buyer received one.
Ironically, a complete-but-entirely-dormant "v3.0" Firebase notification
system (`lib/core/notifications/`, confirmed never imported anywhere in
real app code) already had the *correct* routing logic. Fixed the live
path to match: re-check the call's live status via the existing
`checkIncomingCall(listingId)` endpoint at tap time (a fresh, still-valid
room-scoped token, rather than trusting anything time-sensitive from
when the notification was first shown) and route to `/voip-call` with
the correct role, falling back to chat only if the call's no longer
pending.

**Phase 5 (WebSocket reliability) - heartbeat was genuinely absent.**
Read the entire WS handler; there was no ping/pong and no receive
timeout at all, so a silently-dropped mobile connection (no clean
FIN/RST) was only ever caught by the underlying TCP stack's own
often-multi-minute dead-peer detection. Implemented on both sides:
server pings every 15s via `calls.py`, closes after 3 missed (~60s total
silence, with an explicit close frame rather than relying on the ASGI
server's own handler-return behavior); client replies to pings and also
runs its own independent 25s watchdog that proactively reconnects if
nothing arrives at all, rather than depending solely on the transport's
error/close callbacks. Also hardened the receive loop against malformed
(non-JSON or non-object) signaling messages, which previously would have
thrown unhandled and killed the loop for that connection.

**Phase 7 (TURN/ICE) - refresh groundwork existed but was never wired
up.** `cloudflare_turn_client.py` itself checked out clean (real circuit
breaker, no secret leakage, correct STUN/TURN separation, graceful
degradation). `webrtc_service.dart` already tracked credential expiry
(`_iceCredentialsExpireAt`) with a comment naming
`RTCPeerConnection.setConfiguration()` as the intended mechanism, never
implemented. Wired it up: `_attemptIceRestart()` now refetches TURN
credentials and calls `setConfiguration()` if they're within 2 minutes of
expiry, before restarting - deliberately a pre-restart check only, not a
continuous mid-call refresh loop (not justified for BROKA's short 1-to-1
calls, per the existing design note). Defensively wrapped: since
`setConfiguration()`'s exact behavior on this `flutter_webrtc` version
couldn't be verified without a device, any failure here falls through to
restarting with whatever configuration is already active - never worse
than the prior always-stale behavior, only better if it works.
**DEVICE-VERIFICATION-REQUIRED.** Separately confirmed the "don't falsely
claim TURN was used" requirement was already correctly implemented - the
connection-path diagnostic checks the actual selected candidate pair's
type (`relay`/`srflx`/`host`), not just whether TURN was configured.

**Phase 9 (Android) - two real gaps.** `CallForegroundService.kt`, the
native bridge, and the Dart wrapper were all solid on inspection (partial
wake lock with a 30-minute safety cap, try/catch on both sides of the
platform channel, and - specifically checked, not assumed - both caller
and callee correctly trigger the foreground service, no asymmetry).
Found and fixed: (1) `usesCleartextTraffic="true"` shipped app-wide even
though production always defaults to HTTPS - moved to a new
`android/app/src/debug/AndroidManifest.xml` override so release builds
can never carry unencrypted traffic while local dev against an HTTP
server still works; (2) the incoming-call notification already sets
`fullScreenIntent: true` (correctly configured otherwise - max priority,
call category, custom ringtone) but the manifest never declared the
`USE_FULL_SCREEN_INTENT` permission that flag depends on, so it likely
silently degraded to a plain heads-up notification on modern Android -
added it. One stale (not fixed - cosmetic only), overly-pessimistic code
comment was found describing a reconnect "room full" race that the
server's actual uid-keyed stale-socket-replacement logic already handles
correctly.

**Phase 10 (iOS) - confirmed, not invented.** The exported `ios/` tree
has only `Info.plist` and icon assets - no `AppDelegate.swift`, no Xcode
project files, no Podfile, and the plist is an unmodified Flutter
template with zero VoIP/CallKit/background-mode configuration. Matches
the prior account. Per the spec's own explicit instruction, documented
this rather than writing untestable Swift.

**Phase 11 (call-result security) - a real outcome-classification gap.**
There was no way to distinguish "caller cancelled before the callee
answered" from "callee never responded" - both were recorded as
`missed`. Worse: the call-history card widget only had explicit handling
for `missed`/`declined`, so naively adding a `cancelled` value without
updating it would have made cancelled calls silently render as
*successfully completed* ones - caught before shipping it. Fixed across
`calls.py` (new `cancelled` outcome, mapped to the existing `missed`
CallState rather than inventing a new terminal state), `voip_call_screen.
dart` (distinguishes via the existing `_isCaller` flag), and the history
card (own icon/label, still offers "Call back"). Everything else in
`calls.py`'s `/log-result` - idempotency, deriving identity from the
authoritative session rather than the client's claims - checked out
exactly as the prior account described.

**Phase 12 (security audit) - one genuinely exploitable gap found.**
`POST /calls/initiate` let a seller supply an arbitrary `callee_id` and
would create a call session (plus send an FCM push, when configured) to
**any** registered user, with no check that a real negotiation thread
ever existed between that buyer and the listing - any seller could
effectively cold-call/harass any other user on the platform. Fixed by
requiring an existing `NegotiationMessage` row for that
`(listing_id, buyer_id)` pair before allowing the call, mirroring the
identical thread-scoping check already used elsewhere in the codebase
(`negotiate.py`/`media.py`) rather than inventing a new pattern. One
accepted tradeoff, not swept under the rug: legacy `NegotiationMessage`
rows with a `NULL buyer_id` (a pre-existing data-quality note already in
that model) won't satisfy this check, so a genuinely old thread could see
a 403 - fails safe rather than unsafe, and self-heals the moment the
buyer sends one new message. Also: replay/enumeration risk was checked
and is already handled (a token can't be replayed against a terminal
session; 128 bits of room-ID entropy; 5-minute call-token expiry), and a
targeted sweep for tokens/SDP/credentials leaking into logs on either
side found nothing.

**Endpoint-level test coverage did not exist at all** for `calls.py`
before this pass - `test_call_state.py` only exercises the internal
store directly, never the actual HTTP routes. Added
`tests/test_calls_initiate.py`, covering the fix above plus five other
cases from the spec's required test list (buyer/seller happy paths,
missing `callee_id`, self-call, invalid listing) - written carefully
against the real model and endpoint code, mirroring `test_auth.py`'s
established SQLite-fixture/`AsyncClient` pattern, but **not executed**
(no pytest/DB in this sandbox).

**`voip_call_screen.dart` - a real duplicate-action gap.** The Accept
button had no guard against a rapid double-tap, and
`WebRtcService.start()` has no internal idempotency check of its own - a
double-tap could fire two concurrent media/connection setups (two
camera/mic requests, two peer connections). Fixed by guarding Accept
(reusing the existing `_accepted` flag) and adding a shared `_endingCall`
guard across Decline, both hangup buttons, and the ring-timeout
auto-hangup path, so none of the four ways a call can end can fire
twice.

**Phase 15 (observability) - one real gap, one dangling hook.** ICE
restart count was tracked internally (for bounding retries) but never
surfaced in the `ConnectionDiagnostics` summary alongside the setup-time
and reconnect-count fields that already were - added it. Separately,
`onDiagnostics` itself was never actually assigned to anything in
`voip_call_screen.dart`, so the whole diagnostics summary reached nothing
outside the service - wired it to a single local debug log line per
call, explicitly not sent anywhere, per the spec's own caution against
implying backend reporting that isn't happening.

**Phase 18 (CI) - `flutter analyze` never ran at all.** The build
workflow only ever ran `flutter pub get` then the full release build -
no static-analysis step in between, meaning a type error (the exact
class this round's own Flutter build fix was) would only surface after
the much slower full APK build. Added a non-blocking `Analyze` step
between them - non-blocking specifically because this pass doesn't
include auditing every pre-existing lint warning across the whole app,
and a sudden strict gate here could block releases over unrelated
findings. Also incidentally explains why the GitHub release had been
stuck since June: `build-apk` `needs: backend-test`, and the backend
tests had been failing since before this round started.

**Phase 19 (docs).** Added `CALLING.md` (architecture, state machine,
incoming-call flow, TURN flow, Android/iOS status, the multi-instance
limitation, required env vars, and what device testing must still
confirm - none of it existed as a single reference before), linked from
`ARCHITECTURE.md`, and added a small note to `FCM_SETUP_REMAINING.md`
about `navigateFromPayload`'s now-more-defensive behavior.

## Final status

Per the spec's own exit-criteria and decision rule:

- **Buyer→seller / seller→buyer**: code-level symmetry confirmed
  (`_initiateCall` handles both directions correctly, the seller-side
  spoofing gap above is fixed) - **ready for device testing**, not
  verified beyond that.
- **Android**: foreground/background lifecycle, permissions, and the two
  fixes above are in solid shape on inspection - **ready to move forward
  pending the actual device-test matrix** (Phase 17), which this sandbox
  cannot run.
- **iOS**: **DEFERRED** - zero infrastructure, confirmed and documented,
  not invented.
- **Multi-instance signaling**: **known, documented, deliberate
  limitation** - state is already Redis-safe; live WS connections are
  not, by design, for this pass.
- **HIGH/CRITICAL remaining**: none identified in this pass's own review
  beyond what's listed as still open below.

**This is explicitly not "CALLING HARDENING COMPLETE."** Phase 17
(physical-device test matrix) has not been run - it categorically cannot
be, in a sandbox with no phone, no Flutter toolchain, and no live
network. Every fix above was verified as rigorously as static reading,
compile/syntax checks, and (for the event-loop fix specifically) a
standalone reproduction allow - not by actually placing a call. Before
moving to the next BROKA feature, Xavier needs to: run the two new/
updated backend test files in real CI, get a real `flutter analyze` +
release build, and run the physical-device matrix from Phase 17 (two
devices, all listed call/network/lifecycle combinations) - classifying
any failure found there as CODE BUG / INFRASTRUCTURE / DEVICE LIMITATION
/ TEST ISSUE per the spec's own instruction, not assuming the best case.



Continuing the production-readiness pass from Round 19 (security) into
scalability - the second category requested, in the order requested.
Same discipline: every finding verified against the actual code, every
fix re-compiled and manually traced, nothing assumed correct because it
looked fine on a skim.

**Database connection pool had zero tuning.** `create_async_engine()` was
called with no `pool_size`, `max_overflow`, `pool_recycle`, or
`pool_pre_ping` - SQLAlchemy's bare defaults. Missing `pool_recycle`
specifically is a well-known production failure mode: most managed
Postgres providers (Render's included) silently close connections that
sit idle past some server-side timeout, and without `pool_recycle` set
below that, SQLAlchemy can hand out a connection the server already
dropped - surfacing as an intermittent "connection was closed" error
that looks random and hits hardest during low-traffic periods. Fixed:
added `pool_recycle=300`, `pool_pre_ping=True` (a cheap liveness check
before handing out any pooled connection, second layer of defence), and
made `pool_size`/`max_overflow` env-configurable (`DB_POOL_SIZE`,
`DB_MAX_OVERFLOW`, defaulting to 10/20) since the right ceiling depends
on Xavier's actual Postgres plan's connection cap, not something this
code can know. Scoped to only apply for real network-hop databases -
SQLite (this app's dev default) doesn't use the same pool model and
`create_async_engine` rejects these kwargs for it.

**Multiple real N+1 query patterns, found with a systematic sweep, not
just the ones already suspected.** Wrote a small AST-based scanner (a
for-loop containing an `await ...execute()` call) across the whole
backend rather than relying on spot-checks, then triaged every hit -
some were false positives (one-time startup schema patches, a one-time
category-seeding script), the rest were real:

- `domains/trust/completion_rate.py`'s `flag_leaked_deals()` and
  `recompute_all_dcr()` (both from Rounds 16/18) - 2 queries per
  candidate deal and 2 queries per seller respectively, meaning query
  count scaled linearly with deal/seller volume. Batched: one query per
  evidence type across the whole run instead of per-record, with the
  per-record time-scoping now done in memory against the already-fetched
  set. Re-traced all three existing `test_completion_rate.py` tests by
  hand against the batched logic to confirm identical outcomes to the
  original per-record version before considering this done - same
  discipline as when those tests were first written, since nothing here
  can actually be executed in this sandbox.
- `routers/negotiate.py`'s `get_inbox()` - a real N+1 nested two levels
  deep on the seller-view side (one query per listing, then one query
  per buyer on that listing). Batched the buyer-view's per-listing
  Listing+User fetch and the seller-view's per-listing re-fetch (which
  was refetching listings the function already had, individually) and
  per-buyer User fetch into single `IN (...)` queries. Deliberately
  **not** touched: the per-thread "last message" query and
  `_thread_unread_and_seen()` (which itself does 2 more queries per
  thread). Batching those needs a greatest-n-per-group query and directly
  touches unread/last-seen state - real remaining work, left for a
  focused pass rather than rushed alongside everything else here, since
  getting that subtly wrong without live-data testing is a worse outcome
  than leaving it as a known, flagged gap.
- `routers/reviews.py`'s review-submission and reviewable-deals-list
  endpoints - found while fixing the N+1 in the second one (see below for
  why the first turned out to matter far more).

**Found something more serious while looking at that reviews.py N+1:
`DealStatus.completed` doesn't exist on that enum** (the same bug flagged
and left alone earlier this session, back when it was out of scope -
now directly in a file already being edited for this pass, so fixed
properly rather than left a second time). Consequence: `submit_review()`
evaluated `(DealStatus.agreed, DealStatus.completed)` as part of its
eligibility check, which raises `AttributeError` the instant it runs,
for every deal regardless of status - meaning this endpoint has never
successfully completed a review. Fixed the typo to `DealStatus.released`.
But the deeper issue was what came after the crash: on success, the
endpoint set `deal.status = DealStatus.completed` and bumped
`seller.completed_deals`, labelled "idempotent guard" - except
`completed_deals` is already correctly bumped by the actual escrow-
release flow (`routers/escrow.py confirm_delivery`, the auto-release
sweep). Naively patching the enum typo without noticing this would have
gone from "reviews always crash" to "reviews double-count completed_deals
for every deal that's both released and reviewed" - the normal case, not
an edge case. Removed the status mutation and the counter bump entirely;
a review now only creates the Review row and updates the seller's rating
(`_recalc_seller_rating`, which is already purely Review-table-based and
unaffected). Fixed the identical typo in the reviewable-deals list too.

**Deal and NegotiationMessage were both missing indexes on their most
heavily-filtered columns.** `Deal` had none at all on `seller_id`,
`buyer_id`, `listing_id`, or `status` - every query in every round this
session that filters a deal by any of these (which is most of them:
`compute_dcr`, `seller_deal_stats`, the sweep's `due_deals`, escrow
flows) was a full table scan. `NegotiationMessage` had none at all,
despite `(listing_id, buyer_id)` being the thread-identity pair queried
constantly throughout `negotiate.py` and this session's leak-detection
work. (Checked `Listing` too, expecting the same gap - it already has
proper indexes on `seller_id`/`category`/`status`/`created_at`, so left
untouched; verifying before fixing caught this before wasting effort
"fixing" something that wasn't broken.)

Fixed both where the fix actually needs to happen twice: `index=True` /
a new composite `Index("ix_negotiation_messages_listing_buyer",
listing_id, buyer_id)` added to the model definitions (covers a fresh
deployment via `create_all()`), and a matching new `CREATE INDEX IF NOT
EXISTS` block added to `init_db()`'s existing ad-hoc schema-patch
mechanism (covers Xavier's already-created tables, which `create_all()`
never retroactively indexes - the exact same "gap that only bites an
existing deployment" shape as the missing-column bug Round 18 fixed,
just for indexes instead of columns). `CREATE INDEX IF NOT EXISTS` is
portable across SQLite and Postgres, unlike `ALTER TABLE ADD COLUMN`'s
`IF NOT EXISTS` support, which isn't reliable on SQLite - hence that
block still using try/except instead.

**Verification:** every file re-compiled clean, full session-wide
regression check re-run (not just this round's files), and the batched
`flag_leaked_deals()`/`recompute_all_dcr()` logic re-traced by hand
against all three existing tests, not just re-read and assumed
equivalent. Nothing here could be run against a real Postgres instance
or measured under actual concurrent load - the pool tuning and index
additions are reasoned from documented SQLAlchemy/Postgres/SQLite
behaviour, not benchmarked.

**Scalability is not fully closed out - still open, flagged rather than
silently skipped:**
- `get_inbox()`'s per-thread last-message and unread/seen queries (noted
  above)
- `core/workers.py`'s single in-process sweep loop won't coordinate
  across multiple app instances if BROKA ever runs more than one - though
  Round 19's row-locking fix means this is now *safe* under multi-
  instance concurrency (Postgres row locks work across separate
  processes/connections, not just within one), just not *efficient*
  (every instance would still redundantly poll)
- Several places construct a fresh `redis.asyncio` client per call
  (`core/stats_cache.py` and similar patterns elsewhere) rather than
  reusing a shared connection pool - real latency/resource cost at
  meaningful request volume, not yet addressed
- Media (voice notes, images) stored as base64 in the relational
  database rather than object storage - noted in Round 19 as a
  scalability concern when it was found from the security angle, not
  yet addressed here either

Continuing into these, and then the remaining "everything else"
category, next.

---

# BROKA — Round 19: Production-readiness audit, Phase 1 (Security)

Xavier asked for a full production-readiness pass - security, scalability,
everything else - treating this as potentially the last review before
launch. Tackling it in the order requested: security first. This round
covers security; scalability and the rest are still ahead.

Framed honestly at the start and worth repeating here: a codebase this
size doesn't get a genuine 9.5/10 audit in one sitting, and some things
(real load testing, a live penetration test, a second engineer's review)
need infrastructure this sandbox doesn't have. What follows is a
systematic pass through the highest-stakes categories for a payments
marketplace, with every finding verified against the actual code before
acting on it - the same discipline every other round this session has run
on - not a checklist skimmed and assumed correct.

**Two severe, exploitable bugs found and fixed:**

1. **Payment-callback forgery across three endpoints.** `mpesa.py`,
   `verify.py`, and `featured.py` each expose a Safaricom STK-callback
   route. `mpesa.py` had a secret-protected variant already built but the
   original unprotected route only logged a warning and processed the
   callback anyway - the warning did nothing. `verify.py` and
   `featured.py` had no protection at all. Net effect: anyone who could
   observe or guess a `CheckoutRequestID` (issued the moment any STK push
   starts, before payment completes) could POST a forged
   `{"ResultCode": 0, ...}` body and have a deal marked paid, get free
   "BROKA Verified" status, or get a free listing boost, with no real
   M-Pesa payment behind any of it.

   Fixed: all three routes now reject outright (404, not a warning) once
   `MPESA_CALLBACK_SECRET` is configured; `verify.py`/`featured.py` gained
   the missing secret-protected variants, mirroring `mpesa.py`'s existing
   pattern; and `MPESA_CALLBACK_SECRET` is now required at startup in
   production (`validate_startup()` in `core/config.py`), so this can't
   silently ship unconfigured. The env var itself, and the reasoning for
   it, were already documented in `.env.example` before this round - the
   code just never fully implemented what the docs described. Updated
   that comment to reflect it now covers all three routes and is
   required, not merely recommended.

2. **No row-level locking anywhere in the codebase, for a genuinely
   racy fund-moving flow.** The automated timeout sweep
   (`core/workers.py`) and manual buyer/seller actions
   (`routers/negotiate.py`, `routers/escrow.py`) check the *same* deal
   statuses to decide refund/release eligibility (`awaiting_resolution`,
   `awaiting_condition_check`, and `paid` all appear in both the sweep's
   `due_deals` filter and at least one manual endpoint's check) - meaning
   both could read a deal as eligible before either committed, and both
   fire a real M-Pesa B2C payout for the same deal.

   Fixed with a new shared helper,
   `domains/escrow/service.lock_deal_if_status()` - a `SELECT ... FOR
   UPDATE` row lock plus a re-check of status at the moment the lock is
   acquired, returning `None` if another transaction already moved the
   deal past that status. Real lock on Postgres; SQLAlchemy silently
   drops the clause on SQLite (this app's dev default, per
   `.env.example`), so the status re-check still runs there but without
   true concurrent protection - acceptable since `validate_startup()`
   already refuses to start in production on SQLite, so the dialect that
   matters for real concurrent traffic is the one where the lock holds.

   Applied at four call sites: the sweep's single per-deal dispatch point
   in `core/workers.py` (protects all five of its downstream timer
   branches at once, since they all act on whatever `deal` object the
   loop hands them), `negotiate.py`'s manual refund and manual release
   intents, and `routers/escrow.py`'s `confirm_delivery` endpoint - found
   by continuing to check every release/refund code path in the
   repository rather than stopping once the first two were fixed. That
   fourth one was missed on the initial pass; caught by deliberately
   re-sweeping for the same pattern rather than assuming two fixes meant
   the class of bug was closed.

**Checked and confirmed already solid, no action needed:**
- `SECRET_KEY`/`ZAC_SECRET` both have hardcoded fallback placeholder
  values in source, which looks alarming in isolation - but both are
  already enforced via `validate_startup()`/`validate_secret_key()`,
  which hard-fail production startup if either is still the default.
  Verified this is actually wired into `main.py`, not just present as
  unused functions.
- Rate limiting on login/register/OTP-request/OTP-verify: real Redis-
  backed sliding-window limiters, double-keyed where it matters (OTP
  request checks both phone and IP; login checks both IP and phone),
  correctly loosened only under `is_test`, confirmed properly scoped and
  not reachable from production config.
- JWT verification pins `algorithms=["HS256"]` explicitly rather than
  trusting the token's own header - correctly closed against algorithm-
  confusion attacks.
- No raw/string-formatted SQL anywhere in the backend - every query
  goes through SQLAlchemy's parameterized query builder.
- The v5 dispute engine's `_load_case_and_authorize()` already properly
  restricts every `/disputes/v2/{case_id}/*` endpoint to the deal's
  actual buyer, seller, or an admin - this fix predates this session
  (the docstring documents it as closing a prior IDOR bug), re-verified
  rather than assumed correct.
- `negotiate.py`'s message-history and inbox endpoints derive
  buyer/seller role server-side from the authenticated user, never from
  a client-suppliable role field, and reject cross-user inbox access
  outright.
- Media upload (`routers/media.py`) stores files as base64 data URIs in
  the database, never writes to disk with an attacker-influenced
  filename - no path-traversal surface exists for this upload path.
  (Storing binary media in the relational database at all is a
  scalability concern, not a security one - flagged for that phase.)

**Adjusted, not hard-failed:** CORS defaults to `allow_origins="*"` if
`ALLOWED_ORIGINS` is unset. Confirmed this backend has zero cookie-based
authentication anywhere in the codebase (grepped for `set_cookie`/
`request.cookies` - no matches) - auth is Bearer-token-only, attached
explicitly by the calling client rather than automatically sent by a
browser the way a cookie would be, which significantly de-risks a
wildcard origin compared to a cookie-authenticated app (no CSRF-style
account-takeover path). Still worth tightening - defense-in-depth, and
it only takes one future browser-based admin panel to change the
calculus - so added a production-startup **warning** (not a hard fail,
given the genuinely lower exploitability today) if `ALLOWED_ORIGINS` is
still unset in production.

**Not done, deliberately:** a live penetration test, dependency-CVE
scanning against a real vulnerability database (no network access in
this sandbox to run one), and load testing against real concurrent
traffic - all need infrastructure this environment doesn't have. Noted
here rather than silently skipped.

**Verification:** every file re-compiled clean with `py_compile`, plus
manual tracing for the undefined-name/wrong-variable class of bug
`py_compile` can't catch - the same discipline as every other round.
Nothing in this round could be exercised against a running server or a
real Postgres instance, so the row-locking fix's actual concurrent
behaviour is reasoned through (SQLAlchemy's documented `with_for_update`
semantics per dialect), not observed directly.

---

# BROKA — Round 18: External audit response — three real bugs fixed, ranking formula made faithful, tests added

Xavier shared a ChatGPT audit of the Volume 2 implementation. Checked it
against the actual code rather than trusting it (the same discipline this
whole effort has run on) - it turned out to be a mix of stale findings
(run against the pre-Round-17 zip, before the ML layer and Zeno persona
existed) and several genuinely correct, serious findings against code that
*is* current. Verified every claim independently before acting on any of
them; this round fixes what checked out.

**Confirmed stale, no action needed:** the audit's "ML layer essentially
not implemented" and "Zeno seller persona - significant gap" findings.
Both exist as of Round 17 (`core/ml/`, `SELLER_COACHING_PROMPT_ADDITION` +
the `zeno_seller_coach` override) - confirmed by checking the actual
working tree before writing anything, not by assuming the audit must be
wrong. Xavier confirmed separately that the audit ran against "the second
last source code."

**Three real, confirmed bugs, fixed:**

1. **Missing schema patch for the two new Deal columns (audit's #1, P0).**
   `leak_flag`/`leak_detected_at` were added to the Deal model in Round
   15-16 but never added to `init_db()`'s existing ad-hoc ALTER-TABLE
   list - the same list that already has a comment documenting this exact
   failure mode from an earlier round ("buy_agent_requests ADD COLUMN...
   this closes that gap"). `Base.metadata.create_all()` only creates
   tables that don't exist yet; it never alters an existing table to add
   a missing column. Any query touching either column against a deals
   table that already existed before this round would have failed
   outright. Fixed by adding both columns to that same list, the
   established pattern for exactly this - not an Alembic migration, which
   Xavier explicitly asked to skip since there's no data to migrate from,
   but the lightweight patch mechanism this codebase already uses for
   every other post-launch column addition. (SellerMetrics itself needed
   no entry - it's a genuinely new table, which create_all() does handle.)

2. **Leak-detection timing wasn't sequential (audit's #2, P0).** §3.2
   specifies 7 days with no payment, THEN a further 5 days of silence -
   12 days total, with the back half of it silent. The code checked "is
   the deal >7 days old" and "was the last message >5 days before now" as
   two independent conditions against `now`, not chained - so a deal
   agreed on day 0 with its last message on day 1 would incorrectly
   qualify as a leak on day 7, five days earlier than the design
   intends. Traced through the audit's own worked example by hand against
   the actual code before fixing it (confirmed the bug), then again
   against the fix (confirmed August 13, not August 8, is now the
   earliest a matching deal flags). Fixed in
   `domains/trust/completion_rate.flag_leaked_deals()`: candidates now
   require the full 12 days elapsed, and the silence check compares the
   last message against when the 7-day window closed, not against `now`.

3. **Leak evidence could bleed across deals (audit's #3, P0).**
   `NegotiationMessage` has no `deal_id` foreign key, only
   `(listing_id, buyer_id)`, and nothing in the schema stops the same
   buyer+listing pair from producing a second Deal row later (no
   UniqueConstraint enforces one deal per pair). The evidence queries
   (both the solicitation-flag join and the last-message check) matched
   only on listing_id+buyer_id, with no time bound - so an solicitation
   flag or silence from an EARLIER, already-resolved deal between the
   same two parties could count as evidence against a newer, unrelated
   one. Fixed by scoping both queries to
   `NegotiationMessage.created_at >= deal.created_at` - the closest proxy
   available to "belongs to this deal's thread" without a schema change.

**One P1 finding fixed properly rather than left as a documented
trade-off:** the ranking formula (audit's #5/#6). Round 16 stored
rank_score as trust+DCR+response renormalised to 0-1, with freshness
applied as an ORDER BY tiebreaker afterward - reasoned at the time as a
portability trade-off (the doc's literal blended formula needs
Postgres-only EXTRACT/GREATEST, which would break on this app's SQLite
dev default). Reconsidering under audit scrutiny, that trade-off was worse
than documented: rank_score is a float, exact ties are rare, so a
tiebreaker-only approach meant freshness had almost no practical effect on
ordering at all, not just a mathematically-inexact one. Fixed by storing
the RAW weighted sum (not renormalised) in
`completion_rate.recompute_all_dcr()`, and adding freshness as a genuine
weighted term in `listings/service.py` via `case()`-bucketed date
comparisons (`Listing.created_at >= <python-computed datetime constant>`)
rather than a date-diff SQL function - portable across both dialects
(plain `>=` on a datetime works identically on SQLite and Postgres) while
actually implementing the real 0.35/0.30/0.15/0.20 formula instead of
approximating it. Added `DEFAULT_RANK_SCORE_FOR_NEW_SELLER`, computed from
the same neutral assumptions used everywhere else in this chapter, rather
than a second hardcoded cold-start number.

**One P1 finding fixed after confirming the audit's read of the actual
flow:** the M-Pesa protection badge (audit's #7). `mpesa_confirmation_screen.
dart` had `const ProtectionBadge(status: 'agreed')` - a deliberate choice
at the time (the screen is only ever reached right after an STK push, for
a deal still genuinely at `agreed`), but the audit is right that hardcoding
is fragile regardless of how correct the common case is - a live status is
cheap to fetch here and was already available via the existing
`getEscrowState(dealId)` endpoint, unused by this screen until now. Fixed:
fetched once via a new `_loadLiveDealStatus()`, same error-swallowing
pattern as the existing `_loadDisputeSummary()` (a failed fetch must never
block or error the actual payment flow), falling back to the same
'agreed' default that was already correct for the normal case.

**Tests added for the two most safety-critical fixes.**
`backend/tests/test_completion_rate.py` - the audit's #4/P0 finding
("no Volume 2 tests... especially dangerous because DCR is now
influencing seller visibility") was correct, and this round fixed exactly
the kind of subtle timing/scoping logic most likely to regress silently.
Covers: DCR cold-start (empty history -> exactly the 80% prior), the
leak-timing fix directly (a deal at 8 days + 5-day-old message must NOT
flag; the same shape at the full 12 days must), and the cross-deal
scoping fix directly (an earlier deal's solicitation flag must not
contaminate a later deal's evaluation). Followed the existing
`test_escrow.py` fixture pattern (temp-file SQLite + `reset_engine()` +
real `init_db()`) rather than inventing a different one.

**Caught in my own test before it shipped:** the third test's own fixture
data was wrong on first draft - I placed Deal B's "proof of continued
activity" message shortly after deal creation instead of after its leak
window closed, which (traced by hand, since nothing here can be executed)
would have made the test's own data register as silence and fail against
correct code, not pass against broken code. Caught by manually tracing
every test's timestamps against the fixed logic before considering any of
this done, the same discipline applied to the implementation itself -
not by running pytest, which isn't possible in this sandbox.

**Not done, deliberately, matching the audit's own P2/P3 framing:** the
external listing-sold-outside-BROKA leak signal (still no data source -
audit agrees this is an acceptable phased gap), real response-time
tracking (still a neutral placeholder - audit agrees ML/analytics
maturity is appropriately deferred at current data volume), position-
aware seller coaching, and distributed locking for the nightly workers
under multi-instance deployment (audit itself frames this as "fix before
horizontal scaling," not before this pilot - Xavier is running a single
Render instance today, so speculative distributed-lock infrastructure
for a scaling scenario that doesn't yet exist was left out rather than
built preemptively).

**Verification:** every backend file touched this round re-compiled clean
with `py_compile`, plus a full session-wide re-check of every file touched
since Round 15. The new test file can't actually be executed in this
sandbox (no pytest installed, no network to install it) - every one of
its three DCR/leak-detection assertions was instead traced by hand against
both the buggy and fixed code, the same way the fixes themselves were
verified, and Postgres-vs-SQLite portability of the new ranking SQL was
reasoned through rather than tested against a real Postgres instance
(none available here either).

---

# BROKA — Round 17: Volume 2 Chapters 4-5 — ML layer (heuristic-first) and Zeno's seller-coaching persona

Implemented §4.1-4.5 (ML layer) and §5.1-5.4 (persona) - the last two
chapters of the Volume 2 design journal. Rounds 15-16 covered §2-3.

**Chapter 4 shipped exactly as §4.4 sequences it: heuristic-only, nothing
trained.** BROKA has zero completed deals in any category (empty database,
per Round 15's constraint), nowhere near the doc's own 300-deals-per-
category threshold for trusting a learned model over a heuristic. Built
the full core/ml/ package - feature_extraction.py, predict.py, train.py -
all real and runnable, but predict.py's predict_price()/predict_leak_risk()
check for a trained artifact first and fall through to a heuristic every
single time today, and train.py's train_all() checks the same 300-deal
threshold per category and skips (logging why) anything below it. Nothing
here is stubbed-but-pretends-to-work; it's genuinely heuristic-only,
matching current data reality, with the model path already wired for the
day a category actually crosses the threshold.

**lightgbm/joblib are not installed.** train.py imports both lazily,
inside the one function that needs them, specifically so nothing else in
this package (predict.py's heuristic path, which is what's live) breaks
if they're absent. Added both to requirements.txt as commented-out lines
with a note on when to uncomment them, rather than as live dependencies
for a training path that can't run yet anyway.

**§4.3 calls for a synchronous MLPredictionService.** That's the right
shape once a category has a loaded model - pure in-memory inference, no
DB call. It isn't achievable for the heuristic fallback today: the
heuristic needs a live category-average query, and this codebase is async
SQLAlchemy throughout with no synchronous DB path anywhere to reuse.
predict_price()/predict_leak_risk() are async for now; the day a category
first gets a trained artifact, that category's predictions stop touching
the DB at request time at all, which is what actually converges toward
§4.3's intent rather than a permanent workaround.

**Caught my own design mistake before it shipped:** first draft put
MLPredictionService as an AIBrokerService instance attribute. AIBrokerService
is constructed fresh on every request (`svc = AIBrokerService()` in the
router, per call) - the whole point of caching a loaded artifact in memory
would have been lost, silently, the first time a model actually existed.
Moved it to a module-level singleton (`ml_prediction_service` in
core/ml/predict.py) instead.

**Chapter 5's coaching persona is its own constant, not merged into
ZENO_PROMPT, and only applies behind a new `zeno_seller_coach` system_override**
- never the plain `zeno` override `zeno_screen.dart` and `product_screen.dart`
also send through the same `/negotiate/chat` endpoint. §5.4 is explicit that
the encouraging/coaching tone "applies to dashboards, pricing help, and
general check-ins, never to an active dispute conversation" - scoping this
to its own override value is what actually enforces that, rather than just
documenting it and hoping every future caller remembers.

`seller_dashboard_screen.dart`'s tips prompt only asked for pricing tips
before this round - nothing in it touched completion rate or ranking at
all, so the new coaching persona would have had nothing relevant to apply
to. Broadened the prompt to include the seller's real DCR (now available
per Round 16) and explicitly invite a visibility-framed tip when there's
room to improve, so §5.3's "always cite a specific, real number" and
"frame every suggestion in terms of what the seller gains" bullets have
actual seller data to work with instead of sitting unused.

**Real bug caught mid-edit, not left in:** my Dart change called
`ApiService.zenoChat(..., systemOverride: 'zeno_seller_coach')` before
`zenoChat()` had any such parameter - it hardcoded `system_override: 'zeno'`
in its request body with nothing to override it. Would not have compiled.
Added `systemOverride` as an optional named parameter (default `'zeno'`,
so the other two existing callers are unaffected) before this went further.

**Where it's wired:**
- `core/ml/feature_extraction.py` (new) - `count_completed_deals_by_category()`
  (the §4.4 gate everything else checks), `extract_pricing_examples()`,
  `extract_leak_risk_examples()` (reuses §2.2's off-platform-solicitation
  audit trail and §3's leak_flag as labels - a classifier needs both
  classes, and both already exist from Rounds 15-16)
- `core/ml/predict.py` (new) - `MLPredictionService`, heuristic price
  estimate (category-median-of-comparable-deals, wide confidence band,
  falls back to the seller's own asking price when a category has zero
  comparable deals yet) and heuristic leak-risk score (hand-weighted, not
  learned - §4.2's classifier replaces this body once labelled examples
  exist)
- `core/ml/train.py` (new) - real LightGBM training code, gated by the
  300-deal threshold per category
- `core/workers.py` - `task_retrain_ml_models()`, wired into the same
  sweep loop as Rounds 15-16, gated via the Redis stats-cache helper
  (lower stakes than DCR's DB-based gate - this runs train_all(), which
  for the foreseeable future just finds every category under threshold
  and logs that, so an occasional redundant run costs almost nothing)
- `domains/ai_broker/service.py` - `price_recommend()` now grounds its
  prompt in a real heuristic number instead of letting the LLM invent
  one; needed a `db` parameter it didn't have before, threaded through
  `domains/ai_broker/router.py`'s endpoint too
- `routers/negotiate.py` - `SELLER_COACHING_PROMPT_ADDITION` constant
  (§5.3's block plus §5.4's guardrail against revealing exact thresholds/
  weights/window durations, even if asked directly); new `zeno_seller_coach`
  branch in the `/chat` handler
- `services/api_service.dart` - `zenoChat()` gained the `systemOverride`
  parameter described above
- `seller_dashboard_screen.dart` - tips prompt broadened to include DCR
  and switched to the new scoped override

**Verification:** every backend file re-compiled clean with `py_compile`,
same as Rounds 15-16, including a full session-wide re-check across every
file touched since Round 15. Both touched Dart files passed a brace/paren
balance check - `seller_dashboard_screen.dart` shows the same pre-existing
1-paren "mismatch" Round 16 already traced to a regex character class in
an untouched line, confirmed again this round by checking that this
round's edit added exactly one open and one close paren (perfectly
balanced on its own). Two real bugs were caught before shipping this
round, both described above - neither would have been caught by
`py_compile` alone, which is why every new function got a manual re-scan
of its local names against its imports on top of the compile check.

**Not done, on purpose:** the dedicated backend test files §6.2's task
table lists (test_completion_rate.py, test_leak_detection.py,
test_off_platform_signal.py, test_ranking.py, and whatever Chapter 4/5
would need) were not added, for Chapters 2-3 or this round. Verification
throughout has been py_compile plus careful manual review, not an actual
pytest run - no dependencies are installed and no network access exists
in this sandbox to install them. That's a real gap between this delivery
and an actually-tested one; worth closing before this reaches production,
not just noted here.

This closes out Volume 2 end to end (§2 through §6, per the doc's own
build order in §6.3) across Rounds 15-17.

---

# BROKA — Round 16: Volume 2 Chapter 3 — Deal Completion Rate, leak detection, ranking integration, seller dashboard

Implemented §3.1-3.7 of the Volume 2 design journal (Deal Completion Rate).
Same no-migrations constraint as Round 15 - the new SellerMetrics table
and Deal.leak_flag/leak_detected_at columns are added straight to the
models, nothing to migrate from with an empty database.

**No agreed_at column.** §3.7 asks for one "if not already derivable from
an audit log entry." It's not just derivable but exactly equal: every Deal
row is created already at DealStatus.agreed (confirmed against every
creation call site back in Round 15's investigation), so Deal.created_at
already IS the agreement timestamp. Added nothing rather than a column
that would always duplicate an existing one.

**dcr_score/rank_score went on a new SellerMetrics table**, per the doc's
own "cleaner if these fields are expected to grow" - Chapter 4 already
earmarks more seller-level ML outputs that would otherwise mean repeatedly
widening User.

**Two more places Volume 2 assumed something that isn't actually there:**
- §3.4's "average response time (existing metric)" - it isn't. Grepped the
  repo the same way Round 15 checked for escrow success rate; no response-
  time tracking exists anywhere. response_time_score is a neutral 0.7
  placeholder for every seller so the ranking formula's shape is complete
  (all 4 weighted terms present, correctly normalised) without silently
  inventing a whole response-time-tracking subsystem that wasn't the ask.
- §3.4's ranking formula blends freshness in as a weighted numeric term
  (rank_score + 0.20*freshness_score). Doing that literally in SQL needs
  EXTRACT(EPOCH FROM ...) and GREATEST(), both Postgres-only - this app's
  dev default is SQLite (.env.example: sqlite+aiosqlite), so that query
  would work in production and break locally. Used Listing.created_at as
  a plain ORDER BY tiebreaker instead - same practical effect (newer
  listings still rank above otherwise-equal ones), fully portable.

**§3.2's leak detection ships with two of three corroborating signals.**
The third - "the related listing was marked sold/unavailable outside of a
BROKA-mediated deal" - has no data source. There is no listing-delisting
or deactivation endpoint anywhere in this codebase, seller-facing or
otherwise, so there's nothing for that signal to read. Implemented:
(a) §2.2's off-platform-solicitation flag firing earlier in the same
thread, audit_logs joined back through negotiation_messages rather than
parsed out of the free-text detail string; (b) extended silence - both
parties quiet for a further 5 days after the 7-day leak window closes. A
deal that's just stale, with neither signal present, is left alone
entirely - not flagged, not penalised - matching §3.2's explicit intent
not to punish ordinary buyer indecision.

**Where it's wired:**
- `database.py` - `Deal.leak_flag`/`leak_detected_at`; new `SellerMetrics`
  table (user_id PK, dcr_score, rank_score, updated_at)
- `domains/trust/completion_rate.py` (new) - `deal_weight()` (§3.3's
  45-day-half-life recency curve), `compute_dcr()` (Bayesian-smoothed
  against an 80% prior, so a brand-new seller starts neutral rather than
  at 0%), `flag_leaked_deals()`, `recompute_all_dcr()` (scores every
  seller with >=1 listing, not just ones with deal history - needed for
  §3.5's cold-start fairness)
- `core/workers.py` - `task_recompute_dcr_and_leaks()`, wired into the
  same sweep loop Round 15 used for the dispute-summary cache, but gated
  via the database (max(SellerMetrics.updated_at)) rather than Redis -
  this result affects real search ranking, so the "have I run in the last
  24h" check needs to survive a Redis restart/flush without silently
  skipping a night or re-running every 5 minutes
- `domains/listings/service.py` - default search sort now joins
  SellerMetrics and orders by rank_score (coalesced to the same 0.80
  neutral prior for sellers with no row yet - cold-start fairness again)
  behind is_featured, ahead of the existing created_at tiebreaker
- `domains/auth/service.py` - profile endpoint includes dcr_score/
  rank_score for any seller with >=1 listing (not gated to completed_deals
  like Round 15's escrow-stats block - a seller with zero deals but a
  listing should still see their neutral starting DCR, not have it hidden)
- `seller_dashboard_screen.dart` - DCR shown with self-explanatory
  high/low framing. Not the fully Zeno-narrated, position-aware version
  the doc's own example shows ("move you from position #14 to the top
  5") - that needs a live per-category rank position this pass doesn't
  compute, and the doc explicitly defers exact tone/language to Chapter 5

**Caught mid-implementation, not left in:** the first draft of
`task_recompute_dcr_and_leaks` called `datetime.utcnow()` without
importing `datetime` in that function's scope - this file imports
`datetime` locally per-function rather than once at module level, and the
new function missed it. A NameError at runtime, invisible to
`py_compile`. Found it by re-scanning every new function's local name
usage against its imports, not by running the code - no way to execute
this backend in this sandbox. Fixed before this file was touched again.

**Verification:** every backend file re-compiled clean with `py_compile`
after each edit, same as Round 15. The one Dart file touched
(seller_dashboard_screen.dart) was checked by hand; a brace/paren balance
pass flagged an apparent 1-paren mismatch that turned out to be a false
positive from a regex character class (`[.)]`) inside a string literal at
an untouched line - confirmed by diffing against the pre-edit file, where
the same mismatch already existed. Still not a substitute for actually
running `flutter analyze`.

**Not done, on purpose:** Chapter 4 (ML feature extraction, heuristic-only
predict functions) and Chapter 5 (Zeno persona/prompt updates, including
the fully narrated version of the DCR copy above) are unbuilt. The doc's
own build order (§6.3) sequences these after Chapter 3.

---

# BROKA — Round 15: Volume 2 Chapter 2 — protection badge, off-platform detection, dispute-summary proof, seller social proof


Implemented §2.1-2.4 of the "Volume 2" design journal (escrow trust/social-proof
chapter). Skipped the Alembic migration Volume 2's Chapter 3 would have needed -
no DB data exists yet, so schema changes (not shipped in this round - see below)
will just be created fresh rather than migrated.

Volume 2 was written against an earlier snapshot of this repo and got several
concrete things wrong about the current code. Corrected each rather than
building on the wrong assumption - flagging clearly here rather than letting a
changelog reader assume the doc was followed verbatim:
- §2.3 named `backend/api/models/dispute.py` as holding "the Dispute model."
  That file is real, but what's in it is `DisputeCase` (the v5 state-machine
  system) - the older, simpler `Dispute` class lives in `database.py` and its
  own router (`routers/disputes.py`) isn't even mounted in `main.py`. Built
  the stats endpoint against `DisputeCase`, which is what's actually live.
- §2.2 said to wire off-platform detection into `domains/ai_broker/service.py`.
  Per Round 14's investigation, that's not the live chat path - `negotiate.py`
  is (registered first in `main.py`, wins the `/negotiate/chat` route
  collision). Detection lives in the `/message` handler in negotiate.py.
- §2.3's suggested path `/api/v1/stats/dispute-summary` doesn't match any
  existing convention - no `/api/v1` prefix exists anywhere in this codebase.
  Used `/disputes/v2/stats/summary`, consistent with how the rest of the v5
  dispute router is laid out.
- §2.3 assumed "a periodic ARQ background job." This codebase doesn't
  actually have ARQ cron scheduling wired up anywhere - periodic work runs
  through one shared `asyncio` sweep loop in `core/workers.py`
  (`_periodic_sweep_loop`, ticks every 5 min). Added the refresh there
  instead, self-gated to recompute only every ~4h.
- §2.4 assumed "Escrow Success Rate" and "Dispute Rate" per seller already
  exist from an earlier "Volume 1" chapter ("placement, not new data").
  Grepped the whole repo - neither exists anywhere, as a column or a
  computed value. Only `completed_deals` is real. Built the other two as a
  new, minimal `seller_deal_stats()` helper in `core/fraud.py`.

**Where it's wired:**
- `core/fraud.py` - `detect_off_platform_solicitation()` (regex/keyword,
  analytics-only, deliberately NOT touching trust_score - a single trigger
  is weak signal on its own) and `seller_deal_stats()` (escrow success rate
  + dispute rate per seller, live-computed, cheap enough not to need caching)
- `core/stats_cache.py` (new) - small generic Redis get/set-JSON helpers,
  its own module so `core/workers.py` and `domains/disputes/router.py` can
  share a cache key without importing each other
- `core/workers.py` - `task_refresh_dispute_summary_cache()`, wired into
  the existing sweep loop; also registered in `WorkerSettings.functions`
  for forward-compat if this ever moves to a real ARQ worker process
- `domains/disputes/router.py` - `GET /disputes/v2/stats/summary`, public
  (no auth - it's aggregate and anonymised), lazily populates the cache on
  a cold miss rather than ever hardcoding a fallback number
- `routers/negotiate.py` - detection + audit log (`record_audit`, action
  `off_platform_solicitation_detected`) right after a message is persisted;
  Zeno's reply prompt gets a conditional instruction block that pulls the
  live `resolved_within_24h_pct` from the same Redis cache the stats
  endpoint reads, so the number Zeno cites is never hardcoded
- `domains/auth/service.py` - `get_user_profile` now includes
  `escrow_success_rate_pct`/`dispute_rate_pct` for accounts with
  `completed_deals > 0`; left `_user_dict` (the bulk/search-result path)
  untouched so list endpoints don't pay a new per-user query
- `widgets/protection_badge.dart` (new) - takes the raw backend status
  string rather than the existing Dart `DealStatus` enum in
  `deal_ws_client.dart`, which doesn't model every state this needs
  (`awaiting_condition_check` etc. currently come back as `unknown`) and
  is pattern-matched exhaustively in two other files
  (`deal_status_widget.dart`, `deal_status_screen.dart`) that couldn't be
  verified without a Dart compiler in this environment
- `services/api_service.dart` - `getDisputeSummaryStats()`
- Wired into `deal_status_widget.dart`, `negotiate_screen.dart` (badge +
  escrow-success-rate next to the existing rating/deals line +
  dispute-summary reassurance), `mpesa_confirmation_screen.dart` (badge +
  live 24h-resolution stat shown specifically during the pending-STK-push
  wait, fetched once, all failures swallowed so a stats-fetch hiccup can
  never disrupt the actual payment flow)

**Not wired: `negotiation_screen.dart`.** Volume 2 listed this as a fourth
surface for the badge. It's real and live (`/direct-chat` route in
`main.dart`), but it's a general direct-messaging screen with no deal/escrow
concept at all - no `DealStatus`, no `dealId` even in its constructor
(`NegotiationScreen({super.key})`). Wiring a protection badge in would mean
inventing status plumbing this screen doesn't have, which is a materially
bigger change than "add an existing widget" - left it out rather than
forcing something in that doesn't fit, or silently dropping it without a note.

**Verification:** every backend file re-compiled clean with `py_compile`
after each edit. No Flutter/Dart SDK is available in this sandbox, so the
five touched `.dart` files were checked by hand - matched existing patterns
closely, verified the Dart `DealStatus` enum's exact member names against
source before referencing them, and did a final brace/paren balance pass
across all five files (all matched). None of that substitutes for actually
running `flutter analyze` - do that before merging.

**Not done, on purpose:** Volume 2's Chapter 3 (Deal Completion Rate scoring
+ leak detection + ranking integration), Chapter 4 (ML feature extraction +
heuristic-only predict functions), and Chapter 5 (Zeno persona/prompt
updates) are unbuilt. Chapter 2 alone was a full round; the doc's own
build order (§6.3) sequences these as later, separate steps.

---

# BROKA — Round 14: Groq decommissioned llama-3.3-70b-versatile → OpenRouter (Nemotron 3 Ultra) wired in as testing fallback

Groq emailed on Aug 14, 2026 that `llama-3.3-70b-versatile` — the model
hardcoded as the fallback AI provider everywhere it's called
(`ai_broker/service.py`, `negotiate.py`, `disputes.py`, and
`domains/disputes/service.py`) — would be decommissioned on 2026-08-16.
A separate pasted analysis (apparently from ChatGPT, reviewing OpenRouter's
current free-model lineup) picked NVIDIA Nemotron 3 Ultra as the top
candidate to test as the replacement, ahead of GPT-OSS-20B and Gemma 4 26B
A4B, which are still queued up for the same evaluation later. Verified the
model ID against OpenRouter's own model page before wiring anything in
rather than trusting the pasted summary: the real current ID is
`nvidia/nemotron-3-ultra-550b-a55b:free`, not the shorthand
`nvidia/nemotron-3-ultra:free` the summary used — the wrong slug would
have made every OpenRouter request 404 silently.

**New middle tier, not a replacement.** All four fallback chains now go
Gemini → OpenRouter (Nemotron 3 Ultra, free tier, TESTING) → Groq →
[cache → 503, wherever that tier already existed]. Nothing about Groq
was touched or removed: `GROQ_API_KEY`, the hardcoded `GROQ_MODEL`
constant, `GROQ_ENDPOINT`, `_call_groq`, `groq_breaker`, and the Render
env var are all exactly as they were — they just now sit one tier
further back, behind the new OpenRouter call, so this tier is currently
a no-op (the model it's pinned to is the one that just got retired) but
it will start working again the moment `GROQ_MODEL` is pointed at a Groq
model still being served. Groq's own suggested replacements (GPT-OSS-120B
/ Qwen3.6 27B) were deliberately left as a note rather than auto-applied
— swapping Groq's model wasn't part of "switch to Nemotron for testing,"
so that's flagged as a follow-up decision, not made silently.

**Where it's wired:**
- `core/config.py` — added `openrouter_api_key` / `openrouter_model`
  (the latter env-overridable via `OPENROUTER_MODEL`, defaulting to the
  verified Nemotron free-tier ID)
- `core/circuit_breaker.py` — added `openrouter_breaker`, same 5-failure
  / 30s-recovery shape as `gemini_breaker` / `groq_breaker`
- `domains/ai_broker/service.py` — new `_call_openrouter` method,
  inserted into `_call_ai` behind the circuit breaker; `circuit_stats()`
  now reports an `"openrouter"` key alongside `"gemini"` / `"groq"`
- `routers/negotiate.py` — this is the live path (registered before
  `ai_broker_router` in `main.py`, so it's what `zeno_screen.dart` /
  `product_screen.dart` / `seller_dashboard_screen.dart` actually hit);
  added `_call_openrouter` and the same fallback-order change
- `routers/disputes.py`, `domains/disputes/service.py` — same shape
  added by hand to each. These two plus `negotiate.py` already
  duplicate Gemini/Groq logic locally instead of importing
  `ai_broker/service.py` (existing comments cite avoiding circular
  imports) — kept that pattern rather than refactoring it into a shared
  module, since consolidating four call sites wasn't asked for and
  touches more than this change needs to
- `.env.example` / `render.yaml` — `OPENROUTER_API_KEY` +
  `OPENROUTER_MODEL` added; `OPENROUTER_MODEL` is a plain Render
  `value`, not a secret, so the model can be swapped from the Render
  dashboard with no redeploy, matching the eval workflow the pasted
  analysis described (swap one line, compare results)
- `ARCHITECTURE.md` — overview line, circuit-breaker section, and
  deployment checklist updated to mention OpenRouter and flag Groq's
  current no-op state

**Not done, on purpose:** no 50-scenario benchmark harness, no
per-provider scoring rubric, no synthetic-data test fixtures, no
Zero-Data-Retention routing config for OpenRouter. The analysis that
prompted this explicitly frames Nemotron as the first of three
candidates to test, not a final pick, and separately flags that real
buyer/seller data (names, phone numbers, prices, DCR) shouldn't go to a
free endpoint yet — both are evaluation/rollout work still ahead, not
implied by "switch to Nemotron for testing."

---

# BROKA — Round 13: ChatGPT HomeScreen review — targeted polish pass

User shared a ChatGPT product/engineering review written against the
actual uploaded `broka-latest-release.zip` source (explicitly reviewing
the real HomeScreen/ProductCard/ProductGridView, not proposing from
scratch), rating the current architecture 8.2/10 and recommending small
targeted corrections rather than another redesign. Verified every
concrete claim against the real code before acting, same as every prior
round - all of them checked out.

**Location detection no longer auto-triggers on Home open.** The round-2
comment defending `_detectLocation()` in `initState()` claimed it "feeds
the main feed's per-listing distance_km annotation" - re-checked both
halves of that and neither holds up: `_fetchListingsPage` sends lat/lng
but never `max_km` (so `listings/service.py` only annotates distance, it
never filters by it), and `ProductCard` has no `distanceKm` display
anywhere to show that annotation even if it existed. So Home was
requesting GPS permission and running reverse-geocoding on every open for
zero visible benefit. Removed the `_detectLocation()` call from
`initState()` only - the method itself,
`_gpsGeolocation()`/`_tryGps()`/`_reverseGeocode()`/`_ipGeolocation()`,
and `ApiService.currentUserLat/Lng` are all untouched, since trader
list/profile, the Buy Agent hub, negotiation, Sell, and the listing map
all still read those fields directly. One honest gap worth recording:
grepped the whole Flutter app and `home_screen.dart` was the *only* GPS
call site in it - so until some other screen explicitly triggers its own
detection (or Home grows an opt-in "near me" filter), `currentUserLat/Lng`
will now simply stay null for most sessions. Several existing call sites
already tolerate that fine (`sell_review_screen.dart` falls back to a
Nairobi coordinate; the repository's `lat`/`lng` params are nullable
throughout), so nothing breaks - it's a real behavior change worth being
aware of, not a regression.

**Discovery rail: one thin divider, nothing else.** The rail deliberately
gave categories and Trending/Auctions/Traders identical pill treatment
(home-redesign brief §5) so nothing read as more "special." The review's
ask here was narrower than it might sound at first - not "split them into
rows," explicitly the opposite ("I wouldn't separate them into different
rows... keep one horizontal rail but subtly differentiate"). Added an
`isDestination` flag to `_RailItem` and one 1px hairline (`_railDivider()`,
reusing the existing `BrokaColors.textLow` token, no new color introduced)
exactly at the boundary between the last category and Trending - still
one rail, still one pill shape, no card-size or label-style difference.

**Removed the auto-scroll nudge.** `_nudgeDiscoveryRail()` (the round-3
0→56px→0 animation) is gone entirely, along with its `postFrameCallback`
trigger in `initState()`. Replaced with a static right-edge fade - a
`ShaderMask`/`BlendMode.dstIn` over the rail's own `ListView` viewport
(fades the rendered pills' alpha near the right edge) rather than a
painted overlay in a guessed background color, so it stays correct
against the header's actual gradient (`BrokaColors.headerGradColors`)
instead of hardcoding a fade-to color that could drift from it. The rail
no longer moves unless the user moves it.

**"Discover on Broka" → "Fresh on Broka."** Same underlying fact as the
round-2 label fix (default order is newest-first, not a popularity or
proximity ranking) - the old label made no false claim but didn't say
anything either. The comment at the call site now says explicitly not to
rename this again to "Recommended for you" / "Popular near you" / "Trending
near you" until the backend genuinely computes that signal.

**Confirmed already correct, no action taken** (the review's own "keep"
list, checked against the real code rather than taken on faith):
`ProductCard` has no fabricated trust/deal/market scores anywhere; the
trader avatar is already 24px (`radius: 12`, bumped in an earlier round);
"View Deal" is already the only primary CTA; the wishlist heart only
renders when a real `onWishlistTap` callback is passed, and none of the
three current `ProductCard` callers pass one, so it correctly stays
hidden rather than faking an interaction; `_buildZenoCompactCta()` is
already the small ~50-70px row the review asked to keep, not the old
large promotional card; and Home's `initState()` already only fetches
categories, the marketplace feed, and the active Buy Agent request -
`_loadTrending()`/`_loadLiveAuctions()` were removed from Home two rounds
ago and were not reintroduced.

**Verification, honestly**: this sandbox has no Flutter/Dart toolchain and
no network access, so `flutter analyze`, the Flutter test suite, and a
release APK build could not actually be run here, unlike what the
review's own pasted instructions ask for. Checked by hand instead: every
edited region was re-read in full after editing, grep confirmed no
leftover references to the removed `_nudgeDiscoveryRail()`, the old
`_detectLocation()` call site, or the old "Discover on Broka" string; no
duplicate method signatures were introduced; and brace/paren/bracket
counts balance across the whole file. Run `flutter analyze` and the
existing suite yourself (Codemagic CI will also do this on push) before
merging - careful manual review is not a substitute for the real
toolchain actually running.

**Files changed this round**: `flutter_app/lib/screens/home_screen.dart`
only. No backend files, no migrations, no other Flutter files touched.

---

# BROKA — Round 12: Meta AI review + timezone bug + visual polish pass

User shared a Meta AI critique of a Home screenshot, with an important
caveat: the screenshot was from the build *before* Round 11 (their words:
"not from the last source code but from the second last"), so several of
its points were already fixed and just needed confirming, not redoing.
Also reported directly: seller ratings look fake, and a listing posted
under 15 minutes ago showed "3h ago." Verified every claim against the
current code before acting, same as every prior round.

**Confirmed already fixed by Round 11, no action needed**: the duplicate
"Trending Near You" / "Popular near you" content (Round 11 removed the
Trending grid from Home entirely).

**Real bug, found the exact mechanism: "3h ago" for a listing posted
minutes ago.** The backend stores every timestamp as naive UTC
(`datetime.utcnow()`, no timezone marker) and serializes it with none
either. `DateTime.tryParse()` on a string with no offset marker is
interpreted by Dart as *local* time, not UTC - so a later `.toUtc()` call
shifts it a second time, subtracting the device's own UTC offset from a
value that was already UTC. In Kenya (UTC+3) that turns "posted 5 minutes
ago" into "posted 3h 5m ago" - which is exactly what was reported, and
the UTC+3 match isn't a coincidence. Added `utils/backend_time.dart`
(`parseBackendUtc`) and applied it at the two call sites feeding the
reported symptom (`BrokaListing`'s createdAt as parsed by
`product_card.dart`, and the older `Listing` model's own createdAt/
featuredUntil parsing in `models/listing.dart`, plus the copy of that
same parse in home_screen.dart's featured-pinning sort). **Grepped the
whole app and found the same `DateTime.tryParse` pattern in 11 more
files** (`api_service.dart`, `auction.dart`, `buy_agent_request.dart`,
`models.dart`, `deal_ws_client.dart`, `review_screen.dart`,
`boost_screen.dart`, `user_profile_screen.dart`, `product_screen.dart`,
`negotiation_screen.dart`, `deal_receipt_history_screen.dart`) - not
fixed this round, flagged in `backend_time.dart`'s own header comment
rather than silently left implied-fixed. Any of those showing a
relative/absolute time to a user likely has the same bug.

**Real bug: seller ratings looked fake.** `User.rating` defaults to `5.0`
at account creation (`database.py`) and is only ever nudged upward from
there on a completed deal - so a brand new seller with zero completed
deals showed a perfect, untouched 5.0, indistinguishable from a seller
with a real track record. `product_card.dart` now only renders a star
rating when `sellerCompletedDeals > 0` too (not just `rating > 0`, which
was true for literally every seller including brand new ones) - shows
"New seller" instead when there's no deal history yet. On the "out of 10"
point: checked directly - `Review.rating` is `1-5 stars` by column
comment and `User.rating` is capped at `min(5.0, ...)` everywhere it's
adjusted. The system is built and stored as a 0-5 scale throughout, not
0-10 - didn't rescale the display since that would misrepresent what the
stored data actually means.

**Visual redesign of the product card** ("not that attractive... make it
super attractive and futuristic"): thin gradient edge (purple-to-blue)
replacing the flat single-color border; price bumped to 16sp with a soft
gold glow; "View Deal" changed from an outlined button in the same gold
tone as the price (competing visually - a real point from the Meta AI
review) to a solid gradient-filled pill, borrowing `GoldButton`'s visual
language rather than inventing a third button style; a faint bottom
scrim on the product image for depth. Trader avatar bumped 18px -> 24px
(continuing round 11's fix in the same direction).

**Discovery rail**: category labels now wrap to 2 lines instead of
truncating at 1 ("Beauty & P...", "Books & Ed..." was unreadable) - real
category names from `categories/seed.py` mostly fit now. Added the
scroll-affordance animation requested: one brief nudge-and-settle on
first load (peek ~56px right, ease back to 0) rather than a continuous
wiggle, which would read as distracting/broken over a full session.

**Also fixed while in the area**: location text now gets a space
inserted after a comma when the seller's own free-text location was
missing one ("Bondo,Siaya" -> "Bondo, Siaya") - cosmetic only, doesn't
touch the stored value. Empty state (already had an icon + message, not
literally blank) gained an actual "+ Sell something" CTA.

**Deliberately not touched**: bottom nav icon style mix (outlined vs.
filled/rounded, flagged as a fair point) - fixing it means picking exact
Material icon constant names I can't verify compile in this sandbox
(no Flutter toolchain here), and a wrong guess is a build break for a
minor polish item. Left as a known, flagged gap rather than risk it.



User shared a follow-up review (also developed with ChatGPT, this one
explicitly reviewing Round 9's actual source rather than proposing from
scratch) of the Round 9 Home redesign. Verified every concrete claim
against the real code before acting, same as every prior round - all of
them checked out, including two I'm glad were caught: a heart icon that
animated convincingly and did nothing, and a "near you" label the backend
can't actually back up.

**Trending grid and Live Auctions carousel removed from Home entirely.**
Round 9 had converted Trending into a 2-column grid sitting above the
main feed - a real improvement over the old horizontal reel, but still a
second, fixed listing block competing with the actual paginated feed for
space, which is exactly what the whole redesign was supposed to
eliminate. Both are now pure `_buildDiscoveryRail()` destinations only -
tapping them opens `TrendingScreen`/`AuctionHouseScreen` unchanged, which
fetch their own data. Home no longer calls either API at all
(`_loadTrending()`/`_loadLiveAuctions()` removed from `initState()`,
along with the now-fully-unused `_trendingItems`/`_liveAuctions` state
and their now-unused repository imports) - one less pair of network
calls on every Home open that Home was never using for anything but a
section it no longer shows.

**Two labels were making claims the backend can't back up:**
- Trending's grid used to say "Popular near [location]" - moot now that
  the section is gone, but worth recording why it was wrong:
  `trending/service.py`'s `list_trending` has zero lat/lng/max_km
  handling (grepped directly) - ranking is pure view/interest-count with
  time decay, no geography involved at all.
- The main feed said "Popular near you." Also not true:
  `_fetchListingsPage` sends `lat`/`lng` but never `max_km`, and
  `listings/service.py`'s `list_listings` only *filters* by distance when
  `max_km` is provided alongside coordinates (grepped and confirmed) -
  without it, lat/lng only annotates each result with a `distance_km`
  value, it doesn't restrict the result set to nearby listings at all.
  "Popular" wasn't accurate either - with no sort selected this is just
  the backend's default order (newest first), not a popularity ranking.
  Changed to "Discover on Broka," which claims nothing the feed can't
  support and doesn't need to change again once a real recommendation
  engine exists.

**Fixed a real fake-interaction bug**: `product_card.dart`'s favorite
heart (added Round 9, with a real scale-bounce animation) was rendered on
every card regardless of whether a working callback existed behind it.
Grepped this entire codebase, backend and Flutter both - there is no
wishlist/favorites system anywhere (no model, no endpoint, no
repository), and none of the three places that construct a `ProductCard`
(Home's feed, Home's search results, `ProductGridView`) ever passed
`onWishlistTap`. So the heart bounced convincingly and updated nothing,
every time, everywhere it appeared. Now only renders when a real
`onWishlistTap` callback is actually provided - today that's never, so
the heart doesn't show at all, which is more honest than a
disabled-looking icon that still invites a tap. The animation/state code
is untouched - a future wishlist feature just needs to pass
`onWishlistTap`/`isWishlisted` and it reappears working, nothing to
rebuild.

**Trader avatar increased from 18px to 24px diameter** (`radius: 9` ->
`radius: 12`) - trust identity, not decoration, and 18px read as nearly
invisible next to the name/rating beside it.

**Confirmed already correct, not touched**: discovery rail composition,
compact Zeno CTA, single View Deal action, condition badges, real
seller_verified/seller_rating (no fabricated trust score), backend
filtering (condition/price/location/sort), pagination. All per the
review's own assessment of Round 9, and consistent with what Round 9's
CHANGES.md entry claims - nothing here contradicted it.



Home's header showed the "BROKA" wordmark but never the icon mark next to
it - the login screen (`auth_screen.dart`'s `_buildLogo()`) has always
shown both together. Replicated that exact treatment in
`home_screen.dart`'s header: same asset (`assets/images/broka_icon.png`,
already declared in pubspec.yaml, no new asset needed), same 44x44 size,
same 13px corner radius, same gold glow. Sits to the left of the existing
greeting/wordmark column; the two icon buttons on the right (filter,
search) are untouched.



User shared a full UI redesign brief (developed with ChatGPT) plus a
current-state screenshot and a target mockup: the core complaint was that
Home spent most of its vertical space on navigation chrome (a Goods/
Traders toggle, a permanent location row, category circles, a giant Zeno
promo card) before showing a single product. Implemented the structural
core of the brief - not every one of its ~40 sections (several are
animation-timing detail or repeated emphasis rather than new asks) - and
substituted real data everywhere the brief's own mockup showed numbers
this codebase has never computed.

**Two things in the brief's mockup were NOT reproduced, on purpose**: a
"🛡 99%" trust percentage (no Deal Completion Rate has ever existed
anywhere in this codebase - see traders/service.py's own note) and
"+67% vs avg" price comparisons (no market-average computation exists
anywhere either). Built the equivalent *intent* - a trust signal next to
the trader's name, a price the buyer can act on - from data that's
actually real: a verified checkmark (`seller_verified`) and a star rating
(`seller_rating`), shown only when there's an actual rating to show. No
fabricated numbers shipped.

**Structural changes** (`home_screen.dart`):
- Goods/Traders toggle removed entirely. Traders is now one destination
  inside a single unified discovery rail, alongside the real categories
  and Trending/Auctions - navigates to its own `TraderListScreen` (no
  longer `embedded`) instead of swapping Home's whole body via
  `MarketplaceState`. `MarketplaceState` itself is untouched (still
  registered in main.dart) in case anything else needs it later - just no
  longer read from this screen.
- Permanent location row removed. Location detection
  (`_detectLocation`/`_locationLabel`) is unchanged - it now surfaces
  contextually as the Trending section's subtitle ("Popular near
  Ugunja") instead of a dedicated always-visible row, and is still
  tappable there to manually re-detect.
- Categories + Trending + Auctions + Traders unified into one horizontally
  scrolling rail (previously three separate rows: a category-circle
  strip, a "Quick Access" chip row, and the mode toggle) - same visual
  treatment for every item so nothing reads as more "special" than a
  category circle, ~80px tall.
- Zeno's card shrunk from a ~180px promotional block to a ~60px compact
  row. Reused `_pulseCtrl` - an `AnimationController` that existed since
  an earlier round but was never actually attached to anything - for a
  slow breathing glow.
- Trending converted from a 200px horizontal reel of narrow cards to a
  2-column grid (capped at 4 items - "See all" reaches the rest via
  `TrendingScreen`), same aspect ratio as the main feed grid below it for
  visual consistency. Live Auctions kept as a horizontal carousel - the
  brief itself allows this for time-sensitive content, and it lowers the
  change surface.
- "Zeno is watching for you" now shows the real match count
  (`req.matchCount`, added Round 4) instead of a binary
  searching/matched state.
- Light entrance animation: header renders instantly, the rail/Zeno-CTA/
  active-request/Trending/Auctions sections fade+slide in with a short
  stagger (`_Entrance`, a small reusable one-shot widget - not a full
  driven `AnimationController` per section).

**Listing card rebuilt** (`product_card.dart`):
- Trader identity row (avatar + name + verified check + real star rating)
  added below the image - not overlaid on it, so it never covers product
  photography, which the brief itself calls out as a priority ("do not
  allow trader information to cover too much of the product").
- Trader photo required a small backend addition:
  `seller_profile_photo` never existed on any listing response (only on
  trader-list responses, added Round 4) - added to `_listing_dict` via
  the same optional-seller/batched-fetch pattern as the four seller
  fields already there. Falls back to an initial-letter avatar when
  absent, same pattern trader cards already use elsewhere - never a
  generated face.
- Condition badge (top-left, real data, blank when the listing has none -
  not "Unknown") and relative freshness text ("2h ago", computed from
  `createdAt`) added.
- Single "View Deal →" button added to every card. There was no "Offer"
  button to remove (the card was previously whole-card-tap-only, no
  buttons at all) - the new button fires the same `onTap` the rest of the
  card already used, not a second navigation target.
- Favorite heart now has a real tap animation (scale 1→1.25→1, ~260ms) -
  extracted into its own small `_FavoriteButton` StatefulWidget so the
  rest of the card can stay a plain `StatelessWidget`.
- `ProductCardSkeleton` gained an actual shimmer sweep (was a static flat
  gradient box before this round, despite the class name).

**Deliberately not done this round, flagged rather than silently
skipped**: a custom Broka-logo pull-to-refresh indicator (brief §29) -
`ProductGridView` already has a functional `RefreshIndicator`, just the
default Material one, not a branded animation. A friendly inline error
state for a failed page fetch (brief §32) - not present before this round
either, and out of scope for a hierarchy/layout redesign. Precise
millisecond-level animation choreography across every section (brief
§21-§30's full timing tables) - implemented the real intent (fade+slide
entrance, favorite bounce, gentle Zeno glow, shimmer) with sensible,
tasteful timings rather than chasing every specified number, since this
environment has no way to visually verify exact motion timing anyway.



User shared a review (from ChatGPT) of the Buy Agent work. Verified every
concrete, checkable claim against the actual code before acting on any of
it — a review like this can be right, wrong, or partially right, and
several of its numeric scores were opinion rather than something to "fix."
Two claims were real, confirmed bugs; a third (matching completeness) was
something I'd already flagged as a known limitation in my own Round 4
comments, so this was the pass to actually close it.

**1. `optimization_configuration` was accepted by the service and stored
on the model, but `_create_buying_request` never actually built or passed
it** — confirmed by grep, zero references. A secondary optimization
preference picked when creating a standing request was silently dropped,
even though the exact same preference is correctly carried through for
one-off `SEARCH_PRODUCTS`/`REFINE_SEARCH`/`SORT_RESULTS` calls. Fixed:
`_create_buying_request` now takes `optimization_secondary` and builds
`{"secondary": ...}` the same way.

**2. `negotiation_authorized` was never actually enforced, and - separately
- was never even settable.** The column existed (correctly defaulting to
`False`), Design v2 §24 explicitly requires genuine pre-authorization
before Zeno negotiates autonomously, and my own Round 4 comment on
`_start_negotiation` referenced this exact field - but nothing anywhere
(no param on either params model, no router field, no Flutter UI) could
ever set it to `True`, and `buy_agent_subscribers.py`'s auto-opener never
checked it at all. So every match auto-messaged the seller regardless,
with the authorization boundary existing in name only. Fixed end to end:
- `CreateBuyingRequestParams`/`UpdateBuyingRequestParams`/the plain
  `BuyAgentRequestIn` (all three creation/update paths) now accept it,
  default `False`.
- `buy_agent_subscribers.py` now checks `req.negotiation_authorized`
  before sending the auto-opener - an unauthorized match still flips
  status to "matched" and increments `match_count` (the buyer still sees
  it), it just doesn't message the seller without having said yes to that.
- Buying Agent Hub gained a checkbox ("Let Zeno message the seller for me
  automatically...") on the "Keep Zeno watching" step, off by default -
  otherwise the backend fix alone would leave this permanently
  unreachable from the app, which is correct-but-inert, not actually done.

**3. The autonomous subscriber only ever checked category + max_price**,
silently ignoring condition, subcategory, distance, and
`must_have_features` even when a standing request specified them - a
"Samsung Galaxy, 8GB RAM, under 10km" request behaved identically to
"anything electronics under budget." This was already flagged as a known
limitation in my own Round 4 comment on this file ("Feature-matching
against must_have_features... is not implemented") - this round actually
closes it. Added `_listing_satisfies_request()`: checks subcategory,
condition, and distance as real hard constraints (opt-in - a constraint
the buyer never specified never excludes a listing), and
`must_have_features` as a best-effort case-insensitive substring check
against the listing's name+description. That last one is a real,
documented limitation, not equivalent to structured attribute matching -
a listing that satisfies a requirement without literally saying so in its
text still won't match. A deeper fix needs the attribute-value validation
this codebase doesn't have at listing-write-time either (see
`filter_bottom_sheet.dart`'s own note on this from Round 4). Updated
`test_matching_listing_opens_disclosed_negotiation_thread` accordingly -
its listing now actually contains the feature its matching request
requires, rather than the match happening despite the listing never
mentioning it (which is what "not implemented" had been letting slide).

**Deliberately not changed, and said so rather than silently declining**:
the review's suggestion to compare multiple candidate listings and hold
out for the best-scored one instead of committing to the first one that
satisfies every constraint. `CREATE_BUYING_REQUEST` already runs an
immediate search against existing inventory before a standing request is
even created (the Hub's confirm-and-search step) - the standing watch's
job is specifically to catch *future* listings, and "first future listing
that genuinely qualifies" is a defensible design for that, not obviously
wrong. Doing real multi-candidate scoring would mean deciding how long to
wait and trading responsiveness for a maybe-better match that may never
come - a real product decision, not something to bundle into a
matching-completeness fix. Also not changed: the review's critique of the
`primary*0.85 + secondary*0.15` ranking blend (a fair point - it doesn't
literally "break ties," it always has some influence) - a tuning
refinement, not a gap, and lower-confidence to get right unilaterally
than the three fixes above.



GitHub Actions' next run (after Round 6) flagged a different test:
`tests/test_traders.py::TestTraders::test_specialization_derived_from_listings_not_self_declared`,
failing on `assert "cat-electronics-2" in spec_ids` with the actual value
being the real seeded Electronics category's UUID instead.

Not a specialization-derivation bug - the subscriber found the right kind
of category, just the wrong *row*. The test creates its own
`Category(id="cat-electronics-2", name="Electronics", parent_id=None)` to
control the scenario precisely, but `setup_db`'s `init_db()` call already
seeds the real canonical "Electronics" top-level category before any test
runs (`seed_categories()`, dedup-checked, runs on every startup - this
predates this round, not something introduced here). So the test
unintentionally created two legitimate top-level rows both named
"Electronics". `trader_specialization_subscribers.py`'s Round 4 fix
(`ORDER BY parent_id IS NULL DESC, id` instead of `scalar_one_or_none()`,
specifically so a genuine name collision logs and picks *a* row instead of
crashing with `MultipleResultsFound`) picked deterministically - by id -
between the two, and the seeded UUID happened to sort first. In real
usage this can't happen at all: `seed_categories()`'s own dedup check
means two top-level categories can never legitimately share a name
outside a test going out of its way to create that. Fixed by renaming the
test's category to something outside the canonical 16 top-level names
("Test Electronics") so there's no collision to tie-break in the first
place, rather than changing the subscriber's (correct, needed-for-the-
real-non-test-case) tie-break logic. Grepped every other test file for
the same `Category(id=...)` pattern — this was the only one.

**Also fixed, unprompted by either CI failure**: while in `database.py`
for the above, noticed `init_db()` already has exactly the mechanism
Round 4's `match_count` column should have used - a hand-maintained,
try/except-wrapped list of forward-compat `ALTER TABLE ... ADD COLUMN`
statements that run safely on every startup against an existing DB, which
I'd missed and instead told you to reset your dev database for. Added
`match_count` to that list. **You no longer need to reset anything** -
correcting what Round 4's CHANGES.md entry told you.



GitHub Actions flagged one failing test after the Round 4 zip:
`tests/test_buy_agent.py::TestBuyAgent::test_matching_listing_opens_disclosed_negotiation_thread`,
`assert me.json() is None` on the last line. Worth being precise about
what this failure actually shows, since it's good news, not a new bug:
everything *before* that line (the listing being created, the in-process
subscriber matching it, the broker-role negotiation message with the
right `is_agent_initiated`/content) passed — meaning `buy_agent_subscribers.py`'s
Round 4 migration to the live event system is confirmed working
end-to-end by a real test run, not just by static review.

The one failing line was asserting the *old* bug: `GET
/buy-agent-requests/me` used to return `None` the instant a request
matched (`get_active_for_buyer` only ever queried `status=="active"`) -
which is exactly what Round 4 fixed, on purpose, because it meant
home_screen.dart's "Match found!" state could never actually be reached.
The test was written against the pre-fix behavior and never got updated
alongside it. Updated the assertion to expect the matched request (and
its `match_count`) instead of `None` - not a behavior change, just the
test catching up to the intentional Round 4 fix.



Reported symptom: audio/video calls worked before, then stopped — the
callee saw no incoming-call screen, no notification, no ringtone at all.
Traced end to end rather than guessing at the calling UI first, since a
symptom this total (zero signal, not degraded quality) usually means
something upstream of the feature itself.

**Root cause: access tokens expire in 15 minutes
(`ACCESS_TOKEN_EXPIRE_MINUTES`) and nothing ever refreshed them.**
`POST /auth/token/refresh` (`refresh_router.py`) has existed and worked
correctly the whole time — but `register()`/`login()`
(`AuthService`) never actually called `create_refresh_token()` or
returned one, so no client could ever obtain a refresh token to exchange.
Compounding it: `ApiService.checkIncomingCall` (what
`GlobalPollerService`'s ~7s background poll uses to detect an incoming
call) and `ApiService.initiateCall` (what the caller uses to register the
call at all) had **zero handling for a 401** — a expired-token response
just silently became "no call" / "call not sent," forever, with no error
anywhere. Net effect: call detection (and initiation) worked perfectly
for the first 15 minutes after login, then went completely and silently
dark for the rest of the session — matching "worked before, tested again
after a while, nothing." The one existing recovery attempt in the app
(`ApiService._tryRefreshOrRelogin`, previously only used by
`createListing`) was *also* broken independently: `Uri.parse('\$baseUrl/...')`
had an escaped dollar sign, so even that one call site's refresh attempt
was hitting a garbage URL, not the real one, this whole time.

Fixed all four pieces:
- `AuthService.register`/`login` now issue a real refresh token
  (`_issue_refresh_token`, DB-backed via `RefreshToken`, matching what
  `refresh_router.py` already expected) and return it as `refresh_token`
  — the Flutter side (`login()`) was already reading and storing that
  field, just never receiving it.
- Fixed the `\$baseUrl` typo.
- `checkIncomingCall`/`getInbox`/`initiateCall` now retry once via
  `_tryRelogin()` on a 401 before giving up.

**Not done, flagged rather than silently left implied-fixed**: the
401-retry pattern above was only added to the 3 call-critical methods.
Grepped the rest of `api_service.dart` (~50 methods) — only
`createListing` had any 401 recovery before this round, and still only 4
of ~50 do now. Anything else that polls or runs in the background will
have the same silent-death-after-15-minutes behavior until this is
broadened file-wide. Didn't do that sweep here: touching a large fraction
of a 1300-line file with no way to compile or run the result in this
environment is a worse risk than leaving it flagged for a dedicated pass.

Also found in the same area, not investigated further (out of scope for
this specific bug): `api/routers/auth.py` is a second, unmounted, fully
dead implementation of the auth endpoints — confirmed dead the same way
`api/routers/listings.py` was in Round 4 (checked `main.py`, only
`api/domains/auth/router.py` is `include_router`'d). One live caller
elsewhere in the backend (`negotiate.py`) imports a helper
(`_approx_location`) from the dead file rather than the live one — works
today (dead code can still be imported from, it's just never *routed to*
as an HTTP endpoint), but is a landmine for a future edit made to the
wrong copy.



Deep audit of the actual source against both docs, section by section,
verified by reading the real code rather than trusting prior notes about
it — several things believed fixed in earlier sessions turned out to be
either genuinely regressed or never actually wired into the code path
that's live in production. Implemented the highest-value gaps found.
Nothing existing was removed; every file in the previous zip is still
here, touched or not.

**Cannot be verified by actually running the app from this environment**
— no Flutter SDK, emulator, or live Postgres/Redis here. Every backend
`.py` file compiles cleanly (`python3 -m py_compile` across the whole
`backend/` tree, not just touched files) and every Dart file was
brace/paren-balance checked across the whole `flutter_app/lib/` tree, but
neither is a substitute for actually building and running both sides
before shipping. Build and click through this before deploying.

## Critical fix: five event subscribers were dead under Redis

The single highest-severity thing found this round. `api/core/events.py`'s
legacy `@subscribe` bus only invokes in-process handlers when
`REDIS_URL` is unset (`_publish_inprocess`) — the moment Redis is
configured, `publish()` writes to a Redis Stream instead
(`_publish_redis`), and nothing anywhere in the codebase ever reads that
stream back out (`consume_redis_stream` exists, is fully correct, and is
never called). `config.py`'s own startup log calls Redis
"production-grade operation", i.e. the recommended deploy config — so
this wasn't a dev-only edge case, it was the *documented* config quietly
breaking everything routed through the old bus.

Confirmed still affected: `buy_agent_subscribers.py` (Zeno's core "watching
for a match" mechanic), `trader_specialization_subscribers.py` (specialty
badges), `auction_hub_subscribers.py` (live bid WebSocket broadcast),
`deal_hub_subscribers.py` (all deal-status WebSocket updates), and
`push_subscribers.py` (every FCM push notification). `zeno_subscribers.py`
was already correctly on the newer system and untouched.

Fix: migrated all five from `@subscribe`/`api.core.events` to
`@subscribe_to`/`api.core.event_catalog`, whose handlers fire
unconditionally inside `emit()` regardless of Redis. Verified this needed
**zero call-site changes anywhere else**: `publish()` already
unconditionally bridges every call to the catalog
(`events.py`'s `_bridge_to_catalog`, called after the Redis/in-process
branch either way), and every event type these five files depend on
(`ListingCreated`, `BidPlaced`, `DealFinalized`, `EscrowFunded`,
`EscrowReleased`, `EscrowRefunded`, `DisputeOpened`, `DisputeResolved`,
`ReviewSubmitted`, `UserVerified`, `FraudFlagged`, `MpesaCallbackReceived`)
was already present in `LEGACY_EVENT_MAP` — checked every one against the
map and against each dataclass's real field names before writing the new
payload access, not assumed. `main.py`'s import block reordered/relabelled
to match (still six plain side-effect imports, same as before).

**Also found, not fixed (pre-existing, separate from this bug, out of
scope for a redesign-guide pass — touches core dispute/verification
business logic, not Home/Zeno)**: grepped every call site and confirmed
nothing in the codebase ever calls `publish(EscrowRefunded(...))`,
`publish(DisputeOpened(...))`, `publish(DisputeResolved(...))`, or
`publish(UserVerified(...))` at all. Those four handlers are now wired
correctly and will fire the instant something publishes them, but nothing
does yet — flagging honestly rather than leaving the impression dispute/
verification notifications fully work end-to-end.

## Zeno Action Engine — closed real gaps in `buy_agent/actions.py`

`REFINE_SEARCH`, `SORT_RESULTS`, `UPDATE_BUYING_REQUEST`, `CHANGE_BUDGET`,
`CANCEL_REQUEST`, `START_NEGOTIATION` were all present in the action
vocabulary but returned `NOT_IMPLEMENTED`. Implemented all six:

- `REFINE_SEARCH`/`SORT_RESULTS` execute identically to `SEARCH_PRODUCTS`
  (a refine *is* a new search with merged-in parameters; a sort *is* a
  re-search with a different `optimization_code`, already a top-level
  field) — no new execution logic needed, just real action names Zeno can
  emit honestly.
- `AIBrokerService.parse_search_intent` gained an `existing_filters` arg:
  when the Hub sends the prior search's parameters alongside a follow-up
  like "only 2018 or newer", the model returns the complete merged filter
  set instead of just the new fragment — this is what makes "Zeno must
  understand that 'it' refers to the active request" (design doc §21)
  actually true rather than aspirational.
- `UPDATE_BUYING_REQUEST`/`CANCEL_REQUEST` close a real usability bug:
  with `BUY_AGENT_MAX_ACTIVE` defaulting to 1 and no prior way to ever
  change status away from "active"/"matched", a buyer who created one
  standing request had **no way to ever create a different one**. Also
  fixed `BuyAgentService.get_active_for_buyer` only ever querying
  `status == "active"` — the instant a request matched (status flips to
  "matched"), it became invisible to `GET /buy-agent-requests/me`, so
  `home_screen.dart`'s "Match found!" display branch had real code that
  could never actually be reached.
- `START_NEGOTIATION` opens a real `NegotiationMessage` thread for a
  specific listing, gated on the Hub already having shown a "shall I
  start the negotiation?" confirmation (design doc §24) before ever
  calling it. Deliberately does **not** reach into
  `routers/negotiate.py`'s `send_message` (~2700 lines, built for a live
  HTTP request's own context) — reuses the same safe, plain-message
  pattern `buy_agent_subscribers.py`'s auto-match opener already
  established, rather than duplicating or destabilizing that file.
- Added `BuyAgentRequest.match_count` (real column, incremented by
  `buy_agent_subscribers.py` on each match) so Home/Hub can show a real
  number instead of the previous binary searching/matched state.

**No new Alembic migration was written for `match_count`** — see the
"About migrations" note near the end of this entry.

## Seller trust info now actually reaches product cards

Confirmed by reading `product_card.dart`'s own code (not assumed): the
verified-badge logic was a proxy (`sellerName != null`) because **no
listings endpoint anywhere returned real seller data** —
`ListingService._listing_dict` never took a seller argument at all, under
any caller, despite `BrokaListing`/`product_card.dart` already being
built to show `seller_verified`/`seller_name`/`seller_rating`/
`seller_completed_deals`. Fixed: `_listing_dict` now optionally takes a
`seller: User`; `create_listing`/`get_listing`/`list_listings` (batched,
one `IN (...)` query for a whole page, not N+1)/`trending.list_trending`
(same batching) all pass one through. `BrokaListing` and the older
`Listing` Flutter model both gained the four fields; `product_card.dart`
now shows a real verified badge plus a compact seller-name line instead
of the old proxy, and no longer needs a type-branch to read them since
both models use the same field names.

Also found and left alone, documented rather than silently ignored:
`api/routers/listings.py` is a second, older listings implementation with
its own (different, `seller_verified`-less) version of this same join —
confirmed via `main.py` that it is **never mounted/imported anywhere**,
i.e. fully dead code, not the one actually serving `/listings` traffic
(that's `api/domains/listings/router.py`, the one fixed above). Left as-is
per "don't eliminate any file."

## Home screen search — was not searching listings at all

Confirmed by reading the code: `_ListingSearchDelegate` is named and
labelled as listing search but its `buildSuggestions`/`buildResults` only
ever called `ApiService.searchUsers` — Home's primary search entry point
could not find a single product, despite both docs explicitly listing
product search as one of Home's most important elements. Rewritten to
search listings by default via `ListingsRepository` (added a `location`
passthrough to it too — the backend's `list_listings` already had a
`location` ILIKE param that this repository simply never exposed), with
trader search kept one tap away via a mode toggle rather than removed.
Added a conservative heuristic (5+ words, plus a budget/intent signal
word or a 4+ digit number) that surfaces an "Ask Zeno" banner for
sentences that read like a buying request rather than a product name —
never blocks or replaces plain search, per design doc §4's explicit
"do not remove normal search in favor of AI." `BuyAgentHubScreen` gained
an optional `initialQuery` constructor param so this hand-off actually
pre-fills and auto-submits instead of dropping the buyer's typed text.

## Home screen structure

- Section order was Quick Access → Top Categories; guide §1's explicit
  target order is the reverse. Swapped.
- Migrated the main feed off the older `ApiService.getListings()`/
  `Listing` stack onto `ListingsRepository`/`BrokaListing` (the stack
  every other screen already uses) — this is what makes Condition/Sort
  filterable from Home at all, and is also what makes the seller-trust
  fix above actually show up on Home's own grid, not just Category
  Zone/Trending/the Buying Agent Hub.
- Filter panel gained Condition chips and a Sort dropdown alongside the
  existing Price/Location — guide §5/§20 list Location, Price, Condition,
  Sort as Home's Global filters; only the first two existed.
- Added a "Popular near you" label above the main grid (target structure
  item #10). Not "Recommended for you" — this app has no
  browsing-history-based personalization signal to back that claim yet,
  and the guide is explicit: never fabricate personalization.

## Traders — N+1 query, and three missing card elements

`TradersService.list_traders` ran one `COUNT(*)` query *per trader in the
list*; batched into one grouped query. Design doc §30 lists
business/profile image, location, and distance as trader-card elements;
none were ever returned by the service despite the underlying data
(`User.profile_photo`/`business_location`/`lat`/`lng`) already existing —
added all three, gated behind the same `User.location_visible` privacy
switch `search_screen.dart`'s existing user search already respects (not
exposed unconditionally just because the doc lists them). Deliberately
did **not** add a Deal Completion Rate field: the doc points at "an
existing per-seller DCR function," but no such function exists anywhere
in this codebase under any name — fabricating one wasn't the ask.

## Filter number-range bounds

`filter_bottom_sheet.dart`'s number-range fields (Year, Mileage, Bedrooms,
Acreage, Screen Size, Seating Capacity, Square Footage, Battery Health,
Power Rating, Shoe Size, Hours Used, Size (ml), Experience Years) all
rendered against a flat, shared 0–100 scale regardless of what the field
actually was — a car's Year squeezed into 0–100 has no usable resolution,
and Mileage needs to reach ~500,000 km. `category_filters` still has no
per-field min/max of its own, so added a small hand-picked bounds lookup
covering every `number_range` field name that actually appears in
`categories/seed.py` today, with a safe 0–100 fallback for any future
field name not yet in the map.

## About migrations

No new Alembic migration files were written this round, per direct
request — `match_count` (`BuyAgentRequest`) is the only new column, added
straight to the SQLAlchemy model in `database.py`. `init_db()` already
calls `Base.metadata.create_all()` on startup, which creates missing
*tables* but — standard SQLAlchemy behaviour, not specific to this
codebase — does **not** add a missing *column* to a table that already
exists. Since there's nothing in the database to preserve right now, the
simplest path is letting the next startup's `create_all()` build the
schema fresh (drop the `buy_agent_requests` table, or the whole dev DB,
once) rather than hand-writing a migration for a single nullable-default
integer column. Happy to generate the real Alembic revision once you're
ready to start preserving data across deploys.


Founder chose "go big" on the aesthetic gap over incremental polish. Scope:
the highest-leverage surfaces (seen on nearly every screen, or the specific
"Zone" moment the original spec called the signature feature) rather than
a mechanical pass over every widget in the app. Built entirely from the
design tokens `BrokaColors` already defined (brand gradient, neon accents,
card gradient) — no new colour system, so nothing here fights with what
was already consistent.

**Cannot be verified visually from this environment** — no Flutter SDK or
emulator available here, only static analysis (brace/paren balance, import
resolution by inspection). Build and eyeball this before shipping.

## New shared tokens (`main.dart`)

`BrokaColors.zoneGradients` — a 2-colour gradient per top-level category,
built mostly from the neon tokens that already existed (Electronics/Phones/
Computers → cyan-blue, Gaming → purple-pink, etc.), plus two new ambers/
oranges for categories with no obvious existing match. `zoneGradientFor()`
does a case-insensitive lookup with a fallback to `brandGradient`, so an
unmapped category never renders with no gradient at all.

`ZoneGlowText` — gradient-filled, glowing header text (`ShaderMask` +
`BlendMode.srcIn` + stacked `Shadow`s). This is the "ELECTRONICS ZONE" /
"GAMING ZONE" treatment from the original spec's mockup — built as a
reusable widget, not copy-pasted per screen, since the Zone concept was
explicitly called out as BROKA's one signature visual idea.

## CategoryZoneScreen — the signature moment

- Plain white category name → `ZoneGlowText`, glowing in that category's
  own gradient.
- Added a radial background wash tinted with the zone's colour, fading
  fast into the standard dark background — deliberately subtle rather
  than a full palette swap, per the founder's own earlier note on Gemini's
  proposal ("BROKA identity stays consistent, while each Zone gets its
  own personality").
- Subcategory chips: selected state now fills with the zone gradient and
  a matching glow instead of the generic purple used everywhere else.

## ProductCard

Swapped local one-off hex values for the shared `BrokaColors` gradient/
border tokens. Price now uses the actual brand violet token. The bare
verified checkmark is now a small "✓ Verified" pill, matching how the
mockup actually labels it, instead of an unlabeled icon.

Deliberately did NOT add a Deal-Completion-Rate badge here even though the
mockup shows one — neither listing model returns that field from the API
today (confirmed against `_listing_dict` in `listings/service.py`), and the
founder's own Document 2 says to hold off on it until there's enough
transaction data anyway. Faking a number would be worse than not showing
one.

Also deliberately did NOT add per-card blur/glassmorphism or drop shadows
— many cards render at once in a 2-column grid, and `BackdropFilter` in
particular is expensive per-instance in Flutter. Kept cards visually clean
and spent the glow budget on the Zone header and buttons instead, where
there's only ever one on screen at a time.

## Home screen category carousel

Each category icon's ring is now that category's own zone gradient
(subtle glow, not solid fill), so browsing the home screen previews which
Zone you're about to enter before you tap in.

## Buy-Agent sheet + Filter sheet buttons

Both "Start Buy Request" and "Apply Filters" were flat `ElevatedButton`s
with a solid violet fill — swapped for the app's own `GoldButton` (already
existed, already used elsewhere: gradient fill + glow), which these two
sheets just weren't using yet. No new component, just consistency.

## Not touched this round

Trader cards/list, Buy-Agent's own layout beyond the button, bottom nav,
and auction cards keep their current look — none were part of the
founder's original complaint, and every screen touched here was chosen
because it's either high-frequency (ProductCard, home screen) or the one
screen the original spec called out by name (the Zone). Worth a follow-up
pass once this round's been seen running on a real device.

---

# BROKA — Round 2 fixes off the Volume 6 build (Buy-Agent free text + empty-category visibility)

## 4. Buy-Agent sheet had no free-text entry point

Volume 6 Ch.8/Ch.11/Ch.28 specified BuyAgentSheet as a plain form (category
chips, max-price field, must-have-features chips) — a deliberate
simplification of the founder's original spec, not a rejection of it: the
founder's brief asked for something closer to "type a sentence, AI figures
out the rest" (e.g. "Samsung phone, 12GB RAM, good battery, under 30000").

**The fix:** added a free-text box at the top of the sheet with a "Let Zeno
fill this in" action. It calls a new endpoint that extracts
category/max_price/must_have_features from the sentence and pre-fills the
*same* fields the form already had — nothing about how a request gets
created or matched downstream changes, and the buyer still reviews/edits
before Start Buy Request. A bad or empty parse just leaves the fields for
manual entry, same as before this box existed.

**New backend surface:** `AIBrokerService.parse_buy_request()` (reuses the
existing Gemini/Groq `_call_ai` wiring — no new LLM integration) and
`POST /buy-agent-requests/parse`, constrained to whatever's actually in the
categories table so it can't invent a category that doesn't exist.

**Files touched:** `ai_broker/service.py`, `buy_agent/router.py`,
`services/api_service.dart`, `buy_agent/presentation/buy_agent_sheet.dart`

## 5. Empty categories were indistinguishable from "broken"

Both the home screen's category carousel and the Buy-Agent sheet's category
picker fail silently when the categories table is empty (see
`migrate_categories_from_freetext.py` — a one-off script, never yet run
against a live database, per Ch.19's own flagged risk). A founder or tester
seeing a blank strip has no way to tell "data not seeded" apart from
"this is broken."

**The fix:** both now show a low-key, non-alarming message once loading
finishes with zero rows ("Browse by category — coming soon" / "No
categories available yet"), instead of silently rendering nothing. This
does not seed any data — running the migration script below is still the
actual fix for the missing categories themselves.

**Files touched:** `screens/home_screen.dart`,
`buy_agent/presentation/buy_agent_sheet.dart`

## Flagged, not fixed: same photo-loss pattern in negotiate_screen.dart / negotiation_screen.dart

Both call `ImagePicker().pickImage(source: ImageSource.camera)` with no
`retrieveLostData()`, same as the Sell flow before fix #3 above. Not patched
here: the Sell flow's fix works because `splash_screen.dart` already knows
to resume straight into `SellPhotosScreen` when a draft exists. Neither
negotiation screen has an equivalent "resume into this exact thread" path,
so bolting on `retrieveLostData()` alone wouldn't reconnect it to anything —
it would need that resume path built first. Worth a dedicated pass if
photo-sending inside negotiations is actually dropping photos in practice.

---

# BROKA — Round 1 fixes off the Volume 6 build (Home screen + Sell photo loss)

Founder review of the first Volume-6 build against Design Journal Volume 6
turned up one real regression against that spec, a price-display bug, and a
recurrence of a photo-loss bug that had already been diagnosed and partly
fixed once before (see "Sell flow — photo capture kicking you back to Home"
below). This entry covers all three.

## 1. Goods/Brokers/House Hunting tab bar and the stats ticker were still shipping

Volume 6 Ch.23 (Phase 0) explicitly says to delete both the stats-row widget
and the Goods/Brokers/House Hunting/Traders TabBar as the very first step —
brokers and house hunting are out of scope for this release. Phases 1–5
(categories, trending, auctions, quick access) were all built correctly on
top of the new structure, but Phase 0's own removal never happened, so both
were still rendering above the category carousel.

**The fix:** deleted `_buildTabBar()`, `_buildTickerStrip()`, and every
field/controller that only existed to support them (`_tabCtrl`, `_tabs`,
`_tabCategories`, `_tickerTimer`, `_tickerShift`). `_fetchListingsPage()` and
`_emptyState()` no longer branch on a tab index — Goods is the only mode
this screen ever renders now (Traders is its own screen behind the mode
toggle, untouched).

**Files touched:** `screens/home_screen.dart`

## 2. Listing prices under 10K were rounding to the nearest thousand

`priceFormatted` divided by 1,000 and rounded to zero decimals for any price
≥1,000, so a KES 1,500 listing displayed as "KES 2K" — a third more than the
actual price. Not a hardcoded value; a rounding artifact that only becomes
obvious on small-ticket items.

**The fix:** prices from 1,000–9,999 now keep one decimal (`KES 1.5K`);
10K and above still round to whole thousands, where the lost precision is
proportionally small. Applied to both `BrokaListing.priceFormatted` and
`ProductCard._formatKes` (the two places this logic was duplicated) —
left the price-filter slider's own formatter alone, since a coarse filter
control rounding to the nearest thousand is fine and always was.

**Files touched:** `features/listings/domain/models/listing.dart`,
`widgets/product_card.dart`

## 3. Sell-flow photo loss on camera kill — the "fixed" bug came back because it was only half-fixed

The earlier fix below (`SellDraftStore` + splash-screen resume) protects
every photo that was already added to the draft *before* the next camera
launch. It cannot protect the one photo that's mid-capture at the exact
instant Android kills the process — that shot was never in the draft to
begin with, and its `pickImage()` Future is abandoned for good once the
isolate awaiting it is gone. On the very first photo of a listing (nothing
upstream yet persisted), that failure mode looks identical to "no images
have been uploaded" — which is almost certainly what happened to the
"xpon router" listing showing no photo on Trending: not a display bug, but
this same capture getting lost during creation.

**The fix:** `SellPhotosScreen` now also calls `image_picker`'s
`retrieveLostData()` on init, sequenced *after* draft-restore completes (not
in parallel — running both at once risked the draft-restore's `_data =
restored` silently wiping out a photo the lost-data check had just
recovered). This is `image_picker`'s own Android-specific channel for a
result that arrives after a cold restart, separate from the Future the
original call could no longer resolve. No-ops safely everywhere else.

**Still true after this fix:** the brief splash-screen flash itself can't be
prevented — that's Android reclaiming memory from a backgrounded process,
not something in the app's control (see below). What changes is that the
photo you just took stops disappearing along with it.

**Files touched:** `screens/sell_photos_screen.dart`

---

# BROKA v6.1 — Phone-first onboarding rework

Reworked account creation end-to-end, based on a founder + reviewer design
pass on the original email/username-based signup flow. Three goals drove
this: (1) let people see the app's value before being asked to sign up,
(2) make phone the identifier instead of email, since a meaningful share of
the target user base is unfamiliar or uncomfortable with email-based signup,
and (3) stop forcing the buyer/seller choice at signup.

## 1. Browse-before-signup

Splash now always routes to Home, logged in or not — the previous
`Splash → Auth → Home` gate (auth required before seeing anything) is gone.
Guests can browse freely; only account-gated actions (Sell, talk to Zeno,
Inbox/negotiations, Profile) prompt sign-up, and — importantly — resume
exactly where the user was headed once they finish, rather than dropping
them back at Home. See `lib/utils/auth_gate.dart`.

## 2. Phone replaces email as the identifier

- `users.phone` is now required + unique; `users.email` is now optional
  (kept, not removed — still useful for password recovery, invoicing, and
  cross-border expansion later, per the design discussion).
- Registration is a 3-step server flow: `POST /auth/otp/request` (sends a
  6-digit SMS code via Africa's Talking, wrapped in the same
  circuit-breaker pattern used for the Gemini/Groq AI fallback chain) →
  `POST /auth/otp/verify` (returns a short-lived signed `phone_verify_token`)
  → `POST /auth/register` (requires that token — you cannot register a
  phone number that hasn't actually received and confirmed the code).
- `POST /auth/login` now takes `{phone, password}` instead of
  `{email, password}`. Biometric login is unchanged (still device-local,
  unlocks the stored session).
- OTP entry in the app uses Flutter's built-in `AutofillHints.oneTimeCode`
  (system-level SMS autofill on both Android and iOS) rather than a
  third-party plugin — no new native permissions, no SHA-hash app
  signature registration to maintain.

## 2a. Migration note

Existing rows (there shouldn't be any in production yet) get a placeholder
`unverified-<id>` phone so the new NOT NULL + UNIQUE constraint doesn't fail
the migration; those accounts can't log in by phone until backfilled
manually. See `migrations/versions/0011_phone_first_onboarding.py`.

## 3. Buyer vs. buyer+seller: no longer a forced choice

Every account starts as `buyer`. Becoming a seller is a separate action
(`POST /auth/upgrade-to-seller`, new "Become a Seller" screen reachable from
Profile) — matches the reviewed decision that most people start as buyers
and shouldn't have to decide upfront.

Seller identity is collected as **structured fields**, not one free-typed
name: `business_name` + `business_category` + `business_location` →
server auto-generates `business_display_name` (e.g. `Clanix · Wholesale ·
Sira`). This was a deliberate change from the original "seller types the
whole thing" idea — a free-typed field would fragment the same business
into "Clanix-Ugunja" / "Clanix ugunja" / "CLANIX" variants that break
search and confuse Zeno's business-description matching. `business_description`
is preserved as free text — that one's meant for Zeno to read, not for
generating an identifier.

## 4. Flutter side

- `lib/utils/auth_gate.dart` (new): `requireAuth()` shows a sign-up prompt
  only when a guarded action is tapped, and lets the caller resume that
  exact action afterward (`AuthScreen` now pops `true` back to its caller
  instead of always replacing with Home — see `_returnAuthenticated()` in
  `auth_screen.dart`).
- `splash_screen.dart`: always proceeds to Home (or a saved sell draft)
  regardless of login state.
- `home_screen.dart`: bottom nav (Inbox / Sell / Zeno / Profile) gated
  through `requireAuth`; Home browsing itself is not.
- `product_screen.dart`: "Start Negotiation" gated the same way.
- `auth_screen.dart`: rewritten as a 6-step wizard (Phone → Verify Code →
  Basic Info → Selfie → Biometrics → Confirm). OTP entry uses Flutter's
  built-in `AutofillHints.oneTimeCode` (system-level SMS autofill on both
  Android and iOS) rather than a third-party plugin. Login form now takes
  phone + password.
- `profile_screen.dart`: no more fake `user@broka.ke` placeholder when a
  user has no email (email tile is now conditional; phone is always shown).
  The Seller Dashboard tile now branches — buyers see "Become a Seller"
  (→ new `become_seller_screen.dart`), buyer_sellers see the dashboard as
  before.
- Also fixed in passing: `currentUserPhone` existed as a field in
  `api_service.dart` (read by `boost_screen.dart` and
  `verification_screen.dart`) but was never actually saved/loaded from
  storage — a pre-existing latent bug. It's wired up correctly now, as a
  side effect of adding phone to the session-persistence path.

## 5. Guest browsing already worked server-side — verified, not changed

`GET /listings/`, `GET /listings/{id}`, and `GET /listings/stats` had no
`get_current_user` dependency already — browsing was never actually
gated on the backend. `POST /listings/` (create), the negotiate endpoints,
and the Zeno/ai_broker endpoints all do require it, confirmed by reading
each router directly, which is what actually makes the Flutter-side gate
meaningful rather than a purely cosmetic client-side check. Added
`get_current_user_optional` to `api/security.py` for future guest-facing
personalization, but nothing currently calls it — noting that so it isn't
mistaken for wired-up behavior.

## What you'll need to do

- Run the new migration (`alembic upgrade head`) — includes the phone
  backfill described above.
- Set `AT_USERNAME` / `AT_API_KEY` (and optionally `AT_SENDER_ID`) for real
  SMS delivery. Without them, `/auth/otp/request` logs the code instead of
  sending it (and — non-production environments only — returns it as
  `debug_code` in the response), so registration is fully testable without
  a live SMS account, but **must** be configured before a real deploy.
- `api/routers/auth.py` (email/password, legacy) was already dead code
  before this change — not imported by `main.py`, only `api/domains/auth/router.py`
  is live. Left it in place rather than deleting it since it wasn't part of
  what was asked, but it now describes a signup flow that no longer exists
  anywhere else in the app; worth deleting in a follow-up cleanup pass.
- Tests in `tests/test_auth.py` were rewritten for the new flow but
  **could not be executed in this environment** (no network egress) —
  run `pytest backend/tests/test_auth.py -v` before merging.



## 1. Listing images sometimes rendering blank

Root cause: `Image.memory(base64Decode(photo))` on the home feed card and the
listing detail gallery had no `errorBuilder`. The surrounding `try/catch`
only catches `base64Decode()` throwing synchronously (malformed base64) — it
does **not** catch the image failing to decode as an actual picture, which
Flutter does asynchronously at the paint layer. A listing whose stored photo
bytes are valid base64 but not a decodable image (truncated upload, an
unsupported format, corrupted data, etc.) would pass `base64Decode()` fine
and then silently paint nothing, with no exception for the `catch` block to
catch. Card text/price/CTA would still show — it's only the image itself
that vanished, which matches a card rendering with an empty background.

Fixed in both places by adding `errorBuilder` directly to the `Image.memory`
call, so a bad decode now falls back to the same gradient+emoji placeholder
used when a listing has no photo at all, instead of rendering blank.

Note: several other `Image.memory` calls elsewhere (profile photos, chat/
seller avatars) have this same missing-`errorBuilder` gap and could show the
same symptom under bad data — left alone for now since only listing images
were reported, happy to sweep the rest on request.

## 2. English voice: Kenyan → American accent

`EDGE_VOICES["english"]` (backend `tts.py`) changed from
`en-KE-AsiliaNeural` to `en-US-AriaNeural` — both are Microsoft Edge TTS
neural voices, both **female**, only the accent changes. Updated the
Flutter-side device-TTS fallback locale (`broka_tts.dart`, only used if the
cloud `/tts/speak` call itself fails) from `en-KE` to `en-US` to match, so
the rare fallback case doesn't suddenly sound Kenyan again.

Swahili's voice, and the speech-*recognition* locale used for the mic input
button on the Zeno screen (`zeno_screen.dart`'s `ttsLocale`, actually an STT
setting despite the name), were left untouched — different feature, and
changing what the recognizer expects to hear wasn't asked for.

## What you'll need to do

- Nothing beyond the usual deploy — no new dependency, no migration.
- Worth clearing the TTS in-memory cache expectation: the first time each
  cached English phrase is spoken after this deploy it'll re-fetch (new
  voice = new cache key implicitly, since old audio bytes simply age out of
  the 40-item in-memory cache on restart).

# BROKA — Removed video from listings (mobile data usage)

Product listings are photo-only now. This was a deliberate data-usage fix: the
home feed was autoplaying a promotional "advert video" per card, falling back
to the mandatory verification video when a listing had no advert video — so
almost every card in the feed was silently downloading and decoding video
just to render, which is expensive for the mobile-data-first user base this
app targets, and drives up storage costs as more listings accumulate.

## What changed

- **Sell flow** (`sell_screen.dart`): removed the optional "Advert Video"
  capture entirely — its picker bottom sheet, draft-persistence keys, and the
  `advert_video` payload field. The mandatory **Verification Video** capture
  is untouched — still required at listing creation as possession/fraud
  proof, it's just no longer rendered anywhere for buyers to watch.
- **Home feed** (`home_screen.dart`): cards never play video now.
  `_buildBackground()` always renders the first verified photo (or the emoji
  placeholder on the rare listing with none).
- **Listing detail** (`product_screen.dart`): same change — the photo
  gallery is the only media view; the video player and the secondary
  photo-strip-under-video widget are gone.
- **Models** (`models/listing.dart`,
  `features/listings/domain/models/listing.dart`): dropped the now-unused
  `verifiedVideo`/`advertVideo` fields and the `feedVideo` getter.
- **Buyer tips**: reworded the "request verification photos/video" tip to
  photos only — the app has no way to receive a video from a seller anymore.
- **`pubspec.yaml`**: removed the `video_player` dependency; nothing imports
  it anymore.

## What was deliberately left alone

- **Backend** `advert_video` column/field (`database.py`, `schemas.py`, both
  listings routers, migration `0001`) — left in place rather than migrated
  away. It's already `nullable`/`Optional`, so it's harmless dead weight now
  that Flutter stops sending it, and dropping a column is a riskier change
  than just not using it. Happy to add a proper drop-column migration on
  request.
- **Verification video capture itself** — still required, still uploaded
  once per listing. That's a one-time seller→server cost, not the
  many-buyers × feed-scrolling cost that was actually driving data usage, so
  it wasn't the target of this change.

## What you'll need to do

- `flutter pub get` (dependency removed from `pubspec.yaml`).
- Full rebuild, not a hot reload — removes a native-backed plugin.
- No backend changes, no migration, no manual deploy step.

# BROKA — Video Calls, Ringtone & Screen-Off Call Drop Fix

## 1. Video calls

- New video-call button next to the existing audio-call button in the direct-chat header.
- `WebRtcService` now negotiates a video track when `callType == 'video'` (front camera by default), with front/back camera switching and video on/off toggle mid-call.
- Call screen: full-screen remote video once connected, small local camera preview (tap it to flip camera), extra controls (video toggle, flip camera) alongside the existing mute/end/speaker.
- Call type is threaded end-to-end: initiate → FCM push payload → pending-call poll → incoming-call dialog → call screen → call-history log → call-back (calling back a missed video call opens with video, not just audio).
- New `call_type` column on `negotiation_messages` (migration `0009_call_type.py`). Runs automatically on your next deploy since your Dockerfile already does `alembic upgrade head` before starting uvicorn — no manual step needed.

## 2. Ringtone for incoming calls (audio or video)

- New `RingtoneService` loops a short, original two-tone chime (`assets/audio/ringtone.mp3` — synthesized from scratch, not sampled) for as long as an incoming-call dialog/screen is showing, for both call types.
- Routed through Android's ringtone audio usage so it respects the phone's ringer volume/silent/vibrate state, the way an incoming call should.
- Has a built-in 45-second safety timeout so it can never ring forever (e.g. if the caller cancels before your device's next poll notices).
- Also wired the same sound in as a real Android notification-channel sound (`res/raw/ringtone.mp3`) for the OS-level "Incoming Calls" notification.
  - **Note:** the channel ID changed from `broka_calls` → `broka_calls_v2`. Android locks in a channel's sound once it's been created on a device, so keeping the old ID would have meant nobody who already had the app installed would ever hear the new sound. The new ID guarantees it takes effect for everyone on the next update, no reinstall needed.

## 3. Screen-off call-drop fix

Root cause was two separate things stacking on top of each other:

1. **Android's background mic/camera restriction.** From Android 9+, an app that isn't in the foreground — and isn't running a foreground service — loses microphone/camera access outright. Locking the screen mid-call is exactly this situation.
2. **A `main.dart` side-effect.** The app force-navigates back to `/home` on resume if it had been backgrounded for 5+ minutes — which would have yanked you straight out of any call that had the screen off for that long, whether or not #1 had already killed the audio.

Fixed both:

- **`CallForegroundService.kt`** (new) — a real Android foreground service that runs for the duration of a call. It holds a partial wake lock (CPU keeps running; the screen is still allowed to lock/turn off as normal, exactly like a real phone call) and declares the microphone/camera foreground-service types Android 14+ requires. Started/stopped from `voip_call_screen.dart` over a MethodChannel (`call_foreground_service.dart`) the instant a call begins/ends.
- **`main.dart`** — the resume-triggered redirect-to-home now explicitly excludes the `/voip-call` route.

## What you'll need to do

- `flutter pub get` (new asset entry in `pubspec.yaml`).
- Full rebuild/reinstall on your test device — this includes a new native Kotlin file and new manifest permissions, so a hot reload won't pick it up.
- On the backend, nothing manual — the migration runs automatically on deploy.
- Worth specifically testing: place a call, lock the screen for a couple of minutes, unlock, confirm audio (and for video calls, camera) is still flowing.

## Files touched

**Backend:** `database.py`, `routers/calls.py`, `routers/negotiate.py`, `routers/media.py`, `migrations/versions/0009_call_type.py` (new)

**Flutter:** `pubspec.yaml`, `main.dart`, `models/models.dart`, `services/api_service.dart`, `services/webrtc_service.dart`, `services/notification_service.dart`, `services/global_poller_service.dart`, `services/ringtone_service.dart` (new), `services/call_foreground_service.dart` (new), `screens/voip_call_screen.dart`, `screens/negotiation_screen.dart`, `assets/audio/ringtone.mp3` (new)

**Android:** `AndroidManifest.xml`, `MainActivity.kt`, `CallForegroundService.kt` (new), `res/raw/ringtone.mp3` (new)

Everything else in this archive is untouched, carried over as-is from your upload.

---

# BROKA — Inbox Offline Persistence & Read Receipts

## 1. Inbox wasn't actually using the offline cache

The Inbox *list* screen (`inbox_screen.dart`) was calling the network directly with no fallback at all — on any failure (like the DNS lookup error in your screenshot) it just dumped the raw exception on screen with nothing to look at but a Retry button. `LocalChatStore` (the on-device cache) was already correctly wired into the individual chat *threads* (`negotiation_screen.dart`) — it just was never connected to the inbox list itself, which is what you were actually looking at in the screenshot.

Fixed by giving the inbox the same cache-first pattern the threads already use:
- On open, instantly paints whatever was cached on-device, before the network call even starts.
- On a successful refresh, replaces it with live data and re-caches.
- On a failed refresh: if something's already showing (fresh or cached), it now stays on screen instead of being replaced by an error page — you just get a small "You're offline" banner. The full-screen error only appears if there's truly nothing cached yet (e.g. very first launch with no connection).
- Also replaced the raw `ClientException`/`SocketException` dump with a plain "No internet connection" message for the genuine no-cache case.

## 2. Read receipts ("seen" ticks)

Added real read tracking, backed by a new `thread_read_state` table (migration `0010`) — one row per (listing, buyer, side) holding "read up to this timestamp," the same watermark approach WhatsApp/Telegram use rather than flagging every individual message.

- Two new endpoints: `POST /negotiate/{listing_id}/mark-read` (called whenever you open or actively view a thread) and `GET /negotiate/{listing_id}/read-status` (returns when each side last read it).
- In the chat thread itself: every message you sent now shows a tick — single grey (sent) or double tick, grey (sent, not yet seen) vs blue (seen) — updated live as the other person reads your messages.
- In the inbox list: the same real seen-status now drives the tick next to your last message, and only shows when you actually sent that last message (previously this icon was a bit of a fake — it just meant "I have nothing unread," not "they saw what I sent").
- **Bonus fix:** the inbox `unread` count was hardcoded to `0` server-side the whole time — the UI (badges, bold text) was already built for it, it just never had real data. That's now wired up off the same read-state table.

## You'll need to
- Nothing manual on the backend — migration `0010` runs automatically on deploy, same as `0009`.
- `flutter pub get` isn't needed this time (no new packages), but this does touch several screens, so a full rebuild is still the safer bet over hot-reload.

## Files touched this round
**Backend:** `database.py`, `routers/negotiate.py`, `migrations/versions/0010_thread_read_state.py` (new)
**Flutter:** `services/api_service.dart`, `screens/inbox_screen.dart`, `screens/negotiation_screen.dart`

---

# Build fix — GitHub Actions failure

Your CI run failed at the Flutter compile step:

```
lib/services/ringtone_service.dart:40:14: Error: Cannot invoke a non-'const' constructor where a const expression is expected.
lib/services/ringtone_service.dart:32:43: Error: Cannot invoke a non-'const' constructor where a const expression is expected.
```

`ringtone_service.dart` was marking `AudioContext(...)` (from `audioplayers`) as `const`, but that class isn't actually const-constructible in `audioplayers` 6.4.0 (the version your `^6.1.0` constraint resolved to). Removed the `const` there - functionally identical, just not a compile-time constant.

While I was at it, I found and pre-emptively fixed the same risk in two spots in `notification_service.dart` that hadn't yet failed a build but were relying on the same unverified assumption (`RawResourceAndroidNotificationSound` and `DarwinNotificationDetails`, both added for the ringtone-as-notification-sound feature) - swept the whole diff for anything similar, and confirmed those were the only three spots.

**Files touched:** `services/ringtone_service.dart`, `services/notification_service.dart`

---

# Sell flow — photo capture kicking you back to Home

## What was actually happening

"Directed to the splash screen, like I'd just clicked the app icon" was the right read - that's exactly what it was. Taking a photo hands the foreground over to the system camera app, and on a memory-constrained phone Android can, and does, kill BROKA's process in the background to free that memory. When you back out of the camera, Android relaunches BROKA from nothing - a brand new process, a fresh splash screen - and since Flutter keeps no memory of the old screen, the entire in-progress listing (every field, every photo already taken) was just gone. Splash screen then saw you were still logged in and sent you to Home, since as far as the app could tell, that's a completely fresh launch - it has no way to know you were actually mid-task.

This also explains why video never did this: `pickVideo` just hands back a file path, no extra processing. `pickImage` (with `maxWidth`/`imageQuality` set, so it compresses on the way in) does noticeably more work exactly when the app is most memory-starved - not the sole reason this class of kill happens, but a real contributor.

This can't be prevented outright - Android is explicit that any backgrounded process is fair game to kill - so instead of chasing the root cause, I made the flow resilient to it, which is the standard way this gets handled.

## The fix

- New `SellDraftStore` (same on-device pattern as the chat cache) snapshots the whole in-progress listing - every field, plus the photos/video already taken - right before every single camera/video launch, which is the highest-risk moment.
- `SellScreen` restores it automatically on open, with a small "Draft restored" banner and a Discard option if you don't want it.
- **Splash screen now checks for a pending draft before deciding where to send you** - if one exists, it opens straight back into the listing instead of Home. This is the part that directly fixes what you were seeing.
- Also autosaves (debounced) on ordinary field edits and photo/video removals, so the same protection covers more than just the camera moment.
- Draft is cleared automatically once the listing is successfully submitted.

One honest caveat: the brief splash-screen flash itself can still happen sometimes - that's just how a cold process restart works on Android, and isn't something an app can skip. What's fixed is landing back in your listing with everything intact afterward, instead of losing it all at Home.

**Files touched:** `services/sell_draft_store.dart` (new), `screens/sell_screen.dart`, `screens/splash_screen.dart`


---

# Build fix — backend CI test failure (`test_traders.py`)

Your CI run failed on the backend test suite:

```
FAILED tests/test_traders.py::TestTraders::test_specialization_derived_from_listings_not_self_declared - AssertionError: assert 'cat-electronics-2' in []
```

with this underneath it in the captured logs:

```
ERROR    api.core.events  [events] handler on_listing_created_update_specialization raised for event ListingCreated: Multiple rows were found when one or none was required
```

Root cause turned out to be bigger than that one test. `api/database.py` builds its DB engine once, the moment it's first imported - but every test file tries to sandbox itself with its own `monkeypatch.setenv("DATABASE_URL", ...)` inside a fixture, which runs *after* that first import already happened. Since CI runs the whole suite in one process (`pytest tests/ -v`, `DATABASE_URL=sqlite+aiosqlite:///:memory:`), every test file was actually sharing that one in-memory database the whole time, regardless of which "isolated" sqlite path each file's own fixture thought it was pointing at. `test_categories.py` seeds a Category named "Electronics"; `test_traders.py` seeds a second, differently-`id`'d Category also named "Electronics" - both landed in the same shared db, so `Category.name == "Electronics"` matched two rows, and `scalar_one_or_none()` raised instead of returning one.

(You'd actually already run into a symptom of this exact bug once before - see the phone-uniqueness comment in `tokens()` in `test_escrow.py`.)

## The fix

- `api/database.py`: added `reset_engine()`, and turned `AsyncSessionLocal` into a function that always resolves the *current* engine/session factory, instead of a `sessionmaker` object frozen at import time. Every existing `AsyncSessionLocal()` call site keeps working unchanged - nothing else needed to change.
- All 10 test files that touch the DB now call `reset_engine()` right after `monkeypatch.setenv("DATABASE_URL", ...)`, so each module actually gets its own isolated db, like its own fixture already claimed it did.
- `trader_specialization_subscribers.py`: the Category lookup no longer assumes `Category.name` is unique - it isn't, no constraint enforces that. It now orders top-level-categories-first and picks deterministically instead of crashing if two rows ever do share a name, whether that's a test-isolation artifact or a real duplicate in production.

Couldn't run `pytest` myself to confirm green (no network/deps in this environment) - worth a run on your end before merging.

**Files touched:** `backend/api/database.py`, `backend/api/core/trader_specialization_subscribers.py`, `backend/tests/test_auctions.py`, `backend/tests/test_auth.py`, `backend/tests/test_buy_agent.py`, `backend/tests/test_categories.py`, `backend/tests/test_deal_ws.py`, `backend/tests/test_escrow.py`, `backend/tests/test_interest_nudges.py`, `backend/tests/test_listings.py`, `backend/tests/test_traders.py`, `backend/tests/test_trending.py`
