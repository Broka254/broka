// The app's backend address is compiled in, in two --dart-define names that
// four files default separately: API_URL (ApiService, ApiClient) for
// requests and API_WS_URL (DealWsClient, AuctionWsClient) for live deal and
// auction updates. Moving the app between hosts (Render to Azure, or back)
// means changing all of them. A build that moves only some sends requests to
// one backend and listens for live updates on the other, where the WebSocket
// hubs (process-local) never hear about the deal - nothing errors, updates
// just never arrive.
//
// The WebSocket defaults are private constants, so this reads the source.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/services/api_service.dart';

void main() {
  // flutter test runs with the package root as cwd.
  final defaults = <String, List<String>>{'API_URL': [], 'API_WS_URL': []};
  final declaration = RegExp(
    r"String\.fromEnvironment\(\s*'(API_URL|API_WS_URL)',\s*defaultValue:\s*'([^']*)'",
  );

  setUpAll(() {
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      for (final m in declaration.allMatches(f.readAsStringSync())) {
        defaults[m.group(1)!]!.add(m.group(2)!);
      }
    }
  });

  test('every API_URL default names the same host, over HTTPS', () {
    final http = defaults['API_URL']!;
    expect(http, hasLength(greaterThanOrEqualTo(2)),
        reason: 'ApiService and ApiClient each declare API_URL');
    expect(http.toSet(), hasLength(1), reason: 'API_URL defaults disagree: $http');
    // Release builds refuse cleartext (usesCleartextTraffic="false", ATS).
    expect(http.first, startsWith('https://'));
    expect(http.first, isNot(endsWith('/')));
  });

  test('API_WS_URL is the WebSocket form of API_URL', () {
    final ws = defaults['API_WS_URL']!;
    expect(ws, hasLength(greaterThanOrEqualTo(2)),
        reason: 'DealWsClient and AuctionWsClient each declare API_WS_URL');
    expect(ws.toSet(), hasLength(1), reason: 'API_WS_URL defaults disagree: $ws');
    expect(ws.first,
        defaults['API_URL']!.first.replaceFirst('https://', 'wss://'));
  });

  test('ApiService and ApiClient resolve to the same base URL', () {
    // Calls and negotiation derive their sockets from ApiService.baseUrl;
    // every feature repository goes through ApiClient.
    expect(ApiClient().baseUrl, ApiService.baseUrl);
  });
}
