"""What it costs BROKA to run things - the floor every price is built on.

Every price in this domain is either a cost from this file or a cost from
this file multiplied by something PRICING.md argues for. Nothing is priced
below what it costs to serve: the tests check each plan against its
maxed-out cost, so a price edit that would lose money on a heavy user fails
CI instead of reaching a seller.

Unit costs are the published rates as of September 2026, converted at
USD_KES. Usage figures (tokens per message, chats per listing) are
assumptions until telemetry replaces them; each says so. When a provider
changes its price, change the constant here and the prices move with it.
"""
from __future__ import annotations

import math

# ── Exchange rate ────────────────────────────────────────────────────────────
# USD/KES traded 129.3-129.7 in the second half of September 2026.
USD_KES = 129.5


def usd(amount_usd: float) -> float:
    """US dollars to shillings."""
    return amount_usd * USD_KES


# ── AI: DeepSeek V4.1 Flash (the primary model) ──────────────────────────────
# Official rates effective 2026-09-10, USD per 1M tokens, off-peak. Peak
# (01:00-04:00 and 06:00-10:00 UTC on weekdays = 04:00-07:00 and 09:00-13:00
# EAT) is exactly double.
DEEPSEEK_INPUT_MISS_USD_PER_M = 0.15
DEEPSEEK_INPUT_HIT_USD_PER_M = 0.003
DEEPSEEK_OUTPUT_USD_PER_M = 0.60
DEEPSEEK_PEAK_MULTIPLIER = 2.0
# Assumption: the 09:00-13:00 EAT peak window is prime marketplace time, so
# a large share of chats land in it. 40% keeps the estimate on the high side.
PEAK_SHARE = 0.40
# Assumption: DeepSeek caches repeated prompt prefixes automatically. Zeno's
# system prompt and the thread so far repeat on every call of a thread, so
# half the input tokens being cache hits is conservative.
CACHE_HIT_SHARE = 0.50

_PEAK_BLEND = (1 - PEAK_SHARE) + PEAK_SHARE * DEEPSEEK_PEAK_MULTIPLIER


def ai_call_cost(input_tokens: float, output_tokens: float) -> float:
    """Shillings for one model call at the blended peak/off-peak, cached rate."""
    input_rate = (CACHE_HIT_SHARE * DEEPSEEK_INPUT_HIT_USD_PER_M
                  + (1 - CACHE_HIT_SHARE) * DEEPSEEK_INPUT_MISS_USD_PER_M) * _PEAK_BLEND
    output_rate = DEEPSEEK_OUTPUT_USD_PER_M * _PEAK_BLEND
    return usd((input_tokens * input_rate + output_tokens * output_rate) / 1_000_000)


# One message in a negotiation thread. api/core/ai_cost.py describes the
# pipeline: a relay classifier on most messages (~900 tokens in; the
# pre-filter skips about 30% of them), the reply to the sender (~3,500 in,
# ~250 out: listing, thread and policy) and, about half the time, the relay
# to the other party (the same again). Assumption until tokens are logged.
NEGOTIATION_MESSAGE_INPUT_TOKENS = 0.7 * 900 + 3_500 + 0.5 * 3_500
NEGOTIATION_MESSAGE_OUTPUT_TOKENS = 0.7 * 10 + 250 + 0.5 * 250
AI_PER_NEGOTIATION_MESSAGE = ai_call_cost(
    NEGOTIATION_MESSAGE_INPUT_TOKENS, NEGOTIATION_MESSAGE_OUTPUT_TOKENS)

# A buyer thread: about seven messages from each side before it agrees,
# stalls or moves to a call. Assumption.
MESSAGES_PER_THREAD = 14

# One turn of Zeno as the assistant or the Buying Agent's conversation:
# ~3,000 tokens of instructions and context in, ~250 out.
AI_PER_ASSISTANT_TURN = ai_call_cost(3_000, 250)

