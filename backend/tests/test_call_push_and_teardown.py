"""
BROKA - call push shaping + WS room teardown regressions (calling audit, 2026-09-18)

Three server-side bugs, all of which present to a user as the calling
feature simply misbehaving rather than as an error anywhere:

  1. Incoming-call pushes carried no TTL, so FCM's four-week default
     applied: a phone that was off or out of coverage when someone called
     got the push whenever it next reached the network, and rang for a
     call that had ended hours earlier.
  2. The APNs half of every push was hardcoded to a BACKGROUND push, which
     displays nothing - so every VISIBLE notification this helper sends to
     an iOS device (the deal reminders and nudges in core/workers.py) was
     delivered silently to nobody.
  3. The WebSocket relay's teardown popped its room out of the process
     registry without checking the registry still held THAT room, so a
     peer reconnecting in a narrow window had the live call's socket
     registry deleted out from under it.

_send_fcm is exercised through a stubbed firebase_admin.messaging rather
than a live Firebase project: what is under test is the message we build,
which is exactly where the bugs were.
"""
import sys
import types

import pytest

from api.routers import calls as calls_module


class _FakeAps:
    def __init__(self, alert=None, sound=None, content_available=None):
        self.alert = alert
        self.sound = sound
        self.content_available = content_available


class _FakeApsAlert:
    def __init__(self, title=None, body=None):
        self.title = title
        self.body = body


class _FakeAndroidConfig:
    def __init__(self, priority=None, ttl=None, notification=None):
        self.priority = priority
        self.ttl = ttl
        self.notification = notification


class _FakeAndroidNotification:
    def __init__(self, tag=None, channel_id=None):
        self.tag = tag
        self.channel_id = channel_id


class _FakeAPNSConfig:
    def __init__(self, headers=None, payload=None):
        self.headers = headers
        self.payload = payload


class _FakeAPNSPayload:
    def __init__(self, aps=None):
        self.aps = aps


class _FakeNotification:
    def __init__(self, title=None, body=None):
        self.title = title
        self.body = body


class _FakeMessage:
    def __init__(self, notification=None, data=None, token=None, android=None, apns=None):
        self.notification = notification
        self.data = data
        self.token = token
        self.android = android
        self.apns = apns


@pytest.fixture
def captured(monkeypatch):
    """Installs a fake firebase_admin.messaging and captures what we send."""
    sent = []

    messaging = types.SimpleNamespace(
        Message=_FakeMessage,
        Notification=_FakeNotification,
        AndroidConfig=_FakeAndroidConfig,
        AndroidNotification=_FakeAndroidNotification,
        APNSConfig=_FakeAPNSConfig,
        APNSPayload=_FakeAPNSPayload,
        Aps=_FakeAps,
        ApsAlert=_FakeApsAlert,
        send=lambda msg: sent.append(msg),
    )
    fake_pkg = types.ModuleType("firebase_admin")
    fake_pkg.messaging = messaging
    monkeypatch.setitem(sys.modules, "firebase_admin", fake_pkg)
    monkeypatch.setitem(sys.modules, "firebase_admin.messaging", messaging)
    # _get_fcm() gates the whole function on a configured app.
    monkeypatch.setattr(calls_module, "_get_fcm", lambda: object())
    return sent


