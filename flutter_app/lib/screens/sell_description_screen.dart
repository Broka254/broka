// BROKA - Sell Wizard Step 4: Description (required)
//
// Required since 2026-09-25, here and on the server (listings/validation.py
// MIN_DESCRIPTION_LEN): a listing with no words was a listing buyers had to
// message just to learn its condition, and the description is half of
// what a "not as described" dispute is judged against. Twenty characters -
// one real sentence - is the floor; the prompts below help sellers write
// more than that.
//
// Zeno writes it from the photo (2026-10-05): a premium allowance
// (PRICING.md section 4), offered at the top of the step as what it is
// for - a clear description sells faster, because buyers don't have to
// message to ask the basics. Without a plan the card opens the plans;
// writing your own stays free. What Zeno writes lands in the box below,
// for the seller to check and finish - nothing is posted from here.
import 'dart:async';
import 'package:flutter/material.dart';
import '../core/network/api_client.dart';
import '../core/utils/result.dart';
import '../features/premium/data/premium_repository.dart';
import '../features/premium/domain/premium.dart';
import '../features/premium/presentation/premium_upsell.dart';
import '../features/zeno_assistant/data/zeno_selling_repository.dart';
import '../features/zeno_assistant/domain/zeno_selling.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/photo_upload_tracker.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import '../widgets/sell_zeno_boost_card.dart';
import 'sell_flow.dart';

class SellDescriptionScreen extends StatefulWidget {
  final SellWizardData data;

  /// For tests.
  final ZenoSellingRepository? selling;
  final PremiumRepository? premium;

  const SellDescriptionScreen({super.key, required this.data, this.selling, this.premium});
  @override
  State<SellDescriptionScreen> createState() => _SellDescriptionScreenState();
}

class _SellDescriptionScreenState extends State<SellDescriptionScreen> {
  late final TextEditingController _descCtrl;
  Timer? _debounce;
  String? _error;

  // What the seller's plan leaves of Zeno's descriptions; null until known,
  // and then the card behaves as if allowed (the server still decides).
  PremiumStatus? _premium;
  bool _writing = false;