# Posting a listing: price suggestion, description help and a scam check,
# about 2,000 tokens in and 400 out each.
AI_PER_NEW_LISTING = 3 * ai_call_cost(2_000, 400)

# Zeno negotiating one seller on a buyer's behalf (auto-negotiate): about
# ten exchanges, each a negotiation message plus the agent deciding its move.
AI_PER_AUTO_NEGOTIATION = 10 * (AI_PER_NEGOTIATION_MESSAGE + AI_PER_ASSISTANT_TURN)


# ── Messaging ────────────────────────────────────────────────────────────────
# Mobitech, BROKA's SMS provider, charges KES 0.35 a message, whatever its
# length. (Kenya's bulk market runs KES 0.25-0.80 a message.)
SMS = 0.35
# FCM push: free.
PUSH = 0.0


# ── Voice ────────────────────────────────────────────────────────────────────
# Streaming speech-to-text, per minute the microphone is open. Deepgram
# Nova-3 is $0.0077/min at its regular rate (a $0.0048 promotion is running);
# AssemblyAI Universal-Streaming is $0.15/hour = $0.0025/min. Plans are
# costed at Deepgram's regular rate so a switch between the two never turns
# a plan unprofitable.
STT_PER_MINUTE = usd(0.0077)
# Zeno answers about three times in a voice minute.
VOICE_TURNS_PER_MINUTE = 3
# Speech out is Microsoft Edge TTS today, which costs nothing - but it is an
# unofficial endpoint. A paid neural voice (~$16 per 1M characters, ~450
# characters a minute) would add about KES 0.93/min; plans leave room for it.
TTS_RESERVE_PER_MINUTE = usd(16 * 450 / 1_000_000)
VOICE_MINUTE = STT_PER_MINUTE + VOICE_TURNS_PER_MINUTE * AI_PER_ASSISTANT_TURN + TTS_RESERVE_PER_MINUTE
# What voice mode is metered in: one thing said to Zeno - about twenty
# seconds of open microphone, one reply, spoken back. The microphone time is
# spent on the phone, straight to the speech provider, where BROKA cannot
# count it; the turn reaches BROKA, so the turn is what is counted.
VOICE_REQUEST = VOICE_MINUTE / VOICE_TURNS_PER_MINUTE

# Calls: Cloudflare Realtime TURN is $0.05/GB after 1,000 GB free each
# month. A relayed voice call moves ~0.6 MB a minute, video ~9 MB. Even
# video is under KES 0.06 a minute, and the free 1,000 GB covers ~110,000
# video minutes - calls are not priced separately.
CALL_VIDEO_MINUTE = usd(0.05 * 9 / 1024)


# ── Images ───────────────────────────────────────────────────────────────────
# AI Showcase covers: Qwen-Image-Edit through Hugging Face, ~$0.03 a
# megapixel - about $0.024 for a 1024x768 cover. Kept at the $0.04 FLUX.1
# Kontext [pro] cost it replaced: a ceiling, so plan prices and margins
# don't move with the switch, and room if HF_SHOWCASE_MODEL is changed.
AI_SHOWCASE_IMAGE = usd(0.04)
# Covers are made while a listing is posted, and a seller rarely keeps the
# first one: a look, then another look or a retry. Assumption until the
# app's cover step is measured.
AI_COVER_TRIES_PER_LISTING = 3


# ── Platform infrastructure at planning scale ────────────────────────────────
# Fixed monthly costs, spread over the active listings they serve. Priced at
# the GROWTH scale below, not at launch: at launch the same bill is spread
# over a tenth of the listings, and charging early sellers ten times the
# real cost would kill the supply BROKA needs first. The launch gap
# (PRICING.md, "The cold-start gap") is a budget line, not a fee.
PLANNING_ACTIVE_LISTINGS = 20_000
PLANNING_MONTHLY_ACTIVE_USERS = 15_000

_SECONDS_PER_MONTH = 730 * 3600

