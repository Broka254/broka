// BROKA - Sell Wizard Step 8: Cover image (optional)
//
// The picture a listing shows on Home: the seller's own first photo, a
// cover picked from the gallery, or one made by AI from that photo in a
// look the seller chooses. The seller's camera photos stay what buyers
// inspect on the listing itself, whatever is chosen here.
//
// 2026-09-25 rework. What was wrong with the old step, and what replaced it:
//   * The AI result came back as a base64 data URI of a megabyte or two,
//     was held in memory as a string, decoded again on every rebuild (so
//     the preview re-decoded and flickered as the seller typed), was lost
//     if Android killed the app, and was uploaded again at Activate. The
//     server now stores it as the seller's image and returns an id and
//     URLs (ShowcaseGenerator); the draft keeps the id.
//   * The seller's photo was re-sent as base64 on every generation. It was
//     uploaded when it was taken; the request now names it by id.
//   * A result arriving after the seller had left the step called
//     setState on a disposed screen. Results are now matched to the
//     request that asked for them, and dropped if the screen is gone or
//     the seller cancelled.
//   * A gallery pick opens another app, and if Android killed BROKA
//     meanwhile the picked image came back as a camera-verified listing
//     photo. The draft now records that a cover pick was pending.
//   * The look was a free-text box. It is now a choice of six, each shown
//     as a picture of the look (cover_theme_art.dart), with the one most
//     sellers of this category would pick marked as Zeno's pick.
//
// AI covers are a premium feature (PRICING.md section 4): a few free tries,
// then a plan's monthly tries. The step says how many are left, and once
// they are gone the button leads to the plans instead of a refusal. A cover
// from the gallery stays free.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/network/api_client.dart';
import '../core/utils/result.dart';
import '../features/premium/data/premium_repository.dart';
import '../features/premium/domain/premium.dart';
import '../features/premium/presentation/premium_upsell.dart';
import '../main.dart';
import '../services/photo_upload_tracker.dart';
import '../services/sell_photo_store.dart';
import '../services/sell_wizard_data.dart';
import '../services/showcase_generator.dart';
import '../widgets/broka_image.dart';
import '../widgets/cover_theme_art.dart';
import '../widgets/gradient_button.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_flow.dart';

class SellShowcaseScreen extends StatefulWidget {
  final SellWizardData data;

  /// For tests.
  final ShowcaseGenerator? generator;
  final PremiumRepository? premium;

  const SellShowcaseScreen({super.key, required this.data, this.generator, this.premium});
  @override
  State<SellShowcaseScreen> createState() => _SellShowcaseScreenState();
}

class _SellShowcaseScreenState extends State<SellShowcaseScreen> with TickerProviderStateMixin {
  final _picker = ImagePicker();
  final _noteCtrl = TextEditingController();
  late final ShowcaseGenerator _generator = widget.generator ?? ShowcaseGenerator();

  // One clock for every moving thing on the step (theme previews, the
  // hologram scan line), so they stay in step and cost one ticker.
  late final AnimationController _ambient;

  late String _theme;
  bool _noteOpen = false;
  bool _generating = false;
  bool _pickingGallery = false;
  String? _error;

  // What the seller's plan leaves of AI covers; null until known, and then
  // the step behaves as before (the server still decides).
  PremiumStatus? _premium;

  // A result awaiting "Use this cover" - not in the draft yet.
  GeneratedCover? _result;
  String? _resultTheme;

  // Which request a result belongs to: a result for an older request (or
  // one the seller cancelled) is ignored.
  int _request = 0;

