// BROKA - Listing Map Screen
// Shows buyer's location and seller's (approximate) location on a map.
// A route polyline is drawn between the two points using OpenStreetMap tiles
// via flutter_map (no API key required).
// The "Get Directions" button opens the native maps app via url_launcher.

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart';
import '../models/listing.dart';
import '../services/api_service.dart';

class ListingMapScreen extends StatefulWidget {
  const ListingMapScreen({super.key});

  @override
  State<ListingMapScreen> createState() => _ListingMapScreenState();
}

class _ListingMapScreenState extends State<ListingMapScreen> {
  Listing? _listing;
  bool _initialized = false;
  String? _peerName;
  String? _viewerRole;
  // Server-computed distance, already rounded. Preferred over recomputing
  // from the deliberately-offset pin, which would be wrong by up to ~330m
  // and inconsistent with the distance shown elsewhere in the app.
  double? _serverDistanceKm;

  // Buyer location (current user)
  double? _buyerLat;
  double? _buyerLng;

  // Seller location - offset by ~300 m for privacy until deal is confirmed
  double? _sellerLat;
  double? _sellerLng;

  bool _hasRoute = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    // Two argument shapes, deliberately.
    //
    // A bare Listing is the legacy call (product_screen and anything else
    // that just wants "where is this item"). The negotiation room now sends
    // a Map naming the actual counterparty, because the old shape could not
    // express the seller's side of the question at all: with only a Listing
    // to go on, this screen computed "me -> my own listing" and showed a
    // seller a map of their own sandals.
    final args = ModalRoute.of(context)?.settings.arguments;
    double? argPeerLat, argPeerLng, argDistanceKm;
    if (args is Listing) {
      _listing = args;
    } else if (args is Map) {
      _listing      = args['listing'] as Listing?;
      _peerName     = args['peerName'] as String?;
      _viewerRole   = args['role'] as String?;
      argPeerLat    = (args['peerLat'] as num?)?.toDouble();
      argPeerLng    = (args['peerLng'] as num?)?.toDouble();
      argDistanceKm = (args['distanceKm'] as num?)?.toDouble();
    }
    _serverDistanceKm = argDistanceKm;

    // Buyer coords from saved session
    // Stored session coordinates, used only as the immediate placeholder.
    //
    // ApiService.currentUserLat/Lng come from SharedPreferences and were
    // written at REGISTRATION. They are not a live position and they never
    // move: a user who signed up in Nairobi CBD and is now in Juja gets a
    // "You" pin on Kenyatta Avenue and a "0 m away" readout, because the
    // stored point happens to sit next to the seller's stored point. That
    // is what the map was showing - not the user's location, but where
    // they created their account.
    _buyerLat = ApiService.currentUserLat;
    _buyerLng = ApiService.currentUserLng;
    _refreshLiveLocation();

    // Seller coords - apply small privacy offset (~300 m) so the exact
    // address is not revealed before a deal is confirmed.
    // Counterparty coordinates: whoever was named in the args, else the
    // listing's seller pin for the legacy call shape.
    final rawLat = argPeerLat ?? _listing?.sellerLat;
    final rawLng = argPeerLng ?? _listing?.sellerLng;
    if (rawLat != null && rawLng != null) {
      // Approximate, not exact - and stable, so the pin does not jitter
      // around between openings and let repeated views triangulate the
      // real point by averaging.
      //
      // Seeded on the listing id where there is one, else the rounded
      // coordinate itself, so a counterparty with no listing context still
      // gets a consistent offset rather than a fresh random one each build.
      final seed = (_listing?.id ?? '').isNotEmpty
          ? _listing!.id.hashCode
          : ('${rawLat.toStringAsFixed(3)},${rawLng.toStringAsFixed(3)}').hashCode;
      final rng  = math.Random(seed);
      // ±0.003 degrees ≈ ±330 m
      _sellerLat = rawLat + (rng.nextDouble() - 0.5) * 0.006;
      _sellerLng = rawLng + (rng.nextDouble() - 0.5) * 0.006;
    }

