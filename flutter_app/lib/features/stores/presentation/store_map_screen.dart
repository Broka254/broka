// A store on a map: the buyer's point and the shop's approximate point
// (±1 km, the point the API hands out - never an exact address), on
// OpenStreetMap tiles via flutter_map, the same stack as the listing
// map. "Get directions" hands off to the phone's maps app.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../main.dart' show BrokaColors;
import '../domain/models/store.dart';

/// Opens [store] on the in-app map when it has a mappable point; without
/// one, falls back to a place-text search in the phone's maps app (the
/// old Store-details behaviour), so the action never dead-ends.
Future<void> openStoreMap(
  BuildContext context,
  Store store, {
  double? viewerLat,
  double? viewerLng,
}) async {
  final point = store.mapPoint;
  if (point != null) {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StoreMapScreen(
        storeName: store.name,
        storeLat: point.lat,
        storeLng: point.lng,
        viewerLat: viewerLat,
        viewerLng: viewerLng,
        distanceLabel: store.nearLabel ?? store.anyDistanceLabel ?? store.distanceLabel,
        placeLabel: store.locationLine,
        approximateArea: store.distanceApproximate,
      ),
    ));
    return;
  }
  final place = [store.locationDescription, store.subcounty, store.county, store.country]
      .map((s) => s?.trim() ?? '')
      .where((s) => s.isNotEmpty)
      .join(', ');
  if (place.isEmpty) return;
  await launchUrl(
    Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': place}),
    mode: LaunchMode.externalApplication,
  );
}

class StoreMapScreen extends StatelessWidget {
  const StoreMapScreen({
    super.key,
    required this.storeName,
    required this.storeLat,
    required this.storeLng,
    this.viewerLat,
    this.viewerLng,
    this.distanceLabel,
    this.placeLabel,
    this.approximateArea = false,
  });

  final String storeName;
  final double storeLat;
  final double storeLng;
  final double? viewerLat;
  final double? viewerLng;
  final String? distanceLabel;
  final String? placeLabel;

  /// The point is the shop's declared area (county/subcounty), not a
  /// pin: the footer must say the area is approximate, not "about 1 km".
  final bool approximateArea;

  Future<void> _directions() async {
    await launchUrl(
      Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'destination': '$storeLat,$storeLng',
      }),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shop = LatLng(storeLat, storeLng);
    final viewer = (viewerLat != null && viewerLng != null)
        ? LatLng(viewerLat!, viewerLng!)
        : null;
    final center = viewer == null
        ? shop
        : LatLng((shop.latitude + viewer.latitude) / 2,
            (shop.longitude + viewer.longitude) / 2);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: BrokaColors.textHigh,
        title: Text(storeName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: Column(children: [
        Expanded(
          child: FlutterMap(
            key: const Key('store-map'),
            options: MapOptions(
              initialCenter: center,
              initialZoom: viewer == null ? 13 : 11,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'ke.co.broka.app',
              ),
              if (viewer != null)
                PolylineLayer(polylines: [
                  Polyline(
                    points: [viewer, shop],
                    color: BrokaColors.gold.withOpacity(0.7),
                    strokeWidth: 3,
                  ),
                ]),
              MarkerLayer(markers: [
                if (viewer != null)
                  Marker(
                    point: viewer,
                    width: 36,
                    height: 36,
                    child: const Icon(Icons.my_location_rounded,
                        color: BrokaColors.neonCyan, size: 28),
                  ),
                Marker(
                  point: shop,
                  width: 44,
                  height: 44,
                  child: const Icon(Icons.location_on_rounded,
                      color: BrokaColors.gold, size: 40),
                ),
              ]),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          color: BrokaColors.bgCard,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (distanceLabel != null)
              Text(distanceLabel!,
                  style: const TextStyle(
                      color: BrokaColors.gold, fontSize: 15, fontWeight: FontWeight.w800)),
            if (placeLabel != null) ...[
              const SizedBox(height: 2),
              Text(placeLabel!,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
            ],
            const SizedBox(height: 4),
            Text(
                approximateArea
                    ? 'Approximate area - the shop has not set an exact pin. Ask the store for the exact spot.'
                    : 'Approximate area (about 1 km) - ask the store for the exact spot.',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('store-map-directions'),
                onPressed: _directions,
                icon: const Icon(Icons.directions_rounded, size: 18),
                label: const Text('Get directions'),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
