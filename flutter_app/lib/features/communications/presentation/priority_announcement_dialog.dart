// The prominent in-app notice for an unread critical/high announcement.
//
// One dialog, however many notices are waiting: the highest-priority one
// in full, a count of the rest, and a way into the announcements centre.
// Showing it never marks anything read - only opening the announcement
// (Read announcement -> AnnouncementDetailScreen) acknowledges it.
//
// On the app's visual system: card surface, severity-tinted badge with
// icon + label (never colour alone), full local date and time, and
// 48dp-minimum actions. A critical notice is not barrier-dismissible -
// the user must choose Read, Remind me later, or View all - while a
// high-priority one can be tapped away like any other dialog.
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../domain/models/announcement.dart';
import 'announcement_presentation.dart';

/// Show the priority notice for [announcements] (already ordered,
/// highest priority first). Completes when the user dismisses it.
Future<void> showPriorityAnnouncementDialog(
  BuildContext context, {
  required List<Announcement> announcements,
  required void Function(Announcement announcement) onRead,
  required VoidCallback onRemindLater,
  required VoidCallback onViewAll,
}) {
  final critical = announcements.isNotEmpty &&
      announcements.first.severity == AnnouncementSeverity.critical;
  return showDialog<void>(
    context: context,
    barrierDismissible: !critical,
    builder: (_) => PriorityAnnouncementDialog(
      announcements: announcements,
      onRead: onRead,
      onRemindLater: onRemindLater,
      onViewAll: onViewAll,
    ),
  );
}

class PriorityAnnouncementDialog extends StatelessWidget {
  const PriorityAnnouncementDialog({
    super.key,
    required this.announcements,
    required this.onRead,
    required this.onRemindLater,
    required this.onViewAll,
  });

  /// Eligible notices, highest priority first. Only the first is shown in
  /// full; the rest are counted, never stacked as further dialogs.
  final List<Announcement> announcements;
  final void Function(Announcement announcement) onRead;
  final VoidCallback onRemindLater;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    final primary = announcements.first;
    final critical = primary.severity == AnnouncementSeverity.critical;
    final accent = critical ? BrokaColors.danger : BrokaColors.warning;
    final others = announcements.length - 1;
    final media = MediaQuery.of(context);
    final expiry = AnnouncementPresentation.expiryLine(primary);
    return Dialog(
      key: const Key('priority-announcement-dialog'),
      backgroundColor: BrokaColors.bgCard,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: accent.withOpacity(0.65), width: 1.4),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.82),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.14),
                    shape: BoxShape.circle,
                    border: Border.all(color: accent.withOpacity(0.5)),
                  ),
                  child: Icon(
                    critical
                        ? Icons.crisis_alert_rounded
                        : Icons.priority_high_rounded,
                    key: Key(critical
                        ? 'priority-icon-critical'
                        : 'priority-icon-high'),
                    color: accent,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        key: const Key('priority-severity-badge'),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(20),
                          border:
                              Border.all(color: accent.withOpacity(0.55)),
                        ),
                        child: Text(
                          critical ? 'CRITICAL' : 'HIGH PRIORITY',
                          style: TextStyle(
                              color: accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        AnnouncementPresentation.typeLabel(primary.type),
                        style: const TextStyle(
                            color: BrokaColors.textMid, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('priority-close-button'),
                  onPressed: onRemindLater,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: BrokaColors.textMid,
                  tooltip: 'Remind me later',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                ),
              ]),
              const SizedBox(height: 16),
              Semantics(
                header: true,
                child: Text(primary.title,
                    style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        height: 1.3)),
              ),
              const SizedBox(height: 8),
              if (primary.publishedAt != null)
                Row(children: [
                  const Icon(Icons.schedule_rounded,
                      size: 14, color: BrokaColors.textMid),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        AnnouncementPresentation.publishedLine(
                            primary.publishedAt!),
                        style: const TextStyle(
                            color: BrokaColors.textMid, fontSize: 12)),
                  ),
                ]),
              if (expiry != null) ...[
                const SizedBox(height: 5),
                Row(children: [
                  Icon(Icons.hourglass_bottom_rounded,
                      size: 14,
                      color: AnnouncementPresentation.expiresSoon(primary)
                          ? BrokaColors.warning
                          : BrokaColors.textMid),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(expiry,
                        style: const TextStyle(
                            color: BrokaColors.textMid, fontSize: 12)),
                  ),
                ]),
              ],
              const SizedBox(height: 12),
              Text(primary.body,
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 14, height: 1.55)),
              if (others > 0) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: BrokaColors.bgMid,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: BrokaColors.border),
                  ),
                  child: Row(children: [
                    const Icon(Icons.notifications_active_outlined,
                        size: 16, color: BrokaColors.gold),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        others == 1
                            ? '+ 1 more important notice waiting'
                            : '+ $others more important notices waiting',
                        key: const Key('priority-more-count'),
                        style: const TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 13,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('priority-read-button'),
                  onPressed: () => onRead(primary),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(50),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Read announcement',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('priority-remind-button'),
                    onPressed: onRemindLater,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BrokaColors.textHigh,
                      side: const BorderSide(color: BrokaColors.border),
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Remind me later'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextButton(
                    key: const Key('priority-view-all-button'),
                    onPressed: onViewAll,
                    style: TextButton.styleFrom(
                      foregroundColor: BrokaColors.gold,
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('View all',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
