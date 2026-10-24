// The app's backend address is compiled in, from one place now:
// lib/core/network/api_config.dart. Four clients use it - ApiService and
// ApiClient for requests, DealWsClient and AuctionWsClient for live deal and
// auction updates - so moving a build between hosts means changing that one
// file or passing BOTH --dart-define values. A build that moves only one
// sends requests to one backend and listens for live updates on the other,
// where the WebSocket hubs are process-local and never hear about the deal:
// nothing errors, updates just never arrive.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/network/api_config.dart';
import 'package:broka/services/api_service.dart';

void main() {
  // The production backend: BROKA's API service on Render. If the API moves,
  // this changes with api_config.dart - the failure is the point.
  const productionApi = 'https://broka-a6vh.onrender.com';
  const productionWs = 'wss://broka-a6vh.onrender.com';

  test('the production API is the Render backend, over HTTPS', () {
    expect(ApiConfig.baseUrl, productionApi);
    // Release builds refuse cleartext (usesCleartextTraffic="false", ATS).
    expect(ApiConfig.baseUrl, startsWith('https://'));
    // The API mounts its routes at the root (/auth/login, /listings...), and
    // every client appends a path that already starts with "/".
    expect(ApiConfig.baseUrl, isNot(endsWith('/')));
  });

  test('the WebSocket URL is the same backend, over WSS', () {
    expect(ApiConfig.wsBaseUrl, productionWs);
    expect(
      ApiConfig.wsBaseUrl,
      ApiConfig.baseUrl.replaceFirst('https://', 'wss://'),
    );
  });

  test('ApiService and ApiClient resolve to the same base URL', () {
    // Calls and negotiation derive their sockets from ApiService.baseUrl;
    // every feature repository goes through ApiClient.
    expect(ApiClient().baseUrl, ApiService.baseUrl);
    expect(ApiService.baseUrl, ApiConfig.baseUrl);
  });

  test('no client declares a backend default of its own', () {
    // The old code declared API_URL in ApiService and ApiClient and
    // API_WS_URL in both WebSocket clients, and this test existed to catch
    // them drifting apart. One declaration removes the drift; this catches
    // a second one being added back.
    final declaration = RegExp(
      r"String\.fromEnvironment\(\s*'(API_URL|API_WS_URL)'",
    );
    final declarations = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (declaration.hasMatch(f.readAsStringSync())) {
        declarations.add(f.path.replaceAll(r'\', '/'));
      }
    }
    expect(declarations, ['lib/core/network/api_config.dart']);
  });
}
