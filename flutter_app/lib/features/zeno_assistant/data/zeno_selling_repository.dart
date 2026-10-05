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

  /// The description Zeno writes from the listing's first photo
  /// ([photoId], its upload id) and the [draft] so far.
  Future<String> describe({
    required Map<String, dynamic> draft,
    required String photoId,
    required String language,
  }) async {
    final res = await _client.post('/zeno/listing-draft/describe', {
      'draft': draft,
      'photo_id': photoId,
      'language': language,
    }, timeout: const Duration(seconds: 75));
    final text = res is Map ? res['description'] : null;
    if (text is! String || text.trim().isEmpty) {
      throw const ApiException(502, "Zeno couldn't write that one. Please try again.");
    }
    return text.trim();
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
