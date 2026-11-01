// Chat media vault + receipt watermarks, against the real filesystem.
//
// These are plain unit tests (not widget tests) on purpose: the widget
// test zone's fake async never lets real file writes complete, so anything
// touching the vault has to run here, in the real async zone, to exercise
// the production code for real.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/services/chat_media_vault.dart';
import 'package:broka/services/local_chat_store.dart';

/// A valid PNG big enough that the old cache slimming (>50KB data URIs were
/// stored as an empty placeholder) would have thrown it away.
Uint8List bigPng() {
  final r = Random(7);
  final image = img.Image(width: 320, height: 320);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixel(
          x, y, img.ColorRgb8(r.nextInt(256), r.nextInt(256), r.nextInt(256)));
    }
  }
  final bytes = Uint8List.fromList(img.encodePng(image));
  expect(bytes.length, greaterThan(50 * 1024));
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('vault_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => docs.path);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDownAll(() async {
    try {
      await docs.delete(recursive: true);
    } catch (_) {}
  });

  group('vault', () {
    test('a stored data URI comes back as the same bytes', () async {
      final bytes = bigPng();
      final ref = await ChatMediaVault.storeDataUri(
          messageId: 'vault-roundtrip-1',
          dataUri: 'data:image/png;base64,${base64Encode(bytes)}');
      expect(ref, startsWith('file://'));
      final file = ChatMediaVault.fileForSync(messageId: 'vault-roundtrip-1');
      expect(file, isNotNull);
      expect(await file!.readAsBytes(), bytes);
    });

    test('cacheMediaUrl keeps the vault copy and drops big remotes',
        () async {
      final bytes = bigPng();
      final uri = 'data:image/png;base64,${base64Encode(bytes)}';

      // First sight: materialised into the vault, cache keeps the file ref.
      final first = await ChatMediaVault.cacheMediaUrl(
          url: uri, messageId: 'vault-cache-1');
      expect(first, startsWith('file://'));

      // Second sight (a reopen): the vault file wins, nothing rewritten.
      final second = await ChatMediaVault.cacheMediaUrl(
          url: uri, messageId: 'vault-cache-1');
      expect(second, first);

      // Small remote URLs stay as text; large ones are dropped (they
      // re-fetch with history).
      expect(
          await ChatMediaVault.cacheMediaUrl(
              url: 'https://example.com/t.jpg', messageId: 'vault-cache-2'),
          'https://example.com/t.jpg');
      expect(
          await ChatMediaVault.cacheMediaUrl(
              url: 'https://example.com/${'x' * (60 * 1024)}',
              messageId: 'vault-cache-3'),
          isEmpty);

      // file:// and empty pass through untouched.
      expect(
          await ChatMediaVault.cacheMediaUrl(
              url: 'file:///already/there.jpg', messageId: 'vault-cache-4'),
          'file:///already/there.jpg');
      expect(
          await ChatMediaVault.cacheMediaUrl(url: '', messageId: 'v'),
          isEmpty);
    });

    test('adoptFile keeps the sent photo under its settled id', () async {
      final staged = File('${docs.path}/staged.png');
      await staged.writeAsBytes(bigPng());
      await ChatMediaVault.adoptFile(staged,
          messageId: 'vault-adopt-1', clientId: 'client-temp-1');
      final settled =
          ChatMediaVault.fileForSync(messageId: 'vault-adopt-1');
      expect(settled, isNotNull);
      // The client-id alias is not kept: one id, one copy.
      expect(
          ChatMediaVault.fileForSync(clientId: 'client-temp-1'), isNull);

      await ChatMediaVault.remove(messageId: 'vault-adopt-1');
      expect(ChatMediaVault.fileForSync(messageId: 'vault-adopt-1'), isNull);
    });

    test('prune keeps the newest photos within the cap', () async {
      final base = DateTime.now().subtract(const Duration(hours: 1));
      for (var i = 0; i < ChatMediaVault.maxFiles + 5; i++) {
        final ref = await ChatMediaVault.storeBytes(
            messageId: 'vault-prune-$i',
            bytes: Uint8List.fromList([i % 256]),
            ext: 'jpg');
        // Distinct ages so "oldest" is well defined even on filesystems
        // with coarse timestamp resolution.
        await File(ref!.replaceFirst('file://', ''))
            .setLastModified(base.add(Duration(seconds: i)));
      }
      await ChatMediaVault.prune();
      final dir = Directory('${docs.path}/chat_media');
      final count =
          await dir.list().where((e) => e is File).length;
      expect(count, ChatMediaVault.maxFiles);
      // The newest survives; the oldest is gone.
      expect(
          ChatMediaVault.fileForSync(
              messageId: 'vault-prune-${ChatMediaVault.maxFiles + 4}'),
          isNotNull);
      expect(ChatMediaVault.fileForSync(messageId: 'vault-prune-0'), isNull);
    });
  });

  group('receipt watermarks', () {
    test('last known states survive a restart-shaped reload', () async {
      const scope = 'direct_listing-9_buyer-9';
      final read = DateTime.utc(2026, 10, 30, 12, 0);
      final delivered = DateTime.utc(2026, 10, 30, 12, 5);
      await LocalChatStore.saveReceipts(scope,
          read: read, delivered: delivered);
      final loaded = await LocalChatStore.loadReceipts(scope);
      expect(loaded.read?.toUtc(), read);
      expect(loaded.delivered?.toUtc(), delivered);
    });

    test('nothing stored means nothing claimed', () async {
      final loaded = await LocalChatStore.loadReceipts('direct_nope_nope');
      expect(loaded.read, isNull);
      expect(loaded.delivered, isNull);
    });
  });
}
