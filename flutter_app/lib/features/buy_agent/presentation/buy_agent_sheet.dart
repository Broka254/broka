// lib/features/buy_agent/presentation/buy_agent_sheet.dart
// Simple form: category picker, max-price field, must-have-features chip
// input (Design Journal Volume 6, Ch.8/Ch.28). Opened from home_screen.dart's
// third Quick Access card.
import 'package:flutter/material.dart';
import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../../../widgets/zeno_avatar.dart';
import '../../categories/data/repositories/categories_repository.dart';
import '../../categories/domain/models/category.dart';
import '../data/repositories/buy_agent_repository.dart';

class BuyAgentSheet extends StatefulWidget {
  const BuyAgentSheet({super.key});

  @override
  State<BuyAgentSheet> createState() => _BuyAgentSheetState();
}

class _BuyAgentSheetState extends State<BuyAgentSheet> {
  List<Category> _categories = [];
  String? _selectedCategoryId;
  String? _selectedCategoryName;
  final _descriptionCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _featureCtrl = TextEditingController();
  final List<String> _features = [];
  bool _loadingCategories = true;
  bool _parsing = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  @override
  void dispose() {
    _descriptionCtrl.dispose();
    _priceCtrl.dispose();
    _featureCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final result = await categoriesRepository.getTopLevel();
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _categories = data;
        _loadingCategories = false;
      }),
      onFailure: (_, __) => setState(() => _loadingCategories = false),
    );
  }

  void _addFeature() {
    final text = _featureCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _features.add(text);
      _featureCtrl.clear();
    });
  }

  /// Sends the free-text box to POST /buy-agent-requests/parse and merges
  /// whatever comes back into the *same* fields below - never submits on
  /// its own. A bad or partial parse just leaves those fields as they were
  /// (chip unselected, price blank) for the buyer to fill in by hand,
  /// same as before this box existed - this only ever saves typing, it
  /// never bypasses the review step before Start Buy Request.
  Future<void> _parseDescription() async {
    final text = _descriptionCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Type a description first, or use the fields below.');
      return;
    }
    setState(() {
      _parsing = true;
      _error = null;
    });
    try {
      final parsed = await ApiService.parseBuyRequest(text);
      if (!mounted) return;
      final category  = parsed['category'] as String?;
      final maxPrice  = parsed['max_price'];
      final features  = (parsed['must_have_features'] as List?) ?? const [];
      var matchedCategory = false;
      setState(() {
        if (category != null) {
          final match = _categories.where((c) => c.name == category);
          if (match.isNotEmpty) {
            _selectedCategoryId = match.first.id;
            _selectedCategoryName = match.first.name;
            matchedCategory = true;
          }
        }
        if (maxPrice is num && maxPrice > 0) {
          _priceCtrl.text = maxPrice.toStringAsFixed(0);
        }
        for (final f in features) {
          final s = f.toString().trim();
          if (s.isNotEmpty && !_features.contains(s)) _features.add(s);
        }
        _parsing = false;
        if (!matchedCategory && maxPrice == null && features.isEmpty) {
          _error = "Couldn't pick anything out of that — try the fields below instead.";
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _parsing = false;
        _error = "Couldn't reach Zeno just now — the fields below still work directly.";
      });
    }
  }

  Future<void> _submit() async {
    final price = double.tryParse(_priceCtrl.text.trim());
    if (_selectedCategoryId == null) {
      setState(() => _error = 'Pick a category first');
      return;
    }
    if (price == null || price <= 0) {
      setState(() => _error = 'Enter a valid max price');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result = await buyAgentRepository.create(
      category: _selectedCategoryName!,
      maxPrice: price,
      mustHaveFeatures: _features,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (_) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Zeno is on it — you'll be notified when a match comes in."),
          backgroundColor: BrokaColors.gold,
        ));
      },
      onFailure: (message, statusCode) => setState(() {
        _submitting = false;
        _error = statusCode == 409
            ? 'You already have an active buy request. Cancel it before creating a new one.'
            : message;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: BrokaColors.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              const ZenoAvatar(size: 36),
              const SizedBox(width: 10),
              const Text('Let Zeno find it for you',
                  style: TextStyle(color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 4),
            const Text(
              "Tell Zeno what you're after — it'll watch new listings and reach out to sellers on your behalf.",
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                children: [
                  const SizedBox(height: 20),
                  const Text('Describe what you want (optional)',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _descriptionCtrl,
                    maxLines: 3,
                    style: const TextStyle(color: BrokaColors.textHigh),
                    decoration: InputDecoration(
                      hintText: '"Samsung phone, 12GB RAM, good battery, not more than 30000"',
                      hintStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 12.5),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: BrokaColors.border)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: BrokaColors.gold)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _parsing ? null : _parseDescription,
                      icon: _parsing
                          ? const SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold))
                          : const Icon(Icons.auto_awesome, size: 16, color: BrokaColors.gold),
                      label: Text(_parsing ? 'Reading that…' : 'Let Zeno fill this in',
                          style: const TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: BrokaColors.gold),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text('Fills in the fields below — check them, then submit.',
                      style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
                  const SizedBox(height: 20),
                  const Divider(color: BrokaColors.border, height: 1),
                  const SizedBox(height: 20),
                  const Text('Category',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  if (_loadingCategories)
                    const Center(child: CircularProgressIndicator(color: BrokaColors.gold))
                  else if (_categories.isEmpty)
                    // Same underlying gap as the home screen's category
                    // carousel (categories table not seeded yet) - stated
                    // plainly here because, unlike that carousel, this one
                    // blocks submission (_submit requires a category), so
                    // silently offering zero chips would look like a dead
                    // end with no explanation.
                    const Text('No categories available yet — try again shortly.',
                        style: TextStyle(color: BrokaColors.textLow, fontSize: 12.5))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _categories.map((c) {
                        final selected = _selectedCategoryId == c.id;
                        return ChoiceChip(
                          label: Text(c.name),
                          selected: selected,
                          onSelected: (_) => setState(() {
                            _selectedCategoryId = c.id;
                            _selectedCategoryName = c.name;
                          }),
                          backgroundColor: BrokaColors.bgCard,
                          selectedColor: BrokaColors.gold,
                          labelStyle: TextStyle(color: selected ? Colors.white : BrokaColors.textMid),
                          side: BorderSide(color: selected ? BrokaColors.gold : BrokaColors.border),
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 20),
                  const Text('Max price (KES)',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _priceCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: BrokaColors.textHigh),
                    decoration: InputDecoration(
                      hintText: 'e.g. 50000',
                      hintStyle: const TextStyle(color: BrokaColors.textLow),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: BrokaColors.border)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: BrokaColors.gold)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('Must-have features (optional)',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _featureCtrl,
                        style: const TextStyle(color: BrokaColors.textHigh),
                        decoration: InputDecoration(
                          hintText: 'e.g. 8GB RAM',
                          hintStyle: const TextStyle(color: BrokaColors.textLow),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: BrokaColors.border)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: BrokaColors.gold)),
                        ),
                        onSubmitted: (_) => _addFeature(),
                      ),
                    ),
                    IconButton(
                      onPressed: _addFeature,
                      icon: const Icon(Icons.add_circle, color: BrokaColors.gold),
                    ),
                  ]),
                  if (_features.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: _features
                          .map((f) => Chip(
                                label: Text(f),
                                onDeleted: () => setState(() => _features.remove(f)),
                                backgroundColor: BrokaColors.bgCard,
                                labelStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
                                side: const BorderSide(color: BrokaColors.border),
                              ))
                          .toList(),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: BrokaColors.danger, fontSize: 12)),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: GoldButton(
                label: 'Start Buy Request',
                loading: _submitting,
                onTap: _submitting ? null : _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
