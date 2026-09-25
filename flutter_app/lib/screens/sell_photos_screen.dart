// BROKA - Sell Wizard Step 1: Photos
//
// Entry point for the /sell route (see main.dart). Owns the draft-restore
// check - every other step screen just receives the already-populated
// SellWizardData from whichever screen pushed it.
//
// "The app closes and I land on Home" while taking listing photos: that was
// Android killing BROKA while the phone's own camera app had the screen
// (see listing_camera_screen.dart). Three layers now, strongest first:
//   1. Photos are taken with BROKA's own camera screen. BROKA never leaves
//      the foreground, so it is not the process Android reclaims.
//   2. If that camera can't run on a phone, the phone's camera app is the
//      fallback - with the draft saved before it opens, the photo recovered
//      through image_picker's retrieveLostData() if BROKA is killed anyway,
//      and the splash screen reopening the draft (SellDraftStore).
//   3. A restored draft reopens at the step the seller was on (SellFlow),
//      with its photos kept in the app's own storage (SellPhotoStore), not
//      in a cache directory Android may empty.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../main.dart';
import '../services/photo_upload_tracker.dart';
import '../services/sell_draft_store.dart';
import '../services/sell_photo_store.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import 'listing_camera_screen.dart';
import 'sell_flow.dart';

class SellPhotosScreen extends StatefulWidget {
  const SellPhotosScreen({super.key, this.presetStoreId});

  /// Set when adding a product from My Store: the listing goes into that
  /// store (the review step still lets the seller change it).
  final String? presetStoreId;
  @override
  State<SellPhotosScreen> createState() => _SellPhotosScreenState();
}

