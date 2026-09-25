// BROKA - Sell Wizard Step 7: Location
//
// County and area are picked from Kenya's 47 counties and their
// constituencies (KenyaLocations, the list store setup uses), with typing
// kept for an area the list doesn't have. Both used to be free text: a
// listing in "Nairobii" or "Nbi" was never found by the location filter,
// and the server now places a listing on the map at its county (see
// backend/api/domains/listings/location.py), which needs a county it knows.
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../features/stores/domain/kenya_locations.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/list_picker.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_flow.dart';

class SellLocationScreen extends StatefulWidget {
  final SellWizardData data;
  const SellLocationScreen({super.key, required this.data});
  @override
  State<SellLocationScreen> createState() => _SellLocationScreenState();
}

class _SellLocationScreenState extends State<SellLocationScreen> {
  static const _areaNotListed = "My area isn't listed";
  static const _maxAreaLength = 80; // the server's limit for place names

  // Country is fixed to Kenya for now (not yet user-editable - see
  // SellWizardData's comment), so it has no state: nothing to pick,
  // nothing to persist from this screen.
  String? _county;
  late final TextEditingController _areaCtrl;
  // True when the seller is typing an area the list doesn't have.
  late bool _typingArea;
  Timer? _debounce;
  String? _error;

  @override
  void initState() {
    super.initState();
    // A draft typed before the pickers existed keeps its county only if
    // it is one; otherwise the seller picks it.
    _county = KenyaLocations.canonicalCounty(widget.data.county);
    final area = widget.data.subcounty.trim();
    final listed = KenyaLocations.canonicalSubcounty(_county, area);
    _typingArea = area.isNotEmpty && listed == null;
    _areaCtrl = TextEditingController(text: listed ?? area);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _areaCtrl.dispose();
    super.dispose();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => widget.data.persist());
  }

  void _store() {
    widget.data.county = _county ?? '';
    widget.data.subcounty = _areaCtrl.text.trim();
    _scheduleSave();
  }

  Future<void> _pickCounty() async {
    final picked = await pickFromList(context,
        title: 'Where is the item?', options: KenyaLocations.counties, selected: _county);
    if (picked == null || !mounted) return;
    _chooseCounty(picked);
  }

  Future<void> _pickArea() async {
    final picked = await pickFromList(context,
        title: 'Choose the area',
        options: [...KenyaLocations.subcountiesOf(_county), _areaNotListed],
        selected: _typingArea ? null : _areaCtrl.text);
    if (picked == null || !mounted) return;
    setState(() {
      _typingArea = picked == _areaNotListed;
      _areaCtrl.text = _typingArea ? '' : picked;
      _error = null;
    });
    _store();
  }

  void _next() {
    if (_county == null) {
      setState(() => _error = 'Choose the county the item is in.');
      return;
    }
    if (_areaCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Choose or type the area within $_county.');
      return;
    }
    _store();
    setState(() => _error = null);
    SellFlow.next(context, widget.data, from: SellFlow.location);
  }

  // Where most listings are; one tap instead of scrolling 47 counties.
  static const _popularCounties = [
    'Nairobi', 'Mombasa', 'Kiambu', 'Nakuru', 'Kisumu', 'Machakos', 'Kajiado', 'Uasin Gishu',
  ];

  void _chooseCounty(String county) {
    setState(() {
      if (county != _county) {
        _areaCtrl.clear();
        _typingArea = false;
      }
      _county = county;
      _error = null;
    });
    _store();
  }

  @override
  Widget build(BuildContext context) {
    final area = _areaCtrl.text.trim();
    return SellStepScaffold(
      step: SellFlow.location, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.location),
      subtitle: 'Where the item is. Buyers see the area, never your address.',
      data: widget.data,
      error: _error,
      nextLabel: 'NEXT',
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SellCard(
          child: Row(children: [
            Container(
              width: 42, height: 42,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                boxShadow: [BrokaColors.glowGold],
              ),
              alignment: Alignment.center,
              child: const Text('📍', style: TextStyle(fontSize: 20)),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Where is it?', style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 15, fontWeight: FontWeight.w800)),
              SizedBox(height: 2),
              Text('Buyers near it find it first.', style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 11.5)),
            ])),
            // Kenya only for now - see SellWizardData. A chip, not a
            // disabled text box: it's a fact about the listing, not a field
            // the seller can't use.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: BrokaColors.bg.withOpacity(0.6),
                border: Border.all(color: BrokaColors.border),
              ),
              child: const Text('🇰🇪 Kenya', style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
        const SizedBox(height: 20),

        sellStepLabel('COUNTY'),
        const SizedBox(height: 8),
        _LocationTile(
          key: const Key('sell-county-picker'),
          emoji: '🗺️',
          value: _county,
          placeholder: 'Choose a county',
          onTap: _pickCounty,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _county == null
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final c in _popularCounties)
                      ActionChip(
                        key: Key('sell-county-quick-$c'),
                        label: Text(c),
                        onPressed: () => _chooseCounty(c),
                        backgroundColor: BrokaColors.bgCard.withOpacity(0.8),
                        side: BorderSide(color: BrokaColors.gold.withOpacity(0.35)),
                        labelStyle: const TextStyle(color: BrokaColors.textHigh,
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                  ]),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 20),

        sellStepLabel('AREA / SUBCOUNTY'),
        const SizedBox(height: 8),
        if (_typingArea)
          TextFormField(
            key: const Key('sell-area-field'),
            controller: _areaCtrl,
            autofocus: true,
            maxLength: _maxAreaLength,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              hintText: 'e.g. Kilimani',
              prefixIcon: const Padding(
                padding: EdgeInsets.only(left: 12, right: 8),
                child: Text('📌', style: TextStyle(fontSize: 18)),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
              suffixIcon: IconButton(
                tooltip: 'Choose from the list',
                icon: const Icon(Icons.list_rounded, color: BrokaColors.textMid),
                onPressed: _pickArea,
              ),
            ),
            onChanged: (_) => setState(_store),
          )
        else
          _LocationTile(
            key: const Key('sell-area-picker'),
            emoji: '📌',
            value: area.isEmpty ? null : area,
            placeholder: _county == null ? 'Choose a county first' : 'Choose the area',
            enabled: _county != null,
            onTap: _pickArea,
          ),
        const SizedBox(height: 16),

        // What buyers will see, once there's something to see.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(a), child: child),
          ),
          child: _county != null && area.isNotEmpty
              ? SellCard(
                  key: ValueKey('$area|$_county'),
                  highlight: true,
                  child: Row(children: [
                    const _PulsingPin(),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('BUYERS SEE', style: TextStyle(color: BrokaColors.textMid,
                          fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 1.3)),
                      const SizedBox(height: 2),
                      Text('$area, $_county', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 15,
                              fontWeight: FontWeight.w800)),
                    ])),
                  ]),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 10),
        const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline_rounded, size: 14, color: BrokaColors.textMid),
          SizedBox(width: 6),
          Expanded(child: Text(
            'Your exact address is never shown - agree where to meet once you have a deal.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4),
          )),
        ]),
      ]),
    );
  }
}

