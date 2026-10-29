// One announcement, opened from the announcements centre or from a push.
//
// Opening it IS the read: the detail acknowledges via
// AnnouncementsState.markRead as soon as it builds, and shows the
// acknowledgement state - read, or "couldn't confirm" with a retry when
// the network failed. The app never claims a read the server did not
// confirm.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../main.dart';
import '../../../services/notification_service.dart';
import '../../../widgets/chat_parts.dart' show kChatGradient;
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../domain/models/announcement.dart';
import 'announcements_state.dart';

class AnnouncementDetailScreen extends StatefulWidget {
  const AnnouncementDetailScreen({
    super.key,
    required this.announcement,
    this.animateBackground = true,
  });

  final Announcement announcement;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<AnnouncementDetailScreen> createState() =>
      _AnnouncementDetailScreenState();
}

/// The `/announcement-detail` route: opens one announcement by id, for push
/// taps and deep links that carry only the identifier. The authoritative
/// data comes from the backend (via AnnouncementsState, refreshing when
/// the feed is not loaded yet) - never from the push payload itself. When
/// the announcement is gone for this user (expired, unpublished, never
/// theirs), it falls back to the announcements list with an explanation
/// instead of a dead screen.
class AnnouncementDetailRoute extends StatefulWidget {
  const AnnouncementDetailRoute({super.key, this.communicationId});

  final String? communicationId;

  @override
  State<AnnouncementDetailRoute> createState() =>
      _AnnouncementDetailRouteState();
}

class _AnnouncementDetailRouteState extends State<AnnouncementDetailRoute> {
  bool _loading = true;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    final id = widget.communicationId;
    if (id == null || id.isEmpty || !mounted) {
      _fallBack('That announcement is no longer available.');
      return;
    }
    final state =
        Provider.of<AnnouncementsState>(context, listen: false);
    var announcement = state.byId(id);
    if (announcement == null && state.items.isEmpty && !state.loading) {
      // Cold start straight into a detail (a push tap): the feed has not
      // loaded yet, so load it rather than declaring the row missing.
      await state.refresh();
      if (!mounted) return;
      announcement = state.byId(id);
    }
    if (!mounted) return;
    if (announcement == null || announcement.isExpired) {
      _fallBack('That announcement is no longer available.');
      return;
    }
    setState(() {
      _loading = false;
    });
  }

  void _fallBack(String message) {
    if (_settled || !mounted) return;
    _settled = true;
    final nav = Navigator.of(context);
    // Replace this route with the list: Back from there must not land on
    // a resolver that would bounce straight back.
    nav.pushReplacementNamed('/announcements');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(message),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: BrokaColors.bg,
        body: Center(
            child: CircularProgressIndicator(
                color: BrokaColors.gold, strokeWidth: 1.5)),
      );
    }
    final state = context.watch<AnnouncementsState>();
    final announcement = state.byId(widget.communicationId ?? '');
    if (announcement == null) {
      // Resolved, then the row vanished (a refresh dropped it): fall back.
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _fallBack('That announcement is no longer available.'));
      return const Scaffold(
        backgroundColor: BrokaColors.bg,
        body: Center(
            child: CircularProgressIndicator(
                color: BrokaColors.gold, strokeWidth: 1.5)),
      );
    }
    return AnnouncementDetailScreen(announcement: announcement);
  }
}

