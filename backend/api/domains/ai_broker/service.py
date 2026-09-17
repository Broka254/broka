"""
BROKA v4.0 - AI Broker Service
Enhanced: circuit breakers, timeouts, cached fallback, multi-language support.

Fallback chain:
  Gemini 2.0 Flash → DeepSeek V4 Flash (direct API - TESTING for latency) →
  OpenRouter (Nemotron 3 Ultra, free tier - TESTING) →
  Groq Llama 3.3 70B (legacy - Groq decommissioned this model 2026-08-16;
  kept wired in, reactivate by pointing GROQ_MODEL at a live Groq model) →
  cached last-known-good → 503

Circuit breakers prevent cascading failures:
  • Gemini:     opens after 5 failures, recovers after 30s
  • DeepSeek:   opens after 5 failures, recovers after 30s
  • OpenRouter: opens after 5 failures, recovers after 30s
  • Groq:       opens after 5 failures, recovers after 30s
"""
from __future__ import annotations

import json
import logging
import time
from typing import Optional
from sqlalchemy.ext.asyncio import AsyncSession
from fastapi import HTTPException
import httpx

from api.core.config import settings
from api.core.circuit_breaker import (
    gemini_breaker, deepseek_breaker, openrouter_breaker, groq_breaker, CircuitOpenError,
)

logger = logging.getLogger(__name__)

GEMINI_URL     = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
GROQ_URL       = "https://api.groq.com/openai/v1/chat/completions"
# DeepSeek's URL is NOT a hardcoded module constant like the above, unlike
# the others - it's built from settings.deepseek_base_url in _call_deepseek
# below, since DEEPSEEK_BASE_URL is meant to be operator-configurable.

BROKA_BROKER_SYSTEM = """You are Broka, a friendly and fair AI marketplace broker for East Africa.
You help buyers and sellers negotiate deals fairly. You:
- Suggest fair prices based on context
- Flag potential scams (pressure tactics, unrealistic prices, requests to move off-platform)
- Explain deal terms clearly in simple language
- Stay professional and encourage both parties
- Support English, Swahili, and Sheng naturally
- Never reveal your underlying model or training
Response format: natural conversational text (no markdown). Keep replies under 200 words."""

ZENO_DISPUTE_SYSTEM = """You are Zeno, BROKA's impartial AI dispute mediator.
Your role is to:
1. Review the buyer's and seller's accounts objectively
2. Assess whether the item was as described and delivered
3. Give a fair verdict: Release funds to seller, Refund to buyer, or Split
4. Provide a clear explanation for your verdict
5. Flag fraud patterns (fake photos, identity mismatch, price manipulation)
Format your response as:
ASSESSMENT: [1-2 sentence summary]
VERDICT: [release|refund|split]
REASONING: [2-3 sentences]
FRAUD_FLAGS: [any concerns or "none"]"""

SCAM_DETECTION_SYSTEM = """You are a fraud detection AI for BROKA marketplace.
Analyse the following message for red flags:
- Requests to pay outside the platform
- Fake verification requests
- Pressure tactics ("only 1 hour left", "other buyers waiting")
- Price manipulation (bait-and-switch)
- Identity fraud signals
Respond ONLY with JSON: {"risk_level":"low|medium|high","flags":["..."],"recommendation":"..."} """

ZENO_ADVISOR_SYSTEM = """You are Zeno, BROKA's shopping advisor.
A buyer has described what they're looking for in their own words. You
will be given a shortlist of up to 20 real, currently-active listings that
already matched their query on category/price/location. Your job is NOT
to invent products — only recommend from the shortlist you are given.
You:
- Rank the shortlist by fit to what the buyer described
- Explain briefly why each of your top picks fits
- Ask one clarifying question only if the shortlist is empty or the
  request is too vague to rank (e.g. no budget, no category)
Response format: natural conversational text (no markdown). Keep replies
under 200 words."""

