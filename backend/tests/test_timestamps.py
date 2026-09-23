"""Client timestamps are stored as naive UTC - converted, never just stripped.

PATCH /auctions/{id}/terms used to 500 on any timestamp with an offset
("...Z" included, which is what the Flutter app sends), and the listing
parsers dropped an offset without converting, storing 18:00+03:00 as 18:00
UTC. See api/core/timeutil.py.
"""
import uuid
from datetime import datetime, timedelta, timezone

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core.timeutil import parse_iso_to_naive_utc, to_naive_utc
from api.database import (
    AsyncSessionLocal, AuctionMeta, Listing, ListingStatus, ListingType, User,
    init_db, reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_timestamps.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


EAT = timezone(timedelta(hours=3))  # Nairobi


class TestConversion:
    def test_an_offset_is_converted_before_it_is_dropped(self):
        assert to_naive_utc(datetime(2026, 10, 1, 18, 0, tzinfo=EAT)) == datetime(2026, 10, 1, 15, 0)

    def test_naive_is_already_utc(self):
        naive = datetime(2026, 10, 1, 18, 0)
        assert to_naive_utc(naive) is naive

    @pytest.mark.parametrize("text,expected", [
        ("2026-10-01T15:00:00Z", datetime(2026, 10, 1, 15, 0)),
        ("2026-10-01T15:00:00.000Z", datetime(2026, 10, 1, 15, 0)),
        ("2026-10-01T18:00:00+03:00", datetime(2026, 10, 1, 15, 0)),
        ("2026-10-01T15:00:00", datetime(2026, 10, 1, 15, 0)),
    ])
    def test_parse(self, text, expected):
        assert parse_iso_to_naive_utc(text) == expected

    def test_garbage_raises(self):
        with pytest.raises(ValueError):
            parse_iso_to_naive_utc("next tuesday")


class TestListingAuctionTerms:
    def test_creation_converts_an_offset_to_utc(self):
        from api.domains.listings.service import resolve_auction_terms
        start = datetime.utcnow() + timedelta(days=1)
        end = start + timedelta(days=2)
        terms = resolve_auction_terms({
            "auction_starts_at": start.replace(tzinfo=timezone.utc).astimezone(EAT).isoformat(),
            "auction_ends_at": end.replace(tzinfo=timezone.utc).astimezone(EAT).isoformat(),
        }, price=20000, auction_date=None)
        assert terms["starts_at"] == start
        assert terms["ends_at"] == end
        assert terms["starts_at"].tzinfo is None

    def test_an_aware_datetime_object_is_converted_too(self):
        from api.domains.listings.service import resolve_auction_terms
        end = (datetime.utcnow() + timedelta(days=2)).replace(microsecond=0)
        terms = resolve_auction_terms(
            {"auction_ends_at": end.replace(tzinfo=timezone.utc).astimezone(EAT)},
            price=20000, auction_date=None,
        )
        assert terms["ends_at"] == end


async def _upcoming_auction() -> tuple[str, str]:
    seller = User(name="S", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(seller)
        await db.commit()
        now = datetime.utcnow()
        listing = Listing(
            seller_id=seller.id, name="Watch", category="Electronics", price=20000,
            lat=-1.29, lng=36.82, listing_type=ListingType.auction, status=ListingStatus.active,
        )
        db.add(listing)
        await db.commit()
        db.add(AuctionMeta(
            listing_id=listing.id, status="upcoming", min_bid_increment=500,
            starting_price=20000, starts_at=now + timedelta(hours=1),
            ends_at=now + timedelta(hours=5), bid_count=0,
        ))
        await db.commit()
        return listing.id, seller.id


async def _meta(listing_id: str) -> AuctionMeta:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
        )).scalar_one()


class TestAuctionTermsPatch:
    @pytest.mark.asyncio
    async def test_utc_z_end_time_alone(self, client):
        listing_id, seller_id = await _upcoming_auction()
        new_end = (datetime.utcnow() + timedelta(hours=10)).replace(microsecond=0)
        r = await client.patch(
            f"/auctions/{listing_id}/terms",
            json={"ends_at": new_end.isoformat() + "Z"},
            headers={"Authorization": f"Bearer {create_access_token({'sub': seller_id})}"},
        )
        assert r.status_code == 200, r.text
        assert (await _meta(listing_id)).ends_at == new_end

    @pytest.mark.asyncio
    async def test_offset_window_is_stored_as_the_same_instant_in_utc(self, client):
        listing_id, seller_id = await _upcoming_auction()
        start = (datetime.utcnow() + timedelta(hours=2)).replace(microsecond=0)
        end = start + timedelta(hours=6)
        r = await client.patch(
            f"/auctions/{listing_id}/terms",
            json={
                "starts_at": start.replace(tzinfo=timezone.utc).astimezone(EAT).isoformat(),
                "ends_at": end.replace(tzinfo=timezone.utc).astimezone(EAT).isoformat(),
            },
            headers={"Authorization": f"Bearer {create_access_token({'sub': seller_id})}"},
        )
        assert r.status_code == 200, r.text
        meta = await _meta(listing_id)
        assert meta.starts_at == start
        assert meta.ends_at == end

    @pytest.mark.asyncio
    async def test_an_offset_window_that_ends_before_it_starts_is_still_rejected(self, client):
        listing_id, seller_id = await _upcoming_auction()
        start = datetime.utcnow() + timedelta(hours=4)
        # 05:00+03:00 of the same instant minus an hour -> earlier in UTC.
        end_local = (start - timedelta(hours=1)).replace(tzinfo=timezone.utc).astimezone(EAT)
        r = await client.patch(
            f"/auctions/{listing_id}/terms",
            json={"starts_at": start.isoformat() + "Z", "ends_at": end_local.isoformat()},
            headers={"Authorization": f"Bearer {create_access_token({'sub': seller_id})}"},
        )
        assert r.status_code == 422
