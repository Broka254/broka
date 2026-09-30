// BROKA - Listing photo camera (in-app)
//
// Also the camera for every other photo the app takes - store images, chat
// photos, a damaged-goods report - through services/photo_capture.dart.
//
// Why this exists: listing photos used to be taken with the phone's own
// camera app (image_picker, ImageSource.camera). That hands the whole
// screen to another app, and while it is open Android may kill BROKA to
// free memory - on the 2-3 GB phones most Kenyan sellers carry, it often
// did. Coming back from the camera then meant a cold start: the splash
// screen, and (before SellDraftStore) Home, exactly as if the app had
// crashed. The draft store and image_picker's retrieveLostData() made that
// recoverable; this makes it not happen. The camera runs inside BROKA, so
// BROKA stays the foreground app the whole time and is never the process
// Android reclaims.
//
// Each shot is handed to [onCaptured] the moment it's taken - the caller
// saves it with the draft and starts uploading it - so nothing waits for
// the seller to press Done, and nothing is lost if they never do.
//
// If the camera can't start here (permission refused, a device whose
// camera driver the plugin can't open), the screen offers the phone's own
// camera instead: it pops with `true` and the caller falls back to
// image_picker, which keeps the old recovery path.
import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart';

class ListingCameraScreen extends StatefulWidget {
  const ListingCameraScreen({
    super.key,
    required this.alreadyTaken,
    required this.maxPhotos,
    required this.onCaptured,
    this.hint = defaultHint,
  });

  /// What to photograph, shown over the preview until the first shot.
  static const defaultHint =
      'Good light, the whole item in frame. Take the front, the back, and any marks or damage.';

  /// Photos the listing already has, so the counter reads "3 of 6".
  final int alreadyTaken;
  final int maxPhotos;
  final String hint;

  /// Called with each photo as it's taken (a file in the cache directory);
  /// the caller moves it somewhere durable and returns where it now is.
  final Future<File> Function(File photo) onCaptured;

  @override
  State<ListingCameraScreen> createState() => _ListingCameraScreenState();
}

