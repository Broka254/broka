// Compare escrow providers: what each publishes about its fees, limits and
// protection, a calculator for what the buyer would pay, and filters.
//
// Behind the same gate as every other payment screen (payments_shown.dart):
// nothing leads here while the app hides payments, and ZenoActionRunner
// refuses the escrow_services destination until it is switched on.
//
// WHAT THIS SCREEN WILL NOT DO, because the server will not and the screen
// must not undo it:
//   * show a fee for a provider that publishes none (it shows what the
//     provider says: "Check live quotation in Lipasafe before paying");
//   * show a total when some charge could not be calculated (eConfirm's
//     payout reserve) - it shows the parts it has and says what is missing;
//   * say which provider is cheapest unless the server's ranking allows it
//     (every figure published, verified, current, comparable);
//   * show information from the phone's saved copy as if it were today's: it
//     says "saved copy, fetched <date>", and the server's own verification
//     dates and outdated warnings are on every card.
// The numbers are the server's, not computed here. An amount is typed in
// whole shillings and asked for; nothing is stored.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/result.dart';
import '../../main.dart';
import '../../widgets/chat_ambient_background.dart';
import 'provider_detail_screen.dart';
import 'provider_directory.dart';
import 'provider_directory_repository.dart';
import 'provider_widgets.dart';
import 'safe_payment.dart';

class ProviderComparisonScreen extends StatefulWidget {
  const ProviderComparisonScreen({
    super.key,
    this.repository,
    this.openUrl,
    this.onZeno,
    this.clock,
    this.debounce = const Duration(milliseconds: 450),
  });

  final ProviderDirectoryRepository? repository;

  /// Tests pass these; the app opens the browser and Zeno.
  final Future<bool> Function(Uri)? openUrl;
  final void Function(String prompt)? onZeno;
  final DateTime Function()? clock;
  final Duration debounce;

  @override
  State<ProviderComparisonScreen> createState() => _ProviderComparisonScreenState();
}

class _ProviderComparisonScreenState extends State<ProviderComparisonScreen> {
  final _amount = TextEditingController();
  Timer? _timer;
  ProviderDirectory? _directory;
  String? _error;
  bool _loading = true;
  int _request = 0;

  String? _payout; // phone | till
  String _sort = 'name';
  bool _noAccount = false;
  String? _kyc;
  bool _mpesa = false;
  bool _disputes = false;
  bool _refunds = false;
  String? _category;

