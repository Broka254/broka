// lib/features/traders/presentation/trader_profile_screen.dart
// A trader's page, in Home's language (2026-10-12): the constellation behind
// it, a hero header on the trader's own background image (or the Traders
// gradient), glass cards, glowing titles. It used to be a plain AppBar over
// a centred avatar and three numbers - a screen from a different app - and
// said little more than the card that opened it. Now it adds what a buyer
// weighs before writing to someone: how long they've sold here, what buyers
// say, how fast they answer, what they're about, their stores, what is on
// sale now. The trader themselves can set or remove the background image
// their card and this header show (POST /traders/me/cover).
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../../../services/image_upload_service.dart';
import '../../../services/photo_capture.dart';
import '../../../widgets/collapsing_screen_header.dart' show BrokaEmptyState, BrokaHeaderButton;
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_grid_view.dart';
import '../../discovery/domain/destination_visual.dart';
import '../../listings/data/repositories/listings_repository.dart';
import '../../listings/domain/models/listing.dart';
import '../data/repositories/traders_repository.dart';
import '../domain/models/trader.dart';

/// A profile photo as the backend sends it: one of BROKA's image URLs, or
/// base64 from an older build. Null when there is none or it can't be read -
/// a bad photo must not take the whole card down with it.
ImageProvider? traderPhoto(String? value) {
  if (value == null || value.isEmpty) return null;
  if (value.startsWith('http')) return NetworkImage(value);
  try {
    return MemoryImage(base64Decode(value.contains(',') ? value.split(',').last : value));
  } catch (_) {
    return null;
  }
}

class TraderProfileScreen extends StatefulWidget {
  final String traderId;
  const TraderProfileScreen({super.key, required this.traderId});

  @override
  State<TraderProfileScreen> createState() => _TraderProfileScreenState();
}

class _TraderProfileScreenState extends State<TraderProfileScreen> {
  static const _visual = DestinationVisuals.traders;

  Trader? _trader;
  bool _loading = true;
  bool _savingCover = false;
  String? _error;
  final _grid = ProductGridController();

