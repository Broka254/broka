// How far still counts as "near you", shared by every store list.
//
// The directory, a category screen and the Near you screen all cut their
// list at a radius. Until 2026-10-22 that radius was always 25 km, which is
// the right default but a poor answer for a buyer in a dense town (5 km is
// the whole of it) or one willing to travel across a county (50 km). So the
// control offers the presets, "Any distance", and a number the buyer types.
//
// A radius without a live location has no centre, so callers hide the
// control until they have a fix - a button that cannot do what it says is
// worse than no button. The backend accepts any positive radius, so the
// only ceiling here is its own (2000 km), not a list of allowed values.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../main.dart' show BrokaColors;

/// The radii offered as one tap. 25 is the directory's "near you" radius and
/// the default everywhere.
const List<double> distancePresets = [5, 10, 25, 50, 100];

/// The backend's own ceiling for max_distance_km; a custom radius is refused
/// beyond it rather than silently clamped to a number nobody chose.
const double maxDistanceKm = 2000;

/// "5 km", "12.5 km" - a whole number where the radius is one, which is
/// every preset and most typed values.
String formatDistanceKm(double km) =>
    km == km.roundToDouble() ? '${km.round()} km' : '${km.toStringAsFixed(1)} km';

/// "Any distance", "Within 25 km".
String distanceFilterLabel(double? km) =>
    km == null ? 'Any distance' : 'Within ${formatDistanceKm(km)}';

/// One choice from [pickDistance]. [km] null is "Any distance": the filter is
/// removed, not a 2000 km radius nobody asked for.
class DistancePick {
  const DistancePick(this.km);
  final double? km;
}

/// The distance sheet: presets, Any distance, Custom. Null means the sheet
/// was dismissed - the caller keeps the radius it had.
Future<DistancePick?> pickDistance(BuildContext context, {double? current}) =>
    showModalBottomSheet<DistancePick>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DistanceSheet(current: current),
    );

/// A radius the buyer types. Returns null when cancelled; otherwise a value
/// between 0.5 and [maxDistanceKm]. Anything else is explained in the
/// dialog rather than quietly rounded into range.
Future<double?> askCustomDistance(BuildContext context, {double? current}) =>
    showDialog<double>(
      context: context,
      builder: (_) => _CustomDistanceDialog(current: current),
    );

/// The dialog owns its controller: it outlives the future (the route's exit
/// animation still paints the field), so the future must not dispose it.
class _CustomDistanceDialog extends StatefulWidget {
  const _CustomDistanceDialog({this.current});
  final double? current;

  @override
  State<_CustomDistanceDialog> createState() => _CustomDistanceDialogState();
}

class _CustomDistanceDialogState extends State<_CustomDistanceDialog> {
  late final TextEditingController _controller = TextEditingController(
      text: widget.current == null
          ? ''
          : formatDistanceKm(widget.current!).replaceAll(' km', ''));
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() {
    final km = double.tryParse(_controller.text.trim());
    if (km == null || km <= 0 || km > maxDistanceKm) {
      setState(() => _error =
          'Enter a number between 0.5 and ${maxDistanceKm.round()} km');
      return;
    }
    Navigator.pop(context, km);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        key: const Key('distance-custom-dialog'),
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Custom distance',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Show shops this many kilometres away or closer.',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5,
                  height: 1.4)),
          const SizedBox(height: 12),
          TextField(
            key: const Key('distance-custom-field'),
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,1}'))
            ],
            onSubmitted: (_) => _apply(),
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16),
            decoration: InputDecoration(
              hintText: 'e.g. 5',
              hintStyle: const TextStyle(color: BrokaColors.textLow),
              suffixText: 'km',
              errorText: _error,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid)),
          ),
          FilledButton(
            key: const Key('distance-custom-apply'),
            style: FilledButton.styleFrom(
                backgroundColor: BrokaColors.gold,
                foregroundColor: Colors.white),
            onPressed: _apply,
            child: const Text('Use this distance'),
          ),
        ],
      );
}

class _DistanceSheet extends StatelessWidget {
  const _DistanceSheet({this.current});

  final double? current;

  // A typed radius that is not one of the presets gets its own row, checked,
  // so the sheet never shows five unticked options while a filter is on.
  bool get _customSelected =>
      current != null && !distancePresets.contains(current);

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Container(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF16103A), BrokaColors.bgMid, BrokaColors.bg],
              stops: [0, 0.35, 1],
            ),
            border: Border(top: BorderSide(color: BrokaColors.gold, width: 1.1)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 6),
                  child: Container(
                    width: 42, height: 4,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [BrokaColors.gold, BrokaColors.neonBlue]),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    Icon(Icons.radar_rounded, size: 18, color: BrokaColors.gold),
                    SizedBox(width: 8),
                    Text('How far?',
                        style: TextStyle(color: BrokaColors.textHigh,
                            fontSize: 17, fontWeight: FontWeight.w800)),
                  ]),
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Shops this close to your live location. Sort by '
                        'Nearest to put the closest first.',
                        style: TextStyle(color: BrokaColors.textMid,
                            fontSize: 12, height: 1.35)),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(children: [
                      _DistanceTile(
                        key: const Key('distance-any'),
                        label: 'Any distance',
                        detail: 'Every shop, wherever it is',
                        selected: current == null,
                        onTap: () => Navigator.pop(context, const DistancePick(null)),
                      ),
                      for (final km in distancePresets)
                        _DistanceTile(
                          key: Key('distance-${km.round()}'),
                          label: 'Within ${formatDistanceKm(km)}',
                          detail: km == 25 ? 'The directory default' : null,
                          selected: current == km,
                          onTap: () =>
                              Navigator.pop(context, DistancePick(km)),
                        ),
                      _DistanceTile(
                        key: const Key('distance-custom'),
                        icon: Icons.edit_location_alt_outlined,
                        label: _customSelected
                            ? 'Within ${formatDistanceKm(current!)}'
                            : 'Custom distance',
                        detail: 'Type any radius, e.g. 5 km or 50 km',
                        selected: _customSelected,
                        onTap: () async {
                          final km = await askCustomDistance(context, current: current);
                          if (km == null || !context.mounted) return;
                          Navigator.pop(context, DistancePick(km));
                        },
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _DistanceTile extends StatelessWidget {
  const _DistanceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
    this.icon,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.gold.withOpacity(0.13)
                  : BrokaColors.bgCard.withOpacity(0.72),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: selected
                    ? BrokaColors.gold.withOpacity(0.8)
                    : BrokaColors.border,
              ),
            ),
            child: Row(children: [
              Icon(icon ?? Icons.place_outlined,
                  size: 18,
                  color: selected ? BrokaColors.gold : BrokaColors.textMid),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label,
                      style: TextStyle(
                          color: BrokaColors.textHigh,
                          fontSize: 13.5,
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
                  if (detail != null)
                    Text(detail!,
                        style: const TextStyle(color: BrokaColors.textMid,
                            fontSize: 11, height: 1.25)),
                ]),
              ),
              if (selected)
                const Icon(Icons.check_circle_rounded,
                    color: BrokaColors.gold, size: 20),
            ]),
          ),
        ),
      );
}