  ProviderDirectoryRepository get _repo => widget.repository ?? providerDirectoryRepository;
  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _amount.dispose();
    super.dispose();
  }

  int? get _amountValue {
    final digits = _amount.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty || digits.length > 8) return null;
    final v = int.tryParse(digits);
    return v == null || v < 1 ? null : v;
  }

  DirectoryQuery get _query => DirectoryQuery(
        amount: _amountValue,
        payout: _payout,
        sort: _sort,
        noAccount: _noAccount,
        kyc: _kyc,
        paymentMethod: _mpesa ? 'mpesa' : null,
        category: _category,
        documentedDisputes: _disputes,
        documentedRefunds: _refunds,
      );

  /// Ask again. A newer request makes an older one's answer irrelevant, so a
  /// slow reply for "5,00" can never overwrite the answer for "5,000".
  Future<void> _load({bool forceRefresh = false}) async {
    final mine = ++_request;
    setState(() => _loading = true);
    final result = await _repo.fetch(query: _query, forceRefresh: forceRefresh);
    if (!mounted || mine != _request) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          _directory = data;
          _error = null;
        case Failure(:final message):
          // A failed calculation keeps the last list but says the figures are not current.
          _error = message;
      }
    });
  }

  void _changed() {
    _timer?.cancel();
    _timer = Timer(widget.debounce, _load);
    setState(() {});
  }

  void _zeno(String prompt) =>
      widget.onZeno != null ? widget.onZeno!(prompt) : openZenoEscrowGuide(context, prompt: prompt);

  @override
  Widget build(BuildContext context) {
    final dir = _directory;
    return ChatAmbientBackground(
      intensity: 0.85,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: BrokaColors.bg.withOpacity(0.55),
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text('COMPARE ESCROW SERVICES',
              style: TextStyle(fontSize: 13, letterSpacing: 1.5, fontWeight: FontWeight.w900, color: BrokaColors.textHigh)),
          centerTitle: false,
        ),
        body: RefreshIndicator(
          onRefresh: () => _load(forceRefresh: true),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              DisclosureBox(notice: dir?.notice ?? kRequiredNotice, points: dir?.points ?? kDisclosurePoints),
              const SizedBox(height: 14),
              if (dir != null && dir.fromCache) _SavedCopyBanner(directory: dir, now: _now()),
              if (_error != null) _ErrorBanner(message: _error!, hasList: dir != null),
              _Calculator(
                controller: _amount,
                payout: _payout,
                onChanged: _changed,
                onPayout: (v) {
                  _payout = v;
                  _changed();
                },
              ),
              const SizedBox(height: 12),
              _Filters(
                sort: _sort,
                noAccount: _noAccount,
                kyc: _kyc,
                mpesa: _mpesa,
                disputes: _disputes,
                refunds: _refunds,
                category: _category,
                onSort: (v) {
                  _sort = v;
                  _changed();
                },
                onNoAccount: (v) {
                  _noAccount = v;
                  _changed();
                },
                onKyc: (v) {
                  _kyc = v;
                  _changed();
                },
                onMpesa: (v) {
                  _mpesa = v;
                  _changed();
                },
                onDisputes: (v) {
                  _disputes = v;
                  _changed();
                },
                onRefunds: (v) {
                  _refunds = v;
                  _changed();
                },
                onCategory: (v) {
                  _category = v;
                  _changed();
                },
              ),
              const SizedBox(height: 14),
              if (dir?.ranking != null && _amountValue != null) _RankingBanner(ranking: dir!.ranking!),
              if (_loading && dir == null)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else if (dir == null)
                const _NoList()
              else if (dir.providers.isEmpty)
                const _EmptyResults()
              else
                for (final p in dir.providers)
                  ProviderCard(
                    key: ValueKey('card-${p.id}'),
                    provider: p,
                    ranking: dir.ranking,
                    onDetails: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ProviderDetailScreen(
                        provider: p,
                        notice: dir.notice,
                        points: dir.points,
                        openUrl: widget.openUrl,
                        onZeno: _zeno,
                      ),
                    )),
                    onVisit: () => openProviderSite(context, p, p.websiteUrl, openUrl: widget.openUrl),
                    onZeno: () => _zeno('Walk me through paying with ${p.name}'),
                  ),
              if (dir != null && dir.excluded.isNotEmpty) _Excluded(items: dir.excluded),
              for (final n in dir?.notices ?? const <ProviderNotice>[]) _NoticeCard(notice: n),
              const SizedBox(height: 8),
              if (dir != null && dir.estimateNote.isNotEmpty && _amountValue != null)
                Text(dir.estimateNote, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedCopyBanner extends StatelessWidget {
  const _SavedCopyBanner({required this.directory, required this.now});
  final ProviderDirectory directory;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final at = directory.fetchedAt.toLocal();
    final when = '${at.day}/${at.month}/${at.year} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final stale = directory.isStale(now);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: const Key('saved-copy-banner'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: (stale ? BrokaColors.danger : BrokaColors.warning).withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: (stale ? BrokaColors.danger : BrokaColors.warning).withOpacity(0.5)),
        ),
        child: Text(
          stale
              ? 'This is a saved copy from $when and may be out of date: a provider may have changed its fees or '
                  'been taken off the list since. Pull down to refresh, and confirm everything on the provider\'s own site.'
              : 'Saved copy from $when. Pull down to refresh.',
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12, height: 1.4),
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.hasList});
  final String message;
  final bool hasList;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          key: const Key('error-banner'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: BrokaColors.danger.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: BrokaColors.danger.withOpacity(0.5)),
          ),
          child: Text(
            hasList
                ? '$message The figures below may not match what you asked for. Pull down to try again.'
                : message,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12, height: 1.4),
          ),
        ),
      );
}

