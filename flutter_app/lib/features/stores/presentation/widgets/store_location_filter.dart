// County / subcounty / distance filter for store browsing: two pickers over
// KenyaLocations and the shared distance sheet, used by the store directory,
// a category screen and Near you - so a place and a radius mean the same
// filter everywhere. Stateless - the caller owns the selection and re-runs
// its query.
import 'package:flutter/material.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../widgets/list_picker.dart';
import '../../domain/kenya_locations.dart';
import 'distance_filter.dart';

class StoreLocationFilter extends StatelessWidget {
  const StoreLocationFilter({
    super.key,
    required this.county,
    required this.subcounty,
    required this.onChanged,
    this.maxDistanceKm,
    this.onDistanceChanged,
    this.onClear,
  });

  final String? county;
  final String? subcounty;

  /// (county, subcounty) after a pick or a clear.
  final void Function(String? county, String? subcounty) onChanged;

  /// The radius filter, when the caller has a live location. Null with
  /// [onDistanceChanged] means any distance.
  final double? maxDistanceKm;

  /// Null hides the distance control: without a fix, "within 25 km" has no
  /// centre and offering it would be a button that cannot do what it says.
  final ValueChanged<double?>? onDistanceChanged;

  /// Clears county, area and distance in one state change. Without it the
  /// two callbacks above still clear each half, which is what the older
  /// nearby screen uses.
  final VoidCallback? onClear;

  Future<void> _pickCounty(BuildContext context) async {
    final picked = await pickFromList(
      context,
      title: 'Filter by county',
      options: KenyaLocations.counties,
      selected: county,
    );
    if (picked != null) onChanged(picked, null);
  }

  Future<void> _pickSubcounty(BuildContext context) async {
    if (county == null) return;
    final picked = await pickFromList(
      context,
      title: 'Filter by area',
      options: KenyaLocations.subcountiesOf(county),
      selected: subcounty,
    );
    if (picked != null) onChanged(county, picked);
  }

  Future<void> _pickDistance(BuildContext context) async {
    final picked = await pickDistance(context, current: maxDistanceKm);
    if (picked == null) return;
    onDistanceChanged?.call(picked.km);
  }

  @override
  Widget build(BuildContext context) {
    final showDistance = onDistanceChanged != null;
    final active = county != null || maxDistanceKm != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(children: [
        Expanded(
          child: _FilterChip(
            key: const Key('store-filter-county'),
            icon: Icons.map_outlined,
            label: county ?? 'County',
            active: county != null,
            onTap: () => _pickCounty(context),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _FilterChip(
            key: const Key('store-filter-subcounty'),
            icon: Icons.place_outlined,
            label: subcounty ?? 'Area',
            active: subcounty != null,
            enabled: county != null,
            onTap: () => _pickSubcounty(context),
          ),
        ),
        if (showDistance) ...[
          const SizedBox(width: 8),
          Expanded(
            child: _FilterChip(
              key: const Key('store-filter-distance'),
              icon: Icons.radar_rounded,
              // "Distance" when off - the chip has no room for "Any
              // distance", and the sheet that opens says it plainly.
              label: maxDistanceKm == null
                  ? 'Distance'
                  : distanceFilterLabel(maxDistanceKm),
              active: maxDistanceKm != null,
              onTap: () => _pickDistance(context),
            ),
          ),
        ],
        if (active) ...[
          const SizedBox(width: 4),
          IconButton(
            key: const Key('store-filter-clear'),
            tooltip: 'Clear location filters',
            onPressed: onClear ??
                () {
                  onChanged(null, null);
                  onDistanceChanged?.call(null);
                },
            icon: const Icon(Icons.close_rounded,
                size: 18, color: BrokaColors.textMid),
          ),
        ],
      ]),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: enabled,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: active
                  ? BrokaColors.gold.withOpacity(0.14)
                  : BrokaColors.bgCard.withOpacity(0.6),
              borderRadius: BorderRadius.circular(19),
              border: Border.all(
                color: active
                    ? BrokaColors.gold
                    : BrokaColors.border.withOpacity(0.8),
              ),
            ),
            child: Row(children: [
              Icon(icon,
                  size: 15,
                  color: enabled
                      ? (active ? BrokaColors.gold : BrokaColors.textMid)
                      : BrokaColors.textLow),
              const SizedBox(width: 7),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: enabled
                            ? BrokaColors.textHigh
                            : BrokaColors.textLow,
                        fontSize: 12.5,
                        fontWeight:
                            active ? FontWeight.w800 : FontWeight.w600)),
              ),
              Icon(Icons.arrow_drop_down_rounded,
                  size: 18,
                  color: enabled ? BrokaColors.textMid : BrokaColors.textLow),
            ]),
          ),
        ),
      );
}
