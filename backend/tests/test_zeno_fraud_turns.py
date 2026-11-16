"""The fraud guidance inside a real assistant turn (POST /zeno/assistant/turn).

test_zeno_fraud_guidance.py tests the rules and the guard as plain functions;
this tests the wiring that makes them matter:

  * a scam pattern gets its written answer with NO model call, and the turn
    is free (never one of the day's rationed Zeno sessions) - warning
    someone off a scam is not something to ration;
  * the escrow walkthrough still gets "next", "done" and "back" first;
  * a model's reply that breaks the rules is replaced, and the action it
    proposed with it does not run;
  * a photo that is probably a payment gets the screenshot caution under
    whatever the model says;
  * the model is told the live catalogue - and a provider an administrator
    has just suspended is gone from what it is told and from what it may name.

Follows test_escrow_walkthrough.py's setup (module-scoped SQLite, ASGI client).
"""
import json
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.domains.escrow_directory import catalogue
from api.domains.zeno_assistant import fraud_guidance
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(autouse=True)
def _fresh_catalogue():
    catalogue.reset()
    yield
    catalogue.reset()


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_zeno_fraud_turns.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


async def _user() -> User:
    u = User(name="Wanjiru Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u


def _no_model(monkeypatch):
    from api.domains.ai_broker.service import AIBrokerService

    async def boom(self, *args, **kwargs):
        raise AssertionError("the model was called for a message the rules answer")

    monkeypatch.setattr(AIBrokerService, "_call_ai", boom)


def _model(monkeypatch, prompts, reply, action=None):
    from api.domains.ai_broker.service import AIBrokerService

    async def fake(self, messages, cache_key=None, image_base64=None):
        prompts.append(messages[0]["content"])
        return json.dumps({"reply": reply, "action": action or {"type": "NONE"}})

    monkeypatch.setattr(AIBrokerService, "_call_ai", fake)


async def _say(client, user, message, history=None, **extra):
    r = await client.post(
        "/zeno/assistant/turn",
        headers={"Authorization": f"Bearer {create_access_token({'sub': user.id})}"},
        json={"message": message, "history": history or [], **extra})
    assert r.status_code == 200, r.text
    return r.json()


class TestScamGuidanceIsAnsweredWithoutAModel:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("message,needle", [
        ("The seller asked for my M-Pesa PIN", "Never share a PIN, an OTP or a password"),
        ("he asked for a deposit to reserve the phone", "common scam"),
        ("he sent a screenshot showing he paid, should I send the goods?", "A screenshot is not proof of payment"),
        ("the seller wants to skip escrow", "avoid the escrow"),
        ("what should I agree before I pay?", "inspection period"),
        ("I think I was scammed", "Keep everything"),
    ])
    async def test_a_scam_pattern_gets_its_written_answer(self, client, monkeypatch, message, needle):
        _no_model(monkeypatch)
        out = await _say(client, await _user(), message)
        assert out["source"] == "rules" and out["action"] is None
        assert needle in out["reply"] and out["suggestions"] and out["guidance"]

    @pytest.mark.asyncio
    async def test_the_walkthrough_still_owns_next_and_back(self, client, monkeypatch):
        _no_model(monkeypatch)
        user = await _user()
        history = []
        for text in ("walk me through paying with kenya escrow", "next", "next"):
            out = await _say(client, user, text, history)
            history += [{"role": "user", "content": text}, {"role": "assistant", "content": out["reply"]}]
        assert out["reply"].startswith("Step 3 of 7 · Buying with Kenya Escrow")

    def test_a_scam_warning_is_never_one_of_the_days_rationed_sessions(self):
        """The router charges a free account a session for each question about
        someone else's listing, except a turn is_free_turn says is free. A
        warning off a scam must be one of those: rationing it would leave a
        user who had used their day's sessions without the one answer that
        might have saved their money."""
        from api.domains.zeno_assistant import service
        for message in ("the seller asked for my OTP", "he asked for a deposit to reserve it",
                        "he sent a screenshot showing he paid", "I think I was scammed",
                        "what should I agree before I pay?"):
            assert service.is_free_turn(message, []) is True, message
        # An ordinary question about the listing is still one of the day's sessions,
        assert service.is_free_turn("is this a fair price?", []) is False
        # and a photo never takes the free path (the rules cannot see it).
        assert service.is_free_turn("the seller asked for my OTP", [], "aGVsbG8=") is False


class TestAModelsReplyIsChecked:
    @pytest.mark.asyncio
    async def test_an_invented_paybill_is_replaced_and_its_action_does_not_run(self, client, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts,
               "Sure! Pay to paybill 247247 account 12345 to release it.",
               action={"type": "NAVIGATE", "destination": "settings"})
        out = await _say(client, await _user(), "where do I send the money for the laptop?")
        assert out["reply"] == fraud_guidance.GUARD_FALLBACK
        assert "247247" not in json.dumps(out)
        assert out["action"] is None and out["guarded"] == ["till_or_paybill"]

    @pytest.mark.asyncio
    async def test_an_invented_fee_is_replaced(self, client, monkeypatch):
        _model(monkeypatch, [], "Lipasafe charges 2.5% per transaction.")
        out = await _say(client, await _user(), "how much does lipasafe charge?")
        assert out["reply"] == fraud_guidance.GUARD_FALLBACK
        assert out["guarded"] == ["invented_percentage:lipasafe"]

    @pytest.mark.asyncio
    async def test_a_sound_reply_is_passed_through_untouched(self, client, monkeypatch):
        _model(monkeypatch, [], "Lipasafe shows its fee in the app before you confirm. Check the live quotation.")
        out = await _say(client, await _user(), "how much does lipasafe charge?")
        assert out["reply"].startswith("Lipasafe shows its fee") and "guarded" not in out

    @pytest.mark.asyncio
    async def test_a_photo_of_a_payment_gets_the_screenshot_caution_under_the_models_reply(self, client, monkeypatch):
        # a 1x1 PNG
        png = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
        _model(monkeypatch, [], "That message says the payment was sent.")
        out = await _say(client, await _user(), "is this real? he says he paid", image_base64=png)
        assert out["reply"].startswith("That message says the payment was sent.")
        assert fraud_guidance.IMAGE_CAUTION in out["reply"]

    @pytest.mark.asyncio
    async def test_a_photo_of_an_item_does_not(self, client, monkeypatch):
        png = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
        _model(monkeypatch, [], "That looks like a mid-range phone.")
        out = await _say(client, await _user(), "what phone is this?", image_base64=png)
        assert fraud_guidance.IMAGE_CAUTION not in out["reply"]


class TestTheModelIsToldTheLiveCatalogue:
    @pytest.mark.asyncio
    async def test_the_prompt_carries_the_providers_the_rules_and_the_unknowns(self, client, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts, "Happy to help.")
        await _say(client, await _user(), "tell me about escrow providers")
        prompt = prompts[0]
        assert "FRAUD PREVENTION" in prompt
        assert "https://kenyaescrow.com/" in prompt and "https://econfirm.co.ke/" in prompt
        assert "Check live quotation in Lipasafe before paying" in prompt
        assert "Fee not publicly specified – confirm before paying" in prompt
        assert "NEVER invent or estimate a fee" in prompt
        assert "escrowkenya.com) is NOT on Broka's list" in prompt
        assert "https://escrowkenya.com" not in prompt

    @pytest.mark.asyncio
    async def test_a_provider_suspended_after_startup_leaves_what_zeno_is_told(self, client, monkeypatch):
        from api.domains.escrow_directory import repository
        prompts = []
        _model(monkeypatch, prompts, "Happy to help.")
        user = await _user()
        await _say(client, user, "tell me about escrow providers")
        assert "- Shikilia - official site" in prompts[0]
        async with AsyncSessionLocal() as db:
            await repository.change_status(db, "shikilia", "suspended", actor_id="admin-x",
                                           reason="complaints under investigation here")
            await db.commit()
        catalogue.reset()
        await _say(client, user, "tell me about escrow providers again")
        assert "- Shikilia - official site" not in prompts[1]
        assert "Shikilia (shikilia.co.ke) is NOT on Broka's list" in prompts[1]
