// BROKA v3.0 - Listings Repository
import 'dart:convert';
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/listing.dart';

/// Returned by getListings when withTotal=true - a page of results plus
/// the true total match count (post-filter), for "128 results" style UI
/// and correct pagination. See ListingService.list_listings §7.
class ListingsPage {
  final List<BrokaListing> items;
  final int total;
  ListingsPage({required this.items, required this.total});
}

class ListingsRepository {
  final ApiClient _client;
  ListingsRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<List<BrokaListing>>> getListings({
    String? category,
    String? categoryId,
    String? subcategoryId,
    String? condition,
    String? listingType,
    String? sellerId,
    String? storeId,
    double? lat,
    double? lng,
    double? maxKm,
    double? minPrice,
    double? maxPrice,
    String? search,
    String? location,
    String? sort,
    Map<String, dynamic>? attributes,
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final params = _buildParams(
        category: category, categoryId: categoryId, subcategoryId: subcategoryId,
        condition: condition, listingType: listingType, sellerId: sellerId,
        storeId: storeId,
        lat: lat, lng: lng, maxKm: maxKm, minPrice: minPrice, maxPrice: maxPrice,
        search: search, location: location, sort: sort, attributes: attributes,
        limit: limit, offset: offset, withTotal: false,
      );
      final data = await _client.get('/listings/', queryParams: params) as List;
      return Success(data.map((e) => BrokaListing.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Same query, but asks the backend for the true post-filter total too
  /// (spec §7 "result count") instead of just a bare page of items.
  Future<Result<ListingsPage>> getListingsPage({
    String? category,
    String? categoryId,
    String? subcategoryId,
    String? condition,
    String? listingType,
    String? sellerId,
    String? storeId,
    double? lat,
    double? lng,
    double? maxKm,
    double? minPrice,
    double? maxPrice,
    String? search,
    String? location,
    String? sort,
    Map<String, dynamic>? attributes,
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final params = _buildParams(
        category: category, categoryId: categoryId, subcategoryId: subcategoryId,
        condition: condition, listingType: listingType, sellerId: sellerId,
        storeId: storeId,
        lat: lat, lng: lng, maxKm: maxKm, minPrice: minPrice, maxPrice: maxPrice,
        search: search, location: location, sort: sort, attributes: attributes,
        limit: limit, offset: offset, withTotal: true,
      );
      final data = await _client.get('/listings/', queryParams: params) as Map<String, dynamic>;
      final items = (data['items'] as List).map((e) => BrokaListing.fromJson(e)).toList();
      return Success(ListingsPage(items: items, total: data['total'] as int));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Map<String, String> _buildParams({
    String? category, String? categoryId, String? subcategoryId, String? condition,
    String? listingType, String? sellerId, String? storeId, double? lat, double? lng, double? maxKm,
    double? minPrice, double? maxPrice, String? search, String? location, String? sort,
    Map<String, dynamic>? attributes, required int limit, required int offset,
    required bool withTotal,
  }) {
    return <String, String>{
      'limit':  limit.toString(),
      'offset': offset.toString(),
      if (category      != null) 'category':       category,
      if (categoryId    != null) 'category_id':    categoryId,
      if (subcategoryId != null) 'subcategory_id': subcategoryId,
      if (condition      != null) 'condition':      condition,
      if (listingType != null) 'listing_type': listingType,
      if (sellerId    != null) 'seller_id':    sellerId,
      if (storeId     != null) 'store_id':     storeId,
      if (lat         != null) 'lat':          lat.toString(),
      if (lng         != null) 'lng':          lng.toString(),
      if (maxKm       != null) 'max_km':       maxKm.toString(),
      if (minPrice    != null) 'min_price':    minPrice.toString(),
      if (maxPrice    != null) 'max_price':    maxPrice.toString(),
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      // FIX (redesign-guide audit): the backend already supports a
      // location_name text filter (list_listings' `location` param, ILIKE
      // against Listing.location_name) - this repository just never
      // exposed it, so Home's location filter had nowhere real to send its
      // value to on this stack (only the older, now-migrated-off
      // ApiService.getListings had it wired).
      if (location != null && location.trim().isNotEmpty) 'location': location.trim(),
      if (sort        != null) 'sort':         sort,
      if (attributes != null && attributes.isNotEmpty) 'attributes': jsonEncode(attributes),
      if (withTotal) 'with_total': 'true',
    };
  }

  Future<Result<BrokaListing>> getListing(String listingId) async {
    try {
      final data = await _client.get('/listings/$listingId');
      return Success(BrokaListing.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<BrokaListing>> createListing(Map<String, dynamic> payload) async {
    try {
      final data = await _client.post('/listings/', payload,
          timeout: const Duration(seconds: 120));
      return Success(BrokaListing.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Takes the seller's own listing off BROKA (DELETE /listings/{id}). The
  /// backend refuses, with a message to show, while a buyer's deal on it is
  /// under way or an auction has bids.
  Future<Result<void>> deleteListing(String listingId) async {
    try {
      await _client.delete('/listings/$listingId');
      return const Success(null);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<void>> expressInterest(String listingId, double? offerPrice) async {
    try {
      await _client.post('/listings/$listingId/interest', {'offer_price': offerPrice});
      return const Success(null);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<List<Map<String, dynamic>>>> getMatches(String listingId) async {
    try {
      final data = await _client.get('/listings/$listingId/matches') as List;
      return Success(data.cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Map<String, dynamic>>> getStats() async {
    try {
      final data = await _client.get('/listings/stats');
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Moves an EXISTING listing into a store the caller owns (spec §5/§11).
  /// Backend checks ownership of both the listing and the store server-side.
  Future<Result<BrokaListing>> setListingStore(String listingId, String storeId) async {
    try {
      final data = await _client.post('/listings/$listingId/store', {'store_id': storeId});
      return Success(BrokaListing.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Changes the price of the caller's own listing. Returns how many more
  /// price changes the seller has this week. The server allows two a week,
  /// 12 hours apart, and none while a buyer's deal stands; its refusals are
  /// sentences written for the seller, passed on as they are.
  Future<Result<int?>> changePrice(String listingId, double price) async {
    try {
      final data = await _client.patch('/listings/$listingId', {'price': price});
      return Success((data as Map?)?['price_changes_remaining'] as int?);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Inverse of setListingStore - returns a listing to personal.
  Future<Result<BrokaListing>> removeListingStore(String listingId) async {
    try {
      final data = await _client.delete('/listings/$listingId/store');
      return Success(BrokaListing.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final listingsRepository = ListingsRepository();