class _SellPhotosScreenState extends State<SellPhotosScreen> {
  SellWizardData _data = SellWizardData();
  bool _draftRestored = false;
  // Saved moments ago: the app was killed mid-flow (the camera, the
  // gallery, another app), and the seller is coming straight back.
  bool _draftIsFresh = false;
  String? _error;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _initPhotos();
  }

  /// Runs draft-restore and lost-data recovery in sequence, not in parallel
  /// (both are independently async off initState). If they ran concurrently
  /// and lost-data resolved first, _restoreDraftIfAny's `_data = restored`
  /// would silently overwrite it with a fresh instance and drop the photo
  /// it just recovered - since retrieveLostData() only ever knows about a
  /// photo the draft never had a chance to persist (see below).
  Future<void> _initPhotos() async {
    await _restoreDraftIfAny();
    if (widget.presetStoreId != null) _data.storeId = widget.presetStoreId;
    await _retrieveLostPhotoIfAny();
    // Restored photos that never finished uploading carry on now.
    for (final f in _data.verifiedPhotos) {
      _startUpload(f);
    }
    // Back to the step the seller was on when the app was killed. Only for
    // a draft saved moments ago: one left for days was put down on
    // purpose, and reopening it deep in the flow would drop the seller
    // somewhere they didn't choose to be - it opens here, with the
    // "saved" banner and Start over.
    if (_draftRestored && _draftIsFresh && mounted && _data.resumeStep > SellFlow.photos) {
      SellFlow.resume(context, _data);
    }
  }

  /// Uploads [file] in the background (a no-op if it already has been),
  /// and saves the draft again once it lands so its id survives a restart.
  void _startUpload(File file) {
    final tracker = _data.photoUploads;
    tracker.start(file);
    late final VoidCallback onChange;
    onChange = () {
      final status = tracker.stateFor(file)?.status;
      if (status == PhotoUploadStatus.done || status == PhotoUploadStatus.failed ||
          status == null) {
        tracker.removeListener(onChange);
        if (status == PhotoUploadStatus.done) unawaited(_data.persist());
      }
    };
    tracker.addListener(onChange);
  }

  Future<void> _restoreDraftIfAny() async {
    final draft = await SellDraftStore.load();
    if (draft == null || !mounted) return;
    final restored = SellWizardData.fromDraftJson(draft);
    if (restored == null) {
      await SellDraftStore.clear();
      return;
    }
    final savedAt = DateTime.tryParse(draft['savedAt'] as String? ?? '');
    setState(() {
      _data = restored;
      _draftRestored = true;
      _draftIsFresh = savedAt != null &&
          DateTime.now().difference(savedAt) < SellFlow.resumeWindow;
    });
  }

  /// Recovers the one photo SellDraftStore structurally can't: the capture
  /// that was still in flight the instant Android killed BROKA's process,
  /// when the phone's own camera app was used (the fallback path - BROKA's
  /// own camera can't be the victim). _takeWithPhoneCamera() persists the
  /// draft right before the camera opens, so every photo taken before is
  /// safe - but the shot being taken at that point was never added to
  /// _data. retrieveLostData() is image_picker's own channel for exactly
  /// this. It no-ops (isEmpty) wherever nothing was lost.
  ///
  /// It can't say what the image was FOR, though: a cover picked from the
  /// gallery on the Cover image step arrives here the same way, and used to
  /// be added as a camera-verified photo. pendingPick, saved before either
  /// picker opens, says which it was.
  Future<void> _retrieveLostPhotoIfAny() async {
    try {
      final response = await _picker.retrieveLostData();
      final pending = _data.pendingPick;
      _data.pendingPick = null;
      if (response.isEmpty || response.file == null || !mounted) return;
      final lost = File(response.file!.path);
      if (pending == 'showcase') {
        final kept = await SellPhotoStore.keep(lost);
        _data.setGalleryShowcase(kept.path);
        unawaited(_data.persist());
        return;
      }
      if (pending != 'camera') return;
      if (_data.verifiedPhotos.any((f) => f.path == lost.path)) return;
      if (_data.verifiedPhotos.length >= SellWizardData.maxPhotos) return;
      final kept = await SellPhotoStore.keep(lost, moveOriginal: true);
      setState(() => _data.verifiedPhotos.add(kept));
      unawaited(_data.persist());
      _startUpload(kept);
    } catch (_) {
      // Non-fatal - worst case this one photo still needs a retake.
    }
  }

  void _discardDraft() {
    SellDraftStore.clear();
    SellPhotoStore.clear();
    setState(() {
      _data = SellWizardData()..storeId = widget.presetStoreId;
      _draftRestored = false;
    });
  }

  Future<File> _addPhoto(File captured, {required bool moveOriginal}) async {
    final kept = await SellPhotoStore.keep(captured, moveOriginal: moveOriginal);
    if (!mounted) return kept;
    setState(() {
      _data.verifiedPhotos.add(kept);
      _error = null;
    });
    await _data.persist();
    _startUpload(kept);
    return kept;
  }

  Future<void> _takePhotos() async {
    if (_data.verifiedPhotos.length >= SellWizardData.maxPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Maximum 6 photos allowed'),
          backgroundColor: BrokaColors.bgCard));
      return;
    }
    // Saved first anyway: cheap, and it covers every way out of the camera.
    await _data.persist();
    if (!mounted) return;
    final usePhoneCamera = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ListingCameraScreen(
        alreadyTaken: _data.verifiedPhotos.length,
        maxPhotos: SellWizardData.maxPhotos,
        onCaptured: (file) => _addPhoto(file, moveOriginal: true),
      ),
    ));
    if (usePhoneCamera == true && mounted) await _takeWithPhoneCamera();
  }

  /// The fallback: the phone's own camera app. The draft (with the marker
  /// saying a camera photo is pending) is saved right before it opens -
  /// the moment BROKA hands off the foreground and becomes most likely to
  /// be killed.
  Future<void> _takeWithPhoneCamera() async {
    _data.pendingPick = 'camera';
    await _data.persist();
    XFile? xfile;
    try {
      xfile = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 75,
        maxWidth: 1080,
      );
    } catch (_) {
      if (mounted) setState(() => _error = "The camera couldn't open. Check BROKA's camera permission.");
    } finally {
      _data.pendingPick = null;
    }
    if (xfile != null && mounted) {
      await _addPhoto(File(xfile.path), moveOriginal: true);
    } else {
      unawaited(_data.persist());
    }
  }

  void _removePhoto(int i) {
    final removed = _data.verifiedPhotos[i];
    setState(() => _data.verifiedPhotos.removeAt(i));
    _data.photoUploads.remove(removed);
    unawaited(_data.persist());
    unawaited(SellPhotoStore.discard(removed));
  }

  /// Progress ring while a photo uploads, a tick when it's done, and a
  /// tap-to-retry badge if it failed. Publishing retries a failed upload
  /// too, so a missed tap here never loses the listing.
  Widget _uploadBadge(File file, double size) => ListenableBuilder(
        listenable: _data.photoUploads,
        builder: (_, __) {
          final state = _data.photoUploads.stateFor(file);
          if (state == null) return const SizedBox.shrink();
          switch (state.status) {
            case PhotoUploadStatus.uploading:
              return Container(
                width: size, height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SizedBox(
                  width: 26, height: 26,
                  child: CircularProgressIndicator(
                    value: state.progress > 0 ? state.progress : null,
                    strokeWidth: 2.5, color: Colors.white,
                  ),
                ),
              );
            case PhotoUploadStatus.done:
              return const Positioned(
                left: 8, bottom: 8,
                child: Icon(Icons.check_circle_rounded, size: 20, color: Color(0xFF4DD6A5)),
              );
            case PhotoUploadStatus.failed:
              return GestureDetector(
                onTap: () => _startUpload(file),
                child: Container(
                  width: size, height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.refresh_rounded, color: Colors.white, size: 22),
                    SizedBox(height: 2),
                    Text('Retry', style: TextStyle(color: Colors.white, fontSize: 11,
                        fontWeight: FontWeight.w700)),
                  ]),
                ),
              );
          }
        },
      );

  void _next() {
    if (_data.verifiedPhotos.isEmpty) {
      setState(() => _error = 'Please take at least one verified photo (camera required).');
      return;
    }
    setState(() => _error = null);
    SellFlow.next(context, _data, from: SellFlow.photos);
  }

  @override
  Widget build(BuildContext context) {
    final photos = _data.verifiedPhotos;
    return SellStepScaffold(
      step: SellFlow.photos, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.photos),
      subtitle: 'Real photos of the real item - buyers trust what they can see.',
      data: _data,
      error: _error,
      onNext: _next,
      topBanner: _draftRestored ? Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: BrokaColors.neonBlue.withOpacity(0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
        ),
        child: Row(children: [
          const Icon(Icons.restore_rounded, size: 16, color: BrokaColors.neonBlue),
          const SizedBox(width: 8),
          const Expanded(child: Text(
            'Your listing was saved - pick up where you left off',
            style: TextStyle(color: BrokaColors.neonBlue, fontSize: 11.5, fontWeight: FontWeight.w600),
          )),
          GestureDetector(
            onTap: _discardDraft,
            child: const Text('Start over', style: TextStyle(
                color: BrokaColors.textMid, fontSize: 11.5,
                fontWeight: FontWeight.w700, decoration: TextDecoration.underline)),
          ),
        ]),
      ) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SellCard(
          child: Row(children: [
            Container(
              width: 38, height: 38,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
                boxShadow: [BrokaColors.glowGold],
              ),
              child: const Icon(Icons.verified_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CAMERA-VERIFIED PHOTOS', style: TextStyle(
                    color: BrokaColors.gold, fontSize: 10.5,
                    fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                SizedBox(height: 3),
                Text('Taken live with the camera, never from the gallery - so buyers know '
                    "they're looking at your item, not a picture from the internet.",
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4)),
              ],
            )),
          ]),
        ),
        const SizedBox(height: 18),
        Row(children: [
          sellStepLabel('YOUR PHOTOS'),
          const Spacer(),
          Text('${photos.length} / ${SellWizardData.maxPhotos}', style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 11.5, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (_, box) {
          final tile = (box.maxWidth - 16) / 3;
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < photos.length; i++)
              TweenAnimationBuilder<double>(
                key: ValueKey(photos[i].path),
                tween: Tween(begin: 0.6, end: 1),
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                child: SizedBox(
                  width: tile, height: tile,
                  child: Stack(children: [
                    Container(
                      width: tile, height: tile,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: i == 0 ? BrokaColors.gold : BrokaColors.gold.withOpacity(0.35),
                            width: i == 0 ? 1.8 : 1),
                      ),
                      clipBehavior: Clip.antiAlias,
                      // Decoded at thumbnail size: six full-size photos
                      // decoded for 110px tiles is tens of MB of memory -
                      // the kind of pressure that gets an app killed.
                      child: Image.file(photos[i], fit: BoxFit.cover,
                          cacheWidth: (tile * 2.5).round(),
                          errorBuilder: (_, __, ___) =>
                              const ColoredBox(color: BrokaColors.bgCard)),
                    ),
                    _uploadBadge(photos[i], tile),
                    if (i == 0)
                      Positioned(
                        left: 6, top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: BrokaColors.gold,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text('MAIN', style: TextStyle(color: Colors.white,
                              fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                        ),
                      ),
                    Positioned(top: 5, right: 5,
                      child: Semantics(
                        button: true,
                        label: 'Remove photo ${i + 1}',
                        child: GestureDetector(
                          onTap: () => _removePhoto(i),
                          child: Container(
                            width: 24, height: 24,
                            decoration: const BoxDecoration(
                              color: BrokaColors.danger,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close, size: 14, color: Colors.white),
                          ),
                        ),
                      )),
                  ]),
                ),
              ),
            if (photos.length < SellWizardData.maxPhotos)
              _AddPhotoTile(size: tile, first: photos.isEmpty, onTap: _takePhotos),
          ]);
        }),
        const SizedBox(height: 16),
        const Text(
          'Tip: the first photo is the one buyers see first. Shoot in daylight, '
          'fill the frame, and show any wear honestly - it prevents disputes later.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.45),
        ),
      ]),
    );
  }
}

