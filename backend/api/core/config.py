"""
BROKA v3.0 - Centralised Configuration
• All env vars read here — no os.getenv scattered across routers
• Startup validation added for SECRET_KEY + SQLite-in-production guard (issues #4, #10)
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from functools import lru_cache
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

_INSECURE_SECRETS = {
    "CHANGE_THIS_TO_A_RANDOM_64_CHAR_STRING_IN_PROD",
    "broka-zac-secret-change-in-production",
    "secret", "changeme",
}


def _client_ip_header_default() -> str:
    """CLIENT_IP_HEADER, lowercased; CF-Connecting-IP on Render when unset;
    "" when switched off with "none"."""
    raw = os.getenv("CLIENT_IP_HEADER")
    if raw is None:
        return "cf-connecting-ip" if os.getenv("RENDER", "").lower() == "true" else ""
    raw = raw.strip().lower()
    return "" if raw in ("", "none") else raw


@dataclass(frozen=True)
class Settings:
    # ── App ──────────────────────────────────────────────────────────────────
    app_version: str = "3.0.0"
    env:   str = field(default_factory=lambda: os.getenv("ENV", os.getenv("ENVIRONMENT", "development")).lower())
    debug: bool = field(default_factory=lambda: os.getenv("DEBUG", "false").lower() == "true")

    # ── Database ──────────────────────────────────────────────────────────────
    database_url: str = field(default_factory=lambda: os.getenv(
        "DATABASE_URL", "sqlite+aiosqlite:///./broka.db"
    ))

    # ── Auth ─────────────────────────────────────────────────────────────────
    secret_key: str = field(default_factory=lambda: os.getenv(
        "SECRET_KEY", "CHANGE_THIS_TO_A_RANDOM_64_CHAR_STRING_IN_PROD"
    ))
    algorithm: str = "HS256"
    access_token_expire_minutes: int = field(default_factory=lambda: int(
        os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "15")   # 15 min — was 10080 (7 days)
    ))
    refresh_token_expire_days: int = field(default_factory=lambda: int(
        os.getenv("REFRESH_TOKEN_EXPIRE_DAYS", "30")
    ))

    # ── AI Providers ──────────────────────────────────────────────────────────
    gemini_api_key: str = field(default_factory=lambda: os.getenv("GEMINI_API_KEY", ""))
    groq_api_key: str = field(default_factory=lambda: os.getenv("GROQ_API_KEY", ""))
    gemini_model: str = "gemini-2.0-flash"
    groq_model: str = "llama-3.3-70b-versatile"
    # OpenRouter — TESTING (2026-08): stands in for Groq, whose
    # llama-3.3-70b-versatile model Groq decommissioned on 2026-08-16.
    # Model is env-overridable so the Broka-specific eval (Nemotron 3 Ultra
    # vs GPT-OSS-20B vs Gemma 4 26B A4B) can swap it without a redeploy.
    openrouter_api_key: str = field(default_factory=lambda: os.getenv("OPENROUTER_API_KEY", ""))
    openrouter_model: str = field(default_factory=lambda: os.getenv(
        "OPENROUTER_MODEL", "nvidia/nemotron-3-ultra-550b-a55b:free"
    ))

    # DeepSeek V4 Flash — DIRECT API (not via OpenRouter). Sits between
    # Gemini and OpenRouter/Nemotron in the fallback chain (see
    # ai_broker/service.py and routers/negotiate.py) specifically to
    # evaluate whether it beats the current Nemotron path on latency.
    # Skipped entirely (falls through to OpenRouter) if the key is unset -
    # never a hard startup dependency.
    deepseek_api_key: str = field(default_factory=lambda: os.getenv("DEEPSEEK_API_KEY", ""))
    deepseek_model: str = field(default_factory=lambda: os.getenv(
        "DEEPSEEK_MODEL", "deepseek-flash"
    ))
    deepseek_base_url: str = field(default_factory=lambda: os.getenv(
        "DEEPSEEK_BASE_URL", "https://api.deepseek.com"
    ))
    # Deliberately shorter than the other providers' 25-30s timeouts - the
    # point of trying DeepSeek here is conversational latency, so a slow
    # DeepSeek response should fail fast onto Nemotron rather than make the
    # user wait as long as the existing providers already do.
    deepseek_timeout_seconds: float = field(default_factory=lambda: float(
        os.getenv("DEEPSEEK_TIMEOUT_SECONDS", "15")
    ))

    # ── fal.ai (AI Showcase/Cover Image) ────────────────────────────────────
    # Separate from the AI Providers above on purpose - those are for the
    # negotiation broker (text), this is image generation, and the spec
    # this was built against is explicit that it must be fal.ai specifically
    # (not Gemini/OpenAI/Stability direct) and never reach the Flutter
    # client. See api/domains/showcase/service.py.
    fal_key: str = field(default_factory=lambda: os.getenv("FAL_KEY", ""))
    # fal-ai/flux-pro/kontext: "change X while keeping everything else the
    # same" is its whole design goal, which lines up with the
    # product-preservation requirement better than a generic strength-based
    # img2img model. Overridable without a redeploy in case a better-suited
    # model shows up later.
    fal_showcase_model: str = field(default_factory=lambda: os.getenv(
        "FAL_SHOWCASE_MODEL", "fal-ai/flux-pro/kontext"
    ))
    # Whether AI covers are premium is PREMIUM_ENABLED's business now (the
    # premium domain), not a flag of the showcase's own - it replaced
    # SHOWCASE_AI_REQUIRE_PREMIUM.

    # ── M-Pesa ────────────────────────────────────────────────────────────────
    mpesa_env: str = field(default_factory=lambda: os.getenv("MPESA_ENV", "sandbox"))
    mpesa_consumer_key: str = field(default_factory=lambda: os.getenv("MPESA_CONSUMER_KEY", ""))
    mpesa_consumer_secret: str = field(default_factory=lambda: os.getenv("MPESA_CONSUMER_SECRET", ""))
    mpesa_shortcode: str = field(default_factory=lambda: os.getenv("MPESA_SHORTCODE", "174379"))
    mpesa_passkey: str = field(default_factory=lambda: os.getenv("MPESA_PASSKEY", ""))
    mpesa_callback_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_CALLBACK_URL", "https://api.broka.co.ke/mpesa/callback"
    ))
    mpesa_verify_callback_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_VERIFY_CALLBACK_URL", "https://api.broka.co.ke/verify/callback"
    ))
    mpesa_featured_callback_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_FEATURED_CALLBACK_URL", "https://api.broka.co.ke/featured/callback"
    ))
    mpesa_b2c_initiator: str = field(default_factory=lambda: os.getenv("MPESA_B2C_INITIATOR", ""))
    mpesa_b2c_credential: str = field(default_factory=lambda: os.getenv("MPESA_B2C_CREDENTIAL", ""))
    mpesa_b2c_timeout_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_B2C_TIMEOUT_URL", "https://api.broka.co.ke/mpesa/b2c/timeout"
    ))
    mpesa_b2c_result_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_B2C_RESULT_URL", "https://api.broka.co.ke/mpesa/b2c/result"
    ))

    # ── E-Confirm API v2 (marketplace escrow — replaces direct-Daraja deal
    # payment/release for new deals; Daraja above is untouched and still
    # used for featured/verification payments and legacy B2C refunds) ──────
    econfirm_api_key: str = field(default_factory=lambda: os.getenv("ECONFIRM_API_KEY", ""))
    econfirm_base_url: str = field(default_factory=lambda: os.getenv(
        "ECONFIRM_BASE_URL", "https://api.econfirm.co.ke/api/2"
    ))
    econfirm_timeout_seconds: float = field(default_factory=lambda: float(
        os.getenv("ECONFIRM_TIMEOUT_SECONDS", "20")
    ))
    econfirm_poll_interval_seconds: float = field(default_factory=lambda: float(
        os.getenv("ECONFIRM_POLL_INTERVAL_SECONDS", "4")
    ))
    econfirm_max_poll_seconds: float = field(default_factory=lambda: float(
        os.getenv("ECONFIRM_MAX_POLL_SECONDS", "180")
    ))

    # ── ZetuPay (money users pay BROKA: listing fees, plans, boosts, badges) ──
    # Never deal money: buyer-to-seller payments stay on E-Confirm above.
    # Off, those charges keep using Daraja (core/mpesa_stk.py) as before.
    # The Secret Key is server-only - it authenticates BROKA's calls and is
    # what ZetuPay signs its webhooks with; repr=False keeps it out of any
    # log line or traceback that prints the settings object.
    zetupay_enabled: bool = field(default_factory=lambda: os.getenv(
        "ZETUPAY_ENABLED", "false"
    ).strip().lower() in ("1", "true", "yes", "on"))
    zetupay_base_url: str = field(default_factory=lambda: os.getenv(
        "ZETUPAY_BASE_URL", "https://pay.zetupay.co.ke/api/v1"
    ).strip().rstrip("/"))
    zetupay_secret_key: str = field(repr=False, default_factory=lambda: os.getenv(
        "ZETUPAY_SECRET_KEY", ""
    ).strip())
    zetupay_timeout_seconds: float = field(default_factory=lambda: float(
        os.getenv("ZETUPAY_TIMEOUT_SECONDS", "20")
    ))

    # ── SMS (phone OTP + nudges) ─────────────────────────────────────────────
    # Two providers are supported behind api.core.sms.get_sms_provider();
    # Mobitech takes priority when configured, Africa's Talking is the
    # fallback, and ConsoleSMS (log-only) is the last resort in dev/CI.
    # See api/core/sms.py for the selection logic.
    mobitech_api_key: str = field(default_factory=lambda: os.getenv("MOBITECH_API_KEY", ""))
    mobitech_sender_name: str = field(default_factory=lambda: os.getenv("MOBITECH_SENDER_NAME", ""))
    mobitech_base_url: str = field(default_factory=lambda: os.getenv(
        "MOBITECH_BASE_URL", "https://textapi.mobitechtechnologies.com"
    ))
    # 2026-08-31: split out from mobitech_base_url on purpose. The prod
    # incident this fixes was MOBITECH_BASE_URL itself getting set to
    # ".../sms/sendsms" in Render (path baked into what's supposed to be
    # just a domain) while api/core/sms.py separately appended another
    # "/sms/sendmultiple" - producing the literal broken URL
    # ".../sms/sendsms/sms/sendmultiple". Keeping the endpoint path in
    # its own variable, joined explicitly in sms.py, makes that specific
    # failure mode structurally harder to reintroduce - and see
    # validate_startup() below for a loud check that catches it anyway
    # if MOBITECH_BASE_URL ever again ends up containing a path.
    # /sms/sendsms is the endpoint empirically confirmed working for this
    # account (a manual request returned status_code 1000) - not
    # /sms/sendmultiple, which this shipped with briefly and turned out
    # to be the wrong endpoint for this account/credentials.
    mobitech_send_endpoint: str = field(default_factory=lambda: os.getenv(
        "MOBITECH_SEND_ENDPOINT", "/sms/sendsms"
    ))
    at_username: str = field(default_factory=lambda: os.getenv("AT_USERNAME", ""))
    at_api_key: str = field(default_factory=lambda: os.getenv("AT_API_KEY", ""))
    at_sender_id: str = field(default_factory=lambda: os.getenv("AT_SENDER_ID", ""))
    otp_length: int = field(default_factory=lambda: int(os.getenv("OTP_LENGTH", "6")))
    otp_expiry_seconds: int = field(default_factory=lambda: int(os.getenv("OTP_EXPIRY_SECONDS", "300")))
    otp_max_attempts: int = field(default_factory=lambda: int(os.getenv("OTP_MAX_ATTEMPTS", "5")))
    # Signed phone-verify token (issued after OTP success, presented to
    # /auth/register so registration doesn't need to re-check the OTP row).
    phone_verify_token_expire_minutes: int = field(default_factory=lambda: int(
        os.getenv("PHONE_VERIFY_TOKEN_EXPIRE_MINUTES", "15")
    ))

    # ── Cloudflare Realtime TURN (VoIP calling — audio/video call relay) ──────
    # STUN needs no credentials; TURN relay credentials are short-lived and
    # generated per-call via CLOUDFLARE_TURN_API_TOKEN (server-side only -
    # see api/core/cloudflare_turn_client.py and GET /calls/turn-credentials).
    # Replaces the previous hardcoded third-party (Metered) TURN credential
    # that used to live directly in Flutter's WebRtcService.
    # ── APNs (iOS PushKit VoIP pushes for incoming calls) ────────────────
    # Separate from Firebase: FCM cannot address the PushKit `voip` topic,
    # which is the only push type that wakes a terminated iOS app for a
    # call. Unset -> iOS calls still work while the app is foregrounded
    # (the poller finds them), they just can't ring a killed app.
    apns_auth_key:    str = ""   # contents of the .p8 key file
    apns_key_id:      str = ""
    apns_team_id:     str = ""
    apns_bundle_id:   str = "com.broka.app"
    apns_use_production: bool = False

    @property
    def apns_configured(self) -> bool:
        return bool(self.apns_auth_key and self.apns_key_id and self.apns_team_id)

    cloudflare_turn_key_id: str = field(default_factory=lambda: os.getenv("CLOUDFLARE_TURN_KEY_ID", ""))
    cloudflare_turn_api_token: str = field(default_factory=lambda: os.getenv("CLOUDFLARE_TURN_API_TOKEN", ""))
    # Not used by the credential-generation call itself - kept here only in
    # case a future administrative Cloudflare call needs it.
    cloudflare_account_id: str = field(default_factory=lambda: os.getenv("CLOUDFLARE_ACCOUNT_ID", ""))

    # Short-lived, call-scoped token presented on the WebSocket signaling
    # connection (GET /calls/ws/{room_id}?token=...) instead of the normal
    # long-lived access token - see api/security.py's create_call_token()/
    # decode_call_token() and api/routers/calls.py. Deliberately much
    # shorter than phone_verify_token_expire_minutes above: this token only
    # needs to outlive establishing one call's WS connection, not a whole
    # registration flow.
    call_token_expire_minutes: int = field(default_factory=lambda: int(
        os.getenv("CALL_TOKEN_EXPIRE_MINUTES", "5")
    ))

    # ── Security ──────────────────────────────────────────────────────────────
    zac_secret: str = field(default_factory=lambda: os.getenv(
        "ZAC_SECRET", "broka-zac-secret-change-in-production"
    ))
    # Shared across mpesa.py/verify.py/featured.py's callback routes - see
    # their CALLBACK_SECRET comments. Required in production (checked in
    # validate_startup below) so the unauthenticated fallback path on all
    # three can never be live in a real deployment.
    mpesa_callback_secret: str = field(default_factory=lambda: os.getenv("MPESA_CALLBACK_SECRET", ""))
    admin_bootstrap_email: str = field(default_factory=lambda: os.getenv(
        "ADMIN_BOOTSTRAP_EMAIL", ""
    ).strip().lower())

    # ── Email (Resend — email OTP delivery) ──────────────────────────────────
    # RESEND_FROM must be on a domain verified in the Resend dashboard;
    # Resend refuses a send from anything else. Both must be set before
    # get_email_provider() will pick Resend over the console fallback.
    resend_api_key: str = field(default_factory=lambda: os.getenv("RESEND_API_KEY", "").strip())
    resend_from: str = field(default_factory=lambda: os.getenv(
        "RESEND_FROM", "BROKA <noreply@broka.app>"
    ).strip())
    resend_reply_to: str = field(default_factory=lambda: os.getenv("RESEND_REPLY_TO", "").strip())

    @property
    def email_enabled(self) -> bool:
        return bool(self.resend_api_key and self.resend_from)

    # ── Image storage (Cloudflare R2) ────────────────────────────────────────
    # Listing, store and avatar images are processed into WebP sizes and
    # stored as objects, served from MEDIA_PUBLIC_BASE_URL (the bucket's
    # public custom domain or its r2.dev URL). With any of the four R2
    # values unset, images go to the database instead (media_blobs, served
    # by GET /media/i/...) - fine for dev and tests, not for production
    # traffic. See api/core/media_storage.py.
    r2_account_id: str = field(default_factory=lambda: os.getenv("R2_ACCOUNT_ID", "").strip())
    r2_access_key_id: str = field(default_factory=lambda: os.getenv("R2_ACCESS_KEY_ID", "").strip())
    r2_secret_access_key: str = field(default_factory=lambda: os.getenv("R2_SECRET_ACCESS_KEY", "").strip())
    r2_bucket: str = field(default_factory=lambda: os.getenv("R2_BUCKET", "").strip())
    media_public_base_url: str = field(default_factory=lambda: os.getenv(
        "MEDIA_PUBLIC_BASE_URL", "").strip().rstrip("/"))
    # This API's own public address, e.g. https://api.broka.co.ke.
    # Only used to make database-stored image URLs absolute, which the web
    # storefront and link previews need. Unset, those URLs are relative
    # ("/media/i/...") and the app resolves them against its API base.
    public_api_base_url: str = field(default_factory=lambda: os.getenv(
        "PUBLIC_API_BASE_URL", "").strip().rstrip("/"))
    # Where a store's shareable link points: {STORE_LINK_BASE}/{link name}.
    # Every link is on broka.co.ke from the first store on, so links on
    # flyers and in bios never change; broka.co.ke/store/* is served by the
    # web storefront (STORES_PLAN.md, phase 3). Overridable for staging.
    store_link_base: str = field(default_factory=lambda: os.getenv(
        "STORE_LINK_BASE", "https://broka.co.ke/store").strip().rstrip("/"))

    # ── Client addresses (api/core/client_ip.py) ──────────────────────────────
    # Every per-IP rate limit (login, signup, OTP) and every audit IP depends
    # on knowing who is really calling. Behind Render the TCP peer is one of
    # Render's own proxies, shared by every user - Render sits behind
    # Cloudflare, which puts the caller's address in CF-Connecting-IP.
    #
    # CLIENT_IP_HEADER: a header the edge proxy sets and callers can't
    #   forge. Defaults to CF-Connecting-IP on Render (Render sets RENDER=true
    #   in every service), otherwise unset. "none" turns it off.
    # TRUSTED_PROXY_HOPS: for other hosts, how many proxies append to
    #   X-Forwarded-For in front of this service; the caller is that many
    #   entries from the right. 0 (default) = use the TCP peer.
    # STOREFRONT_API_KEY: shared with the web storefront (web/, Vercel),
    #   which forwards store visits and shares from its own servers. With
    #   the key it may say which visitor it is acting for
    #   (X-Broka-Client-IP); without the key that header is ignored. Set the
    #   same random value (32+ characters) here and in the web project.
    client_ip_header: str = field(default_factory=lambda: _client_ip_header_default())
    trusted_proxy_hops: int = field(default_factory=lambda: max(0, int(os.getenv("TRUSTED_PROXY_HOPS", "0") or 0)))
    storefront_api_key: str = field(default_factory=lambda: os.getenv("STOREFRONT_API_KEY", "").strip())

    # Largest request body accepted at all, in MB (api/core/body_limit.py).
    # Above the biggest legitimate upload: 25 MB of audio for transcription.
    max_request_body_mb: int = field(default_factory=lambda: max(1, int(os.getenv("MAX_REQUEST_BODY_MB", "32") or 32)))

    # ── Rust extension (backend/native, api/core/native.py) ──────────────────
    # BROKA_NATIVE: "auto" (default) uses the broka_native extension when it
    #   is installed and was built from this checkout, else the Python
    #   reference code - same results, slower, and on Python's backtracking
    #   regex engine. "required" refuses to start without it; the Docker image
    #   sets that, so a deploy can't lose the extension without anyone
    #   noticing. "off" never loads it: the kill switch if it misbehaves.
    #   Anything else refuses to start (validate_startup).
    native_mode: str = field(default_factory=lambda: os.getenv("BROKA_NATIVE", "auto").strip().lower() or "auto")

    # ── Redis (for rate-limiting, pub/sub, and distributed workers) ───────────
    redis_url: str = field(default_factory=lambda: os.getenv("REDIS_URL", ""))

    # ── Observability ─────────────────────────────────────────────────────────
    sentry_dsn: str = field(default_factory=lambda: os.getenv("SENTRY_DSN", ""))

    # ── CORS ──────────────────────────────────────────────────────────────────
    allowed_origins_raw: str = field(default_factory=lambda: os.getenv("ALLOWED_ORIGINS", "*").strip())

    # ── Rate Limiting ─────────────────────────────────────────────────────────
    rate_limit_login_per_minute: int = 5
    rate_limit_message_per_minute: int = 30
    rate_limit_offer_per_minute: int = 10
    rate_limit_dispute_per_hour: int = 3

    # ── Commission ────────────────────────────────────────────────────────────
    # BROKA's share of a sale, added to what the buyer pays. The escrow
    # provider (E-Confirm) charges its own 1% on top, quoted by E-Confirm
    # itself - escrow_provider_fee_rate is only for showing buyers the total:
    # 3.49% + 1% = 4.49% on a negotiated deal, 4% + 1% = 5% on an auction.
    # See PRICING.md. A deal keeps the rate it was agreed at (Deal.commission).
    commission_rate: float = 0.0349
    auction_commission_rate: float = 0.04
    escrow_provider_fee_rate: float = 0.01
    # BROKA's share is never less than this, in KES. A deal costs BROKA about
    # KES 13 to carry (Zeno's negotiation, a share of disputes, texts), so
    # 3.49% on an item under ~KES 440 would be carried at a loss once VAT is
    # taken out. Only items under ~KES 573 are affected.
    commission_minimum_kes: float = 20.0

    # ── Listing fees (PRICING.md) ─────────────────────────────────────────────
    # Off until the app build with the Listing fee screen is the one sellers
    # have. On, a new listing stays hidden from buyers until its fee is paid
    # - so an older build, which cannot pay, would post listings nobody can
    # see. Listings created while this is off are never charged.
    listing_fees_enabled: bool = field(default_factory=lambda: os.getenv(
        "LISTING_FEES_ENABLED", "false"
    ).strip().lower() in ("1", "true", "yes", "on"))
    # Where Safaricom posts the result of a listing-fee STK push. Unset, it is
    # derived from MPESA_CALLBACK_SECRET (pricing/payments.py), the same way
    # mpesa.py derives its own - so the secret-protected route is the default.
    mpesa_listing_fee_callback_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_LISTING_FEE_CALLBACK_URL", ""
    ).strip())

    # ── Premium plans (PRICING.md) ────────────────────────────────────────────
    # Off: voice mode, Zeno's SMS, the Buying Agent, AI covers and hosting
    # auctions stay free for everyone, as they are today, and plans cannot be
    # bought. On: they need a plan (AI covers: two free tries first) and plans
    # are sold. Same rule as listing fees - only once the app build with the
    # Premium screen is the one users must have, or an older build hits a
    # wall it has no way past.
    premium_enabled: bool = field(default_factory=lambda: os.getenv(
        "PREMIUM_ENABLED", "false"
    ).strip().lower() in ("1", "true", "yes", "on"))
    # Where Safaricom posts a plan payment's result. Unset, derived from
    # MPESA_CALLBACK_SECRET (premium/payments.py).
    mpesa_premium_callback_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_PREMIUM_CALLBACK_URL", ""
    ).strip())

    # ── Fraud thresholds ──────────────────────────────────────────────────────
    fraud_new_account_days: int = 7
    fraud_rapid_tx_window_hours: int = 24
    fraud_rapid_tx_threshold: int = 10
    fraud_dispute_rate_threshold: float = 0.3

    # ── Marketplace redesign (Design Journal Volume 6, Appendix C) ─────────────
    # per-buyer cap on standing Buy-Agent requests (Ch.8, Ch.22 — do not
    # relax below 1; HOMESCREEN_VARIANT is a Flutter-only compile-time flag
    # read via --dart-define, not a backend setting, so it has no entry here)
    buy_agent_max_active: int = field(default_factory=lambda: int(os.getenv("BUY_AGENT_MAX_ACTIVE", "1")))
    # How long a standing watch runs before it ends by itself. Without an
    # end, a watch outlived the buyer's interest: a year-old request with
    # negotiation authorised kept messaging sellers for someone who had long
    # since bought elsewhere. Changing a watch starts its time again. At
    # least 1 - see buy_agent/service.py watch_days().
    buy_agent_watch_days: int = field(default_factory=lambda: int(os.getenv("BUY_AGENT_WATCH_DAYS", "30")))

    # ── Auctions ──────────────────────────────────────────────────────────────
    # How long the winner has to pay before the win lapses. Configurable
    # because it is a commercial policy, not a technical constant - a
    # high-value vehicle auction may want longer than a phone.
    auction_payment_deadline_hours: int = field(
        default_factory=lambda: int(os.getenv("AUCTION_PAYMENT_DEADLINE_HOURS", "24"))
    )
    # How long after a winner STARTS paying before an unfunded attempt is
    # treated as abandoned rather than in flight. An M-Pesa STK prompt dies
    # on the handset within a couple of minutes; this is deliberately far
    # longer so a slow provider callback or reconciliation still lands
    # before the sweep decides anything. Until it passes - and until the
    # provider has been asked and answered "not funded" - a payment-lapse
    # never cancels the deal. See lifecycle.lapse_unpaid_win.
    auction_funding_settle_minutes: int = field(
        default_factory=lambda: int(os.getenv("AUCTION_FUNDING_SETTLE_MINUTES", "30"))
    )
    # Fallback minimum bid increment when an auction does not set its own.
    # Matches AuctionMeta.min_bid_increment's column default.
    auction_default_min_increment: float = field(
        default_factory=lambda: float(os.getenv("AUCTION_DEFAULT_MIN_INCREMENT", "500"))
    )
    # How close to the end an auction counts as "ending soon" for the
    # one-off reminder to bidders and watchers.
    auction_ending_soon_minutes: int = field(
        default_factory=lambda: int(os.getenv("AUCTION_ENDING_SOON_MINUTES", "15"))
    )
    # How long an auction runs when the seller does not say. The sell
    # wizard does not currently collect an end time at all (it collects a
    # reserve and nothing else auction-specific), so without a default,
    # every auction created through the app would have no closing time -
    # and an auction that can never close cannot take bids. Three days is
    # long enough to attract bidders and short enough that a seller is not
    # surprised by it.
    auction_default_duration_hours: int = field(
        default_factory=lambda: int(os.getenv("AUCTION_DEFAULT_DURATION_HOURS", "72"))
    )

    # ── Derived ───────────────────────────────────────────────────────────────

    @property
    def is_production(self) -> bool:
        return self.env in ("production", "prod", "staging")

    @property
    def is_test(self) -> bool:
        return self.env in ("test", "testing", "ci")

    @property
    def mpesa_base_url(self) -> str:
        return (
            "https://api.safaricom.co.ke"
            if self.mpesa_env == "production"
            else "https://sandbox.safaricom.co.ke"
        )

    @property
    def allowed_origins(self) -> list[str]:
        if self.allowed_origins_raw == "*" or not self.allowed_origins_raw:
            return ["*"]
        return [o.strip() for o in self.allowed_origins_raw.split(",") if o.strip()]

    @property
    def allow_credentials(self) -> bool:
        return self.allowed_origins_raw not in ("*", "")

    @property
    def redis_enabled(self) -> bool:
        return bool(self.redis_url)

    @property
    def r2_configured(self) -> bool:
        return bool(
            self.r2_account_id and self.r2_access_key_id and self.r2_secret_access_key
            and self.r2_bucket and self.media_public_base_url
        )

    @property
    def cloudflare_turn_configured(self) -> bool:
        return bool(self.cloudflare_turn_key_id and self.cloudflare_turn_api_token)


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


settings = get_settings()


# ── Startup validation ────────────────────────────────────────────────────────

def validate_startup() -> None:
    """
    Called once during the FastAPI lifespan startup hook.
    Enforces security and environment sanity rules:
      1. Refuses insecure secret keys in production (issue #4)
      2. Refuses SQLite in production (issue #10)
      3. Warns about any insecure defaults in development
    """
    s = settings

    # ── Check SECRET_KEY ─────────────────────────────────────────────────────
    if s.secret_key in _INSECURE_SECRETS or len(s.secret_key) < 32:
        msg = (
            "SECRET_KEY is insecure (default or < 32 chars). "
            "Generate one: python -c \"import secrets; print(secrets.token_hex(32))\""
        )
        if s.is_production:
            raise RuntimeError(f"FATAL: {msg}")
        logger.warning("[startup] ⚠  %s", msg)

    # ── Check ZAC_SECRET ─────────────────────────────────────────────────────
    if s.zac_secret in _INSECURE_SECRETS:
        msg = "ZAC_SECRET is still the default placeholder — set ZAC_SECRET env var"
        if s.is_production:
            raise RuntimeError(f"FATAL: {msg}")
        logger.warning("[startup] ⚠  %s", msg)

    # ── Check MPESA_CALLBACK_SECRET ───────────────────────────────────────────
    # Without this, mpesa.py/verify.py/featured.py's unauthenticated fallback
    # callback routes stay live and accept forged {"ResultCode": 0, ...}
    # payloads with no real M-Pesa payment behind them - a deal could be
    # marked paid, a user verified, or a listing boosted for free by anyone
    # who can guess or observe a CheckoutRequestID. See each router's
    # CALLBACK_SECRET comment for the full history.
    if s.is_production and not s.mpesa_callback_secret:
        raise RuntimeError(
            "FATAL: MPESA_CALLBACK_SECRET is not set. In production this "
            "leaves the M-Pesa/verification/boost callback endpoints "
            "unauthenticated - anyone can forge a payment-succeeded webhook. "
            "Generate one: python -c \"import secrets; print(secrets.token_hex(24))\" "
            "then set it as MPESA_CALLBACK_SECRET and update the callback "
            "URLs registered with Safaricom to /mpesa/callback/<secret>, "
            "/verify/callback/<secret>, and /featured/callback/<secret>."
        )

    # ── Check ECONFIRM_API_KEY ─────────────────────────────────────────────────
    # Marketplace escrow funding/release for every new deal goes through
    # E-Confirm now (see api/core/econfirm_client.py) - without this key in
    # production, no buyer could ever fund an escrow and no seller could
    # ever be paid out. Not required in dev/test: EConfirmClient raises a
    # clear, controlled error per-call if a request is attempted without a
    # key configured, which is enough for local work and CI (Phase 21 tests
    # mock the provider entirely, they never need a real key).
    if s.is_production and not s.econfirm_api_key:
        raise RuntimeError(
            "FATAL: ECONFIRM_API_KEY is not set. In production this means "
            "no marketplace deal can be funded or released via E-Confirm. "
            "Set ECONFIRM_API_KEY from the E-Confirm developer portal."
        )
    logger.info(
        "[startup] E-Confirm %s configured",
        "is" if s.econfirm_api_key else "is NOT",
    )

    # ── Check ZetuPay ──────────────────────────────────────────────────────────
    # Switched on without its key, every listing fee, plan and boost fails
    # at the prompt, and no webhook's signature can be checked.
    from api.core.zetupay import CONTRACT_VERIFIED
    zetupay_live = s.zetupay_enabled and CONTRACT_VERIFIED
    if s.zetupay_enabled and not CONTRACT_VERIFIED:
        # Logged, not fatal, and checked first: the flag does nothing yet,
        # and refusing to start over it would take deals down too.
        logger.error(
            "[startup] ZETUPAY_ENABLED is set, but core/zetupay.py's API contract "
            "is not verified - BROKA's charges stay on Daraja until it is."
        )
    if zetupay_live:
        if not s.zetupay_secret_key and s.is_production:
            raise RuntimeError(
                "FATAL: ZETUPAY_ENABLED is true but ZETUPAY_SECRET_KEY is not set. "
                "Set it, or set ZETUPAY_ENABLED=false to collect BROKA's own "
                "charges through Daraja as before."
            )
        if not s.zetupay_secret_key:
            logger.warning("[startup] ZetuPay is on without ZETUPAY_SECRET_KEY")
        if s.is_production and not s.zetupay_base_url.startswith("https://"):
            raise RuntimeError("FATAL: ZETUPAY_BASE_URL must be https.")
        if s.zetupay_secret_key and not s.zetupay_secret_key.startswith("sk_live_"):
            # ZetuPay signs every webhook with the wallet's LIVE key, even
            # for payments made with a test key: with any other key here no
            # webhook verifies, and payments land only through the status
            # poll and the sweep.
            logger.error("[startup] ZETUPAY_SECRET_KEY is not the live (sk_live_) key - "
                         "ZetuPay's webhook signatures will not verify")
    logger.info("[startup] ZetuPay is %s", "ON" if zetupay_live else "off")

    # ── Refuse SQLite in production (issue #10) ───────────────────────────────
    if s.is_production and "sqlite" in s.database_url:
        raise RuntimeError(
            "FATAL: DATABASE_URL is set to SQLite in a production environment. "
            "Set DATABASE_URL to a PostgreSQL connection string."
        )

    # ── Warn if Redis not configured in production ────────────────────────────
    if s.is_production and not s.redis_enabled:
        logger.warning(
            "[startup] ⚠  REDIS_URL not set — rate limiting, WebSocket scaling, "
            "and distributed workers will use in-process fallbacks. "
            "Set REDIS_URL for production-grade operation."
        )

    # ── Warn if Sentry not configured in production ───────────────────────────
    if s.is_production and not s.sentry_dsn:
        logger.warning(
            "[startup] ⚠  SENTRY_DSN not set — no error tracking in production."
        )

    # ── Warn if no SMS provider is configured in production ───────────────────
    _has_mobitech = bool(s.mobitech_api_key and s.mobitech_sender_name)
    _has_at       = bool(s.at_username and s.at_api_key)
    if s.is_production and not (_has_mobitech or _has_at):
        logger.warning(
            "[startup] ⚠  No SMS provider configured (MOBITECH_API_KEY/"
            "MOBITECH_SENDER_NAME or AT_USERNAME/AT_API_KEY) — phone OTPs "
            "and SMS nudges will FAIL (never logged, never sent). Phone "
            "verification is unavailable until one of these is set."
        )

    # ── Warn if FAL_KEY not configured ─────────────────────────────────────────
    # Lower severity than the SMS/SECRET_KEY checks above - AI showcase
    # generation is an optional, skippable step in listing creation
    # (sellers can upload a gallery cover or skip it entirely), so a
    # missing key degrades one feature rather than blocking registration.
    if not s.fal_key:
        logger.warning(
            "[startup] ⚠  FAL_KEY not set — AI showcase image generation "
            "will return a clear error instead of calling fal.ai. Gallery "
            "covers and skipping the showcase step are unaffected."
        )

    # ── Warn if image storage is not on R2 ─────────────────────────────────────
    # Not fatal: images still work from the database. But every image then
    # rides in the database and is served by this process, which is what
    # the move to R2 exists to stop.
    if s.is_production and not s.r2_configured:
        logger.warning(
            "[startup] ⚠  R2_ACCOUNT_ID/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/"
            "R2_BUCKET/MEDIA_PUBLIC_BASE_URL not all set — images are stored in "
            "the database and served by the API instead of from Cloudflare R2."
        )

    # ── Warn if Cloudflare TURN not configured ─────────────────────────────────
    # Lower severity than the SECRET_KEY/MPESA_CALLBACK_SECRET checks above -
    # calls still work wherever direct P2P ICE connectivity succeeds; only
    # relay-required calls (common on carrier-grade NAT, frequent on Kenyan
    # mobile data) degrade. See api/core/cloudflare_turn_client.py and
    # GET /calls/turn-credentials.
    if s.is_production and not s.cloudflare_turn_configured:
        logger.warning(
            "[startup] ⚠  CLOUDFLARE_TURN_KEY_ID/CLOUDFLARE_TURN_API_TOKEN not "
            "set — calls will fall back to direct P2P (STUN) only; any call "
            "that needs a TURN relay will fail to connect audio/video."
        )

    # ── Warn if MOBITECH_BASE_URL already contains a path ──────────────────────
    # Exactly the misconfiguration that broke OTP sending in production on
    # 2026-08-30: MOBITECH_BASE_URL was set to ".../sms/sendsms" instead of
    # just the domain, and sms.py separately appended another endpoint
    # path on top of it. Checked here (not just fixed in code) so the
    # NEXT time someone fat-fingers this env var, it's a loud, specific
    # warning at startup instead of a silent broken-URL failure on every
    # OTP request. Deliberately general (any non-empty path, not just one
    # that happens to match the current endpoint) rather than only
    # catching this one exact past mistake.
    _mobitech_url_path = urlparse(s.mobitech_base_url).path
    if _mobitech_url_path and _mobitech_url_path != "/":
        logger.warning(
            "[startup] ⚠  MOBITECH_BASE_URL (%r) appears to include a path "
            "(%r) — it should be just the bare domain (e.g. "
            "https://textapi.mobitechtechnologies.com). The endpoint path "
            "comes from MOBITECH_SEND_ENDPOINT (%r) instead, joined "
            "explicitly in api/core/sms.py.",
            s.mobitech_base_url, _mobitech_url_path, s.mobitech_send_endpoint,
        )

    # ── Warn if CORS is wide open in production ───────────────────────────────
    # Lower severity than it would be for a cookie-authenticated app - this
    # backend has no cookie-based auth anywhere (confirmed: no set_cookie or
    # request.cookies use in the whole codebase), only Bearer tokens attached
    # explicitly by the calling client, so a wildcard origin can't be ridden
    # by a victim's browser the way it could with cookie sessions. Still
    # worth tightening (defense-in-depth, and this only takes one future
    # cookie-based admin panel to change the calculus) - warning, not a
    # hard fail, since the actual exploitability today is limited.
    if s.is_production and not s.email_enabled:
        # Not fatal: email is optional at signup, so registration still
        # completes without it. But email verification requests will fail
        # with 503 (ConsoleEmail refuses in production rather than logging
        # codes), which is worth saying out loud at boot.
        logger.warning(
            "[startup] ⚠  RESEND_API_KEY/RESEND_FROM not set — email "
            "verification is unavailable (requests return 503)."
        )

    if s.storefront_api_key and len(s.storefront_api_key) < 32:
        # The key lets its holder choose the client address every per-IP
        # limit sees. A short one is guessable, so it is refused outright.
        msg = "STOREFRONT_API_KEY is shorter than 32 characters."
        if s.is_production:
            raise RuntimeError(f"FATAL: {msg}")
        logger.warning("[startup] ⚠  %s", msg)
    if s.is_production and not s.storefront_api_key:
        logger.warning(
            "[startup] ⚠  STOREFRONT_API_KEY not set — the web storefront's "
            "visit and share counts are rate-limited by Vercel's addresses, "
            "shared between all web visitors. Set the same value here and in "
            "the web project."
        )
    if s.is_production and not s.client_ip_header and not s.trusted_proxy_hops:
        logger.warning(
            "[startup] ⚠  Neither CLIENT_IP_HEADER nor TRUSTED_PROXY_HOPS is "
            "set: per-IP rate limits key on the TCP peer. Behind a proxy that "
            "is the proxy, shared by every user. Check GET "
            "/admin/diagnostics/client-ip."
        )

    # Imported here, not at the top: api.core.native reads `settings`.
    from api.core import native
    if s.native_mode not in native.MODES:
        # A typo in the kill switch must not quietly mean "auto".
        raise RuntimeError(
            f"FATAL: BROKA_NATIVE={s.native_mode!r} - use one of {', '.join(native.MODES)}."
        )
    if s.native_mode == "required" and not native.AVAILABLE:
        raise RuntimeError(
            f"FATAL: BROKA_NATIVE=required but the Rust extension is unusable: "
            f"{native.REASON}. Rebuild it (pip install ./native from backend/) "
            f"or set BROKA_NATIVE=off to run on the Python fallback."
        )
    if native.AVAILABLE:
        logger.info("[startup] ✓ Rust extension active: %s", native.REASON)
    else:
        logger.warning("[startup] ⚠  Rust extension not in use (%s) — running the "
                       "Python fallback.", native.REASON)

    if s.is_production and s.allowed_origins_raw in ("*", ""):
        logger.warning(
            "[startup] ⚠  ALLOWED_ORIGINS is unset or \"*\" in production — "
            "set it to your actual web/admin origins (comma-separated) once "
            "any browser-based client exists for this API."
        )

    logger.info(
        "[startup] ✓ Config validated  env=%s  db=%s  redis=%s  sentry=%s",
        s.env,
        "postgres" if "postgres" in s.database_url else "sqlite",
        "yes" if s.redis_enabled else "no",
        "yes" if s.sentry_dsn else "no",
    )
