"""Making two changes to one call cross on purpose (2026-11-14).

A change to a call's Redis session reads it, decides, and writes. `Gate`
holds one write - the first to the call's session key that `matches` what is
being written (and, optionally, made by one task) - from the moment it is
about to go until released, so another change can land between that read
and that write. It works on either way the store writes: a plain SET of the
whole session (the store before atomic writes) or the compare-and-set
script (the store since), which is what lets the tests show the race on the
old store and its absence on the new one.
"""
from __future__ import annotations

import asyncio
import json
from typing import Callable, Optional

from api.core import call_state


class Gate:
    def __init__(self, session_key: str, matches: Optional[Callable[[dict], bool]] = None):
        self.session_key = session_key
        self.matches = matches
        self.task = None
        self.reached = asyncio.Event()
        self.release = asyncio.Event()

    def _applies(self, key, value) -> bool:
        if key != self.session_key or self.release.is_set() or self.reached.is_set():
            return False
        if self.task is not None and asyncio.current_task() is not self.task:
            return False
        if self.matches is not None:
            try:
                return bool(self.matches(json.loads(value)))
            except Exception:
                return False
        return True

    async def hold(self, key, value) -> None:
        if self._applies(key, value):
            self.reached.set()
            await self.release.wait()


class GatedClient:
    """A store's Redis client, with its session writes passing a Gate."""

    def __init__(self, real, gate: Gate):
        self._real = real
        self._gate = gate

    def __getattr__(self, name):
        return getattr(self._real, name)

    async def set(self, name, value, *args, **kwargs):
        await self._gate.hold(name, value)
        return await self._real.set(name, value, *args, **kwargs)

    async def evalsha(self, sha, numkeys, *keys_and_args):
        # The compare-and-set script: KEYS[1] the session, ARGV[2] the new JSON.
        if numkeys >= 1 and len(keys_and_args) > numkeys + 1:
            await self._gate.hold(keys_and_args[0], keys_and_args[numkeys + 1])
        return await self._real.evalsha(sha, numkeys, *keys_and_args)

    async def eval(self, script, numkeys, *keys_and_args):
        if numkeys >= 1 and len(keys_and_args) > numkeys + 1:
            await self._gate.hold(keys_and_args[0], keys_and_args[numkeys + 1])
        return await self._real.eval(script, numkeys, *keys_and_args)

    def register_script(self, script):
        from redis.commands.core import AsyncScript
        return AsyncScript(self, script)

    def pipeline(self, *args, **kwargs):
        return GatedPipeline(self._real.pipeline(*args, **kwargs), self._gate)


class GatedPipeline:
    """A MULTI/EXEC pipeline whose queued SET of the session waits at the
    gate - the store's WATCH-based compare-and-set."""

    def __init__(self, real, gate_: Gate):
        self._real = real
        self._gate = gate_

    def __getattr__(self, name):
        return getattr(self._real, name)

    async def __aenter__(self):
        await self._real.__aenter__()
        return self

    async def __aexit__(self, *exc):
        return await self._real.__aexit__(*exc)

    async def execute(self, *args, **kwargs):
        for command, _options in list(getattr(self._real, "command_stack", [])):
            if len(command) >= 3 and str(command[0]).upper() == "SET":
                await self._gate.hold(command[1], command[2])
        return await self._real.execute(*args, **kwargs)


def redis_store():
    """The module's store when it is the Redis one, else None."""
    store = call_state._store
    return store if isinstance(store, call_state._RedisCallStore) else None


def gate(store, room: str, *, matches: Optional[Callable[[dict], bool]] = None,
         monkeypatch=None) -> Gate:
    """Hold the next matching write to `room`'s session made through `store`."""
    g = Gate(store._key(room), matches)
    real_get_client = store._get_client

    async def gated():
        return GatedClient(await real_get_client(), g)

    if monkeypatch is not None:
        monkeypatch.setattr(store, "_get_client", gated)
    else:
        store._get_client = gated
    return g


async def interleave(gate_: Gate, slow, fast, *, timeout: float = 10.0):
    """Start `slow`; once its write is held, run `fast` to the end; then let
    `slow` write. Returns (slow's result, fast's result)."""
    task = asyncio.ensure_future(slow())
    try:
        await asyncio.wait_for(gate_.reached.wait(), timeout=timeout)
    except asyncio.TimeoutError:
        task.cancel()
        raise AssertionError("the slow change never got to its write")
    try:
        fast_result = await asyncio.wait_for(fast(), timeout=timeout)
    finally:
        gate_.release.set()
    slow_result = await asyncio.wait_for(task, timeout=timeout)
    return slow_result, fast_result
