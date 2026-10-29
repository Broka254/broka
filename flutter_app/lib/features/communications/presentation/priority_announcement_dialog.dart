// The prominent in-app notice for an unread critical/high announcement.
//
// One dialog, however many notices are waiting: the highest-priority one
// in full, a count of the rest, and a way into the announcements centre.
// Showing it never marks anything read - only opening the announcement
// (Read announcement -> AnnouncementDetailScreen) acknowledges it.
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../domain/models/announcement.dart';

/// Show the priority notice for [announcements] (already ordered,
/// highest priority first). Completes when the user dismisses it.
Future<void> showPriorityAnnouncementDialog(
  BuildContext context, {
  required List<Announcement> announcements,
  required void Function(Announcement announcement) onRead,
  required VoidCallback onRemindLater,
  required VoidCallback onViewAll,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
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
    return Dialog(
      key: const Key('priority-announcement-dialog'),
      backgroundColor: BrokaColors.bgCard,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
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
                Icon(
                  critical
                      ? Icons.warning_amber_rounded
                      : Icons.priority_high_rounded,
                  key: Key(critical
                      ? 'priority-icon-critical'
                      : 'priority-icon-high'),
                  color: accent,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Container(
                  key: const Key('priority-severity-badge'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: accent.withOpacity(0.55)),
                  ),
                  child: Text(
                    critical ? 'CRITICAL' : 'HIGH PRIORITY',
                    style: TextStyle(
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Text(primary.title,
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      height: 1.3)),
              if (primary.publishedAt != null) ...[
                const SizedBox(height: 4),
                Text(_publishedLine(primary.publishedAt!),
                    style: const TextStyle(
                        color: BrokaColors.textLow, fontSize: 12)),
              ],
              const SizedBox(height: 10),
              Text(primary.body,
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 14, height: 1.5)),
              if (others > 0) ...[
                const SizedBox(height: 14),
                Text(
                  others == 1
                      ? '+ 1 more important notice waiting'
                      : '+ $others more important notices waiting',
                  key: const Key('priority-more-count'),
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 13,
                      fontWeight: FontWeight.w700),
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
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Read announcement',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextButton(
                    key: const Key('priority-remind-button'),
                    onPressed: onRemindLater,
                    child: const Text('Remind me later'),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    key: const Key('priority-view-all-button'),
                    onPressed: onViewAll,
                    child: const Text('View all announcements'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  static String _publishedLine(DateTime at) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    final local = at.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour < 12 ? 'AM' : 'PM';
    return 'Published ${months[local.month - 1]} ${local.day}, '
        '$hour:$minute $ampm';
  }
}
