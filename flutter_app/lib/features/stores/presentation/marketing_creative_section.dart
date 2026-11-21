part of 'marketing_studio_screen.dart';

// ── Creative Studio ─────────────────────────────────────────────────────────

class _CreativeStudioTab extends StatefulWidget {
  const _CreativeStudioTab({
    super.key,
    required this.store,
    required this.repo,
    this.initialProductId,
    this.initialPlatform,
    this.initialObjective,
    this.initialFormat,
  });

  final Store store;
  final StoresRepository repo;
  final String? initialProductId;
  final String? initialPlatform;
  final String? initialObjective;
  final String? initialFormat;

  @override
  State<_CreativeStudioTab> createState() => _CreativeStudioTabState();
}

class _CreativeStudioTabState extends State<_CreativeStudioTab> {
  final _instructions = TextEditingController();
  final _cta = TextEditingController();
  List<StoreProduct> _products = const [];
  List<MarketingCampaign> _recent = const [];
  bool _productsLoading = true;
  bool _recentLoading = true;
  String? _productsError;
  String? _selectedProductId;
  CampaignPlatform _platform = CampaignPlatform.whatsapp;
  CampaignObjective _objective = CampaignObjective.product;
  String? _format;
  bool _busy = false;
  String? _error;
  bool _videoBusy = false;
  CampaignPlatform _videoPlatform = CampaignPlatform.tiktok;
  String _videoKind = 'script';

  @override
  void initState() {
    super.initState();
    final platform = CampaignPlatform.parse(widget.initialPlatform);
    if (platform != null) _platform = platform;
    if (widget.initialObjective != null) {
      _objective = CampaignObjective.parse(widget.initialObjective);
    }
    _format = widget.initialFormat;
    _selectedProductId = widget.initialProductId;
    _loadProducts();
    _loadRecent();
  }

