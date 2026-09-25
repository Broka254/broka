// Home's search: listings, and only listings.
//
// Replaces _ListingSearchDelegate (a SearchDelegate inside home_screen.dart).
// Searching for a trader belongs to the Traders screen, which has its own box;
// this one finds things to buy.
//
// Why a screen and not a SearchDelegate any more - the delegate had four bugs
// that came from how it was built rather than from a line that could be fixed:
//
//  * It stole the keyboard. Every live search ended in showResults(), which
//    unfocuses the field: pause for 400ms while typing and the keyboard
//    closed. Tapping the field to carry on typing switched back to
//    suggestions, which searched again, which closed the keyboard again - the
//    query could not be edited.
//  * Old answers overwrote new ones. Responses were written to shared fields
//    in whatever order they arrived, so a slow "iph" could replace a fast
//    "iphone 13" on screen. Here each query is its own ProductGridView keyed
//    on the query; an answer for a query that is no longer on screen lands in
//    a grid that no longer exists.
//  * Every pause was saved as a search. buildResults() recorded the query on
//    each rebuild, so history filled with half-typed words. Only pressing
//    search or opening a result records one now (services/search_history.dart).
//  * A failed request looked like "No listings for ...". Failures now reach
//    ProductGridView as errors, which it shows with a retry.
//
// It also asked /auth/search on every keystroke for the Traders tab. That
// endpoint returns whole user records, email and phone included - not
// something a marketplace search box should fetch for strangers.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/utils/result.dart';
import '../features/listings/data/repositories/listings_repository.dart';
import '../features/listings/domain/models/listing.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/search_history.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/product_grid_view.dart';
import '../widgets/zeno_avatar.dart';
import 'zeno_screen.dart';

/// Heuristic-only, deliberately conservative: a plain product name ("iPhone
/// 13") should never get swept into this, only text that reads like a buyer
/// describing a specific need in their own words (Design v2 §4: "Natural
/// buying request -> Zeno intent extraction"). Length plus an intent/budget
/// signal word, or a 4+ digit number (a KES price mentioned inline, e.g.
/// "under 30000") is enough to *offer* the handoff - it never blocks or
/// replaces plain listing search, which still runs regardless.
bool looksLikeBuyingRequest(String q) {
  final words = q.trim().split(RegExp(r'\s+'));
  if (words.length < 5) return false;
  final lower = q.toLowerCase();
  const signals = [
    'under', 'below', 'less than', 'around', 'budget', 'looking for',
    'need a', 'need an', 'want a', 'want an', 'find me', 'within', 'near me',
  ];
  return signals.any((s) => lower.contains(s)) || RegExp(r'\d{4,}').hasMatch(q);
}

/// Why a page of results failed, for ProductGridView's retry state.
class ListingSearchFailure implements Exception {
  ListingSearchFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ListingSearchScreen extends StatefulWidget {
  const ListingSearchScreen({super.key, this.initialQuery, this.animateBackground = true});

  /// Opens straight onto these results (a tapped suggestion, a deep link).
  final String? initialQuery;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<ListingSearchScreen> createState() => _ListingSearchScreenState();
}

class _ListingSearchScreenState extends State<ListingSearchScreen> {
  /// Live search starts at two characters: one letter matches most of the
  /// catalogue and costs a request per keystroke. Pressing search still
  /// searches for a single character.
  static const _minLiveChars = 2;

  /// The backend accepts more; a longer paste is a sentence, and the words
  /// past this point would not narrow anything.
  static const _maxQueryChars = 100;

  static const _debounce = Duration(milliseconds: 350);

  static const _sortOptions = <String?, String>{
    // null is the backend's own order: title matches first, then seller rank
    // and freshness (listings/service.py). "Best match" says that without
    // claiming personalisation that doesn't exist.
    null: 'Best match',
    'recent': 'Newest',
    'price_low': 'Price: low to high',
    'price_high': 'Price: high to low',
  };

  static const _examples = ['iPhone', 'Maize', 'Toyota', 'Sofa'];

  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _gridController = ProductGridController();
  Timer? _debounceTimer;