  SellWizardData get _data => widget.data;
  File? get _photo => _data.verifiedPhotos.isEmpty ? null : _data.verifiedPhotos.first;
  bool get _still => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    _ambient = AnimationController(vsync: this, duration: const Duration(seconds: 8));
    _theme = _data.showcaseTheme ?? ShowcaseGenerator.recommendedFor(_data.category);
    _loadPremium();
  }

  Future<void> _loadPremium() async {
    final r = await (widget.premium ?? premiumRepository).me();
    if (mounted && r is Success<PremiumStatus>) setState(() => _premium = r.data);
  }

  /// No AI cover tries left, as far as the app knows.
  bool get _coversLocked => !(_premium?.canUse(PremiumFeature.aiCovers) ?? true);

  /// "3 of 20 AI cover tries left this month" - or nothing while premium
  /// is off or unknown.
  String? get _coversLeftText {
    final p = _premium;
    if (p == null || !p.enabled) return null;
    final left = p.left(PremiumFeature.aiCovers);
    if (p.hasPlan) {
      final all = p.usage[PremiumFeature.aiCovers]?.allowance ?? 0;
      return '$left of $all AI cover tries left this month';
    }
    if (left == 0) return null;
    return left == 1 ? '1 free AI cover try left' : '$left free AI cover tries left';
  }

  /// The plans, when the tries are gone - in the words the server would use.
  Future<void> _offerPlans(String message, {String? upgradeTo}) async {
    final opened = await showPremiumUpsell(context, message: message, upgradeTo: upgradeTo);
    if (opened && mounted) {
      setState(() => _error = null);
      await _loadPremium();
    }
  }

  void _lockedTap() {
    final p = _premium!;
    final renews = p.renewsAt;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final message = p.hasPlan
        ? "You've used this month's AI cover tries on BROKA ${p.planName}"
            '${renews == null ? '.' : '. They renew on ${renews.day} ${months[renews.month - 1]}.'}'
        : "You've used your free AI cover tries. A BROKA plan gives you more every month.";
    _offerPlans('$message You can still upload a cover from your gallery, free.');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_still) {
      _ambient.stop();
    } else if (!_ambient.isAnimating) {
      _ambient.repeat();
    }
  }

  @override
  void dispose() {
    _request++;
    _ambient.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  CoverTheme get _themeInfo =>
      ShowcaseGenerator.themes.firstWhere((t) => t.id == _theme, orElse: () => ShowcaseGenerator.themes.first);

  Future<void> _generate() async {
    final photo = _photo;
    if (photo == null || _generating) return;
    final request = ++_request;
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      // The first photo's upload id; waits for the upload if it's still
      // running and retries it once if it failed.
      final ids = await _data.photoUploads.idsFor([photo]);
      final cover = await _generator.generate(
        photoId: ids.first,
        name: _data.name,
        category: _data.category,
        theme: _theme,
        condition: _data.condition,
        note: _noteCtrl.text,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _result = cover;
        _resultTheme = _theme;
      });
      // A try was spent: keep the count honest.
      if (_premium?.enabled ?? false) _loadPremium();
    } on PhotoUploadIncomplete {
      if (mounted && request == _request) {
        setState(() => _error = "Your photo hasn't finished uploading. Check your connection and try again.");
      }
    } on ApiException catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = e.message);
      if (isPlanRefusal(e.statusCode)) {
        // The app's count was behind the server's (another phone, or a
        // month that just turned): show the server's reason and the plans.
        setState(() => _generating = false);
        await _loadPremium();
        if (mounted) await _offerPlans(e.message, upgradeTo: upgradeToOf(e));
      }
    } on TimeoutException {
      if (mounted && request == _request) {
        setState(() => _error = 'That took too long - your connection may be slow. Please try again.');
      }
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = "Couldn't reach BROKA. Check your connection and try again.");
      }
    } finally {
      if (mounted && request == _request) setState(() => _generating = false);
    }
  }

  void _cancel() {
    _request++;
    setState(() => _generating = false);
  }

  void _useResult() {
    final result = _result;
    if (result == null) return;
    setState(() {
      _data.setAiShowcase(assetId: result.assetId, previewUrl: result.previewUrl, theme: _resultTheme);
      _result = null;
    });
    _data.persist();
  }

  Future<void> _pickFromGallery() async {
    setState(() {
      _pickingGallery = true;
      _error = null;
    });
    // If Android kills BROKA while the gallery is open, the picked image
    // arrives on the next launch through retrieveLostData(); this says it
    // was a cover, not a listing photo (see SellPhotosScreen).
    _data.pendingPick = 'showcase';
    await _data.persist();
    try {
      // Bounded like every other picked image: a full-size gallery photo
      // can pass the server's 10 MB upload limit and fail only at Activate,
      // and nothing larger than 1600 px is ever stored.
      final xfile = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 85, maxWidth: 2048, maxHeight: 2048,
      );
      _data.pendingPick = null;
      if (xfile == null) {
        await _data.persist();
        return;
      }
      final kept = await SellPhotoStore.keep(File(xfile.path));
      if (!mounted) return;
      setState(() {
        _data.setGalleryShowcase(kept.path);
        _result = null;
      });
      await _data.persist();
    } catch (_) {
      _data.pendingPick = null;
      if (mounted) setState(() => _error = "Couldn't open your gallery. Check BROKA's photo permission.");
    } finally {
      if (mounted) setState(() => _pickingGallery = false);
    }
  }

  void _removeCover() {
    setState(() {
      _data.clearShowcase();
      _result = null;
    });
    _data.persist();
  }

  void _next() => SellFlow.next(context, _data, from: SellFlow.showcase);

  @override
  Widget build(BuildContext context) {
    final hasPhoto = _photo != null;
    return Stack(children: [
      SellStepScaffold(
        step: SellFlow.showcase, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.showcase),
        subtitle: 'Optional. The picture your listing shows on Home - make it stand out.',
        data: _data,
        error: _error,
        nextLabel: _data.hasShowcase ? 'CONTINUE' : 'SKIP - USE MY PHOTO',
        onNext: _generating ? null : _next,
        child: !hasPhoto
            ? const SellCard(child: Text('Take your product photos first - go back to the Photos step.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _hero(),
                const SizedBox(height: 14),
                if (_result != null) _resultActions() else ...[
                  if (_data.hasShowcase) _coverActions(),
                  const SizedBox(height: 8),
                  _themePicker(),
                  const SizedBox(height: 14),
                  _noteField(),
                  const SizedBox(height: 16),
                  _MagicButton(
                    key: const Key('showcase-generate'),
                    label: _coversLocked ? '🔒  Get more AI covers' : '✨  Create my ${_themeInfo.name} cover',
                    animation: _ambient,
                    onPressed: _generating ? null : (_coversLocked ? _lockedTap : _generate),
                  ),
                  if (_coversLeftText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Center(
                        child: Text(_coversLeftText!,
                            key: const Key('showcase-tries-left'),
                            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Row(children: [
                    Expanded(child: Divider(color: BrokaColors.border.withOpacity(0.9))),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: Text('or', style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                    ),
                    Expanded(child: Divider(color: BrokaColors.border.withOpacity(0.9))),
                  ]),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _pickingGallery || _generating ? null : _pickFromGallery,
                    icon: _pickingGallery
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.textMid))
                        : const Icon(Icons.photo_library_outlined, color: BrokaColors.textMid, size: 18),
                    label: const Text('Upload a cover from my gallery', style: TextStyle(
                        color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      side: const BorderSide(color: BrokaColors.border),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text('Buyers still inspect your camera photos on the listing itself - '
                      'the AI only changes the setting, never the item.',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 11, height: 1.4)),
                ],
              ]),
      ),
      if (_generating && _photo != null)
        Positioned.fill(
          child: _GeneratingOverlay(
            photo: _photo!,
            themeName: _themeInfo.name,
            still: _still,
            onCancel: _cancel,
          ),
        ),
    ]);
  }

  /// The big picture at the top: the new result (revealed, with a
  /// before/after slider), the chosen cover, or the seller's own photo.
  Widget _hero() {
    final photo = _photo!;
    final result = _result;
    Widget content;
    String label;
    if (result != null) {
      label = '✨ ${ShowcaseGenerator.themes.firstWhere((t) => t.id == _resultTheme, orElse: () => _themeInfo).name} · drag to compare';
      content = _Reveal(
        key: ValueKey(result.assetId),
        still: _still,
        child: _CompareSlider(
          before: Image.file(photo, fit: BoxFit.cover, cacheWidth: 900,
              errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard)),
          after: BrokaImage(result.previewUrl, fit: BoxFit.cover),
          still: _still,
        ),
      );
    } else if (_data.showcaseLocalPath != null) {
      label = 'YOUR COVER PHOTO';
      content = Image.file(File(_data.showcaseLocalPath!), fit: BoxFit.cover, cacheWidth: 900,
          errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard));
    } else if (_data.showcasePreviewUrl != null) {
      label = '✨ AI COVER';
      content = BrokaImage(_data.showcasePreviewUrl, fit: BoxFit.cover);
    } else {
      label = 'YOUR PHOTO';
      content = Stack(fit: StackFit.expand, children: [
        Image.file(photo, fit: BoxFit.cover, cacheWidth: 900,
            errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard)),
        if (!_still) _ScanLine(animation: _ambient),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      sellStepLabel(label.toUpperCase()),
      const SizedBox(height: 8),
      _HologramFrame(
        animation: _ambient,
        // 4:3, the shape of a listing card's picture.
        child: AspectRatio(aspectRatio: 4 / 3, child: content),
      ),
    ]);
  }

  Widget _resultActions() => Column(children: [
        GradientButton(
          key: const Key('showcase-use'),
          height: 52,
          onPressed: _useResult,
          child: const Text('USE THIS COVER', style: TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            onPressed: () => setState(() => _result = null),
            icon: const Icon(Icons.palette_outlined, size: 18, color: BrokaColors.textHigh),
            label: const Text('Another look', style: TextStyle(color: BrokaColors.textHigh,
                fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              side: const BorderSide(color: BrokaColors.border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          )),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(
            onPressed: _generating ? null : (_coversLocked ? _lockedTap : _generate),
            icon: const Icon(Icons.refresh_rounded, size: 18, color: BrokaColors.textHigh),
            label: const Text('Regenerate', style: TextStyle(color: BrokaColors.textHigh,
                fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              side: const BorderSide(color: BrokaColors.border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          )),
        ]),
      ]);

  Widget _coverActions() => Row(children: [
        const Icon(Icons.check_circle_rounded, color: BrokaColors.success, size: 18),
        const SizedBox(width: 6),
        const Expanded(child: Text('This is your cover. Pick another look to change it.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12))),
        TextButton(
          onPressed: _removeCover,
          child: const Text('Remove', style: TextStyle(color: BrokaColors.danger,
              fontWeight: FontWeight.w700)),
        ),
      ]);

  Widget _themePicker() {
    final recommended = ShowcaseGenerator.recommendedFor(_data.category);
    // Zeno's pick first: it's the one selected to begin with, and a
    // selected look scrolled off to the right is a choice the seller
    // never sees being made.
    final themes = [
      ...ShowcaseGenerator.themes.where((t) => t.id == recommended),
      ...ShowcaseGenerator.themes.where((t) => t.id != recommended),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      sellStepLabel('PICK A LOOK'),
      const SizedBox(height: 10),
      SizedBox(
        height: 188,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: themes.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) {
            final theme = themes[i];
            return _ThemeTile(
              key: Key('showcase-theme-${theme.id}'),
              theme: theme,
              selected: theme.id == _theme,
              recommended: theme.id == recommended,
              animation: _ambient,
              onTap: () => setState(() => _theme = theme.id),
            );
          },
        ),
      ),
    ]);
  }

  Widget _noteField() => AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _noteOpen
            ? TextField(
                controller: _noteCtrl,
                maxLength: 150,
                maxLines: 2,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Anything to add? e.g. "on a beach at sunset"',
                ),
              )
            : Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _noteOpen = true),
                  icon: const Icon(Icons.add_rounded, size: 18, color: BrokaColors.gold),
                  label: const Text('Add a detail (optional)', style: TextStyle(
                      color: BrokaColors.gold, fontWeight: FontWeight.w700)),
                ),
              ),
      );
}

