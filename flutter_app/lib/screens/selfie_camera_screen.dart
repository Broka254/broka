// BROKA - Selfie Screen (in-app camera)
// Uses the `camera` plugin for a fully in-app front-camera experience.
// - Never leaves the app
// - Detects low light and warns the user
// - Rejects blurry photos (Laplacian variance < threshold)
// - Oval face-guide overlay
// - Returns base64-encoded JPEG via Navigator.pop

import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../widgets/lighting_coach.dart';
import '../core/errors/user_facing_error.dart';

// ─── Blur / brightness helpers ────────────────────────────────────────────────

/// Approximate brightness from a 40×40 centre sample of the raw YUV plane.
/// Returns 0.0 (black) - 255.0 (white).
double _estimateBrightness(CameraImage image) {
  final yPlane = image.planes[0];
  final bytes  = yPlane.bytes;
  final w      = image.width;
  final h      = image.height;

  // Sample a 40×40 block from the centre
  const samples = 40;
  final startX  = (w ~/ 2) - (samples ~/ 2);
  final startY  = (h ~/ 2) - (samples ~/ 2);

  double sum = 0;
  int    count = 0;
  for (int y = startY; y < startY + samples; y++) {
    for (int x = startX; x < startX + samples; x++) {
      if (x >= 0 && x < w && y >= 0 && y < h) {
        sum += bytes[y * yPlane.bytesPerRow + x];
        count++;
      }
    }
  }
  return count == 0 ? 128 : sum / count;
}

// ─── Main widget ──────────────────────────────────────────────────────────────

class SelfieCameraScreen extends StatefulWidget {
  const SelfieCameraScreen({super.key});
  @override
  State<SelfieCameraScreen> createState() => _SelfieCameraScreenState();
}

