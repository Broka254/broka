// Shared look and wording for announcements: the list card, the detail
// screen and the priority dialog must agree on what a severity means,
// which icon a type carries, and how a date is written - so it lives here
// once instead of three near-copies drifting apart.
//
// Dates: every announcement shows BOTH a relative age ("2h ago") and the
// full local date and time ("Wed, Oct 29, 2026 · 4:45 PM"). Relative alone
// (the old list) left users guessing which day "3d ago" was; absolute
// alone makes freshness hard to scan. Timestamps use textMid, never
// textLow: #2E3D5A on the card surface is ~1.8:1 contrast and fails
// WCAG AA for small text.
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../domain/models/announcement.dart';

abstract final class AnnouncementPresentation {
  static Color severityColor(AnnouncementSeverity severity) {
    switch (severity) {
      case AnnouncementSeverity.critical:
        return BrokaColors.danger;
      case AnnouncementSeverity.high:
        return BrokaColors.warning;
      case AnnouncementSeverity.low:
        return BrokaColors.textMid;
      case AnnouncementSeverity.normal:
        return BrokaColors.neonGreen;
    }
  }

  static IconData severityIcon(AnnouncementSeverity severity) {
    switch (severity) {
      case AnnouncementSeverity.critical:
        return Icons.crisis_alert_rounded;
      case AnnouncementSeverity.high:
        return Icons.priority_high_rounded;
      case AnnouncementSeverity.normal:
        return Icons.info_outline_rounded;
      case AnnouncementSeverity.low:
        return Icons.low_priority_rounded;
    }
  }

  static String severityLabel(AnnouncementSeverity severity) {
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

  static IconData typeIcon(AnnouncementType type) {
    switch (type) {
      case AnnouncementType.maintenance:
        return Icons.build_circle_outlined;
      case AnnouncementType.incident:
        return Icons.report_problem_outlined;
      case AnnouncementType.productUpdate:
        return Icons.new_releases_outlined;
      case AnnouncementType.announcement:
      case AnnouncementType.unknown:
        return Icons.campaign_outlined;
    }
  }

  static String typeLabel(AnnouncementType type) {
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

  static String relativeTime(DateTime at, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final diff = current.difference(at.toLocal());
    if (diff.isNegative || diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    return fullDate(at);
  }

  /// "Wed, Oct 29, 2026"
  static String fullDate(DateTime at) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final local = at.toLocal();
    return '${days[local.weekday - 1]}, ${months[local.month - 1]} '
        '${local.day}, ${local.year}';
  }

  /// "4:45 PM"
  static String timeOfDay(DateTime at) {
    final local = at.toLocal();
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour < 12 ? 'AM' : 'PM';
    return '$hour:$minute $ampm';
  }

  /// "Wed, Oct 29, 2026 · 4:45 PM"
  static String fullDateTime(DateTime at) =>
      '${fullDate(at)} · ${timeOfDay(at)}';

  /// "Oct 29, 2026 · 4:45 PM (2h ago)" - absolute first for records,
  /// relative in brackets for scanning.
  static String publishedLine(DateTime at, {DateTime? now}) =>
      '${fullDateTime(at)} (${relativeTime(at, now: now)})';

  /// Human countdown for the expiry the server set (30 days at most):
  /// "Expires today", "Expires in 3 days · Nov 1, 2026".
  static String? expiryLine(Announcement a, {DateTime? now}) {
    final expiry = a.expiresAt;
    if (expiry == null || a.isExpired) return null;
    final current = now ?? DateTime.now();
    final left = expiry.toLocal().difference(current.toLocal());
    if (left.inHours < 1) return 'Expires within the hour';
    if (left.inHours < 24) return 'Expires today · ${timeOfDay(expiry)}';
    if (left.inDays == 1) return 'Expires tomorrow';
    if (left.inDays < 30) {
      return 'Expires in ${left.inDays} days · ${fullDate(expiry)}';
    }
    return 'Expires ${fullDate(expiry)}';
  }

  static bool expiresSoon(Announcement a, {DateTime? now}) {
    final expiry = a.expiresAt;
    if (expiry == null || a.isExpired) return false;
    final current = now ?? DateTime.now();
    return expiry.difference(current) < const Duration(days: 3);
  }
}

/// Severity/type pill: icon + label, never colour alone (colour-blind
/// users and greyscale screenshots still carry the meaning).
class AnnouncementPill extends StatelessWidget {
  const AnnouncementPill({super.key, required this.label, required this.color, required this.icon});

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.45)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 10.5, fontWeight: FontWeight.w700)),
        ]),
      );
}

/// The type icon in its tinted rounded square - the visual anchor every
/// announcement surface shares.
class AnnouncementTypeBadge extends StatelessWidget {
  const AnnouncementTypeBadge({super.key, required this.announcement, this.size = 40});

  final Announcement announcement;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = AnnouncementPresentation.severityColor(announcement.severity);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Icon(
        AnnouncementPresentation.typeIcon(announcement.type),
        color: color,
        size: size * 0.52,
      ),
    );
  }
}
