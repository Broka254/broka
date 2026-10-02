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

  // ── Buyer protection (backend: api/domains/escrow/protection.py) ────────

  Future<Result<Map<String, dynamic>>> _call(Future<dynamic> Function() send) async {
    try {
      final data = await send();
      return Success((data as Map).cast<String, dynamic>());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// The buyer's total for the next payment: [amount] of goods money (the
  /// whole balance when null) plus its commission and the escrow fee.
  Future<Result<Map<String, dynamic>>> feeQuote(String dealId, {double? amount}) =>
      _call(() => _client.get('/deal/$dealId/fee-quote',
          queryParams: amount == null ? null : {'amount': amount.toStringAsFixed(2)}));

  /// Pays [amount] into escrow (the whole balance when null). Less than the
  /// balance is a part payment; this same call adds the rest later.
  Future<Result<Map<String, dynamic>>> fund(String dealId,
          {required String payerPhone, double? amount, String? idempotencyKey}) =>
      _call(() => _client.post('/deal/$dealId/fund', {
            'payer_phone': payerPhone,
            if (amount != null) 'amount': amount,
          }, headers: idempotencyKey == null ? null : {'X-Idempotency-Key': idempotencyKey}));

  /// The buyer releases the money. Their answers to "has it been
  /// delivered?" are recorded with it, never used to refuse it.
  Future<Result<Map<String, dynamic>>> release(String dealId,
          {bool? itemReceived, bool? ownershipTransferred}) =>
      _call(() => _client.post('/deal/$dealId/confirm-delivery', {
            if (itemReceived != null) 'item_received': itemReceived,
            if (ownershipTransferred != null) 'ownership_transferred': ownershipTransferred,
          }));

  Future<Result<Map<String, dynamic>>> requestRefund(String dealId, String reason,
          {String? idempotencyKey}) =>
      _call(() => _client.post('/deal/$dealId/refund-request', {'reason': reason},
          headers: idempotencyKey == null ? null : {'X-Idempotency-Key': idempotencyKey}));

  Future<Result<Map<String, dynamic>>> withdrawRefund(String dealId) =>
      _call(() => _client.delete('/deal/$dealId/refund-request'));

  Future<Result<Map<String, dynamic>>> respondToRefund(String dealId,
          {required bool accept, String? note, String? idempotencyKey}) =>
      _call(() => _client.post('/deal/$dealId/refund-response', {
            'accept': accept,
            if (note != null && note.isNotEmpty) 'note': note,
          }, headers: idempotencyKey == null ? null : {'X-Idempotency-Key': idempotencyKey}));

  Future<Result<Map<String, dynamic>>> markDelivered(String dealId) =>
      _call(() => _client.post('/deal/$dealId/mark-delivered', {}));

  Future<Result<Map<String, dynamic>>> setPrice(String dealId, double agreedPrice) =>
      _call(() => _client.post('/deal/$dealId/price', {'agreed_price': agreedPrice}));

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