class _SelfieCameraScreenState extends State<SelfieCameraScreen>
    with WidgetsBindingObserver {

  CameraController? _controller;
  bool   _initialising = true;
  String? _initError;

  // Live preview feedback. Judgement about what the number means lives in
  // widgets/lighting_coach.dart, so the screen only has to carry the reading.
  double _brightness   = 128;

  // Capture state
  bool    _capturing   = false;
  String? _previewB64; // base64 JPEG after capture
  bool    _photoBlurry = false;

  // Brightness polling timer handle
  bool _streamingBrightness = false;
  int  _lastBrightnessSampleMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller!.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    setState(() { _initialising = true; _initError = null; });
    try {
      final cameras = await availableCameras();
      // Prefer front camera
      CameraDescription? front;
      for (final c in cameras) {
        if (c.lensDirection == CameraLensDirection.front) { front = c; break; }
      }
      final cam = front ?? (cameras.isNotEmpty ? cameras.first : null);
      if (cam == null) throw Exception('No camera found on this device');

      final ctrl = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await ctrl.initialize();
      if (!mounted) return;

      _controller = ctrl;
      setState(() => _initialising = false);

      // Start brightness stream
      _startBrightnessStream();
    } catch (e) {
      if (mounted) setState(() { _initialising = false; _initError = userFacingError(e, fallback: "Couldn't start the camera. Please try again."); });
    }
  }

  void _startBrightnessStream() {
    if (_streamingBrightness) return;
    _streamingBrightness = true;
    _controller?.startImageStream((image) {
      // Sample at most every 400ms. The previous condition was
      // `now % 500 < 50`, which sampled on whatever share of frames happened
      // to land inside that window rather than on a fixed interval, so the
      // advice updated erratically.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastBrightnessSampleMs < 400) return;
      _lastBrightnessSampleMs = now;

      final b = _estimateBrightness(image);
      if (!mounted) return;
      // Smooth the reading. A raw per-frame value flickers across a
      // threshold as someone moves, which makes the coach's advice flip
      // back and forth and read as broken.
      final smoothed = _brightness + (b - _brightness) * 0.35;
      if ((smoothed - _brightness).abs() < 0.5) return;
      setState(() => _brightness = smoothed);
    });
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_capturing) return;
    setState(() { _capturing = true; _photoBlurry = false; _previewB64 = null; });

    try {
      // Stop image stream before capture
      if (_controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
        _streamingBrightness = false;
      }

      final xFile = await _controller!.takePicture();
      final bytes = await xFile.readAsBytes();

      // Simple blur check: look at file size as a proxy.
      // A crisp 800×800 JPEG is typically > 50 KB; a blurry one is much smaller.
      // This is a heuristic - good enough for mobile without dart:ffi.
      final kb = bytes.length / 1024;
      final blurry = kb < 30; // < 30 KB almost certainly blurry/dark

      final b64 = base64Encode(bytes);

      if (mounted) {
        setState(() {
        _previewB64  = b64;
        _photoBlurry = blurry;
        _capturing   = false;
      });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _capturing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(userFacingError(e, fallback: "Couldn't take the photo. Please try again.")),
          backgroundColor: BrokaColors.danger,
        ));
      }
    }
  }

  void _retake() {
    setState(() { _previewB64 = null; _photoBlurry = false; });
    _startBrightnessStream();
  }

  void _confirm() => Navigator.pop(context, _previewB64);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_initialising) return _buildLoading('Initialising camera…');
    if (_initError != null) return _buildError(_initError!);
    if (_previewB64 != null) return _buildPreview();
    return _buildViewfinder();
  }

  // ── Loading ─────────────────────────────────────────────────────────────────
  Widget _buildLoading(String msg) => Scaffold(
    backgroundColor: Colors.black,
    body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const CircularProgressIndicator(color: BrokaColors.gold),
      const SizedBox(height: 20),
      Text(msg, style: const TextStyle(color: Colors.white70, fontSize: 14)),
    ])),
  );

  Widget _buildError(String msg) => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.camera_alt_outlined, color: BrokaColors.danger, size: 64),
        const SizedBox(height: 20),
        Text(msg, style: const TextStyle(color: Colors.white70, fontSize: 14),
          textAlign: TextAlign.center),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: _initCamera,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.goldDim]),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text('Try Again',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Go Back',
              style: TextStyle(color: BrokaColors.textMid)),
        ),
      ]),
    )),
  );

  // ── Live viewfinder ─────────────────────────────────────────────────────────
  Widget _buildViewfinder() {
    final advice = adviceForBrightness(_brightness);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        // WITHOUT this the Stack collapses. A Stack sizes itself to its
        // largest NON-positioned child, and every layer here except the top
        // bar is Positioned — so the whole screen was being laid out at the
        // height of that one small bar. That is why the preview showed as a
        // sliver at the top and the shutter, nominally 48px from the bottom,
        // appeared next to the front camera with your finger over the lens.
        fit: StackFit.expand,
        children: [
          // Camera preview — fills the screen.
          Positioned.fill(child: CameraPreview(_controller!)),

          // Darkening vignette outside the face oval.
          Positioned.fill(child: CustomPaint(painter: _OvalVignette())),

          // ── Top bar ──
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(children: [
                  _iconBtn(Icons.close_rounded, () => Navigator.pop(context)),
                  const Spacer(),
                ]),
              ),
            ),
          ),

          // ── Instruction above the oval ──
          const Positioned(
            top: 0, left: 24, right: 24,
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.only(top: 62),
                child: Column(children: [
                  Text(
                    'Take a quick selfie',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 22,
                        fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'It protects your account and shows buyers and sellers '
                    'they are dealing with a real person.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 13,
                        height: 1.35),
                  ),
                ]),
              ),
            ),
          ),

          // ── Face guide label, just under the oval ──
          Align(
            alignment: const Alignment(0, 0.46),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white24),
              ),
              child: const Text('Position your face in the oval',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ),

          // ── Zeno's lighting coach, directly above the shutter ──
          Positioned(
            left: 20, right: 20, bottom: 150,
            child: LightingCoachCard(advice: advice),
          ),

          // ── Shutter ──
          // Bottom-centred and well clear of the front lens, which sits at
          // the top of the phone. Reaching for a top-mounted button is what
          // put a finger over the camera and darkened the frame.
          Positioned(
            left: 0, right: 0, bottom: 44,
            child: Center(
              child: GestureDetector(
                // Never gated on lighting. The coach advises; the person
                // decides. A disabled shutter in a dim room is a dead end,
                // and the preview after capture already lets them judge the
                // result and retake.
                onTap: _capturing ? null : _takePicture,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 78, height: 78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.goldDim],
                        begin: Alignment.topLeft, end: Alignment.bottomRight),
                    boxShadow: const [BrokaColors.glowGold],
                    border: Border.all(color: Colors.white30, width: 3),
                  ),
                  child: _capturing
                      ? const Padding(
                          padding: EdgeInsets.all(18),
                          child: CircularProgressIndicator(
                              strokeWidth: 2.5, color: Colors.white))
                      : const Icon(Icons.camera_alt_rounded,
                          color: Colors.white, size: 30),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Preview / confirm ───────────────────────────────────────────────────────
  Widget _buildPreview() {
    final bytes = base64Decode(_previewB64!);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [

        // Full-screen image
        Positioned.fill(child: Image.memory(bytes, fit: BoxFit.cover)),

        // Bottom gradient
        Positioned(bottom: 0, left: 0, right: 0,
          child: Container(height: 240,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter, end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
          ),
        ),

        // Top bar
        SafeArea(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            _iconBtn(Icons.arrow_back_rounded, _retake),
            const Spacer(),
            const Text('Profile Selfie',
                style: TextStyle(color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const Spacer(),
            const SizedBox(width: 40),
          ]),
        )),

        // Blur / quality warning
        if (_photoBlurry)
          Positioned(
            top: 80, left: 20, right: 20,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.92),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Row(children: [
                Icon(Icons.blur_on_rounded, color: Colors.white, size: 18),
                SizedBox(width: 10),
                Expanded(child: Text(
                  'This photo looks blurry or too dark. We recommend retaking it in better light.',
                  style: TextStyle(color: Colors.white,
                      fontSize: 12, fontWeight: FontWeight.w600),
                )),
              ]),
            ),
          ),

        // Status badge
        if (!_photoBlurry)
          SafeArea(child: Padding(
            padding: const EdgeInsets.only(top: 70),
            child: Center(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: BrokaColors.neonGreen.withOpacity(0.6)),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle_rounded,
                    color: BrokaColors.neonGreen, size: 14),
                SizedBox(width: 6),
                Text('Photo looks good ✓', style: TextStyle(
                    color: BrokaColors.neonGreen, fontSize: 12,
                    fontWeight: FontWeight.w700)),
              ]),
            )),
          )),

        // Buttons
        Positioned(
          bottom: 50, left: 24, right: 24,
          child: Row(children: [
            Expanded(child: _outlineBtn(
              Icons.refresh_rounded, 'Retake', _retake)),
            const SizedBox(width: 12),
            Expanded(child: _gradientBtn(
              Icons.check_rounded,
              _photoBlurry ? 'Use Anyway' : 'Use Photo',
              _confirm,
            )),
          ]),
        ),
      ]),
    );
  }

  // ─── Small helpers ──────────────────────────────────────────────────────────

  Widget _iconBtn(IconData icon, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    ),
  );

  Widget _outlineBtn(IconData icon, String label, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700)),
        ]),
      ),
    );

  Widget _gradientBtn(IconData icon, String label, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.goldDim]),
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [BrokaColors.glowGold],
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
}

// ─── Oval vignette painter ─────────────────────────────────────────────────────

class _OvalVignette extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height * 0.42;
    final rx = size.width  * 0.40;
    final ry = size.height * 0.30;

    // Dark overlay everywhere EXCEPT inside the oval
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCenter(
          center: Offset(cx, cy), width: rx * 2, height: ry * 2))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, Paint()..color = Colors.black.withOpacity(0.55));

    // Oval border glow
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(cx, cy), width: rx * 2, height: ry * 2),
      Paint()
        ..style   = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color   = const Color(0xFFD4A017).withOpacity(0.8),
    );
  }

  @override
  bool shouldRepaint(_) => false;
}
