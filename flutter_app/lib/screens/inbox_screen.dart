// BROKA - Inbox Screen
// Grouped by listing: general inbox -> per-listing sub-inbox
// Seller selling 5 items sees 5 groups; each group contains all buyer threads.
//
// On Home's visual system (2026-09-26), like the Menu next to it in the
// bottom bar: the constellation, the shared collapsing header, and cards
// like Home's. It was the last tab on a flat grey app bar over a plain
// background.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../features/categories/domain/category_visual.dart';
import '../features/stores/presentation/widgets/broka_default_logo.dart';
import '../widgets/chat_parts.dart' show kChatGradient;
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/delivery_nudge.dart';
import '../widgets/gradient_button.dart';
import '../models/listing.dart';
import '../services/api_service.dart';
import '../widgets/broka_image.dart';
import '../services/chat_deletion.dart';
import '../services/chat_screen_memory.dart';
import '../services/last_screen_tracker.dart';
import '../services/global_poller_service.dart';
import '../services/local_chat_store.dart';
import '../core/cache/screen_cache.dart';
import '../core/errors/user_facing_error.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> with WidgetsBindingObserver {
  // Map of listing_id -> list of threads for that listing
  Map<String, List<Map<String, dynamic>>> _grouped = {};
  List<Map<String, dynamic>> _threads = [];
  bool    _loading = true;
  String? _error;
  // True only when a fetch has actually failed with a network error and
  // what's on screen is (or might be) stale on-device cache. Showing the
  // cache on open is NOT being offline - that painted "You're offline"
  // over a working connection whenever the first fetch was slow or the
  // server answered an error, and nothing cleared it again.
  bool    _isOffline = false;
  // The last refresh failed for a non-network reason (a server error,
  // say): stale, but not "offline", and the banner must not claim it is.
  bool    _refreshFailed = false;
  Timer?  _retryTimer;

  /// How often a stale inbox quietly tries again, so coming back online
  /// (or the server recovering) clears the banner by itself instead of
  /// waiting for a pull-to-refresh the user may never think of.
  static const _retryEvery = Duration(seconds: 15);

  // Currently expanded listing group (null = all collapsed). Remembered
  // with the scroll position across visits (_InboxMemory): the Inbox is a
  // pushed route, rebuilt on every open, and used to come back collapsed
  // and at the top every time.
  String? _expanded;
  late final ScrollController _scroll;

  // Chats picked for deleting (ChatDeletion.keyOf). A long press on a chat
  // - or on a listing's card, for all of its chats - starts picking; while
  // any is picked a tap picks or drops instead of opening.
  final Set<String> _selected = {};
  bool _deleting = false;
  bool get _selecting => _selected.isNotEmpty;

  // Per-account inbox cache. Shared with GlobalPollerService, which keeps
  // this warm in the background - see LocalChatStore.inboxListScopeFor.
  // The old single slot showed the previous account's conversations when
  // someone else signed in on the same phone.
  String get _inboxScope =>
      LocalChatStore.inboxListScopeFor(ApiService.currentUserId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LastScreenTracker.save('/inbox');
    final memory = _InboxMemory.forUser(ApiService.currentUserId);
    _expanded = memory?.expanded;
    _scroll = ScrollController(initialScrollOffset: memory?.offset ?? 0);
    GlobalPollerService.instance.inbox.addListener(_onPollerInbox);
    _loadInbox();
  }

  @override
  void dispose() {
    _InboxMemory.save(ApiService.currentUserId, _expanded,
        _scroll.hasClients ? _scroll.offset : 0);
    GlobalPollerService.instance.inbox.removeListener(_onPollerInbox);
    _scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    super.dispose();
  }

  /// The poller's sweep (every ~7s while BROKA is in front) already holds
  /// this account's inbox: shown here, so the open Inbox stays current
  /// without a request of its own - and a stale banner clears as soon as
  /// any sweep reaches the server.
  void _onPollerInbox() {
    final snap = GlobalPollerService.instance.inbox.value;
    if (snap == null || !mounted) return;
    if (snap.userId == null || snap.userId != ApiService.currentUserId) return;
    // Older loads still in flight must not land over this.
    _loadSeq++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _retries = 0;
    setState(() {
      if (snap.changed || _threads.isEmpty) {
        _applyThreads([for (final t in snap.threads) Map<String, dynamic>.from(t)]);
      }
      _loading = false;
      _error = null;
      _isOffline = false;
      _refreshFailed = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back in front after time away (or off the network): what is on
    // screen may be stale. main.dart's resume handler runs the poller's
    // catch-up, whose answer arrives here through _onPollerInbox - asking
    // again here was the same request twice. Without a running poller
    // (signed in moments ago, tests), fetch as before.
    if (state == AppLifecycleState.resumed) {
      if (!GlobalPollerService.instance.isRunning) unawaited(_loadInbox());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // No quiet retries while the app is away - the poller and pushes
      // own the background, and a 15s timer there only costs battery.
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  bool _isNetworkError(Object e) {
    final s = e.toString();
    return s.contains('SocketException') || s.contains('Failed host lookup') ||
        s.contains('Connection refused') || s.contains('Connection failed') ||
        s.contains('Network is unreachable') || s.contains('TimeoutException');
  }

  // Retries in a row that failed (reset by any answer).
  int _retries = 0;

  /// One quiet retry, later each time: 15, 30, then every 60 seconds.
  ///
  /// None while the poller runs: its sweep fetches this same inbox and
  /// hands every success to [_onPollerInbox], which clears the banner -
  /// a timer of our own was the same request a second time. It used to
  /// retry every 15 seconds, for as long as the server stayed down.
  void _armRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (GlobalPollerService.instance.isRunning) return;
    final delay = _retryEvery * (1 << (_retries >= 2 ? 2 : _retries));
    _retries++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_loadInbox());
    });
  }

  void _applyThreads(List<Map<String, dynamic>> data) {
    // An answer that left the server before a delete must not bring the
    // deleted chat back.
    data = ChatDeletion.visible(data);
    final keys = {for (final t in data) ChatDeletion.keyOf(t)};
    _selected.removeWhere((k) => !keys.contains(k));
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final t in data) {
      // Store-general threads have no listing: group by store instead of
      // dropping them (the old "never in the inbox" bug, client half).
      final key = t['thread_type'] == 'store'
          ? 'store:${t['store_id']}'
          : t['listing_id'] as String?;
      if (key == null) continue;
      grouped.putIfAbsent(key, () => []).add(t);
    }
    _threads = data;
    _grouped = grouped;
    if (grouped.length == 1) _expanded = grouped.keys.first;
  }

  /// Paints whatever was cached on-device the instant this screen opens,
  /// before the network call even starts - so a spotty or absent
  /// connection shows your last-known inbox instead of a blank/error
  /// screen. Mirrors the same LocalChatStore pattern the chat threads
  /// themselves already use.
  Future<void> _loadCachedInbox() async {
    final cached = await LocalChatStore.load(_inboxScope);
    if (cached.isEmpty || !mounted || _threads.isNotEmpty) return;
    // First paint only. Whether we are offline is a question only the
    // fetch that follows can answer - this used to declare the user
    // offline the moment saved messages were shown, online or not.
    setState(() {
      _applyThreads(cached);
      _loading = false;
    });
  }

  // Overlapping loads (the retry timer, a resume, a pull-to-refresh)
  // must not let a slow older answer overwrite a fresher one.
  int _loadSeq = 0;

  Future<void> _loadInbox() async {
    final seq = ++_loadSeq;
    if (_threads.isEmpty) {
      await _loadCachedInbox();
    }
    if (!mounted || seq != _loadSeq) return;
    setState(() { _loading = _threads.isEmpty; _error = null; });
    try {
      final data = await ApiService.getInbox();
      if (!mounted || seq != _loadSeq) return;
      _retryTimer?.cancel();
      _retryTimer = null;
      _retries = 0;
      setState(() {
        _applyThreads(data);
        _loading = false;
        _isOffline = false;
        _refreshFailed = false;
      });
      unawaited(LocalChatStore.save(
          _inboxScope, data.length > 300 ? data.sublist(0, 300) : data));
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      if (_threads.isNotEmpty) {
        // Already showing something (fresh or cached) - stay on it rather
        // than replacing a working inbox with an error page. Say what
        // actually happened: offline only for a network failure, and
        // keep trying in the background either way.
        setState(() {
          _loading = false;
          _isOffline = _isNetworkError(e);
          _refreshFailed = !_isOffline;
        });
        _armRetry();
        return;
      }
      // Nothing cached either - genuinely nothing to show.
      setState(() {
        _loading = false;
        _isOffline = _isNetworkError(e);
        _refreshFailed = !_isOffline;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('Failed host lookup') ||
        s.contains('Connection refused') || s.contains('Connection failed')) {
      return "No internet connection.\nPull down to try again once you're back online.";
    }
    if (s.contains('TimeoutException')) {
      return 'The connection timed out.\nPull down to try again.';
    }
    return userFacingError(e);
  }

  int get _totalUnread =>
      _threads.fold(0, (s, t) => s + ((t['unread'] as int?) ?? 0));

  // ── Picking and deleting chats ───────────────────────────────────────────

  void _toggle(Map<String, dynamic> t) {
    final key = ChatDeletion.keyOf(t);
    if (key == null) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  /// A listing's card: all of its chats, or none if all were picked.
  void _toggleGroup(List<Map<String, dynamic>> threads) {
    final keys = [for (final t in threads) ChatDeletion.keyOf(t)].whereType<String>().toList();
    if (keys.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (keys.every(_selected.contains)) {
        _selected.removeAll(keys);
      } else {
        _selected.addAll(keys);
      }
    });
  }

  void _cancelSelection() => setState(_selected.clear);

  Future<void> _deleteSelected() async {
    if (_deleting || _selected.isEmpty) return;
    final picked = [
      for (final t in _threads)
        if (_selected.contains(ChatDeletion.keyOf(t))) t,
    ];
    if (picked.isEmpty) return;
    final n = picked.length;
    final who = n == 1 ? _otherNameOf(picked.first) : null;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: BrokaColors.danger.withOpacity(0.45))),
        title: Text(n == 1 ? 'Delete this chat?' : 'Delete $n chats?',
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 17)),
        content: Text(
          '${n == 1 ? 'The messages and calls' : 'Their messages and calls'} will be removed '
          'from your inbox, Zeno\'s notes included. '
          '${who != null ? '$who keeps' : 'The other person keeps'} their copy, and if '
          '${who != null ? 'they write' : 'someone writes'} again the chat comes back '
          'with just the new messages.',
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            key: const Key('inbox-confirm-delete'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete',
                style: TextStyle(color: BrokaColors.danger, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _deleting = true);
    final results = await Future.wait(picked.map((t) async {
      try {
        await ChatDeletion.delete(t);
        return true;
      } catch (_) {
        return false;
      }
    }));
    if (!mounted) return;
    final gone = {
      for (var i = 0; i < picked.length; i++)
        if (results[i]) ChatDeletion.keyOf(picked[i]),
    };
    final failed = results.where((ok) => !ok).length;
    setState(() {
      _deleting = false;
      _selected.removeAll(gone);
      if (failed == 0) _selected.clear();
      _applyThreads([for (final t in _threads) if (!gone.contains(ChatDeletion.keyOf(t))) t]);
    });
    unawaited(LocalChatStore.save(
        _inboxScope, _threads.length > 300 ? _threads.sublist(0, 300) : _threads));
    final done = gone.length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: failed > 0 ? BrokaColors.danger : null,
      content: Text(failed == 0
          ? (done == 1 ? 'Chat deleted' : '$done chats deleted')
          : "Couldn't delete $failed chat${failed == 1 ? '' : 's'} - "
              'check your connection and try again.'),
    ));
  }

  /// The name a chat's row shows for the other person.
  static String _otherNameOf(Map<String, dynamic> t) {
    final myRole = t['my_role'] as String?;
    final buyer = t['buyer_name'] as String?;
    final seller = t['seller_name'] as String?;
    if (t['thread_type'] == 'store') {
      return (t['counterpart_name'] as String?) ??
          (myRole == 'seller' ? (buyer ?? 'The buyer') : (seller ?? 'The store'));
    }
    return myRole == 'seller' ? (buyer ?? 'The buyer') : (seller ?? 'The seller');
  }

  /// Opens the thread on the screen the user was last on for it - Zeno's
  /// room or the direct chat - unless only the other one has something new
  /// (ChatScreenMemory.choose). It always opened Zeno's room, so someone
  /// who had moved to the direct chat had to switch back every time.
  Future<void> _openThread(Map<String, dynamic> t) async {
    if (t['thread_type'] == 'store') {
      Navigator.pushNamed(context, '/direct-chat', arguments: {
        'storeId': t['store_id'],
        'storeName': t['store_name'] ?? t['listing_name'],
        'storeLogo': t['store_logo'] ?? t['listing_image'],
        'role': t['my_role'],
        'buyer_id': t['buyer_id'],
        'seller_id': t['seller_id'],
        'counterpartName': t['counterpart_name'],
      }).then((_) => _loadInbox());
      return;
    }
    final listing = Listing(
      id:           t['listing_id']       as String,
      name:         t['listing_name']     as String,
      category:     t['listing_category'] as String,
      price:        (t['listing_price']   as num).toDouble(),
      locationName: t['location_name']    as String?,
      listingType:  t['listing_type']     as String,
      status:       'active',
      views:        0,
      sellerId:     t['seller_id']        as String?,
      sellerName:   t['seller_name']      as String?,
    );
    final buyerId = t['buyer_id'] as String?;
    final screen = ChatScreenMemory.choose(
      remembered:   await ChatScreenMemory.recall(listing.id, buyerId),
      directUnread: (t['unread'] as int?) ?? 0,
      zenoUnread:   (t['zeno_unread'] as int?) ?? 0,
    );
    if (!mounted) return;
    Navigator.pushNamed(context, screen.route, arguments: {
      'listing':  listing,
      'role':     t['my_role'] as String,
      'buyer_id': buyerId,
    }).then((_) => _loadInbox());
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final unread = _totalUnread;
    // Back while picking chats puts the picks down, as in any messenger.
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _cancelSelection();
      },
      child: Scaffold(
      backgroundColor: BrokaColors.bg,
      bottomNavigationBar: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, a) => SizeTransition(
            sizeFactor: a, axisAlignment: -1, child: FadeTransition(opacity: a, child: child)),
        child: _selecting
            ? _SelectionBar(
                key: const Key('inbox-selection-bar'),
                count: _selected.length,
                busy: _deleting,
                onCancel: _cancelSelection,
                onDelete: _deleteSelected,
              )
            : const SizedBox.shrink(),
      ),
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: BrokaColors.gold,
            backgroundColor: BrokaColors.bgCard,
            displacement: 72,
            onRefresh: _loadInbox,
            child: CustomScrollView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: CollapsingScreenHeader(
                    title: 'Inbox',
                    emoji: '💬',
                    gradient: kChatGradient,
                    onBack: () => Navigator.maybePop(context),
                    narrow: media.size.width < 360,
                    textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                    // Calls sit with the conversations they belong to.
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (unread > 0) ...[
                        _UnreadPill(unread),
                        const SizedBox(width: 8),
                      ],
                      _CallHistoryButton(
                        key: const Key('inbox-calls'),
                        onTap: () => Navigator.pushNamed(context, '/call-history'),
                      ),
                    ]),
                    trailingKey: unread,
                  ),
                ),
                if (ApiService.currentUserId != null)
                  const SliverToBoxAdapter(
                    child: DeliveryNudge(place: DeliveryNudgePlace.inbox,
                        margin: EdgeInsets.fromLTRB(16, 4, 16, 8)),
                  ),
                ..._body(media),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  List<Widget> _body(MediaQueryData media) {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator(
              color: BrokaColors.gold, strokeWidth: 1.5)),
        ),
      ];
    }

    if (_error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: BrokaEmptyState(
            emoji: '📡',
            gradient: kChatGradient,
            headline: "Couldn't load your inbox",
            body: _error!,
            action: GradientButton(
              onPressed: _loadInbox,
              colors: kChatGradient,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text('Retry', style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          )),
        ),
      ];
    }

    if (_grouped.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: BrokaEmptyState(
            emoji: '💬',
            gradient: kChatGradient,
            headline: 'No conversations yet',
            body: 'Find something you like and start a deal - '
                'your conversations with sellers and buyers land here.',
            action: GradientButton(
              onPressed: () => Navigator.pushNamedAndRemoveUntil(
                  context, '/home', (_) => false),
              colors: kChatGradient,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text('Browse listings', style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14, color: Colors.white)),
              ),
            ),
          )),
        ),
      ];
    }

    final listingIds = _grouped.keys.toList();
    return [
      if (_isOffline || _refreshFailed)
        SliverToBoxAdapter(child: _buildOfflineBanner()),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) {
              final lid     = listingIds[i];
              final threads = _grouped[lid]!;
              final first   = threads.first;
              final unread  = threads.fold(0, (s, t) => s + ((t['unread'] as int?) ?? 0));
              final isExpanded = _expanded == lid;
              final isStore = first['thread_type'] == 'store';
              final image = isStore
                  ? ((first['store_photo'] ?? first['store_logo'] ?? first['listing_image']) as String?)
                  : (first['listing_image'] as String?);

              return _ListingGroup(
                listingId:   lid,
                listingName: first['listing_name'] as String,
                listingImage: image,
                category:    first['listing_category'] as String,
                price:       (first['listing_price'] as num?)?.toDouble() ?? 0,
                isStore:     isStore,
                unreadCount: unread,
                threadCount: threads.length,
                isExpanded:  isExpanded,
                // While picking, a card's tap picks all of its chats; the
                // arrow still opens it, to pick some of them.
                onToggle: _selecting
                    ? () => _toggleGroup(threads)
                    : () => setState(() => _expanded = isExpanded ? null : lid),
                onExpand: () => setState(() => _expanded = isExpanded ? null : lid),
                onLongPress: () => _toggleGroup(threads),
                threads:     threads,
                onThreadTap: (t) {
                  if (_selecting) {
                    _toggle(t);
                  } else {
                    unawaited(_openThread(t));
                  }
                },
                onThreadLongPress: _toggle,
                selecting:   _selecting,
                isSelected:  (t) => _selected.contains(ChatDeletion.keyOf(t)),
              );
            },
            childCount: listingIds.length,
          ),
        ),
      ),
      // How to clear old chats out, said once at the foot of the list.
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 6, 24, 24 + media.padding.bottom),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _selecting ? 0 : 1,
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.touch_app_outlined, size: 13, color: BrokaColors.textMid),
              SizedBox(width: 6),
              Flexible(
                child: Text('Press and hold a chat to delete it',
                    key: Key('inbox-delete-hint'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
              ),
            ]),
          ),
        ),
      ),
    ];
  }

  /// A card over the constellation, like Home's notices - not a flat strip.
  /// "Offline" is claimed only for a network failure; a server error says
  /// so instead. Either way it retries on its own (see _armRetry) and can
  /// be tapped to retry now.
  Widget _buildOfflineBanner() => GestureDetector(
    onTap: () => unawaited(_loadInbox()),
    child: Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.warning.withOpacity(0.45)),
      ),
      child: Row(children: [
        Icon(_isOffline ? Icons.cloud_off_rounded : Icons.cloud_sync_rounded,
            size: 16, color: BrokaColors.warning),
        const SizedBox(width: 10),
        Expanded(child: Text(
          _isOffline
              ? "You're offline - showing your last saved messages"
              : "Couldn't refresh - showing your last saved messages",
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w600),
        )),
        const SizedBox(width: 8),
        const Text('Retry', style: TextStyle(
            color: BrokaColors.warning, fontSize: 12.5, fontWeight: FontWeight.w700)),
      ]),
    ),
  );
}

