// BROKA - Launch offers: GET /pricing/launch-offers. A read never claims
// a slot; claiming happens inside the create calls on the server.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/errors/user_facing_error.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../domain/launch_offers.dart';

class LaunchOffersRepository {
  LaunchOffersRepository({ApiClient? client}) : _client = client ?? apiClient;
  final ApiClient _client;

  Future<Result<LaunchOffers>> offers() async {
    try {
      final data = await _client.get('/pricing/launch-offers') as Map<String, dynamic>;
      return Success(LaunchOffers.fromJson(data));
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
}

final launchOffersRepository = LaunchOffersRepository();