  bool get _isOwn => _trader != null && _trader!.id == ApiService.currentUserId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _trader == null;
      _error = null;
    });
    final result = await tradersRepository.get(
      widget.traderId,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    if (!mounted) return;
    result.fold(
      onSuccess: (data) => setState(() {
        _trader = data;
        _loading = false;
      }),
      onFailure: (msg, __) => setState(() {
        _error = msg;
        _loading = false;
      }),
    );
  }

  Future<void> _refresh() async {
    await Future.wait([_load(), _grid.refresh()]);
  }

  // ── The trader's own background ───────────────────────────────────────────

  Future<void> _changeCover() async {
    final file = await PhotoCapture.pickFromGallery(context);
    if (file == null || !mounted) return;
    setState(() => _savingCover = true);
    try {
      final uploaded = await imageUploadService.uploadFile(file, purpose: ImagePurpose.traderCover);
      final saved = await tradersRepository.setCover(uploaded.id);
      if (!mounted) return;
      if (saved case Failure(:final message)) {
        _say(message);
      } else {
        _say('Background updated - buyers see it on your trader card.');
        await _load();
      }
    } catch (_) {
      if (mounted) _say("Couldn't upload that image. Try another one.");
    } finally {
      if (mounted) setState(() => _savingCover = false);
    }
  }

  Future<void> _removeCover() async {
    setState(() => _savingCover = true);
    final saved = await tradersRepository.setCover(null);
    if (!mounted) return;
    setState(() => _savingCover = false);
    if (saved case Failure(:final message)) {
      _say(message);
    } else {
      await _load();
    }
  }

  void _coverMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: BrokaColors.border, borderRadius: BorderRadius.circular(2))),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('Your trader card background',
                style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Optional. Shown behind your name on the Traders list and on this page.',
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
          ),
          ListTile(
            leading: const Icon(Icons.add_photo_alternate_outlined, color: BrokaColors.neonBlue),
            title: Text(_trader?.coverUrl == null ? 'Choose an image' : 'Change the image',
                style: const TextStyle(color: BrokaColors.textHigh)),
            onTap: () {
              Navigator.pop(sheet);
              _changeCover();
            },
          ),
          if (_trader?.coverUrl != null)
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: BrokaColors.danger),
              title: const Text('Remove it', style: TextStyle(color: BrokaColors.textHigh)),
              onTap: () {
                Navigator.pop(sheet);
                _removeCover();
              },
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
    }
    final trader = _trader;
    if (trader == null) {
      return SafeArea(
        child: Column(children: [
          Align(alignment: Alignment.centerLeft, child: _backButton()),
          Expanded(
            child: BrokaEmptyState(
              emoji: '📡',
              gradient: _visual.gradient,
              headline: "Couldn't load this trader",
              body: _error ?? 'Trader not found',
              action: OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _hero(trader)),
          SliverToBoxAdapter(child: _stats(trader)),
          SliverToBoxAdapter(child: _facts(trader)),
          if (trader.about != null) SliverToBoxAdapter(child: _about(trader.about!)),
          if (trader.stores.isNotEmpty) SliverToBoxAdapter(child: _stores(trader)),
          if (trader.specializations?.isNotEmpty ?? false)
            SliverToBoxAdapter(child: _categories(trader)),
          SliverToBoxAdapter(child: _actions(trader)),
          SliverToBoxAdapter(
            child: _sectionTitle('On sale now',
                trailing: trader.activeListings == null ? null : '${trader.activeListings}'),
          ),
          ProductGridView(
            sliver: true,
            controller: _grid,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            fetchPage: (page) async {
              final result = await listingsRepository.getListings(
                sellerId: trader.id,
                limit: 20,
                offset: page * 20,
              );
              return result.fold<List<BrokaListing>>(
                onSuccess: (data) => data,
                onFailure: (_, __) => <BrokaListing>[],
              );
            },
            onTapItem: (item) => Navigator.pushNamed(context, '/product',
                arguments: {'listingId': (item as BrokaListing).id}),
            onViewStore: (storeId, storeSlug) => Navigator.pushNamed(
                context, '/store-view', arguments: {'storeId': storeId}),
            emptyStateBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('Nothing on sale right now',
                    style: TextStyle(color: BrokaColors.textMid)),
              ),
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: MediaQuery.of(context).padding.bottom + 12)),
        ],
      ),
    );
  }

  Widget _backButton() => IconButton(
        tooltip: 'Back',
        onPressed: () => Navigator.maybePop(context),
        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: BrokaColors.textHigh, size: 19),
      );

  /// The trader's background (or the Traders gradient), their photo with a
  /// glowing ring, their name and where they are.
  Widget _hero(Trader trader) {
    final top = MediaQuery.of(context).padding.top;
    final photo = traderPhoto(trader.profilePhoto);
    final cover = trader.coverUrl;
    return SizedBox(
      height: top + 268,
      child: Stack(fit: StackFit.expand, children: [
        // The background, fading into the sky below it.
        ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.white, Colors.transparent],
            stops: [0.0, 0.55, 1.0],
          ).createShader(r),
          child: cover != null
              ? Image.network(cover,
                  fit: BoxFit.cover,
                  color: Colors.black.withOpacity(0.35),
                  colorBlendMode: BlendMode.darken,
                  errorBuilder: (_, __, ___) => _gradientCover())
              : _gradientCover(),
        ),
        Positioned(
          top: top + 4,
          left: 4,
          right: 12,
          child: Row(children: [
            _backButton(),
            const Spacer(),
            if (_isOwn)
              _savingCover
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold)),
                    )
                  : BrokaHeaderButton(
                      icon: Icons.wallpaper_rounded,
                      tooltip: 'Card background',
                      onTap: _coverMenu,
                    ),
          ]),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 4,
          child: Column(children: [
            Stack(clipBehavior: Clip.none, children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: _visual.gradient),
                  boxShadow: [
                    BoxShadow(color: _visual.gradient.first.withOpacity(0.55), blurRadius: 22),
                  ],
                ),
                child: CircleAvatar(
                  radius: 44,
                  backgroundColor: BrokaColors.bgCard,
                  backgroundImage: photo,
                  child: photo != null
                      ? null
                      : Text(
                          trader.businessName.isNotEmpty ? trader.businessName[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 32),
                        ),
                ),
              ),
              if (trader.isOnline)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: BrokaColors.neonGreen,
                      border: Border.all(color: BrokaColors.bg, width: 3),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Flexible(
                child: Text(trader.businessName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        height: 1.15,
                        shadows: [Shadow(color: _visual.gradient.first, blurRadius: 18)])),
              ),
              if (trader.isVerified) ...[
                const SizedBox(width: 6),
                const Icon(Icons.verified_rounded, size: 20, color: BrokaColors.neonGreen),
              ],
            ]),
            if (trader.locationName != null || trader.distanceKm != null) ...[
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.location_on_rounded, size: 14, color: BrokaColors.neonBlue),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    [
                      if (trader.locationName != null) trader.locationName!,
                      if (trader.distanceKm != null) '${trader.distanceKm!.toStringAsFixed(1)} km away',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _gradientCover() => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _visual.gradient.first.withOpacity(0.55),
              BrokaColors.neonPurple.withOpacity(0.35),
              BrokaColors.bg,
            ],
          ),
        ),
      );

  /// Four numbers a buyer weighs, on one glass card.
  Widget _stats(Trader trader) {
    final stars = trader.reviewAvg ?? (trader.reviewCount > 0 ? trader.rating : null);
    final reply = trader.medianResponseMinutes;
    return _glass(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
      child: Row(children: [
        _stat(stars == null ? 'New' : stars.toStringAsFixed(1),
            trader.reviewCount == 1 ? '1 review' : '${trader.reviewCount} reviews',
            Icons.star_rounded, const Color(0xFFFBBF24)),
        _divider(),
        _stat('${trader.completedDeals}', 'Deals done', Icons.handshake_rounded, BrokaColors.neonGreen),
        _divider(),
        _stat('${trader.activeListings ?? trader.listingCount}', 'On sale', Icons.sell_rounded,
            BrokaColors.neonPink),
        _divider(),
        _stat(reply == null ? '—' : _minutes(reply), 'Replies in', Icons.bolt_rounded, BrokaColors.neonCyan),
      ]),
    );
  }

  static String _minutes(double m) {
    if (m < 1) return '<1m';
    if (m < 60) return '${m.round()}m';
    final h = m / 60;
    return h < 24 ? '${h.toStringAsFixed(h < 10 ? 1 : 0)}h' : '${(h / 24).round()}d';
  }

  Widget _stat(String value, String label, IconData icon, Color color) => Expanded(
        child: Column(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 5),
          Text(value,
              maxLines: 1,
              style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5)),
        ]),
      );

  Widget _divider() => Container(width: 1, height: 36, color: BrokaColors.border.withOpacity(0.7));

  /// Member since, last seen - small facts as chips.
  Widget _facts(Trader trader) {
    final chips = <Widget>[
      if (trader.memberSince != null)
        _chip(Icons.event_available_rounded, 'On BROKA since ${_monthYear(trader.memberSince!)}'),
      if (trader.isOnline)
        _chip(Icons.circle, 'Active now', color: BrokaColors.neonGreen)
      else if (trader.lastSeen != null)
        _chip(Icons.schedule_rounded, 'Active ${_ago(trader.lastSeen!)}'),
      if (trader.isVerified) _chip(Icons.verified_user_rounded, 'Verified', color: BrokaColors.neonGreen),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _monthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';

  static String _ago(DateTime at) {
    final d = DateTime.now().toUtc().difference(at.isUtc ? at : DateTime.utc(
        at.year, at.month, at.day, at.hour, at.minute, at.second));
    if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Widget _chip(IconData icon, String text, {Color color = BrokaColors.neonBlue}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: icon == Icons.circle ? 8 : 13, color: color),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _about(String about) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle('About'),
        _glass(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.all(14),
          child: Text(about,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, height: 1.5)),
        ),
      ]);

  Widget _stores(Trader trader) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle(trader.stores.length == 1 ? 'Store' : 'Stores'),
        for (final s in trader.stores)
          GestureDetector(
            onTap: () => Navigator.pushNamed(context, '/store-view', arguments: {'storeId': s.id}),
            child: _glass(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
                  ),
                  child: const Icon(Icons.storefront_rounded, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 14)),
                ),
                const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid),
              ]),
            ),
          ),
      ]);

  Widget _categories(Trader trader) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _sectionTitle('Specializes in'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in trader.specializations!) _chip(Icons.category_rounded, s.name, color: BrokaColors.neonPurple),
            ],
          ),
        ),
      ]);

  /// Reviews and the full profile live on the user profile screen.
  Widget _actions(Trader trader) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: SizedBox(
          height: 46,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(23),
              gradient: LinearGradient(colors: _visual.gradient),
              boxShadow: [BoxShadow(color: _visual.gradient.first.withOpacity(0.35), blurRadius: 14)],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(23),
                onTap: () => Navigator.pushNamed(context, '/user-profile', arguments: trader.id),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.reviews_rounded, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Text(trader.reviewCount > 0 ? 'Reviews & full profile' : 'Full profile',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                ]),
              ),
            ),
          ),
        ),
      );

  Widget _sectionTitle(String text, {String? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
        child: Row(children: [
          ZoneGlowText(text.toUpperCase(), gradient: _visual.gradient, fontSize: 13, letterSpacing: 1.6),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(trailing, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ]),
      );

  Widget _glass({required Widget child, EdgeInsets? margin, EdgeInsets? padding}) => Container(
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.82),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.22)),
        ),
        child: child,
      );
}