  @override
  void dispose() {
    _instructions.dispose();
    _cta.dispose();
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
            _format = null;
          }
        case Failure(:final message):
          _productsError = message;
      }
    });
  }

  Future<void> _loadRecent() async {
    final result = await widget.repo.getCampaigns(widget.store.id, limit: 5);
    if (!mounted) return;
    setState(() {
      _recentLoading = false;
      if (result case Success(:final data)) {
        _recent = data.$1.where((c) => c.creatives.isNotEmpty).toList();
      }
    });
  }

  List<String> get _formats => switch (_platform) {
        CampaignPlatform.whatsapp => const ['message', 'status'],
        CampaignPlatform.instagram => const ['caption', 'story', 'carousel'],
        CampaignPlatform.tiktok => const ['script', 'video_plan'],
        CampaignPlatform.facebook => const ['post', 'story'],
        CampaignPlatform.x => const ['post'],
      };

  String? _validate() {
    if (_selectedProductId == null) {
      return 'Choose a product to promote. A post with no product can be made in the '
          'campaign builder from Overview.';
    }
    if (_objective == CampaignObjective.discount &&
        _instructions.text.trim().isEmpty) {
      return 'Describe the real discount (for example "10% off until Friday"). '
          "BROKA won't invent one.";
    }
    return null;
  }

  Future<void> _generate() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.repo.createCampaign(
      widget.store.id,
      objective: _objective.value,
      productIds: [_selectedProductId!],
      platforms: [_platform.value],
      instructions: _instructions.text,
      cta: _cta.text,
      creativeFormat: _format,
      generate: true,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Success(:final data):
        // The seller's selections are kept for a second creative, and the
        // campaign detail screen is where preview, edit and sharing live.
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CampaignDetailScreen(
                store: widget.store, repo: widget.repo, campaignId: data.id)));
        if (mounted) _loadRecent();
      case Failure(:final message):
        // Everything the seller typed stays exactly as it was.
        setState(() => _error = message);
    }
  }

  Future<void> _openVideo() async {
    setState(() => _videoBusy = true);
    try {
      await showVideoScriptSheet(
        context,
        repo: widget.repo,
        storeId: widget.store.id,
        initialPlatform: _videoPlatform.value,
        initialProductId: _selectedProductId,
        initialKind: _videoKind,
      );
    } finally {
      if (mounted) setState(() => _videoBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected =
        _products.where((p) => p.id == _selectedProductId).firstOrNull;
    return ListView(
      key: const Key('marketing-creative'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        _card(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Creative Studio',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 20,
                    height: 1.15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3)),
            const SizedBox(height: 3),
            const Text(
              'One product, one platform, one format. BROKA writes the caption, '
              'hashtags and a poster from your real listing - you publish it.',
              style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            _StudioStep(number: 1, title: 'Product'),
            if (_productsLoading)
              const Padding(
                  padding: EdgeInsets.all(14),
                  child: Center(
                      child: CircularProgressIndicator(
                          color: BrokaColors.gold, strokeWidth: 2.5)))
            else if (_productsError != null)
              _InlineError(message: _productsError!, onRetry: _loadProducts)
            else if (_products.isEmpty)
              const Text(
                'No live products yet. Add a product to your store first - that is what '
                'there is to promote.',
                style: TextStyle(
                    color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
              )
            else
              SizedBox(
                height: 100,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final product in _products)
                      _ProductTile(
                        key: Key('creative-product-${product.id}'),
                        product: product,
                        selected: product.id == _selectedProductId,
                        onTap: () => setState(() {
                          _selectedProductId = product.id;
                          _format = null;
                        }),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            _StudioStep(number: 2, title: 'Platform'),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final platform in CampaignPlatform.values)
                _Chip(
                  key: Key('creative-platform-${platform.value}'),
                  label: platform.label,
                  selected: _platform == platform,
                  onTap: () => setState(() {
                    _platform = platform;
                    if (_format != null && !_formats.contains(_format))
                      _format = null;
                  }),
                ),
            ]),
            const SizedBox(height: 14),
            _StudioStep(number: 3, title: 'Objective'),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final objective in CampaignObjective.values)
                _Chip(
                  key: Key('creative-objective-${objective.value}'),
                  label: objective.label,
                  selected: _objective == objective,
                  onTap: () => setState(() => _objective = objective),
                ),
            ]),
            const SizedBox(height: 4),
            Text(_objective.hint,
                style: const TextStyle(
                    color: BrokaColors.textLow, fontSize: 11.5)),
            const SizedBox(height: 14),
            _StudioStep(number: 4, title: 'Format'),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final format in _formats)
                _Chip(
                  key: Key('creative-format-$format'),
                  label: _creativeShapeLabel(format),
                  selected: _format == format,
                  onTap: () => setState(
                      () => _format = _format == format ? null : format),
                ),
            ]),
            const SizedBox(height: 4),
            const Text(
                "Leave it unset and BROKA uses the platform's natural shape.",
                style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5)),
            const SizedBox(height: 14),
            TextField(
              key: const Key('creative-instructions'),
              controller: _instructions,
              maxLength: 600,
              maxLines: 3,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _studioField(
                _objective == CampaignObjective.discount
                    ? 'The real discount (required)'
                    : 'Offer or instructions (optional)',
                Icons.edit_note_rounded,
                hint:
                    'e.g. Mention delivery to Kisumu; the discount is 10% off until Friday',
              ),
            ),
            TextField(
              key: const Key('creative-cta'),
              controller: _cta,
              maxLength: 160,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _studioField(
                  'Call to action (optional)', Icons.touch_app_outlined,
                  hint: 'e.g. Open the store link to order'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('creative-error'),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: BrokaColors.danger.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(11),
                  border:
                      Border.all(color: BrokaColors.danger.withOpacity(0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error!,
                        style: const TextStyle(
                            color: BrokaColors.danger,
                            fontSize: 12,
                            height: 1.4)),
                    const SizedBox(height: 3),
                    const Text(
                      'Nothing above was cleared - change one thing and try again.',
                      style: TextStyle(
                          color: BrokaColors.textMid,
                          fontSize: 11,
                          height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            _ChoiceSummary(
              product: selected?.listing.name,
              platform: _platform.label,
              format: _format == null
                  ? 'Platform default'
                  : _creativeShapeLabel(_format!),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('creative-generate'),
                onPressed: _busy ? null : _generate,
                icon: _busy
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(_busy
                    ? 'Writing the caption and drawing the poster...'
                    : 'Generate creative'),
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 8),
              const ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(4)),
                child: LinearProgressIndicator(
                  minHeight: 3,
                  backgroundColor: BrokaColors.border,
                  valueColor: AlwaysStoppedAnimation(BrokaColors.gold),
                ),
              ),
            ],
            const SizedBox(height: 7),
            Text(
              selected == null
                  ? 'BROKA will not add warranties, discounts or delivery promises you '
                      'have not given it.'
                  : 'Using ${selected.listing.name} and the price in your listing. '
                      'BROKA will not add claims you have not given it.',
              style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11, height: 1.4),
            ),
            // The full builder still exists: a whole-store campaign, tone,
            // language and a saved draft are not part of the one-product
            // flow above, and removing the way to them would take working
            // functionality away.
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('creative-more-options'),
                onPressed: () async {
                  final campaign = await Navigator.of(context)
                      .push<MarketingCampaign>(MaterialPageRoute(
                          builder: (_) => CampaignBuilderScreen(
                              store: widget.store, repo: widget.repo)));
                  if (!mounted) return;
                  if (campaign != null) {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CampaignDetailScreen(
                            store: widget.store,
                            repo: widget.repo,
                            campaignId: campaign.id)));
                  }
                  if (mounted) _loadRecent();
                },
                style:
                    TextButton.styleFrom(foregroundColor: BrokaColors.textMid),
                child: const Text('More options: whole store, tone, draft',
                    style: TextStyle(fontSize: 11.5)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        _sectionLabel('Video scripts'),
        _card(
          key: const Key('creative-video-card'),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.movie_creation_outlined,
                  size: 18, color: BrokaColors.textMid),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('A script to film yourself',
                      style: TextStyle(
                          color: BrokaColors.textHigh,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 4),
            const Text(
              'TikTok concepts, Reels scripts, Facebook video scripts and scene-by-scene '
              'storyboards. BROKA does not generate a video file.',
              style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 11.5, height: 1.4),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final platform in const [
                CampaignPlatform.tiktok,
                CampaignPlatform.instagram,
                CampaignPlatform.facebook,
              ])
                _Chip(
                  key: Key('video-platform-${platform.value}'),
                  label: platform.label,
                  selected: _videoPlatform == platform,
                  onTap: () => setState(() => _videoPlatform = platform),
                ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final kind in const {
                'concept': 'Concept',
                'script': 'Script',
                'storyboard': 'Storyboard',
                'voice_over': 'Voice-over',
              }.entries)
                _Chip(
                  key: Key('video-kind-${kind.key}'),
                  label: kind.value,
                  selected: _videoKind == kind.key,
                  onTap: () => setState(() => _videoKind = kind.key),
                ),
            ]),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('video-generate'),
              onPressed: _videoBusy ? null : _openVideo,
              icon: _videoBusy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: BrokaColors.textHigh))
                  : const Icon(Icons.description_outlined, size: 17),
              label: const Text('Write the script'),
              style: OutlinedButton.styleFrom(
                foregroundColor: BrokaColors.textHigh,
                side: const BorderSide(color: BrokaColors.border),
                minimumSize: const Size(0, 44),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        _sectionLabel('Recent creatives'),
        if (_recentLoading)
          const Padding(
              padding: EdgeInsets.all(18),
              child: Center(
                  child: CircularProgressIndicator(
                      color: BrokaColors.gold, strokeWidth: 2.5)))
        else if (_recent.isEmpty)
          _card(
            key: const Key('creative-recent-empty'),
            child: const Text(
              'Nothing made yet. Your generated posters and captions will appear here.',
              style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
            ),
          )
        else
          for (final campaign in _recent)
            _RecentCreative(
              key: Key('recent-creative-${campaign.id}'),
              campaign: campaign,
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => CampaignDetailScreen(
                        store: widget.store,
                        repo: widget.repo,
                        campaignId: campaign.id)));
                if (mounted) _loadRecent();
              },
            ),
      ],
    );
  }
}

