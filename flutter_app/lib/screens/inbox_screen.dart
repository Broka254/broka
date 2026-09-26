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
import '../main.dart';
import '../features/categories/domain/category_visual.dart';
import '../widgets/chat_parts.dart' show kChatGradient;
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/gradient_button.dart';
import '../models/listing.dart';
import '../services/api_service.dart';
import '../services/last_screen_tracker.dart';
import '../services/local_chat_store.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  // Map of listing_id -> list of threads for that listing
  Map<String, List<Map<String, dynamic>>> _grouped = {};
  List<Map<String, dynamic>> _threads = [];
  bool    _loading = true;
  String? _error;
  // True once a network fetch has failed and what's on screen is (or might
  // be) stale on-device cache rather than a fresh server response.
  bool    _isOffline = false;

  // Currently expanded listing group (null = all collapsed)
  String? _expanded;

  // Single on-device cache slot for the whole inbox list (there's only one
  // inbox per signed-in user, unlike per-thread message caching which needs
  // a key per conversation). Shared with GlobalPollerService, which keeps
  // this warm in the background - see LocalChatStore.inboxListScope.
  static const _inboxScope = LocalChatStore.inboxListScope;

  @override
  void initState() {
    super.initState();
    LastScreenTracker.save('/inbox');
    _loadInbox();
  }

  void _applyThreads(List<Map<String, dynamic>> data) {
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final t in data) {
      final lid = t['listing_id'] as String?;
      if (lid == null) continue;
      grouped.putIfAbsent(lid, () => []).add(t);
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
    setState(() {
      _applyThreads(cached);
      _loading = false;
      _isOffline = true;
    });
  }

  Future<void> _loadInbox() async {
    if (_threads.isEmpty) {
      await _loadCachedInbox();
    }
    if (!mounted) return;
    setState(() { _loading = _threads.isEmpty; _error = null; });
    try {
      final data = await ApiService.getInbox();
      if (!mounted) return;
      setState(() {
        _applyThreads(data);
        _loading = false;
        _isOffline = false;
      });
      unawaited(LocalChatStore.save(
          _inboxScope, data.length > 300 ? data.sublist(0, 300) : data));
    } catch (e) {
      if (!mounted) return;
      if (_threads.isNotEmpty) {
        // Already showing something (fresh or cached) - stay on it rather
        // than replacing a working inbox with an error page. Just flag
        // that it might be stale.
        setState(() { _loading = false; _isOffline = true; });
        return;
      }
      // Nothing cached either - genuinely nothing to show.
      setState(() {
        _loading = false;
        _isOffline = true;
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
    return s.replaceFirst('Exception: ', '');
  }

  int get _totalUnread =>
      _threads.fold(0, (s, t) => s + ((t['unread'] as int?) ?? 0));

  void _openThread(Map<String, dynamic> t) {
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
    Navigator.pushNamed(context, '/negotiate', arguments: {
      'listing':  listing,
      'role':     t['my_role'] as String,
      'buyer_id': t['buyer_id'] as String?,
    }).then((_) => _loadInbox());
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final unread = _totalUnread;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
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
                    trailing: unread > 0 ? _UnreadPill(unread) : null,
                    trailingKey: unread,
                  ),
                ),
                ..._body(media),
              ],
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
      if (_isOffline) SliverToBoxAdapter(child: _buildOfflineBanner()),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + media.padding.bottom),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) {
              final lid     = listingIds[i];
              final threads = _grouped[lid]!;
              final first   = threads.first;
              final unread  = threads.fold(0, (s, t) => s + ((t['unread'] as int?) ?? 0));
              final isExpanded = _expanded == lid;

              return _ListingGroup(
                listingId:   lid,
                listingName: first['listing_name'] as String,
                category:    first['listing_category'] as String,
                price:       (first['listing_price'] as num).toDouble(),
                unreadCount: unread,
                threadCount: threads.length,
                isExpanded:  isExpanded,
                onToggle: () => setState(() =>
                    _expanded = isExpanded ? null : lid),
                threads:     threads,
                onThreadTap: _openThread,
              );
            },
            childCount: listingIds.length,
          ),
        ),
      ),
    ];
  }

  /// A card over the constellation, like Home's notices - not a flat strip.
  Widget _buildOfflineBanner() => Container(
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard.withOpacity(0.92),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: BrokaColors.warning.withOpacity(0.45)),
    ),
    child: const Row(children: [
      Icon(Icons.cloud_off_rounded, size: 16, color: BrokaColors.warning),
      SizedBox(width: 10),
      Expanded(child: Text(
        "You're offline - showing your last saved messages",
        style: TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w600),
      )),
    ]),
  );
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
  final String  category;
  final double  price;
  final int     unreadCount;
  final int     threadCount;
  final bool    isExpanded;
  final VoidCallback onToggle;
  final List<Map<String, dynamic>> threads;
  final void Function(Map<String, dynamic>) onThreadTap;

  const _ListingGroup({
    required this.listingId, required this.listingName,
    required this.category,  required this.price,
    required this.unreadCount, required this.threadCount,
    required this.isExpanded,  required this.onToggle,
    required this.threads,     required this.onThreadTap,
  });

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
    // lit with the brand glow.
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: unreadCount > 0
              ? BrokaColors.neonBlue.withOpacity(0.55)
              : BrokaColors.border,
          width: unreadCount > 0 ? 1.4 : 1,
        ),
        boxShadow: unreadCount > 0
            ? [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.14), blurRadius: 16)]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        // ── Group header (tap to expand/collapse) ──
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              // Listing icon
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
                child: Center(child: Text(_emoji(category),
                    style: const TextStyle(fontSize: 22))),
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
              AnimatedRotation(
                turns: isExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: BrokaColors.textMid, size: 22),
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
  const _ThreadRow({required this.thread, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final lastMsg    = thread['last_message']  as String;
    final lastRole   = thread['last_role']     as String;
    final unread     = (thread['unread']       as int?) ?? 0;
    final lastSeen   = (thread['last_message_seen'] as bool?) ?? false;
    final timeAgo    = thread['time_ago']      as String;
    final myRole     = thread['my_role']       as String;
    final sellerName = thread['seller_name']   as String?;
    final buyerName  = thread['buyer_name']    as String?;
    final avatarB64  = thread['counterpart_avatar'] as String?;
    final isOnline   = thread['is_online']     as bool? ?? false;

    // Show name of the OTHER party
    final otherName = myRole == 'seller'
        ? (buyerName ?? 'Buyer')
        : (sellerName ?? 'Seller');

    final initials = otherName.isNotEmpty ? otherName[0].toUpperCase() : '?';

    final roleColor = lastRole == 'broker'
        ? BrokaColors.gold
        : lastRole == 'buyer' ? BrokaColors.neonBlue : BrokaColors.neonGreen;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
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
                child: avatarB64 != null && avatarB64.isNotEmpty
                    ? Image.memory(base64Decode(avatarB64), fit: BoxFit.cover)
                    : Center(child: Text(initials, style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700,
                        fontSize: 16))),
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
              Container(width: 5, height: 5, decoration: BoxDecoration(
                  shape: BoxShape.circle, color: roleColor)),
              const SizedBox(width: 5),
              Expanded(child: Text(lastMsg, style: TextStyle(
                  color: unread > 0 ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontSize: 12,
                  fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.normal),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (lastRole == myRole)
                Icon(
                  lastSeen ? Icons.done_all_rounded : Icons.done_rounded,
                  size: 13,
                  color: lastSeen ? BrokaColors.neonBlue : BrokaColors.textLow,
                ),
            ]),
          ])),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right_rounded,
              color: BrokaColors.textLow, size: 18),
        ]),
      ),
    );
  }
}
