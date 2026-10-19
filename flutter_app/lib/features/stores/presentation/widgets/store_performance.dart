// BROKA — My Store's performance section
//
// The store dashboard's equivalent of the seller dashboard's command
// centre: a rating you can explain, a rank, period-over-period KPIs, a
// trend chart, what buyers did with each product, and advice that cites a
// number.
//
// WHERE THE NUMBERS COME FROM
// One owner-only request, GET /stores/{id}/insights, and nothing else. The
// backend measures every figure (stores/insights.py); this file parses and
// draws them. That is deliberate: a chart whose numbers are assembled on
// the phone from several endpoints drifts from the server's own totals the
// first time one of those endpoints changes.
//
// WHAT "REALTIME" MEANS HERE, EXACTLY
// Two honest things, no invented ones:
//   * the live-visitor count is a real count of distinct visitors in the
//     last five minutes (backend stats.live_visitors) - the same window the
//     chat header calls "online";
//   * the card refreshes itself every 30 s while the app is in front, so
//     the figure moves without a pull. It stops when the app is
//     backgrounded rather than polling a screen nobody is looking at.
//
// A dash, never a zero, for a value that has not loaded: a zero on this
// screen means "nobody came", which is a very different message from "still
// loading".
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../main.dart';
import '../../../../core/utils/result.dart';
import '../../../../widgets/axis_line_chart.dart';
import '../../data/repositories/stores_repository.dart';
import '../../domain/models/store_insights.dart';

/// How often the card refreshes itself while the app is in front.
const _pollEvery = Duration(seconds: 30);

class StorePerformanceSection extends StatefulWidget {
  const StorePerformanceSection({
    super.key,
    required this.storeId,
    required this.repo,
    this.refreshTick = 0,
    this.onOpenProduct,
    this.animate = true,
  });

  final String storeId;
  final StoresRepository repo;

  /// Bumped by the parent on pull-to-refresh, so one gesture refreshes the
  /// whole screen rather than only the cards above this one.
  final int refreshTick;

  /// Opens a product from the "Top products" card. Null hides the tap.
  final void Function(String listingId)? onOpenProduct;

  /// False in tests: no self-refresh timer, so a test's pump loop stays
  /// deterministic.
  final bool animate;

  @override
  State<StorePerformanceSection> createState() => _StorePerformanceSectionState();
}

