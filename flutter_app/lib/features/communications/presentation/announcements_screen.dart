// BROKA - Announcements centre.
//
// Admin-published service communications (maintenance windows, incidents,
// product news) as their own feed - not chat conversations, and not mixed
// into the negotiation inbox. The feed comes from GET /communications, the
// unread count behind the badge from GET /communications/unread-count, and
// opening an announcement acknowledges it via POST .../read - all through
// AnnouncementsState, which the Menu badge and the push handler share.
//
// On Home's visual system, like the Inbox next to it: the constellation,
// the shared collapsing header, and cards like Home's.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../services/last_screen_tracker.dart';
import '../../../services/notification_service.dart';
import '../../../utils/auth_gate.dart';
import '../../../widgets/chat_parts.dart' show kChatGradient;
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/gradient_button.dart';
import '../domain/models/announcement.dart';
import 'announcement_detail_screen.dart';
import 'announcement_presentation.dart';
import 'announcements_state.dart';

enum _FeedFilter { all, unread, important }

extension on _FeedFilter {
  bool accepts(Announcement a) {
    switch (this) {
      case _FeedFilter.all:
        return true;
      case _FeedFilter.unread:
        return !a.isRead;
      case _FeedFilter.important:
        return a.severity == AnnouncementSeverity.high ||
            a.severity == AnnouncementSeverity.critical;
    }
  }
}

