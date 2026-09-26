// BROKA - Start selling
//
// A buyer who decides to sell is asked what signup asks, in the same words
// and with the same widgets (lib/widgets/seller_setup.dart): a few items, or
// a business? A few items needs nothing more. A business goes on to its
// name, what it sells, where it is and what it does, then a last look at the
// name buyers will see.
//
// This replaced BecomeSellerScreen (2026-09-26): one long form that treated
// every new seller as a business, so someone clearing out a phone and a sofa
// had to invent a business name, category and location before listing
// anything - the thing signup's first seller question exists to avoid.
import 'package:flutter/material.dart';

import '../core/network/api_client.dart';
import '../main.dart' show BrokaColors;
import '../services/api_service.dart';
import '../widgets/seller_setup.dart';
import '../widgets/wizard_scaffold.dart';
import 'seller_dashboard_screen.dart';

/// What '/seller-dashboard' opens. A buyer who opens the dashboard - from the
/// Menu, their own profile, or a restored last screen - is asked what kind of
/// seller they are first, as signup asks, rather than shown a dashboard
/// nothing could ever fill.
Widget sellerDashboardOrSetup() => ApiService.currentUserAccountType == 'buyer_seller'
    ? const SellerDashboardScreen()
    : const StartSellingScreen();

enum _Step { horizon, name, category, location, description, preview }

class StartSellingScreen extends StatefulWidget {
  const StartSellingScreen({super.key, this.forStore = false, this.animateBackground = true});

  /// Opened on the way to an online store, which only a business can have:
  /// the "few items or a business?" question is already answered, so it
  /// goes straight to the business steps, and it pops with `true` when done
  /// instead of opening the dashboard - the store setup carries on.
  final bool forStore;

  /// False renders one still frame of the background (tests).
  final bool animateBackground;

  @override
  State<StartSellingScreen> createState() => _StartSellingScreenState();
}

class _StartSellingScreenState extends State<StartSellingScreen> {
  final _nameCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _otherCategoryCtrl = TextEditingController();

  /// 'short_term' | 'long_term' - preselected as at signup.
  late String _tier = widget.forStore ? 'long_term' : 'short_term';

  /// One of kBusinessCategories.
  String _category = 'Electronics';

