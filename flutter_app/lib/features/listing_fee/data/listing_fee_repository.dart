// BROKA - Listing fee: quotes, the M-Pesa payment and its progress
// (backend/api/domains/pricing/router.py).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../domain/listing_fee.dart';

class ListingFeeRepository {
  ListingFeeRepository({ApiClient? client}) : _client = client ?? apiClient;
  final ApiClient _client;

  Future<Result<T>> _guard<T>(Future<T> Function() call) async {
    try {
      return Success(await call());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } on SocketException {
      return const Failure("You're offline. Check your connection and try again.");
    } on TimeoutException {
      return const Failure('BROKA is taking too long to answer. Try again.');
    } on http.ClientException {
      return const Failure("Couldn't reach BROKA. Try again.");
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// The fee for a listing that doesn't exist yet - the Go live teaser.
  Future<Result<ListingFeeQuote>> quoteForDraft({
    required String category,
    required double price,
    int quantity = 1,
  }) =>
      _guard(() async => ListingFeeQuote.fromJson(
            await _client.get('/pricing/listing-fee/quote', queryParams: {
              'category': category,
              'price': price.toString(),
              'quantity': '${quantity < 1 ? 1 : quantity}',
            }) as Map<String, dynamic>,
          ));

  /// The fee for one of the seller's listings: to publish it, or renew it.
  Future<Result<ListingFeeQuote>> quoteForListing(String listingId) => _guard(() async =>
      ListingFeeQuote.fromJson(
          await _client.get('/pricing/listing-fee/listings/$listingId/quote') as Map<String, dynamic>));

  /// Sends the M-Pesa prompt. [idempotencyKey] is the attempt's: sent again
  /// after a timeout, the server answers with the prompt it already sent
  /// instead of a second one.
  Future<Result<ListingFeePayment>> pay({
    required String listingId,
    required int months,
    required String phone,
    String? featuredPlan,
    required String idempotencyKey,
  }) =>
      _guard(() async => ListingFeePayment.fromJson(await _client.post(
            '/pricing/listing-fee/pay',
            {
              'listing_id': listingId,
              'months': months,
              'phone_number': phone,
              if (featuredPlan != null) 'featured_plan': featuredPlan,
            },
            headers: {'X-Idempotency-Key': idempotencyKey},
          ) as Map<String, dynamic>));

  Future<Result<ListingFeePayment>> paymentStatus(String paymentId) => _guard(() async =>
      ListingFeePayment.fromJson(
          await _client.get('/pricing/listing-fee/payments/$paymentId') as Map<String, dynamic>));

  /// The seller's listings buyers can't see until paid, or soon won't.
  Future<Result<List<ListingAwaitingFee>>> awaitingPayment() => _guard(() async {
        final data = await _client.get('/pricing/listing-fee/mine') as Map<String, dynamic>;
        return [
          for (final l in (data['listings'] as List? ?? const []))
            ListingAwaitingFee.fromJson((l as Map).cast<String, dynamic>()),
        ];
      });

  /// A fresh key for one payment attempt.
  static String newAttemptKey() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

final listingFeeRepository = ListingFeeRepository();