// ── Pieces ────────────────────────────────────────────────────────────────

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    super.key,
    required this.theme,
    required this.selected,
    required this.recommended,
    required this.animation,
    required this.onTap,
  });
  final CoverTheme theme;
  final bool selected;
  final bool recommended;
  final Animation<double> animation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${theme.name} look',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          scale: selected ? 1.0 : 0.93,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            width: 132,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: selected
                  ? const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonCyan])
                  : null,
              color: selected ? null : BrokaColors.border,
              boxShadow: selected
                  ? [BoxShadow(color: BrokaColors.gold.withOpacity(0.5), blurRadius: 20)]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(fit: StackFit.expand, children: [
                RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: animation,
                    builder: (_, __) => CustomPaint(
                        painter: coverThemePainter(theme.id, selected ? animation.value : 0.2)),
                  ),
                ),
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(9, 18, 9, 9),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xDD000000)],
                      ),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(theme.name, style: const TextStyle(color: Colors.white,
                          fontSize: 12.5, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 1),
                      Text(theme.tagline, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 9.5, height: 1.2)),
                    ]),
                  ),
                ),
                if (recommended)
                  Positioned(
                    left: 7, top: 7,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonPink]),
                      ),
                      child: const Text("ZENO'S PICK", style: TextStyle(color: Colors.white,
                          fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
                    ),
                  ),
                if (selected)
                  const Positioned(
                    right: 7, top: 7,
                    child: CircleAvatar(
                      radius: 11,
                      backgroundColor: BrokaColors.gold,
                      child: Icon(Icons.check_rounded, size: 14, color: Colors.white),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A frame with glowing corner brackets, like a scanner's viewfinder.
class _HologramFrame extends StatelessWidget {
  const _HologramFrame({required this.child, required this.animation});
  final Widget child;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (_, inner) {
        final glow = 0.35 + 0.2 * sin(animation.value * 2 * pi);
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: SweepGradient(
              transform: GradientRotation(animation.value * 2 * pi),
              colors: const [BrokaColors.gold, BrokaColors.neonCyan, BrokaColors.neonPink, BrokaColors.gold],
            ),
            boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(glow), blurRadius: 24)],
          ),
          child: inner,
        );
      },
      child: ClipRRect(borderRadius: BorderRadius.circular(17), child: child),
    );
  }
}