/// Opens the call history. A labelled pill, not a bare phone icon: the
/// icon alone did not say where it went, and "Calls" alone did not say
/// it was the history - so it carries both, with the full name for
/// tooltips and screen readers.
class _CallHistoryButton extends StatelessWidget {
  const _CallHistoryButton({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The full words wherever they fit; on a narrow phone the pill
    // shortens to "Calls" (tooltip and semantics keep the full name) so
    // the header cannot overflow next to the unread pill.
    final narrow = MediaQuery.sizeOf(context).width < 360;
    return Semantics(
      button: true,
      label: 'Call history',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Call history',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: CollapsingScreenHeader.control,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard.withOpacity(0.86),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.call_rounded, size: 16, color: BrokaColors.textMid),
              const SizedBox(width: 6),
              Text(narrow ? 'Calls' : 'Call history', style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "3 new" in the header - the brand gradient, like the header's other
/// lit controls.
class _UnreadPill extends StatelessWidget {
  const _UnreadPill(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$count unread',
    excludeSemantics: true,
    child: Container(
      height: CollapsingScreenHeader.control,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: kChatGradient),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.3), blurRadius: 12)],
      ),
      child: Text('$count new', style: const TextStyle(
          color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
    ),
  );
}

// ── Listing Group (accordion) ─────────────────────────────────────────────────

class _ListingGroup extends StatelessWidget {
  final String  listingId;
  final String  listingName;
  final String? listingImage;
  final String  category;
  final double  price;
  final bool    isStore;
  final int     unreadCount;
  final int     threadCount;
  final bool    isExpanded;
  final VoidCallback onToggle;
  final VoidCallback? onExpand;
  final VoidCallback? onLongPress;
  final List<Map<String, dynamic>> threads;
  final void Function(Map<String, dynamic>) onThreadTap;
  final void Function(Map<String, dynamic>)? onThreadLongPress;
  final bool selecting;
  final bool Function(Map<String, dynamic>)? isSelected;

  const _ListingGroup({
    required this.listingId, required this.listingName,
    this.listingImage, this.isStore = false,
    required this.category,  required this.price,
    required this.unreadCount, required this.threadCount,
    required this.isExpanded,  required this.onToggle,
    required this.threads,     required this.onThreadTap,
    this.onExpand, this.onLongPress, this.onThreadLongPress,
    this.selecting = false, this.isSelected,
  });

  int get _picked => isSelected == null ? 0 : threads.where(isSelected!).length;

  // Category-alignment pass (2026-09-18): this four-case switch only
  // knew Vehicles/Property/Electronics/Livestock, so eleven of the
  // backend's sixteen top-level categories rendered as a generic box.
  // features/categories/domain/category_visual.dart is the one table now.
  String _emoji(String cat) => CategoryVisuals.emojiFor(cat);

  String _fmt(double v) => 'KES ${v.toStringAsFixed(0).replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}';

  @override
  Widget build(BuildContext context) {
    // A card like Home's over the constellation; one with unread messages
    // lit with the brand glow, one with chats picked for deleting in red.
    final picked = _picked;
    return AnimatedContainer(
      key: Key('inbox-group-$listingId'),
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: picked > 0
            ? Color.alphaBlend(BrokaColors.danger.withOpacity(0.07), BrokaColors.bgCard)
            : BrokaColors.bgCard.withOpacity(0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: picked > 0
              ? BrokaColors.danger.withOpacity(0.6)
              : unreadCount > 0
                  ? BrokaColors.neonBlue.withOpacity(0.55)
                  : BrokaColors.border,
          width: picked > 0 || unreadCount > 0 ? 1.4 : 1,
        ),
        boxShadow: unreadCount > 0 && picked == 0
            ? [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.14), blurRadius: 16)]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        // ── Group header (tap to expand/collapse; long press picks all) ──
        InkWell(
          onTap: onToggle,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              if (selecting) ...[
                _PickMark(
                  picked: picked == threads.length && picked > 0,
                  partial: picked > 0 && picked < threads.length,
                ),
                const SizedBox(width: 10),
              ],
              // The listing's own photo, in the same 46dp circle the
              // category icon used to fill - same size, same shape. The
              // category emoji is only the fallback for a listing with
              // no photo (or one that will not load).
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [
                    kChatGradient.first.withOpacity(unreadCount > 0 ? 0.35 : 0.16),
                    kChatGradient.last.withOpacity(unreadCount > 0 ? 0.25 : 0.08),
                  ]),
                  border: Border.all(
                    color: unreadCount > 0
                        ? BrokaColors.neonBlue.withOpacity(0.7)
                        : BrokaColors.border),
                ),
                child: ClipOval(child: BrokaImage(
                  listingImage,
                  fit: BoxFit.cover,
                  width: 46, height: 46,
                  placeholder: isStore
                      ? const BrokaDefaultLogo()
                      : Center(child: Text(_emoji(category),
                          style: const TextStyle(fontSize: 22))),
                )),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(listingName, style: TextStyle(
                    color: unreadCount > 0
                        ? BrokaColors.textHigh : BrokaColors.textMid,
                    fontWeight: unreadCount > 0
                        ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 14),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                // Wraps rather than overflowing on a small phone at a large
                // text size.
                Wrap(spacing: 8, children: [
                  if (isStore)
                    const Text('Store', style: TextStyle(
                        color: BrokaColors.gold,
                        fontSize: 11.5, fontWeight: FontWeight.w700))
                  else
                    Text(_fmt(price), style: const TextStyle(
                        color: BrokaColors.neonGreen,
                        fontSize: 11.5, fontWeight: FontWeight.w700)),
                  Text('$threadCount conversation${threadCount == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: BrokaColors.textMid, fontSize: 11.5)),
                ]),
              ])),
              // Unread badge
              if (unreadCount > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: BrokaColors.danger,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$unreadCount', style: const TextStyle(
                      color: Colors.white, fontSize: 11,
                      fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
              ],
              GestureDetector(
                // While picking the card's tap picks its chats, so the
                // arrow is what still opens it.
                onTap: selecting ? onExpand : null,
                behavior: HitTestBehavior.opaque,
                child: AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      color: BrokaColors.textMid, size: 22),
                ),
              ),
            ]),
          ),
        ),
        // ── Thread list (expanded) ──
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: isExpanded
              ? Column(children: [
                  Divider(color: BrokaColors.border.withOpacity(0.7), height: 1),
                  ...threads.map((t) => _ThreadRow(
                    thread: t,
                    onTap: () => onThreadTap(t),
                    onLongPress: onThreadLongPress == null ? null : () => onThreadLongPress!(t),
                    selecting: selecting,
                    selected: isSelected?.call(t) ?? false,
                  )),
                ])
              : const SizedBox.shrink(),
        ),
      ]),
    );
  }
}

