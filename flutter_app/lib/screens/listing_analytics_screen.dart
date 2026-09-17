// BROKA — listing analytics
//
// One listing, and whether it is going to sell.
//
// The dashboard answers "how am I doing"; this answers "what is wrong with
// THIS one", which is a different question with a different action attached.
// A seller who sees their overall rating slipping cannot do much today; a
// seller who sees 180 views, 22 saves and nobody asking knows the price is
// the problem and can change it in thirty seconds.
//
// Everything here comes from GET /listings/{id}/metrics. Nothing is computed
// on-device: the sell probability and the advice are the same numbers the
// nightly snapshot records, so what the seller reads today is what the
// history will show tomorrow.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../main.dart';
// listing.dart directly: models.dart IMPORTS Listing rather than
// exporting it, so importing the barrel here would not bring the symbol
// into scope. Every other screen that uses Listing imports this path.
import '../models/listing.dart';
import '../services/api_service.dart';
import '../theme/motion.dart';
import '../widgets/chat_ambient_background.dart';
import '../widgets/factor_trend_chart.dart';
import '../widgets/motion_widgets.dart';

class ListingAnalyticsScreen extends StatefulWidget {
  const ListingAnalyticsScreen({super.key});

  @override
  State<ListingAnalyticsScreen> createState() => _ListingAnalyticsScreenState();
}

