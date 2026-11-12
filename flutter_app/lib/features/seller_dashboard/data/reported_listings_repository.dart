// The seller's own listings a buyer marked unavailable (backend
// listings/sold_out.py, GET /listings/reported-unavailable), and putting one
// back on sale (DELETE /listings/{id}/sold-out).
//
// A reported listing is out of every list buyers browse - and so out of the
// dashboard's catalogue, which is read from the same lists. This is the
// only place the seller finds it again; the text and the push they get
// when it is reported both send them here.
import '../../../core/errors/user_facing_error.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../../../models/listing.dart';
import '../../../utils/backend_time.dart';

class ReportedListing {
  const ReportedListing({
    required this.listing,
    this.reportedAt,
    this.openReports = 1,
  });

  final Listing listing;

  /// When the first buyer marked it unavailable.
  final DateTime? reportedAt;

  /// How many buyers have, since.
  final int openReports;

  static ReportedListing? fromJson(Object? json) {
    // Every row the endpoint sends says when it was reported; a row that
    // doesn't is not one of these, whatever else it looks like.
    if (json is! Map || json['reported_at'] is! String) return null;
    try {
      final j = json.cast<String, dynamic>();
      return ReportedListing(
        listing: Listing.fromJson(j),
        reportedAt: parseBackendUtc(j['reported_at'] as String?)?.toLocal(),
        openReports: (j['open_reports'] as num?)?.toInt() ?? 1,
      );
    } catch (_) {
      // A row this build can't read is left out, not allowed to hide the rest.
      return null;
    }
  }
}

class ReportedListingsRepository {
  ReportedListingsRepository({ApiClient? client}) : _client = client ?? apiClient;

  final ApiClient _client;

  Future<Result<List<ReportedListing>>> mine() async {
    try {
      final res = await _client.get('/listings/reported-unavailable');
      return Success([
        if (res is List)
          for (final row in res)
            if (ReportedListing.fromJson(row) case final r?) r,
      ]);
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  /// The seller: it is still for sale. Every open report is revoked and the
  /// listing is back in front of buyers.
  Future<Result<void>> stillAvailable(String listingId) async {
    try {
      await _client.delete('/listings/$listingId/sold-out');
      return const Success(null);
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }
}

final reportedListingsRepository = ReportedListingsRepository();
