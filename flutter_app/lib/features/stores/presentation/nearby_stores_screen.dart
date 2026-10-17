// BROKA — Stores near you
//
// Browsable exactly like a store category, except the filter is where you
// are standing: shops within 25 km of your current position, nearest first.
// The position is a live GPS fix, never the saved signup point - near you
// from a stale point is worse than no list at all (a shop in your own town
// reading tens of km away). No fix, no list: the screen asks for location
// instead of guessing.

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../widgets/collapsing_screen_header.dart';
import '../../../widgets/constellation_background.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import 'store_home_screen.dart';
import 'widgets/store_card.dart';
import 'widgets/store_details_view.dart' show showStoreDetails;

class NearbyStoresScreen extends StatefulWidget {
  const NearbyStoresScreen({super.key, this.repository});

  final StoresRepository? repository;

  @override
  State<NearbyStoresScreen> createState() => _NearbyStoresScreenState();
}

enum _Stage { locating, needsLocation, ready, loadFailed }

class _NearbyStoresScreenState extends State<NearbyStoresScreen> {
  StoresRepository get _repo => widget.repository ?? storesRepository;

  _Stage _stage = _Stage.locating;
  final List<Store> _stores = [];
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _stage = _Stage.locating);
    double? lat;
    double? lng;
    try {
      var enabled = await Geolocator.isLocationServiceEnabled();
      var perm = enabled ? await Geolocator.checkPermission() : LocationPermission.denied;
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() => _stage = _Stage.needsLocation);
        return;
      }
      if (!enabled) {
        if (!mounted) return;
        setState(() => _stage = _Stage.needsLocation);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 10),
        ),
      );
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {
      if (!mounted) return;
      setState(() => _stage = _Stage.needsLocation);
      return;
    }
    final result = await _repo.listStores(
      lat: lat,
      lng: lng,
      maxDistanceKm: Store.nearRadiusKm,
      nearestFirst: true,
      limit: 50,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _stores..clear()..addAll(data);
        _stage = _Stage.ready;
      }),
      onFailure: (_, __) => setState(() => _stage = _Stage.loadFailed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        child: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _load,
            color: BrokaColors.gold,
            backgroundColor: BrokaColors.bgCard,
            displacement: 72,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: CollapsingScreenHeader(
                    title: 'Near you',
                    emoji: '📍',
                    gradient: const [BrokaColors.gold, BrokaColors.neonCyan],
                    onBack: () => Navigator.pop(context),
                    narrow: media.size.width < 360,
                    textScale: media.textScaler.scale(1.0).clamp(1.0, 1.35).toDouble(),
                  ),
                ),
                ..._bodySlivers(),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _bodySlivers() {
    switch (_stage) {
      case _Stage.locating:
        return const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)),
          ),
        ];
      case _Stage.needsLocation:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.location_off_outlined, size: 44, color: BrokaColors.textMid),
                const SizedBox(height: 14),
                const Text('Turn on location to see stores near you',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text('Near you means within 25 km of where you are standing.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
                const SizedBox(height: 18),
                FilledButton.icon(
                  key: const Key('nearby-use-location'),
                  onPressed: () async {
                    await Geolocator.openLocationSettings();
                    _load();
                  },
                  icon: const Icon(Icons.my_location_rounded, size: 18),
                  label: const Text('Use my location'),
                ),
              ]),
            ),
          ),
        ];
      case _Stage.loadFailed:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.cloud_off_outlined, size: 44, color: BrokaColors.textMid),
                const SizedBox(height: 14),
                const Text('Stores near you could not load',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                FilledButton(
                  key: const Key('nearby-retry'),
                  onPressed: _load,
                  child: const Text('Try again'),
                ),
              ]),
            ),
          ),
        ];
      case _Stage.ready:
        if (_stores.isEmpty) {
          return const [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.storefront_outlined, size: 44, color: BrokaColors.textMid),
                  SizedBox(height: 14),
                  Text('No stores within 25 km of you',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  SizedBox(height: 6),
                  Text('Shops further away are under Shop by category.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
                ]),
              ),
            ),
          ];
        }
        return [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(children: [
                const Icon(Icons.near_me_rounded, size: 16, color: BrokaColors.gold),
                const SizedBox(width: 6),
                Text('${_stores.length} within 25 km of you',
                    style: const TextStyle(color: BrokaColors.gold, fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => StoreCard(
                  store: _stores[i],
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => StoreHomeScreen(storeId: _stores[i].id))),
                  onDetails: () => showStoreDetails(context, _stores[i],
                      repository: _repo),
                ),
                childCount: _stores.length,
              ),
            ),
          ),
        ];
    }
  }
}
