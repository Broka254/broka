"""Shared pytest configuration for BROKA tests."""
import os

import pytest

# Production runs with IN_APP_PAYMENTS_ENABLED off for now, but the escrow
# machinery it pauses is what most of this suite tests - and what comes back
# when an escrow provider works. Set before any test imports the settings;
# tests of the paused mode (test_payments_off.py) switch it off themselves.
os.environ.setdefault("IN_APP_PAYMENTS_ENABLED", "true")
# Auctions too are off in production for launch, and on here for the suites
# that test them; test_auctions_off.py switches them off itself.
os.environ.setdefault("AUCTIONS_ENABLED", "true")
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
def auctions_off():
    """AUCTIONS_ENABLED off, as production runs it for launch."""
    from api.core.config import settings
    before = settings.auctions_enabled
    object.__setattr__(settings, "auctions_enabled", False)
    yield
    object.__setattr__(settings, "auctions_enabled", before)