_CACHE_KEY_PREFIX = "broka:ai_cache:"
_CACHE_TTL        = 3600


async def _cache_get(key: str) -> Optional[str]:
    try:
        if not settings.redis_enabled:
            return None
        import redis.asyncio as aioredis
        client = aioredis.from_url(settings.redis_url, decode_responses=True, socket_connect_timeout=1)
        val = await client.get(f"{_CACHE_KEY_PREFIX}{key}")
        await client.aclose()
        return val
    except Exception:
        return None


async def _cache_set(key: str, value: str) -> None:
    try:
        if not settings.redis_enabled:
            return
        import redis.asyncio as aioredis
        client = aioredis.from_url(settings.redis_url, decode_responses=True, socket_connect_timeout=1)
        await client.setex(f"{_CACHE_KEY_PREFIX}{key}", _CACHE_TTL, value)
        await client.aclose()
    except Exception:
        pass


class AIBrokerService:
    def __init__(self):
        self.gemini_key     = settings.gemini_api_key
        self.deepseek_key   = settings.deepseek_api_key
        self.openrouter_key = settings.openrouter_api_key
        self.groq_key       = settings.groq_api_key

    async def broker_chat(
        self,
        content: str,
        history: list[dict],
        user_name: Optional[str] = None,
        system_override: Optional[str] = None,
        language: str = "english",
    ) -> dict:
        system = ZENO_DISPUTE_SYSTEM if system_override == "zeno" else BROKA_BROKER_SYSTEM
        if language and language.lower() != "english":
            system += f"\n\nRespond primarily in {language}."
        if user_name:
            system += f"\nThe user's name is {user_name}. Use their name occasionally."
        messages = self._build_messages(system, history, content)
        reply    = await self._call_ai(messages, cache_key=f"chat:{hash(content)}")
        return {"role": "broker", "content": reply}

    async def detect_scam(self, message: str) -> dict:
        messages = [{"role": "user", "content": f"{SCAM_DETECTION_SYSTEM}\n\nMessage to analyse:\n{message}"}]
        raw = await self._call_ai(messages, cache_key=f"scam:{hash(message)}")
        try:
            start = raw.index("{")
            end   = raw.rindex("}") + 1
            return json.loads(raw[start:end])
        except (ValueError, json.JSONDecodeError):
            return {"risk_level": "unknown", "flags": [], "recommendation": raw}

    async def price_recommend(
        self, item_name: str, category: str, description: str,
        location: str = "Nairobi", db: Optional[AsyncSession] = None,
    ) -> dict:
        # §4.3: "injects the structured prediction into Zeno's prompt
        # context as a fact Zeno can reference in plain language, rather
        # than letting the model invent a number." db is Optional only so
        # existing callers/tests that construct AIBrokerService without a
        # session don't break; the router always passes one (see
        # domains/ai_broker/router.py).
        ml_hint = ""
        if db is not None:
            from api.core.ml.predict import ml_prediction_service
            prediction = await ml_prediction_service.predict_price(
                category=category, condition="used", listing_price=0.0, db=db,
            )
            if prediction["source"] == "heuristic" and prediction["confidence"] == "low_no_comparable_data":
                pass  # nothing real to ground on yet - let the LLM estimate as before
            else:
                ml_hint = (
                    f"\n\nDATA POINT (use this, don't invent your own number): comparable "
                    f"BROKA deals in this category suggest a range of KES "
                    f"{prediction['min_price']:,.0f}-{prediction['max_price']:,.0f}, "
                    f"median around KES {prediction['recommended_price']:,.0f} "
                    f"(confidence: {prediction['confidence']}, source: {prediction['source']})."
                )

        prompt = (
            f"You are a market pricing expert for East Africa.\n"
            f"Item: {item_name}\nCategory: {category}\nDescription: {description}\nLocation: {location}\n"
            f"{ml_hint}\n\n"
            f'Provide a price estimate in KES. Respond with JSON only:\n'
            f'{{"min_price":0,"max_price":0,"recommended_price":0,"reasoning":"..."}}'
        )
        messages = [{"role": "user", "content": prompt}]
        raw = await self._call_ai(messages, cache_key=f"price:{hash(item_name+category)}")
        try:
            start = raw.index("{")
            end   = raw.rindex("}") + 1
            return json.loads(raw[start:end])
        except (ValueError, json.JSONDecodeError):
            return {"min_price": None, "max_price": None, "recommended_price": None, "reasoning": raw}

    async def dispute_analysis(self, buyer_claim: str, seller_claim: str, deal_amount: float, item_name: str) -> dict:
        prompt = (
            f"Deal: {item_name} for KES {deal_amount:,.0f}\n\n"
            f"Buyer's claim: {buyer_claim}\n\nSeller's response: {seller_claim}\n\n{ZENO_DISPUTE_SYSTEM}"
        )
        messages = [{"role": "user", "content": prompt}]
        raw = await self._call_ai(messages, cache_key=None)
        verdict = "split"
        if "verdict: release" in raw.lower():
            verdict = "release"
        elif "verdict: refund" in raw.lower():
            verdict = "refund"
        return {"raw_verdict": raw, "recommended_resolution": verdict, "confidence": "ai_analysis"}

    async def shopping_advisor(self, query: str, shortlist: list[dict], history: list[dict]) -> dict:
        """shortlist is pre-filtered by ordinary SQL (ListingService) on
        category/price/location BEFORE this is called - this method only
        ranks and explains, it never expands the candidate set itself.
        See Volume 5 Ch.5: the 20-item cap is enforced by the caller, not
        here.
        """
        prompt = f"Buyer's request: {query}\n\nShortlist:\n" + "\n".join(
            f"- {item['name']} — KES {item['price']} — {item['category']}" for item in shortlist
        )
        # Reuses the exact internal method broker_chat() already uses to
        # call Gemini with Groq fallback (_call_ai, top of this file, and
        # circuit_breaker.py) - not a second LLM-calling code path. The
        # doc's draft called this `_call_llm(system=, prompt=, history=)`,
        # which doesn't exist under that name or signature; the real
        # method is `_call_ai(messages, cache_key)`, built via the same
        # `_build_messages` helper broker_chat() uses.
        messages = self._build_messages(ZENO_ADVISOR_SYSTEM, history, prompt)
        reply = await self._call_ai(messages)
        return {"role": "advisor", "content": reply}

    async def parse_buy_request(self, text: str, valid_categories: list[str]) -> dict:
        """Turns a buyer's free-text "what I want" description into the
        structured shape BuyAgentRequestIn needs (category / max_price /
        must_have_features) - added so the Buy-Agent sheet can accept a
        single sentence like "Samsung phone, 12GB RAM, good battery, under
        30000" instead of three separate fields, per the founder's original
        spec (a plain form with no free-text entry point was Volume 6's
        simplification of that, not a rejection of it).
        Client-side contract: this only pre-fills the same three fields the
        form already collects - the buyer still sees and can edit them
        before submitting, so a bad parse costs a correction, not a wrong
        standing request created silently on their behalf.
        Same defensive JSON pattern as detect_scam/price_recommend above:
        one _call_ai round-trip, strict-JSON response, safe all-null
        fallback if the model doesn't cooperate rather than a 500.
        """
        cat_list = ", ".join(valid_categories) if valid_categories else "(none configured yet)"
        prompt = (
            "A buyer on an East African marketplace app typed this description "
            "of what they want to buy. Extract structured search criteria.\n\n"
            f'Buyer\'s description: "{text}"\n\n'
            f"Valid categories - pick the single closest match, or null if truly "
            f"none fit (do not invent a category not in this list): {cat_list}\n\n"
            'Respond with JSON only, no other text, no markdown fences:\n'
            '{"category": "<one of the valid categories, or null>", '
            '"max_price": <number in KES the buyer mentioned as a budget/ceiling, '
            'or null if none was mentioned>, '
            '"must_have_features": ["<short phrase>", ...]}\n\n'
            "must_have_features should be short phrases pulled from the "
            "description itself (brand, spec, condition, colour, etc.) - not "
            "a restatement of the whole sentence, and not invented details "
            "the buyer didn't mention."
        )
        messages = [{"role": "user", "content": prompt}]
        raw = await self._call_ai(messages, cache_key=None)
        try:
            start = raw.index("{")
            end = raw.rindex("}") + 1
            parsed = json.loads(raw[start:end])
            category = parsed.get("category")
            if category not in valid_categories:
                category = None
            max_price = parsed.get("max_price")
            if not isinstance(max_price, (int, float)):
                max_price = None
            features = parsed.get("must_have_features")
            if not isinstance(features, list):
                features = []
            return {
                "category": category,
                "max_price": max_price,
                "must_have_features": [str(f) for f in features][:8],
            }
        except (ValueError, json.JSONDecodeError):
            return {"category": None, "max_price": None, "must_have_features": []}

    async def parse_search_intent(
        self, text: str, valid_categories: list[str], subcategories_by_category: dict[str, list[str]],
        existing_filters: Optional[dict] = None,
    ) -> dict:
        """Richer sibling of parse_buy_request, for the Buying Agent Hub
        (Design v2 §14-15) rather than the plain sheet - extracts into the
        same shape actions.SearchProductsParams expects, so the Hub can
        hand the result straight to POST /buy-agent-requests/action instead
        of a separate hand-rolled request builder. Same defensive pattern
        as parse_buy_request: one _call_ai round-trip, strict JSON, and a
        safe all-null fallback rather than a 500 - the Hub shows the
        confirmation card either way and the buyer can fill in anything
        Zeno missed (§15: "show the interpreted request... user confirmation
        activates the action" - the confirmation step is what makes an
        incomplete parse safe, not a perfect one).

        existing_filters (added for REFINE_SEARCH, Design v2 §21: "Zeno must
        understand that 'it' refers to the active request"): when the Hub is
        already showing results and the buyer types a follow-up like "only
        2018 or newer" or "actually cheaper, under 2M", pass the previous
        SearchProductsParams-shaped dict here. The model is asked to return
        the COMPLETE updated filter set (carrying forward anything the new
        text didn't contradict) rather than just a delta - a plain Python
        merge can't reliably resolve relative language ("cheaper", "a bit
        closer") the way giving the model the prior values in-context can.
        None (the default) reproduces the original one-shot parse exactly.
        """
        cat_list = ", ".join(valid_categories) if valid_categories else "(none configured yet)"
        subcat_hint = "\n".join(
            f"  {cat}: {', '.join(subs)}" for cat, subs in subcategories_by_category.items() if subs
        ) or "  (none configured yet)"
        refinement_hint = ""
        if existing_filters:
            refinement_hint = (
                f"\nThe buyer already has an active search with these filters: "
                f"{json.dumps(existing_filters)}\n"
                f"The text below is a FOLLOW-UP refining that search, not a fresh "
                f"one - return the COMPLETE updated filter set: carry forward every "
                f"existing value the follow-up doesn't contradict or change, and only "
                f"modify what the buyer's new message actually implies (including "
                f"relative language like \"cheaper\", \"newer\", \"a bit closer\").\n"
            )
        prompt = (
            "A buyer on an East African marketplace app typed this description "
            "of what they want to buy. Extract structured search criteria.\n"
            f"{refinement_hint}\n"
            f'Buyer\'s description: "{text}"\n\n'
            f"Valid top-level categories - pick the single closest match, or null if "
            f"truly none fit (do not invent one not in this list): {cat_list}\n\n"
            f"Valid subcategories per category - pick one only if the category above "
            f"has a clear matching subcategory, else null:\n{subcat_hint}\n\n"
            'Respond with JSON only, no other text, no markdown fences:\n'
            '{"query": "<short product description, e.g. \'iPhone 15 Pro\'>", '
            '"category": "<one of the valid categories, or null>", '
            '"subcategory": "<one of that category\'s valid subcategories, or null>", '
            '"min_price": <number in KES, or null>, '
            '"max_price": <number in KES, or null>, '
            '"location": "<place name mentioned, or null>", '
            '"max_distance_km": <number, or null>, '
            '"condition": "<\'new\', \'used\', or \'refurbished\', or null>", '
            '"attributes": {"<field>": "<value>", ...} }\n\n'
            "attributes should only contain specific details the buyer actually "
            "mentioned that aren't already covered above (brand, storage, RAM, "
            "make, model, year, etc.) - not invented details, and not a restatement "
            "of the query."
        )
        messages = [{"role": "user", "content": prompt}]
        raw = await self._call_ai(messages, cache_key=None)
        try:
            start = raw.index("{")
            end = raw.rindex("}") + 1
            parsed = json.loads(raw[start:end])

            category = parsed.get("category")
            if category not in valid_categories:
                category = None
            subcategory = parsed.get("subcategory")
            if category is None or subcategory not in subcategories_by_category.get(category, []):
                subcategory = None

            def _num(key):
                v = parsed.get(key)
                return v if isinstance(v, (int, float)) else None

            attributes = parsed.get("attributes")
            if not isinstance(attributes, dict):
                attributes = {}

            condition = parsed.get("condition")
            if condition not in ("new", "used", "refurbished"):
                condition = None

            return {
                "query": str(parsed.get("query")) if parsed.get("query") else None,
                "category": category,
                "subcategory": subcategory,
                "min_price": _num("min_price"),
                "max_price": _num("max_price"),
                "location": str(parsed.get("location")) if parsed.get("location") else None,
                "max_distance_km": _num("max_distance_km"),
                "condition": condition,
                "attributes": {str(k): str(v) for k, v in attributes.items()},
            }
        except (ValueError, json.JSONDecodeError):
            return {
                "query": None, "category": None, "subcategory": None,
                "min_price": None, "max_price": None, "location": None,
                "max_distance_km": None, "condition": None, "attributes": {},
            }

    async def draft_availability_nudge_sms(
        self,
        seller_name: str,
        buyer_name: str,
        listing_name: str,
        language: str = "english",
    ) -> str:
        """
        Drafts a short SMS nudging a seller who hasn't replied to a buyer's
        interest within 5 minutes. Called only by the deterministic sweep
        (task_check_interest_nudges) after it has already confirmed —
        against real message timestamps, not an AI judgment — that the
        seller genuinely hasn't responded. This method only supplies
        wording; it has no say in whether or when a nudge fires.
        """
        prompt = (
            f"Write a short SMS (under 300 characters, one message, no markdown) "
            f"from Zeno, BROKA's AI marketplace assistant, to a seller named "
            f"{seller_name}. A buyer named {buyer_name} asked about the "
            f"availability of their listing '{listing_name}' about 5 minutes ago "
            f"and the seller hasn't replied yet in the app. Write a friendly, "
            f"brief nudge asking them to confirm availability. Sign off as "
            f"'– Zeno, Broka'. Do not invent any details (location, price, "
            f"condition) that weren't given here."
        )
        if language and language.lower() != "english":
            prompt += f" Write it in {language}."
        messages = [{"role": "user", "content": prompt}]
        return await self._call_ai(messages, cache_key=None)

    def circuit_stats(self) -> dict:
        return {
            "gemini":     gemini_breaker.stats(),
            "deepseek":   deepseek_breaker.stats(),
            "openrouter": openrouter_breaker.stats(),
            "groq":       groq_breaker.stats(),
        }

    def _build_messages(self, system: str, history: list[dict], current: str) -> list[dict]:
        messages = [{"role": "user", "content": system}]
        for h in history[-8:]:
            role = "assistant" if h.get("role") in ("broker", "assistant") else "user"
            messages.append({"role": role, "content": h.get("content", "")})
        messages.append({"role": "user", "content": current})
        return messages

    async def _call_ai(self, messages: list[dict], cache_key: Optional[str] = None) -> str:
        # 1. Try Gemini via circuit breaker
        if self.gemini_key:
            try:
                result = await gemini_breaker.call(self._call_gemini, messages)
                if cache_key:
                    await _cache_set(cache_key, result)
                return result
            except CircuitOpenError:
                logger.warning("[ai_broker] Gemini circuit OPEN — skipping to OpenRouter")
            except Exception as e:
                logger.warning("[ai_broker] Gemini failed: %s — trying OpenRouter", e)

        # 2. Try DeepSeek V4 Flash (direct API - TESTING for latency) via circuit breaker
        if self.deepseek_key:
            try:
                result = await deepseek_breaker.call(self._call_deepseek, messages)
                if cache_key:
                    await _cache_set(cache_key, result)
                return result
            except CircuitOpenError:
                logger.warning("[ai_broker] DeepSeek circuit breaker open — skipping to OpenRouter")
            except Exception as e:
                logger.warning("[ai_broker] DeepSeek failed: %s — trying OpenRouter", e)

        # 3. Try OpenRouter (Nemotron 3 Ultra, free tier — TESTING) via circuit breaker
        if self.openrouter_key:
            try:
                result = await openrouter_breaker.call(self._call_openrouter, messages)
                if cache_key:
                    await _cache_set(cache_key, result)
                return result
            except CircuitOpenError:
                logger.warning("[ai_broker] OpenRouter circuit OPEN — trying Groq")
            except Exception as e:
                logger.warning("[ai_broker] OpenRouter failed: %s — trying Groq", e)

        # 4. Try Groq via circuit breaker
        if self.groq_key:
            try:
                result = await groq_breaker.call(self._call_groq, messages)
                if cache_key:
                    await _cache_set(cache_key, result)
                return result
            except CircuitOpenError:
                logger.warning("[ai_broker] Groq circuit OPEN — trying cached response")
            except Exception as e:
                logger.error("[ai_broker] Groq also failed: %s", e)

        # 5. Return stale cached response (degraded mode)
        if cache_key:
            cached = await _cache_get(cache_key)
            if cached:
                logger.warning("[ai_broker] all AI providers unavailable — returning cached response")
                return cached + "\n\n(Note: This is a cached response — AI is temporarily unavailable.)"

        # 6. Hard failure
        raise HTTPException(status_code=503, detail="AI service temporarily unavailable. Please try again shortly.")

    async def _call_gemini(self, messages: list[dict]) -> str:
        url   = GEMINI_URL.format(model=settings.gemini_model, key=self.gemini_key)
        parts = [{"text": m["content"]} for m in messages if m.get("content")]
        async with httpx.AsyncClient(timeout=25) as c:
            r = await c.post(url, json={"contents": [{"parts": parts}]})
        r.raise_for_status()
        return r.json()["candidates"][0]["content"]["parts"][0]["text"]

    async def _call_deepseek(self, messages: list[dict]) -> str:
        """
        Direct DeepSeek V4 Flash API call - NOT via OpenRouter. Sits
        between Gemini and OpenRouter/Nemotron in the fallback chain (see
        module docstring) specifically to evaluate latency against the
        current Nemotron path. Raises on any failure so _call_ai's
        circuit-breaker-wrapped call falls through to OpenRouter; never
        returns a partial/garbage result.

        Non-thinking mode: deepseek-flash defaults to non-thinking
        already, but this passes {"type": "disabled"} explicitly rather
        than relying on that default silently continuing to hold - real,
        documented parameter (https://api-docs.deepseek.com/guides/thinking_mode),
        not invented. This migration is about conversational latency, not
        deep reasoning, so heavier thinking modes are deliberately not
        enabled here.
        """
        if not self.deepseek_key:
            # _call_ai already gates on self.deepseek_key before calling
            # this, but this defends the method itself against being
            # invoked directly (e.g. from a test) without that gate.
            raise ValueError("DEEPSEEK_API_KEY not configured")

        url = f"{settings.deepseek_base_url}/chat/completions"
        payload = {
            "model":      settings.deepseek_model,
            "messages":   messages,
            "max_tokens": 512,
            "stream":     False,
            "thinking":   {"type": "disabled"},
        }
        headers = {
            "Authorization": f"Bearer {self.deepseek_key}",
            "Content-Type":  "application/json",
        }

        logger.info("[ai_broker] DeepSeek request started")
        started = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=settings.deepseek_timeout_seconds) as c:
                r = await c.post(url, json=payload, headers=headers)
        except httpx.TimeoutException:
            logger.warning(
                "[ai_broker] DeepSeek request timed out after %.1fs",
                time.monotonic() - started,
            )
            raise
        except httpx.RequestError as e:
            # Covers connection errors, DNS failures, TLS issues, etc.
            # Logs only the exception type, never headers/payload.
            logger.warning("[ai_broker] DeepSeek request failed: %s", type(e).__name__)
            raise

        elapsed = time.monotonic() - started

        if r.status_code in (401, 403):
            logger.warning(
                "[ai_broker] DeepSeek authentication failed (HTTP %d) - check DEEPSEEK_API_KEY",
                r.status_code,
            )
        elif r.status_code == 429:
            logger.warning("[ai_broker] DeepSeek rate-limited (HTTP 429)")
        elif r.status_code >= 500:
            logger.warning("[ai_broker] DeepSeek provider error (HTTP %d)", r.status_code)
        r.raise_for_status()  # raises httpx.HTTPStatusError for any 4xx/5xx, including the above

        try:
            data = r.json()
        except ValueError as e:  # json.JSONDecodeError is a ValueError subclass
            logger.warning("[ai_broker] DeepSeek returned malformed JSON: %s", e)
            raise

        try:
            content = data["choices"][0]["message"]["content"]
            if not content:
                raise KeyError("content")
        except (KeyError, IndexError, TypeError) as e:
            logger.warning("[ai_broker] DeepSeek response missing expected fields: %s", e)
            raise ValueError("DeepSeek response missing choices/message/content") from e

        logger.info("[ai_broker] DeepSeek request succeeded")
        logger.info("[ai_broker] DeepSeek response received in %.2fs", elapsed)
        return content

    async def _call_openrouter(self, messages: list[dict]) -> str:
        payload = {"model": settings.openrouter_model, "messages": messages, "max_tokens": 512}
        headers = {
            "Authorization": f"Bearer {self.openrouter_key}",
            "Content-Type":  "application/json",
            # Optional attribution headers OpenRouter uses for its public
            # leaderboards - harmless to omit, but free to include.
            "HTTP-Referer":  "https://broka-dbjd.onrender.com",
            "X-Title":       "BROKA",
        }
        async with httpx.AsyncClient(timeout=25) as c:
            r = await c.post(OPENROUTER_URL, json=payload, headers=headers)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]

    async def _call_groq(self, messages: list[dict]) -> str:
        payload = {"model": settings.groq_model, "messages": messages, "max_tokens": 512}
        headers = {"Authorization": f"Bearer {self.groq_key}", "Content-Type": "application/json"}
        async with httpx.AsyncClient(timeout=25) as c:
            r = await c.post(GROQ_URL, json=payload, headers=headers)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