    _hasRoute = _buyerLat != null &&
        _buyerLng != null &&
        _sellerLat != null &&
        _sellerLng != null;
  }

  /// Replace the stored signup coordinate with where the device actually is.
  ///
  /// Same permission dance home_screen already does. Deliberately does NOT
  /// block the first paint - the map opens immediately on the stored point
  /// and snaps when the fix arrives, because a GPS lock can take seconds
  /// and a blank screen is worse than a stale pin that corrects itself.
  ///
  /// Also clears _serverDistanceKm on success: that figure was computed by
  /// the backend from the same stale coordinate this is replacing, so
  /// keeping it would leave "0 m away" printed next to a pin that had just
  /// moved 30km.
  Future<void> _refreshLiveLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;
      setState(() {
        _buyerLat = pos.latitude;
        _buyerLng = pos.longitude;
        _serverDistanceKm = null;
      });
      // No MapController on this screen - initialCenter is only read on
      // first build, so the camera stays put and the "You" marker moves
      // under it. Correct data with a camera that has not recentred beats
      // a recentred camera showing the wrong point; adding a controller is
      // a separate change and this one is about the position being true.
    } catch (_) {
      // No fix, no permission, or timed out - keep the stored point.
    }
  }

  // ── Haversine distance label ───────────────────────────────────────────────

  String _distanceLabel() {
    final d = _serverDistanceKm ??
        (_hasRoute
            ? _haversineKm(_buyerLat!, _buyerLng!, _sellerLat!, _sellerLng!)
            : null);
    if (d == null) return '';
    if (d < 1.0) return '${(d * 1000).toStringAsFixed(0)} m away';
    return '${d.toStringAsFixed(1)} km away';
  }

  // ── Compass bearing ───────────────────────────────────────────────────────

  /// Which way they are from here, as a compass point.
  ///
  /// Straight-line bearing, not a road heading - "north-east of you" is
  /// orientation, not a turn instruction. Deliberately coarse (8 points):
  /// the pin it is measured from is offset by up to ~330m for privacy, so
  /// a precise bearing would be false precision, and 45-degree sectors stay
  /// truthful at any distance worth caring about.
  String _bearingLabel() {
    if (!_hasRoute) return '';
    final lat1 = _deg2rad(_buyerLat!), lat2 = _deg2rad(_sellerLat!);
    final dLng = _deg2rad(_sellerLng! - _buyerLng!);
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    final deg = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    const points = ['North', 'North-east', 'East', 'South-east',
                    'South', 'South-west', 'West', 'North-west'];
    return '${points[(((deg + 22.5) % 360) ~/ 45)]} of you';
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return r * 2 * math.asin(math.sqrt(a));
  }

  double _deg2rad(double deg) => deg * math.pi / 180.0;

  // ── Estimated travel time (rough road estimate at 40 km/h avg) ────────────

  /// Rough travel time. Explicitly an estimate, and says by what.
  ///
  /// Straight-line distance with a mode-appropriate average speed, not a
  /// routed duration - there is no routing service wired up, and inventing
  /// a confident "12 min" from a crow-flies number would be worse than
  /// admitting the approximation. The 1.3x factor is the usual detour
  /// allowance for real streets versus a straight line.
  ///
  /// Under 2km it reports a walk, because "~2 min drive" for a neighbour
  /// three streets away is useless: in Juja or anywhere similar you are
  /// walking or taking a boda, not driving.
  String _travelTime() {
    final km = _serverDistanceKm ??
        (_hasRoute
            ? _haversineKm(_buyerLat!, _buyerLng!, _sellerLat!, _sellerLng!)
            : null);
    if (km == null) return '';
    final road = km * 1.3;
    final walking = road < 2.0;
    final mins = (road / (walking ? 4.5 : 30.0) * 60).round();
    final mode = walking ? 'walk' : 'drive';
    if (mins < 1) return 'Right nearby';
    if (mins < 60) return '~$mins min $mode';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '~${h}h $mode' : '~${h}h ${m}min $mode';
  }

  // ── Map centre & zoom ─────────────────────────────────────────────────────

  LatLng get _mapCenter {
    if (_hasRoute) {
      return LatLng(
        (_buyerLat! + _sellerLat!) / 2,
        (_buyerLng! + _sellerLng!) / 2,
      );
    }
    if (_sellerLat != null) return LatLng(_sellerLat!, _sellerLng!);
    // Fallback to Nairobi centre
    return const LatLng(-1.2921, 36.8219);
  }

  double get _mapZoom {
    if (!_hasRoute) return 13.0;
    final km = _haversineKm(
        _buyerLat!, _buyerLng!, _sellerLat!, _sellerLng!);
    if (km < 1)   return 15.0;
    if (km < 5)   return 13.0;
    if (km < 20)  return 11.0;
    if (km < 100) return 9.0;
    return 7.0;
  }

  // ── Open native maps ──────────────────────────────────────────────────────

  Future<void> _openDirections() async {
    if (_sellerLat == null || _sellerLng == null) return;
    final lat = _sellerLat!;
    final lng = _sellerLng!;
    Uri uri;
    // Use Apple Maps on iOS, Google Maps everywhere else
    try {
      if (Platform.isIOS) {
        uri = Uri.parse('maps://?daddr=$lat,$lng&dirflg=d');
      } else {
        uri = Uri.parse(
            'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving');
      }
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        // Fallback: open OpenStreetMap in browser
        final fallback = Uri.parse(
            'https://www.openstreetmap.org/directions?from=&to=$lat,$lng');
        await launchUrl(fallback, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not open maps app.'),
        ));
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    if (listing == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: BrokaColors.gold),
        ),
      );
    }

    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: Column(children: [
        _buildHeader(listing),
        Expanded(child: _buildMap()),
        _buildBottomPanel(listing),
      ]),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader(Listing listing) => Container(
        color: BrokaColors.bgMid,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: BrokaColors.bgCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: BrokaColors.border),
                  ),
                  child: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: BrokaColors.textMid, size: 16),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text('Route to Seller',
                      style: TextStyle(
                          color: BrokaColors.textHigh,
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  Text(listing.name,
                      style: const TextStyle(
                          color: BrokaColors.textMid, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ]),
              ),
              if (_hasRoute) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: BrokaColors.neonBlue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: BrokaColors.neonBlue.withOpacity(0.35)),
                  ),
                  child: Text(_distanceLabel(),
                      style: const TextStyle(
                          color: BrokaColors.neonBlue,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ]),
          ),
        ),
      );

  // ── Map ───────────────────────────────────────────────────────────────────

  Widget _buildMap() {
    // Build marker and polyline lists
    final markers = <Marker>[];
    final polylinePoints = <LatLng>[];

    if (_hasRoute) {
      final buyerPt  = LatLng(_buyerLat!, _buyerLng!);
      final sellerPt = LatLng(_sellerLat!, _sellerLng!);

      polylinePoints.addAll([buyerPt, sellerPt]);

      // Buyer marker - blue pin
      markers.add(Marker(
        point: buyerPt,
        width: 48,
        height: 58,
        child: _buildPin(
          icon: Icons.my_location_rounded,
          color: BrokaColors.neonBlue,
          label: 'You',
        ),
      ));

      // Seller marker - purple pin
      markers.add(Marker(
        point: sellerPt,
        width: 56,
        height: 68,
        child: _buildPin(
          icon: Icons.storefront_rounded,
          color: BrokaColors.gold,
          label: 'Seller',
          large: true,
        ),
      ));
    } else if (_sellerLat != null) {
      // No buyer location - show seller pin only
      markers.add(Marker(
        point: LatLng(_sellerLat!, _sellerLng!),
        width: 56,
        height: 68,
        child: _buildPin(
          icon: Icons.storefront_rounded,
          color: BrokaColors.gold,
          label: 'Seller',
          large: true,
        ),
      ));
    }

    return FlutterMap(
      options: MapOptions(
        initialCenter: _mapCenter,
        initialZoom: _mapZoom,
        minZoom: 4,
        maxZoom: 18,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all,
        ),
      ),
      children: [
        // OpenStreetMap tile layer - no API key required
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.broka.app',
          // Dark-style tiles from CartoDB (matches Broka's dark theme)
          // Swap urlTemplate to the line below for a dark map:
          // 'https://cartodb-basemaps-{s}.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png'
        ),
        // Route line
        if (polylinePoints.length == 2)
          PolylineLayer(
            polylines: [
              Polyline(
                points: polylinePoints,
                strokeWidth: 4.0,
                color: BrokaColors.gold.withOpacity(0.85),
                isDotted: false,
              ),
            ],
          ),
        // Markers
        MarkerLayer(markers: markers),
        // OSM attribution (required by OSM tile usage policy)
        RichAttributionWidget(
          attributions: [
            TextSourceAttribution(
              'OpenStreetMap contributors',
              onTap: () => launchUrl(
                  Uri.parse('https://www.openstreetmap.org/copyright')),
            ),
          ],
        ),
      ],
    );
  }

  // ── Pin widget ────────────────────────────────────────────────────────────

  Widget _buildPin({
    required IconData icon,
    required Color color,
    required String label,
    bool large = false,
  }) {
    final size = large ? 44.0 : 36.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.4),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Icon(icon, color: color, size: large ? 22 : 18),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }

  // ── Bottom panel ──────────────────────────────────────────────────────────

  Widget _buildBottomPanel(Listing listing) {
    // The person the map is ABOUT, which is not always the seller. Falls
    // back by viewer role rather than to the bare word "Seller", which a
    // seller reading their own screen would take as their own label.
    final sellerName = _peerName ??
        _listing?.sellerName ??
        (_viewerRole == 'seller' ? 'Buyer' : 'Seller');
    return Container(
      decoration: const BoxDecoration(
        color: BrokaColors.bgMid,
        border: Border(top: BorderSide(color: BrokaColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            // Seller info row
            Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [BrokaColors.gold, BrokaColors.goldDim],
                  ),
                ),
                child: Center(
                  child: Text(
                    sellerName.trim().split(' ').map((w) =>
                        w.isEmpty ? '' : w[0]).take(2).join().toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 14),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(sellerName,
                      style: const TextStyle(
                          color: BrokaColors.textHigh,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                  Text(
                    listing.locationName ?? 'Kenya',
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12),
                  ),
                ]),
              ),
              // Distance & time chip
              if (_hasRoute)
                Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                  Text(_distanceLabel(),
                      style: const TextStyle(
                          color: BrokaColors.neonBlue,
                          fontSize: 13,
                          fontWeight: FontWeight.w800)),
                  Text(_travelTime(),
                      style: const TextStyle(
                          color: BrokaColors.textMid, fontSize: 11)),
                  // Which way, not just how far. Someone deciding whether to
                  // meet wants orientation as much as a number - "1.2 km"
                  // means something different if it is toward town than
                  // away from it.
                  if (_bearingLabel().isNotEmpty)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.explore_outlined,
                          size: 10, color: BrokaColors.textLow),
                      const SizedBox(width: 3),
                      Text(_bearingLabel(),
                          style: const TextStyle(
                              color: BrokaColors.textLow, fontSize: 10)),
                    ]),
                ]),
            ]),
            const SizedBox(height: 12),

            // Privacy note
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: BrokaColors.warning.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: BrokaColors.warning.withOpacity(0.3)),
              ),
              child: const Row(children: [
                Icon(Icons.shield_outlined,
                    color: BrokaColors.warning, size: 14),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Seller location is approximate for privacy. '
                    'Exact address shared after deal confirmation.',
                    style: TextStyle(
                        color: BrokaColors.warning,
                        fontSize: 10,
                        height: 1.4),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),

            // Get Directions button
            GestureDetector(
              onTap: _sellerLat != null ? _openDirections : null,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [BrokaColors.gold, BrokaColors.goldDim],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [BrokaColors.glowGold],
                ),
                child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                  Icon(Icons.directions_rounded,
                      color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('Get Directions',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 15)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