class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen>
    with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  _FeedFilter _filter = _FeedFilter.all;

  AnnouncementsState get _state =>
      Provider.of<AnnouncementsState>(context, listen: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LastScreenTracker.save('/announcements');
    _scroll.addListener(_onScroll);
    // Pushes arriving while this centre is open refresh the feed quietly
    // instead of posting a notification - the user is looking at it.
    NotificationService.instance.isAnnouncementsOnScreen = () => mounted;
    // Guests sign in first - the feed is authenticated - then the feed
    // loads (not in build: rebuilds must not refetch). Whoever gets here
    // without a session is asked, then lands back here signed in;
    // declining leaves to whatever opened this.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    if (!ApiService.isLoggedIn) {
      final authed = await requireAuth(context,
          reason: 'to read announcements from BROKA');
      if (!mounted) return;
      if (!authed) {
        Navigator.maybePop(context);
        return;
      }
    }
    // useAccount is cheap when the account is unchanged; refresh() then
    // reloads the first page, and the badge reconciles with the server.
    await _state.useAccount(ApiService.currentUserId);
    if (!mounted) return;
    await _state.refresh();
    if (!mounted) return;
    await _state.refreshUnreadCount();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (NotificationService.instance.isAnnouncementsOnScreen != null) {
      NotificationService.instance.isAnnouncementsOnScreen = null;
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back in front after time away: what is on screen may be stale, so
    // fetch again rather than trusting it.
    if (state == AppLifecycleState.resumed) {
      _state.refresh();
      _state.refreshUnreadCount();
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // Near the bottom: the next page, before the user hits the end.
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 320) {
      _state.loadMore();
    }
  }

  Future<void> _delete(Announcement announcement) async {
    final ok = await _state.dismissAnnouncement(announcement);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Announcement deleted'
          : "Couldn't delete it. Check your connection and try again."),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<bool> _confirmDelete(Announcement announcement) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete this announcement?',
            style: TextStyle(
                color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        content: Text(
            '“${announcement.title}” will be removed from your announcements. '
            'This only affects you.',
            style: const TextStyle(color: BrokaColors.textMid)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep',
                style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete',
                style: TextStyle(
                    color: BrokaColors.danger, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _open(Announcement announcement) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: '/announcement-detail'),
        builder: (_) => AnnouncementDetailScreen(announcement: announcement),
      ),
    );
    // Back from reading: the detail already acknowledged it, but reconcile
    // anyway - the badge is server-backed, not assumed.
    if (mounted) _state.refreshUnreadCount();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          bottom: false,
          child: Consumer<AnnouncementsState>(
            builder: (context, state, _) => RefreshIndicator(
              color: BrokaColors.gold,
              backgroundColor: BrokaColors.bgCard,
              displacement: 72,
              onRefresh: () async {
                await state.refresh();
                await state.refreshUnreadCount();
              },
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: CollapsingScreenHeader(
                      title: 'Announcements',
                      emoji: '📣',
                      gradient: kChatGradient,
                      onBack: () => Navigator.maybePop(context),
                      narrow: media.size.width < 360,
                      textScale: media.textScaler
                          .scale(1.0)
                          .clamp(1.0, 1.35)
                          .toDouble(),
                      trailing: state.unreadKnown && state.unreadCount! > 0
                          ? Row(mainAxisSize: MainAxisSize.min, children: [
                              _UnreadPill(state.unreadCount!),
                              const SizedBox(width: 8),
                              _MarkAllReadButton(
                                  onPressed: () => _state.markAllRead()),
                            ])
                          : null,
                      trailingKey: state.unreadCount ?? 0,
                    ),
                  ),
                  ..._body(media, state),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(MediaQueryData media, AnnouncementsState state) {
    if (state.loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
              child: CircularProgressIndicator(
                  color: BrokaColors.gold, strokeWidth: 1.5)),
        ),
      ];
    }

    if (state.error != null && state.items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
              child: BrokaEmptyState(
            emoji: '📡',
            gradient: kChatGradient,
            headline: "Couldn't load announcements",
            body: state.error!,
            action: GradientButton(
              onPressed: () => _state.refresh(),
              colors: kChatGradient,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text('Retry',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          )),
        ),
      ];
    }

    if (state.items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
              child: BrokaEmptyState(
            emoji: '📣',
            gradient: kChatGradient,
            headline: 'No announcements',
            body: 'News from BROKA - maintenance, incidents and product '
                'updates - will appear here.',
            action: GradientButton(
              onPressed: () => _state.refresh(),
              colors: kChatGradient,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text('Refresh',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: Colors.white)),
              ),
            ),
          )),
        ),
      ];
    }

    final visible =
        state.items.where((a) => _filter.accepts(a)).toList();
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
          child: Row(children: [
            _FilterChip(
              label: 'All',
              selected: _filter == _FeedFilter.all,
              onTap: () => setState(() => _filter = _FeedFilter.all),
            ),
            const SizedBox(width: 8),
            _FilterChip(
              label: 'Unread',
              selected: _filter == _FeedFilter.unread,
              onTap: () => setState(() => _filter = _FeedFilter.unread),
            ),
            const SizedBox(width: 8),
            _FilterChip(
              label: 'Important',
              selected: _filter == _FeedFilter.important,
              onTap: () => setState(() => _filter = _FeedFilter.important),
            ),
          ]),
        ),
      ),
      if (visible.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
              child: BrokaEmptyState(
            emoji: '📣',
            gradient: kChatGradient,
            headline: 'Nothing here',
            body: _filter == _FeedFilter.unread
                ? 'You have read everything. New announcements will appear here.'
                : 'No announcements match this filter.',
          )),
        )
      else
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + media.padding.bottom),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) {
              if (i >= visible.length) {
                // The next page failed or is loading: a spinner while it
                // loads, a retry row when it stalled.
                if (state.loadingMore) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                        child: CircularProgressIndicator(
                            color: BrokaColors.gold, strokeWidth: 1.5)),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: TextButton(
                      onPressed: () => _state.loadMore(),
                      child: const Text('Load more',
                          style: TextStyle(
                              color: BrokaColors.gold,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                );
              }
              final announcement = visible[i];
              return Dismissible(
                key: ValueKey('announcement-dismiss-${announcement.id}'),
                direction: DismissDirection.endToStart,
                confirmDismiss: (_) => _confirmDelete(announcement),
                onDismissed: (_) => _delete(announcement),
                background: Container(
                  alignment: Alignment.centerRight,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.only(right: 20),
                  decoration: BoxDecoration(
                    color: BrokaColors.danger.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: BrokaColors.danger.withOpacity(0.5)),
                  ),
                  child: const Icon(Icons.delete_outline_rounded,
                      color: BrokaColors.danger),
                ),
                child: _AnnouncementCard(
                  key: ValueKey('announcement-${announcement.id}'),
                  announcement: announcement,
                  onTap: () => _open(announcement),
                  onDelete: () async {
                    if (await _confirmDelete(announcement)) {
                      await _delete(announcement);
                    }
                  },
                ),
              );
            },
            childCount:
                visible.length + (state.hasMore ? 1 : 0),
          ),
        ),
      ),
    ];
  }
}