class _StorePerformanceSectionState extends State<StorePerformanceSection> {
  StoreInsights? _data;
  String? _error;
  bool _loading = true;
  int _days = 7;
  StoreMetric _metric = StoreMetric.visits;
  bool _changingPeriod = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.animate) _startPolling();
  }

  @override
  void didUpdateWidget(StorePerformanceSection old) {
    super.didUpdateWidget(old);
    if (old.refreshTick != widget.refreshTick) _load(silent: true);
    if (old.storeId != widget.storeId) _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_pollEvery, (_) {
      // Only while someone can see it. A backgrounded app polling a store
      // dashboard is battery spent on nothing.
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
      _load(silent: true);
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = _data == null);
    final result = await widget.repo.getInsights(widget.storeId, days: _days);
    if (!mounted) return;
    switch (result) {
      case Success(:final data):
        setState(() {
          _data = data;
          _error = null;
          _loading = false;
          _changingPeriod = false;
        });
      case Failure(:final message):
        setState(() {
          // A failed silent refresh keeps the last good data on screen:
          // replacing real numbers with an error on a dropped packet makes
          // the screen worse than slightly stale numbers.
          if (_data == null) _error = message;
          _loading = false;
          _changingPeriod = false;
        });
    }
  }

  Future<void> _setPeriod(int days) async {
    if (days == _days) return;
    setState(() {
      _days = days;
      _changingPeriod = true;
    });
    await _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return _card(
        child: SizedBox(
          height: 130,
          child: Center(
            child: _loading
                ? const CircularProgressIndicator(color: BrokaColors.gold)
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error ?? "Couldn't load your numbers",
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ]),
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _ratingCard(data),
      const SizedBox(height: 14),
      _kpiGrid(data),
      const SizedBox(height: 14),
      _trendCard(data),
      if (data.topProducts.isNotEmpty) ...[
        const SizedBox(height: 14),
        _topProductsCard(data),
      ],
      if (data.positives.isNotEmpty || data.negatives.isNotEmpty) ...[
        const SizedBox(height: 14),
        _adviceCard(data),
      ],
      const SizedBox(height: 14),
      _sourcesCard(data),
    ]);
  }

  // ── Rating ────────────────────────────────────────────────────────────────

  Widget _ratingCard(StoreInsights d) {
    final breakdown = d.ratingBreakdown;
    return _card(
      key: const Key('store-rating-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.ratingLabel, style: const TextStyle(color: BrokaColors.textHigh,
                fontSize: 34, fontWeight: FontWeight.w800, height: 1.0)),
            const SizedBox(height: 2),
            const Text('out of 10', style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
          ]),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.star_rounded, size: 16, color: BrokaColors.gold),
              const SizedBox(width: 4),
              Text(
                  d.reviewCount == 0
                      ? 'No reviews yet'
                      : '${d.reviewCount} review${d.reviewCount == 1 ? '' : 's'}',
                  key: const Key('store-rating-reviews'),
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 3),
            Text(
                d.rankLabel ?? 'Not ranked yet',
                key: const Key('store-rating-rank'),
                style: const TextStyle(color: BrokaColors.neonCyan, fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(d.replyLabel ?? 'Reply time not measured yet',
                key: const Key('store-reply-line'),
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
          ])),
        ]),
        if (breakdown != null) ...[
          const SizedBox(height: 14),
          _ComponentBar(
            key: const Key('rating-review-bar'),
            label: 'Reviews',
            value: breakdown.review,
            weight: 0.55,
            color: BrokaColors.gold,
          ),
          _ComponentBar(
            key: const Key('rating-response-bar'),
            label: 'Reply speed',
            value: breakdown.response,
            weight: 0.30,
            color: BrokaColors.neonCyan,
          ),
          _ComponentBar(
            key: const Key('rating-tenure-bar'),
            label: 'Time on BROKA',
            value: breakdown.tenure,
            weight: 0.15,
            color: BrokaColors.neonBlue,
          ),
        ],
        if (d.ratingExplanation != null) ...[
          const SizedBox(height: 10),
          Text(d.ratingExplanation!, key: const Key('store-rating-explanation'),
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.45)),
        ],
      ]),
    );
  }

  // ── KPIs ──────────────────────────────────────────────────────────────────

  Widget _kpiGrid(StoreInsights d) {
    final items = <({String key, IconData icon, StoreKpi kpi, String label})>[
      (key: 'kpi-visits', icon: Icons.people_alt_outlined, kpi: d.visits, label: 'Visitors'),
      (key: 'kpi-views', icon: Icons.visibility_outlined, kpi: d.productViews, label: 'Product views'),
      (key: 'kpi-saves', icon: Icons.bookmark_outline_rounded, kpi: d.saves, label: 'Saves'),
      (key: 'kpi-chats', icon: Icons.forum_outlined, kpi: d.chats, label: 'Chats'),
      (key: 'kpi-interested', icon: Icons.handshake_outlined, kpi: d.interestedBuyers,
          label: 'Interested'),
      (key: 'kpi-shares', icon: Icons.ios_share_rounded, kpi: d.shares, label: 'Shares'),
    ];
    return LayoutBuilder(builder: (context, box) {
      final columns = box.maxWidth < 340 ? 2 : 3;
      final width = (box.maxWidth - (columns - 1) * 8) / columns;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final item in items)
          SizedBox(
            width: width,
            child: _KpiTile(
              key: Key(item.key),
              icon: item.icon,
              value: item.kpi.value,
              label: item.label,
              change: item.kpi.changePercent,
              isNew: item.kpi.isNew,
              // A lifetime counter is labelled as such rather than passed
              // off as this period's traffic.
              note: item.kpi.exact ? null : 'since tracking began',
            ),
          ),
      ]);
    });
  }

  // ── Trend ─────────────────────────────────────────────────────────────────

  Widget _trendCard(StoreInsights d) {
    final series = d.seriesFor(_metric);
    return _card(
      key: const Key('store-trend-card'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('Performance',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                    fontWeight: FontWeight.w800)),
          ),
          if (_changingPeriod)
            const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold)),
        ]),
        const SizedBox(height: 10),
        // Metric switch.
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final metric in StoreMetric.values)
            _ChoiceChip(
              key: Key('metric-${metric.name}'),
              label: metric.label,
              selected: _metric == metric,
              onTap: () => setState(() => _metric = metric),
            ),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 164,
          child: series.isEmpty
              ? const Center(
                  child: Text('No data yet', style: TextStyle(color: BrokaColors.textMid, fontSize: 13)))
              : AxisLineChart(
                  values: [for (final p in series) p.count.toDouble()],
                  positions: datePositions([for (final p in series) p.date]),
                  xTicks: dateTicks([for (final p in series) p.date]),
                  yFormat: (v) => v.round().toString(),
                  xTitle: 'Date',
                  yTitle: _metric.axisTitle,
                  lineColor: BrokaColors.neonBlue,
                  yFloor: 0,
                  minStep: 1,
                  showLastValue: true,
                ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          for (final days in const [7, 30, 90])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _ChoiceChip(
                key: Key('period-$days'),
                label: '$days days',
                selected: _days == days,
                onTap: () => _setPeriod(days),
              ),
            ),
        ]),
      ]),
    );
  }

  // ── Products ──────────────────────────────────────────────────────────────

  Widget _topProductsCard(StoreInsights d) {
    return _card(
      key: const Key('store-top-products'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Top products',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('By views, all time',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        const SizedBox(height: 10),
        for (var i = 0; i < d.topProducts.length; i++) ...[
          if (i > 0) Divider(height: 16, color: BrokaColors.border.withOpacity(0.7)),
          _ProductRow(
            key: Key('top-product-${d.topProducts[i].id}'),
            product: d.topProducts[i],
            onTap: widget.onOpenProduct == null
                ? null
                : () => widget.onOpenProduct!(d.topProducts[i].id),
          ),
        ],
      ]),
    );
  }

  // ── Advice ────────────────────────────────────────────────────────────────

  Widget _adviceCard(StoreInsights d) {
    return _card(
      key: const Key('store-advice'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('What to do next',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        for (final card in d.negatives) _AdviceRow(card: card, positive: false),
        for (final card in d.positives) _AdviceRow(card: card, positive: true),
      ]),
    );
  }

  // ── Sources ───────────────────────────────────────────────────────────────

  Widget _sourcesCard(StoreInsights d) {
    final sources = d.visitsBySource.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (sources.isEmpty) {
      return _card(
        key: const Key('store-sources'),
        child: const Text(
            'No visitors yet. Share your link on WhatsApp or your socials to bring in '
            'your first customers.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
      );
    }
    final total = sources.fold<int>(0, (sum, e) => sum + e.value);
    return _card(
      key: const Key('store-sources'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Where visitors came from · last ${d.days} days',
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        for (final e in sources.take(5))
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(children: [
              SizedBox(width: 104, child: Text(_sourceLabel(e.key),
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5))),
              Expanded(child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: total == 0 ? 0 : e.value / total,
                  minHeight: 6,
                  backgroundColor: BrokaColors.border,
                  valueColor: const AlwaysStoppedAnimation(BrokaColors.gold),
                ),
              )),
              SizedBox(width: 38, child: Text('${e.value}', textAlign: TextAlign.right,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 12))),
            ]),
          ),
      ]),
    );
  }

  static String _sourceLabel(String key) => switch (key) {
        'whatsapp' => 'WhatsApp',
        'tiktok' => 'TikTok',
        'instagram' => 'Instagram',
        'facebook' => 'Facebook',
        'x' => 'X',
        'qr' => 'QR code',
        'direct' => 'Direct / typed',
        _ => 'Other',
      };
}

