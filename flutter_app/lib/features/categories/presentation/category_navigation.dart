// lib/features/categories/presentation/category_navigation.dart
//
// The one way into a category, a type of item, or a directory of them, so
// Home, a Zone and the "See all" screens open them alike. Category and
// subcategory screens open with no transition (Design Journal Volume 6,
// Ch.3: tapping a category should feel like the page changing in place, not
// a screen sliding over it); a directory is an ordinary route.
import 'package:flutter/material.dart';

import '../domain/category_visual.dart';
import '../domain/models/category.dart';
import '../domain/subcategory_visual.dart';
import 'category_directory_screen.dart';
import 'category_zone_screen.dart';
import 'subcategory_screen.dart';

Route<void> _instant(Widget page) => PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => page,
    );

void openCategoryZone(BuildContext context, Category category) {
  Navigator.push(context,
      _instant(CategoryZoneScreen(categoryId: category.id, categoryName: category.name)));
}

void openSubcategory(BuildContext context,
    {required String parentId, required String? parentName, required Category subcategory}) {
  Navigator.push(
      context,
      _instant(SubcategoryScreen(
        parentId: parentId,
        parentName: parentName,
        subcategory: subcategory,
      )));
}

/// Every top-level category, as cards.
void openAllCategories(BuildContext context, List<Category> categories) {
  Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CategoryDirectoryScreen(
          title: 'All categories',
          emoji: '🧭',
          gradient: CategoryVisuals.fallback.gradient,
          intro: 'Everything on BROKA, by what it is. Pick one to see its types of item.',
          entries: [
            for (final c in categories)
              DirectoryEntry(
                label: c.name,
                emoji: CategoryVisuals.emojiFor(c.name),
                gradient: CategoryVisuals.gradientFor(c.name),
                assetPath: CategoryVisuals.resolve(c.name).assetPath,
                onTap: () => openCategoryZone(context, c),
              ),
          ],
        ),
      ));
}

/// Every type of item in one category, as cards.
void openAllSubcategories(BuildContext context,
    {required String parentId, required String? parentName, required List<Category> subcategories}) {
  final visual = CategoryVisuals.resolve(parentName);
  Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (directory) => CategoryDirectoryScreen(
          title: '${parentName ?? 'Category'} types',
          emoji: visual.emoji,
          gradient: visual.gradient,
          intro: 'Every type of item in ${parentName ?? 'this category'}. '
              'Each has its own listings and filters.',
          entries: [
            for (final sub in subcategories)
              DirectoryEntry(
                label: sub.name,
                emoji: visual.emoji,
                gradient: visual.gradient,
                assetPath: SubcategoryVisuals.resolve(parentName, sub.name).assetPath,
                onTap: () => openSubcategory(directory,
                    parentId: parentId, parentName: parentName, subcategory: sub),
              ),
          ],
        ),
      ));
}
