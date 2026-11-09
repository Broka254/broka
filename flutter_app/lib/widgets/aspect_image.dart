// A photo at its own aspect ratio: the provider's real dimensions drive an
// exact AspectRatio, so portrait, landscape and square photos all render
// uncropped. While the dimensions resolve (or when they can't), a bounded
// placeholder holds the layout instead of collapsing it.
import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;

class AspectImage extends StatefulWidget {
  const AspectImage({
    super.key,
    required this.provider,
    required this.maxWidth,
    required this.maxHeight,
    this.fit = BoxFit.cover,
    this.borderRadius = BorderRadius.zero,
    this.placeholderHeight = 160,
    this.errorIconSize = 36,
    this.fillWidth = false,
    this.minHeight = 0,
  });

  final ImageProvider provider;
  final double maxWidth;
  final double maxHeight;
  final BoxFit fit;
  final BorderRadius borderRadius;
  final double placeholderHeight;
  final double errorIconSize;

  /// Always [maxWidth] wide (the chat's photo frame, 2026-11-09). The photo
  /// keeps its own ratio while its height falls between [minHeight] and
  /// [maxHeight]; past either bound it is cropped to the bound ([fit]
  /// cover) rather than shrunk, so a tall portrait no longer sits in a
  /// strip between two dark bars.
  final bool fillWidth;

  /// The shortest a [fillWidth] photo is drawn: a panorama is cropped to
  /// this rather than flattened into a sliver.
  final double minHeight;

  @override
  State<AspectImage> createState() => _AspectImageState();
}

class _AspectImageState extends State<AspectImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _aspect; // width / height
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(AspectImage old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      _aspect = null;
      _failed = false;
      _resolve();
    }
  }

  void _resolve() {
    final oldListener = _listener;
    if (oldListener != null) _stream?.removeListener(oldListener);
    final stream = widget.provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (w > 0 && h > 0) setState(() => _aspect = w / h);
      },
      onError: (_, __) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _listener = listener;
    _stream = stream;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _aspect;
    if (_failed || ratio == null || !ratio.isFinite || ratio <= 0) {
      return Container(
        constraints: BoxConstraints(
          maxWidth: widget.maxWidth,
          maxHeight: _failed ? widget.placeholderHeight : widget.maxHeight,
        ),
        height: _failed ? widget.placeholderHeight : widget.placeholderHeight,
        alignment: Alignment.center,
        color: BrokaColors.bgCard,
        child: _failed
            ? Icon(Icons.broken_image_outlined,
                color: BrokaColors.textLow, size: widget.errorIconSize)
            : const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: BrokaColors.gold)),
      );
    }
    // Fit the ratio inside the bounds: width-led, height clamped, so a very
    // tall panorama can't push the bubble off screen.
    var w = widget.maxWidth;
    var h = w / ratio;
    if (widget.fillWidth) {
      final low = widget.minHeight < widget.maxHeight ? widget.minHeight : widget.maxHeight;
      h = h.clamp(low, widget.maxHeight).toDouble();
    } else if (h > widget.maxHeight) {
      h = widget.maxHeight;
      w = h * ratio;
    }
    // The Align is load-bearing, not decorative: parents (chat bubbles)
    // hand down a tight full width that would stretch a narrow portrait
    // back to a wide box. Align loosens the constraints so the frame keeps
    // the computed size; the photo itself is never cropped.
    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        width: w,
        height: h,
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          child: Image(
            image: widget.provider,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => Container(
              color: BrokaColors.bgCard,
              alignment: Alignment.center,
              child: Icon(Icons.broken_image_outlined,
                  color: BrokaColors.textLow, size: widget.errorIconSize),
            ),
          ),
        ),
      ),
    );
  }
}
