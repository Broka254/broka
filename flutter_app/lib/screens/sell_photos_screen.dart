// BROKA - Sell Wizard Step 1: Photos
//
// Entry point for the /sell route (see main.dart). Owns the initial
// draft-restore check that used to live in SellScreen.initState() - every
// other step screen just receives the already-populated SellWizardData
// from whichever screen pushed it.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../main.dart';
import '../services/sell_draft_store.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_basics_screen.dart';

class SellPhotosScreen extends StatefulWidget {
  const SellPhotosScreen({super.key});
  @override
  State<SellPhotosScreen> createState() => _SellPhotosScreenState();
}

class _SellPhotosScreenState extends State<SellPhotosScreen> {
  SellWizardData _data = SellWizardData();
  bool _draftRestored = false;
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
    await _retrieveLostPhotoIfAny();
  }

  Future<void> _restoreDraftIfAny() async {
    final draft = await SellDraftStore.load();
    if (draft == null || !mounted) return;
    final restored = SellWizardData.fromDraftJson(draft);
    if (restored == null) {
      await SellDraftStore.clear();
      return;
    }
    setState(() {
      _data = restored;
      _draftRestored = true;
    });
  }

  /// Recovers the one photo SellDraftStore structurally can't: the capture
  /// that was still in flight the instant Android killed BROKA's process.
  /// _takePhoto() persists the draft right before launching the camera, so
  /// every photo taken *before* that point is safe - but the shot being
  /// taken *at* that point was never added to _data, so there was nothing
  /// to persist for it. Its pickImage() Future is gone too: the isolate
  /// that was awaiting it no longer exists after a cold restart, so it can
  /// never resolve on its own. retrieveLostData() is image_picker's own
  /// channel for exactly this - Android delivers the camera result to the
  /// new process instead, separately from the abandoned Future. This is
  /// almost certainly why photo 1 specifically vanishes with no draft to
  /// fall back on: there's nothing upstream of it to have been persisted.
  /// Safe to call unconditionally - it's a no-op (isEmpty) on any platform
  /// or launch where nothing was actually lost.
  Future<void> _retrieveLostPhotoIfAny() async {
    try {
      final response = await _picker.retrieveLostData();
      if (response.isEmpty || response.file == null || !mounted) return;
      final path = response.file!.path;
      if (_data.verifiedPhotos.any((f) => f.path == path)) return;
      setState(() => _data.verifiedPhotos.add(File(path)));
      unawaited(_data.persist());
    } catch (_) {
      // Non-fatal - worst case this one photo still needs a retake, same
      // as before this fix, rather than surfacing a raw error for something
      // the user already just experienced as "the app acting up".
    }
  }

  void _discardDraft() {
    SellDraftStore.clear();
    setState(() {
      _data = SellWizardData();
      _draftRestored = false;
    });
  }

  /// Called right before the camera launch - the moment BROKA hands off
  /// the foreground and becomes most likely to be killed - so photos
  /// already taken are recoverable even if this capture never returns.
  Future<void> _takePhoto() async {
    if (_data.verifiedPhotos.length >= 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Maximum 6 photos allowed'),
          backgroundColor: BrokaColors.bgCard));
      return;
    }
    await _data.persist();
    final xfile = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 75,
      maxWidth: 1080,
    );
    if (xfile != null && mounted) {
      setState(() => _data.verifiedPhotos.add(File(xfile.path)));
      unawaited(_data.persist());
    }
  }

  void _removePhoto(int i) {
    setState(() => _data.verifiedPhotos.removeAt(i));
    unawaited(_data.persist());
  }

  void _next() {
    if (_data.verifiedPhotos.isEmpty) {
      setState(() => _error = 'Please take at least one verified photo (camera required).');
      return;
    }
    setState(() => _error = null);
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SellBasicsScreen(data: _data),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SellStepScaffold(
      step: 1, totalSteps: 7, title: 'Photos',
      error: _error,
      onNext: _next,
      topBanner: _draftRestored ? Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: BrokaColors.neonBlue.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.3)),
        ),
        child: Row(children: [
          const Icon(Icons.restore_rounded, size: 16, color: BrokaColors.neonBlue),
          const SizedBox(width: 8),
          const Expanded(child: Text(
            "Draft restored from before - pick up where you left off",
            style: TextStyle(color: BrokaColors.neonBlue, fontSize: 11.5, fontWeight: FontWeight.w600),
          )),
          GestureDetector(
            onTap: _discardDraft,
            child: const Text('Discard', style: TextStyle(
                color: BrokaColors.textMid, fontSize: 11.5,
                fontWeight: FontWeight.w700, decoration: TextDecoration.underline)),
          ),
        ]),
      ) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Info strip - futuristic
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              BrokaColors.gold.withOpacity(0.07),
              BrokaColors.neonBlue.withOpacity(0.03),
            ], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.gold.withOpacity(0.2)),
          ),
          child: Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                    colors: [BrokaColors.gold, BrokaColors.goldDim]),
                boxShadow: const [BrokaColors.glowGold],
              ),
              child: const Icon(Icons.smart_toy_outlined,
                  color: Colors.white, size: 17),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI-POWERED LISTING', style: TextStyle(
                    color: BrokaColors.gold, fontSize: 10,
                    fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                SizedBox(height: 3),
                Text('BROKA AI will match you with vetted buyers. 3% commission - fully transparent.',
                    style: TextStyle(color: BrokaColors.textMid,
                        fontSize: 11, height: 1.4)),
              ],
            )),
          ]),
        ),

        sellStepLabel('VERIFIED PHOTOS  (camera only - required)'),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Text('📷 Photos must be taken directly from your camera. '
              'This prevents fake/AI-generated images and builds buyer trust.',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.4)),
        ),
        const SizedBox(height: 10),

        if (_data.verifiedPhotos.isNotEmpty) ...[
          SizedBox(
            height: 90,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _data.verifiedPhotos.length,
              itemBuilder: (_, i) => Stack(
                children: [
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    width: 90, height: 90,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: BrokaColors.gold.withOpacity(0.5)),
                      image: DecorationImage(
                        image: FileImage(_data.verifiedPhotos[i]),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Positioned(top: 4, right: 12,
                    child: GestureDetector(
                      onTap: () => _removePhoto(i),
                      child: Container(
                        width: 20, height: 20,
                        decoration: const BoxDecoration(
                          color: BrokaColors.danger,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, size: 12, color: Colors.white),
                      ),
                    )),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],

        GestureDetector(
          onTap: _takePhoto,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            decoration: BoxDecoration(
              color: BrokaColors.gold.withOpacity(0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
            ),
            child: Row(children: [
              const Icon(Icons.camera_alt_rounded, color: BrokaColors.gold, size: 22),
              const SizedBox(width: 12),
              const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Take Photo with Camera', style: TextStyle(color: BrokaColors.gold,
                    fontWeight: FontWeight.w700, fontSize: 13)),
                SizedBox(height: 2),
                Text('Gallery not allowed - camera only', style: TextStyle(
                    color: BrokaColors.textLow, fontSize: 10)),
              ])),
              Icon(Icons.arrow_forward_ios_rounded, color: BrokaColors.gold.withOpacity(0.5), size: 14),
            ]),
          ),
        ),
      ]),
    );
  }
}
