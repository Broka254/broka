// BROKA - Sell Wizard Step 6: Showcase Image (optional)
//
// Inserted between Location and Review. The seller can skip this
// entirely, upload a cover photo from their gallery, or generate one
// with AI from their actual product photo. Nothing here is required -
// CONTINUE always proceeds regardless of whether a showcase was chosen.
//
// AI generation is a *preview* first: tapping Generate calls
// POST /showcase/preview (no listing exists yet at this point in the
// wizard - see api/domains/showcase/service.py's generate_showcase_
// preview_standalone docstring) and shows the result with Use This
// Image / Regenerate / Change Description. Nothing is committed to
// SellWizardData until the seller explicitly taps Use This Image -
// regenerating always re-sends the *original* actual photo as the
// reference, never a previous AI result, so repeated regenerations
// can't drift away from the real product.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import '../widgets/gradient_button.dart';
import 'sell_review_screen.dart';

class SellShowcaseScreen extends StatefulWidget {
  final SellWizardData data;
  const SellShowcaseScreen({super.key, required this.data});
  @override
  State<SellShowcaseScreen> createState() => _SellShowcaseScreenState();
}

class _SellShowcaseScreenState extends State<SellShowcaseScreen> {
  final _picker = ImagePicker();
  final _descriptionCtrl = TextEditingController();

  bool _generating = false;
  bool _pickingGallery = false;
  String? _error;

  // AI result awaiting approval - not yet written into widget.data.
  String? _previewDataUri;

  @override
  void dispose() {
    _descriptionCtrl.dispose();
    super.dispose();
  }

