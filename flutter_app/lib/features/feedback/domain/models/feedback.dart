// One feedback or complaint submission, as /feedback returns it
// (backend/api/domains/feedback/router.py). Mirrors the backend enums;
// unknown values degrade to general/normal/open rather than failing.
import '../../../../utils/backend_time.dart';

enum FeedbackKind { feedback, complaint }

enum FeedbackStatus { open, acknowledged, inProgress, resolved, closed }

FeedbackKind feedbackKindFromJson(String? raw) =>
    raw == 'complaint' ? FeedbackKind.complaint : FeedbackKind.feedback;

FeedbackStatus feedbackStatusFromJson(String? raw) {
  switch (raw) {
    case 'acknowledged':
      return FeedbackStatus.acknowledged;
    case 'in_progress':
      return FeedbackStatus.inProgress;
    case 'resolved':
      return FeedbackStatus.resolved;
    case 'closed':
      return FeedbackStatus.closed;
    case 'open':
    default:
      return FeedbackStatus.open;
  }
}

String feedbackStatusName(FeedbackStatus status) {
  switch (status) {
    case FeedbackStatus.open:
      return 'open';
    case FeedbackStatus.acknowledged:
      return 'acknowledged';
    case FeedbackStatus.inProgress:
      return 'in_progress';
    case FeedbackStatus.resolved:
      return 'resolved';
    case FeedbackStatus.closed:
      return 'closed';
  }
}

String feedbackStatusLabel(FeedbackStatus status) {
  switch (status) {
    case FeedbackStatus.open:
      return 'Open';
    case FeedbackStatus.acknowledged:
      return 'Acknowledged';
    case FeedbackStatus.inProgress:
      return 'In progress';
    case FeedbackStatus.resolved:
      return 'Resolved';
    case FeedbackStatus.closed:
      return 'Closed';
  }
}

/// Categories the backend accepts (FEEDBACK_CATEGORIES). The form offers
/// the user-facing subset with plain-language labels.
const Map<String, String> kFeedbackCategories = {
  'general': 'General',
  'bug': 'Something is broken',
  'suggestion': 'Suggestion',
  'compliment': 'Compliment',
  'account': 'My account',
  'payments': 'Payments',
  'listing': 'A listing',
  'seller_conduct': 'A seller',
  'buyer_conduct': 'A buyer',
  'delivery': 'Delivery',
  'safety': 'Safety concern',
  'other': 'Other',
};

/// What each severity means to the person choosing it, and how soon the
/// team answers (backend intelligence.COMPLAINT_SLA_HOURS).
const Map<String, String> kFeedbackSeverityHints = {
  'low': 'Whenever you can - a reply within 5 days',
  'normal': 'A reply within 3 days',
  'high': 'Costing me money or a sale - a reply within a day',
  'urgent': 'Happening now, or someone is at risk - a reply within 4 hours',
};

String feedbackSeverityLabel(String severity) {
  switch (severity) {
    case 'low':
      return 'Low';
    case 'high':
      return 'High';
    case 'urgent':
      return 'Urgent';
    case 'normal':
    default:
      return 'Normal';
  }
}

/// Where a submission is on its way to an answer: received, seen by a
/// person, being worked on, done. Closed counts as done.
int feedbackStage(FeedbackStatus status) {
  switch (status) {
    case FeedbackStatus.open:
      return 0;
    case FeedbackStatus.acknowledged:
      return 1;
    case FeedbackStatus.inProgress:
      return 2;
    case FeedbackStatus.resolved:
    case FeedbackStatus.closed:
      return 3;
  }
}

String? _nonBlank(Object? raw) {
  if (raw is! String) return null;
  final s = raw.trim();
  return s.isEmpty ? null : s;
}

class FeedbackSubmission {
  const FeedbackSubmission({
    required this.id,
    required this.kind,
    required this.category,
    required this.severity,
    required this.subject,
    required this.body,
    required this.status,
    this.adminResponse,
    this.respondedAt,
    this.resolvedAt,
    this.createdAt,
    this.updatedAt,
    this.relatedListingId,
    this.relatedDealId,
    this.relatedUserId,
  });

  final String id;
  final FeedbackKind kind;
  final String category;
  final String severity;
  final String subject;
  final String body;
  final FeedbackStatus status;
  final String? adminResponse;
  final DateTime? respondedAt;
  final DateTime? resolvedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? relatedListingId;
  final String? relatedDealId;
  final String? relatedUserId;

  bool get isComplaint => kind == FeedbackKind.complaint;
  bool get isClosed =>
      status == FeedbackStatus.resolved || status == FeedbackStatus.closed;
  bool get hasReply => adminResponse != null;

  String get categoryLabel => kFeedbackCategories[category] ?? 'General';
  String get severityLabel => feedbackSeverityLabel(severity);
  int get stage => feedbackStage(status);

  /// A short reference the user can quote to the team ("#3F2A9C").
  String get reference {
    final compact = id.replaceAll('-', '').toUpperCase();
    return '#${compact.length > 6 ? compact.substring(0, 6) : compact}';
  }

  static FeedbackSubmission? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    final subject = (j['subject'] as String?)?.trim();
    final body = (j['body'] as String?)?.trim();
    if (id == null || id.isEmpty || subject == null || subject.isEmpty ||
        body == null || body.isEmpty) {
      return null;
    }
    return FeedbackSubmission(
      id: id,
      kind: feedbackKindFromJson(j['kind'] as String?),
      category: (j['category'] as String?) ?? 'general',
      severity: (j['severity'] as String?) ?? 'normal',
      subject: subject,
      body: body,
      status: feedbackStatusFromJson(j['status'] as String?),
      adminResponse: (j['admin_response'] as String?)?.trim().isEmpty == true
          ? null
          : (j['admin_response'] as String?)?.trim(),
      respondedAt: parseBackendUtc(j['responded_at'] as String?),
      resolvedAt: parseBackendUtc(j['resolved_at'] as String?),
      createdAt: parseBackendUtc(j['created_at'] as String?),
      updatedAt: parseBackendUtc(j['updated_at'] as String?),
      relatedListingId: _nonBlank(j['related_listing_id']),
      relatedDealId: _nonBlank(j['related_deal_id']),
      relatedUserId: _nonBlank(j['related_user_id']),
    );
  }
}

class FeedbackPage {
  const FeedbackPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<FeedbackSubmission> items;
  final int total;
  final int limit;
  final int offset;

  factory FeedbackPage.fromJson(Map<String, dynamic> j) {
    final raw = j['items'];
    final items = <FeedbackSubmission>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          final parsed = FeedbackSubmission.fromJson(e);
          if (parsed != null) items.add(parsed);
        } else if (e is Map) {
          final parsed =
              FeedbackSubmission.fromJson(Map<String, dynamic>.from(e));
          if (parsed != null) items.add(parsed);
        }
      }
    }
    return FeedbackPage(
      items: items,
      total: (j['total'] as num?)?.toInt() ?? items.length,
      limit: (j['limit'] as num?)?.toInt() ?? items.length,
      offset: (j['offset'] as num?)?.toInt() ?? 0,
    );
  }
}
