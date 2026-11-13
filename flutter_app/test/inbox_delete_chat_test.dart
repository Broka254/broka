// Deleting a chat from the Inbox (asked for 2026-11-13: "add the option of
// deleting an entire chat so that old conversations don't accumulate").
// A long press offers it, a swipe asks for it; either way it is confirmed
// first, sent to POST /negotiate/thread/delete, and the row goes. A chat
// whose deal holds money in escrow is refused by the server, and stays.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/inbox_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/local_chat_store.dart';

import 'support/fake_api.dart';

Map<String, dynamic> _thread(String listingId, String listing, String buyer,
        {String last = 'Is it still available?'}) =>
    {
      'listing_id': listingId,
      'listing_name': listing,
      'listing_category': 'Electronics',
      'listing_price': 24000,
      'location_name': 'Westlands',
      'listing_type': 'fixed',
      'seller_id': 'u1',
      'seller_name': 'Grace Akinyi',
      'buyer_id': 'buyer-$buyer',
      'buyer_name': buyer,
      'counterpart_name': buyer,
      'my_role': 'seller',
      'last_message': last,
      'last_message_id': 'last-$listingId-$buyer',
      'last_role': 'buyer',
      'last_msg_type': 'text',
      'unread': 0,
      'last_message_seen': false,
      'last_message_delivered': false,
      'time_ago': '5m',
      'is_online': false,
    };

void main() {
  setUpAll(installFakeApi);

  Object? deleteAnswer;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'u1';
    clearFakeRequests();
    deleteAnswer = {'deleted': true, 'cleared_at': '2026-11-13T18:00:00Z'};
    setFakeRoute((uri) {
      if (uri.path == '/negotiate/inbox/u1') {
        return [
          _thread('l1', 'Airtel Smart Connect', 'Arnold'),
          _thread('l1', 'Airtel Smart Connect', 'Otieno', last: 'Deal at 4K?'),
          _thread('l2', 'HP EliteBook 840 G5', 'Kamau'),
        ];
      }
      if (uri.path == '/negotiate/thread/delete') return deleteAnswer;
      return null;
    });
  });

  Widget app() => const MaterialApp(home: InboxScreen(animateBackground: false));

  List<Map<String, dynamic>> deletes() => [
        for (final r in fakeRequests)
          if (r.uri.path == '/negotiate/thread/delete') r.json as Map<String, dynamic>,
      ];

  testWidgets('a long press deletes one chat, after asking', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.text('Airtel Smart Connect'));
    await _settle(tester);
    expect(find.text('Arnold'), findsOneWidget);

    await tester.longPress(find.text('Arnold'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('inbox-delete-chat')));
    await _settle(tester);
    expect(find.text('Delete this chat?'), findsOneWidget);
    expect(deletes(), isEmpty, reason: 'nothing goes before it is confirmed');

    await tester.tap(find.byKey(const Key('inbox-confirm-delete')));
    await _settle(tester);

    expect(deletes(), [{'listing_id': 'l1', 'buyer_id': 'buyer-Arnold'}]);
    expect(find.text('Arnold'), findsNothing);
    expect(find.text('Otieno'), findsOneWidget, reason: "the other buyer's chat stays");
    expect(find.text('Chat deleted'), findsOneWidget);
  });

  testWidgets("a listing's card deletes all of its chats", (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);

    await tester.longPress(find.text('Airtel Smart Connect'));
    await _settle(tester);
    expect(find.text('Delete 2 chats'), findsOneWidget);
    await tester.tap(find.byKey(const Key('inbox-delete-chat')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('inbox-confirm-delete')));
    await _settle(tester);

    expect(deletes().map((d) => d['buyer_id']), ['buyer-Arnold', 'buyer-Otieno']);
    expect(find.text('Airtel Smart Connect'), findsNothing);
    expect(find.text('HP EliteBook 840 G5'), findsOneWidget);
  });

  testWidgets('a swipe deletes it too, and the saved copy of the chat goes',
      (tester) async {
    await LocalChatStore.save('direct_l2_buyer-Kamau', [
      {'id': 'm1', 'role': 'buyer', 'content': 'old'},
    ]);
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.text('HP EliteBook 840 G5'));
    await _settle(tester);

    await tester.drag(find.text('Kamau'), const Offset(-500, 0));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('inbox-confirm-delete')));
    await _settle(tester);

    expect(deletes(), [{'listing_id': 'l2', 'buyer_id': 'buyer-Kamau'}]);
    expect(find.text('Kamau'), findsNothing);
    expect(await LocalChatStore.load('direct_l2_buyer-Kamau'), isEmpty);
  });

  testWidgets('a chat with money in escrow is refused, says why, and stays',
      (tester) async {
    deleteAnswer = const FakeResponse({
      'detail': 'This chat has a deal in progress. You can delete it once the deal is complete.',
    }, statusCode: 409);
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.tap(find.text('HP EliteBook 840 G5'));
    await _settle(tester);

    await tester.longPress(find.text('Kamau'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('inbox-delete-chat')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('inbox-confirm-delete')));
    await _settle(tester);

    expect(find.textContaining('deal in progress'), findsOneWidget);
    expect(find.text('Kamau'), findsOneWidget);
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
