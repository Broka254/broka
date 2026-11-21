part of 'marketing_studio_screen.dart';

// ── Ads Guidance ────────────────────────────────────────────────────────────
//
// A plan, not a campaign. The seller's inputs stay separate from BROKA's
// recommendations and from the checklist they complete in Meta's own tool.
// Money is only ever the amount the seller typed: there is no inferred budget,
// and no figure here is a prediction of results.

const _adsObjectives = {
  'awareness': 'Awareness',
  'traffic': 'Traffic',
  'engagement': 'Engagement',
  'leads': 'Leads',
  'sales': 'Sales',
};

class _AdsGuidanceTab extends StatefulWidget {
  const _AdsGuidanceTab({
    super.key,
    required this.store,
    required this.repo,
    this.initialProductId,
  });
  final Store store;
  final StoresRepository repo;
  final String? initialProductId;

  @override
  State<_AdsGuidanceTab> createState() => _AdsGuidanceTabState();
}

class _AdsGuidanceTabState extends State<_AdsGuidanceTab> {
  final _budget = TextEditingController();
  final _audience = TextEditingController();
  final _location = TextEditingController();
  final _scroll = ScrollController();
  final _resultsKey = GlobalKey();
  List<StoreProduct> _products = const [];
  bool _productsLoading = true;
  String? _productsError;
  String? _selectedProductId;
  String _objective = 'traffic';
  bool _busy = false;
  String? _error;
  AdsPlan? _plan;

  @override
  void initState() {
    super.initState();
    _selectedProductId = widget.initialProductId;
    _loadProducts();
  }

