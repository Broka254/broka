// State behind the store setup wizard and the store's settings pages.
//
// One controller, two uses:
//   - setting a store up ([StoreSetupController.new]): starts from the
//     seller's signup details (GET /auth/me), keeps a draft on the phone
//     after every change so leaving the wizard loses nothing, and ends
//     with [launch];
//   - editing an open store ([StoreSetupController.edit]): starts from the
//     store, and [saveSection] sends just the part being edited.
//
// Images upload the moment they're picked (Phase 1's upload service), so
// launching sends ids, not image data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/utils/result.dart';
import '../../../../services/api_service.dart';
import '../../../../services/image_upload_service.dart';
import '../../../../services/photo_upload_tracker.dart';
import '../../../../services/sell_photo_store.dart';
import '../../data/repositories/stores_repository.dart';
import '../../domain/kenya_locations.dart';
import '../../domain/models/store.dart';
import '../../domain/store_categories.dart';

enum StoreSetupStep { name, link, category, location, logo, photos, email, review }

/// The store wizard's and settings pages' picked images, in the app's own
/// storage until the store is saved (see pickStoreImage).
const storeDraftPhotos = KeptPhotos('store_draft');

/// An image in the draft: a picked file (uploading, or uploaded), or an
/// image the store already has.
class DraftImage {
  /// The picked file on this phone, if it was picked here.
  final String? path;

  /// The stored image's id, once uploaded.
  final String? id;

  /// A URL to show it by, once uploaded (or for an existing image).
  final String? url;

  const DraftImage({this.path, this.id, this.url});

  DraftImage withUpload(String id, String? url) =>
      DraftImage(path: path, id: id, url: url ?? this.url);

  bool get hasLocalFile => path != null && File(path!).existsSync();

  Map<String, dynamic> toJson() => {'path': path, 'id': id, 'url': url};

  static DraftImage? fromJson(Object? j) {
    if (j is! Map) return null;
    final image = DraftImage(
      path: j['path'] as String?,
      id: j['id'] as String?,
      url: j['url'] as String?,
    );
    // A picked file that was never uploaded and is gone from the phone
    // (the picker's cache was cleared) can't be recovered.
    if (image.id == null && !image.hasLocalFile) return null;
    return image;
  }
}

enum LinkStatus { idle, invalid, checking, available, unavailable, error }

/// Why launching or saving didn't work, and which step fixes it.
class SetupProblem implements Exception {
  final String message;
  final StoreSetupStep? step;
  const SetupProblem(this.message, [this.step]);

  @override
  String toString() => message;
}

class StoreSetupController extends ChangeNotifier {
  static const maxPhotos = 6;
  static const maxNameLength = 60;
  static const maxDescriptionLength = 1000;
  static const minLinkLength = 3;
  static const maxLinkLength = 30;
  static final _linkPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  StoreSetupController({
    StoresRepository? repository,
    ImageUploadService? uploader,
    Duration linkCheckDelay = const Duration(milliseconds: 450),
  })  : existing = null,
        _repo = repository ?? storesRepository,
        _linkCheckDelay = linkCheckDelay,
        logoUploads = PhotoUploadTracker(purpose: ImagePurpose.storeLogo, service: uploader),
        coverUploads = PhotoUploadTracker(purpose: ImagePurpose.storeCover, service: uploader),
        photoUploads = PhotoUploadTracker(purpose: ImagePurpose.storePhoto, service: uploader) {
    _listenToUploads();
  }

  StoreSetupController.edit(
    Store this.existing, {
    StoresRepository? repository,
    ImageUploadService? uploader,
  })  : _repo = repository ?? storesRepository,
        _linkCheckDelay = Duration.zero,
        logoUploads = PhotoUploadTracker(purpose: ImagePurpose.storeLogo, service: uploader),
        coverUploads = PhotoUploadTracker(purpose: ImagePurpose.storeCover, service: uploader),
        photoUploads = PhotoUploadTracker(purpose: ImagePurpose.storePhoto, service: uploader) {
    final s = existing!;
    name = s.name;
    slug = s.slug;
    linkStatus = LinkStatus.available;
    if (s.url.endsWith(s.slug)) {
      _linkPrefix = s.url
          .substring(0, s.url.length - s.slug.length)
          .replaceFirst(RegExp(r'^https?://'), '');
    }
    category = s.category;
    description = s.description ?? '';
    county = KenyaLocations.canonicalCounty(s.county) ?? s.county;
    subcounty = s.subcounty;
    landmark = s.locationDescription ?? '';
    logo = s.logo != null
        ? DraftImage(id: s.logo!.id, url: s.logo!.thumb)
        : (s.logoUrl != null ? DraftImage(url: s.logoUrl) : null);
    cover = s.cover != null ? DraftImage(id: s.cover!.id, url: s.cover!.medium) : null;
    photos = s.photoImages.isNotEmpty
        ? [for (final p in s.photoImages) DraftImage(id: p.id, url: p.thumb)]
        : [for (final p in s.photos) DraftImage(url: p)];
    email = s.businessEmail ?? '';
    emailVerified = s.businessEmailVerified;
    _savedEmail = s.businessEmail;
    loading = false;
    _listenToUploads();
  }

