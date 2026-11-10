"""Founder intelligence and reports: the figures, the advice and the archive.

One small marketplace is seeded per module, with every timestamp placed
relative to "now", so each figure below can be worked out by hand:

    seller1 (20d old)   L7 Fashion   -16d   never contacted (stale)
                        L1 Electronics -10d  buyer1 at -9d, seller1 answers 30m later
                        L2 Electronics -9d   only the admin messaged it
    seller2 (12d old)   L3 Fashion    -8d   buyer1 interest at -12h (too late: day 7.5)
                        L5 Fashion    -1d   buyer2 at -30h, no answer (waiting)
                        L6 Fashion    -2d   buyer1 at -2h, seller2 answers at -1h
    admin               L4 Electronics -10d  a buyer message (staff: excluded)
    buyer1              Buying Agent request "Phones", nothing matched
    deal                L1 seller1/buyer1 agreed at -8d

The current 7-day window is [now-7d, now), the previous [now-14d, now-7d).
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core import admin_reports
from api.core.insights import build_insights
from api.database import (
    AccountType, AsyncSessionLocal, BuyAgentRequest, Deal, DealStatus, Interest, Listing,
    NegotiationMessage, User, init_db, reset_engine,
)
from api.models.admin_alert import AdminAlert
from api.models.admin_report import AdminReport
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_intelligence_{uuid.uuid4().hex}.db"
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


def _h(user_id: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user_id})}"}


@pytest_asyncio.fixture(scope="module")
async def market():
    now = datetime.utcnow()
    tag = uuid.uuid4().hex[:8]

    def user(name, *, days_old, admin=False, seller=False):
        return User(
            name=name, phone=f"+2547{uuid.uuid4().hex[:8]}", email=f"{uuid.uuid4().hex[:8]}@intel.test",
            password_hash="x", is_admin=admin, created_at=now - timedelta(days=days_old),
            account_type=AccountType.buyer_seller if seller else AccountType.buyer,
        )

    admin = user(f"Admin {tag}", days_old=1, admin=True)
    seller1 = user(f"Asha {tag}", days_old=20, seller=True)
    seller2 = user(f"Baraka {tag}", days_old=12, seller=True)
    buyer1 = user(f"Chebet {tag}", days_old=2)
    buyer2 = user(f"Daudi {tag}", days_old=9)
    async with AsyncSessionLocal() as db:
        db.add_all([admin, seller1, seller2, buyer1, buyer2])
        await db.flush()

        def listing(seller, name, category, county, days_ago):
            return Listing(
                seller_id=seller.id, name=name, category=category, location_county=county,
                price=1000.0, lat=-1.29, lng=36.82, created_at=now - timedelta(days=days_ago),
            )

        l1 = listing(seller1, "Phone X", "Electronics", "Nairobi", 10)
        l2 = listing(seller1, "Laptop Y", "Electronics", "Nairobi", 9)
        l3 = listing(seller2, "Dress A", "Fashion", "Mombasa", 8)
        l4 = listing(admin, "Staff test", "Electronics", "Nairobi", 10)
        l5 = listing(seller2, "Shoes B", "Fashion", "Mombasa", 1)
        l6 = listing(seller2, "Bag C", "Fashion", "Mombasa", 2)
        l7 = listing(seller1, "Jacket D", "Fashion", "Nairobi", 16)
        db.add_all([l1, l2, l3, l4, l5, l6, l7])
        await db.flush()

        def message(listing_, sender, role, buyer, at):
            return NegotiationMessage(
                listing_id=listing_.id, sender_id=sender.id, role=role,
                recipient_role="seller" if role == "buyer" else "buyer",
                content="hi", buyer_id=buyer.id, created_at=at,
            )

        db.add_all([
            message(l1, buyer1, "buyer", buyer1, now - timedelta(days=9)),
            message(l1, seller1, "seller", buyer1, now - timedelta(days=9) + timedelta(minutes=30)),
            message(l2, admin, "buyer", admin, now - timedelta(days=8)),
            message(l4, buyer1, "buyer", buyer1, now - timedelta(days=9)),
            message(l5, buyer2, "buyer", buyer2, now - timedelta(hours=30)),
            message(l6, buyer1, "buyer", buyer1, now - timedelta(hours=2)),
            message(l6, seller2, "seller", buyer1, now - timedelta(hours=1)),
            Interest(listing_id=l3.id, buyer_id=buyer1.id, created_at=now - timedelta(hours=12)),
            BuyAgentRequest(buyer_id=buyer1.id, category="Phones", max_price=30000.0,
                            match_count=0, status="active", created_at=now - timedelta(days=1)),
            Deal(listing_id=l1.id, seller_id=seller1.id, buyer_id=buyer1.id, agreed_price=1000.0,
                 commission=0.0, status=DealStatus.agreed, created_at=now - timedelta(days=8)),
        ])
        await db.commit()
        ids = {name: obj.id for name, obj in {
            "admin": admin, "seller1": seller1, "seller2": seller2, "buyer1": buyer1,
            "buyer2": buyer2, "l5": l5, "l7": l7,
        }.items()}
    return ids


@pytest.mark.asyncio
async def test_pulse_counts_the_week_against_the_one_before(client, market):
    r = await client.get("/admin/intelligence/pulse?window_days=7", headers=_h(market["admin"]))
    assert r.status_code == 200, r.text
    body = r.json()
    m = body["metrics"]
    # Staff (the admin, L4 and the admin's message on L2) never count.
    assert m["new_listings"]["current"] == 2 and m["new_listings"]["previous"] == 3
    assert m["new_sellers"]["current"] == 0 and m["new_sellers"]["previous"] == 1
    assert m["new_users"]["current"] == 1  # buyer1; the admin is staff
    assert m["live_listings"]["current"] == 6
    assert m["active_buyers"]["current"] == 2 and m["active_buyers"]["previous"] == 1
    assert m["active_sellers"]["current"] == 1 and m["active_sellers"]["previous"] == 2
    assert m["conversations_started"]["current"] == 2 and m["conversations_started"]["previous"] == 1
    assert m["messages"]["current"] == 3 and m["messages"]["previous"] == 2
    assert m["deals_agreed"]["previous"] == 1
    assert m["buy_agent_unmet_open"]["current"] == 1

    # Liquidity: L1, L2 and L3 finished their first week in this window and
    # only L1 heard from a buyer inside it (L3's interest came on day 7.5).
    liquidity = body["liquidity"]["current"]
    assert (liquidity["eligible"], liquidity["with_buyer_contact"]) == (3, 1)
    assert liquidity["rate_pct"] == 33.3
    assert body["liquidity"]["previous"]["eligible"] == 1  # L7
    assert body["liquidity"]["previous"]["rate_pct"] == 0.0

    # Replies: buyer2's 30-hour-old message is the one eligible thread this
    # week and nobody answered; buyer1's 2-hour-old one is not eligible yet.
    current = body["seller_response"]["current"]
    assert (current["eligible"], current["replied_24h"], current["rate_pct"]) == (1, 0, 0.0)
    previous = body["seller_response"]["previous"]
    assert (previous["eligible"], previous["replied_24h"]) == (1, 1)
    assert previous["median_reply_minutes"] == 30.0

    assert [t["key"] for t in body["targets"]] == [
        "live_listings", "paying_customers_30d", "collected_30d_minor", "deals_agreed_30d"]
    assert body["targets"][0]["actual"] == 6
    assert body["break_even"]["fixed_monthly_cost_minor"] == 77_300
    assert body["staff_excluded"] is True


@pytest.mark.asyncio
async def test_categories_weigh_demand_against_supply(client, market):
    r = await client.get("/admin/intelligence/categories?window_days=30", headers=_h(market["admin"]))
    assert r.status_code == 200, r.text
    by_key = {c["key"]: c for c in r.json()["categories"]}
    electronics, fashion, phones = by_key["electronics"], by_key["fashion"], by_key["phones"]
    assert (electronics["supply_live"], electronics["buyer_threads"], electronics["demand"]) == (2, 1, 1)
    assert electronics["liquidity"]["rate_pct"] == 50.0
    assert electronics["signal"] == "healthy"
    assert (fashion["supply_live"], fashion["buyer_threads"], fashion["interests"]) == (4, 2, 1)
    assert fashion["demand"] == 3
    assert (phones["supply_live"], phones["buy_agent_requests"], phones["buy_agent_unmatched"]) == (0, 1, 1)
    assert phones["signal"] == "unserved"


@pytest.mark.asyncio
async def test_geography_groups_by_county(client, market):
    r = await client.get("/admin/intelligence/geography", headers=_h(market["admin"]))
    assert r.status_code == 200, r.text
    by_key = {c["key"]: c for c in r.json()["counties"]}
    assert by_key["nairobi"]["supply_live"] == 3  # L1, L2, L7 - not the admin's L4
    assert by_key["mombasa"]["supply_live"] == 3
    assert by_key["mombasa"]["buyer_threads"] == 2


@pytest.mark.asyncio
async def test_sellers_shows_waiting_buyers_and_stale_listings(client, market):
    r = await client.get("/admin/intelligence/sellers", headers=_h(market["admin"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["waiting_total"] == 1
    [waiting] = body["waiting"]
    assert waiting["seller_id"] == market["seller2"]
    assert waiting["items"] == ["Shoes B"]
    assert waiting["oldest_wait_hours"] >= 29
    assert body["stale_total"] == 1
    assert [s["id"] for s in body["stale_listings"]] == [market["l7"]]


@pytest.mark.asyncio
async def test_funnel_follows_signups_through_both_journeys(client, market):
    now = datetime.utcnow()
    r = await client.get(
        "/admin/intelligence/funnel",
        params={"from": (now - timedelta(days=30)).isoformat() + "Z", "to": now.isoformat() + "Z"},
        headers=_h(market["admin"]),
    )
    assert r.status_code == 200, r.text
    body = r.json()
    seller = {s["key"]: s["count"] for s in body["seller_journey"]}
    buyer = {s["key"]: s["count"] for s in body["buyer_journey"]}
    assert seller == {"signed_up": 4, "became_seller": 2, "posted_listing": 2,
                      "got_buyer_contact": 2, "agreed_deal": 1}
    assert buyer == {"signed_up": 4, "engaged": 2, "messaged_seller": 2, "agreed_deal": 1}
    assert body["seller_journey"][1]["pct_of_start"] == 50.0
    bad = await client.get("/admin/intelligence/funnel?from=nonsense", headers=_h(market["admin"]))
    assert bad.status_code == 422


@pytest.mark.asyncio
async def test_cohorts_have_one_row_per_week(client, market):
    r = await client.get("/admin/intelligence/cohorts?weeks=4", headers=_h(market["admin"]))
    assert r.status_code == 200, r.text
    rows = r.json()["cohorts"]
    assert len(rows) == 4
    # Week 0 starts 21-28 days ago, so all four non-staff users are inside.
    assert sum(row["size"] for row in rows) == 4
    assert [len(row["retention_pct"]) for row in rows] == [4, 3, 2, 1]
    for row in rows:
        assert all(v is None or 0 <= v <= 100 for v in row["retention_pct"])


@pytest.mark.asyncio
async def test_insights_endpoint_points_at_what_to_do(client, market):
    r = await client.get("/admin/intelligence/insights", headers=_h(market["admin"]))
    assert r.status_code == 200, r.text
    body = r.json()
    ids = [i["id"] for i in body["insights"]]
    assert "buyers_waiting" in ids
    assert "undersupplied:phones" in ids
    assert "buy_agent_unmet" in ids
    severities = [i["severity"] for i in body["insights"]]
    order = ["critical", "warning", "opportunity", "info", "positive"]
    assert severities == sorted(severities, key=order.index)
    assert sum(body["counts"].values()) == len(body["insights"])


@pytest.mark.asyncio
async def test_intelligence_is_admin_only(client, market):
    for path in ("pulse", "insights", "categories", "geography", "funnel", "cohorts", "sellers"):
        r = await client.get(f"/admin/intelligence/{path}", headers=_h(market["buyer1"]))
        assert r.status_code == 403, path
    assert (await client.get("/admin/reports", headers=_h(market["buyer1"]))).status_code == 403


# ── Reports ──────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_generate_list_read_and_regenerate_a_report(client, market):
    h = _h(market["admin"])
    first = await client.post("/admin/reports/generate", json={"kind": "weekly"}, headers=h)
    assert first.status_code == 200, first.text
    report = first.json()
    assert report["stored"] is True and report["kind"] == "weekly"
    assert report["payload"]["period"]["in_progress"] is False
    assert report["markdown"].startswith("# Weekly brief")
    assert "## Key numbers" in report["markdown"]
    assert {k["key"] for k in report["payload"]["kpis"]} >= {"liquidity_pct", "new_listings"}

    again = await client.post("/admin/reports/generate", json={"kind": "weekly"}, headers=h)
    assert again.json()["id"] == report["id"]  # rebuilt in place, not duplicated

    listed = await client.get("/admin/reports?kind=weekly", headers=h)
    assert listed.status_code == 200
    assert listed.json()["total"] == 1
    assert listed.json()["items"][0]["id"] == report["id"]

    one = await client.get(f"/admin/reports/{report['id']}", headers=h)
    assert one.status_code == 200 and one.json()["title"] == report["title"]
    assert (await client.get("/admin/reports/nope", headers=h)).status_code == 404

    bad = await client.post("/admin/reports/generate", json={"kind": "yearly"}, headers=h)
    assert bad.status_code == 422
    unfinished = await client.post(
        "/admin/reports/generate",
        json={"kind": "monthly", "period_date": (datetime.utcnow() + timedelta(hours=3)).strftime("%Y-%m-%d")},
        headers=h)
    assert unfinished.status_code == 422


@pytest.mark.asyncio
async def test_preview_is_computed_not_stored(client, market):
    h = _h(market["admin"])
    async with AsyncSessionLocal() as db:
        before = len((await db.execute(select(AdminReport.id))).all())
    r = await client.get("/admin/reports/preview?kind=daily", headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["stored"] is False and r.json()["id"] is None
    assert r.json()["payload"]["period"]["in_progress"] is True
    async with AsyncSessionLocal() as db:
        after = len((await db.execute(select(AdminReport.id))).all())
    assert after == before


@pytest.mark.asyncio
async def test_the_sweep_writes_each_closed_period_once_and_announces_it(market):
    now = datetime.utcnow()
    created = await admin_reports.generate_due_reports(now=now)
    again = await admin_reports.generate_due_reports(now=now)
    assert again == []
    async with AsyncSessionLocal() as db:
        kinds = sorted(k for (k,) in (await db.execute(select(AdminReport.kind))).all())
        alerts = (await db.execute(
            select(AdminAlert).where(AdminAlert.kind == "report_ready"))).scalars().all()
    assert kinds == ["daily", "monthly", "weekly"]
    # The weekly report already existed (generated by an admin above), so
    # this sweep created the daily and monthly ones and announced the monthly.
    assert len(created) == 2
    assert [a.meta["report_id"] for a in alerts] != []
    assert all(a.href.startswith("/reports?id=") for a in alerts)


def test_periods_are_local_days_weeks_and_months():
    now = datetime(2026, 11, 11, 10, 0)  # Wednesday, 13:00 in Nairobi
    week = admin_reports.period_bounds("weekly", now=now, which="previous")
    assert week == (datetime(2026, 11, 1, 21, 0), datetime(2026, 11, 8, 21, 0))
    assert admin_reports.period_label("weekly", *week) == "2–8 Nov 2026"
    month = admin_reports.period_bounds("monthly", now=now, which="previous")
    assert month == (datetime(2026, 9, 30, 21, 0), datetime(2026, 10, 31, 21, 0))
    assert admin_reports.period_label("monthly", *month) == "October 2026"
    day = admin_reports.period_bounds("daily", now=now, which="previous")
    assert day == (datetime(2026, 11, 9, 21, 0), datetime(2026, 11, 10, 21, 0))
    assert admin_reports.period_label("daily", *day) == "Tue 10 Nov 2026"
    current = admin_reports.period_bounds("weekly", now=now, which="current")
    assert current[0] == week[1] and current[1] > now


# ── Insight rules (pure) ─────────────────────────────────────────────────────

def _pulse(**overrides) -> dict:
    def metric(current, previous=None, change=None):
        return {"current": current, "previous": previous, "change_pct": change}

    pulse = {
        "window": {"days": 7.0},
        "metrics": {
            "new_listings": metric(10, 10, 0.0), "new_users": metric(10, 10, 0.0),
            "buy_agent_unmet_open": metric(0), "fraud_flags": metric(0, 0),
            "disputes_opened": metric(0, 0), "income_minor": metric(0, 0),
        },
        "liquidity": {"current": {"rate_pct": 60.0, "eligible": 10, "with_buyer_contact": 6},
                      "previous": {"rate_pct": 50.0}},
        "seller_response": {"current": {"rate_pct": 80.0, "eligible": 10, "replied_24h": 8}},
        "balance": {"active_buyers": 10, "active_sellers": 5},
        "complaints": {"sla_breached": 0, "repeat_reported_users": []},
        "break_even": {"fixed_monthly_cost_minor": 77_300, "coverage_pct": 10.0,
                       "gap_minor": 70_000, "net_30d_minor": 7_300},
        "monetisation": {"listing_fees_enabled": True},
        "targets": [],
    }
    for key, value in overrides.items():
        pulse[key] = value
    return pulse


def test_low_liquidity_and_overdue_complaints_come_first():
    pulse = _pulse(
        liquidity={"current": {"rate_pct": 20.0, "eligible": 10, "with_buyer_contact": 2},
                   "previous": {"rate_pct": 40.0}},
        complaints={"sla_breached": 2, "sla_breached_urgent": 1, "repeat_reported_users": []},
    )
    insights = build_insights(pulse=pulse)
    assert [i["id"] for i in insights[:2]] == ["complaints_sla", "liquidity"]
    assert insights[1]["severity"] == "critical"  # under half the 50% bar
    assert insights[1]["action"]["href"] == "/intelligence"


def test_healthy_liquidity_is_reported_as_good_news():
    insights = build_insights(pulse=_pulse())
    liquidity = next(i for i in insights if i["id"] == "liquidity")
    assert liquidity["severity"] == "positive"


def test_a_listing_drop_past_the_rollback_line_is_a_warning():
    metrics = _pulse()["metrics"]
    metrics["new_listings"] = {"current": 4, "previous": 10, "change_pct": -60.0}
    insights = build_insights(pulse=_pulse(metrics=metrics))
    drop = next(i for i in insights if i["id"] == "listings_drop")
    assert drop["severity"] == "warning" and "60%" in drop["title"]


def test_too_few_buyers_for_the_sellers_is_flagged():
    insights = build_insights(pulse=_pulse(balance={"active_buyers": 2, "active_sellers": 9}))
    assert any(i["id"] == "buyer_shortage" for i in insights)


def test_small_numbers_do_not_make_trends():
    metrics = _pulse()["metrics"]
    metrics["new_listings"] = {"current": 0, "previous": 2, "change_pct": -100.0}
    pulse = _pulse(metrics=metrics, liquidity={
        "current": {"rate_pct": 0.0, "eligible": 2, "with_buyer_contact": 0}, "previous": {"rate_pct": None}})
    ids = [i["id"] for i in build_insights(pulse=pulse)]
    assert "listings_drop" not in ids and "liquidity" not in ids