/// A plain restatement of what the seller chose, so the generate button is
/// never a leap of faith. It reads only from the form above.
class _ChoiceSummary extends StatelessWidget {
  const _ChoiceSummary({
    required this.product,
    required this.platform,
    required this.format,
  });
  final String? product;
  final String platform;
  final String format;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          color: BrokaColors.bgMid.withOpacity(0.45),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Text(
          '${product ?? 'No product yet'}  ·  $platform  ·  $format',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: BrokaColors.textMid,
              fontSize: 11.5,
              fontWeight: FontWeight.w600),
        ),
      );
}

class _StudioStep extends StatelessWidget {
  const _StudioStep({required this.number, required this.title});
  final int number;
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _accent.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Text('$number',
                style: const TextStyle(
                    color: _accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 7),
          Text(title,
              style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
        ]),
      );
}

class _ProductTile extends StatelessWidget {
  const _ProductTile(
      {super.key,
      required this.product,
      required this.selected,
      required this.onTap});
  final StoreProduct product;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = product.listing.photos.isNotEmpty
        ? product.listing.photos.first.thumb
        : null;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected
            ? BrokaColors.gold.withOpacity(0.09)
            : BrokaColors.bgCard.withOpacity(0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(
              color: selected ? BrokaColors.gold : BrokaColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 104,
            height: 96,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                height: 48,
                width: double.infinity,
                child: image == null
                    ? Container(
                        color: BrokaColors.bgMid,
                        child: const Icon(Icons.image_not_supported_outlined,
                            color: BrokaColors.textLow, size: 18))
                    : BrokaImage(image, fit: BoxFit.cover),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(7, 4, 7, 4),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(product.listing.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: BrokaColors.textHigh,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600)),
                      Text(product.listing.priceFormatted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: BrokaColors.gold,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RecentCreative extends StatelessWidget {
  const _RecentCreative(
      {super.key, required this.campaign, required this.onTap});
  final MarketingCampaign campaign;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final creative = campaign.creatives.first;
    final image = creative.image?.thumb;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: BrokaColors.bgCard.withOpacity(0.6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: BrokaColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                    width: 46,
                    height: 46,
                    child: image == null
                        ? Container(
                            color: BrokaColors.bgMid,
                            child: const Icon(Icons.image_outlined,
                                color: BrokaColors.textLow, size: 18))
                        : BrokaImage(image, fit: BoxFit.cover)),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(campaign.titleOrObjective,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                        '${campaign.creatives.length} creative'
                        '${campaign.creatives.length == 1 ? '' : 's'} · '
                        '${campaign.platforms.map((p) => CampaignPlatform.parse(p)?.label ?? p).join(' · ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: BrokaColors.textMid, fontSize: 11)),
                  ])),
              const Icon(Icons.chevron_right_rounded,
                  color: BrokaColors.textMid),
            ]),
          ),
        ),
      ),
    );
  }
}
