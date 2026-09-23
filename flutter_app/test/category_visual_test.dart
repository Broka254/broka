// Covers the one thing this whole category pass is about: the UI's category
// visuals are resolved by NAME from a single registry, and that registry
// cannot silently drift from the backend taxonomy.
//
// The parity test below reads backend/api/domains/categories/seed.py itself.
// That is unusual for a Flutter test and it is the point: the brief's failure
// mode was six Dart tables quietly disagreeing with the Python that defines
// what categories exist. A test that only checks Dart against Dart would have
// passed happily while eleven of sixteen categories rendered a generic box.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/features/categories/domain/category_visual.dart';

void main() {
  group('backend parity', () {
    // flutter test runs with the package root as cwd.
    final seed = File('../backend/api/domains/categories/seed.py');

    late List<String> canonicalFromBackend;

    setUpAll(() {
      expect(seed.existsSync(), isTrue,
          reason: 'expected the backend seed at ${seed.path}');
      final src = seed.readAsStringSync();
      final block = RegExp(r'CANONICAL_CATEGORIES\s*=\s*\[(.*?)\]', dotAll: true)
          .firstMatch(src);
      expect(block, isNotNull,
          reason: 'CANONICAL_CATEGORIES not found in seed.py');
      canonicalFromBackend = RegExp('"([^"]+)"')
          .allMatches(block!.group(1)!)
          .map((m) => m.group(1)!)
          .toList();
    });

    test('the registry mirrors the backend taxonomy exactly', () {
      final fromDart =
          CategoryVisuals.canonical.map((v) => v.categoryName).toList();
      // Same names, same order, same count. If someone adds a category to
      // seed.py this fails and names the missing one, instead of that
      // category silently rendering as "Other" on every screen.
      expect(fromDart, canonicalFromBackend);
    });

    test('every backend category resolves to its own visual', () {
      for (final name in canonicalFromBackend) {
        final visual = CategoryVisuals.resolve(name);
        expect(visual.categoryName, name,
            reason: '$name did not resolve to itself');
        if (name != 'Other') {
          expect(identical(visual, CategoryVisuals.fallback), isFalse,
              reason: '$name fell through to the catch-all visual');
        }
        expect(visual.emoji, isNotEmpty);
        expect(visual.gradient, hasLength(greaterThanOrEqualTo(2)),
            reason: '$name needs a two-colour gradient');
      }
    });

    test('no two categories share a visual', () {
      final emojis = CategoryVisuals.canonical.map((v) => v.emoji).toList();
      final icons =
          CategoryVisuals.canonical.map((v) => v.icon.codePoint).toList();
      expect(emojis.toSet(), hasLength(emojis.length),
          reason: 'duplicate emoji across categories');
      expect(icons.toSet(), hasLength(icons.length),
          reason: 'duplicate icon across categories');
    });
  });

  group('resolution', () {
    test('is case- and whitespace-insensitive', () {
      final expected = CategoryVisuals.resolve('Books & Education');
      for (final spelling in const [
        'books & education',
        'BOOKS & EDUCATION',
        '  Books & Education  ',
        'Books & EDUCATION',
      ]) {
        expect(CategoryVisuals.resolve(spelling).categoryName,
            expected.categoryName,
            reason: '"$spelling" should resolve like the canonical name');
      }
    });

    test('an unknown or missing name degrades to the catch-all, never null',
        () {
      for (final unknown in const [
        null,
        '',
        'Time Machines',
        'a category invented after this table was written',
      ]) {
        final visual = CategoryVisuals.resolve(unknown);
        expect(visual.categoryName, 'Other');
        expect(visual.emoji, '🛍️');
      }
    });

    test('legacy free-text categories map onto their canonical successor', () {
      // Listings predating the taxonomy migration still carry these strings.
      expect(CategoryVisuals.resolve('Automobiles').categoryName, 'Vehicles');
      expect(CategoryVisuals.resolve('Livestock').categoryName, 'Agriculture');
      expect(CategoryVisuals.resolve('Phones').categoryName, 'Electronics');
      expect(CategoryVisuals.resolve('Clothing').categoryName, 'Fashion');
      expect(CategoryVisuals.resolve('Books').categoryName, 'Books & Education');
      expect(CategoryVisuals.resolve('Furniture').categoryName,
          'Home & Furniture');
    });

    test('top-level Gaming stays distinct from Electronics', () {
      // The backend defines Gaming both as a top-level category and as a
      // subcategory of Electronics, on purpose. Nothing here may collapse
      // them into one.
      final gaming = CategoryVisuals.resolve('Gaming');
      final electronics = CategoryVisuals.resolve('Electronics');
      expect(gaming.categoryName, 'Gaming');
      expect(electronics.categoryName, 'Electronics');
      expect(gaming.emoji, isNot(electronics.emoji));
      expect(gaming.gradient, isNot(electronics.gradient));
    });

    test('the convenience accessors agree with resolve()', () {
      for (final v in CategoryVisuals.canonical) {
        expect(CategoryVisuals.emojiFor(v.categoryName), v.emoji);
        expect(CategoryVisuals.iconFor(v.categoryName), v.icon);
        expect(CategoryVisuals.gradientFor(v.categoryName), v.gradient);
      }
    });

    test('"Other" is the catch-all and carries plain brand identity', () {
      final other = CategoryVisuals.resolve('Other');
      expect(identical(other, CategoryVisuals.fallback), isTrue);
      // Not a made-up per-category theme - see the registry's own note.
      expect(other.gradient.length, greaterThanOrEqualTo(2));
    });

    test('no entry claims an asset that is not in the bundle', () {
      // Sixteen broken asset references is the specific thing the brief said
      // not to do. When real artwork lands, this test is where the check that
      // it actually exists belongs.
      for (final v in CategoryVisuals.canonical) {
        if (v.assetPath == null) continue;
        expect(File('./${v.assetPath!}').existsSync(), isTrue,
            reason: '${v.categoryName} points at a missing asset '
                '(${v.assetPath})');
      }
    });

    test('semanticLabel is the category name', () {
      expect(CategoryVisuals.resolve('Pets & Animals').semanticLabel,
          'Pets & Animals');
    });
  });

  group('icons are real', () {
    test('every icon is a Material icon from the bundled font', () {
      for (final v in CategoryVisuals.canonical) {
        expect(v.icon, isA<IconData>());
        expect(v.icon.fontFamily, 'MaterialIcons',
            reason: '${v.categoryName} uses a non-bundled icon font');
      }
    });
  });
}