  late _Step _step = widget.forStore ? _Step.name : _Step.horizon;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _locationCtrl.dispose();
    _descriptionCtrl.dispose();
    _otherCategoryCtrl.dispose();
    super.dispose();
  }

  bool get _isBusiness => _tier == 'long_term';

  /// The steps this answer actually visits: someone selling a few items is
  /// never shown the business screens, so the progress bar tells the truth.
  List<_Step> get _steps => [
        if (!widget.forStore) _Step.horizon,
        if (_isBusiness) ...[
          _Step.name, _Step.category, _Step.location, _Step.description, _Step.preview,
        ],
      ];

  int get _position => _steps.indexOf(_step);
  bool get _isLastStep => _position == _steps.length - 1;

  String get _effectiveCategory =>
      _category == 'Other' ? _otherCategoryCtrl.text.trim() : _category;

  String get _displayName =>
      businessDisplayName(_nameCtrl.text, _effectiveCategory, _locationCtrl.text);

  static const _titles = {
    _Step.horizon: 'What kind of seller?',
    _Step.name: 'Business Name',
    _Step.category: 'What You Sell',
    _Step.location: 'Location',
    _Step.description: 'About the Business',
    _Step.preview: 'Your Business Name',
  };

  static const _subtitles = {
    _Step.horizon: 'This decides how much setup we ask for now',
    _Step.name: 'What is your business called?',
    _Step.category: 'Buyers use this to find you',
    _Step.location: 'The area buyers would come to',
    _Step.description: 'Optional, but recommended — Zeno uses this to represent you',
    _Step.preview: 'This is how buyers will see your business',
  };

  void _go(_Step step) => setState(() {
        _step = step;
        _error = null;
      });

  void _back() {
    if (_position > 0) _go(_steps[_position - 1]);
  }

  void _next() {
    final problem = switch (_step) {
      _Step.name when _nameCtrl.text.trim().isEmpty => 'Please enter your business name',
      _Step.category when _effectiveCategory.isEmpty => 'Please say what your business does',
      _Step.location when _locationCtrl.text.trim().isEmpty =>
        'Please enter your immediate location',
      _ => null,
    };
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    if (_isLastStep) {
      _submit();
    } else {
      _go(_steps[_position + 1]);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ApiService.upgradeToSeller(
        sellerTier: _tier,
        businessName: _isBusiness ? _nameCtrl.text.trim() : null,
        businessCategory: _isBusiness ? _effectiveCategory : null,
        businessLocation: _isBusiness ? _locationCtrl.text.trim() : null,
        businessDescription: _isBusiness ? _descriptionCtrl.text.trim() : null,
      );
      if (!mounted) return;
      if (widget.forStore) {
        Navigator.of(context).pop(true);
        return;
      }
      // Where they were headed: the dashboard is the seller's home.
      Navigator.of(context).pushReplacementNamed('/seller-dashboard');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message.isNotEmpty ? e.message : "Couldn't finish setting up. Please try again.";
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = "Couldn't reach BROKA. Check your connection and try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The system back gesture walks back through the steps, as Back does,
      // instead of throwing away everything typed so far.
      canPop: _position == 0 && !_submitting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_submitting) _back();
      },
      child: WizardScaffold(
        flowTitle: widget.forStore ? 'Set up your business' : 'Start selling',
        position: _position,
        total: _steps.length,
        title: _titles[_step]!,
        subtitle: _subtitles[_step],
        onBack: _position > 0 ? _back : null,
        onNext: _next,
        nextLabel: !_isLastStep
            ? 'Continue'
            : (widget.forStore ? 'On to my store' : 'Start selling'),
        nextIcon: _isLastStep ? Icons.storefront_rounded : Icons.arrow_forward_rounded,
        loading: _submitting,
        error: _error,
        animateBackground: widget.animateBackground,
        child: KeyedSubtree(key: ValueKey(_step), child: _content()),
      ),
    );
  }

  Widget _content() => switch (_step) {
        _Step.horizon => SellerHorizonChoices(
            tier: _tier,
            onChanged: (t) => setState(() => _tier = t),
          ),
        _Step.name => Column(children: [
            SetupTextField(_nameCtrl, 'Business name', Icons.storefront_outlined,
                autofocus: true, onChanged: (_) => setState(() {})),
            const SizedBox(height: 10),
            SetupHint(widget.forStore
                ? 'Online stores are for businesses, so your business comes first. '
                    'Buying stays exactly the same.'
                : 'Buying stays exactly the same. This just unlocks listing '
                    'and selling on your account.'),
          ]),
        _Step.category => BusinessCategoryPicker(
            value: _category,
            onChanged: (v) => setState(() => _category = v),
            otherController: _otherCategoryCtrl,
            onOtherChanged: (_) => setState(() {}),
          ),
        _Step.location => Column(children: [
            SetupTextField(_locationCtrl, 'Immediate location', Icons.place_outlined,
                autofocus: true, onChanged: (_) => setState(() {})),
            const SizedBox(height: 10),
            const SetupHint('The estate, street or town buyers would come to — not the '
                'whole county. Specific beats broad here.'),
          ]),
        _Step.description => Column(children: [
            TextField(
              controller: _descriptionCtrl,
              autofocus: true,
              maxLines: 5,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: const InputDecoration(
                labelText: 'Describe your business (optional)',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 10),
            const SetupHint('Recommended. Zeno reads this when it represents you in a '
                'negotiation, so the more it knows, the better it argues your case.'),
            const SizedBox(height: 16),
            Center(
              child: GestureDetector(
                onTap: _submitting ? null : () => _go(_Step.preview),
                child: const Text('Skip — add it later',
                    style: TextStyle(color: BrokaColors.textMid,
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        _Step.preview => Column(children: [
            BusinessPreviewCard(displayName: _displayName),
            const SizedBox(height: 18),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 10),
              child: Text('Not quite right? Tap any part to change it.',
                  style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
            ),
            BusinessEditRow(
                label: 'Business name',
                value: _nameCtrl.text.trim(),
                onTap: () => _go(_Step.name)),
            BusinessEditRow(
                label: 'What you sell',
                value: _effectiveCategory,
                onTap: () => _go(_Step.category)),
            BusinessEditRow(
                label: 'Location',
                value: _locationCtrl.text.trim(),
                onTap: () => _go(_Step.location)),
            BusinessEditRow(
              label: 'Description',
              value: _descriptionCtrl.text.trim().isEmpty
                  ? 'Not added'
                  : _descriptionCtrl.text.trim(),
              onTap: () => _go(_Step.description),
            ),
          ]),
      };
}