class _NoList extends StatelessWidget {
  const _NoList();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'The list of escrow services is not available right now, and BROKA does not keep one on your '
          'phone that could be out of date. Connect to the internet and pull down to try again. Never use an '
          'escrow link someone sends you in its place.',
          key: Key('no-list'),
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45),
        ),
      );
}

class _EmptyResults extends StatelessWidget {
  const _EmptyResults();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('No provider matches those filters. Some providers are left out because a fact is not '
            'documented: they are listed below with the reason.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45)),
      );
}

class _Calculator extends StatelessWidget {
  const _Calculator({required this.controller, required this.payout, required this.onChanged, required this.onPayout});
  final TextEditingController controller;
  final String? payout;
  final VoidCallback onChanged;
  final ValueChanged<String?> onPayout;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('What would I pay?', style: TextStyle(color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Enter what the seller should receive. Each provider\'s published fee is added, where it has one.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
        const SizedBox(height: 10),
        TextField(
          key: const Key('amount-field'),
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
          onChanged: (_) => onChanged(),
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16),
          decoration: const InputDecoration(
            labelText: 'Seller should receive (KSh)',
            hintText: '5000',
            prefixText: 'KSh ',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        const Text('Where will the seller be paid? (some providers charge differently)',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          ChoiceChip(
            key: const Key('payout-phone'),
            label: const Text('M-Pesa phone number'),
            selected: payout == 'phone',
            onSelected: (on) => onPayout(on ? 'phone' : null),
          ),
          ChoiceChip(
            key: const Key('payout-till'),
            label: const Text('M-Pesa till'),
            selected: payout == 'till',
            onSelected: (on) => onPayout(on ? 'till' : null),
          ),
        ]),
      ]),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.sort, required this.noAccount, required this.kyc, required this.mpesa, required this.disputes,
    required this.refunds, required this.category, required this.onSort, required this.onNoAccount,
    required this.onKyc, required this.onMpesa, required this.onDisputes, required this.onRefunds, required this.onCategory,
  });

  final String sort;
  final bool noAccount;
  final String? kyc;
  final bool mpesa;
  final bool disputes;
  final bool refunds;
  final String? category;
  final ValueChanged<String> onSort;
  final ValueChanged<bool> onNoAccount;
  final ValueChanged<String?> onKyc;
  final ValueChanged<bool> onMpesa;
  final ValueChanged<bool> onDisputes;
  final ValueChanged<bool> onRefunds;
  final ValueChanged<String?> onCategory;

  static const _categories = {
    'goods': 'Goods', 'services': 'Services', 'vehicles': 'Vehicles', 'property': 'Property',
    'digital': 'Digital', 'freelance': 'Freelance',
  };

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Sort and filter', style: TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 4, children: [
        ChoiceChip(key: const Key('sort-name'), label: const Text('A to Z'), selected: sort == 'name', onSelected: (_) => onSort('name')),
        ChoiceChip(key: const Key('sort-fee'), label: const Text('Lowest known fee'), selected: sort == 'lowest_fee', onSelected: (_) => onSort('lowest_fee')),
        ChoiceChip(key: const Key('sort-limit'), label: const Text('Highest limit'), selected: sort == 'highest_limit', onSelected: (_) => onSort('highest_limit')),
      ]),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 4, children: [
        FilterChip(key: const Key('filter-no-account'), label: const Text('No account needed'), selected: noAccount, onSelected: onNoAccount),
        FilterChip(key: const Key('filter-mpesa'), label: const Text('M-Pesa'), selected: mpesa, onSelected: onMpesa),
        FilterChip(key: const Key('filter-kyc-no'), label: const Text('No ID check'), selected: kyc == 'not_required', onSelected: (on) => onKyc(on ? 'not_required' : null)),
        FilterChip(key: const Key('filter-kyc-yes'), label: const Text('ID check required'), selected: kyc == 'required', onSelected: (on) => onKyc(on ? 'required' : null)),
        FilterChip(key: const Key('filter-disputes'), label: const Text('Dispute process documented'), selected: disputes, onSelected: onDisputes),
        FilterChip(key: const Key('filter-refunds'), label: const Text('Refund rules documented'), selected: refunds, onSelected: onRefunds),
        for (final e in _categories.entries)
          FilterChip(
            key: Key('filter-category-${e.key}'),
            label: Text(e.value),
            selected: category == e.key,
            onSelected: (on) => onCategory(on ? e.key : null),
          ),
      ]),
    ]);
  }
}