# BROKA's API runs on Azure Container Apps in South Africa North (the
# nearest Azure region; AZURE_MIGRATION_AUDIT.md). Azure publishes its rates
# for East US; South Africa North is taken as 25% dearer - an assumption,
# near the 31% AWS charges for Cape Town over Virginia - until the Azure
# invoice replaces it.
AZURE_REGION_PREMIUM = 1.25

# Container Apps, consumption plan: $0.000024/vCPU-s and $0.000003/GiB-s
# while active, $0.40 per million requests, after a monthly free 180,000
# vCPU-s, 360,000 GiB-s and 2M requests. Two replicas of 1 vCPU / 2 GiB,
# always on: the call-signalling WebSockets and the 5-minute sweep need a
# live process, and an open socket keeps a replica billed as active. (One
# replica today - the audit's process-local state must be fixed before a
# second - but planning scale needs two.) ~1,500 API requests per active
# user a month.
_REPLICA_SECONDS = 2 * _SECONDS_PER_MONTH
CONTAINER_APPS_MONTHLY = usd(AZURE_REGION_PREMIUM * (
    max(0, _REPLICA_SECONDS * 1 - 180_000) * 0.000024
    + max(0, _REPLICA_SECONDS * 2 - 360_000) * 0.000003
    + max(0, PLANNING_MONTHLY_ACTIVE_USERS * 1_500 - 2_000_000) / 1_000_000 * 0.40
))
# Container Registry, Basic tier, for the images Container Apps runs.
CONTAINER_REGISTRY_MONTHLY = usd(5.0)
# Azure Database for PostgreSQL flexible server, General Purpose D2ds_v5
# (2 vCores, 8 GiB, ~$125/month) with 64 GiB of storage (~$0.115/GiB);
# backups up to the storage size are included.
POSTGRES_MONTHLY = usd(AZURE_REGION_PREMIUM * (125.0 + 64 * 0.115))
# Redis for rate limits, pub/sub, idempotency keys and call state: Azure
# Cache for Redis Basic C1 (1 GB, ~$40/month).
REDIS_MONTHLY = usd(AZURE_REGION_PREMIUM * 40.0)
# Log Analytics for the Container Apps logs: ~10 GB a month at ~$2.30/GB
# after 5 GB free, with headroom.
LOGS_MONTHLY = usd(15.0)
# Cloudflare R2 for images: $0.015/GB-month after 10 GB free, egress free.
# 20,000 listings x 5 photos x ~250 KB across the resized copies = ~25 GB.
R2_MONTHLY = usd(max(0, 25 - 10) * 0.015 + 1.0)
# Internet egress from South Africa North (Azure's Zone 3): $0.181/GB after
# 100 GB free a month. Images come from R2, so this is API JSON and
# sockets: ~20 MB per active user.
EGRESS_MONTHLY = usd(max(0, PLANNING_MONTHLY_ACTIVE_USERS * 20 / 1024 - 100) * 0.181)
# The web storefront on Vercel Pro ($20; Hobby forbids commercial use),
# Sentry Team ($26), logging headroom ($10).
WEB_AND_MONITORING_MONTHLY = usd(20 + 26 + 10)
# broka.co.ke (~KES 1,500/year), Apple Developer ($99/year), Google Play
# ($25 once, spread over two years).
STORES_AND_DOMAIN_MONTHLY = 1_500 / 12 + usd(99 / 12) + usd(25 / 24)

INFRA_MONTHLY = (CONTAINER_APPS_MONTHLY + CONTAINER_REGISTRY_MONTHLY + POSTGRES_MONTHLY
                 + REDIS_MONTHLY + LOGS_MONTHLY + R2_MONTHLY + EGRESS_MONTHLY
                 + WEB_AND_MONITORING_MONTHLY + STORES_AND_DOMAIN_MONTHLY)
INFRA_PER_LISTING_MONTH = INFRA_MONTHLY / PLANNING_ACTIVE_LISTINGS

