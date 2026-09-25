// Publishing a listing from the sell wizard: the photos' ids, the showcase,
// then POST /listings - in a form that is safe to repeat.
//
// Three ways publishing went wrong on a real connection:
//   * The listing was created but the response never arrived (a timeout on
//     a slow network, the app sent to the background). Activate was still
//     there, so the seller pressed it again and the item was posted twice.
//     Every attempt now carries the draft's key (X-Idempotency-Key), and
//     the server answers a repeat with the listing it already made.
//   * A draft restored after a week held photo ids the server had cleaned
//     up - uploads no listing uses are removed after 7 days. Publishing
//     failed with "upload it again", and there was no way to: the app
//     thought they were uploaded. They're now uploaded again from the files
//     on the phone, and the listing sent once more.
//   * The showcase, which lived only in memory, was uploaded again on every
//     retry. Its id is kept now - and an AI cover (2026-09-25) is already
//     the seller's stored image, so it isn't uploaded at all.
import 'dart:io';

import '../core/network/api_client.dart';
import '../utils/price_format.dart';
import 'image_upload_service.dart';
import 'sell_wizard_data.dart';

class ListingPublisher {
  ListingPublisher({ApiClient? client, ImageUploadService? uploader})
      : _client = client,
        _uploader = uploader;

  final ApiClient? _client;
  final ImageUploadService? _uploader;
  ApiClient get _api => _client ?? apiClient;
  ImageUploadService get _images => _uploader ?? imageUploadService;

  /// The server's code for an image id it no longer has (see
  /// IMAGE_GONE_HEADERS in backend/api/domains/media/service.py).
  static const imageGone = 'IMAGE_GONE';

  /// Creates the listing [data] describes and returns it as the server
  /// does. [lat]/[lng] are where the seller is, for a county the server
  /// doesn't recognise. Throws PhotoUploadIncomplete when a photo can't be
  /// uploaded, and [ApiException] when the listing is refused.
  Future<Map<String, dynamic>> publish(
    SellWizardData data, {
    required double lat,
    required double lng,
  }) async {
    for (var attempt = 0;; attempt++) {
      // Waits for uploads still running and retries failed ones once.
      final photoIds = await data.photoUploads.idsFor(data.verifiedPhotos);
      final showcaseId = await _showcaseId(data);
      try {
        final created = await _api.post(
          '/listings/',
          payloadFor(data, photoIds: photoIds, showcaseId: showcaseId, lat: lat, lng: lng),
          timeout: const Duration(seconds: 120),
          headers: {'X-Idempotency-Key': data.draftKey},
        );
        return created as Map<String, dynamic>;
      } on ApiException catch (e) {
        if (e.code != imageGone || attempt > 0) rethrow;
        data.photoUploads.forget(data.verifiedPhotos);
        // A gallery cover can be uploaded again from its file; an AI cover
        // exists only on the server, so one that's gone is dropped rather
        // than blocking the listing - the first photo becomes the cover.
        if (data.showcaseLocalPath != null) {
          data.showcaseAssetId = null;
        } else if (data.showcaseImageSource == 'ai') {
          data.clearShowcase();
        }
      }
    }
  }

  Future<String?> _showcaseId(SellWizardData data) async {
    if (data.showcaseAssetId != null) return data.showcaseAssetId;
    final path = data.showcaseLocalPath;
    if (path == null) return null;
    final uploaded = await _images.uploadFile(File(path), purpose: ImagePurpose.listingShowcase);
    data.showcaseAssetId = uploaded.id;
    await data.persist();
    return uploaded.id;
  }

  /// The POST /listings body for [data].
  static Map<String, dynamic> payloadFor(
    SellWizardData data, {
    required List<String> photoIds,
    required String? showcaseId,
    required double lat,
    required double lng,
  }) {
    final isAuction = data.type == 'auction';
    final reserve = parseKesInput(data.reserve);
    final increment = parseKesInput(data.minBidIncrement);
    final quantity = int.tryParse(data.quantity);
    return {
      'name': data.name.trim(),
      'category': data.category,
      // A category with no subcategories ("Other") is filed under itself.
      'subcategory_id': data.subcategoryId ?? data.categoryId,
      'condition': data.condition,
      if (data.attributes.isNotEmpty) 'attributes': data.attributes,
      'price': parseKesInput(data.price),
      'lat': lat,
      'lng': lng,
      'location_county': data.county.trim(),
      'location_subcounty': data.subcounty.trim(),
      'listing_type': data.type,
      'description': data.description.trim(),
      'photo_ids': photoIds,
      // Selling terms (2026-09-25). An auction sells the lot: no unit, one
      // of it, and bidding is its negotiation.
      if (!isAuction && data.priceUnit != null) 'price_unit': data.priceUnit,
      if (!isAuction && quantity != null && quantity > 0) 'quantity': quantity,
      'price_negotiable': isAuction || data.priceNegotiable != false,
      if (data.deliveryAvailable != null) 'delivery_available': data.deliveryAvailable,
      if (data.deliveryAvailable == true && data.deliveryNote.trim().isNotEmpty)
        'delivery_note': data.deliveryNote.trim(),
      'sms_alerts': data.smsAlerts != false,
      // Auction terms. Omitted entirely for a direct listing; for an
      // auction these are what configure the backend lifecycle, and
      // without them the backend had to invent a window and an increment
      // on the seller's behalf.
      if (isAuction && reserve != null) 'reserve_price': reserve,
      if (isAuction && increment != null) 'min_bid_increment': increment,
      if (isAuction && data.auctionStartsAt != null)
        'auction_starts_at': data.auctionStartsAt!.toUtc().toIso8601String(),
      if (isAuction && data.auctionEndsAt != null)
        'auction_ends_at': data.auctionEndsAt!.toUtc().toIso8601String(),
      // AI Showcase/Cover Image (2026-08-29) - only sent if the wizard's
      // Showcase step actually produced one; the backend requires the two
      // fields together or not at all.
      if (showcaseId != null) 'showcase_id': showcaseId,
      if (showcaseId != null && data.showcaseImageSource != null)
        'showcase_image_source': data.showcaseImageSource,
      if (data.storeId != null) 'store_id': data.storeId,
    };
  }
}
