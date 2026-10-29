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
import 'announcements_state.dart';

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
                          ? _UnreadPill(state.unreadCount!)
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

    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + media.padding.bottom),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) {
              if (i >= state.items.length) {
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
              final announcement = state.items[i];
              return _AnnouncementCard(
                key: ValueKey('announcement-${announcement.id}'),
                announcement: announcement,
                onTap: () => _open(announcement),
              );
            },
            childCount:
                state.items.length + (state.hasMore ? 1 : 0),
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

/// One announcement row: unread ones carry the gold edge and the dot, read
/// ones sit quiet. Severity and type ride as small pills under the title.
class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard(
      {super.key, required this.announcement, required this.onTap});

  final Announcement announcement;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = announcement;
    final unread = !a.isRead;
    final severityColor = _severityColor(a.severity);
    return Semantics(
      button: true,
      label: '${a.title}. ${unread ? 'Unread. ' : ''}${_typeLabel(a.type)}.',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(unread ? 0.96 : 0.82),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: unread
                  ? BrokaColors.gold.withOpacity(0.55)
                  : BrokaColors.border,
              width: unread ? 1.4 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (unread)
                    Container(
                      key: Key('announcement-unread-dot-${a.id}'),
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: 5, right: 8),
                      decoration: const BoxDecoration(
                        color: BrokaColors.gold,
                        shape: BoxShape.circle,
                      ),
                    ),
                  Expanded(
                    child: Text(a.title,
                        style: TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 15,
                            fontWeight:
                                unread ? FontWeight.w800 : FontWeight.w600,
                            height: 1.3)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(a.body,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: BrokaColors.textMid,
                      fontSize: 13,
                      height: 1.45)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _Pill(
                      label: _typeLabel(a.type),
                      color: BrokaColors.neonBlue),
                  _Pill(
                      label: _severityLabel(a.severity),
                      color: severityColor),
                  if (a.publishedAt != null)
                    Text(_relativeTime(a.publishedAt!),
                        style: const TextStyle(
                            color: BrokaColors.textLow, fontSize: 11.5)),
                  if (a.expiresAt != null && !a.isExpired)
                    Text('· expires ${_shortDate(a.expiresAt!)}',
                        style: const TextStyle(
                            color: BrokaColors.textLow, fontSize: 11.5)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _severityColor(AnnouncementSeverity severity) {
    switch (severity) {
      case AnnouncementSeverity.critical:
        return BrokaColors.danger;
      case AnnouncementSeverity.high:
        return BrokaColors.warning;
      case AnnouncementSeverity.low:
        return BrokaColors.textLow;
      case AnnouncementSeverity.normal:
        return BrokaColors.neonGreen;
    }
  }

  static String _typeLabel(AnnouncementType type) {
    switch (type) {
      case AnnouncementType.maintenance:
        return 'Maintenance';
      case AnnouncementType.incident:
        return 'Incident';
      case AnnouncementType.productUpdate:
        return 'Product update';
      case AnnouncementType.announcement:
      case AnnouncementType.unknown:
        return 'Announcement';
    }
  }

  static String _severityLabel(AnnouncementSeverity severity) {
    switch (severity) {
      case AnnouncementSeverity.low:
        return 'Low';
      case AnnouncementSeverity.normal:
        return 'Normal';
      case AnnouncementSeverity.high:
        return 'High';
      case AnnouncementSeverity.critical:
        return 'Critical';
    }
  }

  static String _relativeTime(DateTime at) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(at.toUtc());
    if (diff.isNegative || diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return _shortDate(at);
  }

  static String _shortDate(DateTime at) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final local = at.toLocal();
    return '${months[local.month - 1]} ${local.day}';
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.45)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 10.5, fontWeight: FontWeight.w700)),
      );
}
