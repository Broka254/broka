// BROKA — Create Store (spec §9, V1 flow)
//
// Modeled directly on become_seller_screen.dart's form: structured
// fields rather than one free-typed block, same BrokaColors/GradientButton
// styling. Logo/store-photo picking (hardening-pass Phase 6) reuses this
// app's one established pattern for turning a picked image into what the
// backend expects - image_picker + base64Encode + a hardcoded
// 'data:image/jpeg;base64,' prefix, the same shape negotiation_screen.dart
// already uses for a chat image attachment.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../main.dart';
import '../../../widgets/gradient_button.dart';
import '../../../core/utils/result.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import 'store_media_image.dart';

class CreateStoreScreen extends StatefulWidget {
  // When non-null, this screen edits that store instead of creating a
  // new one - same form, same fields, just a different submit action and
  // pre-filled controllers. Reached from StoreManagementScreen's "Edit".
  final Store? existing;
  const CreateStoreScreen({super.key, this.existing});
  @override
  State<CreateStoreScreen> createState() => _CreateStoreScreenState();
}

class _CreateStoreScreenState extends State<CreateStoreScreen> {
  final _nameCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _countyCtrl = TextEditingController();
  final _subcountyCtrl = TextEditingController();
  final _locationDescCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _whatsappCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _customSpecializationCtrl = TextEditingController();