  /// The store being edited; null while setting one up.
  final Store? existing;
  bool get isEditing => existing != null;

  final StoresRepository _repo;
  StoresRepository get repository => _repo;
  final Duration _linkCheckDelay;
  final PhotoUploadTracker logoUploads;
  final PhotoUploadTracker coverUploads;
  final PhotoUploadTracker photoUploads;

  // ── Loading ──────────────────────────────────────────────────────────────

  bool loading = true;
  String? loadError;
  StoreOwnerProfile? owner;

  /// True when this account can't open a store yet: only a seller set up
  /// as a business can, and the server refuses anyone else. The wizard
  /// doesn't make anyone a seller - it used to, with a "Your business" step
  /// that turned a buyer into a long-term seller halfway through opening a
  /// store, skipping the question signup and Start selling ask. Start
  /// selling does that now, and the wizard waits for it.
  bool needsBusiness = false;

  // ── Draft ────────────────────────────────────────────────────────────────

  String name = '';
  String slug = '';

  /// Whether the owner typed the link themselves. Until they do, it
  /// follows the store name.
  bool slugEdited = false;
  String? category;
  String description = '';
  String? county;
  String? subcounty;
  String landmark = '';
  DraftImage? logo;
  DraftImage? cover;
  List<DraftImage> photos = [];

  String email = '';
  bool emailVerified = false;
  bool emailCodeSent = false;
  String? _emailToken;
  String? _savedEmail;

  /// Development servers return the emailed code; shown so testing
  /// doesn't need a real inbox. Always null in production.
  String? debugEmailCode;

  // ── Link check ───────────────────────────────────────────────────────────

  LinkStatus linkStatus = LinkStatus.idle;
  String? linkMessage;
  String? linkSuggestion;
  String? _checkedSlug;
  String? _linkPrefix;
  Timer? _linkTimer;

  static const defaultLinkPrefix = 'broka.co.ke/store/';

  /// What goes before the link name, as the server builds it (the base
  /// is configurable there), without "https://".
  String get linkPrefix => _linkPrefix ?? defaultLinkPrefix;
  int _linkSeq = 0;

  bool busy = false;

  List<StoreSetupStep> get steps => [
        StoreSetupStep.name,
        StoreSetupStep.link,
        StoreSetupStep.category,
        StoreSetupStep.location,
        StoreSetupStep.logo,
        StoreSetupStep.photos,
        StoreSetupStep.email,
        StoreSetupStep.review,
      ];

  static String _draftKey() => 'store_setup_draft_v1:${ApiService.currentUserId ?? 'guest'}';

  /// Loads the seller's details and any saved draft. Safe to call again
  /// after a failure.
  Future<void> load() async {
    loading = true;
    loadError = null;
    notifyListeners();

    final result = await _repo.getOwnerProfile();
    switch (result) {
      case Failure(:final message):
        loadError = message;
        loading = false;
        notifyListeners();
        return;
      case Success(:final data):
        owner = data;
    }
    final o = owner!;
    needsBusiness = !o.canOpenStore;

    if (!await _restoreDraft()) _prefill(o);
    loading = false;
    notifyListeners();
    if (slug.isNotEmpty) _scheduleLinkCheck(immediate: true);
  }

  void _prefill(StoreOwnerProfile o) {
    name = (o.businessName ?? '').trim();
    slug = suggestLink(name);
    category = StoreCategories.fromAny(o.businessCategory);
    description = (o.businessDescription ?? '').trim();
    county = KenyaLocations.guessCounty(o.businessLocation);
    landmark = '';
  }