/// A county or area choice, drawn like the rest of the wizard's cards
/// rather than as a grey form field: glowing once chosen, dimmed until it
/// can be.
class _LocationTile extends StatelessWidget {
  const _LocationTile({
    super.key,
    required this.emoji,
    required this.value,
    required this.placeholder,
    required this.onTap,
    this.enabled = true,
  });
  final String emoji;
  final String? value;
  final String placeholder;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final chosen = value != null && value!.isNotEmpty;
    return Semantics(
      button: true,
      enabled: enabled,
      label: chosen ? value : placeholder,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: enabled ? 1 : 0.45,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: chosen
                  ? LinearGradient(colors: [
                      BrokaColors.gold.withOpacity(0.24), BrokaColors.bgCard.withOpacity(0.85),
                    ])
                  : null,
              color: chosen ? null : BrokaColors.bgCard.withOpacity(0.72),
              border: Border.all(color: chosen ? BrokaColors.gold : BrokaColors.border,
                  width: chosen ? 1.5 : 1),
              boxShadow: chosen ? const [BrokaColors.glowGold] : null,
            ),
            child: Row(children: [
              Text(emoji, style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(chosen ? value! : placeholder, maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: chosen ? Colors.white : BrokaColors.textMid,
                      fontSize: 15,
                      fontWeight: chosen ? FontWeight.w800 : FontWeight.w500,
                    )),
              ),
              Icon(chosen ? Icons.edit_rounded : Icons.keyboard_arrow_down_rounded,
                  color: chosen ? BrokaColors.gold : BrokaColors.textMid, size: 20),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A map pin with a ring pulsing out of it (still under reduced motion).
class _PulsingPin extends StatefulWidget {
  const _PulsingPin();

  @override
  State<_PulsingPin> createState() => _PulsingPinState();
}

class _PulsingPinState extends State<_PulsingPin> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 40, height: 40,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (_, __) => Stack(alignment: Alignment.center, children: [
            Container(
              width: 18 + 22 * _pulse.value, height: 18 + 22 * _pulse.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: BrokaColors.neonCyan.withOpacity(0.7 * (1 - _pulse.value)), width: 2),
              ),
            ),
            const Icon(Icons.location_on_rounded, color: BrokaColors.neonCyan, size: 24),
          ]),
        ),
      );
}