/// "3 new" in the header - the brand gradient, like the Inbox's own pill.
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
            boxShadow: [
              BoxShadow(
                  color: BrokaColors.neonBlue.withOpacity(0.3),
                  blurRadius: 12)
            ],
          ),
          child: Text('$count new',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
        ),
      );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: '$label filter',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.gold.withOpacity(0.18)
                  : BrokaColors.bgCard.withOpacity(0.7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? BrokaColors.gold : BrokaColors.border,
                width: selected ? 1.3 : 1,
              ),
            ),
            child: Text(label,
                style: TextStyle(
                    color: selected ? BrokaColors.textHigh : BrokaColors.textMid,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
          ),
        ),
      );
}

class _MarkAllReadButton extends StatelessWidget {
  const _MarkAllReadButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Mark all announcements as read',
        child: IconButton(
          key: const Key('announcements-mark-all-read'),
          onPressed: onPressed,
          icon: const Icon(Icons.done_all_rounded, size: 20),
          color: BrokaColors.textHigh,
          tooltip: 'Mark all read',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          style: IconButton.styleFrom(
            backgroundColor: BrokaColors.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: BrokaColors.border),
            ),
          ),
        ),
      );
}

/// One announcement row on the app's card system: type badge, title,
/// preview, then date/time and expiry in readable (textMid) type.
/// Unread rows are brighter with a gold dot and "New" pill; severity is
/// icon + label, never colour alone. Swipe or the delete action removes
/// the row for this user only.
class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard(
      {super.key,
      required this.announcement,
      required this.onTap,
      required this.onDelete});

  final Announcement announcement;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final a = announcement;
    final unread = !a.isRead;
    final expiry = AnnouncementPresentation.expiryLine(a);
    final soon = AnnouncementPresentation.expiresSoon(a);
    return Semantics(
      button: true,
      label: '${a.title}. ${unread ? 'Unread. ' : ''}'
          '${AnnouncementPresentation.typeLabel(a.type)}, '
          '${AnnouncementPresentation.severityLabel(a.severity)} severity.'
          '${a.publishedAt != null ? ' Published ${AnnouncementPresentation.fullDateTime(a.publishedAt!)}.' : ''}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(unread ? 0.97 : 0.78),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: unread
                  ? BrokaColors.gold.withOpacity(0.55)
                  : BrokaColors.border,
              width: unread ? 1.4 : 1,
            ),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AnnouncementTypeBadge(announcement: a),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    if (unread) ...[
                      Container(
                        key: Key('announcement-unread-dot-${a.id}'),
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: BrokaColors.gold,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                    ],
                    Expanded(
                      child: Text(a.title,
                          style: TextStyle(
                              color: BrokaColors.textHigh,
                              fontSize: 15,
                              fontWeight:
                                  unread ? FontWeight.w800 : FontWeight.w600,
                              height: 1.3)),
                    ),
                  ]),
                  const SizedBox(height: 5),
                  Text(a.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: BrokaColors.textMid,
                          fontSize: 13,
                          height: 1.45)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      AnnouncementPill(
                          label: AnnouncementPresentation.typeLabel(a.type),
                          color: BrokaColors.neonBlue,
                          icon: AnnouncementPresentation.typeIcon(a.type)),
                      AnnouncementPill(
                          label:
                              AnnouncementPresentation.severityLabel(a.severity),
                          color: AnnouncementPresentation.severityColor(
                              a.severity),
                          icon: AnnouncementPresentation.severityIcon(
                              a.severity)),
                      if (unread)
                        const AnnouncementPill(
                            label: 'New',
                            color: BrokaColors.gold,
                            icon: Icons.fiber_new_outlined),
                    ],
                  ),
                  if (a.publishedAt != null) ...[
                    const SizedBox(height: 9),
                    Row(children: [
                      const Icon(Icons.schedule_rounded,
                          size: 13, color: BrokaColors.textMid),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                            AnnouncementPresentation.publishedLine(
                                a.publishedAt!),
                            style: const TextStyle(
                                color: BrokaColors.textMid, fontSize: 11.5)),
                      ),
                    ]),
                  ],
                  if (expiry != null) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.hourglass_bottom_rounded,
                          size: 13,
                          color: soon
                              ? BrokaColors.warning
                              : BrokaColors.textMid),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(expiry,
                            style: TextStyle(
                                color: soon
                                    ? BrokaColors.warning
                                    : BrokaColors.textMid,
                                fontSize: 11.5,
                                fontWeight: soon
                                    ? FontWeight.w700
                                    : FontWeight.w400)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
            IconButton(
              key: Key('announcement-delete-${a.id}'),
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: BrokaColors.textMid,
              tooltip: 'Delete announcement',
              constraints:
                  const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          ]),
        ),
      ),
    );
  }
}
