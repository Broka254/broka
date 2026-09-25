// BROKA - Sell Wizard Data
//
// The "new listing" flow is split across several screens (see
// sell_flow.dart for their order), each editing one piece of a listing.
// This class is the single mutable instance passed by reference from
// screen to screen via each constructor, so every step reads and writes the
// same in-progress listing rather than each screen owning its own
// disconnected copy.
//
// Also owns the draft <-> JSON shape (SellDraftStore). Everything a seller
// has chosen is in the draft - including, since the 2026-09-25 overhaul, the
// cover image (as an uploaded image id or a file kept on the phone, never as
// the megabytes-long base64 string it used to be) and the step they were on,
// so a process killed mid-flow comes back where the seller left it.
import 'dart:io';
import 'dart:math';
import 'sell_draft_store.dart';
import 'photo_upload_tracker.dart';

class SellWizardData {
  SellWizardData({PhotoUploadTracker? photoUploads})
      : photoUploads = photoUploads ?? PhotoUploadTracker();

  // Limits the server enforces (backend/api/domains/listings/validation.py),
  // applied as the seller types instead of refused at the end.
  static const maxNameLength = 120;
  static const maxDescriptionLength = 2000;
  static const minDescriptionLength = 20;
  static const maxPriceUnitLength = 24;
  static const maxQuantity = 1000000;
  static const maxDeliveryNoteLength = 120;
  static const maxPhotos = 6;

  /// Sent as X-Idempotency-Key when this listing is published, and saved
  /// with the draft. If the response to Activate is lost - a slow
  /// connection, the app killed mid-request - pressing it again returns the
  /// listing that was created instead of posting the item a second time.
  /// A new draft gets a new key.
  String draftKey = newDraftKey();

  static String newDraftKey() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// The wizard step the seller was last on (1-based, see SellFlow). A
  /// draft restored after Android killed the app reopens there instead of
  /// at Photos - which is what used to make a kill look like "the app
  /// threw my listing away".
  int resumeStep = 1;

  /// Set just before BROKA hands the screen to another app to pick an
  /// image ("camera" or "showcase"), cleared when it comes back. If Android
  /// kills BROKA meanwhile, the image arrives through image_picker's
  /// retrieveLostData() on the next launch with no hint of what it was for;
  /// this says. Without it, a cover picked from the gallery came back as a
  /// "camera-verified" listing photo.
  String? pendingPick;

  String name = '';
  // Top-level category name, and the backend Category row ids for the
  // picks. The ids are what actually get sent for subcategory_id; the
  // name is what the review screen shows and the legacy listings.category
  // column holds (the server now files it under the subcategory's parent).
  String category = '';
  String? categoryId;
  String? subcategoryId;
  String? subcategoryName;
  String? condition; // "new" | "used" | "refurbished" - universal, not a CategoryFilter
  // Dynamic per-subcategory values, keyed by CategoryFilterField.fieldName
  // (e.g. {"make": "Toyota", "mileage": "45000"}). Rendered from whatever
  // /categories/{subcategoryId}/filters returns - see DynamicAttributeField.
  // A Land listing's size lives here too, as land_size + land_size_unit.
  Map<String, String> attributes = {};
  String type = 'direct';
  String price = '';

  /// What one unit of the price is ("bag": KES 3,500 per bag). Null = the
  /// price is for the whole listing.
  String? priceUnit;

  /// Null until the seller answers "fixed or open to offers?".
  bool? priceNegotiable;

  /// How many units the seller has, as typed (digits).
  String quantity = '1';

  /// Null until the seller answers "can you arrange delivery?".
  bool? deliveryAvailable;
  String deliveryNote = '';

  /// The answer to Zeno's "should I text you when a buyer shows up?".
  bool? smsAlerts;

  // Structured location (2026-08-29): country is fixed to Kenya for now,
  // not yet user-editable (see sell_location_screen.dart) so it isn't
  // stored here at all - the backend defaults it. `location` below is a
  // derived display string, not an independent field, so the review
  // screen's summary can never drift out of sync with what county/
  // subcounty actually hold - it mirrors the backend's own
  // _derive_location_name() exactly (subcounty first, then county).
  String county = '';
  String subcounty = '';
  String get location =>
      [subcounty, county].where((s) => s.trim().isNotEmpty).join(', ');
  String description = '';
  String reserve = '';
  final List<File> verifiedPhotos = [];
  // Each photo uploads in the background as soon as it's taken (Online
  // Stores phase 1); Publish sends the resulting ids, not the photos.
  final PhotoUploadTracker photoUploads;