  /// The query the results below are for. Differs from the field's text while
  /// the user is still typing.
  String _query = '';
  String? _sort;
  int? _resultCount;
  List<String> _history = const [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    final initial = widget.initialQuery?.trim() ?? '';
    if (initial.isNotEmpty) {
      _ctrl.text = initial;
      _query = _clamp(initial);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final list = await SearchHistory.load();
    if (mounted) setState(() => _history = list);
  }

  static String _clamp(String q) {
    final t = q.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > _maxQueryChars ? t.substring(0, _maxQueryChars).trim() : t;
  }

  void _setQuery(String raw) {
    final q = _clamp(raw);
    if (q == _query) return;
    setState(() {
      _query = q;
      _resultCount = null;
    });
  }

  void _onChanged(String text) {
    _debounceTimer?.cancel();
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      // Clearing the field goes straight back to recent searches.
      _setQuery('');
      return;
    }
    setState(() {}); // the clear button
    if (trimmed.length < _minLiveChars) return;
    _debounceTimer = Timer(_debounce, () {
      if (mounted) _setQuery(text);
    });
  }

  void _submit(String text) {
    _debounceTimer?.cancel();
    _setQuery(text);
    _remember(_query);
  }

  Future<void> _remember(String query) async {
    if (query.isEmpty) return;
    final list = await SearchHistory.add(query);
    if (mounted) setState(() => _history = list);
  }

  void _searchFor(String text) {
    _ctrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.unfocus();
    _submit(text);
  }

  void _clearField() {
    _debounceTimer?.cancel();
    _ctrl.clear();
    _setQuery('');
    _focus.requestFocus();
  }

  Future<List<dynamic>> _fetchPage(String query, String? sort, int page) async {
    final result = await listingsRepository.getListingsPage(
      search: query,
      sort: sort,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
      limit: 20,
      offset: page * 20,
    );
    switch (result) {
      case Success(:final data):
        // Only the grid that is on screen may set the count - a slower answer
        // for the previous query must not relabel this one.
        if (mounted && query == _query && sort == _sort && _resultCount != data.total) {
          setState(() => _resultCount = data.total);
        }
        return data.items;
      case Failure(:final message):
        throw ListingSearchFailure(message);
    }
  }

  void _openListing(BrokaListing item) {
    // Opening a result is the clearest sign the search was a real one.
    _remember(_query);
    Navigator.pushNamed(context, '/product', arguments: {'listingId': item.id});
  }