  Future<bool> _restoreDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftKey());
      if (raw == null) return false;
      final d = jsonDecode(raw) as Map<String, dynamic>;
      name = d['name'] as String? ?? '';
      slug = d['slug'] as String? ?? '';
      slugEdited = d['slugEdited'] as bool? ?? false;
      category = d['category'] as String?;
      description = d['description'] as String? ?? '';
      county = d['county'] as String?;
      subcounty = d['subcounty'] as String?;
      landmark = d['landmark'] as String? ?? '';
      logo = DraftImage.fromJson(d['logo']);
      cover = DraftImage.fromJson(d['cover']);
      photos = [
        for (final p in (d['photos'] as List? ?? const []))
          if (DraftImage.fromJson(p) case final DraftImage image) image,
      ];
      email = d['email'] as String? ?? '';
      // A verification is only good for a while, so it isn't kept - except
      // for the owner's own verified account email, which needs none.
      final o = owner;
      emailVerified = o != null && o.emailVerified && _sameEmail(email, o.email);
      // Picked images that hadn't finished uploading carry on.
      for (final (tracker, image) in [
        (logoUploads, logo),
        (coverUploads, cover),
        for (final p in photos) (photoUploads, p),
      ]) {
        if (image == null || image.path == null) continue;
        if (image.id != null) {
          tracker.restore({image.path!: image.id!});
        } else {
          tracker.start(File(image.path!));
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Timer? _saveTimer;

  void _changed() {
    notifyListeners();
    if (isEditing) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), saveDraft);
  }

  /// Writes the draft now. Called after every change (debounced) and when
  /// the wizard is left.
  Future<void> saveDraft() async {
    if (isEditing) return;
    _saveTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_draftKey(), jsonEncode({
        'name': name,
        'slug': slug,
        'slugEdited': slugEdited,
        'category': category,
        'description': description,
        'county': county,
        'subcounty': subcounty,
        'landmark': landmark,
        'logo': logo?.toJson(),
        'cover': cover?.toJson(),
        'photos': [for (final p in photos) p.toJson()],
        'email': email,
      }));
    } catch (_) {}
  }

  static Future<void> discardDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_draftKey());
    } catch (_) {}
    await storeDraftPhotos.clear();
  }

  static Future<bool> hasDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey(_draftKey());
    } catch (_) {
      return false;
    }
  }

  // ── Name and link ────────────────────────────────────────────────────────

  void setName(String v) {
    name = v;
    if (!slugEdited && !isEditing) {
      final suggested = suggestLink(v);
      if (suggested != slug) {
        slug = suggested;
        _scheduleLinkCheck();
      }
    }
    _changed();
  }

  void setSlug(String v) {
    if (isEditing) return;
    slugEdited = true;
    slug = v.trim().toLowerCase();
    _scheduleLinkCheck();
    _changed();
  }

  /// Takes the server's suggestion when the typed link can't be used.
  void useSuggestedLink() {
    final s = linkSuggestion;
    if (s != null) setSlug(s);
  }

  /// A link name derived from a store name: "Clanix Electronics" ->
  /// "clanix-electronics". Empty when nothing usable is left.
  static String suggestLink(String storeName) {
    var s = storeName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.length > maxLinkLength) {
      s = s.substring(0, maxLinkLength).replaceAll(RegExp(r'-+$'), '');
    }
    return s.length >= minLinkLength ? s : '';
  }

  /// The same rules the server applies (except the reserved-word list,
  /// which the server checks), so obviously invalid links don't need a
  /// round trip. Null when the link looks fine.
  static String? linkProblem(String link) {
    if (link.isEmpty) return 'Choose the name for your link.';
    if (link.length < minLinkLength) return 'Use at least $minLinkLength characters.';
    if (link.length > maxLinkLength) return 'Use at most $maxLinkLength characters.';
    if (!_linkPattern.hasMatch(link)) {
      if (link.startsWith('-') || link.endsWith('-')) return "It can't start or end with a hyphen.";
      if (link.contains('--')) return 'Use one hyphen at a time.';
      return 'Use only letters, numbers and hyphens - no spaces.';
    }
    return null;
  }

  bool get linkReady => linkStatus == LinkStatus.available && _checkedSlug == slug;

  void _scheduleLinkCheck({bool immediate = false}) {
    if (isEditing) return;
    _linkTimer?.cancel();
    final seq = ++_linkSeq;
    final local = linkProblem(slug);
    if (local != null) {
      linkStatus = LinkStatus.invalid;
      linkMessage = slug.isEmpty ? null : local;
      linkSuggestion = null;
      _checkedSlug = null;
      notifyListeners();
      return;
    }
    linkStatus = LinkStatus.checking;
    linkMessage = null;
    linkSuggestion = null;
    notifyListeners();
    _linkTimer = Timer(immediate ? Duration.zero : _linkCheckDelay, () => _checkLink(seq));
  }

  /// Checks the current link now (the Retry button).
  void retryLinkCheck() => _scheduleLinkCheck(immediate: true);

  Future<void> _checkLink(int seq) async {
    final asked = slug;
    final result = await _repo.checkLinkName(asked);
    if (seq != _linkSeq) return;   // the owner has typed since
    switch (result) {
      case Success(:final data):
        _checkedSlug = asked;
        final url = data.url;
        if (url != null && url.endsWith(asked)) {
          _linkPrefix = url
              .substring(0, url.length - asked.length)
              .replaceFirst(RegExp(r'^https?://'), '');
        }
        linkStatus = data.available ? LinkStatus.available : LinkStatus.unavailable;
        linkMessage = data.reason;
        linkSuggestion = data.suggestion;
      case Failure(:final message, :final statusCode):
        linkStatus = LinkStatus.error;
        linkMessage = statusCode == 429
            ? 'Too many checks - wait a moment, then tap Retry.'
            : message;
    }
    notifyListeners();
  }

  // ── Category, location ───────────────────────────────────────────────────

  void setCategory(String v) { category = v; _changed(); }
  void setDescription(String v) { description = v; _changed(); }

  void setCounty(String? v) {
    if (v == county) return;
    county = v;
    subcounty = null;
    _changed();
  }

  void setSubcounty(String? v) { subcounty = v; _changed(); }
  void setLandmark(String v) { landmark = v; _changed(); }

  // ── Images ───────────────────────────────────────────────────────────────

  void _listenToUploads() {
    for (final t in [logoUploads, coverUploads, photoUploads]) {
      t.addListener(_syncUploads);
    }
  }

  /// Copies finished uploads' ids and URLs into the draft.
  void _syncUploads() {
    DraftImage? synced(DraftImage? image, PhotoUploadTracker tracker) {
      if (image == null || image.path == null || image.id != null) return image;
      final state = tracker.stateFor(File(image.path!));
      if (state?.status != PhotoUploadStatus.done || state?.assetId == null) return image;
      return image.withUpload(state!.assetId!, state.image?.thumb);
    }

    final newLogo = synced(logo, logoUploads);
    final newCover = synced(cover, coverUploads);
    final newPhotos = [for (final p in photos) synced(p, photoUploads)!];
    final changed = newLogo != logo ||
        newCover != cover ||
        !listEquals(newPhotos, photos);
    logo = newLogo;
    cover = newCover;
    photos = newPhotos;
    if (changed) {
      _changed();
    } else {
      notifyListeners();
    }
  }

  PhotoUploadState? uploadState(DraftImage image, PhotoUploadTracker tracker) =>
      image.path == null || image.id != null ? null : tracker.stateFor(File(image.path!));

  void setLogo(File file) {
    _forget(logo, logoUploads);
    logo = DraftImage(path: file.path);
    logoUploads.start(file);
    _changed();
  }

  void removeLogo() {
    _forget(logo, logoUploads);
    logo = null;
    _changed();
  }

  void setCover(File file) {
    _forget(cover, coverUploads);
    cover = DraftImage(path: file.path);
    coverUploads.start(file);
    _changed();
  }

  void removeCover() {
    _forget(cover, coverUploads);
    cover = null;
    _changed();
  }

  bool get canAddPhoto => photos.length < maxPhotos;

  void addPhoto(File file) {
    if (!canAddPhoto) return;
    photos = [...photos, DraftImage(path: file.path)];
    photoUploads.start(file);
    _changed();
  }

  void removePhoto(int index) {
    if (index < 0 || index >= photos.length) return;
    _forget(photos[index], photoUploads);
    photos = [...photos]..removeAt(index);
    _changed();
  }

  /// Uploads again whatever failed.
  void retryUploads() {
    for (final (tracker, image) in [
      (logoUploads, logo),
      (coverUploads, cover),
      for (final p in photos) (photoUploads, p),
    ]) {
      if (image?.path != null && image?.id == null) tracker.start(File(image!.path!));
    }
  }

  void _forget(DraftImage? image, PhotoUploadTracker tracker) {
    if (image?.path != null) tracker.remove(File(image!.path!));
  }

  // ── Business email ───────────────────────────────────────────────────────

  bool get canUseAccountEmail {
    final o = owner;
    return o != null && o.emailVerified && (o.email ?? '').isNotEmpty &&
        !_sameEmail(email, o.email);
  }

  static bool _sameEmail(String? a, String? b) =>
      (a ?? '').trim().toLowerCase() == (b ?? '').trim().toLowerCase();

  void setEmail(String v) {
    if (_sameEmail(v, email)) {
      email = v;
      return;
    }
    email = v;
    emailCodeSent = false;
    debugEmailCode = null;
    _emailToken = null;
    final o = owner;
    emailVerified = (o != null && o.emailVerified && _sameEmail(v, o.email)) ||
        (isEditing && existing!.businessEmailVerified && _sameEmail(v, _savedEmail));
    _changed();
  }

  void useAccountEmail() {
    final o = owner;
    if (o?.email == null) return;
    setEmail(o!.email!);
  }

  bool get emailLooksValid => _emailPattern.hasMatch(email.trim());

  /// Emails a code to the address. Returns an error message, or null.
  Future<String?> sendEmailCode() async {
    if (!emailLooksValid) return 'Enter a valid email address.';
    busy = true;
    notifyListeners();
    final result = await _repo.requestEmailCode(email.trim());
    busy = false;
    switch (result) {
      case Failure(:final message, :final statusCode):
        notifyListeners();
        return statusCode == 429
            ? "You've asked for several codes. Wait a few minutes, then try again."
            : message;
      case Success(:final data):
        emailCodeSent = true;
        debugEmailCode = data;
        notifyListeners();
        return null;
    }
  }

  /// Checks the emailed code. Returns an error message, or null.
  Future<String?> verifyEmailCode(String code) async {
    if (code.trim().length < 4) return 'Enter the code from the email.';
    busy = true;
    notifyListeners();
    final result = await _repo.verifyEmailCode(email.trim(), code.trim());
    busy = false;
    switch (result) {
      case Failure(:final message):
        notifyListeners();
        return message;
      case Success(:final data):
        _emailToken = data;
        emailVerified = true;
        emailCodeSent = false;
        debugEmailCode = null;
        _changed();
        return null;
    }
  }

  // ── Validation ───────────────────────────────────────────────────────────

  /// What stops [step] from being complete, or null.
  String? validate(StoreSetupStep step) {
    switch (step) {
      case StoreSetupStep.name:
        final n = name.trim();
        if (n.length < 2) return 'Give your store a name.';
        if (n.length > maxNameLength) return 'Keep the name under $maxNameLength characters.';
        return null;
      case StoreSetupStep.link:
        if (isEditing) return null;
        if (linkReady) return null;
        return switch (linkStatus) {
          LinkStatus.checking => 'Checking your link...',
          LinkStatus.error => linkMessage ?? "Couldn't check the link. Tap Retry.",
          _ => linkMessage ?? linkProblem(slug) ?? 'Choose an available link.',
        };
      case StoreSetupStep.category:
        if (category == null) return 'Choose what your store sells.';
        if (description.trim().length > maxDescriptionLength) {
          return 'Keep the description under $maxDescriptionLength characters.';
        }
        return null;
      case StoreSetupStep.location:
        if (county == null || county!.isEmpty) return 'Choose your county.';
        if (subcounty == null || subcounty!.trim().isEmpty) return 'Choose or type your area.';
        return null;
      case StoreSetupStep.logo:
      case StoreSetupStep.photos:
        return null;
      case StoreSetupStep.email:
        if (email.trim().isEmpty) return null;
        if (!emailLooksValid) return 'Enter a valid email address, or clear it to skip.';
        if (!emailVerified) return 'Verify the email with the code we send, or clear it to skip.';
        return null;
      case StoreSetupStep.review:
        for (final s in steps) {
          if (s == StoreSetupStep.review) continue;
          final problem = validate(s);
          if (problem != null) return problem;
        }
        return null;
    }
  }

  /// The first step that isn't complete, for the review screen.
  StoreSetupStep? firstIncompleteStep() {
    for (final s in steps) {
      if (s != StoreSetupStep.review && validate(s) != null) return s;
    }
    return null;
  }

  // ── Launch and save ──────────────────────────────────────────────────────

  Future<String?> _imageId(DraftImage? image, PhotoUploadTracker tracker, String label) async {
    if (image == null) return null;
    if (image.id != null) return image.id;
    if (image.path == null) return null;
    try {
      return (await tracker.idsFor([File(image.path!)])).first;
    } on PhotoUploadIncomplete catch (e) {
      throw SetupProblem("$label couldn't be uploaded (${e.reason}). Try again, or remove it.");
    }
  }

  Future<Map<String, dynamic>> _imagePayload({bool logoPart = true, bool photosPart = true}) async {
    final out = <String, dynamic>{};
    if (logoPart) out['logo_id'] = await _imageId(logo, logoUploads, 'Your logo');
    if (photosPart) {
      out['cover_id'] = await _imageId(cover, coverUploads, 'Your cover photo');
      final ids = <String>[];
      for (var i = 0; i < photos.length; i++) {
        final id = await _imageId(photos[i], photoUploads, 'Shop photo ${i + 1}');
        if (id != null) ids.add(id);
      }
      out['photo_ids'] = ids;
    }
    return out;
  }

  Map<String, dynamic> _emailPayload() {
    final e = email.trim();
    if (e.isEmpty) return {'business_email': ''};
    return {
      'business_email': e,
      if (_emailToken != null) 'business_email_token': _emailToken,
    };
  }

  String? _clean(String v) => v.trim().isEmpty ? null : v.trim();

  /// Opens the store. The error, if any, says which step to go back to.
  Future<(Store?, SetupProblem?)> launch() async {
    final incomplete = firstIncompleteStep();
    if (incomplete != null) return (null, SetupProblem(validate(incomplete)!, incomplete));
    busy = true;
    notifyListeners();
    try {
      final payload = <String, dynamic>{
        'name': name.trim(),
        'slug': slug,
        'category': category,
        'description': _clean(description),
        'county': county,
        'subcounty': _clean(subcounty ?? ''),
        'location_description': _clean(landmark),
        ...await _imagePayload(),
        if (email.trim().isNotEmpty) ..._emailPayload(),
      };
      final result = await _repo.createStore(payload);
      switch (result) {
        case Success(:final data):
          await discardDraft();
          return (data, null);
        case Failure(:final message, :final statusCode):
          return (null, _problemFor(message, statusCode));
      }
    } on SetupProblem catch (p) {
      return (null, p);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  SetupProblem _problemFor(String message, int? statusCode) {
    if (statusCode == 403) {
      // The account stopped being a business seller while the wizard was
      // open (or never was, on an old draft): back to Start selling.
      needsBusiness = true;
      return SetupProblem(message);
    }
    if (statusCode == 409 && message.toLowerCase().contains('link')) {
      linkStatus = LinkStatus.unavailable;
      linkMessage = message;
      _checkedSlug = slug;
      return SetupProblem(message, StoreSetupStep.link);
    }
    if (statusCode == 400 && message.toLowerCase().contains('verify')) {
      emailVerified = false;
      _emailToken = null;
      return SetupProblem(message, StoreSetupStep.email);
    }
    return SetupProblem(message);
  }

  /// Saves one part of an open store (settings). Returns the updated
  /// store, or the problem.
  Future<(Store?, SetupProblem?)> saveSection(StoreSetupStep step) async {
    final store = existing;
    if (store == null) return (null, const SetupProblem('Nothing to save.'));
    final problem = validate(step);
    if (problem != null) return (null, SetupProblem(problem, step));
    busy = true;
    notifyListeners();
    try {
      final Map<String, dynamic> payload = switch (step) {
        StoreSetupStep.name => {'name': name.trim()},
        StoreSetupStep.category => {
            'category': category,
            'description': _clean(description) ?? '',
          },
        StoreSetupStep.location => {
            'county': county,
            'subcounty': _clean(subcounty ?? ''),
            'location_description': _clean(landmark) ?? '',
          },
        StoreSetupStep.logo => await _imagePayload(photosPart: false),
        StoreSetupStep.photos => await _imagePayload(logoPart: false),
        StoreSetupStep.email => _emailPayload(),
        _ => const {},
      };
      final result = await _repo.updateStore(store.id, payload);
      switch (result) {
        case Success(:final data):
          // Uploaded and now the store's: the local copies have done their
          // job. (An open store has no draft, so nothing else uses them.)
          if (step == StoreSetupStep.logo || step == StoreSetupStep.photos) {
            unawaited(storeDraftPhotos.clear());
          }
          return (data, null);
        case Failure(:final message, :final statusCode):
          return (null, _problemFor(message, statusCode));
      }
    } on SetupProblem catch (p) {
      return (null, p);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _linkTimer?.cancel();
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      saveDraft();
    }
    for (final t in [logoUploads, coverUploads, photoUploads]) {
      t.removeListener(_syncUploads);
    }
    super.dispose();
  }
}
