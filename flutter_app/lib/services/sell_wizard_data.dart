// BROKA - Sell Wizard Data
//
// The "new listing" flow used to be one long scrolling form in
// sell_screen.dart. It's now split across several screens (Photos ->
// Basics -> Description -> Price -> Location -> Review), each editing
// one piece of a listing. This class is the single mutable instance
// passed by reference from screen to screen via each constructor, so
// every step reads and writes the same in-progress listing rather than
// each screen owning its own disconnected copy.
//
// Also owns the draft <-> JSON shape, replacing the inline logic that
// used to live directly in SellScreen's _saveDraft()/_restoreDraftIfAny().
// Same SellDraftStore keys as before, minus 'verifiedVideoPath' - the
// verification video capture has been removed from the sell flow
// entirely, not just hidden.
import 'dart:io';
import 'sell_draft_store.dart';

class SellWizardData {
  String name = '';
  String category = 'Vehicles';
  // Backend Category row ids for the picks above/below (Phase 2:
  // mockup-actualization spec §4/§19 — backend-driven category selection).
  // `category`/`subcategoryName` stay as display-name strings so the
  // review screen and the legacy listings.category column keep working
  // unchanged; the ids are what actually get sent for subcategory_id.
  String? categoryId;
  String? subcategoryId;
  String? subcategoryName;
  String? condition; // "new" | "used" | "refurbished" - universal, not a CategoryFilter
  // Dynamic per-subcategory values, keyed by CategoryFilterField.fieldName
  // (e.g. {"make": "Toyota", "mileage": "45000"}). Rendered from whatever
  // /categories/{subcategoryId}/filters returns - see DynamicAttributeField.
  Map<String, String> attributes = {};
  String type = 'direct';
  String price = '';
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
  // AI Showcase/Cover Image (2026-08-29) - optional, chosen on the wizard's
  // Showcase step (gallery pick or an approved AI preview), submitted
  // alongside everything else in the single POST /listings call at
  // Publish. Deliberately NOT persisted to the on-device draft store like
  // the fields above: it can be a multi-megabyte base64 string (an AI
  // result or a raw gallery photo), and unlike verifiedPhotos there's no
  // on-disk file path to store instead - only the final data: URI itself.
  // The showcase step is also the very last one before Review, so the
  // crash-recovery window this would protect is short; losing an
  // unpublished showcase pick on a rare process kill just means
  // re-generating or re-picking it, not re-doing the whole listing.
  String? showcaseImageDataUri;
  String? showcaseImageSource; // "gallery" | "ai"
  // Store feature (spec §11): null = personal listing (default, unchanged
  // behavior) - set only when the seller has a store AND picked "My
  // Store" on the Review step. Cheap to persist (unlike the showcase
  // image above), so it survives a draft restore like every other field.
  String? storeId;

  // ── Auction terms (auction listings only) ─────────────────────────────
  // These configure the backend's auction lifecycle (auction_meta:
  // starting_price, min_bid_increment, starts_at, ends_at). The seller
  // could previously set only a reserve, so every auction was created with
  // a default window and a default increment nobody chose.
  //
  // Kept as strings/nullable DateTimes alongside the other draft fields so
  // they persist and restore exactly like everything else. The backend
  // re-validates all of it - see lifecycle.validate_terms - because the
  // client is not the authority on any of these rules.
  String minBidIncrement = '';
  DateTime? auctionStartsAt;
  DateTime? auctionEndsAt;

  bool get hasContent =>
      name.isNotEmpty || price.isNotEmpty || verifiedPhotos.isNotEmpty;

  Map<String, dynamic> toDraftJson() => {
    'name': name,
    'price': price,
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
    'storeId': storeId,
    'minBidIncrement': minBidIncrement,
    'auctionStartsAt': auctionStartsAt?.toIso8601String(),
    'auctionEndsAt': auctionEndsAt?.toIso8601String(),
  };

  /// Snapshots the current step's data to on-device storage. Called right
  /// before every camera launch (the highest-risk moment for the process
  /// to be killed) and, debounced, on ordinary field edits - same pattern
  /// the old single-screen flow used, just centralized here so every step
  /// screen can call the same method instead of duplicating it.
  Future<void> persist() => SellDraftStore.save(toDraftJson());

  /// Builds a populated instance from a saved draft, or null if there's
  /// nothing worth restoring (e.g. an empty draft saved before anything
  /// was actually filled in - mirrors the old _restoreDraftIfAny check).
  static SellWizardData? fromDraftJson(Map<String, dynamic> draft) {
    final photoPaths = (draft['verifiedPhotoPaths'] as List?)?.cast<String>() ?? [];
    // Photo files live in the OS's own temp/cache dir, which normally
    // survives a process kill+relaunch fine - but guard against the rare
    // case one was already cleaned up, rather than a broken image tile.
    final restoredPhotos = photoPaths.map((p) => File(p)).where((f) => f.existsSync()).toList();

    final data = SellWizardData()
      ..name        = draft['name']        as String? ?? ''
      ..price       = draft['price']       as String? ?? ''
      ..county      = draft['county']      as String? ?? ''
      ..subcounty   = draft['subcounty']   as String? ?? ''
      ..description = draft['description'] as String? ?? ''
      ..reserve     = draft['reserve']     as String? ?? ''
      ..category    = draft['category']    as String? ?? 'Vehicles'
      ..categoryId       = draft['categoryId']       as String?
      ..subcategoryId    = draft['subcategoryId']    as String?
      ..subcategoryName  = draft['subcategoryName']  as String?
      ..condition        = draft['condition']        as String?
      ..attributes  = (draft['attributes'] as Map?)?.cast<String, String>() ?? {}
      ..type        = draft['type']        as String? ?? 'direct'
      ..storeId     = draft['storeId']     as String?
      ..minBidIncrement = draft['minBidIncrement'] as String? ?? ''
      ..auctionStartsAt = _parseDraftDate(draft['auctionStartsAt'])
      ..auctionEndsAt   = _parseDraftDate(draft['auctionEndsAt'])
      ..verifiedPhotos.addAll(restoredPhotos);

    return data.hasContent ? data : null;
  }

  static DateTime? _parseDraftDate(dynamic raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