class _AddPhotoTile extends StatefulWidget {
  const _AddPhotoTile({required this.size, required this.first, required this.onTap});
  final double size;
  final bool first;
  final VoidCallback onTap;

  @override
  State<_AddPhotoTile> createState() => _AddPhotoTileState();
}

class _AddPhotoTileState extends State<_AddPhotoTile> with SingleTickerProviderStateMixin {
  late final AnimationController _glow;

  @override
  void initState() {
    super.initState();
    _glow = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _glow.stop();
    } else if (!_glow.isAnimating) {
      _glow.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Take photos',
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedBuilder(
            animation: _glow,
            builder: (_, child) => Container(
              width: widget.size, height: widget.size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: BrokaColors.gold.withOpacity(0.08 + 0.06 * _glow.value),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.45 + 0.3 * _glow.value),
                    width: 1.4),
                boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.18 * _glow.value),
                    blurRadius: 16)],
              ),
              child: child,
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.photo_camera_rounded, color: BrokaColors.gold, size: 28),
              const SizedBox(height: 6),
              Text(widget.first ? 'Take photos' : 'Add more',
                  style: const TextStyle(color: BrokaColors.gold, fontSize: 12,
                      fontWeight: FontWeight.w800)),
            ]),
          ),
        ),
      );
}
