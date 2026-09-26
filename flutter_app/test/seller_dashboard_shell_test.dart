// The Seller Dashboard on Home's visual system (2026-09-26): the
// constellation, the shared header language, and a pill switcher for its
// three tabs. What the tabs contain is unchanged; this covers the shell.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/seller_dashboard_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/chat_ambient_background.dart';
import 'package:broka/widgets/collapsing_screen_header.dart';
import 'package:broka/widgets/constellation_background.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(() async {
    installFakeApi();
    // The overflow check below needs real glyph widths: the test font draws
    // every character a full em wide, roughly twice Roboto's, and reports
    // overflows no phone would show. Flutter's SDK ships Roboto.
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts';
    if (Directory(fonts).existsSync()) {
      final roboto = FontLoader('Roboto');
      for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
        roboto.addFont(Future.value(ByteData.view(File('$fonts/$f').readAsBytesSync().buffer)));
      }
      await roboto.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'seller-1';
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/auth/user/seller-1') {
        return {'id': 'seller-1', 'name': 'Grace Akinyi', 'rating': 4.7, 'completed_deals': 3, 'trust_score': 86};
      }
      if (p.endsWith('/revenue')) return {'total': 0, 'deals': 0, 'series': []};
      if (p.endsWith('/metrics')) return {'history': [], 'advice': []};
      return null;
    });
  });

  testWidgets("on Home's visual system, with its tabs as a pill switcher", (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SellerDashboardScreen(animateBackground: false)));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(ConstellationBackground), findsOneWidget);
    expect(find.byType(ChatAmbientBackground), findsNothing);
    expect(find.text('SELLER DASHBOARD'), findsOneWidget);
    expect(find.byType(BrokaHeaderButton), findsOneWidget); // refresh
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('LIVE'), findsNothing);

    await tester.tap(find.byKey(const Key('dashboard-tab-2')));
    await _settle(tester);
    expect(find.text('DEAL SUMMARY'), findsOneWidget);
    final deals = tester.widget<Text>(find.text('Deals'));
    expect(deals.style!.color, Colors.white, reason: 'the selected tab is lit');
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const MaterialApp(home: SellerDashboardScreen(animateBackground: false)));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(Key('dashboard-tab-$i')));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: 'tab $i');
    }
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