// ── Thread row inside a group ─────────────────────────────────────────────────

class _ThreadRow extends StatelessWidget {
  final Map<String, dynamic> thread;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selecting;
  final bool selected;
  const _ThreadRow({
    required this.thread,
    required this.onTap,
    this.onLongPress,
    this.selecting = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final lastMsg    = thread['last_message']  as String;
    final lastRole   = thread['last_role']     as String;
    final unread     = (thread['unread']       as int?) ?? 0;
    final lastSeen   = (thread['last_message_seen'] as bool?) ?? false;
    final lastDelivered =
        (thread['last_message_delivered'] as bool?) ?? false;
    final timeAgo    = thread['time_ago']      as String;
    final myRole     = thread['my_role']       as String;
    final sellerName = thread['seller_name']   as String?;
    final buyerName  = thread['buyer_name']    as String?;
    final avatarSource = (thread['counterpart_photo'] as String?)?.isNotEmpty == true
        ? thread['counterpart_photo'] as String
        : (thread['counterpart_avatar'] as String?);
    final isOnline   = thread['is_online']     as bool? ?? false;

    // Show name of the OTHER party (a store thread names the shop itself
    // for the buyer, the buyer for the owner).
    final otherName = thread['thread_type'] == 'store'
        ? ((thread['counterpart_name'] as String?) ??
            (myRole == 'seller' ? (buyerName ?? 'Buyer') : (sellerName ?? 'Seller')))
        : myRole == 'seller'
            ? (buyerName ?? 'Buyer')
            : (sellerName ?? 'Seller');

    final initials = otherName.isNotEmpty ? otherName[0].toUpperCase() : '?';

    final roleColor = lastRole == 'broker'
        ? BrokaColors.gold
        : lastRole == 'buyer' ? BrokaColors.neonBlue : BrokaColors.neonGreen;

    // A call row is a conversation entry like any other, not a
    // notification pasted into the list: its content is the raw outcome
    // verb the backend stored ("missed"), which used to surface here as
    // a "Missed call received" alert line. It now reads as a plain call
    // label and carries its state the way messages do - bold with the
    // unread badge while unseen, plain once seen, and the sent /
    // delivered / read ticks when the call was mine.
    final isCall = thread['last_msg_type'] == 'call';
    final outcome = lastMsg.trim().toLowerCase();
    final isMissed = isCall && (outcome == 'missed' || outcome == 'cancelled');
    final previewText = !isCall
        ? lastMsg
        : switch (outcome) {
            'missed' || 'cancelled' => 'Missed call',
            'declined' => 'Call declined',
            'failed_to_connect' => "Call didn't connect",
            'completed' => 'Call',
            _ => 'Call',
          };
    final previewIcon = !isCall
        ? null
        : isMissed
            ? Icons.call_missed_rounded
            : (lastRole == myRole
                ? Icons.call_made_rounded
                : Icons.call_received_rounded);

    final key = ChatDeletion.keyOf(thread);
    return Semantics(
      selected: selecting ? selected : null,
      child: InkWell(
      key: key == null ? null : Key('inbox-thread-$key'),
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        color: selected ? BrokaColors.danger.withOpacity(0.10) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          if (selecting) ...[
            _PickMark(picked: selected),
            const SizedBox(width: 10),
          ],
          // Avatar with online dot
          Stack(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: unread > 0
                    ? kChatGradient
                    : [BrokaColors.bgMid, BrokaColors.bgMid]),
                border: Border.all(
                  color: unread > 0 ? BrokaColors.neonBlue : BrokaColors.border,
                  width: unread > 0 ? 2 : 1,
                ),
              ),
              child: ClipOval(
                child: BrokaImage(
                  avatarSource,
                  fit: BoxFit.cover,
                  width: 42,
                  height: 42,
                  placeholder: Center(child: Text(initials, style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700,
                      fontSize: 16))),
                ),
              ),
            ),
            Positioned(bottom: 1, right: 1,
              child: Container(
                width: 11, height: 11,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOnline ? BrokaColors.neonGreen : BrokaColors.textLow,
                  border: Border.all(color: BrokaColors.bgCard, width: 1.5),
                ),
              ),
            ),
            if (unread > 0)
              Positioned(top: 0, right: 0, child: Container(
                width: 16, height: 16,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: BrokaColors.danger),
                child: Center(child: Text('$unread', style: const TextStyle(
                    color: Colors.white, fontSize: 9,
                    fontWeight: FontWeight.w800))),
              )),
          ]),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(otherName, style: TextStyle(
                  color: unread > 0 ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text(timeAgo, style: TextStyle(
                  color: unread > 0 ? BrokaColors.neonBlue : BrokaColors.textMid,
                  fontSize: 10.5,
                  fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w400)),
            ]),
            const SizedBox(height: 3),
            Row(children: [
              if (previewIcon != null) ...[
                Icon(previewIcon, size: 13,
                    color: isMissed && unread > 0
                        ? BrokaColors.danger
                        : BrokaColors.textMid),
                const SizedBox(width: 5),
              ] else ...[
                Container(width: 5, height: 5, decoration: BoxDecoration(
                    shape: BoxShape.circle, color: roleColor)),
                const SizedBox(width: 5),
              ],
              Expanded(child: Text(previewText, style: TextStyle(
                  color: unread > 0 ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontSize: 12,
                  fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.normal),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (lastRole == myRole)
                // The same tick grammar as the chat (message_receipt.dart):
                // single dull tick = sent, dull double = received but
                // unread, purple double = received and read. This row used
                // to draw the read tick blue while the chat drew it purple,
                // so one state wore two colours depending on the screen;
                // the sent tick was also textLow, the near-invisible shade
                // the chat already retired for these ticks.
                Icon(
                  (lastSeen || lastDelivered)
                      ? Icons.done_all_rounded
                      : Icons.done_rounded,
                  size: 13,
                  color: lastSeen
                      ? BrokaColors.neonPurple
                      : BrokaColors.textMid,
                ),
            ]),
          ])),
          const SizedBox(width: 6),
          if (!selecting)
            const Icon(Icons.chevron_right_rounded,
                color: BrokaColors.textLow, size: 18),
        ]),
      ),
      ),
    );
  }
}

