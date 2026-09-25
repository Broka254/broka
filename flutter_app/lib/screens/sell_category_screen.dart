// BROKA - Sell Wizard Step 2: Category
//
// Categories used to be a wrap of chips inside the Basics step: sixteen
// names in a paragraph, then another paragraph of subcategories, with
// nothing to say which one a plot or a bag of maize belonged in. Now it is
// its own step, top to bottom: every category as a row with its emoji and
// a sample of what's in it, opening in place to its subcategories - and a
// search across all ~180 subcategories at once, in the words sellers use
// (CategorySearch). The whole taxonomy comes in one request
// (GET /categories/tree).
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../core/utils/result.dart';
import '../features/categories/data/repositories/categories_repository.dart';
import '../features/categories/domain/category_search.dart';
import '../features/categories/domain/category_visual.dart';
import '../features/categories/domain/models/category.dart';
import '../services/sell_wizard_data.dart';
import '../utils/land_size.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_flow.dart';

class SellCategoryScreen extends StatefulWidget {
  final SellWizardData data;

  /// For tests: the tree instead of fetching it.
  final Future<Result<List<CategoryNode>>> Function()? loadTree;

  const SellCategoryScreen({super.key, required this.data, this.loadTree});
  @override
  State<SellCategoryScreen> createState() => _SellCategoryScreenState();
}

class _SellCategoryScreenState extends State<SellCategoryScreen> {
  List<CategoryNode> _tree = [];
  bool _loading = true;
  bool _failed = false;
  String? _error;
  String? _expandedId;
  final _searchCtrl = TextEditingController();
  String _query = '';

  SellWizardData get _data => widget.data;

  @override
  void initState() {
    super.initState();
    _expandedId = _data.categoryId;
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final result = await (widget.loadTree ?? categoriesRepository.getTree)();
    if (!mounted) return;
    result.fold(
      onSuccess: (tree) => setState(() {
        _tree = tree;
        _loading = false;
      }),
      onFailure: (_, __) => setState(() {
        _loading = false;
        _failed = true;
      }),
    );
  }

  void _pick(CategoryNode node, Category? sub) {
    final categoryChanged = _data.categoryId != node.category.id;
    setState(() {
      _data.categoryId = node.category.id;
      _data.category = node.category.name;
      if (categoryChanged || _data.subcategoryId != sub?.id) {
        // Another kind of item: the previous one's details don't apply.
        _data.attributes = {};
      }
      _data.subcategoryId = sub?.id;
      _data.subcategoryName = sub?.name;
      // Mtumba is second-hand by definition.
      if (sub?.name == SubcategoryHighlights.mtumba) _data.condition = 'used';
      if (node.category.name == 'Land') _data.condition = null;
      _expandedId = node.category.id;
      _error = null;
    });
    _data.persist();
  }

  void _toggle(CategoryNode node) {
    setState(() => _expandedId = _expandedId == node.category.id ? null : node.category.id);
    // A category without subcategories ("Other") is chosen by opening it.
    if (node.subcategories.isEmpty) _pick(node, null);
  }

  void _next() {
    if (!SellFlow.isComplete(SellFlow.category, _data)) {
      setState(() => _error = _data.categoryId == null
          ? 'Choose the category your item belongs in.'
          : 'Choose the type of item within ${_data.category}.');
      return;
    }
    // A Land listing keeps only its land details; anything else drops them.
    if (!_data.isLand) {
      _data.attributes.removeWhere((k, _) => LandSize.fieldNames.contains(k));
    }
    SellFlow.next(context, _data, from: SellFlow.category);
  }

