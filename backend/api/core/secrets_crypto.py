"""
BROKA — At-Rest Secret Encryption
─────────────────────────────────────────────────────────────────────────────
Small, isolated helper for the one thing this codebase didn't have yet:
reversible encryption of a short-lived operational secret that must later be
read back in cleartext (unlike passwords, which only ever need one-way
hashing — see api/security.py's bcrypt use, which is NOT reusable here).

Currently used for exactly one thing: E-Confirm's `confirmation_code` (the
release credential returned when a marketplace escrow is created — see
api/domains/escrow/providers.py / models/external_escrow.py). Kept generic
("secret" in, "secret" out) rather than named after that one caller, so a
second reversible-secret need later doesn't grow a second ad-hoc
implementation next to this one.

Design:
  • Symmetric encryption via `cryptography`'s Fernet (AES-128-CBC + HMAC,
    authenticated — a tampered/corrupted token fails to decrypt rather than
    silently returning garbage).
  • The Fernet key is derived from the app's existing SECRET_KEY (already
    required, already validated at startup — see core/config.py's
    validate_startup) via PBKDF2-HMAC-SHA256, so this needs no new secret to
    generate, store, or rotate operationally for v1. The salt below is
    fixed and non-secret (salts don't need to be secret, only the derived
    key does) — it exists purely to namespace this derivation from any
    other future use of SECRET_KEY-derived material, not as extra entropy.
  • Deliberately NOT versioned/rotatable yet: if SECRET_KEY is ever
    rotated, any confirmation_code encrypted under the old key becomes
    undecryptable. Acceptable for what this currently protects — a
    confirmation_code is only ever needed for the brief window between an
    escrow being created and its release being confirmed, not a long-lived
    credential — but a real key-rotation scheme (key id alongside the
    ciphertext, try each known key) would be needed before this is reused
    for anything longer-lived.

Never logs, never returns, plaintext or ciphertext in an exception message.
"""
from __future__ import annotations

import base64
import hashlib
import logging
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken

logger = logging.getLogger(__name__)

# Fixed, non-secret namespacing salt — see module docstring. Changing this
# invalidates every previously-encrypted value, same as rotating SECRET_KEY
# would, so treat it the same way: not to be changed casually in place.
_SALT = b"broka:econfirm:confirmation_code:v1"


class SecretCryptoError(Exception):
    """Raised on encrypt/decrypt failure. Never carries plaintext/ciphertext."""


@lru_cache(maxsize=1)
def _fernet() -> Fernet:
    from api.core.config import settings
    if not settings.secret_key or len(settings.secret_key) < 32:
        # Mirrors validate_startup()'s own SECRET_KEY strength check —
        # if that check has already run (main.py's lifespan calls
        # validate_secret_key() before init_db()), this branch is
        # unreachable outside of a narrow test/script that constructs
        # this module without going through normal startup.
        raise SecretCryptoError(
            "Cannot derive an encryption key: SECRET_KEY is missing or too "
            "short. This should have been caught by startup validation."
        )
    derived = hashlib.pbkdf2_hmac(
        "sha256", settings.secret_key.encode("utf-8"), _SALT, iterations=390_000, dklen=32,
    )
    return Fernet(base64.urlsafe_b64encode(derived))


def encrypt_secret(plaintext: str) -> str:
    """Encrypt a short secret string for storage. Returns an opaque token."""
    if not plaintext:
        raise SecretCryptoError("Refusing to encrypt an empty value")
    try:
        return _fernet().encrypt(plaintext.encode("utf-8")).decode("ascii")
    except SecretCryptoError:
        raise
    except Exception as exc:
        # Deliberately no plaintext in this message — see module docstring.
        logger.error("[secrets_crypto] encrypt failed: %s", type(exc).__name__)
        raise SecretCryptoError("Encryption failed") from exc


def decrypt_secret(token: str) -> str:
    """Decrypt a token produced by encrypt_secret(). Raises SecretCryptoError
    if the token is invalid, corrupted, or was encrypted under a different
    SECRET_KEY (e.g. after a key rotation — see module docstring)."""
    if not token:
        raise SecretCryptoError("Refusing to decrypt an empty value")
    try:
        return _fernet().decrypt(token.encode("ascii")).decode("utf-8")
    except InvalidToken as exc:
        logger.error("[secrets_crypto] decrypt failed: invalid/corrupted token")
        raise SecretCryptoError("Could not decrypt value — invalid or corrupted token") from exc
    except SecretCryptoError:
        raise
    except Exception as exc:
        logger.error("[secrets_crypto] decrypt failed: %s", type(exc).__name__)
        raise SecretCryptoError("Decryption failed") from exc
