"""Contact-leak scanning (api/core/text_guard.py) and where its findings go.

Every behaviour test runs against both engines - the Python reference and,
when the extension is installed, the Rust one - so neither can drift from
what is written here. tests/test_native_parity.py compares the two on
generated text; this file says what the right answer is.
"""
import itertools

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core import native, text_guard
from api.core.fraud import detect_off_platform_solicitation
from api.core.text_guard import ContactFinding
from api.database import AsyncSessionLocal, AuditLog, Listing, NegotiationMessage, User, init_db, reset_engine
from api.security import create_access_token
from main import app


class _Rust:
    """The extension, with the Python engine's interface."""

    def scan(self, text):
        return [ContactFinding(*f) for f in native.module.scan_contact_leaks(text)]

    def normalize(self, text):
        return native.module.normalize_text(text)


@pytest.fixture(params=["python", "rust"])
def engine(request):
    if request.param == "python":
        return text_guard.python_engine()
    if native.module is None:
        pytest.skip(f"Rust extension not in use: {native.REASON}")
    return _Rust()


def _kinds(engine, text):
    return text_guard.kinds_of(engine.scan(text))


# ── What the old detector caught still counts ────────────────────────────────
# The five patterns fraud.py used to hold. Anything they matched, the new
# scanner must too: they are what the leak signal was calibrated on.
LEGACY_POSITIVES = [
    "0712345678",
    "reach me: 0112345678.",
    "WhatsApp",
    "whats app",
    "what sapp",
    "whatapp me",
    "Call me",
    "please CALL ME tomorrow",
    "send cash direct",
    "send money direct",
    "pay me directly",
    "pay me outside",
]


@pytest.mark.parametrize("text", LEGACY_POSITIVES)
def test_everything_the_old_patterns_caught_is_still_caught(engine, text):
    assert engine.scan(text), text


# ── Disguises ─────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("text", [
    "0712 345 678",
    "0712-345-678",
    "0712.345.678",
    "(0712) 345 678",
    "+254 712 345 678",
    "254712345678",
    "+254 (0) 712 345 678",
    "0 7 1 2 3 4 5 6 7 8",
    "zero seven one two three four five six seven eight",
    "sifuri saba moja mbili tatu nne tano sita saba nane",
    "zero seven one two 345 678",
    "zero seven double one 345 678",
    "O7l2345678",                          # letter O and lower-case L
    "０７１２３４５６７８",   # fullwidth
    "07​12​345​678",        # zero-width spaces
    "٠٧١٢٣٤٥٦٧٨",   # Arabic-Indic
    "0712\U0001F4DE345678",                # an emoji in the middle
    "\U0001D7CE\U0001D7D5\U0001D7CF\U0001D7D0 345 678",              # maths digits
])
def test_disguised_phone_numbers_are_found(engine, text):
    assert "phone" in _kinds(engine, text), engine.normalize(text)


@pytest.mark.parametrize("text", [
    "whаtsapp",                       # Cyrillic a
    "WHΑTSAPP",                       # Greek capital alpha
    "whats‍app",                      # zero-width joiner
    "wh@ts@pp",
    "w4tsapp",
    "Ｗｈａｔｓａｐｐ",   # fullwidth
    "wa.me/254712345678",
    "t.me/sellerke",
    "telegram",
])
def test_disguised_messaging_apps_are_found(engine, text):
    assert "messaging_app" in _kinds(engine, text), engine.normalize(text)


@pytest.mark.parametrize("text,kind", [
    ("jo.doe+ads@example.co.ke.", "email"),
    ("JO@GMAIL.COM", "email"),
    ("jo at gmail dot com", "email"),
    ("jo (at) yahoo (dot) com", "email"),
    ("till no. 123456", "payment_redirect"),
    ("Paybill 247247 account 1234", "payment_redirect"),
    ("lipa na m-pesa", "payment_redirect"),
    ("send it to my mpesa", "payment_redirect"),
    ("tuma pesa moja kwa moja", "payment_redirect"),
    ("can we skip escrow", "payment_redirect"),
    ("nipigie kesho", "contact_request"),
    ("nitumie sms", "contact_request"),
    ("namba yangu ni", "contact_request"),
    ("text me", "contact_request"),
    ("inbox me", "contact_request"),
    ("here's my number", "contact_request"),
])
def test_each_kind_is_found(engine, text, kind):
    assert kind in _kinds(engine, text), engine.normalize(text)


# ── And ordinary marketplace talk is left alone ──────────────────────────────
# A finding lowers a seller's rank (domains/trust/completion_rate.py), so a
# false one costs an honest seller. These are the near misses.
@pytest.mark.parametrize("text", [
    "Is the iPhone 13 still available?",
    "Can you do 45,000? Final offer KES 42,500",
    "Price is 1,200,000 negotiable",
    "Whats up, is it in good condition",
    "I'll pay through the app once you confirm",
    "Delivery on 07.10.2025 at 12:30",
    "IMEI 356938035643809",
    "Order number 0612345678",
    "Kitu moja tu, bei gani? Nataka mbili",
    "my line of business is phones",
    "I want to buy goods from your store",
    "It has 8GB RAM and 128GB storage, bought 2023",
    "follow our page @broka_ke",
    "size 10, one pair, two colours",
    "",
])
def test_ordinary_messages_have_no_findings(engine, text):
    assert engine.scan(text) == [], engine.normalize(text)


