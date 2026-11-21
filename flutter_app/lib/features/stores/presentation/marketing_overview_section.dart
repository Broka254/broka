part of 'marketing_studio_screen.dart';

// ── Overview ────────────────────────────────────────────────────────────────
//
// The landing area answers three questions in order: what can I do now, what
// has already happened, and what did I make before. Numbers are only the events
// the server recorded; nothing here estimates reach, spend or sales.

class _MarketingOverviewTab extends StatefulWidget {
  const _MarketingOverviewTab({
    required this.store,
    required this.repo,
    required this.onAskSidekick,
    required this.onCreateCreative,
    required this.onPlanAds,
    required this.onOpenCampaign,
    required this.onAction,
  });

  final Store store;
  final StoresRepository repo;
  final VoidCallback onAskSidekick;
  final VoidCallback onCreateCreative;
  final VoidCallback onPlanAds;
  final ValueChanged<String> onOpenCampaign;
  final ValueChanged<SidekickAction> onAction;

  @override
  State<_MarketingOverviewTab> createState() => _MarketingOverviewTabState();
}

class _MarketingOverviewTabState extends State<_MarketingOverviewTab> {
  List<MarketingCampaign> _campaigns = const [];
  int _total = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await widget.repo.getCampaigns(widget.store.id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          _campaigns = data.$1;
          _total = data.$2;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  Future<void> _showOlder() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await widget.repo
        .getCampaigns(widget.store.id, offset: _campaigns.length);
    if (!mounted) return;
    switch (result) {
      case Success(:final data):
        setState(() {
          _campaigns = [..._campaigns, ...data.$1];
          _total = data.$2;
        });
      case Failure(:final message):
        messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visits = _campaigns.fold<int>(0, (sum, c) => sum + c.events.visits);
    final shared = _campaigns.fold<int>(0, (sum, c) => sum + c.events.shares);
    final saved = _campaigns.fold<int>(0, (sum, c) => sum + c.events.downloads);

    return RefreshIndicator(
      color: BrokaColors.gold,
      onRefresh: _load,
      child: ListView(
        key: const Key('marketing-overview'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
        children: [
          Text('Grow ${widget.store.name}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 22,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4)),
          const SizedBox(height: 4),
          const Text(
            'Plan what to post, make it, then decide whether paid reach is worth it.',
            style: TextStyle(
                color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 14),
          _SidekickHero(onTap: widget.onAskSidekick),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _ToolTile(
                    key: const Key('overview-create-creative'),
                    icon: Icons.palette_outlined,
                    title: 'Creative Studio',
                    subtitle: 'Poster, caption and hashtags from one product',
                    onTap: widget.onCreateCreative,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ToolTile(
                    key: const Key('overview-plan-ads'),
                    icon: Icons.campaign_outlined,
                    title: 'Meta Ads',
                    subtitle: 'A KES checklist you finish in Ads Manager',
                    onTap: widget.onPlanAds,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionLabel('What BROKA has counted'),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_loading && _campaigns.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: BrokaColors.gold),
                      ),
                    ),
                  )
                else if (_error != null)
                  Column(
                    key: const Key('marketing-error'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_error!,
                          style: const TextStyle(
                              color: BrokaColors.textMid,
                              fontSize: 12.5,
                              height: 1.4)),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _load,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: BrokaColors.textHigh,
                          side: const BorderSide(color: BrokaColors.border),
                        ),
                        child: const Text('Try again'),
                      ),
                    ],
                  )
                else
                  Row(children: [
                    _StatTile(value: '$_total', label: 'Campaigns'),
                    _StatTile(
                        value: '$visits', label: 'Shop visits\nfrom links'),
                    _StatTile(
                        value: '${shared + saved}',
                        label: 'Posts shared\nor saved'),
                  ]),
                const SizedBox(height: 10),
                const Text(
                  'Only actions BROKA observed are counted. Impressions, reach and ad '
                  'spend are not measured, so they are not shown.',
                  style: TextStyle(
                      color: BrokaColors.textLow, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: _sectionLabel('Platform guides')),
            TextButton(
              onPressed: widget.onAskSidekick,
              style: TextButton.styleFrom(
                  foregroundColor: BrokaColors.textMid,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.only(bottom: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Which one?', style: TextStyle(fontSize: 11.5)),
            ),
          ]),
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final platform in CampaignPlatform.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      key: Key('overview-guide-${platform.value}'),
                      avatar: const Icon(Icons.menu_book_outlined,
                          size: 14, color: BrokaColors.textMid),
                      label: Text(platform.label,
                          style: const TextStyle(
                              color: BrokaColors.textMid, fontSize: 12)),
                      backgroundColor: BrokaColors.bgCard.withOpacity(0.6),
                      side: const BorderSide(color: BrokaColors.border),
                      onPressed: () => showPlatformGuideSheet(
                        context,
                        repo: widget.repo,
                        storeId: widget.store.id,
                        platform: platform.value,
                        onAction: widget.onAction,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: _sectionLabel('Your campaigns')),
            if (_total > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('$_total',
                    style: const TextStyle(
                        color: BrokaColors.textMid,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
          ]),
          if (_loading && _campaigns.isEmpty)
            const SizedBox.shrink()
          else if (_campaigns.isEmpty)
            _FirstCampaign(
              onStart: widget.onCreateCreative,
              onAsk: widget.onAskSidekick,
            )
          else ...[
            for (final campaign in _campaigns.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _CampaignCard(
                  campaign: campaign,
                  onTap: () => widget.onOpenCampaign(campaign.id),
                ),
              ),
            if (_total > _campaigns.length && _campaigns.length < 8)
              OutlinedButton(
                key: const Key('older-campaigns'),
                onPressed: _showOlder,
                style: OutlinedButton.styleFrom(
                  foregroundColor: BrokaColors.textHigh,
                  side: const BorderSide(color: BrokaColors.border),
                  minimumSize: const Size(0, 44),
                ),
                child: Text(
                    'Show older campaigns (${_total - _campaigns.length})'),
              ),
          ],
        ],
      ),
    );
  }
}

/// The one thing the Studio wants a seller to try first. The whole card is the
/// button; the inner button is only the visible affordance.
class _SidekickHero extends StatelessWidget {
  const _SidekickHero({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('overview-ask-sidekick'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  _accent.withOpacity(0.26),
                  BrokaColors.bgCard.withOpacity(0.85),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _accent.withOpacity(0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: _accent.withOpacity(0.20),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.auto_awesome_rounded,
                        color: _accent, size: 19),
                  ),
                  const SizedBox(width: 11),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Ask the AI Sidekick',
                            style: TextStyle(
                                color: BrokaColors.textHigh,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w800)),
                        SizedBox(height: 2),
                        Text('A plan built from your live products and prices',
                            style: TextStyle(
                                color: BrokaColors.textMid, fontSize: 11.5)),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_rounded,
                      color: BrokaColors.textMid, size: 18),
                ]),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  decoration: BoxDecoration(
                    color: BrokaColors.bg.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '"What should I post this week to sell more?"',
                    style: TextStyle(
                        color: BrokaColors.textMid,
                        fontSize: 12,
                        fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: BrokaColors.bgCard.withOpacity(0.62),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: BrokaColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _accent.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 17, color: _accent),
                ),
                const SizedBox(height: 9),
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 11, height: 1.3)),
              ],
            ),
          ),
        ),
      );
}

