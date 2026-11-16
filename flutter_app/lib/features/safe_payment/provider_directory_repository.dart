// Fetching the escrow providers (GET /escrow-providers/compare).
//
// What the phone keeps, and why it is not a list of providers: it keeps the
// LAST ANSWER, dated (ScreenCache), for CachePolicies.escrowProviders - five
// minutes counted as fresh, and nothing older than two days shown at all.
// Offline it shows that copy marked as saved, with the date it was fetched
// (ProviderDirectory.fromCache / fetchedAt), and the server's own
// verification dates ride inside it. Past the limit it shows no list, because
// "where to send your money" from a week ago is worse than saying the list is
// not available. Nothing is ever shown from code that shipped with the app.
//
// The calculator's amounts are NOT cached: an estimate for an amount typed a
// moment ago is cheap to ask for again, and a saved estimate would be a
// price shown as if it were current.

import '../../core/cache/screen_cache.dart';
import '../../core/errors/user_facing_error.dart';
import '../../core/network/api_client.dart';
import '../../core/utils/result.dart';
import 'provider_directory.dart';

/// What the comparison screen asks for.
class DirectoryQuery {
  const DirectoryQuery({
    this.amount,
    this.payout,
    this.sort = 'name',
    this.noAccount = false,
    this.kyc,
    this.paymentMethod,
    this.category,
    this.documentedDisputes = false,
    this.documentedRefunds = false,
  });

  final int? amount;
  final String? payout;
  final String sort;
  final bool noAccount;
  final String? kyc;
  final String? paymentMethod;
  final String? category;
  final bool documentedDisputes;
  final bool documentedRefunds;

  /// Whether this is the plain, unfiltered list - the only one worth keeping
  /// on the phone.
  bool get isPlain =>
      amount == null && payout == null && sort == 'name' && !noAccount && kyc == null &&
      paymentMethod == null && category == null && !documentedDisputes && !documentedRefunds;

  Map<String, String> toParams() => {
        if (amount != null) 'amount': '$amount',
        if (payout != null) 'payout': payout!,
        if (sort != 'name') 'sort': sort,
        if (noAccount) 'no_account': 'true',
        if (kyc != null) 'kyc': kyc!,
        if (paymentMethod != null) 'payment_method': paymentMethod!,
        if (category != null) 'category': category!,
        if (documentedDisputes) 'documented_disputes': 'true',
        if (documentedRefunds) 'documented_refunds': 'true',
      };
}

class ProviderDirectoryRepository {
  ProviderDirectoryRepository({ApiClient? client, DateTime Function()? clock})
      : _client = client ?? apiClient,
        _clock = clock ?? DateTime.now;

  final ApiClient _client;
  final DateTime Function() _clock;

  static CacheKey get _key => CacheKey.public(CacheFeature.escrowProviders);

  /// The directory for [query]. The plain list comes from the phone's copy
  /// while it is fresh and falls back to it (marked as saved) if the server
  /// cannot be reached; a filtered or calculated one is always asked for, and
  /// a failure is a failure - an estimate is never made from a saved copy.
  Future<Result<ProviderDirectory>> fetch({DirectoryQuery query = const DirectoryQuery(), bool forceRefresh = false}) async {
    final cache = ScreenCache.instance;
    final saved = query.isPlain ? await cache.read(_key, CachePolicies.escrowProviders) : null;

    ProviderDirectory? parse(Object? data, DateTime at) {
      try {
        return ProviderDirectory.tryParse(data, fetchedAt: at);
      } catch (_) {
        return null;
      }
    }

    if (!forceRefresh && saved != null && saved.isFresh) {
      final copy = parse(saved.data, saved.fetchedAt);
      if (copy != null) return Success(copy.asCached());
    }

    try {
      final Object? data;
      if (query.isPlain) {
        data = await cache.fetch(_key, () => _client.get('/escrow-providers/compare'));
      } else {
        data = await _client.get('/escrow-providers/compare', queryParams: query.toParams());
      }
      final fresh = parse(data, _clock());
      if (fresh == null) return const Failure('The escrow list could not be read. Please try again.');
      return Success(fresh);
    } on ApiException catch (e) {
      return _offline(saved, parse, Failure(sanitizeErrorText(e.message), statusCode: e.statusCode));
    } catch (e) {
      return _offline(saved, parse, Failure(userFacingError(e)));
    }
  }

  /// The saved copy (marked as saved, with its date) when there is one for
  /// the plain list; otherwise [failure]. Never for a calculation.
  Result<ProviderDirectory> _offline(
    CacheEntry? saved,
    ProviderDirectory? Function(Object?, DateTime) parse,
    Failure<ProviderDirectory> failure,
  ) {
    if (saved == null) return failure;
    final copy = parse(saved.data, saved.fetchedAt);
    return copy == null ? failure : Success(copy.asCached());
  }
}

final providerDirectoryRepository = ProviderDirectoryRepository();