class _ListingAnalyticsScreenState extends State<ListingAnalyticsScreen> {
  Listing? _listing;
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  bool _initialised = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    _initialised = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Listing) _listing = args;
    _load();
  }

  Future<void> _load() async {
    final id = _listing?.id;
    if (id == null) {
      setState(() { _loading = false; _error = 'No listing selected.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final d = await ApiService.getListingMetrics(id, days: 60);
      if (mounted) setState(() { _data = d; _loading = false; });
    } catch (e) {
      // Shows the failure rather than an empty screen that looks like a
      // listing with no activity - those are very different messages to
      // give a seller.
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  Map<String, dynamic> get _current =>
      (_data?['current'] as Map?)?.cast<String, dynamic>() ?? const {};

  double? _live(String key) => (_current[key] as num?)?.toDouble();

  List<TrendPoint> _series(String key) {
    final hist = (_data?['history'] as List?) ?? const [];
    return [
      for (final row in hist)
        TrendPoint(
          DateTime.tryParse(row['date'] as String? ?? '') ?? DateTime.now(),
          (row[key] as num?)?.toDouble(),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => ChatAmbientBackground(
        // Same treatment as the dashboard: wraps the Scaffold so the field
        // runs behind the app bar too, rather than stopping at a line under
        // it. This screen was the one place the background was missing.
        intensity: 0.85,
        child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: BrokaColors.bg.withOpacity(0.55),
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('LISTING INSIGHTS',
                style: TextStyle(fontSize: 13, letterSpacing: 1.6,
                    fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
            if (_listing != null)
              Text(_listing!.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5,
                      color: BrokaColors.textMid, letterSpacing: 0.4)),
          ]),
          centerTitle: false,
        ),
        body: _loading
            ? _skeleton()
            : (_error != null ? _errorState() : _content()),
        ),
      );

  Widget _skeleton() => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: const [
          ShimmerBox(height: 150, radius: BorderRadius.all(Radius.circular(18))),
          SizedBox(height: 12),
          ShimmerBox(height: 92,  radius: BorderRadius.all(Radius.circular(14))),
          SizedBox(height: 12),
          ShimmerBox(height: 168, radius: BorderRadius.all(Radius.circular(16))),
        ],
      );

  Widget _errorState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.signal_wifi_statusbar_null_rounded,
                color: BrokaColors.textMid, size: 34),
            const SizedBox(height: 12),
            const Text("Couldn't load insights for this listing",
                textAlign: TextAlign.center,
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 14)),
            const SizedBox(height: 14),
            PressableScale(
              onTap: _load,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: BrokaColors.neonBlue.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.35)),
                ),
                child: const Text('Try again',
                    style: TextStyle(color: BrokaColors.neonBlue,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      );

  Widget _content() {
    final sections = <Widget>[
      _photoStrip(),
      _probabilityCard(),
      _statGrid(),
      _priceCard(),
      _adviceBlock(),
      _trends(),
    ];
    return RefreshIndicator(
      onRefresh: _load,
      color: BrokaColors.gold,
      backgroundColor: BrokaColors.bgCard,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
        children: [
          for (int i = 0; i < sections.length; i++)
            FadeSlideIn(index: i, child: Padding(
                padding: const EdgeInsets.only(bottom: 14), child: sections[i])),
        ],
      ),
    );
  }


  // ── Photos ────────────────────────────────────────────────────────────────
  //
  // The screen judges a listing on views, saves and price without ever
  // showing the thing being judged. A seller reading "20 views, no saves"
  // needs to see the photos to act on it, because the photos are usually
  // the cause - and asking them to navigate back to the listing to check
  // breaks the one train of thought the screen exists to support.
  //
  // Cover first, then the rest. Cover is the image buyers actually meet in
  // the feed, so it is the one the numbers are really about.
  //
  // Decoding mirrors product_card exactly: showcaseImageUrl is a full
  // "data:<mime>;base64,<payload>" string, while verifiedPhotos is bare
  // comma-separated base64. Two different shapes, two different strips -
  // getting that wrong is what produced the "XB" avatar bug.
  List<String> get _photoPayloads {
    final out = <String>[];
    final showcase = _listing?.showcaseImageUrl;
    if (showcase != null && showcase.isNotEmpty) {
      final idx = showcase.indexOf(',');
      if (idx != -1 && idx != showcase.length - 1) {
        out.add(showcase.substring(idx + 1));
      }
    }
    final verified = _listing?.verifiedPhotos;
    if (verified != null && verified.isNotEmpty) {
      for (final chunk in verified.split(',')) {
        final t = chunk.trim();
        if (t.isNotEmpty) out.add(t);
      }
    }
    return out;
  }

  Widget _photoStrip() {
    final photos = _photoPayloads;
    if (photos.isEmpty) {
      return Container(
        height: 96,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.danger.withOpacity(0.3)),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_not_supported_rounded,
              size: 16, color: BrokaColors.danger),
          SizedBox(width: 8),
          Text('No photos on this listing',
              style: TextStyle(color: BrokaColors.danger, fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ]),
      );
    }
    return SizedBox(
      height: 96,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        itemBuilder: (_, i) => Padding(
          padding: EdgeInsets.only(right: i == photos.length - 1 ? 0 : 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 120,
              child: Stack(fit: StackFit.expand, children: [
                Builder(builder: (_) {
                  try {
                    return Image.memory(base64Decode(photos[i]),
                        fit: BoxFit.cover, gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => Container(
                            color: BrokaColors.bgCard,
                            child: const Icon(Icons.broken_image_rounded,
                                color: BrokaColors.textMid, size: 18)));
                  } catch (_) {
                    // base64Decode throws rather than routing through
                    // errorBuilder, so it has to be caught here.
                    return Container(color: BrokaColors.bgCard,
                        child: const Icon(Icons.broken_image_rounded,
                            color: BrokaColors.textMid, size: 18));
                  }
                }),
                if (i == 0)
                  Positioned(
                    left: 6, top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: BrokaColors.bg.withOpacity(0.78),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('COVER',
                          style: TextStyle(color: BrokaColors.gold,
                              fontSize: 8.5, letterSpacing: 0.8,
                              fontWeight: FontWeight.w800)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ── Headline ──────────────────────────────────────────────────────────────

  Widget _probabilityCard() {
    final p = (_current['sell_probability'] as num?)?.toDouble() ?? 0;
    final conf = (_current['confidence'] as num?)?.toDouble() ?? 0;
    final colour = p >= 65 ? BrokaColors.neonGreen
                 : (p >= 40 ? BrokaColors.gold : BrokaColors.danger);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: BrokaColors.cardGradColors,
            begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colour.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('CHANCE OF SELLING',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 10,
                letterSpacing: 1.4, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: p),
            duration: BrokaMotion.reduced(context)
                ? Duration.zero : const Duration(milliseconds: 900),
            curve: BrokaMotion.enter,
            builder: (_, v, __) => Text('${v.toStringAsFixed(0)}%',
                style: TextStyle(color: colour, fontSize: 40,
                    fontWeight: FontWeight.w900, height: 1.0)),
          ),
          const SizedBox(width: 10),
          // Says how much to trust the number rather than presenting a
          // confident figure built on four data points. A listing posted
          // this morning genuinely does not have a knowable answer yet, and
          // pretending otherwise is how a seller drops a price that was
          // never the problem.
          if (conf < 0.6)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                conf < 0.3 ? 'early estimate' : 'still firming up',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        _componentBars(),
      ]),
    );
  }

  /// The five terms behind the headline number.
  ///
  /// Shown because a percentage on its own is a verdict a seller can only
  /// accept or ignore. Broken into demand / interest / buyers / you / price,
  /// the short bar is the thing to work on.
  Widget _componentBars() {
    final c = (_current['components'] as Map?)?.cast<String, dynamic>() ?? const {};
    const labels = {
      'demand': 'Views', 'intent': 'Saves', 'commitment': 'Buyers asking',
      'seller': 'Your service', 'price_fit': 'Price',
    };
    return Column(children: [
      for (final e in labels.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            SizedBox(width: 92, child: Text(e.value,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5))),
            Expanded(child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: ((c[e.key] as num?)?.toDouble() ?? 0)),
              duration: BrokaMotion.reduced(context)
                  ? Duration.zero : const Duration(milliseconds: 750),
              curve: BrokaMotion.enter,
              builder: (_, v, __) => ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: v.clamp(0.0, 1.0),
                  minHeight: 5,
                  backgroundColor: BrokaColors.bg.withOpacity(0.6),
                  valueColor: AlwaysStoppedAnimation(
                      v >= 0.6 ? BrokaColors.neonGreen
                               : (v >= 0.3 ? BrokaColors.gold : BrokaColors.danger)),
                ),
              ),
            )),
          ]),
        ),
    ]);
  }

  // ── Raw numbers ───────────────────────────────────────────────────────────

  Widget _statGrid() {
    final views = (_current['views'] as num?)?.toInt() ?? 0;
    final likes = (_current['likes'] as num?)?.toInt() ?? 0;
    final ratio = (_current['like_to_view_ratio'] as num?)?.toDouble();
    final asking = (_current['interested_buyers'] as num?)?.toInt() ?? 0;
    final vpd = (_current['views_per_day'] as num?)?.toDouble() ?? 0;

    Widget tile(String v, String l, Color c) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(children: [
          Text(v, style: TextStyle(color: c, fontSize: 18,
              fontWeight: FontWeight.w900)),
          const SizedBox(height: 3),
          Text(l, textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 9.5,
                  letterSpacing: 0.5, fontWeight: FontWeight.w600)),
        ]),
      ),
    );

    return Column(children: [
      Row(children: [
        tile('$views', 'VIEWS', BrokaColors.neonBlue),
        const SizedBox(width: 8),
        tile('$likes', 'SAVES', BrokaColors.gold),
        const SizedBox(width: 8),
        tile('$asking', 'ASKED', BrokaColors.neonGreen),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        tile(ratio == null ? '—' : '${(ratio * 100).toStringAsFixed(1)}%',
             'SAVES PER VIEW', BrokaColors.neonCyan),
        const SizedBox(width: 8),
        tile(vpd.toStringAsFixed(1), 'VIEWS / DAY', BrokaColors.neonBlue),
      ]),
    ]);
  }

  // ── Price position ────────────────────────────────────────────────────────

  Widget _priceCard() {
    final price = (_current['price'] as num?)?.toDouble();
    final median = (_current['category_median_price'] as num?)?.toDouble();
    final delta = (_current['price_delta_percent'] as num?)?.toDouble();
    final comparables = (_current['comparable_count'] as num?)?.toInt() ?? 0;

    if (price == null) return const SizedBox.shrink();

    // No benchmark: say so, do not imply the price is fine.
    //
    // This card previously compared a listing against a median that
    // INCLUDED the listing itself, so a category containing one item
    // reported 0% off the median and "your price is competitive". A router
    // at KES 30,000 against a real value near KES 2,000 was told it was
    // priced correctly - the seller's own guess handed back as
    // confirmation. Silence is the honest output here.
    if (median == null || delta == null) {
      return Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('PRICE',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 10,
                  letterSpacing: 1.3, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text('KES ${price.toStringAsFixed(0)}',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.info_outline_rounded,
                size: 13, color: BrokaColors.textMid),
            const SizedBox(width: 6),
            Expanded(child: Text(
                comparables == 0
                    ? 'No other listings in this category yet — nothing to '
                      'compare against'
                    : 'Only $comparables other listings in this category — too '
                      'few to judge your price against',
                style: const TextStyle(color: BrokaColors.textMid,
                    fontSize: 11, height: 1.35))),
          ]),
        ]),
      );
    }
    final over = delta > 0;
    final notable = delta.abs() >= 10;

    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('PRICE VS SIMILAR LISTINGS',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 10,
                letterSpacing: 1.3, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [
          Text('KES ${price.toStringAsFixed(0)}',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (notable && over ? BrokaColors.danger : BrokaColors.neonGreen)
                  .withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${over ? '+' : ''}${delta.toStringAsFixed(0)}% vs median',
              style: TextStyle(
                  color: notable && over ? BrokaColors.danger : BrokaColors.neonGreen,
                  fontSize: 10.5, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Text('Based on $comparables similar listings, around KES ${median.toStringAsFixed(0)}',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
      ]),
    );
  }

  // ── Advice ────────────────────────────────────────────────────────────────

  Widget _adviceBlock() {
    final advice = (_data?['advice'] as Map?)?.cast<String, dynamic>();
    if (advice == null) return const SizedBox.shrink();
    final pos = (advice['positives'] as List?) ?? const [];
    final neg = (advice['negatives'] as List?) ?? const [];
    final recs = (advice['recommendations'] as List?) ?? const [];
    if (pos.isEmpty && neg.isEmpty && recs.isEmpty) {
      return const SizedBox.shrink();
    }

    Widget card(Map c, bool good) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (good ? BrokaColors.neonGreen : BrokaColors.danger).withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(
            color: good ? BrokaColors.neonGreen : BrokaColors.danger, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c['title'] as String? ?? '',
            style: const TextStyle(color: BrokaColors.textHigh,
                fontSize: 12.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(c['detail'] as String? ?? '',
            style: const TextStyle(color: BrokaColors.textMid,
                fontSize: 11.5, height: 1.35)),
      ]),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Negatives first here, unlike the dashboard. A seller opening ONE
      // listing is looking for the thing to fix, so the fix goes at the top.
      if (neg.isNotEmpty) ...[
        const Text('WHAT TO FIX',
            style: TextStyle(color: BrokaColors.danger, fontSize: 10,
                letterSpacing: 1.3, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (final c in neg) card(c as Map, false),
        const SizedBox(height: 6),
      ],
      if (recs.isNotEmpty) ...[
        const SizedBox(height: 6),
        for (final c in recs) _storeCard(c as Map, context),
        const SizedBox(height: 6),
      ],
      if (pos.isNotEmpty) ...[
        const Text('WORKING WELL',
            style: TextStyle(color: BrokaColors.neonGreen, fontSize: 10,
                letterSpacing: 1.3, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (final c in pos) card(c as Map, true),
      ],
    ]);
  }


  /// The store recommendation, shown here as well as on the dashboard.
  ///
  /// A seller staring at one listing that is not moving is in exactly the
  /// frame of mind this answers, and this screen gets opened far more often
  /// than the dashboard's recommendation block gets scrolled to.
  Widget _storeCard(Map c, BuildContext context) => PressableScale(
    onTap: () => Navigator.pushNamed(context, '/store-explainer'),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            BrokaColors.gold.withOpacity(0.10), BrokaColors.bgCard),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.38)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.storefront_rounded,
              size: 16, color: BrokaColors.gold),
          const SizedBox(width: 8),
          Expanded(child: Text(c['title'] as String? ?? '',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontSize: 13, fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 6),
        Text(c['detail'] as String? ?? '',
            style: const TextStyle(color: BrokaColors.textMid,
                fontSize: 11.5, height: 1.4)),
        if (c['cta'] != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(c['cta'] as String,
                  style: const TextStyle(color: Colors.white,
                      fontSize: 11.5, fontWeight: FontWeight.w800)),
              const SizedBox(width: 5),
              const Icon(Icons.arrow_forward_rounded,
                  size: 13, color: Colors.white),
            ]),
          ),
        ],
      ]),
    ),
  );

  // ── History ───────────────────────────────────────────────────────────────

  Widget _trends() => Column(children: [
        FactorTrendChart(
          label: 'Chance of selling',
          points: _series('sell_probability'),
          currentValue: _live('sell_probability'),
          goodThreshold: 65, poorThreshold: 40,
          format: (v) => '${v.toStringAsFixed(0)}%',
          lineColor: BrokaColors.gold,
        ),
        const SizedBox(height: 10),
        FactorTrendChart(
          label: 'Views per day',
          points: _series('views_today'),
          currentValue: _live('views_per_day'),
          goodThreshold: 5, poorThreshold: 1,
          format: (v) => v.toStringAsFixed(0),
          lineColor: BrokaColors.neonBlue,
        ),
        const SizedBox(height: 10),
        FactorTrendChart(
          label: 'Saves',
          points: _series('likes'),
          currentValue: _live('likes'),
          goodThreshold: 10, poorThreshold: 2,
          format: (v) => v.toStringAsFixed(0),
          lineColor: BrokaColors.neonCyan,
        ),
      ]);
}