/// What a seller sees before their first campaign: the actual three steps,
/// not a decorative empty card.
class _FirstCampaign extends StatelessWidget {
  const _FirstCampaign({required this.onStart, required this.onAsk});
  final VoidCallback onStart;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) => _card(
        key: const Key('marketing-empty'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('No campaigns yet',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              'Your first post takes about a minute. It uses a product that is '
              'already live in your store.',
              style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            const _FirstStep(
                number: 1, text: 'Pick one live product and a platform.'),
            const _FirstStep(
                number: 2, text: 'BROKA writes the caption and poster.'),
            const _FirstStep(
                number: 3, text: 'Check it, then share it yourself.'),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('empty-start-creative'),
                  onPressed: onStart,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Create a post'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: onAsk,
                style: OutlinedButton.styleFrom(
                  foregroundColor: BrokaColors.textHigh,
                  side: const BorderSide(color: BrokaColors.border),
                  minimumSize: const Size(0, 44),
                ),
                child: const Text('Ask first'),
              ),
            ]),
          ],
        ),
      );
}

class _FirstStep extends StatelessWidget {
  const _FirstStep({required this.number, required this.text});
  final int number;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: BrokaColors.gold.withOpacity(0.14),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('$number',
                style: const TextStyle(
                    color: BrokaColors.gold,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text,
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 12, height: 1.35)),
            ),
          ),
        ]),
      );
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(children: [
          Text(value,
              style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 21,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 10.5, height: 1.25)),
        ]),
      );
}

class _CampaignCard extends StatelessWidget {
  const _CampaignCard({required this.campaign, required this.onTap});
  final MarketingCampaign campaign;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final platforms = campaign.platforms
        .map((p) => CampaignPlatform.parse(p)?.label ?? p)
        .join(' · ');
    return Material(
      color: BrokaColors.bgCard.withOpacity(0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: BrokaColors.border.withOpacity(0.8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('campaign-${campaign.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(campaign.titleOrObjective,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: BrokaColors.textHigh,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700))),
              const Icon(Icons.chevron_right_rounded,
                  color: BrokaColors.textMid),
            ]),
            const SizedBox(height: 4),
            Text(
                [platforms, _dateLabel(campaign.createdAt)]
                    .where((s) => s.isNotEmpty)
                    .join(' · '),
                style:
                    const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 4, children: [
              _CountChip(
                icon: Icons.visibility_outlined,
                label: '${campaign.events.visits}',
                tooltip: 'Store visits from this campaign',
              ),
              _CountChip(
                icon: Icons.ios_share_rounded,
                label: '${campaign.events.shares}',
                tooltip: 'Times you shared a creative',
              ),
              if (campaign.products.isNotEmpty)
                _CountChip(
                  icon: Icons.inventory_2_outlined,
                  label: '${campaign.products.length}',
                  tooltip: 'Products promoted',
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip(
      {required this.icon, required this.label, required this.tooltip});
  final IconData icon;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: BrokaColors.textMid),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  color: BrokaColors.textMid,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600)),
        ]),
      );
}
