"""The few things every Gemini caller in BROKA has to agree on.

Four modules call Gemini's REST API directly (negotiate.py, the AI broker,
both dispute modules). Each had the model name typed into its own URL, so
when Google shut gemini-2.0-flash down on 2026-06-01 every one of them
started failing at once - and silently: the callers fall through to the next
provider, so Zeno kept answering, just without Gemini and without the photo
analysis Gemini was first in line for. The model now comes from one setting
(GEMINI_MODEL, see config.py).

Newer Flash models also *think* before answering, and that thinking is
drawn from the same maxOutputTokens budget as the reply. A cap sized for the
reply alone (Zeno's 400) can be spent entirely on thinking, leaving a
response with no text part at all - which the old `parts[0]["text"]` read as
a KeyError. `output_budget` leaves room for it, and `reply_text` reads only
the answer.
"""
from __future__ import annotations

from typing import Optional

from api.core.config import settings

_BASE = "https://generativelanguage.googleapis.com/v1beta/models"

# Room for the model's thinking on top of the reply's own cap. Billed only
# when used; the prompt, not this number, is what keeps replies short.
THINKING_HEADROOM_TOKENS = 2048


def endpoint(model: Optional[str] = None) -> str:
    return f"{_BASE}/{model or settings.gemini_model}:generateContent"


def output_budget(reply_tokens: int) -> int:
    return reply_tokens + THINKING_HEADROOM_TOKENS


def reply_text(data: dict) -> str:
    """The answer's text: every text part of the first candidate that is
    not a thought summary, joined. Raises ValueError when there is none
    (blocked, cut off before any answer), so the caller falls back to its
    next provider instead of showing the user an empty bubble."""
    candidates = data.get("candidates") if isinstance(data, dict) else None
    if not candidates or not isinstance(candidates[0], dict):
        block = (data.get("promptFeedback") or {}).get("blockReason") if isinstance(data, dict) else None
        raise ValueError(f"Gemini returned no answer ({block or 'no candidates'})")
    parts = (candidates[0].get("content") or {}).get("parts")
    if not isinstance(parts, list):
        raise ValueError(
            f"Gemini returned no answer ({candidates[0].get('finishReason') or 'no content'})")
    text = "".join(
        p.get("text", "") for p in parts
        if isinstance(p, dict) and not p.get("thought")
    ).strip()
    if not text:
        raise ValueError("Gemini returned an empty answer")
    return text