# ── Shape of a result ─────────────────────────────────────────────────────────

def test_findings_are_sorted_with_offsets_into_the_normalized_text(engine):
    text = "WhatsApp me on 0712 345 678 or email jo@example.com"
    norm = engine.normalize(text)
    found = engine.scan(text)
    assert [f.kind for f in found] == ["messaging_app", "phone", "email"]
    for f in found:
        assert norm[f.start:f.end] == f.text
    assert [f.start for f in found] == sorted(f.start for f in found)


def test_two_numbers_side_by_side_are_two_findings(engine):
    phones = [f.text for f in engine.scan("0712345678 0733123456") if f.kind == "phone"]
    assert phones == ["0712345678", "0733123456"]


def test_findings_are_capped(engine):
    assert len(engine.scan("0712345678 " * 500)) == text_guard.MAX_FINDINGS


def test_lone_surrogates_do_not_break_the_scan(engine):
    # "\ud800" arrives from any JSON body; UTF-8 can't hold it.
    assert _kinds(engine, "call \ud800 0712345678") == ["phone"]


def test_normalized_text_is_printable_ascii_on_single_spaces(engine):
    norm = engine.normalize("  Café\t 　NAIROBI \U0001F600\x00 Ω  ")
    assert norm == "cafe nairobi"
    assert norm.isascii() and norm.isprintable()


def test_public_api_uses_the_loaded_engine():
    text = "call me on 0712345678"
    assert [tuple(f) for f in text_guard.scan(text)] == [tuple(f) for f in text_guard.python_engine().scan(text)]
    assert detect_off_platform_solicitation(text) is True
    assert detect_off_platform_solicitation("is it available?") is False
    assert detect_off_platform_solicitation("") is False


def test_kinds_of_is_distinct_and_sorted():
    found = text_guard.scan("0712345678, 0733123456, whatsapp")
    assert text_guard.kinds_of(found) == ["messaging_app", "phone"]


# ── Rules file ────────────────────────────────────────────────────────────────

def test_a_broken_rules_file_is_refused():
    import json
    rules = json.loads(native.RULES_PATH.read_text())
    for mutate in (
        lambda r: r["rules"][0].update(pattern="("),
        lambda r: r["rules"][0].update(pattern="a*"),
        lambda r: r["rules"][0].update(kind="Bad Kind"),
        lambda r: r["homoglyphs"].update({"0430": "ab"}),
        lambda r: r["number_words"].update(zero="x"),
        lambda r: r["repeaters"].update(double=1),
        lambda r: r["invisible"].append("ZZZZ"),
    ):
        broken = json.loads(json.dumps(rules))
        mutate(broken)
        with pytest.raises(ValueError):
            text_guard.PythonEngine(json.dumps(broken))


# ── Where findings go: the direct-chat audit row ─────────────────────────────

@pytest.fixture(scope="module")
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_text_guard.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module")
async def client(set_test_db):
    await init_db()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


_seq = itertools.count()


async def _thread():
    """A seller, a buyer and a listing between them."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Seller", phone=f"0790{next(_seq):06d}", password_hash="x", phone_verified=True)
        buyer = User(name="Buyer", phone=f"0791{next(_seq):06d}", password_hash="x", phone_verified=True)
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="electronics",
                          price=20_000.0, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return seller.id, buyer.id, listing.id


async def _send_direct(client, sender_id, role, listing_id, buyer_id, content):
    resp = await client.post(
        "/negotiate/direct-message",
        json={"listing_id": listing_id, "sender_role": role, "sender_id": sender_id,
              "content": content, "buyer_id": buyer_id},
        headers={"Authorization": f"Bearer {create_access_token({'sub': sender_id})}"},
    )
    assert resp.status_code == 200, resp.text


async def _solicitation_rows(listing_id):
    async with AsyncSessionLocal() as db:
        rows = await db.execute(
            select(AuditLog, NegotiationMessage)
            .join(NegotiationMessage, NegotiationMessage.id == AuditLog.resource_id)
            .where(AuditLog.action == "off_platform_solicitation_detected",
                   NegotiationMessage.listing_id == listing_id)
        )
        return rows.all()


@pytest.mark.asyncio
async def test_direct_message_with_a_number_is_audited_without_the_number(client):
    seller_id, buyer_id, listing_id = await _thread()
    await _send_direct(client, buyer_id, "buyer", listing_id, buyer_id,
                       "WhatsApp me on zero seven one two 345 678")
    rows = await _solicitation_rows(listing_id)
    assert len(rows) == 1
    audit, message = rows[0]
    # Joinable the way completion_rate.py joins it: to this thread's message.
    assert message.buyer_id == buyer_id and audit.actor_id == buyer_id
    assert "kinds=messaging_app,phone" in audit.detail
    assert "role=buyer" in audit.detail
    # The audit log must not become a copy of people's phone numbers.
    assert "345" not in audit.detail and "678" not in audit.detail


@pytest.mark.asyncio
async def test_ordinary_direct_message_writes_no_audit_row(client):
    seller_id, buyer_id, listing_id = await _thread()
    await _send_direct(client, seller_id, "seller", listing_id, buyer_id,
                       "Yes it's available, 8GB RAM, KES 45,000")
    assert await _solicitation_rows(listing_id) == []
