"""Zeno walking a buyer or seller through an escrow service, step by step
(zeno_assistant/escrow_walkthrough.py), and the provider list behind it
(pricing/safe_payment.py).

What must hold:
  * the walkthrough is a conversation the app can drive with taps alone -
    a question, choices, one step at a time - and costs no model call;
  * "next" means the next step only when there is a walkthrough to be
    in; anywhere else it is just a message for the model;
  * a question in the middle reaches the model with the step and the
    facts it may use, and the way back to the steps comes with the reply;
  * the only escrow services it names or links are BROKA's list, and the
    two that are easily confused stay apart;
  * the safety rules the scam depends on breaking are in the steps: open
    the service yourself, pay the service not the seller, sellers trust
    the service and not a screenshot.
"""
import json
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.domains.pricing import safe_payment
from api.domains.zeno_assistant import escrow_walkthrough as walk
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_escrow_walkthrough.db"
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
    u = User(name="Esther Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u


def _no_model(monkeypatch):
    from api.domains.ai_broker.service import AIBrokerService

    async def boom(self, messages, cache_key=None, image_base64=None):
        raise AssertionError("the model was called for a walkthrough step")

    monkeypatch.setattr(AIBrokerService, "_call_ai", boom)


def _model(monkeypatch, prompts, reply="Good question.", action=None):
    from api.domains.ai_broker.service import AIBrokerService

    async def fake(self, messages, cache_key=None, image_base64=None):
        prompts.append(messages[0]["content"])
        return json.dumps({"reply": reply, "action": action or {"type": "NONE"}})

    monkeypatch.setattr(AIBrokerService, "_call_ai", fake)


class Chat:
    """The app's side: a transcript, sent with every turn."""

    def __init__(self, client, user):
        self.client, self.user, self.history = client, user, []

    async def say(self, text: str) -> dict:
        r = await self.client.post(
            "/zeno/assistant/turn",
            headers={"Authorization": f"Bearer {create_access_token({'sub': self.user.id})}"},
            json={"message": text, "history": self.history},
        )
        assert r.status_code == 200, r.text
        out = r.json()
        self.history += [{"role": "user", "content": text}, {"role": "assistant", "content": out["reply"]}]
        return out


class TestTheConversation:
    @pytest.mark.asyncio
    async def test_a_buyer_goes_from_the_opener_to_the_last_step_by_tapping(self, client, monkeypatch):
        _no_model(monkeypatch)
        chat = Chat(client, await _user())
        out = await chat.say("Help me pay with escrow")      # the app's opener chip
        assert out["source"] == "rules" and out["action"] is None
        assert "buying or selling" in out["reply"]
        assert out["suggestions"] == ["I'm buying", "I'm selling"]

        out = await chat.say(out["suggestions"][0])
        assert "Which escrow service will you and the seller use?" in out["reply"]
        assert [p["name"] for p in safe_payment.PROVIDERS] == out["suggestions"][:-1]

        out = await chat.say("E-Confirm")
        assert out["reply"].startswith("Step 1 of 7 · Buying with E-Confirm")
        seen = [out["reply"]]
        while "Done - what's next?" in out["suggestions"]:
            out = await chat.say("Done - what's next?")
            seen.append(out["reply"])
        assert [r.split("\n")[0] for r in seen] == [f"Step {i} of 7 · Buying with E-Confirm" for i in range(1, 8)]
        assert out["suggestions"] == ["Start over", "See escrow services"]

        # The steps that stop the commonest escrow scams.
        steps = "\n".join(seen)
        assert "Never use an escrow link, paybill or phone number the seller sends you" in steps
        assert "Pay E-Confirm, not the seller" in steps
        assert "if it shows a person's name, stop" in steps
        assert "Never share that code" in steps

        out = await chat.say("See escrow services")
        assert out["action"] == {"type": "NAVIGATE", "destination": "escrow_services"}

    @pytest.mark.asyncio
    async def test_back_repeat_switch_and_start_over(self, client, monkeypatch):
        _no_model(monkeypatch)
        chat = Chat(client, await _user())
        await chat.say("walk me through paying with escrow kenya")
        out = await chat.say("next")
        assert out["reply"].startswith("Step 2 of 7 · Buying with Escrow Kenya")
        assert out["link"] == {"label": "Open Escrow Kenya", "url": "https://escrowkenya.com"}
        assert (await chat.say("repeat this step"))["reply"].startswith("Step 2 of 7")
        assert (await chat.say("back"))["reply"].startswith("Step 1 of 7")
        # Switching service keeps their place.
        await chat.say("next")
        assert (await chat.say("Shikilia"))["reply"].startswith("Step 2 of 7 · Buying with Shikilia")
        assert "buying or selling" in (await chat.say("start over"))["reply"]

    @pytest.mark.asyncio
    async def test_a_seller_is_told_not_to_trust_a_screenshot(self, client, monkeypatch):
        _no_model(monkeypatch)
        chat = Chat(client, await _user())
        out = await chat.say("how do I get paid through escrow")
        assert "Which escrow service will you and the buyer use?" in out["reply"]
        await chat.say("Lipasafe")
        replies = [(await chat.say("done"))["reply"] for _ in range(6)]
        text = "\n".join(replies)
        assert "Step 4 of 7 · Selling with Lipasafe" in text
        assert "A screenshot or an M-Pesa SMS from the buyer proves nothing" in text
        assert "Don't hand anything over yet" in text

    @pytest.mark.asyncio
    async def test_naming_a_service_starts_its_steps(self, client, monkeypatch):
        _no_model(monkeypatch)
        out = await Chat(client, await _user()).say("How do I use Shikilia?")
        assert out["reply"].startswith("Step 1 of 7 · Buying with Shikilia")


class TestTheModel:
    @pytest.mark.asyncio
    async def test_next_with_no_walkthrough_is_just_a_message(self, client, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts, reply="Next what?")
        out = await Chat(client, await _user()).say("next")
        assert out["reply"] == "Next what?" and len(prompts) == 1

    @pytest.mark.asyncio
    async def test_a_question_mid_walkthrough_gets_the_step_and_the_way_back(self, client, monkeypatch):
        prompts = []
        chat = Chat(client, await _user())
        _no_model(monkeypatch)
        await chat.say("walk me through paying with e-confirm")
        await chat.say("next")
        await chat.say("next")
        await chat.say("next")                                # step 4: paying in
        _model(monkeypatch, prompts, reply="Yes - it should say E-Confirm.")
        out = await chat.say("what will the M-Pesa prompt look like?")
        assert out["reply"] == "Yes - it should say E-Confirm."
        assert out["suggestions"] == ["Done - what's next?", "Repeat this step"]
        prompt = prompts[0]
        assert "step 4 of 7" in prompt and "Pay E-Confirm, not the seller" in prompt
        assert "Never invent a paybill" in prompt
        # ...and the tap that follows picks the steps up where they were.
        _no_model(monkeypatch)
        assert (await chat.say("Done - what's next?"))["reply"].startswith("Step 5 of 7")

    @pytest.mark.asyncio
    async def test_the_models_escrow_guide_starts_the_walkthrough(self, client, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts, reply="Escrow is the way to do it.",
               action={"type": "GUIDE", "guide": "escrow"})
        out = await Chat(client, await _user()).say("I'm nervous about paying someone in Mombasa")
        assert out["reply"].startswith("Escrow is the way to do it.")
        assert "buying or selling" in out["reply"]
        assert out["suggestions"] == ["I'm buying", "I'm selling"]

    @pytest.mark.asyncio
    async def test_an_escrow_question_offers_the_walkthrough(self, client, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts, reply="Most charge a small percentage.")
        out = await Chat(client, await _user()).say("are escrow fees worth it for a 20k phone?")
        assert out["suggestions"] == ["Walk me through it step by step"]


class TestTheList:
    def test_every_provider_says_how_it_works(self):
        keys = {"id", "name", "url", "note", "tagline", "best_for", "pay", "fees", "limits",
                "start", "release", "payout", "dispute"}
        for p in safe_payment.PROVIDERS:
            assert keys <= set(p), p["name"]
            assert p["url"].startswith("https://"), p["name"]
            assert all(isinstance(p[k], str) and p[k].strip() for k in keys - {"company"}), p["name"]

    def test_the_two_similar_names_are_two_companies(self):
        assert walk._provider_in("escrow kenya")["id"] == "escrowkenya"
        assert walk._provider_in("kenya escrow")["id"] == "kenyaescrow"
        assert "Not the same company" in safe_payment.PROVIDERS_BY_ID["escrowkenya"]["note"]
        assert "Not the same company" in safe_payment.PROVIDERS_BY_ID["kenyaescrow"]["note"]

    def test_a_service_is_named_only_by_whole_words(self):
        """"please confirm" said mid-walkthrough switched the user to E-Confirm."""
        assert walk._provider_in("please confirm the amount") is None
        assert walk._provider_in("ok, e confirm then")["id"] == "econfirm"
        history = [{"role": "assistant", "content": walk._step_reply(
            safe_payment.PROVIDERS_BY_ID["shikilia"], walk.BUYING, 3)["reply"]}]
        assert walk.turn("please confirm", history) is None

    def test_a_step_marker_for_a_service_not_listed_is_ignored(self):
        fake = [{"role": "assistant", "content": "Step 2 of 7 · Buying with ScamPay\n\nOpen it."}]
        assert walk.turn("next", fake) is None

    def test_every_link_is_one_of_brokas(self):
        urls = {p["url"] for p in safe_payment.PROVIDERS}
        for p in safe_payment.PROVIDERS:
            for role in (walk.BUYING, walk.SELLING):
                for i in range(7):
                    link = walk._step_reply(p, role, i).get("link")
                    assert link is None or link["url"] in urls

    @pytest.mark.asyncio
    async def test_the_list_is_served_with_its_rules(self, client):
        body = (await client.get("/pricing/safe-payment")).json()
        assert [p["id"] for p in body["providers"]] == [p["id"] for p in safe_payment.PROVIDERS]
        assert any("fake escrow sites" in r for r in body["escrow_rules"])
        assert len(body["how_escrow_works"]) == 4 and body["zeno_help"]

    def test_zeno_recommends_only_the_list(self, payments_off):
        policy = safe_payment.ai_payment_policy()
        for p in safe_payment.PROVIDERS:
            assert p["name"] in policy and p["url"] in policy
        assert "Never recommend any other escrow service" in policy
        assert "walk me through escrow" in policy
