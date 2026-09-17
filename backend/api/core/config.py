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
    # Debugging/testing phase (2026-08-29): AI showcase generation is NOT
    # gated behind is_premium yet, per explicit instruction - everyone can
    # try it while the feature is being shaken out. The full check
    # (ownership + this flag) already runs in showcase/service.py, so
    # turning real premium enforcement on later is just flipping this to
    # true - no further code change needed.
    showcase_ai_require_premium: bool = field(default_factory=lambda: os.getenv(
        "SHOWCASE_AI_REQUIRE_PREMIUM", "false"
    ).strip().lower() in ("1", "true", "yes", "on"))

    # ── M-Pesa ────────────────────────────────────────────────────────────────
    mpesa_env: str = field(default_factory=lambda: os.getenv("MPESA_ENV", "sandbox"))
    mpesa_consumer_key: str = field(default_factory=lambda: os.getenv("MPESA_CONSUMER_KEY", ""))
    mpesa_consumer_secret: str = field(default_factory=lambda: os.getenv("MPESA_CONSUMER_SECRET", ""))
    mpesa_shortcode: str = field(default_factory=lambda: os.getenv("MPESA_SHORTCODE", "174379"))
    mpesa_passkey: str = field(default_factory=lambda: os.getenv("MPESA_PASSKEY", ""))
    mpesa_callback_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_CALLBACK_URL", "https://broka-dbjd.onrender.com/mpesa/callback"
    ))
    mpesa_verify_callback_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_VERIFY_CALLBACK_URL", "https://broka-dbjd.onrender.com/verify/callback"
    ))
    mpesa_featured_callback_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_FEATURED_CALLBACK_URL", "https://broka-dbjd.onrender.com/featured/callback"
    ))
    mpesa_b2c_initiator: str = field(default_factory=lambda: os.getenv("MPESA_B2C_INITIATOR", ""))
    mpesa_b2c_credential: str = field(default_factory=lambda: os.getenv("MPESA_B2C_CREDENTIAL", ""))
    mpesa_b2c_timeout_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_B2C_TIMEOUT_URL", "https://broka-dbjd.onrender.com/mpesa/b2c/timeout"
    ))
    mpesa_b2c_result_url: str = field(default_factory=lambda: os.getenv(
        "MPESA_B2C_RESULT_URL", "https://broka-dbjd.onrender.com/mpesa/b2c/result"
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
    commission_rate: float = 0.03

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
            "and SMS nudges will be logged instead of actually sent. No new "
            "user can complete registration until one of these is set."
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