  @override
  Widget build(BuildContext context) {
    final picked = _data.categoryId != null
        ? _tree.where((n) => n.category.id == _data.categoryId).firstOrNull
        : null;
    return SellStepScaffold(
      step: SellFlow.category, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.category),
      subtitle: 'Where would a buyer look for it? Search, or tap a category to see what\'s inside.',
      data: _data,
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _searchField(),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: picked != null && _query.isEmpty
              ? _PickedBanner(
                  key: ValueKey('${_data.categoryId}|${_data.subcategoryId}'),
                  node: picked,
                  subName: _data.subcategoryName,
                )
              : const SizedBox.shrink(),
        ),
        if (_loading)
          ...List.generate(6, (i) => const _SkeletonRow())
        else if (_failed)
          SellCard(child: Row(children: [
            const Expanded(child: Text("Couldn't load the categories. Check your connection.",
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5))),
            TextButton(onPressed: _load, child: const Text('Retry',
                style: TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w700))),
          ]))
        else if (_query.isNotEmpty)
          _results()
        else
          for (var i = 0; i < _tree.length; i++) _categoryRow(_tree[i], i),
      ]),
    );
  }

  Widget _searchField() => Container(
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.4)),
          boxShadow: const [BrokaColors.glowBlue],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          const Icon(Icons.search_rounded, color: BrokaColors.textMid, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: const Key('sell-category-search'),
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'Search: maize, iPhone, plot, mtumba…',
                hintStyle: TextStyle(color: BrokaColors.textMid, fontSize: 13.5),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          if (_query.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() {
                _searchCtrl.clear();
                _query = '';
              }),
              child: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 18),
            ),
        ]),
      );

  Widget _results() {
    final matches = CategorySearch.search(_query, _tree);
    if (matches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(children: [
          const Text('🔎', style: TextStyle(fontSize: 30)),
          const SizedBox(height: 8),
          Text('Nothing called "$_query" yet.', style: const TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Try another word, or clear the search and browse the categories.',
              textAlign: TextAlign.center,
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        ]),
      );
    }
    return Column(children: [
      for (var i = 0; i < matches.length; i++)
        _Entrance(
          index: i,
          child: _resultRow(matches[i]),
        ),
    ]);
  }

  Widget _resultRow(CategoryMatch m) {
    final visual = CategoryVisuals.resolve(m.node.category.name);
    final selected = m.subcategory != null
        ? _data.subcategoryId == m.subcategory!.id
        : (_data.categoryId == m.node.category.id && _data.subcategoryId == null);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _TapCard(
        selected: selected,
        colors: visual.gradient,
        onTap: () {
          if (m.subcategory == null && m.node.subcategories.isNotEmpty) {
            // A category, not a type of item: open it in the list.
            _pick(m.node, null);
            setState(() {
              _searchCtrl.clear();
              _query = '';
              _expandedId = m.node.category.id;
            });
            return;
          }
          _pick(m.node, m.subcategory);
        },
        child: Row(children: [
          _EmojiOrb(emoji: visual.emoji, colors: visual.gradient, size: 38),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.subcategory?.name ?? m.node.category.name, style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(m.subcategory != null ? 'in ${m.node.category.name}' : 'Category',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
          ])),
          _Check(selected: selected),
        ]),
      ),
    );
  }

  Widget _categoryRow(CategoryNode node, int index) {
    final visual = CategoryVisuals.resolve(node.category.name);
    final expanded = _expandedId == node.category.id;
    final chosen = _data.categoryId == node.category.id;
    final sample = node.subcategories.take(3).map((c) => c.name).join(' · ');
    return _Entrance(
      index: index,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: BrokaColors.bgCard.withOpacity(expanded ? 0.9 : 0.7),
            border: Border.all(
              color: chosen ? visual.gradient.first : (expanded
                  ? visual.gradient.first.withOpacity(0.5) : BrokaColors.border),
              width: chosen ? 1.6 : 1,
            ),
            boxShadow: chosen
                ? [BoxShadow(color: visual.gradient.first.withOpacity(0.3), blurRadius: 18)]
                : null,
          ),
          child: Column(children: [
            InkWell(
              key: Key('sell-category-${node.category.name}'),
              borderRadius: BorderRadius.circular(18),
              onTap: () => _toggle(node),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  _EmojiOrb(emoji: visual.emoji, colors: visual.gradient, size: 46),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(node.category.name, style: const TextStyle(
                        color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800)),
                    if (sample.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(sample, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
                    ],
                  ])),
                  if (node.subcategories.isEmpty)
                    _Check(selected: chosen)
                  else
                    AnimatedRotation(
                      turns: expanded ? 0.25 : 0,
                      duration: const Duration(milliseconds: 240),
                      child: Icon(Icons.chevron_right_rounded,
                          color: expanded ? visual.gradient.first : BrokaColors.textMid),
                    ),
                ]),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: expanded && node.subcategories.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Column(children: [
                        Divider(color: BrokaColors.border.withOpacity(0.8), height: 1),
                        const SizedBox(height: 6),
                        for (final sub in node.subcategories) _subRow(node, sub, visual),
                      ]),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _subRow(CategoryNode node, Category sub, CategoryVisual visual) {
    final selected = _data.subcategoryId == sub.id;
    final highlight = SubcategoryHighlights.of(sub.name);
    return InkWell(
      key: Key('sell-subcategory-${sub.name}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => _pick(node, sub),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: selected
              ? LinearGradient(colors: [
                  visual.gradient.first.withOpacity(0.28),
                  visual.gradient.last.withOpacity(0.12),
                ])
              : null,
        ),
        child: Row(children: [
          if (highlight != null) ...[
            Text(highlight.emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(sub.name, style: TextStyle(
              color: selected ? Colors.white : BrokaColors.textHigh,
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500))),
          if (highlight != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: const LinearGradient(colors: [BrokaColors.neonPink, BrokaColors.gold]),
              ),
              child: Text(highlight.label.toUpperCase(), style: const TextStyle(
                  color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.w800,
                  letterSpacing: 0.8)),
            ),
            const SizedBox(width: 8),
          ],
          _Check(selected: selected),
        ]),
      ),
    );
  }
}

