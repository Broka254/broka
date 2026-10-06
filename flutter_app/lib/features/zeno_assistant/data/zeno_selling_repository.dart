// lib/features/zeno_assistant/data/zeno_selling_repository.dart
//
// Zeno's help in the sell wizard (backend api/domains/zeno_assistant/
// selling.py). Both calls are premium: a refusal is an ApiException with
// statusCode 402 and upgrade_to in its details, which the screens turn
// into the plans (premium_upsell.dart) - so these throw rather than fold
// the details away into a Result.
import '../../../core/network/api_client.dart';
import '../domain/zeno_selling.dart';

class ZenoSellingRepository {
  ZenoSellingRepository({ApiClient? client}) : _client = client ?? apiClient;

  final ApiClient _client;

  /// Zeno's look at the listing's first photo ([photoId], its upload id)
  /// and the [draft] so far: the description, and what to ask the seller
  /// for what the photo can't show. One of the plan's AI descriptions.
  Future<ZenoDescribeTurn> describe({
    required Map<String, dynamic> draft,
    required String photoId,
    required String language,
  }) async {
    final res = await _client.post('/zeno/listing-draft/describe', {
      'draft': draft,
      'photo_id': photoId,
      'language': language,
      // This build asks the seller Zeno's questions: without it they come
      // back as blank lines in the description.
      'conversation': true,
    }, timeout: const Duration(seconds: 75));
    final turn = res is Map ? ZenoDescribeTurn.fromJson(res.cast<String, dynamic>()) : null;
    if (turn == null || (turn.description.isEmpty && turn.questions.isEmpty)) {
      throw const ApiException(502, "Zeno couldn't write that one. Please try again.");
    }
    return turn;
  }

  /// The seller's answer ([message]) to what Zeno asked about the
  /// [description] it is writing. Free once the plan has descriptions.
  Future<ZenoDescribeTurn> describeTurn({
    required Map<String, dynamic> draft,
    required String description,
    required List<ZenoDescribeQuestion> questions,
    required String message,
    required List<Map<String, String>> history,
    required String language,
  }) async {
    final res = await _client.post('/zeno/listing-draft/describe/turn', {
      'draft': draft,
      'description': description,
      'questions': [for (final q in questions) q.toJson()],
      'message': message,
      'history': history,
      'language': language,
    });
    if (res is! Map) throw const ApiException(502, 'Zeno sent back nothing usable.');
    return ZenoDescribeTurn.fromJson(res.cast<String, dynamic>());
  }

  /// One turn of pricing the [draft] with Zeno. [research]: check what
  /// similar live listings on BROKA ask - one of the plan's price checks.
  Future<ZenoPriceTurn> priceTurn({
    required Map<String, dynamic> draft,
    required String message,
    required List<Map<String, String>> history,
    required String language,
    bool research = false,
  }) async {
    final res = await _client.post('/zeno/listing-draft/price/turn', {
      'draft': draft,
      'message': message,
      'history': history,
      'language': language,
      'research': research,
    });
    if (res is! Map) throw const ApiException(502, 'Zeno sent back nothing usable.');
    return ZenoPriceTurn.fromJson(res.cast<String, dynamic>());
  }
}

final zenoSellingRepository = ZenoSellingRepository();
