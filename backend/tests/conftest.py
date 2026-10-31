"""Shared pytest configuration for BROKA tests."""
import os

import pytest

# The suite is the "test" environment, wherever it runs: CI sets ENV=test
# in the workflow, and this setdefault covers every other runner (a dev
# shell almost never exports ENV). Without it the settings load as
# development, the production rate limits apply (3 OTP requests per 5 min
# from one loopback IP across hundreds of tests), and most of the suite
# 429s - surfacing as missing debug_code fields, not as rate limiting.
# An explicitly exported ENV still wins over this default.
os.environ.setdefault("ENV", "test")
# Production runs with IN_APP_PAYMENTS_ENABLED off for now, but the escrow
# machinery it pauses is what most of this suite tests - and what comes back
# when an escrow provider works. Set before any test imports the settings;
# tests of the paused mode (test_payments_off.py) switch it off themselves.
os.environ.setdefault("IN_APP_PAYMENTS_ENABLED", "true")
# Auctions too are off in production for launch, and on here for the suites
# that test them; test_auctions_off.py switches them off itself.
os.environ.setdefault("AUCTIONS_ENABLED", "true")
# The Verified badge and Zeno's unprompted escrow advice are off in
# production for now (2026-10-09) and on here for the suites written for
# them; test_payments_hidden.py switches them off.
os.environ.setdefault("VERIFIED_BADGE_ENABLED", "true")
os.environ.setdefault("ESCROW_GUIDANCE_ENABLED", "true")
# Likewise the listing-fee tests price a seller's first listing at full
# price; free places and the founding offer are tested on their own
# (test_listing_fee_payment.py, test_founding_sellers.py).
os.environ.setdefault("FREE_LISTINGS_PER_SELLER", "0")
os.environ.setdefault("FOUNDING_SELLER_TIERS", "")  # test_founding_sellers.py


def pytest_configure(config):
    """Register asyncio mode."""


# Ensure asyncio works for all tests
pytest_plugins = ["pytest_asyncio"]



@pytest.fixture
def payments_off():
    """IN_APP_PAYMENTS_ENABLED off, as production runs it for now.

    Flipped on the one shared settings object (it is frozen, hence
    object.__setattr__) so every module that reads it sees the change."""
    from api.core.config import settings
    before = settings.in_app_payments_enabled
    object.__setattr__(settings, "in_app_payments_enabled", False)
    yield
    object.__setattr__(settings, "in_app_payments_enabled", before)


@pytest.fixture
def dcr_on():
    """DCR_ENABLED on: the deal completion rate counts and is shown. Off by
    default while buyers pay sellers outside BROKA."""
    from api.core.config import settings
    before = settings.dcr_enabled
    object.__setattr__(settings, "dcr_enabled", True)
    yield
    object.__setattr__(settings, "dcr_enabled", before)


@pytest.fixture
def auctions_off():
    """AUCTIONS_ENABLED off, as production runs it for launch."""
    from api.core.config import settings
    before = settings.auctions_enabled
    object.__setattr__(settings, "auctions_enabled", False)
    yield
    object.__setattr__(settings, "auctions_enabled", before)


@pytest.fixture
def payments_hidden():
    """VERIFIED_BADGE_ENABLED and ESCROW_GUIDANCE_ENABLED off, as production
    runs them while the app hides payments."""
    from api.core.config import settings
    before = (settings.verified_badge_enabled, settings.escrow_guidance_enabled)
    object.__setattr__(settings, "verified_badge_enabled", False)
    object.__setattr__(settings, "escrow_guidance_enabled", False)
    yield
    object.__setattr__(settings, "verified_badge_enabled", before[0])
    object.__setattr__(settings, "escrow_guidance_enabled", before[1])