  @override
  void dispose() {
    _budget.dispose();
    _audience.dispose();
    _location.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() {
      _productsLoading = true;
      _productsError = null;
    });
    final result = await widget.repo.getOwnerProducts(widget.store.id,
        state: StoreProductState.live, limit: 100);
    if (!mounted) return;
    setState(() {
      _productsLoading = false;
      switch (result) {
        case Success(:final data):
          _products = data.items;
          if (_selectedProductId == null && _products.isNotEmpty) {
            _selectedProductId = _products.first.id;
          }
        case Failure(:final message):
          _productsError = message;
      }
    });
  }

  Future<void> _buildPlan() async {
    final rawBudget = _budget.text.trim();
    final parsed = rawBudget.isEmpty ? null : int.tryParse(rawBudget);
    if (rawBudget.isNotEmpty && (parsed == null || parsed < 1)) {
      setState(() => _error =
          'Enter a daily budget greater than zero in KES, or leave it empty '
              'and set it in Ads Manager.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.repo.getAdsPlan(
      widget.store.id,
      productId: _selectedProductId,
      objective: _objective,
      budgetKes: parsed,
      audience: _audience.text,
      location: _location.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Success(:final data):
          _plan = data;
          // Bring the plan into view: the seller has just asked for it, and the
          // inputs they came from are above the fold.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final target = _resultsKey.currentContext;
            if (target == null) return;
            Scrollable.ensureVisible(target,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOut,
                alignment: 0.02);
          });
        case Failure(:final message):
          _error = message;
      }
    });
  }

  Future<void> _copyPlan(AdsPlan plan) async {
    final budget = plan.budget.specified
        ? '${plan.budget.dailyLabel} a day for ${plan.budget.trialDays} days '
            '(${plan.budget.totalLabel} in total) - your chosen budget, not a '
            'prediction of results.'
        : 'No daily budget chosen yet - you set it in Meta Ads Manager.';
    final text = [
      'Meta ads plan for ${plan.productName ?? widget.store.name}',
      'Objective: ${plan.objectiveLabel}',
      'Audience: ${plan.audience}',
      'Location: ${plan.location}',
      'Budget: $budget',
      if (!plan.tracking.websitePurchasesMeasured)
        'Purchase tracking: not set up. Meta cannot confirm which clicks became '
            'orders or payments here.',
      '',
      for (final stage in plan.stages) ...[
        stage.title,
        if (stage.summary.isNotEmpty) stage.summary,
        for (final step in stage.steps) '  - $step',
        '',
      ],
      'BROKA has not created or published this campaign.',
    ].join('\n');
    await _copy(context, text, 'Ad plan');
  }

  Future<void> _openManager(String url) async {
    final ok = await _openExternal(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't open Meta Ads Manager on this device.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    return ListView(
      key: const Key('marketing-ads'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
      children: [
        const Text('Plan a Meta ad',
            style: TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 22,
                height: 1.15,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4)),
        const SizedBox(height: 4),
        const Text(
          'BROKA prepares the decisions and wording. You create, pay for and '
          'publish the campaign inside Meta Ads Manager.',
          style: TextStyle(
              color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
        ),
        const SizedBox(height: 14),

        // 1. Seller inputs - only things only the seller can decide.
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Your choices',
                  style: TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              const Text('Everything here is optional except the product.',
                  style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5)),
              const SizedBox(height: 12),
              const _FieldLabel('1. What are you advertising?'),
              if (_productsLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                      child: SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                              color: BrokaColors.gold, strokeWidth: 2.5))),
                )
              else if (_productsError != null)
                _InlineError(message: _productsError!, onRetry: _loadProducts)
              else if (_products.isEmpty)
                const Text(
                    'Add a live product first; an ad needs something real to show.',
                    style:
                        TextStyle(color: BrokaColors.textMid, fontSize: 12.5))
              else
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final product in _products)
                        Padding(
                          padding: const EdgeInsets.only(right: 7),
                          child: _Chip(
                            key: Key('ads-product-${product.id}'),
                            label: product.listing.name,
                            selected: product.id == _selectedProductId,
                            onTap: () =>
                                setState(() => _selectedProductId = product.id),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              const _FieldLabel('2. What should the ad do?'),
              Wrap(spacing: 7, runSpacing: 7, children: [
                for (final entry in _adsObjectives.entries)
                  _Chip(
                    key: Key('ads-objective-${entry.key}'),
                    label: entry.value,
                    selected: _objective == entry.key,
                    onTap: () => setState(() => _objective = entry.key),
                  ),
              ]),
              if (_objective == 'sales') ...[
                const SizedBox(height: 7),
                const _WarnNote(
                  'Sales needs purchase tracking to optimise. BROKA’s storefront '
                  'does not send Meta purchase events today, so Meta cannot confirm '
                  'which clicks became orders.',
                ),
              ],
              const SizedBox(height: 14),
              const _FieldLabel('3. Daily budget and audience'),
              TextField(
                key: const Key('ads-budget'),
                controller: _budget,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: _studioField(
                    'Daily budget in KES (optional)', Icons.payments_outlined,
                    hint: 'Leave empty if you have not decided'),
              ),
              const SizedBox(height: 4),
              const Text(
                'BROKA does not estimate a budget from your product price. If you '
                'leave this empty, you choose the amount in Ads Manager.',
                style: TextStyle(
                    color: BrokaColors.textLow, fontSize: 11, height: 1.4),
              ),
              TextField(
                key: const Key('ads-audience'),
                controller: _audience,
                maxLength: 160,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: _studioField(
                    'Audience (optional)', Icons.groups_outlined,
                    hint: 'e.g. Parents in Kisumu'),
              ),
              TextField(
                key: const Key('ads-location'),
                controller: _location,
                maxLength: 120,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: _studioField(
                    'Location (optional)', Icons.place_outlined,
                    hint: 'e.g. Kisumu and Siaya'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Container(
                  key: const Key('ads-error'),
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: BrokaColors.danger.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(11),
                    border:
                        Border.all(color: BrokaColors.danger.withOpacity(0.35)),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(
                          color: BrokaColors.danger,
                          fontSize: 12,
                          height: 1.4)),
                ),
              ],
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const Key('ads-build-plan'),
                onPressed: _busy ? null : _buildPlan,
                icon: _busy
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.list_alt_rounded, size: 18),
                label:
                    Text(_busy ? 'Building your plan...' : 'Build my ad plan'),
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ],
          ),
        ),
        if (plan != null) ...[
          const SizedBox(height: 16),
          KeyedSubtree(
            key: _resultsKey,
            child: _sectionLabel('BROKA’s recommendation'),
          ),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _accent.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.insights_rounded,
                        size: 17, color: _accent),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      plan.productName ?? widget.store.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: BrokaColors.textHigh,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  _PlanFact(label: 'Objective', value: plan.objectiveLabel),
                  _PlanFact(label: 'Audience', value: plan.audience),
                  _PlanFact(label: 'Location', value: plan.location),
                ]),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _card(
            key: const Key('ads-budget-summary'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Budget',
                    style: TextStyle(
                        color: BrokaColors.textMid,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4)),
                const SizedBox(height: 4),
                if (plan.budget.specified) ...[
                  Text(
                    '${plan.budget.dailyLabel} a day',
                    style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 19,
                        fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${plan.budget.totalLabel} over ${plan.budget.trialDays} days',
                    key: const Key('ads-budget-total'),
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12),
                  ),
                ] else
                  Container(
                    key: const Key('ads-budget-unset'),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: BrokaColors.gold.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(11),
                      border:
                          Border.all(color: BrokaColors.gold.withOpacity(0.3)),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Not selected yet',
                            style: TextStyle(
                                color: BrokaColors.gold,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text(
                          'Choose a daily amount you are comfortable spending, '
                          'then set it in Ads Manager.',
                          style: TextStyle(
                              color: BrokaColors.textMid,
                              fontSize: 11.5,
                              height: 1.4),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Text(plan.budget.note,
                    style: const TextStyle(
                        color: BrokaColors.textLow, fontSize: 11, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _TrackingCard(tracking: plan.tracking),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('ads-open-manager'),
            onPressed: () => _openManager(plan.managerUrl),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Open Meta Ads Manager'),
            style: FilledButton.styleFrom(
              backgroundColor: BrokaColors.gold,
              foregroundColor: BrokaColors.bg,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 8),
          _card(
            key: const Key('ads-disclaimer'),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.info_outline_rounded,
                    size: 17, color: BrokaColors.gold),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(plan.disclaimer,
                        style: const TextStyle(
                            color: BrokaColors.textMid,
                            fontSize: 11.5,
                            height: 1.4))),
              ]),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('ads-copy-plan'),
                  onPressed: () => _copyPlan(plan),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy plan'),
                  style: TextButton.styleFrom(
                      foregroundColor: BrokaColors.textMid),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 18),
          _sectionLabel('Your checklist'),
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 8),
            child: Text(
              'Eight stages, in the order Meta asks for them. Tick each one off '
              'inside Ads Manager.',
              style: TextStyle(
                  color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
            ),
          ),
          for (final stage in plan.stages)
            _AdsStageCard(key: Key('ads-stage-${stage.key}'), stage: stage),
        ],
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(text,
            style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 12.5,
                fontWeight: FontWeight.w700)),
      );
}

