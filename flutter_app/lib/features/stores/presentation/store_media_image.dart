// BROKA — Store media image (Phase 6 hardening)
//
// Renders a Store media string (a full "data:<mime>;base64,<payload>"
// data URI - this codebase's existing convention, see
// sell_review_screen.dart's _showcasePreviewImage for the same
// strip-before-comma-then-decode pattern) as an image, falling back to a
// placeholder if the string is null, empty, malformed, or fails to
// decode. Never throws - Phase 6's explicit requirement is "do not break
// if media is missing/invalid."
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../widgets/broka_image.dart';

class StoreMediaImage extends StatelessWidget {
  final String? dataUri;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final Widget Function(BuildContext)? placeholderBuilder;

  const StoreMediaImage({
    super.key,
    required this.dataUri,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholderBuilder,
  });

  @override
  Widget build(BuildContext context) {
    // Store images are URLs once the backend has stored them as image
    // assets, data URIs before that; BrokaImage renders both.
    final child = BrokaImage(
      dataUri,
      width: width, height: height, fit: fit,
      placeholder: _placeholder(context),
    );
    return borderRadius != null ? ClipRRect(borderRadius: borderRadius!, child: child) : child;
  }

  Widget _placeholder(BuildContext context) {
    if (placeholderBuilder != null) return placeholderBuilder!(context);
    return Container(
      width: width, height: height,
      color: BrokaColors.bgMid,
      alignment: Alignment.center,
      child: Icon(Icons.storefront_outlined, color: BrokaColors.textLow, size: (height ?? 40) * 0.4),
    );
  }
}
