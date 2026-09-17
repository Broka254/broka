// BROKA v3.0 - Escrow / Deal Repository
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';

class EscrowRepository {
  final ApiClient _client;
  EscrowRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<Map<String, dynamic>>> finalizeDeal({
    required String listingId,
    required String buyerId,
    required double agreedPrice,
  }) async {
    try {
      final data = await _client.post('/deal/finalize', {
        'listing_id':   listingId,
        'buyer_id':     buyerId,
        'agreed_price': agreedPrice,
      });
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<void>> confirmDelivery(String dealId) async {
    try {
      await _client.post('/deal/$dealId/confirm-delivery', {});
      return const Success(null);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Map<String, dynamic>>> getDeal(String dealId) async {
    try {
      final data = await _client.get('/deal/$dealId');
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<List<Map<String, dynamic>>>> getMyDeals() async {
    try {
      final data = await _client.get('/deal/') as List;
      return Success(data.cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  // M-Pesa escrow funding
  Future<Result<Map<String, dynamic>>> stkPush({
    required String dealId,
    required String phoneNumber,
    required String password,
  }) async {
    try {
      final data = await _client.post('/mpesa/stk-push', {
        'deal_id':      dealId,
        'phone_number': phoneNumber,
        'password':     password,
      });
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Map<String, dynamic>>> queryPayment(String checkoutRequestId) async {
    try {
      final data = await _client.post('/mpesa/query', {
        'checkout_request_id': checkoutRequestId,
      });
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Map<String, dynamic>>> getPaymentStatus(String dealId) async {
    try {
      final data = await _client.get('/mpesa/status/$dealId');
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final escrowRepository = EscrowRepository();
