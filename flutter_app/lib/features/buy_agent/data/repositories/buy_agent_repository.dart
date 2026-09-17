// lib/features/buy_agent/data/repositories/buy_agent_repository.dart
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/buy_agent_request.dart';

class BuyAgentRepository {
  final ApiClient _client;
  BuyAgentRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<BuyAgentRequest>> create({
    required String category,
    required double maxPrice,
    List<String> mustHaveFeatures = const [],
  }) async {
    try {
      final res = await _client.post('/buy-agent-requests', {
        'category': category,
        'max_price': maxPrice,
        'must_have_features': mustHaveFeatures,
      });
      return Success(BuyAgentRequest.fromJson(res));
    } on ApiException catch (e) {
      // statusCode is preserved so the UI can show the specific "you
      // already have an active request" message on a 409, not a generic
      // failure banner.
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<BuyAgentRequest?>> getActive() async {
    try {
      final res = await _client.get('/buy-agent-requests/me');
      return Success(res == null ? null : BuyAgentRequest.fromJson(res));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Buying Agent Hub's richer sibling of the plain sheet's category/price
  /// parse - extracts into the SearchProductsParams shape (query,
  /// subcategory, location, attributes...) instead of 3 fields.
  ///
  /// existingFilters (REFINE_SEARCH, Design v2 §21): pass the Hub's current
  /// SearchProductsParams-shaped filters when this is a follow-up refining
  /// an already-shown search ("only 2018 or newer") rather than a fresh
  /// one - the model merges the new text against them server-side. Omit
  /// for a first-time search.
  Future<Result<Map<String, dynamic>>> parseIntent(String text, {Map<String, dynamic>? existingFilters}) async {
    try {
      final body = <String, dynamic>{'text': text};
      if (existingFilters != null) body['existing_filters'] = existingFilters;
      final res = await _client.post('/buy-agent-requests/parse-intent', body);
      return Success(res as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Zeno structured action endpoint (Design v2 §16-20) - action is the
  /// raw {"action": ..., "optimization_code": ..., "parameters": {...}}
  /// map; response is whatever shape that action returns (§27), status
  /// SUCCESS or FAILED either way - caller interprets it per-action.
  Future<Result<Map<String, dynamic>>> executeAction(
    Map<String, dynamic> action, {
    double? lat,
    double? lng,
  }) async {
    try {
      final query = Uri(queryParameters: {
        if (lat != null) 'lat': lat.toString(),
        if (lng != null) 'lng': lng.toString(),
      }).query;
      final path = '/buy-agent-requests/action${query.isNotEmpty ? '?$query' : ''}';
      final res = await _client.post(path, action);
      return Success(res as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// CANCEL_REQUEST convenience wrapper (redesign-guide audit) - the
  /// action itself needs no parameters, it always targets the caller's
  /// own current standing request.
  Future<Result<Map<String, dynamic>>> cancelRequest() =>
      executeAction({'action': 'CANCEL_REQUEST', 'parameters': {}});

  /// START_NEGOTIATION convenience wrapper (redesign-guide audit). The
  /// caller (BuyAgentHubScreen) must have already shown the buyer a
  /// confirmation before calling this - see actions.py's
  /// _start_negotiation docstring for why authorization is a UI-level
  /// confirm step here rather than a server-checked flag.
  Future<Result<Map<String, dynamic>>> startNegotiation(String listingId, {String? message}) =>
      executeAction({
        'action': 'START_NEGOTIATION',
        'parameters': {
          'listing_id': listingId,
          if (message != null && message.trim().isNotEmpty) 'message': message.trim(),
        },
      });
}

final buyAgentRepository = BuyAgentRepository();
