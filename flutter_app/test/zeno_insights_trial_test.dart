// Zeno's insights without a plan: three free looks, then BROKA Premium
// (2026-10-12). The server counts each opening (POST /premium/insights);
// the screen shows the cards at once and, refused, says why and closes.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/premium/data/premium_repository.dart';
import 'package:broka/screens/zeno_insights_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

PremiumRepository _premium(int status, Object body, List<String> calls) =>
    PremiumRepository(client: ApiClient(client: MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
    })));

Future<void> _open(WidgetTester tester, PremiumRepository premium) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
      onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => ZenoInsightsScreen(premium: premium))),
      child: const Text('open'),
    )))),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a free look counts and shows the insights', (tester) async {
    final calls = <String>[];
    await _open(tester, _premium(200, {'ok': true}, calls));
    expect(calls, ['POST /premium/insights']);
    expect(find.text('ZENO INSIGHTS'), findsOneWidget);
  });

  testWidgets('with the free looks used, it says why and closes', (tester) async {
    final calls = <String>[];
    await _open(tester, _premium(402, {
      'detail': {
        'code': 'ALLOWANCE_USED',
        'message': "You've used your 3 free looks at Zeno's insights.",
        'feature': 'zeno_insights', 'plan': null, 'upgrade_to': 'plus',
      },
    }, calls));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining("You've used your 3 free looks"), findsWidgets);
  });
}
