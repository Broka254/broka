// One admin-published announcement, as GET /communications returns it
// (backend/api/domains/service_communications/router.py,
// CustomerAnnouncementOut). Deliberately narrow: the customer feed carries
// no audience, channel, count or delivery internals - only what the
// announcements centre shows.
import '../../../../utils/backend_time.dart';

/// What kind of service communication this is. The backend's
/// `communication_type`: announcement | maintenance | incident |
/// product_update. Unknown values from a newer backend still parse - they
/// render as a plain announcement rather than failing the whole feed.
enum AnnouncementType { announcement, maintenance, incident, productUpdate, unknown }

/// How urgent the announcement is. The backend's `severity`:
/// low | normal | high | critical. Unknown values fall back to normal.
enum AnnouncementSeverity { low, normal, high, critical }

AnnouncementType announcementTypeFromJson(String? raw) {
  switch (raw) {
    case 'announcement':
      return AnnouncementType.announcement;
    case 'maintenance':
      return AnnouncementType.maintenance;
    case 'incident':
      return AnnouncementType.incident;
    case 'product_update':
      return AnnouncementType.productUpdate;
    default:
      return AnnouncementType.unknown;
  }
}

AnnouncementSeverity announcementSeverityFromJson(String? raw) {
  switch (raw) {
    case 'low':
      return AnnouncementSeverity.low;
    case 'high':
      return AnnouncementSeverity.high;
    case 'critical':
      return AnnouncementSeverity.critical;
    case 'normal':
    default:
      return AnnouncementSeverity.normal;
  }
}

class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.severity,
    this.deepLink,
    this.publishedAt,
    this.expiresAt,
    this.readAt,
  });

  final String id;
  final String title;
  final String body;
  final AnnouncementType type;
  final AnnouncementSeverity severity;

  /// Optional in-app destination, already allowlisted server-side
  /// (broka://communications, broka://app|store|listing|deal, or
  /// https://broka.co.ke...). The detail screen opens it when set.
  final String? deepLink;
  final DateTime? publishedAt;
  final DateTime? expiresAt;

  /// When this user acknowledged it (POST /communications/{id}/read), or
  /// null while unread. The server preserves the first read - a repeated
  /// acknowledgement returns the stored timestamp.
  final DateTime? readAt;

  bool get isRead => readAt != null;

  /// The server stops showing expired rows (404 on read, gone from the
  /// feed), but a cached copy can outlive its expiry - hide those too
  /// rather than presenting a dead announcement as active.
  bool get isExpired {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return !expiry.isAfter(DateTime.now().toUtc());
  }

  /// A row without an id, title or body is unusable - skip it rather than
  /// fail the whole page. Returns null for such rows.
  static Announcement? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    final title = (j['title'] as String?)?.trim();
    final body = (j['body'] as String?)?.trim();
    if (id == null || id.isEmpty || title == null || title.isEmpty || body == null || body.isEmpty) {
      return null;
    }
    return Announcement(
      id: id,
      title: title,
      body: body,
      type: announcementTypeFromJson(j['communication_type'] as String?),
      severity: announcementSeverityFromJson(j['severity'] as String?),
      deepLink: (j['deep_link'] as String?)?.trim().isEmpty == true
          ? null
          : (j['deep_link'] as String?)?.trim(),
      publishedAt: parseBackendUtc(j['published_at'] as String?),
      expiresAt: parseBackendUtc(j['expires_at'] as String?),
      readAt: parseBackendUtc(j['read_at'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'communication_type': _typeName(type),
        'severity': severity.name,
        'deep_link': deepLink,
        'published_at': publishedAt?.toIso8601String(),
        'expires_at': expiresAt?.toIso8601String(),
        'read_at': readAt?.toIso8601String(),
        'is_read': isRead,
      };

  Announcement copyWith({DateTime? readAt, bool clearReadAt = false}) => Announcement(
        id: id,
        title: title,
        body: body,
        type: type,
        severity: severity,
        deepLink: deepLink,
        publishedAt: publishedAt,
        expiresAt: expiresAt,
        readAt: clearReadAt ? null : (readAt ?? this.readAt),
      );

  static String _typeName(AnnouncementType type) {
    switch (type) {
      case AnnouncementType.announcement:
        return 'announcement';
      case AnnouncementType.maintenance:
        return 'maintenance';
      case AnnouncementType.incident:
        return 'incident';
      case AnnouncementType.productUpdate:
        return 'product_update';
      case AnnouncementType.unknown:
        return 'announcement';
    }
  }
}

/// One page of the announcements feed, as
/// CustomerAnnouncementPageOut returns it: {items, total, limit, offset}.
class AnnouncementPage {
  const AnnouncementPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<Announcement> items;
  final int total;
  final int limit;
  final int offset;

  /// Rows that fail to parse are skipped, not fatal: one malformed row
  /// must not blank the whole feed.
  factory AnnouncementPage.fromJson(Map<String, dynamic> j) {
    final raw = j['items'];
    final items = <Announcement>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          final parsed = Announcement.fromJson(e);
          if (parsed != null) items.add(parsed);
        } else if (e is Map) {
          final parsed = Announcement.fromJson(Map<String, dynamic>.from(e));
          if (parsed != null) items.add(parsed);
        }
      }
    }
    return AnnouncementPage(
      items: items,
      total: (j['total'] as num?)?.toInt() ?? items.length,
      limit: (j['limit'] as num?)?.toInt() ?? items.length,
      offset: (j['offset'] as num?)?.toInt() ?? 0,
    );
  }
}
