// The incoming-call notification for a closed app was never posted.
//
// The FCM background isolate sets up NotificationService and posts the call.
// initialize() asked for the notification permission inside the same try
// that marks the service ready. That isolate has no Activity, the plugin
// throws when asked for a permission without one, the service stayed
// not-ready, and showIncomingCall returned without posting anything - so a
// call to a phone whose app was closed never showed up at all.
import 'package:broka/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> calls;

  setUp(() {
    // flutter_local_notifications picks its Android implementation from
    // this, the first time the plugin is created.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = [];
    messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'initialize':
          return true;
        case 'requestNotificationsPermission':
          // What the plugin's Android side answers with no Activity: it
          // dereferences its null Activity, and Flutter returns the
          // exception as an error.
          throw PlatformException(
            code: 'error',
            message: "Attempt to invoke virtual method "
                "'int android.content.Context.checkPermission(...)' "
                'on a null object reference',
          );
        default:
          return null;
      }
    });
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<void> postCall() => NotificationService.instance.showIncomingCall(
        roomId: 'room-1',
        callerName: 'Buyer',
        listingName: 'Phone',
        payload: {'listingId': 'listing-1', 'buyerId': 'buyer-1'},
        // As the FCM background handler posts it.
        ringInApp: false,
      );

  test('a failed permission request still leaves notifications working',
      () async {
    await NotificationService.instance
        .initialize(navKey: GlobalKey<NavigatorState>());
    expect(calls, contains('requestNotificationsPermission'));

    await postCall();
    expect(calls, contains('show'),
        reason: 'the incoming-call notification must be posted');
  });

  test('the background isolate does not ask for the permission', () async {
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
    expect(calls, isNot(contains('requestNotificationsPermission')));

    await postCall();
    expect(calls, contains('show'));
  });
}
