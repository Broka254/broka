// How BROKA's pollers space their requests (polling-load pass, 2026-11-14).
//
// The app asks the server on timers: the background sweep (the inbox and
// the incoming-call check), the direct chat's fallback poll while its socket
// is down, the offline sync's retries and the chat socket's reconnects. Two
// things cost the server more than the count of those requests:
//
//  * Every phone waited the SAME delays. After a deploy, an outage or a
//    broadcast push, every phone's timer, backoff and reconnect lined up,
//    and they all asked again in the same second.
//  * The inbox - the most expensive answer the server gives - was fetched
//    as often as the incoming-call check, even while push was bringing
//    every message within a second and nudging a fetch for it.
//
// Pure functions of their inputs and a Random, so the rules are tested
// without timers (test/poll_pacing_test.dart).

import 'dart:math';

/// [base], spread at random over ±[spread] of itself: the same average
/// pace, without every phone on the same beat.
Duration jittered(Duration base, Random random, {double spread = 0.2}) {
  if (base <= Duration.zero || spread <= 0) return base;
  final factor = 1 - spread + random.nextDouble() * 2 * spread;
  return Duration(microseconds: (base.inMicroseconds * factor).round());
}

/// A wait of up to [max], for something many phones are told to do at the
/// same moment (a broadcast push, the network coming back): spread over
/// [max] instead of arriving together.
Duration upTo(Duration max, Random random) {
  if (max <= Duration.zero) return Duration.zero;
  return Duration(milliseconds: random.nextInt(max.inMilliseconds + 1));
}

/// Extra sweep ticks on top of a failure backoff of [baseTicks]: up to a
/// quarter of it, so phones that failed together - the server was down for
/// all of them - do not all retry on the same tick when it comes back.
/// Nothing is added to the fast paces, which are not retries.
int failureSlackTicks(int baseTicks, Random random) =>
    baseTicks >= 4 ? random.nextInt(baseTicks ~/ 4 + 1) : 0;

/// Background-sweep ticks between two fetches of the INBOX, when
/// [callTicks] ticks go by between two incoming-call checks
/// (GlobalPollerService.ticksBetweenSweeps).
///
/// Never fewer than [callTicks]: every inbox fetch checks calls too. While
/// push reaches this phone and the inbox has stayed unchanged for a dozen
/// fetches, the inbox is fetched every 6 ticks - 42 s, or 10 ticks (70 s)
/// with Data saver - because a new message arrives by push and nudges a
/// fetch at once. The incoming-call check keeps [callTicks]: it is how a
/// call rings when its push is late, and it is not slowed. Without push, or
/// while the server is failing, nothing is stretched: the sweep is then how
/// messages arrive at all, and the failure backoff is already [callTicks].
int inboxTicksBetween({
  required int callTicks,
  required int quietSweeps,
  required bool pushReady,
  required bool dataSaver,
  required bool failing,
}) {
  if (failing || !pushReady || quietSweeps < 12) return callTicks;
  return max(callTicks, dataSaver ? 10 : 6);
}
