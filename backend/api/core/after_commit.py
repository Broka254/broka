"""Pushes and texts a sweep decides on, sent once its transaction commits.

The deal-timer sweep decides inside a locked transaction which reminders are
due, records that it sent them (Deal.checkin_count, reminder_sms_count) and
writes Zeno's messages. It used to make the FCM and SMS round trips right
there, holding the deal's row lock and one of the process's five pooled
connections through every provider wait - and opening a second connection
for each push's token lookup while the first was still out.

A session the sweep opts in (`defer_sends`) collects the sends instead
(`send_after_commit`); the sweep runs them (`run_sends`) after its commit,
with no connection held. A text whose marker was recorded before it went out
carries `on_failure`, which takes the marker back if the provider refuses
it, so the next pass sends it again - as a failed send always did.

What it trades: a process that dies between the commit and the send leaves
a reminder recorded but not sent, where a commit failing after a send used
to send it twice. Reminders are at most once; nothing here moves money.

A session that has not opted in is not affected: `send_after_commit`
answers False and the caller sends as before (the API paths, which commit
first anyway).
"""
from __future__ import annotations

import logging
from typing import Awaitable, Callable, Optional

logger = logging.getLogger(__name__)

_SENDS = "broka_post_commit_sends"

Send = Callable[[], Awaitable[object]]


def defer_sends(session) -> None:
    """From now on, this session's sends wait for its commit."""
    session.info[_SENDS] = []


def send_after_commit(session, label: str, send: Send, *,
                      on_failure: Optional[Callable[[], Awaitable[None]]] = None) -> bool:
    """Queue `send` (a zero-argument coroutine function) when the session
    defers its sends; False, and nothing queued, when it does not."""
    queue = session.info.get(_SENDS)
    if queue is None:
        return False
    queue.append((label, send, on_failure))
    return True


def take_sends(session) -> list:
    """The queued sends, handed over once - after the commit they wait for.
    A transaction that rolled back drops them with it: what they announced
    did not happen."""
    return session.info.pop(_SENDS, None) or []


async def run_sends(sends: list) -> None:
    """Make the queued sends, each on its own: one provider failing does not
    stop the rest. A send that raises or answers False runs its on_failure."""
    for label, send, on_failure in sends:
        delivered = False
        try:
            delivered = (await send()) is not False
        except Exception as exc:
            logger.warning("[after-commit] %s failed: %s", label, exc)
        if not delivered and on_failure is not None:
            try:
                await on_failure()
            except Exception as exc:
                logger.error("[after-commit] could not undo %s's record: %s", label, exc)