  // ── Cover image (the Showcase step) ─────────────────────────────────────
  // Either an AI cover the server generated and already stored as the
  // seller's image (showcaseAssetId + its URL), or a gallery pick kept on
  // the phone (showcaseLocalPath) that uploads at Activate if it hasn't
  // already. Small either way, so it is saved with the draft like
  // everything else - the old in-memory data URI was lost to a kill.
  String? showcaseImageSource; // "gallery" | "ai"
  String? showcaseAssetId;
  String? showcasePreviewUrl;
  String? showcaseLocalPath;
  String? showcaseTheme;

  bool get hasShowcase => showcaseAssetId != null || showcaseLocalPath != null;

  /// An AI cover the server made and stored: nothing left to upload.
  void setAiShowcase({required String assetId, required String previewUrl, String? theme}) {
    showcaseImageSource = 'ai';
    showcaseAssetId = assetId;
    showcasePreviewUrl = previewUrl;
    showcaseLocalPath = null;
    showcaseTheme = theme;
  }

  /// A cover picked from the gallery, kept at [path]; uploaded at Activate.
  void setGalleryShowcase(String path) {
    showcaseImageSource = 'gallery';
    showcaseLocalPath = path;
    showcaseAssetId = null;
    showcasePreviewUrl = null;
    showcaseTheme = null;
  }

  void clearShowcase() {
    showcaseImageSource = null;
    showcaseAssetId = null;
    showcasePreviewUrl = null;
    showcaseLocalPath = null;
    showcaseTheme = null;
  }

  // Store feature (spec §11): null = personal listing (default, unchanged
  // behavior) - set only when the seller has a store AND picked "My
  // Store" on the Review step.
  String? storeId;

  // ── Auction terms (auction listings only) ─────────────────────────────
  // These configure the backend's auction lifecycle (auction_meta:
  // starting_price, min_bid_increment, starts_at, ends_at). The backend
  // re-validates all of it - see lifecycle.validate_terms - because the
  // client is not the authority on any of these rules.
  String minBidIncrement = '';
  DateTime? auctionStartsAt;
  DateTime? auctionEndsAt;

  bool get isAuction => type == 'auction';
  bool get isLand => category.trim().toLowerCase() == 'land';

  bool get hasContent =>
      name.isNotEmpty || price.isNotEmpty || verifiedPhotos.isNotEmpty;

  Map<String, dynamic> toDraftJson() => {
    'draftKey': draftKey,
    'resumeStep': resumeStep,
    'pendingPick': pendingPick,
    'name': name,
    'price': price,
    'priceUnit': priceUnit,
    'priceNegotiable': priceNegotiable,
    'quantity': quantity,
    'deliveryAvailable': deliveryAvailable,
    'deliveryNote': deliveryNote,
    'smsAlerts': smsAlerts,
    'county': county,
    'subcounty': subcounty,
    'description': description,
    'reserve': reserve,
    'category': category,
    'categoryId': categoryId,
    'subcategoryId': subcategoryId,
    'subcategoryName': subcategoryName,
    'condition': condition,
    'attributes': attributes,
    'type': type,
    'verifiedPhotoPaths': verifiedPhotos.map((f) => f.path).toList(),
    // path -> uploaded image id, so a restored draft doesn't upload the
    // same photos again.
    'photoAssetIds': photoUploads.uploadedIds,
    'showcaseImageSource': showcaseImageSource,
    'showcaseAssetId': showcaseAssetId,
    'showcasePreviewUrl': showcasePreviewUrl,
    'showcaseLocalPath': showcaseLocalPath,
    'showcaseTheme': showcaseTheme,
    'storeId': storeId,
    'minBidIncrement': minBidIncrement,
    'auctionStartsAt': auctionStartsAt?.toIso8601String(),
    'auctionEndsAt': auctionEndsAt?.toIso8601String(),
  };