class _AnnouncementDetailScreenState
    extends State<AnnouncementDetailScreen> {
  /// Whether an acknowledgement is in flight - one at a time, started once
  /// from initState (never from build, which rebuilds).
  bool _acking = false;
  bool _ackFailed = false;
  bool _ackDone = false;

  @override
  void initState() {
    super.initState();
    final announcement = widget.announcement;
    // Opened - from a push, the list, or a deep link: whatever announced
    // it comes down. A no-op when nothing was posted.
    NotificationService.instance.cancelAnnouncement(announcement.id);
    if (announcement.isRead) {
      _ackDone = true;
    } else {
      // After the first frame: the acknowledgement notifies listeners, and
      // notifying during the Navigator's own build (this route pushing) is
      // a setState-during-build. The "Confirming..." row paints first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _acknowledge(announcement);
      });
    }
  }

  Future<bool> _acknowledge(Announcement announcement) async {
    if (!mounted || _acking) return false;
    _acking = true;
    final state =
        Provider.of<AnnouncementsState>(context, listen: false);
    final ok = await state.markRead(announcement);
    _acking = false;
    if (!mounted) return ok;
    setState(() {
      _ackDone = ok;
      _ackFailed = !ok;
    });
    return ok;
  }

  void _retry() {
    setState(() {
      _ackFailed = false;
    });
    _acknowledge(widget.announcement);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // The live copy, so a read acknowledged elsewhere (another device, a
    // refresh) shows here too.
    final live = context.select<AnnouncementsState, Announcement?>(
        (s) => s.byId(widget.announcement.id));
    final announcement = live ?? widget.announcement;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          bottom: false,
          child: CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: CollapsingScreenHeader(
                  title: 'Announcement',
                  emoji: '📣',
                  gradient: kChatGradient,
                  onBack: () => Navigator.maybePop(context),
                  narrow: media.size.width < 360,
                  textScale: media.textScaler
                      .scale(1.0)
                      .clamp(1.0, 1.35)
                      .toDouble(),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                    16, 4, 16, 24 + media.padding.bottom),
                sliver: SliverToBoxAdapter(
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: BrokaColors.bgCard.withOpacity(0.94),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: BrokaColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _Pill(
                                label: _typeLabel(announcement.type),
                                color: BrokaColors.neonBlue),
                            _Pill(
                                label:
                                    _severityLabel(announcement.severity),
                                color: _severityColor(
                                    announcement.severity)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SelectableText(announcement.title,
                            style: const TextStyle(
                                color: BrokaColors.textHigh,
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                height: 1.3)),
                        const SizedBox(height: 4),
                        Text(
                          _metaLine(announcement),
                          style: const TextStyle(
                              color: BrokaColors.textLow, fontSize: 12),
                        ),
                        const Divider(
                            height: 28, color: BrokaColors.border),
                        SelectableText(announcement.body,
                            style: const TextStyle(
                                color: BrokaColors.textHigh,
                                fontSize: 14.5,
                                height: 1.6)),
                        if (announcement.deepLink != null) ...[
                          const SizedBox(height: 20),
                          _DeepLinkButton(
                              deepLink: announcement.deepLink!),
                        ],
                        const SizedBox(height: 20),
                        _ReadState(
                          done: _ackDone || announcement.isRead,
                          failed: _ackFailed,
                          onRetry: _retry,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _metaLine(Announcement a) {
    final parts = <String>[];
    if (a.publishedAt != null) {
      parts.add('Published ${_fullDate(a.publishedAt!)}');
    }
    if (a.expiresAt != null && !a.isExpired) {
      parts.add('Expires ${_fullDate(a.expiresAt!)}');
    }
    return parts.join('  ·  ');
  }

  static String _fullDate(DateTime at) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final local = at.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour < 12 ? 'AM' : 'PM';
    return '${months[local.month - 1]} ${local.day}, ${local.year} '
        '$hour:$minute $ampm';
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

/// Whether the server confirmed the read - a quiet check when it did, an
/// honest retry row when the acknowledgement failed.
class _ReadState extends StatelessWidget {
  const _ReadState(
      {required this.done, required this.failed, required this.onRetry});

  final bool done;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (failed) {
      return GestureDetector(
        onTap: onRetry,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: BrokaColors.warning.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: BrokaColors.warning.withOpacity(0.45)),
          ),
          child: Row(children: [
            const Icon(Icons.cloud_sync_rounded,
                size: 16, color: BrokaColors.warning),
            const SizedBox(width: 8),
            const Expanded(
                child: Text("Couldn't confirm you've read this",
                    style: TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            const Text('Retry',
                style: TextStyle(
                    color: BrokaColors.warning,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      );
    }
    if (done) {
      return const Row(children: [
        Icon(Icons.check_circle_rounded,
            size: 15, color: BrokaColors.neonGreen),
        SizedBox(width: 6),
        Text('Read',
            style: TextStyle(
                color: BrokaColors.textMid, fontSize: 12.5)),
      ]);
    }
    return const Row(children: [
      SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
              color: BrokaColors.textLow, strokeWidth: 1.5)),
      SizedBox(width: 8),
      Text('Confirming…',
          style:
              TextStyle(color: BrokaColors.textLow, fontSize: 12.5)),
    ]);
  }
}

/// The announcement's own destination, when the admin set one. Only
/// broka:// links and broka.co.ke pages open in-app (the server allowlist);
/// anything else opens in the browser - and nothing opens without the
/// user's tap.
class _DeepLinkButton extends StatelessWidget {
  const _DeepLinkButton({required this.deepLink});
  final String deepLink;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: () => _open(context),
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: const Text('Open in BROKA'),
        style: OutlinedButton.styleFrom(
          foregroundColor: BrokaColors.gold,
          side: BorderSide(color: BrokaColors.gold.withOpacity(0.5)),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      );

  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(deepLink);
    if (uri == null) return;
    if (uri.scheme == 'broka') {
      _openBrokaLink(context, uri);
      return;
    }
    try {
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    } catch (_) {}
  }

  void _openBrokaLink(BuildContext context, Uri uri) {
    // broka://communications opens the list (optionally one announcement);
    // broka://store|listing|deal open their own screens via the existing
    // deep-link service shapes; broka://app is the home screen.
    final host = uri.host;
    final nav = Navigator.of(context);
    switch (host) {
      case 'communications':
        final id = uri.queryParameters['id'];
        if (id != null && id.isNotEmpty) {
          nav.pushNamed('/announcement-detail', arguments: {'id': id});
        } else {
          nav.pushNamed('/announcements');
        }
      case 'app':
        nav.pushNamedAndRemoveUntil('/home', (_) => false);
      case 'store':
        final storeId = uri.queryParameters['id'] ??
            (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null);
        if (storeId != null && storeId.isNotEmpty) {
          nav.pushNamed('/store-view',
              arguments: {'storeId': storeId});
        }
      case 'listing':
        final listingId = uri.queryParameters['id'] ??
            (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null);
        if (listingId != null && listingId.isNotEmpty) {
          nav.pushNamed('/product',
              arguments: {'listingId': listingId});
        }
      case 'deal':
        final dealId = uri.queryParameters['id'] ??
            (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null);
        if (dealId != null && dealId.isNotEmpty) {
          nav.pushNamed('/review', arguments: {'deal_id': dealId});
        }
      default:
        nav.pushNamed('/announcements');
    }
  }
}
