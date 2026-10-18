// Replacing a listing's photos, from the seller dashboard.
//
// Why this exists: a seller could change a price but not the photos. If the
// pictures weren't drawing buyers - the wrong angle, a dull shot, a scuff
// they missed - the only way to fix it was to delete the listing and post
// it again, losing its views, its paid time and its place in the catalogue.
//
// Photos here are taken with the camera, never picked from the gallery.
// That is the same rule the sell wizard holds (see sell_photos_screen.dart):
// a listing photo on BROKA is a photo of the thing actually in the seller's
// hands, taken now. A gallery fill would let an old picture, or someone
// else's, stand in for the item, which is exactly what the "taken live"
// promise on every listing card rules out.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../../../services/image_upload_service.dart';
import '../../../services/photo_capture.dart';
import '../../../services/photo_upload_tracker.dart';
import '../../../services/sell_photo_store.dart';
import '../../../widgets/broka_image.dart';
import '../../../widgets/wizard_scaffold.dart';
import '../../../models/listing.dart';
import '../data/repositories/listings_repository.dart';

/// Where this screen's captured photos live while they upload. Its own
/// folder, so clearing it can never touch a half-finished sell draft.
const _editPhotos = KeptPhotos('listing_edit');

/// At most six, as the sell wizard and PATCH /listings/{id} both allow.
const maxListingPhotos = 6;

/// Opens the photo editor for [listing]. True when the photos changed.
Future<bool> replaceListingPhotos(
  BuildContext context, {
  required ListingsRepository repo,
  required Listing listing,
}) async {
  final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ListingPhotosScreen(repo: repo, listing: listing),
  ));
  return changed == true;
}

class ListingPhotosScreen extends StatefulWidget {
  const ListingPhotosScreen({
    super.key,
    required this.repo,
    required this.listing,
    this.animateBackground = true,
  });

  final ListingsRepository repo;
  final Listing listing;

  /// False renders one still frame of the background (tests).
  final bool animateBackground;

  @override
  State<ListingPhotosScreen> createState() => _ListingPhotosScreenState();
}

class _ListingPhotosScreenState extends State<ListingPhotosScreen> {
  /// Ones already on BROKA: their asset id and the URL to show them by.
  late final List<({String id, String url})> _existing = [
    for (final p in widget.listing.photos)
      if (p.id.isNotEmpty) (id: p.id, url: p.medium),
  ];

  /// Photos from a listing saved before images were stored as assets: bare
  /// base64 in `verified_photos`, with no id to send back. They are shown so
  /// the seller sees what buyers see today - otherwise this page would look
  /// empty and invite them to "replace" photos they already have - but they
  /// cannot be kept individually: taking a new photo replaces them, which is
  /// what the media backfill would have done anyway.
  late final List<String> _legacy = widget.listing.photos.isEmpty
      ? _splitLegacyPhotos(widget.listing.verifiedPhotos)
      : const [];

  /// Every photo this listing would have after saving, for the counter.
  bool get _unchanged => _added.isEmpty;

  /// Photos taken on this phone, in the order they were shot.
  final List<File> _added = [];

