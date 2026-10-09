// BROKA - Premium: the plans, where the user stands, and paying for a plan
// (backend/api/domains/premium/router.py, GET /pricing/plans).
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../domain/premium.dart';
import '../../../core/errors/user_facing_error.dart';

class PremiumRepository {
  PremiumRepository({ApiClient? client}) : _client = client ?? apiClient;
  final ApiClient _client;

  Future<Result<T>> _guard<T>(Future<T> Function() call) async {
    try {
      return Success(await call());
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } on SocketException {
      return const Failure("You're offline. Check your connection and try again.");
    } on TimeoutException {
      return const Failure('BROKA is taking too long to answer. Try again.');
    } on http.ClientException {
      return const Failure("Couldn't reach BROKA. Try again.");
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  Future<Result<PremiumStatus>> me() => _guard(() async =>
      PremiumStatus.fromJson(await _client.get('/premium/me') as Map<String, dynamic>));

  Future<Result<List<PremiumPlan>>> plans() => _guard(() async {
        final data = await _client.get('/pricing/plans') as Map<String, dynamic>;
        return [
          for (final p in (data['premium'] as List? ?? const []))
            PremiumPlan.fromJson((p as Map).cast<String, dynamic>()),
        ];
      });

  /// Sends the M-Pesa prompt. [idempotencyKey] is the attempt's, so a
  /// retry after a timeout gets the prompt already sent, not a second one.
  Future<Result<PlanPayment>> subscribe({
    required String planId,
    required int months,
    required String phone,
    required String idempotencyKey,
  }) =>
      _guard(() async => PlanPayment.fromJson(await _client.post(
            '/premium/subscribe',
            {'plan_id': planId, 'months': months, 'phone_number': phone},
            headers: {'X-Idempotency-Key': idempotencyKey},
          ) as Map<String, dynamic>));

  Future<Result<PlanPayment>> paymentStatus(String paymentId) => _guard(() async =>
      PlanPayment.fromJson(await _client.get('/premium/payments/$paymentId') as Map<String, dynamic>));
}

final premiumRepository = PremiumRepository();
