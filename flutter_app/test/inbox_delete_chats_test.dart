// Deleting chats from the Inbox (services/chat_deletion.dart; backend
// POST /negotiate/{listing}/clear and /negotiate/store/{store}/clear).
// Old and finished conversations piled up with no way to remove them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/inbox_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/chat_deletion.dart';
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
      'my_role': 'seller',
      'last_message': last,
      'last_role': 'buyer',
      'last_msg_type': 'text',
      'last_message_at': '2026-11-13T10:00:00Z',
      'unread': 0,
      'last_message_seen': false,
      'last_message_delivered': false,
      'time_ago': '5m',
      'is_online': false,
    };

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  setUpAll(installFakeApi);

  var failClear = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'chat_cache_v1_direct_l1_buyer-Amina': '[{"id":"m1","content":"old"}]',
      'chat_cache_v1_ai_l1_buyer-Amina': '[{"id":"z1","content":"zeno"}]',
    });
    ApiService.currentUserId = 'u1';
    ChatDeletion.reset();
    clearFakeRequests();
    failClear = false;
    // The server keeps answering with every chat: a deleted one must stay
    // gone on this screen even so (an inbox answer already on its way when
    // the delete went out).
    setFakeRoute((uri) {
      if (uri.path == '/negotiate/inbox/u1') {
        return [
          _thread('l1', 'HP EliteBook 840 G5', 'Amina'),
          _thread('l1', 'HP EliteBook 840 G5', 'Otieno', last: 'Deal at 21K?'),
          _thread('l2', 'Samsung Galaxy A54', 'Kamau', last: 'Thanks, collected'),
        ];
      }
      if (uri.path.endsWith('/clear')) {
        if (failClear) return const FakeResponse.error();
        return {'status': 'ok', 'cleared_at': '2026-11-13T12:00:00Z'};
      }
      return null;
    });
  });

  tearDown(() => setFakeRoute(null));

  Widget app() => const MaterialApp(home: InboxScreen(animateBackground: false));

  List<FakeRequest> clears() =>
      fakeRequests.where((r) => r.method == 'POST' && r.uri.path.endsWith('/clear')).toList();

  testWidgets('a long press picks a chat, and Delete removes it after asking', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    expect(find.byKey(const Key('inbox-delete-hint')), findsOneWidget);

    await tester.tap(find.text('HP EliteBook 840 G5'));
    await _settle(tester);
    await tester.longPress(find.text('Amina'));
    await _settle(tester);
    expect(find.byKey(const Key('inbox-selection-bar')), findsOneWidget);
    expect(find.text('1 chat selected'), findsOneWidget);

    // While picking, a tap picks rather than opening the chat.
    await tester.tap(find.text('Otieno'));
    await _settle(tester);
    expect(find.text('2 chats selected'), findsOneWidget);
    await tester.tap(find.text('Otieno'));
    await _settle(tester);
    expect(find.text('1 chat selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('inbox-delete-selected')));
    await _settle(tester);
    expect(find.text('Delete this chat?'), findsOneWidget);
    expect(clears(), isEmpty, reason: 'nothing is deleted before the answer');
    await tester.tap(find.byKey(const Key('inbox-confirm-delete')));
    await _settle(tester);

    expect(clears().map((r) => r.uri.path), ['/negotiate/l1/clear']);
    expect(clears().single.json, {'buyer_id': 'buyer-Amina'});
    expect(find.text('Amina'), findsNothing);
    expect(find.text('Otieno'), findsOneWidget);
    expect(find.text('Chat deleted'), findsOneWidget);
    expect(find.byKey(const Key('inbox-selection-bar')), findsNothing);

    // The phone's own copy of the chat - the direct chat and Zeno's room -
    // is gone too, so it can't reopen from it.
    expect(await LocalChatStore.load('direct_l1_buyer-Amina'), isEmpty);
    expect(await LocalChatStore.load('ai_l1_buyer-Amina'), isEmpty);

    // A refresh that still lists it doesn't bring it back.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await _settle(tester);
    expect(find.text('Amina'), findsNothing);
  });

  testWidgets("a long press on a listing's card picks all of its chats", (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.longPress(find.text('Samsung Galaxy A54'));
    await _settle(tester);
    await tester.longPress(find.text('HP EliteBook 840 G5'));
    await _settle(tester);
    expect(find.text('3 chats selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('inbox-delete-selected')));
    await _settle(tester);
    expect(find.text('Delete 3 chats?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('inbox-confirm-delete')));
    await _settle(tester);
    expect(clears(), hasLength(3));
    expect(find.text('No conversations yet'), findsOneWidget);
  });

  testWidgets('Cancel, or Back, puts the picks down', (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.longPress(find.text('Samsung Galaxy A54'));
    await _settle(tester);
    expect(find.text('1 chat selected'), findsOneWidget);
    await tester.tap(find.byKey(const Key('inbox-selection-cancel')));
    await _settle(tester);
    expect(find.byKey(const Key('inbox-selection-bar')), findsNothing);

    await tester.longPress(find.text('Samsung Galaxy A54'));
    await _settle(tester);
    final handled = await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(handled, isTrue);
    expect(find.byKey(const Key('inbox-selection-bar')), findsNothing);
    expect(find.text('Samsung Galaxy A54'), findsOneWidget, reason: 'still on the Inbox');
    expect(clears(), isEmpty);
  });

  testWidgets('a delete the server refused leaves the chat where it was', (tester) async {
    failClear = true;
    await tester.pumpWidget(app());
    await _settle(tester);
    await tester.longPress(find.text('Samsung Galaxy A54'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('inbox-delete-selected')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('inbox-confirm-delete')));
    await _settle(tester);
    expect(find.text('Samsung Galaxy A54'), findsOneWidget);
    expect(find.textContaining("Couldn't delete 1 chat"), findsOneWidget);
    expect(find.text('1 chat selected'), findsOneWidget, reason: 'picked still, to try again');
  });
}