/// "Filed under Automobiles › Cars" - what the seller has chosen, above
/// the list, so it stays visible however far they scroll.
class _PickedBanner extends StatelessWidget {
  const _PickedBanner({super.key, required this.node, required this.subName});
  final CategoryNode node;
  final String? subName;

  @override
  Widget build(BuildContext context) {
    final visual = CategoryVisuals.resolve(node.category.name);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(colors: [
          visual.gradient.first.withOpacity(0.35),
          visual.gradient.last.withOpacity(0.15),
        ]),
        border: Border.all(color: visual.gradient.first.withOpacity(0.7)),
      ),
      child: Row(children: [
        Text(visual.emoji, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('FILED UNDER', style: TextStyle(color: Colors.white70, fontSize: 9.5,
              fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          const SizedBox(height: 2),
          Text(subName == null ? node.category.name : '${node.category.name}  ›  $subName',
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w800)),
        ])),
        const Icon(Icons.check_circle_rounded, color: Colors.white),
      ]),
    );
  }
}

class _EmojiOrb extends StatelessWidget {
  const _EmojiOrb({required this.emoji, required this.colors, required this.size});
  final String emoji;
  final List<Color> colors;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [colors.first.withOpacity(0.9), colors.last.withOpacity(0.55)],
            begin: Alignment.topLeft, end: Alignment.bottomRight,
          ),
          boxShadow: [BoxShadow(color: colors.first.withOpacity(0.35), blurRadius: 12)],
        ),
        alignment: Alignment.center,
        child: Text(emoji, style: TextStyle(fontSize: size * 0.46)),
      );
}

class _Check extends StatelessWidget {
  const _Check({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 22, height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? BrokaColors.gold : Colors.transparent,
          border: Border.all(color: selected ? BrokaColors.gold : BrokaColors.textMid, width: 1.5),
          boxShadow: selected ? const [BrokaColors.glowGold] : null,
        ),
        child: selected ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
      );
}

class _TapCard extends StatelessWidget {
  const _TapCard({required this.child, required this.onTap, required this.selected,
      required this.colors});
  final Widget child;
  final VoidCallback onTap;
  final bool selected;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: BrokaColors.bgCard.withOpacity(0.75),
            border: Border.all(color: selected ? colors.first : BrokaColors.border,
                width: selected ? 1.5 : 1),
          ),
          child: child,
        ),
      );
}

/// Rows slide up and fade in one after another when the list appears.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + 35 * index.clamp(0, 12)),
      curve: Curves.easeOutCubic,
      builder: (_, v, c) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 18 * (1 - v)), child: c),
      ),
      child: child,
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) => Container(
        height: 70,
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BrokaColors.border),
        ),
      );
}
