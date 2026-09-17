// BROKA — Become a Seller
// Upgrades a buyer-only account to buyer+seller. Business identity is
// collected as structured fields (name / category / location) rather than
// one free-typed string — the server generates the display name
// (e.g. "Clanix · Wholesale · Sira") so it can't drift into inconsistent
// variants that would fragment search and confuse Zeno's matching.
import 'package:flutter/material.dart';
import '../main.dart';
import '../widgets/gradient_button.dart';
import '../services/api_service.dart';

class BecomeSellerScreen extends StatefulWidget {
  const BecomeSellerScreen({super.key});
  @override
  State<BecomeSellerScreen> createState() => _BecomeSellerScreenState();
}

class _BecomeSellerScreenState extends State<BecomeSellerScreen> {
  final _nameCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _customCategoryCtrl = TextEditingController();

  static const _categories = [
    'Electronics', 'Wholesale', 'Clothing & Fashion', 'Supermarket',
    'Property', 'Automotive', 'Food & Beverages', 'Services', 'Other',
  ];
  String _category = 'Electronics';
  bool _submitting = false;
  String? _error;

  String get _effectiveCategory =>
      _category == 'Other' ? _customCategoryCtrl.text.trim() : _category;

  String get _previewName {
    final parts = [
      _nameCtrl.text.trim(),
      _effectiveCategory,
      _locationCtrl.text.trim(),
    ].where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? '' : parts.join(' · ');
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final location = _locationCtrl.text.trim();
    final category = _effectiveCategory;
    if (name.isEmpty || location.isEmpty || category.isEmpty) {
      setState(() => _error = 'Business name, category, and location are all required.');
      return;
    }
    setState(() { _submitting = true; _error = null; });
    try {
      await ApiService.upgradeToSeller(
        businessName: name,
        businessCategory: category,
        businessLocation: location,
        businessDescription: _descriptionCtrl.text.trim().isEmpty
            ? null
            : _descriptionCtrl.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        title: const Text('Become a Seller',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Set up your business',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 20,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text(
              'Buying stays exactly the same. This just unlocks listing and selling on your account.',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 24),

            TextField(
              controller: _nameCtrl,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _decoration('Business name', hint: 'e.g. Clanix'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),

            DropdownButtonFormField<String>(
              value: _category,
              dropdownColor: BrokaColors.bgMid,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _decoration('What does the business do?'),
              items: _categories
                  .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                  .toList(),
              onChanged: (v) => setState(() => _category = v ?? _category),
            ),
            if (_category == 'Other') ...[
              const SizedBox(height: 14),
              TextField(
                controller: _customCategoryCtrl,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: _decoration('Describe what you sell', hint: 'e.g. Furniture'),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 14),

            TextField(
              controller: _locationCtrl,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _decoration(
                'Immediate location',
                hint: 'e.g. Sira, Ugunja — helps tell you apart from others with the same name',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),

            TextField(
              controller: _descriptionCtrl,
              maxLines: 4,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _decoration(
                'Describe your business (optional, but recommended)',
                hint: 'The more detail here, the better Zeno can recommend the right '
                    'features for you — an online store, catalogue, delivery options, and so on.',
              ),
            ),

            if (_previewName.isNotEmpty) ...[
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: BrokaColors.gold.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: BrokaColors.gold.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Your business will appear as',
                        style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                    const SizedBox(height: 6),
                    Text(_previewName,
                        style: const TextStyle(color: BrokaColors.gold, fontSize: 16,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: BrokaColors.danger, fontSize: 13)),
            ],

            const SizedBox(height: 28),
            GradientButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Start Selling',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _locationCtrl.dispose();
    _descriptionCtrl.dispose();
    _customCategoryCtrl.dispose();
    super.dispose();
  }
}
