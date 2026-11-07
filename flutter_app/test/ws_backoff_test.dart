// The live auction and deal sockets back off when the server won't have
// them (mobile-data pass, 2026-11-07).
//
// Both clients reset their retry count at the start of every attempt,
// before the server had answered, so the backoff never grew past its first
// step: a server that refused every connection was asked again every
// second, for as long as the screen was open, and the deal client's
// ten-retry limit was never reached. The count resets on the server's first
// frame now.
//
// These run against a real local server: no widget binding here, whose
// HttpOverrides would answer every handshake itself.
import 'dart:async';
import 'dart:io';

import 'package:broka/core/network/auction_ws_client.dart';
import 'package:broka/core/network/deal_ws_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  var attempts = 0;
  // false: refuse every handshake. true: accept, say hello, hang up.
  var answer = false;

  setUp(() async {
    attempts = 0;
    answer = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      attempts++;
      if (!answer) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add('{"type": "pong"}');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await socket.close();
    });
    final base = 'ws://127.0.0.1:${server.port}';
    AuctionWsClient.baseUrlOverride = base;
    DealWsClient.baseUrlOverride = base;
    AuctionWsClient.backoffUnit = const Duration(milliseconds: 10);
    DealWsClient.backoffUnit = const Duration(milliseconds: 5);
  });

  tearDown(() async {
    AuctionWsClient.baseUrlOverride = null;
    DealWsClient.baseUrlOverride = null;
    AuctionWsClient.backoffUnit = const Duration(seconds: 1);
    DealWsClient.backoffUnit = const Duration(seconds: 1);
    await server.close(force: true);
  });

  group('the auction socket', () {
    test('backs off while the server refuses it', () async {
      final client = AuctionWsClient(listingId: 'l1', token: 't', onEvent: (_) {})..connect();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      client.dispose();

      // 10, 20, 40, 80, 160, 320 ms between attempts: about seven in 900 ms.
      // Without the backoff (every 10 ms) it would be dozens.
      expect(client.retryCount, greaterThanOrEqualTo(3));
      expect(attempts, lessThanOrEqualTo(9));
    });

    test('starts again from the shortest wait once the server has answered', () async {
      answer = true;
      final events = <Map<String, dynamic>>[];
      final client = AuctionWsClient(listingId: 'l1', token: 't', onEvent: events.add)..connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      client.dispose();

      expect(events, isNotEmpty);
      expect(client.retryCount, lessThanOrEqualTo(1));
      expect(attempts, greaterThan(2), reason: 'each answered drop is retried quickly');
    });

    test('disposed, it does not reconnect', () async {
      final client = AuctionWsClient(listingId: 'l1', token: 't', onEvent: (_) {})..connect();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      client.dispose();
      final before = attempts;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(attempts, before);
    });
  });

  group('the deal socket', () {
    test('backs off, and gives up after its ten retries', () async {
      final client = DealWsClient(dealId: 'd1', token: 't');
      final states = <WsConnectionState>[];
      final sub = client.stateStream.listen((s) => states.add(s.connection));
      client.connect();
      // 5, 10, 20, 40, 80, then 160 ms: ten retries in about a second.
      await Future<void>.delayed(const Duration(milliseconds: 2500));

      expect(client.retryCount, 10);
      expect(attempts, lessThanOrEqualTo(11), reason: 'the first attempt and ten retries');
      expect(states.last, WsConnectionState.disconnected);
      await sub.cancel();
      client.disconnect();
    });

    test('a frame from the server resets the count', () async {
      answer = true;
      final client = DealWsClient(dealId: 'd1', token: 't')..connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(client.retryCount, lessThanOrEqualTo(1));
      expect(attempts, greaterThan(2));
      client.disconnect();
    });
  });
}
