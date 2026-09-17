"""Shared pytest configuration for BROKA tests."""
import pytest


def pytest_configure(config):
    """Register asyncio mode."""


# Ensure asyncio works for all tests
pytest_plugins = ["pytest_asyncio"]
