// BROKA v3.0 - AI Broker Repository
// Wraps all AI features: broker chat, scam detection, price recommendations,
// dispute analysis.
import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';

class AIBrokerRepository {
  final ApiClient _client;
  AIBrokerRepository({ApiClient? client}) : _client = client ?? apiClient;

  /// General broker / Zeno chat
  Future<Result<String>> chat({
    required String message,
    required List<Map<String, String>> history,
    String? systemOverride,
    String? userName,
    String language = 'english',
  }) async {
    try {
      final data = await _client.post('/negotiate/chat', {
        'content':         message,
        'history':         history,
        'user_name':       userName,
        'system_override': systemOverride,
        'language':        language,
      }, timeout: const Duration(seconds: 60));
      final content = (data as Map<String, dynamic>)['content'] as String?
          ?? data['message'] as String? ?? '';
      return Success(content);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Check a message for scam signals
  Future<Result<Map<String, dynamic>>> scamCheck(String message) async {
    try {
      final data = await _client.post('/negotiate/scam-check', {'message': message},
          timeout: const Duration(seconds: 30));
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// AI price recommendation for a listing
  Future<Result<Map<String, dynamic>>> priceRecommend({
    required String itemName,
    required String category,
    required String description,
    String location = 'Nairobi',
  }) async {
    try {
      final data = await _client.post('/negotiate/price-recommend', {
        'item_name':   itemName,
        'category':    category,
        'description': description,
        'location':    location,
      }, timeout: const Duration(seconds: 30));
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Deep AI analysis of a dispute
  Future<Result<Map<String, dynamic>>> disputeAnalysis({
    required String buyerClaim,
    required String sellerClaim,
    required double dealAmount,
    required String itemName,
  }) async {
    try {
      final data = await _client.post('/negotiate/dispute-analysis', {
        'buyer_claim':  buyerClaim,
        'seller_claim': sellerClaim,
        'deal_amount':  dealAmount,
        'item_name':    itemName,
      }, timeout: const Duration(seconds: 60));
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final aiBrokerRepository = AIBrokerRepository();