class _WarnNote extends StatelessWidget {
  const _WarnNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: BrokaColors.gold.withOpacity(0.09),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.28)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded,
                size: 14, color: BrokaColors.gold),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 11, height: 1.4)),
          ),
        ]),
      );
}

/// What Meta can measure here, stated plainly because it changes which
/// objective makes sense. No pixel, no Conversions API, no verified purchases.
class _TrackingCard extends StatelessWidget {
  const _TrackingCard({required this.tracking});
  final AdsTracking tracking;

  @override
  Widget build(BuildContext context) => _card(
        key: const Key('ads-tracking'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.troubleshoot_rounded,
                  size: 17, color: BrokaColors.textMid),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Purchase tracking is not set up',
                    style: TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 5),
            Text(
              tracking.summary.isEmpty
                  ? 'BROKA does not send purchase events to Meta, so Meta cannot '
                      'confirm which clicks became orders.'
                  : tracking.summary,
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 11.5, height: 1.4),
            ),
            if (tracking.steps.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final step in tracking.steps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 5),
                          child: Icon(Icons.circle,
                              size: 4, color: BrokaColors.textLow),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(step,
                              style: const TextStyle(
                                  color: BrokaColors.textMid,
                                  fontSize: 11,
                                  height: 1.4)),
                        ),
                      ]),
                ),
            ],
          ],
        ),
      );
}

class _PlanFact extends StatelessWidget {
  const _PlanFact({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  color: BrokaColors.textLow,
                  fontSize: 9,
                  letterSpacing: 0.7,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 11.5,
                  height: 1.3,
                  fontWeight: FontWeight.w600)),
        ]),
      );
}

class _AdsStageCard extends StatelessWidget {
  const _AdsStageCard({super.key, required this.stage});
  final AdsStage stage;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _card(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(stage.title,
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            if (stage.summary.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(stage.summary,
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
            ],
            if (stage.suggestion.isNotEmpty) ...[
              const SizedBox(height: 7),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: BrokaColors.gold.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text('BROKA suggests: ${stage.suggestion}',
                    style: const TextStyle(
                        color: BrokaColors.gold,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
            ],
            if (stage.steps.isNotEmpty) ...[
              const SizedBox(height: 9),
              for (final step in stage.steps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Icon(Icons.check_box_outline_blank_rounded,
                              size: 11, color: BrokaColors.textLow),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                            child: Text(step,
                                style: const TextStyle(
                                    color: BrokaColors.textMid,
                                    fontSize: 11.5,
                                    height: 1.4))),
                      ]),
                ),
            ],
          ]),
        ),
      );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(children: [
        Text(message,
            style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
        const SizedBox(height: 6),
        OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
      ]);
}

InputDecoration _studioField(String label, IconData icon, {String? hint}) =>
    InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 12),
      labelStyle: const TextStyle(color: BrokaColors.textMid),
      prefixIcon: Icon(icon, color: BrokaColors.textMid, size: 18),
      filled: true,
      fillColor: BrokaColors.bgCard.withOpacity(0.5),
      counterStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 10),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: BrokaColors.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: const BorderSide(color: BrokaColors.border)),
    );