  String _guessMimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<String?> _fileToDataUri(File f) async {
    try {
      final bytes = await f.readAsBytes();
      return 'data:${_guessMimeFromPath(f.path)};base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickFromGallery() async {
    setState(() { _pickingGallery = true; _error = null; });
    try {
      final xfile = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (xfile == null) return; // user cancelled
      final dataUri = await _fileToDataUri(File(xfile.path));
      if (dataUri == null) {
        setState(() => _error = "Couldn't read that image - please try another.");
        return;
      }
      setState(() {
        widget.data.showcaseImageDataUri = dataUri;
        widget.data.showcaseImageSource = 'gallery';
        _previewDataUri = null;
      });
    } finally {
      if (mounted) setState(() => _pickingGallery = false);
    }
  }

  Future<void> _generate() async {
    if (widget.data.verifiedPhotos.isEmpty) return; // guarded out of the UI too - see build()
    setState(() { _generating = true; _error = null; });
    try {
      final photoDataUri = await _fileToDataUri(widget.data.verifiedPhotos.first);
      if (photoDataUri == null) {
        setState(() => _error = "Couldn't read your product photo - please try again.");
        return;
      }
      final result = await ApiService.generateShowcasePreview({
        'photo_data_uri': photoDataUri,
        'name': widget.data.name,
        'category': widget.data.category,
        if (widget.data.condition != null) 'condition': widget.data.condition,
        if (double.tryParse(widget.data.price) != null) 'price': double.parse(widget.data.price),
        if (_descriptionCtrl.text.trim().isNotEmpty) 'description': _descriptionCtrl.text.trim(),
      });
      final uri = result['image_data_uri'] as String?;
      if (uri == null) {
        setState(() => _error = 'Generation failed. Your actual photos are safe. Try again.');
        return;
      }
      setState(() => _previewDataUri = uri);
    } on TimeoutException {
      setState(() => _error = 'Request timed out - please try again.');
    } catch (e) {
      setState(() => _error = 'Generation failed. Your actual photos are safe. Try again.');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _useThisImage() {
    setState(() {
      widget.data.showcaseImageDataUri = _previewDataUri;
      widget.data.showcaseImageSource = 'ai';
      _previewDataUri = null;
    });
  }

  void _discardPreviewAndEditDescription() {
    setState(() => _previewDataUri = null);
  }

  void _removeShowcase() {
    setState(() {
      widget.data.showcaseImageDataUri = null;
      widget.data.showcaseImageSource = null;
      _previewDataUri = null;
    });
  }

  void _next() {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SellReviewScreen(data: widget.data),
    ));
  }

  Widget _photoThumb({String? dataUri, File? file}) {
    Widget image;
    if (file != null) {
      image = Image.file(file, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard));
    } else {
      final idx = dataUri?.indexOf(',') ?? -1;
      final payload = (dataUri != null && idx != -1) ? dataUri.substring(idx + 1) : null;
      if (payload == null) {
        image = const ColoredBox(color: BrokaColors.bgCard);
      } else {
        try {
          image = Image.memory(base64Decode(payload), fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const ColoredBox(color: BrokaColors.bgCard));
        } catch (_) {
          image = const ColoredBox(color: BrokaColors.bgCard);
        }
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(height: 180, width: double.infinity, child: image),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final hasActualPhoto = data.verifiedPhotos.isNotEmpty;
    final hasPreview = _previewDataUri != null;
    final hasCommitted = !hasPreview && data.showcaseImageDataUri != null;

    return SellStepScaffold(
      step: 6, totalSteps: 7, title: 'Showcase Image',
      error: _error,
      nextLabel: 'CONTINUE',
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sellStepLabel('SHOWCASE IMAGE'),
        const SizedBox(height: 6),
        const Text(
          'Optional. Makes your listing stand out on the homescreen - your '
          'actual photos are always what buyers inspect before they deal.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 16),

        if (!hasActualPhoto)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Text(
              'Upload your product photos first - go back to the Photos step.',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5),
            ),
          )
        else if (hasPreview) ...[
          sellStepLabel('GENERATED PREVIEW'),
          const SizedBox(height: 8),
          _photoThumb(dataUri: _previewDataUri!),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: GradientButton(
              height: 46,
              onPressed: _useThisImage,
              child: const Text('USE THIS IMAGE', style: TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            )),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton(
              onPressed: _generating ? null : _generate,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                side: const BorderSide(color: BrokaColors.border),
              ),
              child: Text('REGENERATE', style: TextStyle(
                  color: BrokaColors.textHigh.withOpacity(_generating ? 0.4 : 1),
                  fontSize: 13, fontWeight: FontWeight.w700)),
            )),
          ]),
          const SizedBox(height: 8),
          Center(child: TextButton(
            onPressed: _discardPreviewAndEditDescription,
            child: const Text('Change description',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          )),
        ] else if (hasCommitted) ...[
          sellStepLabel(data.showcaseImageSource == 'ai' ? '✨ AI SHOWCASE' : 'YOUR COVER PHOTO'),
          const SizedBox(height: 8),
          _photoThumb(dataUri: data.showcaseImageDataUri!),
          const SizedBox(height: 12),
          Center(child: TextButton(
            onPressed: _removeShowcase,
            child: const Text('Remove showcase image',
                style: TextStyle(color: BrokaColors.danger, fontSize: 12.5)),
          )),
        ] else ...[
          sellStepLabel('YOUR ACTUAL PHOTO'),
          const SizedBox(height: 8),
          _photoThumb(file: data.verifiedPhotos.first),
          const SizedBox(height: 20),

          OutlinedButton.icon(
            onPressed: _pickingGallery ? null : _pickFromGallery,
            icon: _pickingGallery
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.textMid))
                : const Icon(Icons.photo_library_outlined, color: BrokaColors.textMid, size: 18),
            label: const Text('UPLOAD FROM GALLERY', style: TextStyle(
                color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              side: const BorderSide(color: BrokaColors.border),
            ),
          ),
          const SizedBox(height: 20),

          sellStepLabel('DESCRIBE YOUR IDEAL SHOWCASE (OPTIONAL)'),
          const SizedBox(height: 8),
          TextField(
            controller: _descriptionCtrl,
            enabled: !_generating,
            maxLines: 3,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'e.g. Professional showroom, dramatic lighting',
            ),
          ),
          const SizedBox(height: 14),

          GradientButton(
            height: 48,
            onPressed: _generating ? null : _generate,
            child: _generating
                ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                    SizedBox(width: 10),
                    Text('Generating your showcase...', style: TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                  ])
                : const Text('✨  GENERATE WITH AI', style: TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    );
  }
}