class _RankingBanner extends StatelessWidget {
  const _RankingBanner({required this.ranking});
  final Ranking ranking;

  @override
  Widget build(BuildContext context) {
    // The server says whether a "lowest fee" statement is allowed; either way
    // its sentence is shown as written - this screen never makes one up.
    final allowed = ranking.claimAllowed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: Key(allowed ? 'ranking-claim' : 'ranking-withheld'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: (allowed ? BrokaColors.success : BrokaColors.warning).withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: (allowed ? BrokaColors.success : BrokaColors.warning).withOpacity(0.45)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(allowed ? Icons.leaderboard_rounded : Icons.info_outline_rounded, size: 18,
              color: allowed ? BrokaColors.success : BrokaColors.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(ranking.headline, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, height: 1.4))),
        ]),
      ),
    );
  }
}

class _Excluded extends StatelessWidget {
  const _Excluded({required this.items});
  final List<Excluded> items;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Not shown for these filters', style: TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          for (final e in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text('${e.name}: ${e.reason}', style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
            ),
        ]),
      );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice});
  final ProviderNotice notice;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: BrokaColors.danger.withOpacity(0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: BrokaColors.danger.withOpacity(0.4)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.block_rounded, size: 16, color: BrokaColors.danger),
            const SizedBox(width: 8),
            Expanded(child: Text(notice.message, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, height: 1.4))),
          ]),
        ),
      );
}

/// One provider: what it publishes, at a glance.
class ProviderCard extends StatelessWidget {
  const ProviderCard({
    super.key,
    required this.provider,
    required this.onDetails,
    required this.onVisit,
    required this.onZeno,
    this.ranking,
  });

  final EscrowListing provider;
  final Ranking? ranking;
  final VoidCallback onDetails;
  final VoidCallback onVisit;
  final VoidCallback onZeno;