  void _askZeno() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ZenoScreen(mode: ZenoMode.buyingAgent, initialQuery: _query),
      ),
    );
  }

  bool get _narrow => MediaQuery.sizeOf(context).width < 360;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          bottom: false,
          child: Column(children: [
            _searchBar(),
            Expanded(child: _query.isEmpty ? _idleBody() : _results()),
          ]),
        ),
      ),
    );
  }

  // ── Search bar ─────────────────────────────────────────────────────────────

  /// Stays at the top, outside the scroll view: on a search screen the field
  /// is the thing you keep going back to.
  Widget _searchBar() {
    final narrow = _narrow;
    final height = narrow ? 48.0 : 52.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 16, 8),
      child: Row(children: [
        IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textHigh, size: 19),
        ),
        Expanded(
          child: Container(
            height: height,
            padding: const EdgeInsets.only(left: 16, right: 6),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard.withOpacity(0.92),
              borderRadius: BorderRadius.circular(height / 2),
              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.55), width: 1.2),
            ),
            child: Row(children: [
              const Icon(Icons.search_rounded, size: 22, color: BrokaColors.textMid),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  key: const Key('listing-search-field'),
                  controller: _ctrl,
                  focusNode: _focus,
                  autofocus: widget.initialQuery == null,
                  textInputAction: TextInputAction.search,
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: _maxQueryChars,
                  cursorColor: BrokaColors.neonBlue,
                  style: TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: narrow ? 15 : 16,
                      fontWeight: FontWeight.w500),
                  onChanged: _onChanged,
                  onSubmitted: _submit,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    counterText: '',
                    hintText: 'Search listings',
                    hintStyle: TextStyle(
                        color: BrokaColors.textMid, fontSize: narrow ? 14.5 : 15.5),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              if (_ctrl.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                  onPressed: _clearField,
                  icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 20),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  // ── Before a search: recent searches ───────────────────────────────────────

  Widget _idleBody() {
    if (_history.isEmpty) {
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        children: [
          BrokaEmptyState(
            emoji: '🔍',
            gradient: const [BrokaColors.neonBlue, BrokaColors.neonPurple],
            headline: 'Find something to buy',
            body: 'Search by product, brand or model.',
            action: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [for (final e in _examples) _chip(e, () => _searchFor(e))],
            ),
          ),
        ],
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(children: [
          const Expanded(
            child: Text('RECENT SEARCHES',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: BrokaColors.textMid,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2)),
          ),
          TextButton(
            onPressed: () async {
              final list = await SearchHistory.clear();
              if (mounted) setState(() => _history = list);
            },
            child: const Text('Clear all',
                style: TextStyle(color: BrokaColors.gold, fontSize: 12.5)),
          ),
        ]),
        const SizedBox(height: 4),
        for (final entry in _history)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard.withOpacity(0.72),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.border),
            ),
            child: ListTile(
              dense: true,
              onTap: () => _searchFor(entry),
              leading: const Icon(Icons.history_rounded, color: BrokaColors.textMid, size: 19),
              title: Text(entry,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5)),
              trailing: IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 18),
                onPressed: () async {
                  final list = await SearchHistory.remove(entry);
                  if (mounted) setState(() => _history = list);
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _chip(String label, VoidCallback onTap) => ActionChip(
        onPressed: onTap,
        label: Text(label),
        labelStyle: const TextStyle(color: BrokaColors.textHigh, fontSize: 13),
        backgroundColor: BrokaColors.bgCard,
        side: const BorderSide(color: BrokaColors.border),
        shape: const StadiumBorder(),
      );

  // ── Results ────────────────────────────────────────────────────────────────

  Widget _results() {
    final query = _query;
    final sort = _sort;
    return RefreshIndicator(
      onRefresh: _gridController.refresh,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _resultsHeader()),
          if (looksLikeBuyingRequest(query)) SliverToBoxAdapter(child: _zenoBanner()),
          ProductGridView(
            // One grid per query and order: a new search is a new grid, so an
            // answer still in flight for the old one has nowhere to land.
            key: ValueKey('search|$query|$sort'),
            sliver: true,
            controller: _gridController,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            fetchPage: (page) => _fetchPage(query, sort, page),
            onTapItem: (item) => _openListing(item as BrokaListing),
            onViewStore: (storeId, _) =>
                Navigator.pushNamed(context, '/store-view', arguments: {'storeId': storeId}),
            emptyStateBuilder: (_) => BrokaEmptyState(
              emoji: '🔍',
              gradient: const [BrokaColors.neonBlue, BrokaColors.neonPurple],
              headline: 'No listings match "$query"',
              body: 'Check the spelling or try fewer words - or let Zeno look for you.',
              action: OutlinedButton.icon(
                onPressed: _askZeno,
                icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                label: const Text('Ask Zeno to find it'),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ],
      ),
    );
  }

  Widget _resultsHeader() {
    final narrow = _narrow;
    final count = _resultCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Row(children: [
        Expanded(
          child: Text(
            count == null ? ' ' : '$count result${count == 1 ? '' : 's'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: BrokaColors.textMid,
                fontSize: narrow ? 12.5 : 13,
                fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 8),
        // Bounded for the same reason as the Category Zone's sort: a bare
        // DropdownButton sizes to its widest item and overflows a 320dp row.
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: narrow ? 150 : 176),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              key: const Key('listing-search-sort'),
              value: _sort,
              isDense: true,
              isExpanded: true,
              alignment: Alignment.centerRight,
              dropdownColor: BrokaColors.bgCard,
              icon: const Icon(Icons.expand_more_rounded, color: BrokaColors.textMid, size: 18),
              style: TextStyle(
                  color: BrokaColors.textMid,
                  fontSize: narrow ? 12.5 : 13,
                  fontWeight: FontWeight.w600),
              selectedItemBuilder: (_) => _sortOptions.values
                  .map((label) => Align(
                        alignment: Alignment.centerRight,
                        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              items: _sortOptions.entries
                  .map((e) => DropdownMenuItem<String?>(
                      value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (v) => setState(() {
                _sort = v;
                _resultCount = null;
              }),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _zenoBanner() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              BrokaColors.neonPurple.withOpacity(0.20),
              BrokaColors.neonBlue.withOpacity(0.12),
            ]),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
          ),
          child: Row(children: [
            const ZenoAvatar(size: 30, glow: true),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                  'This sounds like a specific request - want Zeno to find and negotiate it for you?',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 12.5)),
            ),
            const SizedBox(width: 6),
            TextButton(
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: _askZeno,
              child: const Text('Ask Zeno',
                  style: TextStyle(
                      color: BrokaColors.neonBlue, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ]),
        ),
      );
}