# ── People ───────────────────────────────────────────────────────────────────
# One support and moderation person (KES 40,000/month, Nairobi customer-care
# pay) per 20,000 active listings: reviewing reports, fixing listings,
# answering sellers. Disputes are paid for by commission, not here.
SUPPORT_MONTHLY_SALARY = 40_000
SUPPORT_PER_LISTING_MONTH = SUPPORT_MONTHLY_SALARY / PLANNING_ACTIVE_LISTINGS
# Minutes of a person's time for "priority support", at the same salary
# over ~160 working hours.
SUPPORT_PER_MINUTE = SUPPORT_MONTHLY_SALARY / (160 * 60)

# ── Overhead ─────────────────────────────────────────────────────────────────
# On top of every cost: a 1.5% Turnover Tax reserve (Kenya's rate on gross
# receipts since December 2024; it was 3%) and 12% for what the averages
# miss: fallback models dearer than DeepSeek, failed payments, refunds,
# traffic spikes.
OVERHEAD = 1.135

# ── VAT ──────────────────────────────────────────────────────────────────────
# Past the VAT threshold (KES 5M-8M of turnover a year; confirm with KRA)
# BROKA owes 16% of every fee and plan it sells. Prices are set VAT-included
# from the start, so crossing the threshold never forces a price rise: the
# floors below are checked on what is left once VAT is taken out. Before
# registration the difference is margin.
VAT_RATE = 0.16


def with_vat(amount: float) -> float:
    """What must be charged for `amount` to be left after VAT."""
    return amount * (1 + VAT_RATE)


def net_of_vat(price: float) -> float:
    """What BROKA keeps of a VAT-included price."""
    return price / (1 + VAT_RATE)


# ── Premium features ─────────────────────────────────────────────────────────
# One Buying Agent watch for a month: setting it up and adjusting it is about
# eight assistant turns. Matching new listings against it is rules, not a
# model call (buy_agent/matching.py), and match alerts go by push.
AGENT_WATCH_MONTH = 8 * AI_PER_ASSISTANT_TURN
# Hosting one auction: two minutes of a person checking the listing before
# it goes live (high-value auctions attract fraud), and the winner and
# seller told by SMS. Bids travel over sockets already paid for above.
AUCTION_HOSTED = 2 * SUPPORT_PER_MINUTE + 2 * SMS
# A store for a month, before its listings: about five minutes of support
# (setup questions, orders gone wrong). The storefront page is served from
# the web project's cache inside the Vercel plan above.
STORE_MONTH = 5 * SUPPORT_PER_MINUTE
# Opening a store: reviewing it (10 minutes) and an onboarding call
# (15 minutes).
STORE_SETUP = 25 * SUPPORT_PER_MINUTE


def listing_month_cost(chats_per_month: float) -> float:
    """What one active listing costs BROKA for 30 days, in shillings.

    `chats_per_month` is how many buyers open a negotiation on it - the
    category's demand (categories.py). Push notifications are free; the SMS
    nudge to a seller is a premium feature and costed in the plans.
    """
    ai = AI_PER_NEW_LISTING + chats_per_month * MESSAGES_PER_THREAD * AI_PER_NEGOTIATION_MESSAGE
    return (ai + INFRA_PER_LISTING_MONTH + SUPPORT_PER_LISTING_MONTH) * OVERHEAD


# ── Collecting the money ─────────────────────────────────────────────────────
def mpesa_collection_cost(amount: float) -> float:
    """What Safaricom charges BROKA to receive `amount` through the paybill.

    From the tariff effective 7 August 2026: nothing up to KES 100, KES 3 to
    KES 500, KES 5 to KES 1,000, and no more than KES 54 on any payment.
    Between the published bands it is taken as 0.55% - the Buy Goods rate,
    which is never below the paybill band - so the estimate errs high.
    """
    if amount <= 100:
        return 0.0
    if amount <= 500:
        return 3.0
    if amount <= 1_000:
        return 5.0
    return min(54.0, max(5.0, math.ceil(amount * 0.0055)))