/// The round tick a picked chat (or a fully picked card) wears.
class _PickMark extends StatelessWidget {
  const _PickMark({required this.picked, this.partial = false});
  final bool picked;
  final bool partial;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: picked
              ? const LinearGradient(colors: [BrokaColors.danger, BrokaColors.neonPink])
              : null,
          color: picked ? null : Colors.transparent,
          border: Border.all(
            color: picked || partial ? BrokaColors.danger : BrokaColors.textMid,
            width: 1.6,
          ),
          boxShadow: picked
              ? [BoxShadow(color: BrokaColors.danger.withOpacity(0.35), blurRadius: 8)]
              : null,
        ),
        child: picked
            ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
            : partial
                ? const Icon(Icons.remove_rounded, size: 14, color: BrokaColors.danger)
                : null,
      );
}

/// The bar along the bottom while chats are picked: how many, put them
/// down, or delete them.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    super.key,
    required this.count,
    required this.busy,
    required this.onCancel,
    required this.onDelete,
  });

  final int count;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.96),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: BrokaColors.danger.withOpacity(0.45)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 24, offset: const Offset(0, 8)),
              BoxShadow(color: BrokaColors.danger.withOpacity(0.12), blurRadius: 18),
            ],
          ),
          child: Row(children: [
            IconButton(
              key: const Key('inbox-selection-cancel'),
              tooltip: 'Cancel',
              onPressed: busy ? null : onCancel,
              icon: const Icon(Icons.close_rounded, color: BrokaColors.textHigh),
            ),
            Expanded(
              child: Text(
                count == 1 ? '1 chat selected' : '$count chats selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
            FilledButton.icon(
              key: const Key('inbox-delete-selected'),
              onPressed: busy ? null : onDelete,
              style: FilledButton.styleFrom(
                backgroundColor: BrokaColors.danger,
                foregroundColor: Colors.white,
                disabledBackgroundColor: BrokaColors.danger.withOpacity(0.4),
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              icon: busy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Delete', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
      );
}

/// Which group was open and how far down the Inbox was, per account, for
/// the next visit this session. In memory only: after a restart the Inbox
/// opens at the top, as any app does.
class _InboxMemory {
  _InboxMemory(this.userId, this.expanded, this.offset);
  final String? userId;
  final String? expanded;
  final double offset;

  static _InboxMemory? _last;

  /// Off under `flutter test` (like ScreenCache): each test opens a fresh
  /// Inbox and must not inherit the last test's open group.
  static bool enabled = !ScreenCache.isFlutterTest;

  static _InboxMemory? forUser(String? userId) {
    final m = _last;
    return enabled && m != null && m.userId == userId ? m : null;
  }

  static void save(String? userId, String? expanded, double offset) {
    if (enabled) _last = _InboxMemory(userId, expanded, offset);
  }
}