  /// Splits a legacy `verified_photos` value - base64 chunks joined with
  /// commas - the way the backend does (api/domains/media/service.py's
  /// split_legacy_photos). A data URI has one comma of its own, so a chunk
  /// that is a data-URI header is rejoined with its payload.
  static List<String> _splitLegacyPhotos(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final parts = raw.split(',').map((p) => p.trim()).toList();
    final out = <String>[];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.startsWith('data:') && i + 1 < parts.length) {
        out.add('${parts[i]},${parts[i + 1]}');
        i++;
      } else if (part.isNotEmpty) {
        out.add(part);
      }
    }
    return out;
  }
  final _uploads = PhotoUploadTracker(purpose: ImagePurpose.listingPhoto);

  bool _saving = false;
  String? _error;

  /// How many stored photos the listing started with, so "did anything
  /// change?" has an answer even when the seller only removed one.
  ///
  /// Computed from the listing, not from [_existing]: a `late final` read
  /// here would run after any removal and report the post-removal count,
  /// making a real removal look like an unchanged page.
  int get _initialExisting =>
      widget.listing.photos.where((p) => p.id.isNotEmpty).length;

  @override
  void initState() {
    super.initState();
    _uploads.addListener(_onUploads);
  }

  @override
  void dispose() {
    _uploads.removeListener(_onUploads);
    _uploads.dispose();
    // Photos that were never saved are of no use to anyone.
    for (final f in _added) {
      _discard(f);
    }
    super.dispose();
  }

  void _onUploads() {
    if (mounted) setState(() {});
  }


  /// What a save would actually send. Legacy photos are not counted: they
  /// carry no id, so they are replaced wholesale by the first new photo -
  /// counting them would fill the six slots with pictures that cannot be
  /// removed and leave no way to add one.
  int get _count => _existing.length + _added.length;

  bool get _canAdd => _count < maxListingPhotos;

  Future<void> _take() async {
    if (!_canAdd) return;
    HapticFeedback.selectionClick();
    await PhotoCapture.takePhotos(
      context,
      alreadyTaken: _count,
      maxPhotos: maxListingPhotos,
      hint: 'The whole item in frame, in good light. Take the front, the back, '
          'and any marks or damage.',
      onCaptured: (photo) async {
        final kept = await _editPhotos.keep(photo, moveOriginal: true);
        if (!mounted) return kept;
        setState(() => _added.add(kept));
        _uploads.start(kept);
        return kept;
      },
    );
    if (mounted) setState(() {});
  }

  void _removeExisting(int i) {
    HapticFeedback.selectionClick();
    setState(() => _existing.removeAt(i));
  }

  void _removeAdded(int i) {
    HapticFeedback.selectionClick();
    final file = _added[i];
    setState(() => _added.removeAt(i));
    _uploads.remove(file);
    _discard(file);
  }

  Future<void> _save() async {
    // Nothing added and nothing removed: closing is the whole job.
    if (_unchanged && _existing.length == _initialExisting) {
      Navigator.of(context).pop(false);
      return;
    }
    if (_count == 0) {
      setState(() => _error = 'Keep at least one photo - buyers need to see the item.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });

    // Uploads usually finished long ago; this waits for any still running
    // and retries a failed one once, naming it if it still can't go.
    List<String> addedIds;
    try {
      addedIds = await _uploads.idsFor(_added);
    } on PhotoUploadIncomplete catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'A photo couldn\'t be uploaded (${e.reason}). '
            'Tap it to try again, or remove it.';
      });
      return;
    }

    final ids = [for (final p in _existing) p.id, ...addedIds];
    final result = await widget.repo.replacePhotos(widget.listing.id, ids);
    if (!mounted) return;

    switch (result) {
      case Success():
        // The kept files have done their job: they are on BROKA now.
        await _editPhotos.clear();
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Photos updated')));
        Navigator.of(context).pop(true);
      case Failure(:final message):
        setState(() {
          _saving = false;
          _error = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      flowTitle: widget.listing.name,
      position: 0,
      total: 1,
      title: 'Photos',
      subtitle: 'Swap the pictures buyers see. Take new ones now - '
          'gallery photos are not used for listings.',
      onNext: _saving ? null : _save,
      nextLabel: 'Save photos',
      nextIcon: Icons.check_rounded,
      loading: _saving,
      error: _error,
      animateBackground: widget.animateBackground,
      child: _grid(),
    );
  }

  Widget _grid() {
    final tiles = <Widget>[
      for (var i = 0; i < _existing.length; i++)
        _PhotoTile(
          key: Key('existing-photo-$i'),
          onRemove: _saving ? null : () => _removeExisting(i),
          child: BrokaImage(_existing[i].url, fit: BoxFit.cover),
        ),
      // Older photos with no asset id: shown, not removable one by one.
      for (var i = 0; i < _legacy.length; i++)
        _PhotoTile(
          key: Key('legacy-photo-$i'),
          label: 'Current',
          child: BrokaImage(_legacy[i], fit: BoxFit.cover),
        ),
      for (var i = 0; i < _added.length; i++)
        _PhotoTile(
          key: Key('new-photo-$i'),
          onRemove: _saving ? null : () => _removeAdded(i),
          state: _uploads.stateFor(_added[i]),
          onRetry: () => _uploads.start(_added[i]),
          child: Image.file(_added[i], fit: BoxFit.cover),
        ),
      if (_canAdd)
        _AddPhotoTile(
          key: const Key('add-photo'),
          onTap: _saving ? null : _take,
        ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$_count of $maxListingPhotos',
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5,
              fontWeight: FontWeight.w600)),      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: tiles,
      ),
      const SizedBox(height: 18),
      if (_legacy.isNotEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'The photos marked Current were uploaded by an older version of '
            'BROKA. Taking a new photo replaces them.',
            style: TextStyle(color: BrokaColors.warning, fontSize: 12.5, height: 1.45),
          ),
        ),
      const Text(
        'The first photo is what buyers see in search and on your store. '
        'Photos are taken with the camera, so buyers know the item is '
        'really in your hands.',
        style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.45),
      ),
    ]);
  }
}

void _discard(File file) {
  // Deliberately not awaited: this runs in dispose and after a remove,
  // where waiting would hold up the frame for a file deletion.
  _editPhotos.discard(file);
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    super.key,
    required this.child,
    this.onRemove,
    this.state,
    this.onRetry,
    this.label,
  });

  final Widget child;
  final VoidCallback? onRemove;
  final PhotoUploadState? state;
  final VoidCallback? onRetry;

  /// A small caption over the tile, e.g. "Current" for a photo that is on
  /// the listing but can't be removed on its own.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final uploading = s?.status == PhotoUploadStatus.uploading;
    final failed = s?.status == PhotoUploadStatus.failed;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(fit: StackFit.expand, children: [
        child,
        if (uploading)
          ColoredBox(
            color: Colors.black54,
            child: Center(
              child: SizedBox(
                width: 26, height: 26,
                child: CircularProgressIndicator(
                  value: s!.progress <= 0 ? null : s.progress,
                  strokeWidth: 2.4,
                  color: BrokaColors.gold,
                ),
              ),
            ),
          ),
        if (failed)
          Positioned.fill(
            child: Material(
              color: BrokaColors.bgMid.withOpacity(0.82),
              child: InkWell(
                onTap: onRetry,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.refresh_rounded, color: BrokaColors.gold, size: 22),
                  const SizedBox(height: 4),
                  Text('Retry', style: const TextStyle(color: BrokaColors.gold,
                      fontSize: 11, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        if (label != null)
          Positioned(
            bottom: 4, left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(label!, style: const TextStyle(color: Colors.white,
                  fontSize: 9.5, fontWeight: FontWeight.w700)),
            ),
          ),
        if (onRemove != null)
          Positioned(
            top: 4,
            right: 4,
            child: Semantics(
              button: true,
              label: 'Remove photo',
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 26, height: 26,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.62),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.5)),
                  ),
                  child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Take a photo',
        child: Material(
          color: BrokaColors.gold.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.45), width: 1.4),
              ),
              child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.photo_camera_rounded, color: BrokaColors.gold, size: 26),
                SizedBox(height: 6),
                Text('Take photo', style: TextStyle(color: BrokaColors.gold,
                    fontSize: 12, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ),
      );
}
