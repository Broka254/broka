// lib/features/categories/presentation/category_directory_screen.dart
//
// "See all": every card of a row on one screen, two to a line - all of
// BROKA's categories from Home, or every type of item in a category from its
// Zone (2026-10-08, after the website's /categories and
// /browse/subcategories/<category> pages). The rows show a few cards and a
// swipe; this is where someone who wants to scan the whole list goes.
import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import 'widgets/category_art_card.dart';

/// One card in a directory.
class DirectoryEntry {
  const DirectoryEntry({
    required this.label,
    required this.emoji,
    required this.gradient,
    required this.onTap,
    this.assetPath,
    this.caption,
  });

  final String label;
  final String emoji;
  final List<Color> gradient;
  final String? assetPath;
  final String? caption;
  final VoidCallback onTap;
}

class CategoryDirectoryScreen extends StatelessWidget {
  const CategoryDirectoryScreen({
    super.key,
    required this.title,
    required this.emoji,
    required this.gradient,
    required this.entries,
    this.intro,
  });

  final String title;
  final String emoji;
  final List<Color> gradient;
  final List<DirectoryEntry> entries;

  /// One line under the header saying what the cards are.
  final String? intro;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final narrow = media.size.width < 360;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.25,
              colors: [gradient.first.withOpacity(0.15), Colors.transparent],
              stops: const [0.0, 0.62],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: CollapsingScreenHeader(
                    title: title,
                    emoji: emoji,
                    gradient: gradient,
                    onBack: () => Navigator.pop(context),
                    narrow: narrow,
                    textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                  ),
                ),
                if (intro != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Text(intro!,
                          style: const TextStyle(
                              color: BrokaColors.textMid, fontSize: 13, height: 1.4)),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + media.padding.bottom),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: media.size.width >= 600 ? 3 : 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      // Landscape, like the pictures: the subject keeps its
                      // shape and two lines of name still fit at large text.
                      childAspectRatio: 1.32 / media.textScaler.scale(1.0).clamp(1.0, 1.3),
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final e = entries[i];
                        return CategoryArtCard(
                          key: Key('directory-card-${e.label}'),
                          label: e.label,
                          emoji: e.emoji,
                          gradient: e.gradient,
                          assetPath: e.assetPath,
                          caption: e.caption,
                          labelSize: narrow ? 13 : 14,
                          onTap: e.onTap,
                        );
                      },
                      childCount: entries.length,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