  SellWizardData get _data => widget.data;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: _data.description);
    _loadPremium();
  }

  Future<void> _loadPremium() async {
    final r = await (widget.premium ?? premiumRepository).me();
    if (mounted && r is Success<PremiumStatus>) setState(() => _premium = r.data);
  }

  bool get _zenoLocked => !(_premium?.canUse(PremiumFeature.aiDescriptions) ?? true);

  /// "28 of 30 left this month" - only for a plan that has them.
  String? get _zenoLeftText {
    final p = _premium;
    if (p == null || !p.enabled || !p.hasPlan || !p.includes(PremiumFeature.aiDescriptions)) return null;
    final all = p.usage[PremiumFeature.aiDescriptions]?.allowance ?? 0;
    return '${p.left(PremiumFeature.aiDescriptions)} of $all left this month';
  }

  Future<void> _offerPlans(String message, {String? upgradeTo}) async {
    final opened = await showPremiumUpsell(context, message: message, upgradeTo: upgradeTo);
    if (opened && mounted) await _loadPremium();
  }

  /// Zeno writes the description from the first photo.
  Future<void> _zenoWrite() async {
    if (_writing) return;
    final p = _premium;
    if (_zenoLocked && p != null) {
      // The server would only refuse it - say why it is worth it instead.
      await _offerPlans(
        p.hasPlan && p.includes(PremiumFeature.aiDescriptions)
            ? "You've used this month's descriptions by Zeno on BROKA ${p.planName}. "
                'Listings with a clear, detailed description sell faster - you can still write your own, free.'
            : 'Let Zeno write your description from your photo with BROKA Premium. Listings with a '
                "clear, detailed description sell faster - buyers don't have to message to ask the "
                'basics. You can still write your own, free.',
        upgradeTo: p.hasPlan ? null : 'plus',
      );
      return;
    }
    if (_data.verifiedPhotos.isEmpty) {
      setState(() => _error = 'Take your listing photos first - Zeno writes from them.');
      return;
    }
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      // The first photo's upload id; waits for the upload if it's still
      // running (as the cover step does).
      final ids = await _data.photoUploads.idsFor([_data.verifiedPhotos.first]);
      // What the seller already wrote goes with it: Zeno keeps its facts.
      _data.description = _descCtrl.text.trim();
      final text = await (widget.selling ?? zenoSellingRepository).describe(
        draft: zenoListingDraft(_data),
        photoId: ids.first,
        language: ApiService.currentUserLanguage,
      );
      if (!mounted) return;
      _descCtrl.text = text;
      _descCtrl.selection = TextSelection.collapsed(offset: text.length);
      _onChanged(text);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Zeno wrote this from your photo. Check it, and fill in anything it left blank.'),
        behavior: SnackBarBehavior.floating,
      ));
      if (_premium?.enabled ?? false) unawaited(_loadPremium());
    } on PhotoUploadIncomplete {
      if (mounted) {
        setState(() => _error = "Your photo hasn't finished uploading. Check your connection and try again.");
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (isPlanRefusal(e.statusCode)) {
        // Zeno has stopped working on it: the card must not go on
        // spinning behind the plans sheet.
        setState(() => _writing = false);
        await _loadPremium();
        if (mounted) await _offerPlans(e.message, upgradeTo: upgradeToOf(e));
      } else {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't reach Zeno. Check your connection and try again.");
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _descCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => _data.persist());
  }

  /// Starters that fit the item; tapping one adds it as a new line.
  List<String> get _prompts {
    switch (_data.category) {
      case 'Land':
        return ['Title deed: ', 'Distance from the main road: ', 'Water and power: ', 'Neighbourhood: '];
      case 'Agriculture':
      case 'Food & Beverages':
        return ['Harvested / made: ', 'Quality: ', 'Minimum order: ', 'Packaging: '];
      case 'Automobiles':
        return ['Mileage and service history: ', 'Known issues: ', 'Logbook: ', 'Why selling: '];
      case 'Property':
        return ['Rooms: ', 'Amenities: ', 'Nearby: ', 'Available from: '];
      case 'Services':
        return ['What I do: ', 'Experience: ', 'Areas I cover: ', 'Availability: '];
    }
    if (_data.subcategoryName?.startsWith('Mtumba') == true) {
      return ['Grade: ', 'What\'s in the bale: ', 'Sizes: ', 'Minimum order: '];
    }
    return ['Condition: ', "What's included: ", 'Why I\'m selling: ', 'Age / how long used: '];
  }

  void _insert(String prompt) {
    final text = _descCtrl.text;
    final prefix = text.isEmpty || text.endsWith('\n') ? '' : '\n';
    _descCtrl.text = '$text$prefix$prompt';
    _descCtrl.selection = TextSelection.collapsed(offset: _descCtrl.text.length);
    _onChanged(_descCtrl.text);
  }

  void _onChanged(String v) {
    setState(() {
      _data.description = v.trim();
      if (_error != null && _data.description.length >= SellWizardData.minDescriptionLength) {
        _error = null;
      }
    });
    _scheduleSave();
  }

  void _next() {
    _data.description = _descCtrl.text.trim();
    if (_data.description.length < SellWizardData.minDescriptionLength) {
      setState(() => _error = 'Describe the item in at least '
          '${SellWizardData.minDescriptionLength} characters - its condition, what\'s '
          'included and why you\'re selling.');
      return;
    }
    setState(() => _error = null);
    SellFlow.next(context, _data, from: SellFlow.description);
  }

  @override
  Widget build(BuildContext context) {
    final length = _data.description.length;
    const min = SellWizardData.minDescriptionLength;
    final enough = length >= min;
    return SellStepScaffold(
      step: SellFlow.description, totalSteps: SellFlow.total,
      title: SellFlow.title(SellFlow.description),
      subtitle: 'Say what the photos can\'t. Honest detail gets serious buyers - and avoids disputes.',
      data: _data,
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SellZenoBoostCard(
          key: const Key('sell-zeno-describe'),
          icon: Icons.auto_awesome_rounded,
          title: _writing ? 'Zeno is studying your photo…' : 'Let Zeno write it from your photo',
          benefit: 'Clear, detailed descriptions sell faster - buyers get their answers '
              'without having to message you first.',
          badge: 'PREMIUM',
          locked: _zenoLocked,
          busy: _writing,
          footnote: _zenoLeftText,
          onTap: _zenoWrite,
        ),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: sellStepLabel('DESCRIPTION  (REQUIRED)')),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              enough ? '✓ Looks good' : '${min - length} more characters',
              key: ValueKey(enough),
              style: TextStyle(
                color: enough ? BrokaColors.success : BrokaColors.textMid,
                fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: (length / min).clamp(0.0, 1.0)),
            duration: const Duration(milliseconds: 250),
            builder: (_, v, __) => LinearProgressIndicator(
              value: v,
              minHeight: 3,
              backgroundColor: BrokaColors.border,
              valueColor: AlwaysStoppedAnimation(enough ? BrokaColors.success : BrokaColors.gold),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('sell-description-field'),
          controller: _descCtrl,
          maxLines: 9,
          minLines: 6,
          maxLength: SellWizardData.maxDescriptionLength,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(color: BrokaColors.textHigh, height: 1.45),
          decoration: const InputDecoration(
              hintText: 'Condition, features, what\'s included, why you\'re selling…'),
          // Into the draft as typed - see SellDetailsScreen's name field.
          onChanged: _onChanged,
        ),
        const SizedBox(height: 6),
        sellStepLabel('TAP TO ADD'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in _prompts)
            ActionChip(
              label: Text(p.replaceAll(': ', '')),
              avatar: const Icon(Icons.add_rounded, size: 16, color: BrokaColors.gold),
              onPressed: () => _insert(p),
              backgroundColor: BrokaColors.bgCard,
              side: const BorderSide(color: BrokaColors.border),
              labelStyle: const TextStyle(color: BrokaColors.textHigh, fontSize: 12),
            ),
        ]),
      ]),
    );
  }
}