/// A bright line sweeping down the photo: "BROKA is looking at this".
class _ScanLine extends StatelessWidget {
  const _ScanLine({required this.animation});
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: AnimatedBuilder(
          animation: animation,
          builder: (_, __) {
            final y = (animation.value * 2) % 1.0;
            return Align(
              alignment: Alignment(0, y * 2 - 1),
              child: Container(
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [
                      BrokaColors.neonCyan.withOpacity(0),
                      BrokaColors.neonCyan.withOpacity(0.28),
                      BrokaColors.neonCyan.withOpacity(0),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
}

/// The generate button: a gradient that shimmers, so the one thing on the
/// step that makes something happen looks like it.
class _MagicButton extends StatelessWidget {
  const _MagicButton({super.key, required this.label, required this.animation, required this.onPressed});
  final String label;
  final Animation<double> animation;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onPressed,
        child: AnimatedBuilder(
          animation: animation,
          builder: (_, __) {
            final sweep = (animation.value * 3) % 1.0;
            return Container(
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  colors: enabled
                      ? const [Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFF3B82F6)]
                      : [BrokaColors.border, BrokaColors.border],
                ),
                boxShadow: enabled
                    ? [BoxShadow(color: const Color(0xFFEC4899).withOpacity(0.4), blurRadius: 22)]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(children: [
                  if (enabled)
                    Positioned.fill(
                      child: FractionalTranslation(
                        translation: Offset(sweep * 2.4 - 1.2, 0),
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                              Colors.white.withOpacity(0),
                              Colors.white.withOpacity(0.32),
                              Colors.white.withOpacity(0),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  Center(
                    child: Text(label, style: const TextStyle(color: Colors.white,
                        fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.2)),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Full screen while the AI works: the seller's photo in the middle of
/// counter-rotating rings, orbiting sparks, and what's happening now.
class _GeneratingOverlay extends StatefulWidget {
  const _GeneratingOverlay({
    required this.photo,
    required this.themeName,
    required this.still,
    required this.onCancel,
  });
  final File photo;
  final String themeName;
  final bool still;
  final VoidCallback onCancel;

  @override
  State<_GeneratingOverlay> createState() => _GeneratingOverlayState();
}

class _GeneratingOverlayState extends State<_GeneratingOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _spin;
  Timer? _stageTimer;
  int _stage = 0;

  List<String> get _stages => [
        'Studying your photo…',
        'Setting up the lights…',
        'Building the ${widget.themeName} scene…',
        'Keeping your item exactly as it is…',
        'Polishing the details…',
        'Almost there…',
      ];

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: const Duration(seconds: 6));
    if (!widget.still) _spin.repeat();
    _stageTimer = Timer.periodic(const Duration(milliseconds: 2600), (_) {
      if (mounted && _stage < _stages.length - 1) setState(() => _stage++);
    });
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          color: const Color(0xCC03040A),
          child: SafeArea(
            child: Column(children: [
              const Spacer(flex: 2),
              SizedBox(
                width: 260, height: 260,
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (_, __) => CustomPaint(
                    painter: _OrbitPainter(_spin.value),
                    child: Center(
                      child: Container(
                        width: 128, height: 128,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(
                              color: BrokaColors.gold.withOpacity(0.45 + 0.25 * sin(_spin.value * 4 * pi)),
                              blurRadius: 40)],
                        ),
                        child: ClipOval(child: Image.file(widget.photo, fit: BoxFit.cover, cacheWidth: 300,
                            errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard))),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),
              ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                    colors: [BrokaColors.gold, BrokaColors.neonCyan]).createShader(r),
                child: const Text('Zeno is creating your cover', style: TextStyle(
                    color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900)),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 22,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  transitionBuilder: (child, a) => FadeTransition(
                    opacity: a,
                    child: SlideTransition(
                      position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(a),
                      child: child,
                    ),
                  ),
                  child: Text(_stages[_stage], key: ValueKey(_stage),
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14)),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Usually 20-40 seconds', style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
              const Spacer(flex: 3),
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid,
                    fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 16),
            ]),
          ),
        ),
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final rings = [
      (r: 82.0, w: 3.0, speed: 1.0, colors: const [BrokaColors.gold, Color(0x008B5CF6)]),
      (r: 100.0, w: 2.0, speed: -1.6, colors: const [BrokaColors.neonCyan, Color(0x0022D3EE)]),
      (r: 118.0, w: 1.5, speed: 2.3, colors: const [BrokaColors.neonPink, Color(0x00F472B6)]),
    ];
    for (final ring in rings) {
      final rect = Rect.fromCircle(center: c, radius: ring.r);
      canvas.drawArc(rect, 0, 2 * pi, false, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ring.w
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: ring.colors,
          transform: GradientRotation(t * 2 * pi * ring.speed),
        ).createShader(rect));
    }
    // Sparks orbiting at different radii and speeds.
    for (var i = 0; i < 10; i++) {
      final angle = t * 2 * pi * (i.isEven ? 1.4 : -0.9) + i * 0.63;
      final radius = 90.0 + (i % 3) * 14 + 6 * sin(t * 2 * pi * 2 + i);
      final p = c + Offset(cos(angle), sin(angle)) * radius;
      canvas.drawCircle(p, 2.2 + (i % 3), Paint()
        ..color = [BrokaColors.gold, BrokaColors.neonCyan, BrokaColors.neonPink][i % 3].withOpacity(0.9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
    }
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter oldDelegate) => oldDelegate.t != t;
}

/// The result appears from the centre outward, with a flash of light.
class _Reveal extends StatelessWidget {
  const _Reveal({super.key, required this.child, required this.still});
  final Widget child;
  final bool still;

  @override
  Widget build(BuildContext context) {
    if (still) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1100),
      curve: Curves.easeOutCubic,
      builder: (_, v, c) => Stack(fit: StackFit.expand, children: [
        ClipPath(clipper: _CircleReveal(v), child: c),
        IgnorePointer(
          child: Opacity(
            opacity: (1 - v) * 0.8,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]),
              ),
            ),
          ),
        ),
      ]),
      child: child,
    );
  }
}