class _ListingCameraScreenState extends State<ListingCameraScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _controller;
  bool _starting = true;
  String? _error;
  bool _permissionProblem = false;
  bool _capturing = false;
  // An initialize() in flight. The first one can raise the permission
  // dialog, which makes the app "inactive" then "resumed" - and a second
  // start on that resume would open the camera twice.
  bool _opening = false;
  bool _sentToSettings = false;
  FlashMode _flash = FlashMode.off;
  bool _grid = true;
  Offset? _focusPoint;
  final List<File> _shots = [];

  // Created in initState, not lazily: a lazy controller first touched in
  // dispose() (the focus ring, if the seller never tapped to focus) is
  // created on a deactivated element and asserts.
  late final AnimationController _shutterFlash;
  late final AnimationController _focusRing;
  late final AnimationController _pulse;

  int get _count => widget.alreadyTaken + _shots.length;
  bool get _full => _count >= widget.maxPhotos;

  @override
  void initState() {
    super.initState();
    _shutterFlash = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
    _focusRing = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat(reverse: true);
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    final controller = _controller;
    _controller = null;
    controller?.dispose();
    _shutterFlash.dispose();
    _focusRing.dispose();
    _pulse.dispose();
    super.dispose();
  }

  // The camera is released whenever BROKA leaves the foreground (a call
  // comes in, the seller switches apps) and reopened on return. Holding it
  // blocks every other app from the camera, and Android closes it anyway.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final controller = _controller;
      if (controller == null) return;
      _controller = null;
      controller.dispose();
      if (mounted) setState(() => _starting = true);
    } else if (state == AppLifecycleState.resumed && _controller == null &&
        (_error == null || _sentToSettings)) {
      // Also back from "Open settings": the seller may just have allowed
      // it. Only then - the permission dialog itself pauses and resumes the
      // app, and retrying on that resume would ask again straight after a
      // "Deny".
      _sentToSettings = false;
      _start();
    }
  }

  Future<void> _start() async {
    if (_opening) return;
    _opening = true;
    setState(() {
      _starting = true;
      _error = null;
      _permissionProblem = false;
    });
    CameraController? created;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('NoCamera', 'No camera found on this phone.');
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      // veryHigh (1080p): sharp enough for buyers to inspect, and a photo of
      // a few hundred KB to upload over mobile data - the server keeps at
      // most 1600 px anyway. Full sensor resolution would be 3-5 MB a shot.
      final controller = created = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      try {
        await controller.setFlashMode(_flash);
      } catch (_) {}
      setState(() {
        _controller = controller;
        _starting = false;
      });
    } on CameraException catch (e) {
      // A controller that failed to open still holds native resources.
      unawaited(created?.dispose());
      if (!mounted) return;
      final code = e.code.toLowerCase();
      setState(() {
        _starting = false;
        _permissionProblem = code.contains('access') || code.contains('permission');
        _error = _permissionProblem
            ? 'BROKA needs your permission to use the camera.'
            : "The camera couldn't start here.";
      });
    } catch (_) {
      unawaited(created?.dispose());
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = "The camera couldn't start here.";
      });
    } finally {
      _opening = false;
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing || _full) return;
    setState(() => _capturing = true);
    try {
      HapticFeedback.mediumImpact();
      _shutterFlash.forward(from: 0);
      final shot = await controller.takePicture();
      final kept = await widget.onCaptured(File(shot.path));
      if (!mounted) return;
      setState(() => _shots.add(kept));
      if (_full) {
        // The last allowed photo: nothing more to do here.
        await Future<void>.delayed(const Duration(milliseconds: 450));
        if (mounted) Navigator.of(context).pop(false);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("That photo didn't take - hold steady and try again."),
          backgroundColor: BrokaColors.bgCard,
        ));
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _cycleFlash() async {
    const order = [FlashMode.off, FlashMode.auto, FlashMode.torch];
    final next = order[(order.indexOf(_flash) + 1) % order.length];
    try {
      await _controller?.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {
      // No flash on this camera: stay as we are.
    }
  }

  Future<void> _focusAt(TapDownDetails details, BoxConstraints box) async {
    final controller = _controller;
    if (controller == null) return;
    final point = Offset(
      (details.localPosition.dx / box.maxWidth).clamp(0.0, 1.0),
      (details.localPosition.dy / box.maxHeight).clamp(0.0, 1.0),
    );
    setState(() => _focusPoint = details.localPosition);
    _focusRing.forward(from: 0);
    try {
      await controller.setFocusPoint(point);
      await controller.setExposurePoint(point);
    } catch (_) {
      // Fixed-focus cameras: the ring still shows, nothing else to do.
    }
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.auto => Icons.flash_auto_rounded,
        FlashMode.torch => Icons.flashlight_on_rounded,
        _ => Icons.flash_off_rounded,
      };

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_capturing,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          _preview(),
          // Shutter flash.
          IgnorePointer(
            child: FadeTransition(
              opacity: Tween(begin: 0.85, end: 0.0).animate(_shutterFlash),
              child: AnimatedBuilder(
                animation: _shutterFlash,
                builder: (_, __) => _shutterFlash.isAnimating
                    ? const ColoredBox(color: Colors.white)
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          SafeArea(child: Column(children: [
            _topBar(),
            const Spacer(),
            if (_controller != null && _count == 0) _hint(),
            _bottomBar(),
          ])),
        ]),
      ),
    );
  }

  Widget _preview() {
    final controller = _controller;
    if (_error != null) return _errorView();
    if (_starting || controller == null || !controller.value.isInitialized) {
      return const Center(
        child: SizedBox(width: 34, height: 34,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: BrokaColors.gold)),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      // Fill the screen: the preview's own aspect ratio is the sensor's,
      // wider than a phone held upright, so it is scaled to cover.
      final screenRatio = box.maxWidth / box.maxHeight;
      var scale = screenRatio * controller.value.aspectRatio;
      if (scale < 1) scale = 1 / scale;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _focusAt(d, box),
        child: Stack(fit: StackFit.expand, children: [
          ClipRect(
            child: Transform.scale(
              scale: scale,
              child: Center(child: CameraPreview(controller)),
            ),
          ),
          if (_grid) const IgnorePointer(child: CustomPaint(painter: _ThirdsPainter())),
          if (_focusPoint != null)
            AnimatedBuilder(
              animation: _focusRing,
              builder: (_, __) {
                final t = _focusRing.value;
                if (t == 0 || t == 1) return const SizedBox.shrink();
                final size = 86 - 22 * Curves.easeOut.transform(t.clamp(0, 0.5) * 2);
                return Positioned(
                  left: _focusPoint!.dx - size / 2,
                  top: _focusPoint!.dy - size / 2,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: t < 0.8 ? 1 : (1 - t) * 5,
                      child: Container(
                        width: size, height: size,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: BrokaColors.neonCyan, width: 2),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ]),
      );
    });
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.no_photography_outlined, color: BrokaColors.textMid, size: 46),
            const SizedBox(height: 14),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 18),
            if (_permissionProblem)
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: BrokaColors.gold),
                onPressed: () async {
                  _sentToSettings = true;
                  await openAppSettings();
                },
                child: const Text('Open settings'),
              )
            else
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: BrokaColors.gold),
                onPressed: _start,
                child: const Text('Try again'),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text("Use the phone's camera instead",
                  style: TextStyle(color: BrokaColors.textMid)),
            ),
          ]),
        ),
      );

  Widget _topBar() => Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
        child: Row(children: [
          _roundButton(Icons.close_rounded, 'Close', () => Navigator.of(context).maybePop(false)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.45),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white24),
            ),
            // A single shot (a logo, a chat photo) has nothing to count.
            child: Text(widget.maxPhotos == 1 ? 'Photo' : '$_count of ${widget.maxPhotos} photos',
                style: const TextStyle(color: Colors.white, fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ),
          const Spacer(),
          _roundButton(_grid ? Icons.grid_on_rounded : Icons.grid_off_rounded, 'Grid',
              () => setState(() => _grid = !_grid)),
          const SizedBox(width: 6),
          _roundButton(_flashIcon, 'Flash', _cycleFlash),
        ]),
      );

  Widget _hint() => Container(
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          widget.hint,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.35),
        ),
      );

  Widget _bottomBar() => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xCC000000)],
          ),
        ),
        child: Row(children: [
          SizedBox(
            width: 92, height: 60,
            child: _shots.isEmpty
                ? const SizedBox.shrink()
                : Stack(clipBehavior: Clip.none, children: [
                    for (var i = 0; i < _shots.length && i < 3; i++)
                      Positioned(
                        left: i * 12.0,
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey(_shots[_shots.length - 1 - i].path),
                          tween: Tween(begin: 0.4, end: 1),
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutBack,
                          builder: (_, v, child) => Transform.scale(scale: v, child: child),
                          child: Container(
                            width: 56, height: 56,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white, width: 1.5),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.file(_shots[_shots.length - 1 - i],
                                fit: BoxFit.cover, cacheWidth: 160,
                                errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black)),
                          ),
                        ),
                      ),
                  ]),
          ),
          const Spacer(),
          _shutter(),
          const Spacer(),
          SizedBox(
            width: 92,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _shots.isEmpty ? 0.45 : 1,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BrokaColors.gold,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _capturing ? null : () => Navigator.of(context).pop(false),
                child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ]),
      );

  Widget _shutter() {
    final ready = _controller != null && !_capturing && !_full;
    return Semantics(
      button: true,
      label: 'Take photo',
      child: GestureDetector(
        onTap: ready ? _capture : null,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (_, child) => Container(
            width: 84, height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
              boxShadow: ready
                  ? [BoxShadow(
                      color: BrokaColors.gold.withOpacity(0.25 + 0.3 * _pulse.value),
                      blurRadius: 18 + 10 * _pulse.value)]
                  : null,
            ),
            padding: const EdgeInsets.all(5),
            child: child,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: ready
                    ? const [Colors.white, Color(0xFFE3D9F7)]
                    : [Colors.white38, Colors.white24],
              ),
            ),
            child: _capturing
                ? const Padding(
                    padding: EdgeInsets.all(22),
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: BrokaColors.gold),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _roundButton(IconData icon, String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withOpacity(0.45),
              border: Border.all(color: Colors.white24),
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      );
}

/// Rule-of-thirds guide: the item goes where the lines cross, not jammed
/// against an edge.
class _ThirdsPainter extends CustomPainter {
  const _ThirdsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.22)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