  @override
  Widget build(BuildContext context) {
    final p = provider;
    final e = p.estimate;
    final why = ranking?.notRanked[p.id];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ProviderLogo(name: p.name),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w900)),
              Text(p.site, style: const TextStyle(color: BrokaColors.neonBlue, fontSize: 11.5)),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        Text(p.reviewLabel, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        FreshnessChip(freshness: p.pricingFreshness, prefix: 'Pricing: '),
        for (final c in p.notToBeConfusedWith) WarningLine(c.text),
        const SizedBox(height: 8),
        _Line('Fees', p.summaries['fees'] ?? p.feeSummary),
        if (e != null) _EstimateBox(estimate: e, whyNotRanked: why),
        _Line('Limits', p.summaries['limits']),
        _Line('Payment', p.summaries['payment_methods']),
        _Line('Account and ID checks', p.summaries['requirements']),
        _Line('Release', p.summaries['release']),
        _Line('Disputes', p.summaries['disputes']),
        for (final w in p.warnings) WarningLine(w),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton(
              key: Key('details-${p.id}'),
              onPressed: onDetails,
              style: FilledButton.styleFrom(backgroundColor: BrokaColors.neonPurple, foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('View full details', overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              key: Key('visit-${p.id}'),
              onPressed: onVisit,
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Official website', overflow: TextOverflow.ellipsis),
              style: OutlinedButton.styleFrom(foregroundColor: BrokaColors.textHigh,
                  side: BorderSide(color: BrokaColors.neonBlue.withOpacity(0.6)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
          ),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onZeno,
            icon: const Icon(Icons.auto_awesome_rounded, size: 15),
            label: Text('Ask Zeno about ${p.name}'),
          ),
        ),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final known = value != null && value!.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(TextSpan(children: [
        TextSpan(text: '${label.toUpperCase()}  ',
            style: const TextStyle(color: BrokaColors.neonGreen, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        TextSpan(text: known ? value : 'Not documented',
            style: TextStyle(color: known ? BrokaColors.textMid : BrokaColors.textLow, fontSize: 12.5, height: 1.4,
                fontStyle: known ? FontStyle.normal : FontStyle.italic)),
      ])),
    );
  }
}

/// The calculator's answer for one provider, exactly as the server gave it.
class _EstimateBox extends StatelessWidget {
  const _EstimateBox({required this.estimate, this.whyNotRanked});
  final FeeEstimate estimate;
  final String? whyNotRanked;

  @override
  Widget build(BuildContext context) {
    final e = estimate;
    Widget row(String label, String value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          // Both sides are the server's strings, so neither may be assumed short:
          // a plain Text for the value took its full width and, with "6.32% of
          // what the seller receives" beside the label, overflowed a 304px card
          // by 117px - on the very box that shows what a person will pay. The
          // label keeps the larger share; the value wraps, right-aligned.
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12))),
            const SizedBox(width: 8),
            Flexible(flex: 4, child: Text(value, textAlign: TextAlign.right,
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: bold ? FontWeight.w900 : FontWeight.w600))),
          ]),
        );
    final rows = <Widget>[];
    if (e.status == 'estimated' || e.status == 'partial') {
      rows.add(row('Seller receives', formatKes(e.sellerReceives)));
      rows.add(row('Commission', e.commission == null ? 'Not available' : formatKes(e.commission!)));
      rows.add(row('Fixed charges', e.fixedCharges == null ? 'None published' : formatKes(e.fixedCharges!)));
      rows.add(row('M-Pesa / payout charges',
          e.otherCharges == null ? 'Not available' : (e.otherCharges == 0 ? 'KSh 0' : formatKes(e.otherCharges!))));
      if (e.otherNote.isNotEmpty) rows.add(Text(e.otherNote, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)));
      rows.add(const Divider(height: 14));
      rows.add(row('Total buyer payment', e.hasTotal ? formatKes(e.totalBuyerPayment!) : 'Not available', bold: true));
      if (e.effectivePercent != null) rows.add(row('Effective fee', '${e.effectivePercent!.toStringAsFixed(2)}% of what the seller receives'));
      if (e.includesEstimatedCharges) {
        rows.add(const Text('Includes charges the provider publishes only as an estimate.',
            style: TextStyle(color: BrokaColors.warning, fontSize: 11)));
      }
    }
    return Container(
      key: Key('estimate-${e.status}'),
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: BrokaColors.bg.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(e.hasTotal ? 'ESTIMATE' : 'NO TOTAL SHOWN',
            style: TextStyle(color: e.hasTotal ? BrokaColors.neonGreen : BrokaColors.warning, fontSize: 10.5,
                fontWeight: FontWeight.w900, letterSpacing: 0.6)),
        const SizedBox(height: 4),
        ...rows,
        const SizedBox(height: 4),
        Text(e.message, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4)),
        if (whyNotRanked != null && whyNotRanked!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Not in the ranking: $whyNotRanked',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11, fontStyle: FontStyle.italic)),
          ),
      ]),
    );
  }
}