  /// Snapshots the current step's data to on-device storage. Called right
  /// before every camera launch (the highest-risk moment for the process
  /// to be killed) and, debounced, on ordinary field edits.
  Future<void> persist() => SellDraftStore.save(toDraftJson());

  /// Builds a populated instance from a saved draft, or null if there's
  /// nothing worth restoring (e.g. an empty draft saved before anything
  /// was actually filled in).
  static SellWizardData? fromDraftJson(Map<String, dynamic> draft) {
    final photoPaths = (draft['verifiedPhotoPaths'] as List?)?.whereType<String>().toList() ?? [];
    // Photos are kept in the app's own storage now (SellPhotoStore), which
    // survives a process kill - but guard against one that was deleted
    // anyway, rather than a broken image tile.
    final restoredPhotos = photoPaths.map((p) => File(p)).where((f) => f.existsSync()).toList();
    final showcasePath = draft['showcaseLocalPath'] as String?;

    final data = SellWizardData()
      // A draft saved before keys existed gets a new one.
      ..draftKey    = draft['draftKey']    as String? ?? SellWizardData.newDraftKey()
      ..resumeStep  = (draft['resumeStep'] as num?)?.toInt() ?? 1
      ..pendingPick = draft['pendingPick'] as String?
      ..name        = draft['name']        as String? ?? ''
      ..price       = draft['price']       as String? ?? ''
      ..priceUnit   = draft['priceUnit']   as String?
      ..priceNegotiable = draft['priceNegotiable'] as bool?
      ..quantity    = draft['quantity']    as String? ?? '1'
      ..deliveryAvailable = draft['deliveryAvailable'] as bool?
      ..deliveryNote = draft['deliveryNote'] as String? ?? ''
      ..smsAlerts   = draft['smsAlerts']   as bool?
      ..county      = draft['county']      as String? ?? ''
      ..subcounty   = draft['subcounty']   as String? ?? ''
      ..description = draft['description'] as String? ?? ''
      ..reserve     = draft['reserve']     as String? ?? ''
      // "Vehicles" in a draft from before the rename is the same category.
      ..category    = _currentCategoryName(draft['category'] as String? ?? '')
      ..categoryId       = draft['categoryId']       as String?
      ..subcategoryId    = draft['subcategoryId']    as String?
      ..subcategoryName  = draft['subcategoryName']  as String?
      ..condition        = draft['condition']        as String?
      ..attributes  = _stringMap(draft['attributes'])
      ..type        = draft['type']        as String? ?? 'direct'
      ..showcaseImageSource = draft['showcaseImageSource'] as String?
      ..showcaseAssetId     = draft['showcaseAssetId']     as String?
      ..showcasePreviewUrl  = draft['showcasePreviewUrl']  as String?
      ..showcaseLocalPath   = (showcasePath != null && File(showcasePath).existsSync())
          ? showcasePath : null
      ..showcaseTheme = draft['showcaseTheme'] as String?
      ..storeId     = draft['storeId']     as String?
      ..minBidIncrement = draft['minBidIncrement'] as String? ?? ''
      ..auctionStartsAt = _parseDraftDate(draft['auctionStartsAt'])
      ..auctionEndsAt   = _parseDraftDate(draft['auctionEndsAt'])
      ..verifiedPhotos.addAll(restoredPhotos);
    // A gallery cover whose file is gone, and which never uploaded, is no
    // cover at all.
    if (data.showcaseAssetId == null && data.showcaseLocalPath == null) {
      data.clearShowcase();
    }
    final assetIds = _stringMap(draft['photoAssetIds']);
    data.photoUploads.restore({
      for (final f in restoredPhotos)
        if (assetIds[f.path] != null) f.path: assetIds[f.path]!,
    });

    return data.hasContent ? data : null;
  }

  static String _currentCategoryName(String name) =>
      name.trim().toLowerCase() == 'vehicles' ? 'Automobiles' : name;

  /// A JSON map with only its string values - a corrupted or hand-edited
  /// draft must not crash the restore that exists to rescue it.
  static Map<String, String> _stringMap(dynamic raw) => raw is Map
      ? {
          for (final e in raw.entries)
            if (e.key is String && e.value != null) e.key as String: e.value.toString(),
        }
      : <String, String>{};

  static DateTime? _parseDraftDate(dynamic raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