  static const _specializations = [
    'Electronics', 'Wholesale', 'Clothing & Fashion', 'Furniture',
    'Automotive', 'Appliances', 'Building Materials', 'Food & Beverages',
    'Phones & Accessories', 'General Merchandise', 'Other',
  ];
  String _specialization = 'Electronics';
  bool _submitting = false;
  String? _error;
  final _picker = ImagePicker();
  String? _logoDataUri;
  final List<String> _photoDataUris = [];
  static const int _maxPhotos = 12; // matches backend MAX_STORE_PHOTOS

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    if (s != null) {
      _nameCtrl.text = s.name;
      _descriptionCtrl.text = s.description ?? '';
      _countyCtrl.text = s.county ?? '';
      _subcountyCtrl.text = s.subcounty ?? '';
      _locationDescCtrl.text = s.locationDescription ?? '';
      _phoneCtrl.text = s.officialPhone ?? '';
      _whatsappCtrl.text = s.officialWhatsapp ?? '';
      _emailCtrl.text = s.officialEmail ?? '';
      _logoDataUri = s.logoUrl;
      _photoDataUris.addAll(s.photos);
      if (s.specialization != null && _specializations.contains(s.specialization)) {
        _specialization = s.specialization!;
      } else if (s.specialization != null) {
        _specialization = 'Other';
        _customSpecializationCtrl.text = s.specialization!;
      }
    }
  }

  String get _effectiveSpecialization =>
      _specialization == 'Other' ? _customSpecializationCtrl.text.trim() : _specialization;

  /// Shared pick+compress+encode step for both the logo and gallery
  /// photos - same imageQuality/maxWidth compression as the sell wizard's
  /// own picker (sell_photos_screen.dart), so a store photo doesn't end
  /// up dramatically larger than a listing photo for no reason. Returns
  /// null on cancel or on any read/encode failure - callers already
  /// treat null as "nothing changed", never crash.
  Future<String?> _pickAndEncode(ImageSource source) async {
    try {
      final xfile = await _picker.pickImage(source: source, imageQuality: 75, maxWidth: 1080);
      if (xfile == null) return null;
      final bytes = await File(xfile.path).readAsBytes();
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read that image — please try another.')));
      }
      return null;
    }
  }

  Future<void> _chooseSource(void Function(String dataUri) onPicked) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined, color: BrokaColors.gold),
            title: const Text('Camera', style: TextStyle(color: BrokaColors.textHigh)),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: BrokaColors.gold),
            title: const Text('Gallery', style: TextStyle(color: BrokaColors.textHigh)),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null) return;
    final dataUri = await _pickAndEncode(source);
    if (dataUri != null) onPicked(dataUri);
  }

  void _pickLogo() => _chooseSource((uri) => setState(() => _logoDataUri = uri));

  void _pickPhoto() {
    if (_photoDataUris.length >= _maxPhotos) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Maximum $_maxPhotos photos allowed')));
      return;
    }
    _chooseSource((uri) => setState(() => _photoDataUris.add(uri)));
  }

  void _removePhoto(int i) => setState(() => _photoDataUris.removeAt(i));

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Store name is required.');
      return;
    }
    setState(() { _submitting = true; _error = null; });

    final payload = {
      'name': name,
      'specialization': _effectiveSpecialization.isEmpty ? null : _effectiveSpecialization,
      'description': _descriptionCtrl.text.trim().isEmpty ? null : _descriptionCtrl.text.trim(),
      'county': _countyCtrl.text.trim().isEmpty ? null : _countyCtrl.text.trim(),
      'subcounty': _subcountyCtrl.text.trim().isEmpty ? null : _subcountyCtrl.text.trim(),
      'location_description': _locationDescCtrl.text.trim().isEmpty ? null : _locationDescCtrl.text.trim(),
      'official_phone': _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
      'official_whatsapp': _whatsappCtrl.text.trim().isEmpty ? null : _whatsappCtrl.text.trim(),
      'official_email': _emailCtrl.text.trim().isEmpty ? null : _emailCtrl.text.trim(),
      'logo_url': _logoDataUri,
      'photos': _photoDataUris,
    };

    final result = _isEditing
        ? await storesRepository.updateStore(widget.existing!.id, payload)
        : await storesRepository.createStore(payload);

    if (!mounted) return;
    result.fold(
      onSuccess: (store) => _isEditing
          ? Navigator.pop(context, store)
          : Navigator.pushReplacementNamed(context, '/store-manage'),
      onFailure: (msg, __) => setState(() { _error = msg; _submitting = false; }),
    );
  }

  InputDecoration _decoration(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: BrokaColors.textMid),
        hintStyle: const TextStyle(color: BrokaColors.textLow),
        filled: true,
        fillColor: BrokaColors.bgMid,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: BrokaColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: BrokaColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: BrokaColors.gold, width: 1.5),
        ),
      );

  Widget _field(TextEditingController c, String label, {String? hint, int maxLines = 1, TextInputType? keyboardType}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType: keyboardType,
        style: const TextStyle(color: BrokaColors.textHigh),
        decoration: _decoration(label, hint: hint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        title: Text(_isEditing ? 'Edit Store' : 'Create Your Store',
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(_isEditing ? 'Update your storefront' : 'Set up your storefront',
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 20,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text(
              'Group your listings under one business identity with its own '
              'public page. You can keep posting personal listings too - a '
              'store is something you have in addition, not instead.',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 24),

            Center(
              child: GestureDetector(
                onTap: _pickLogo,
                child: Stack(children: [
                  StoreMediaImage(
                    dataUri: _logoDataUri, width: 88, height: 88,
                    borderRadius: BorderRadius.circular(22),
                    placeholderBuilder: (_) => Container(
                      width: 88, height: 88,
                      decoration: BoxDecoration(
                        color: BrokaColors.bgCard, borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: BrokaColors.border),
                      ),
                      child: const Icon(Icons.storefront_outlined, color: BrokaColors.textLow, size: 32),
                    ),
                  ),
                  Positioned(
                    bottom: -2, right: -2,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: const BoxDecoration(color: BrokaColors.gold, shape: BoxShape.circle),
                      child: const Icon(Icons.edit, size: 13, color: Colors.white),
                    ),
                  ),
                ]),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Store logo', style: TextStyle(
                    color: BrokaColors.textLow, fontSize: 11.5)),
              ),
            ),
            const SizedBox(height: 20),

            _field(_nameCtrl, 'Store name', hint: 'e.g. Clanix Electronics'),

            DropdownButtonFormField<String>(
              value: _specialization,
              dropdownColor: BrokaColors.bgMid,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _decoration('Specialization'),
              items: _specializations
                  .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: (v) => setState(() => _specialization = v ?? _specialization),
            ),
            if (_specialization == 'Other') ...[
              const SizedBox(height: 14),
              _field(_customSpecializationCtrl, 'Describe what the store sells', hint: 'e.g. Furniture'),
            ] else
              const SizedBox(height: 14),

            _field(_descriptionCtrl, 'Business description (optional)', maxLines: 4,
                hint: 'What you sell, brands you carry, delivery/negotiation policies...'),

            const Text('STORE PHOTOS (OPTIONAL)', style: TextStyle(color: BrokaColors.textLow,
                fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            const SizedBox(height: 10),
            SizedBox(
              height: 84,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (int i = 0; i < _photoDataUris.length; i++) ...[
                  Stack(children: [
                    StoreMediaImage(
                      dataUri: _photoDataUris[i], width: 76, height: 76,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    Positioned(
                      top: -6, right: -6,
                      child: GestureDetector(
                        onTap: () => _removePhoto(i),
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(color: BrokaColors.danger, shape: BoxShape.circle),
                          child: const Icon(Icons.close, size: 12, color: Colors.white),
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(width: 10),
                ],
                if (_photoDataUris.length < _maxPhotos)
                  GestureDetector(
                    onTap: _pickPhoto,
                    child: Container(
                      width: 76, height: 76,
                      decoration: BoxDecoration(
                        color: BrokaColors.bgCard, borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: BrokaColors.border),
                      ),
                      child: const Icon(Icons.add_photo_alternate_outlined, color: BrokaColors.gold, size: 26),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 20),

            const Text('LOCATION', style: TextStyle(color: BrokaColors.textLow,
                fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            const SizedBox(height: 10),
            _field(_countyCtrl, 'County', hint: 'e.g. Nairobi'),
            _field(_subcountyCtrl, 'Subcounty', hint: 'e.g. Westlands'),
            _field(_locationDescCtrl, 'Additional location detail (optional)',
                hint: 'e.g. Along Waiyaki Way, near Sarit Centre'),

            const Text('OFFICIAL CONTACTS (OPTIONAL)', style: TextStyle(color: BrokaColors.textLow,
                fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            const SizedBox(height: 10),
            _field(_phoneCtrl, 'Official phone', keyboardType: TextInputType.phone),
            _field(_whatsappCtrl, 'Official WhatsApp', keyboardType: TextInputType.phone),
            _field(_emailCtrl, 'Official email', keyboardType: TextInputType.emailAddress),

            if (_error != null) ...[
              const SizedBox(height: 6),
              Text(_error!, style: const TextStyle(color: BrokaColors.danger, fontSize: 13)),
            ],

            const SizedBox(height: 12),
            GradientButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(_isEditing ? 'Save Changes' : 'Create Store',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descriptionCtrl.dispose();
    _countyCtrl.dispose();
    _subcountyCtrl.dispose();
    _locationDescCtrl.dispose();
    _phoneCtrl.dispose();
    _whatsappCtrl.dispose();
    _emailCtrl.dispose();
    _customSpecializationCtrl.dispose();
    super.dispose();
  }
}