// ── Building blocks ─────────────────────────────────────────────────────────

Widget _card({Key? key, required Widget child}) => Container(
      key: key,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
      ),
      child: child,
    );

class _ComponentBar extends StatelessWidget {
  const _ComponentBar({
    super.key,
    required this.label,
    required this.value,
    required this.weight,
    required this.color,
  });
  final String label;
  final double value;
  final double weight;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          SizedBox(width: 96, child: Text(label,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12))),
          Expanded(child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor: BrokaColors.border,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          )),
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            child: Text('${(weight * 100).round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5)),
          ),
        ]),
      );
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.change,
    this.isNew = false,
    this.note,
  });
  final IconData icon;
  final int value;
  final String label;
  final double? change;
  final bool isNew;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final up = (change ?? 0) >= 0;
    final color = isNew ? BrokaColors.neonCyan
        : change == null ? BrokaColors.textMid
        : up ? BrokaColors.success : BrokaColors.danger;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 17, color: BrokaColors.neonCyan),
          const Spacer(),
          if (isNew)
            Text('new', style: TextStyle(color: color, fontSize: 10.5,
                fontWeight: FontWeight.w800))
          else if (change != null)
            Text('${up ? '+' : ''}${change!.toStringAsFixed(0)}%',
                key: const Key('kpi-change'),
                style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),
        Text('$value', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 22,
                fontWeight: FontWeight.w800, height: 1.05)),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        if (note != null) ...[
          const SizedBox(height: 2),
          Text(note!, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textLow, fontSize: 9.5)),
        ],
      ]),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? BrokaColors.neonBlue.withOpacity(0.18)
                  : BrokaColors.bgCard.withOpacity(0.5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: selected ? BrokaColors.neonBlue : BrokaColors.border,
                  width: selected ? 1.4 : 1),
            ),
            child: Text(label, style: TextStyle(
              color: selected ? BrokaColors.neonBlue : BrokaColors.textMid,
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            )),
          ),
        ),
      );
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({super.key, required this.product, this.onTap});
  final StoreTopProduct product;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                  [
                    if (product.price != null) 'KSh ${product.price!.toStringAsFixed(0)}',
                    '${product.views} views',
                    if (product.saves > 0) '${product.saves} saves',
                    if (product.interestedBuyers > 0)
                      '${product.interestedBuyers} interested',
                  ].join(' · '),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
            ])),
            if (onTap != null)
              const Icon(Icons.chevron_right_rounded, size: 18, color: BrokaColors.textMid),
          ]),
        ),
      );
}

class _AdviceRow extends StatelessWidget {
  const _AdviceRow({required this.card, required this.positive});
  final StoreAdvice card;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final accent = positive ? BrokaColors.success : BrokaColors.warning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(positive ? Icons.trending_up_rounded : Icons.priority_high_rounded,
            size: 16, color: accent),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(card.title, style: TextStyle(color: accent, fontSize: 12.5,
              fontWeight: FontWeight.w800, height: 1.3)),
          const SizedBox(height: 2),
          Text(card.detail, style: const TextStyle(color: BrokaColors.textMid,
              fontSize: 12, height: 1.45)),
        ])),
      ]),
    );
  }
}
