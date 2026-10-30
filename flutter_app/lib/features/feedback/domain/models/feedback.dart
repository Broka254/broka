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

  bool get isComplaint => kind == FeedbackKind.complaint;
  bool get isClosed =>
      status == FeedbackStatus.resolved || status == FeedbackStatus.closed;

  String get categoryLabel => kFeedbackCategories[category] ?? 'General';

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
