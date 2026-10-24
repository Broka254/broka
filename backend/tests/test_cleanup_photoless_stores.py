"""cleanup_photoless_stores.py must only ever target physical shops.

A physical shop needs a photograph of itself (StoreService.create_store);
a virtual store has no premises to photograph and opens without one. The
one-off clean-up that removes pre-rule photo-less shops must therefore
never classify a virtual store as a photo-less physical shop - doing so
would delete exactly the online-only businesses the store type exists
for.
"""
import json
import uuid
from datetime import datetime

import pytest
import pytest_asyncio
from sqlalchemy import select

import cleanup_photoless_stores as cleanup
from api.database import (
    AccountType, AsyncSessionLocal, AuditLog, Listing, ListingStatus, SellerTier,
    User, init_db, reset_engine,
)
from api.models.store import Store


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_photoless_cleanup.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


async def _owner() -> User:
    user = User(
        name="Photo Cleanup Seller", phone=f"+2547{uuid.uuid4().hex[:8]}",
        password_hash="x", account_type=AccountType.buyer_seller,
        seller_tier=SellerTier.long_term,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def _store(owner: User, **fields) -> Store:
    store = Store(
        owner_id=owner.id,
        name=fields.pop("name", f"Cleanup Shop {uuid.uuid4().hex[:8]}"),
        slug=fields.pop("slug", f"cleanup-{uuid.uuid4().hex[:10]}"),
        **fields,
    )
    async with AsyncSessionLocal() as db:
        db.add(store)
        await db.commit()
        await db.refresh(store)
    return store


async def _photo_less_ids() -> set[str]:
    async with AsyncSessionLocal() as db:
        return {s.id for s in await cleanup.photo_less(db)}


@pytest.mark.asyncio
class TestPhotoLessClassification:
    async def test_an_online_only_store_without_shop_photographs_is_preserved(self):
        owner = await _owner()
        virtual = await _store(
            owner, store_type="virtual", photos=None, photo_ids=None,
            service_areas=json.dumps(["Nationwide"]),
        )
        assert cleanup.has_shop_photo(virtual) is False
        assert virtual.id not in await _photo_less_ids()

    async def test_a_physical_store_without_premises_photographs_is_still_identified(self):
        owner = await _owner()
        physical = await _store(owner, store_type="physical", county="Nairobi")
        # A logo is not a photo of the shop, exactly as on create.
        only_logo = await _store(owner, store_type="physical", logo_id="asset-logo")
        found = await _photo_less_ids()
        assert physical.id in found
        assert only_logo.id in found

    async def test_a_physical_store_with_a_shop_photo_is_not_eligible(self):
        owner = await _owner()
        legacy = await _store(
            owner, store_type="physical",
            photos=json.dumps(["data:image/png;base64,iVBORw0KGgo="]),
        )
        asset = await _store(owner, store_type="physical", photo_ids='["asset-1"]')
        found = await _photo_less_ids()
        assert legacy.id not in found
        assert asset.id not in found

    async def test_a_deleted_physical_store_is_not_reported_again(self):
        owner = await _owner()
        gone = await _store(
            owner, store_type="physical", deleted_at=datetime.utcnow(),
        )
        assert gone.id not in await _photo_less_ids()

    async def test_removing_an_eligible_physical_store_still_soft_deletes_and_archives(self):
        owner = await _owner()
        physical = await _store(owner, store_type="physical", county="Kisumu")
        listing_id = str(uuid.uuid4())
        async with AsyncSessionLocal() as db:
            db.add(Listing(
                id=listing_id, seller_id=owner.id, store_id=physical.id,
                name="Cleanup Listing", category="Electronics", price=1000,
                lat=-0.09, lng=34.77, status=ListingStatus.active,
            ))
            await db.commit()

        async with AsyncSessionLocal() as db:
            store = await db.get(Store, physical.id)
            assert await cleanup.remove(db, store, apply=False) is True
            assert store.deleted_at is None
            await cleanup.remove(db, store, apply=True)

        async with AsyncSessionLocal() as db:
            store = await db.get(Store, physical.id)
            listing = await db.get(Listing, listing_id)
            audit = (await db.execute(
                select(AuditLog).where(
                    AuditLog.action == "store_deleted_no_photo",
                    AuditLog.resource_id == physical.id,
                )
            )).scalars().first()
        assert store.deleted_at is not None and store.is_active is False
        assert listing.status == ListingStatus.cancelled
        assert audit is not None
