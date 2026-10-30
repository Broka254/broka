// Feedback & complaints API: POST /feedback, GET /feedback,
// GET /feedback/{id} (backend/api/domains/feedback/router.py).
import '../../../../core/errors/user_facing_error.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/feedback.dart';

class FeedbackRepository {
  final ApiClient _client;
  FeedbackRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<FeedbackSubmission>> submit({
    required String kind,
    required String category,
    required String severity,
    required String subject,
    required String body,
    String? relatedListingId,
    String? relatedDealId,
    String? relatedUserId,
  }) async {
    try {
      final data = await _client.post('/feedback', {
        'kind': kind,
        'category': category,
        'severity': severity,
        'subject': subject,
        'body': body,
        'related_listing_id': relatedListingId,
        'related_deal_id': relatedDealId,
        'related_user_id': relatedUserId,
      });
      final map = data is Map<String, dynamic>
          ? data
          : data is Map
              ? Map<String, dynamic>.from(data)
              : <String, dynamic>{};
      final parsed = FeedbackSubmission.fromJson(map);
      if (parsed == null) {
        return const Failure('Something went wrong. Please try again.');
      }
      return Success(parsed);
    } on ApiException catch (e) {
      return Failure(_messageFor(e), statusCode: e.statusCode, code: e.code);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  Future<Result<FeedbackPage>> mine({int limit = 50, int offset = 0}) async {
    try {
      final data = await _client.get('/feedback', queryParams: {
        'limit': '$limit',
        'offset': '$offset',
      });
      if (data is! Map<String, dynamic> && data is! Map) {
        return const Failure('Something went wrong. Please try again.');
      }
      return Success(FeedbackPage.fromJson(
          data is Map<String, dynamic>
              ? data
              : Map<String, dynamic>.from(data as Map)));
    } on ApiException catch (e) {
      return Failure(_messageFor(e), statusCode: e.statusCode, code: e.code);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }
}

String _messageFor(ApiException e) {
  if (e.statusCode >= 500) return kGenericErrorMessage;
  if (e.statusCode == 429) {
    return 'You have sent several messages in a short time. '
        'Please wait a while before sending another.';
  }
  return sanitizeErrorText(e.message);
}

final feedbackRepository = FeedbackRepository();