class _CircleReveal extends CustomClipper<Path> {
  _CircleReveal(this.fraction);
  final double fraction;

  @override
  Path getClip(Size size) {
    final radius = sqrt(size.width * size.width + size.height * size.height) / 2 * fraction;
    return Path()..addOval(Rect.fromCircle(center: size.center(Offset.zero), radius: radius));
  }

  @override
  bool shouldReclip(covariant _CircleReveal oldClipper) => oldClipper.fraction != fraction;
}

/// Before (the seller's photo) and after (the AI cover), split by a handle
/// the seller drags. It sweeps once by itself so the seller sees it's
/// there.
class _CompareSlider extends StatefulWidget {
  const _CompareSlider({required this.before, required this.after, required this.still});
  final Widget before;
  final Widget after;
  final bool still;

  @override
  State<_CompareSlider> createState() => _CompareSliderState();
}

class _CompareSliderState extends State<_CompareSlider> with SingleTickerProviderStateMixin {
  // Created in initState, not lazily: a lazy controller first touched in
  // dispose() (reduced motion never starts it) is created on a deactivated
  // element and asserts.
  late final AnimationController _intro;
  double _split = 1.0;
  bool _dragged = false;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
    if (widget.still) {
      _split = 0.5;
    } else {
      _intro.addListener(() {
        if (_dragged) return;
        // Wait for the reveal, then show the before, then settle midway.
        final t = _intro.value;
        setState(() => _split = t < 0.5 ? 1 - 0.8 * Curves.easeInOut.transform(t / 0.5)
            : 0.2 + 0.3 * Curves.easeOut.transform((t - 0.5) / 0.5));
      });
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _intro.forward();
      });
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, box) {
      final x = box.maxWidth * _split;
      return GestureDetector(
        onHorizontalDragUpdate: (d) => setState(() {
          _dragged = true;
          _split = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0);
        }),
        child: Stack(fit: StackFit.expand, children: [
          widget.after,
          ClipRect(clipper: _LeftOf(x), child: widget.before),
          Positioned(
            left: x - 1.5, top: 0, bottom: 0,
            child: Container(width: 3, color: Colors.white),
          ),
          Positioned(
            left: x - 18, top: box.maxHeight / 2 - 18,
            child: Container(
              width: 36, height: 36,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 8)],
              ),
              child: const Icon(Icons.compare_arrows_rounded, color: BrokaColors.gold, size: 20),
            ),
          ),
          const Positioned(left: 10, bottom: 10, child: _Tag('BEFORE')),
          const Positioned(right: 10, bottom: 10, child: _Tag('AFTER ✨')),
        ]),
      );
    });
  }
}

class _LeftOf extends CustomClipper<Rect> {
  _LeftOf(this.x);
  final double x;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, x, size.height);

  @override
  bool shouldReclip(covariant _LeftOf oldClipper) => oldClipper.x != x;
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 9.5,
            fontWeight: FontWeight.w800, letterSpacing: 0.6)),
      );
}
