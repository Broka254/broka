// Store images are taken the way listing photos are (services/photo_capture.dart):
// BROKA's own camera first, the phone's camera only as the fallback, the
// listing's size and quality settings, and the photo kept in the app's own
// storage rather than a cache Android may empty.
//
// Reported as "image upload everywhere else doesn't match listing image
// upload": store images went straight to the phone's camera app (which
// Android could kill BROKA behind), at their own settings, and stayed in
// image_picker's cache.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:broka/features/stores/presentation/setup/store_setup_controller.dart';
import 'package:broka/features/stores/presentation/setup/store_setup_steps.dart';
import 'package:broka/screens/listing_camera_screen.dart';
import 'package:broka/services/sell_photo_store.dart';

void main() {
  late Directory base;
  late _FakePicker picker;

  setUp(() {
    base = Directory.systemTemp.createTempSync('photo_capture_test');
    KeptPhotos.baseDirectory = () async => base;
    picker = _FakePicker(base);
    ImagePickerPlatform.instance = picker;
  });

  tearDown(() {
    try {
      base.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A button that picks a store image, and what it got.
  Future<List<File?>> pumpPicker(WidgetTester tester) async {
    final results = <File?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(await pickStoreImage(context, hint: 'Your logo')),
            child: const Text('Pick'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Pick'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return results;
  }

  /// Copying a photo is real file I/O, which only moves outside the test's
  /// fake clock: alternate real waits with frames until it's through.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpFor(WidgetTester tester, Duration d) async {
    for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 50)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('"Take a photo" opens BROKA\'s own camera, not the phone\'s', (tester) async {
    await pumpPicker(tester);
    await tester.tap(find.text('Take a photo'));
    await pumpFor(tester, const Duration(milliseconds: 600));

    expect(find.byType(ListingCameraScreen), findsOneWidget);
    expect(picker.calls, isEmpty, reason: 'the phone camera app is only the fallback');
  });

  testWidgets('the phone camera fallback uses the listing settings and keeps the photo',
      (tester) async {
    final results = await pumpPicker(tester);
    await tester.tap(find.text('Take a photo'));
    await pumpFor(tester, const Duration(milliseconds: 600));
    await settleIo(tester);
    // No camera plugin in a test: BROKA's camera can't start and offers
    // the phone's instead, as on a phone whose camera driver it can't open.
    await tester.tap(find.text("Use the phone's camera instead"));
    await settleIo(tester);

    expect(picker.calls.single.source, ImageSource.camera);
    expect(picker.calls.single.options.imageQuality, 75);
    expect(picker.calls.single.options.maxWidth, 1080);
    final kept = results.single!;
    expect(kept.path, startsWith('${base.path}${Platform.pathSeparator}store_draft'));
    expect(kept.existsSync(), isTrue);
    expect(File(picker.returned.single).existsSync(), isFalse,
        reason: 'a camera shot is moved out of the cache, not copied');
  });

  testWidgets('a gallery pick uses the listing settings and is copied into app storage',
      (tester) async {
    final results = await pumpPicker(tester);
    await tester.tap(find.text('Choose from gallery'));
    await settleIo(tester);

    expect(picker.calls.single.source, ImageSource.gallery);
    expect(picker.calls.single.options.imageQuality, 85);
    expect(picker.calls.single.options.maxWidth, 2048);
    expect(picker.calls.single.options.maxHeight, 2048);
    expect(results.single!.path, startsWith('${base.path}${Platform.pathSeparator}store_draft'));
  });

  test('the store draft and the sell draft keep their photos apart', () async {
    final shot = File('${base.path}/shot.jpg')..writeAsBytesSync([1, 2, 3]);
    final storePhoto = await storeDraftPhotos.keep(shot);
    final listingPhoto = await SellPhotoStore.keep(shot);

    // Publishing a listing clears the sell draft's photos...
    await SellPhotoStore.clear();
    expect(listingPhoto.existsSync(), isFalse);
    // ...and must not take a half-set-up store's logo with it.
    expect(storePhoto.existsSync(), isTrue);
  });
}

class _PickCall {
  _PickCall(this.source, this.options);
  final ImageSource source;
  final ImagePickerOptions options;
}

class _FakePicker extends ImagePickerPlatform {
  _FakePicker(this.dir);
  final Directory dir;
  final calls = <_PickCall>[];
  final returned = <String>[];

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    calls.add(_PickCall(source, options));
    final f = File('${dir.path}/picked_${calls.length}.jpg')..writeAsBytesSync([9, 9, 9]);
    returned.add(f.path);
    return XFile(f.path);
  }
}
