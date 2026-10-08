// lib/features/categories/presentation/widgets/feed_sort_row.dart
//
// The result count and the sort control above a Zone's or a subcategory's
// grid. Moved out of category_zone_screen.dart when subcategory screens
// needed the same row (2026-10-08) - a second copy is how the sort labels
// would drift apart.
import 'package:flutter/material.dart';

import '../../../../main.dart';

class FeedSortRow extends StatelessWidget {
  const FeedSortRow({
    super.key,
    required this.sort,
    required this.resultCount,
    required this.onSortChanged,
    required this.narrow,
  });

  // 'newest' is the backend's ranking (seller trust, completion rate,
  // freshness), not a date order - it was labelled "Most Recent", so the one
  // order that sounded chronological wasn't. 'recent' is strictly newest
  // first. The default stays the ranking, under an honest name.
  static const options = {
    'newest': 'Top ranked',
    'recent': 'Most Recent',
    'price_low': 'Price: Low to High',
    'price_high': 'Price: High to Low',
  };

  final String sort;

  /// Null while the first page is on its way.
  final int? resultCount;
  final ValueChanged<String> onSortChanged;
  final bool narrow;

  /// Readable but secondary (brief §9). Was textLow on both halves, which put
  /// the result count - the one number telling you whether your filters found
  /// anything - below the legibility floor.
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        color: BrokaColors.textMid, fontSize: narrow ? 12 : 12.5, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              resultCount == null ? ' ' : '$resultCount result${resultCount == 1 ? '' : 's'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: 8),
          // A bare DropdownButton lays itself out to its WIDEST menu item, not
          // to the one that is selected - so "Most Recent" reserved the width
          // of "Price: High to Low" and this Row overflowed on a 320dp phone
          // (and on a 390dp one at a large accessibility text scale). Bounding
          // it and letting it expand inside that bound means the control is
          // sized by the space available, and the selected label ellipsises
          // instead of pushing the result count off the screen.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: narrow ? 140 : 168),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: sort,
                isDense: true,
                isExpanded: true,
                alignment: Alignment.centerRight,
                dropdownColor: BrokaColors.bgCard,
                icon: const Icon(Icons.expand_more_rounded, color: BrokaColors.textMid, size: 18),
                style: style,
                // The closed button renders these; the menu renders `items`.
                selectedItemBuilder: (_) => options.values
                    .map((label) => Align(
                          alignment: Alignment.centerRight,
                          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                items: options.entries
                    .map((e) => DropdownMenuItem(
                        value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (v) {
                  if (v != null) onSortChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