class TestCallPushShaping:
    @pytest.mark.asyncio
    async def test_incoming_call_push_expires(self, captured):
        """A call push is the definitive "only useful right now" message.
        Without a TTL, FCM holds it for four weeks and rings a phone for a
        call that is long over."""
        await calls_module._send_fcm(
            "tok", "Incoming call", "About: a listing",
            {"type": "incoming_call", "roomId": "r1"},
            data_only=True,
            ttl_seconds=calls_module.CALL_PUSH_TTL_SECONDS,
        )
        assert len(captured) == 1
        msg = captured[0]
        assert msg.android.ttl is not None, "call push must expire"
        assert msg.android.ttl.total_seconds() == calls_module.CALL_PUSH_TTL_SECONDS
        assert msg.android.priority == "high"
        # APNs wants an absolute expiry rather than a duration.
        assert "apns-expiration" in msg.apns.headers
        assert int(msg.apns.headers["apns-expiration"]) > 0

    @pytest.mark.asyncio
    async def test_data_only_push_carries_no_notification_block(self, captured):
        """A `notification` block is auto-displayed by the OS with generic
        styling, which is exactly what the app's own full-screen incoming
        call UI must replace."""
        await calls_module._send_fcm(
            "tok", "t", "b", {"type": "incoming_call"}, data_only=True,
        )
        msg = captured[0]
        assert msg.notification is None
        assert msg.apns.headers["apns-push-type"] == "background"
        assert msg.apns.payload.aps.content_available is True
        # A background push displays nothing, so a sound on it is
        # meaningless - Apple does not honour the combination.
        assert msg.apns.payload.aps.sound is None

    @pytest.mark.asyncio
    async def test_visible_push_is_an_alert_not_a_silent_background_push(self, captured):
        """THE iOS bug. Every non-call notification (workers.py's deal
        reminders and nudges) went out as apns-push-type=background, which
        displays nothing at all."""
        await calls_module._send_fcm(
            "tok", "Your deal is ready", "Tap to pay", {"type": "deal_status"},
        )
        msg = captured[0]
        assert msg.apns.headers["apns-push-type"] == "alert"
        assert msg.apns.headers["apns-priority"] == "10"
        assert msg.apns.payload.aps.alert is not None
        assert msg.apns.payload.aps.alert.title == "Your deal is ready"
        assert msg.apns.payload.aps.content_available is not True
        assert msg.notification is not None

    @pytest.mark.asyncio
    async def test_a_tagged_push_is_drawn_under_that_tag(self, captured):
        """The missed-call push is tagged so the app's own notification for
        the same missed call replaces it rather than doubling it."""
        await calls_module._send_fcm(
            "tok", "Missed call from Ann", "About: Phone", {"type": "missed_call"},
            android_tag="missed_L1_B1", android_channel_id="broka_messages",
        )
        msg = captured[0]
        assert msg.notification is not None
        assert msg.android.notification.tag == "missed_L1_B1"
        assert msg.android.notification.channel_id == "broka_messages"

    @pytest.mark.asyncio
    async def test_push_without_ttl_is_still_valid(self, captured):
        """Reminders are worth delivering late - only calls expire."""
        await calls_module._send_fcm("tok", "t", "b", {"k": "v"})
        msg = captured[0]
        assert msg.android.ttl is None
        assert "apns-expiration" not in msg.apns.headers

    @pytest.mark.asyncio
    async def test_all_data_values_are_stringified(self, captured):
        """FCM rejects non-string data values outright."""
        await calls_module._send_fcm("tok", "t", "b", {"n": 42, "b": True})
        assert captured[0].data == {"n": "42", "b": "True"}


class TestRoomRegistryTeardown:
    """The relay keeps live sockets in a process-local dict keyed by room.
    A handler's `finally` must only ever tear down the room IT was serving -
    not whatever happens to be under that key by the time it runs."""

    def test_teardown_does_not_evict_a_room_replaced_by_a_reconnect(self):
        """The race, concretely: two handlers hold the same (now empty)
        room dict. The first pops it. A peer reconnects and, finding no
        entry, creates a NEW dict under the same room id. The second
        handler then reaches its own pop - and without an identity check
        deletes the reconnected call's registry, so no offer, answer, ICE
        candidate or restart can ever reach the other side again.
        """
        rooms = calls_module._rooms
        room_id = "race-room"
        rooms.pop(room_id, None)

        old_room = {}                 # what both stale handlers captured
        rooms[room_id] = old_room

        # First handler's finally: empty, and still the registered room.
        assert not old_room and rooms.get(room_id) is old_room
        rooms.pop(room_id, None)

        # The reconnect lands here, creating a fresh dict.
        new_room = rooms.setdefault(room_id, {})
        new_room["user-a"] = object()
        assert new_room is not old_room

        # Second (stale) handler's finally. Its room is empty, so the
        # pre-fix condition `if not room:` was True and it popped. The
        # shipped predicate is what's asserted here, not a restatement of it.
        should_pop = (not old_room) and calls_module._owns_room(room_id, old_room)
        assert should_pop is False, "a stale handler must not evict the live room"

        assert rooms.get(room_id) is new_room
        assert "user-a" in rooms[room_id]
        rooms.pop(room_id, None)

    def test_teardown_still_cleans_up_its_own_empty_room(self):
        """The guard must not leak rooms in the normal case."""
        rooms = calls_module._rooms
        room_id = "normal-room"
        rooms.pop(room_id, None)

        room = rooms.setdefault(room_id, {})
        room["user-a"] = object()
        del room["user-a"]

        should_pop = (not room) and calls_module._owns_room(room_id, room)
        assert should_pop is True
        rooms.pop(room_id, None)
        assert room_id not in rooms
