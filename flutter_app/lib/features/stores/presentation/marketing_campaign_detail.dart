part of 'marketing_studio_screen.dart';

// ── Detail ──────────────────────────────────────────────────────────────────

class CampaignDetailScreen extends StatefulWidget {
  const CampaignDetailScreen(
      {super.key,
      required this.store,
      required this.repo,
      required this.campaignId,
      this.share = const DeviceCreativeShare()});
  final Store store;
  final StoresRepository repo;
  final String campaignId;

  /// How a poster or post leaves the phone. Injected in tests; on a device
  /// it is the OS share sheet (data/creative_share.dart).
  final CreativeShare share;

  @override
  State<CampaignDetailScreen> createState() => _CampaignDetailScreenState();
}

class _CampaignDetailScreenState extends State<CampaignDetailScreen> {
  MarketingCampaign? _campaign;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result =
        await widget.repo.getCampaign(widget.store.id, widget.campaignId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          _campaign = data;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  Future<void> _regenerate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Write this campaign again?',
            style: TextStyle(color: BrokaColors.textHigh)),
        content: const Text(
            'The campaign keeps its setup and products. Its current captions are '
            'replaced with new ones - copy anything you want to keep first.',
            style: TextStyle(color: BrokaColors.textMid, height: 1.45)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Rewrite')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final result = await widget.repo
        .regenerateCampaign(widget.store.id, widget.campaignId);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Success(:final data):
        setState(() => _campaign = data);
      case Failure(:final message):
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Delete this campaign?',
            style: TextStyle(color: BrokaColors.textHigh)),
        content: const Text(
            'Its drafts, creatives and tracked links stop working. Shop visits already '
            'counted stay in your store numbers.',
            style: TextStyle(color: BrokaColors.textMid, height: 1.45)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm-delete-campaign'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete',
                style: TextStyle(
                    color: BrokaColors.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final result =
        await widget.repo.deleteCampaign(widget.store.id, widget.campaignId);
    if (!mounted) return;
    switch (result) {
      case Success():
        Navigator.of(context).pop();
      case Failure(:final message):
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _editCreative(CampaignCreative creative) async {
    final edited = await showModalBottomSheet<
        ({
          String headline,
          String body,
          String cta,
          List<String> hashtags,
        })>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _CreativeEditor(creative: creative),
    );
    if (edited == null || !mounted) return;
    setState(() => _busy = true);
    final result = await widget.repo.updateCreative(
      widget.store.id,
      widget.campaignId,
      creative.id,
      headline: edited.headline,
      body: edited.body,
      cta: edited.cta,
      hashtags: edited.hashtags,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Success(:final data):
        setState(() => _campaign = data);
      case Failure(:final message):
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Records an observed action. `shared` is the seller taking the copy or
  /// opening the platform - something BROKA saw, never an impression.
  void _record(String kind, String platform) {
    // Fire and forget: a counter failure must not block copying.
    widget.repo.recordCampaignEvent(widget.store.id, widget.campaignId,
        kind: kind, platform: platform);
  }

  /// The rectangle the iPad share popover points at. Null elsewhere, and
  /// harmless there - phones ignore it.
  Rect? _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// A copy is not a share: BROKA did not see the post leave the phone, so
  /// nothing is counted. Only an actual share-sheet result is recorded.
  Future<void> _copyCaption(CampaignCreative creative) =>
      _copy(context, creative.caption, 'Caption');

  String _captionWithLink(CampaignCreative creative) {
    final link = _campaign?.linkFor(creative.platform) ?? '';
    return creative.shareText(link);
  }

  /// Saves or sends the campaign's rendered poster - the one file the
  /// studio actually produced. Recorded as `downloaded` only when the
  /// share sheet says it completed: a dismissed sheet saved nothing.
  Future<void> _saveImage(CampaignCreative creative) async {
    final image = creative.image?.large ??
        creative.image?.medium ??
        creative.image?.thumb;
    if (image == null) return;
    // The link travels with the poster so a creative sent on WhatsApp still
    // leads somewhere the campaign can count.
    final outcome = await widget.share.image(
      image,
      caption: _captionWithLink(creative),
      fileName: 'broka-${creative.platform}-${creative.id}.png',
      origin: _shareOrigin(),
    );
    if (!mounted) return;
    switch (outcome) {
      case CreativeShareOutcome.shared:
        _record('downloaded', creative.platform);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Image saved or sent')));
      case CreativeShareOutcome.dismissed:
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Nothing was saved.')));
      case CreativeShareOutcome.unconfirmed:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "The sheet closed without confirming a save, so it wasn't counted.")));
      case CreativeShareOutcome.failed:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "Couldn't get the image ready - copy the caption instead.")));
    }
  }

  /// Hands the written post (with its tracked link) to any app on the phone.
  Future<void> _sharePost(CampaignCreative creative) async {
    final outcome = await widget.share
        .text(_captionWithLink(creative), origin: _shareOrigin());
    if (!mounted) return;
    switch (outcome) {
      case CreativeShareOutcome.shared:
        _record('shared', creative.platform);
      case CreativeShareOutcome.dismissed:
        break;
      case CreativeShareOutcome.unconfirmed:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "The sheet closed without confirming it was sent, so it wasn't counted.")));
      case CreativeShareOutcome.failed:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "Couldn't open the share sheet - copy the caption instead.")));
    }
  }

  Future<void> _copyLink(MarketingCampaign campaign, String platform) async {
    final link = campaign.linkFor(platform);
    if (link.isEmpty) return;
    // Copying the link proves nothing about where it went; only a share
    // sheet result is recorded.
    await _copy(context, link, 'Campaign link');
  }

  Future<void> _openPlatform(
      CampaignCreative creative, MarketingCampaign campaign) async {
    final ok = await _openExternal(
        _composeUrl(creative.platform, _captionWithLink(creative)));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "Couldn't open that app on this phone - copy the caption instead.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final campaign = _campaign;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: BrokaColors.textHigh,
        title: const Text('Campaign',
            style: TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 17,
                fontWeight: FontWeight.w800)),
        actions: [
          if (campaign != null)
            IconButton(
              key: const Key('delete-campaign'),
              tooltip: 'Delete campaign',
              icon: const Icon(Icons.delete_outline_rounded,
                  color: BrokaColors.textMid),
              onPressed: _delete,
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: BrokaColors.gold))
          : campaign == null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.cloud_off_rounded,
                            color: BrokaColors.textMid, size: 36),
                        const SizedBox(height: 10),
                        Text(_error ?? "Couldn't load this campaign.",
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: BrokaColors.textMid)),
                        const SizedBox(height: 12),
                        OutlinedButton(
                            onPressed: _load, child: const Text('Try again')),
                      ])))
              : AbsorbPointer(
                  absorbing: _busy,
                  child: ListView(
                    key: const Key('campaign-detail-list'),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      _HeaderCard(
                          campaign: campaign,
                          busy: _busy,
                          onRegenerate: _regenerate),
                      const SizedBox(height: 20),
                      if (campaign.products.isNotEmpty) ...[
                        _sectionLabel('Promoting'),
                        for (final product in campaign.products)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _ProductLine(product: product),
                          ),
                        const SizedBox(height: 14),
                      ],
                      if (campaign.creatives.isEmpty)
                        _card(
                          key: const Key('campaign-no-creatives'),
                          child: Column(children: [
                            const Icon(Icons.edit_note_rounded,
                                color: BrokaColors.textMid, size: 32),
                            const SizedBox(height: 8),
                            const Text('Saved as a draft',
                                style: TextStyle(
                                    color: BrokaColors.textHigh,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            const Text(
                              'No posts written yet. Rewrite the campaign to generate them now - '
                              'its setup is kept.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: BrokaColors.textMid,
                                  fontSize: 12.5,
                                  height: 1.4),
                            ),
                          ]),
                        )
                      else ...[
                        _sectionLabel('Ready to share'),
                        for (final creative in campaign.creatives)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _CreativeCard(
                              creative: creative,
                              campaign: campaign,
                              onEdit: () => _editCreative(creative),
                              onCopyCaption: () => _copyCaption(creative),
                              onCopyLink: () =>
                                  _copyLink(campaign, creative.platform),
                              onOpenPlatform: () =>
                                  _openPlatform(creative, campaign),
                              onSaveImage: creative.image == null
                                  ? null
                                  : () => _saveImage(creative),
                              onSharePost: () => _sharePost(creative),
                            ),
                          ),
                      ],
                      if (campaign.plan.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        _sectionLabel('Suggested week'),
                        _card(
                          key: const Key('campaign-plan'),
                          child: Column(children: [
                            for (final item in campaign.plan)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                          width: 78,
                                          child: Text(item.day,
                                              style: const TextStyle(
                                                  color: BrokaColors.gold,
                                                  fontSize: 12.5,
                                                  fontWeight:
                                                      FontWeight.w700))),
                                      Expanded(
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                            Text(
                                                [item.platform, item.format]
                                                    .whereType<String>()
                                                    .where((s) => s.isNotEmpty)
                                                    .join(' · '),
                                                style: const TextStyle(
                                                    color: BrokaColors.textHigh,
                                                    fontSize: 12.5,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                            if ((item.product ?? '').isNotEmpty)
                                              Text(item.product!,
                                                  style: const TextStyle(
                                                      color:
                                                          BrokaColors.textMid,
                                                      fontSize: 12)),
                                            if ((item.note ?? '').isNotEmpty)
                                              Text(item.note!,
                                                  style: const TextStyle(
                                                      color:
                                                          BrokaColors.textMid,
                                                      fontSize: 12,
                                                      height: 1.35)),
                                          ])),
                                    ]),
                              ),
                          ]),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'A plan, not a schedule: BROKA does not post for you.',
                          style: TextStyle(
                              color: BrokaColors.textLow, fontSize: 11.5),
                        ),
                      ],
                      const SizedBox(height: 20),
                      _sectionLabel('What this campaign brought'),
                      _MeasuredCard(campaign: campaign),
                      const SizedBox(height: 20),
                      _sectionLabel('Campaign links'),
                      _card(
                        child: Column(children: [
                          const Text(
                            'Each platform has its own link. A shop visit that arrives with one '
                            'is counted for this campaign - no visitor identity is stored.',
                            style: TextStyle(
                                color: BrokaColors.textMid,
                                fontSize: 12.5,
                                height: 1.4),
                          ),
                          const SizedBox(height: 10),
                          for (final platform in campaign.platforms)
                            _LinkRow(
                              platform: platform,
                              link: campaign.linkFor(platform),
                              onCopy: () => _copyLink(campaign, platform),
                            ),
                        ]),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard(
      {required this.campaign, required this.busy, required this.onRegenerate});
  final MarketingCampaign campaign;
  final bool busy;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final objective = CampaignObjective.parse(campaign.objective).label;
    final platforms = campaign.platforms
        .map((p) => CampaignPlatform.parse(p)?.label ?? p)
        .join(' · ');
    return _card(
      key: const Key('campaign-header'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(campaign.titleOrObjective,
            style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                height: 1.25)),
        const SizedBox(height: 6),
        Text([objective, platforms].where((s) => s.isNotEmpty).join(' · '),
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
        const SizedBox(height: 4),
        Text(
            [
              CampaignLanguage.label(campaign.language),
              CampaignTone.parse(campaign.tone).label,
              _dateLabel(campaign.createdAt),
            ].where((s) => s.isNotEmpty).join(' · '),
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 11.5)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: BrokaColors.bgMid.withOpacity(0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(
                campaign.isAiGenerated
                    ? Icons.auto_awesome_rounded
                    : Icons.notes_rounded,
                size: 17,
                color: _accent),
            const SizedBox(width: 9),
            Expanded(
                child: Text(
              campaign.isAiGenerated
                  ? 'Written by ${campaign.generation['provider']} from your product details, '
                      'then checked for claims it cannot support.'
                  : (campaign.fallbackReason ??
                      'Written from your product details by BROKA\'s template writer'
                          '${campaign.generation['provider'] != null ? ', because ${campaign.generation['provider']} was unavailable' : ''}.'),
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 12, height: 1.4),
            )),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const Key('regenerate-campaign'),
            onPressed: busy ? null : onRegenerate,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Rewrite the posts'),
            style: OutlinedButton.styleFrom(
              foregroundColor: BrokaColors.textHigh,
              side: const BorderSide(color: BrokaColors.border),
              minimumSize: const Size(0, 44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ProductLine extends StatelessWidget {
  const _ProductLine({required this.product});
  final CampaignProduct product;

  @override
  Widget build(BuildContext context) {
    final image = product.image?.thumb;
    return Row(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: SizedBox(
            width: 42,
            height: 42,
            child: image == null
                ? Container(
                    color: BrokaColors.bgMid,
                    child: const Icon(Icons.image_not_supported_outlined,
                        color: BrokaColors.textLow, size: 17))
                : BrokaImage(image, fit: BoxFit.cover)),
      ),
      const SizedBox(width: 10),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(product.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        if (product.price != null)
          Text(
              product.priceUnit == null
                  ? 'KES ${product.price!.toStringAsFixed(0)}'
                  : 'KES ${product.price!.toStringAsFixed(0)} ${product.priceUnit}',
              style: const TextStyle(
                  color: BrokaColors.gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w700)),
      ])),
      if ((product.brand ?? '').isNotEmpty)
        Text(product.brand!,
            style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
    ]);
  }
}

class _CreativeCard extends StatelessWidget {
  const _CreativeCard({
    required this.creative,
    required this.campaign,
    required this.onEdit,
    required this.onCopyCaption,
    required this.onCopyLink,
    required this.onOpenPlatform,
    required this.onSaveImage,
    required this.onSharePost,
  });

  final CampaignCreative creative;
  final MarketingCampaign campaign;
  final VoidCallback onEdit;
  final VoidCallback onCopyCaption;
  final VoidCallback onCopyLink;
  final VoidCallback onOpenPlatform;

  /// Null when this creative has no rendered poster (only the first one
  /// does): a Save button that saves nothing would be a lie.
  final VoidCallback? onSaveImage;
  final VoidCallback onSharePost;

  @override
  Widget build(BuildContext context) {
    final image = creative.image?.medium ?? creative.image?.thumb;
    final ratio = creative.media['aspect_ratio'] as String?;
    final duration = (creative.media['duration_seconds'] as num?)?.toInt();
    final scenes = [
      for (final s in (creative.media['scenes'] as List? ?? const []))
        if (s is Map) s.cast<String, dynamic>(),
    ];
    return _card(
      key: Key('creative-${creative.id}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _accent.withOpacity(0.16),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(creative.formatLabel,
                style: const TextStyle(
                    color: _accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3)),
          ),
          const Spacer(),
          if (ratio != null || duration != null)
            Text(
                [
                  if (ratio != null) ratio,
                  if (duration != null) '${duration}s',
                ].join(' · '),
                style:
                    const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
          IconButton(
            key: Key('edit-creative-${creative.id}'),
            tooltip: 'Edit this text',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined,
                size: 18, color: BrokaColors.textMid),
            onPressed: onEdit,
          ),
        ]),
        if (image != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio:
                  ratio == '9:16' ? 9 / 16 : (ratio == '16:9' ? 16 / 9 : 1),
              child: BrokaImage(image, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 4),
          Text(
              'Poster built from your product photo - a starting point, not a finished design.',
              style: TextStyle(
                  color: BrokaColors.textLow, fontSize: 10.5, height: 1.3)),
        ],
        if (creative.headline.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          SelectableText(creative.headline,
              style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  height: 1.3)),
        ],
        if (creative.body.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(creative.body,
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 13, height: 1.5)),
        ],
        if (scenes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.movie_creation_outlined,
                size: 15, color: BrokaColors.textMid),
            const SizedBox(width: 6),
            Text('Shot list',
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          for (var i = 0; i < scenes.length; i++)
            _SceneRow(index: i, scene: scenes[i]),
          Text(
              'A script and shot list to film yourself - BROKA has not filmed, '
              'published or scheduled anything here.',
              style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 10.5, height: 1.3)),
        ],
        if (creative.hashtags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(creative.hashtags.map((t) => '#$t').join(' '),
              style: const TextStyle(color: _accent, fontSize: 12.5)),
        ],
        if (creative.cta.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.arrow_forward_rounded,
                size: 15, color: BrokaColors.gold),
            const SizedBox(width: 5),
            Expanded(
                child: Text(creative.cta,
                    style: const TextStyle(
                        color: BrokaColors.gold,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600))),
          ]),
        ],
        if (campaign.linkFor(creative.platform).isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(campaign.linkFor(creative.platform),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        ],
        const SizedBox(height: 6),
        Wrap(spacing: 4, runSpacing: 2, children: [
          if (onSaveImage != null)
            TextButton.icon(
              key: Key('save-image-${creative.id}'),
              onPressed: onSaveImage,
              icon: const Icon(Icons.download_rounded, size: 16),
              label: const Text('Save image'),
              style: TextButton.styleFrom(
                  foregroundColor: BrokaColors.gold,
                  visualDensity: VisualDensity.compact),
            ),
          TextButton.icon(
            key: Key('share-post-${creative.id}'),
            onPressed: onSharePost,
            icon: const Icon(Icons.ios_share_rounded, size: 16),
            label: const Text('Share post'),
            style: TextButton.styleFrom(
                foregroundColor: BrokaColors.textHigh,
                visualDensity: VisualDensity.compact),
          ),
          TextButton.icon(
            key: Key('copy-caption-${creative.id}'),
            onPressed: onCopyCaption,
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy caption'),
            style: TextButton.styleFrom(
                foregroundColor: BrokaColors.textHigh,
                visualDensity: VisualDensity.compact),
          ),
          TextButton.icon(
            key: Key('copy-link-${creative.id}'),
            onPressed: onCopyLink,
            icon: const Icon(Icons.link_rounded, size: 16),
            label: const Text('Copy link'),
            style: TextButton.styleFrom(
                foregroundColor: BrokaColors.textHigh,
                visualDensity: VisualDensity.compact),
          ),
          TextButton.icon(
            key: Key('open-platform-${creative.id}'),
            onPressed: onOpenPlatform,
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text('Open ${creative.platformLabel}'),
            style: TextButton.styleFrom(
                foregroundColor: _accent, visualDensity: VisualDensity.compact),
          ),
        ]),
      ]),
    );
  }
}

/// One shot from a video creative's storyboard: what to film, what to put
/// on screen and what to say over it. A plan for the seller's own camera.
class _SceneRow extends StatelessWidget {
  const _SceneRow({required this.index, required this.scene});
  final int index;
  final Map<String, dynamic> scene;

  @override
  Widget build(BuildContext context) {
    String text(String key) => (scene[key] as String? ?? '').trim();
    final seconds = (scene['seconds'] as num?)?.toInt();
    final shot = text('shot');
    final onScreen = text('on_screen_text');
    final voice = text('voice_over');
    return Container(
      key: Key('scene-$index'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid.withOpacity(0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Shot ${index + 1}',
              style: const TextStyle(
                  color: _accent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2)),
          const Spacer(),
          if (seconds != null)
            Text('${seconds}s',
                style:
                    const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
        ]),
        if (shot.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(shot,
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 12.5, height: 1.35)),
        ],
        if (onScreen.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text('On screen: $onScreen',
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 11.5, height: 1.35)),
        ],
        if (voice.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text('Voice-over: $voice',
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 11.5, height: 1.35)),
        ],
      ]),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow(
      {required this.platform, required this.link, required this.onCopy});
  final String platform;
  final String link;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final label = CampaignPlatform.parse(platform)?.label ?? platform;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(
            width: 82,
            child: Text(label,
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600))),
        Expanded(
            child: Text(link.isEmpty ? 'Link unavailable' : link,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: link.isEmpty
                        ? BrokaColors.textLow
                        : BrokaColors.textMid,
                    fontSize: 11.5))),
        IconButton(
          tooltip: 'Copy $label link',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy_rounded,
              size: 17, color: BrokaColors.textMid),
          onPressed: link.isEmpty ? null : onCopy,
        ),
      ]),
    );
  }
}

/// Only what BROKA observed. The "not measured" line is not decoration: a
/// seller needs to know this is not an ad report, and nothing here claims a
/// sale or an impression.
class _MeasuredCard extends StatelessWidget {
  const _MeasuredCard({required this.campaign});
  final MarketingCampaign campaign;

  @override
  Widget build(BuildContext context) {
    final events = campaign.events;
    Widget tile(IconData icon, String value, String label) => Expanded(
          child: Column(children: [
            Icon(icon, size: 18, color: BrokaColors.textMid),
            const SizedBox(height: 4),
            Text(value,
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 17,
                    fontWeight: FontWeight.w800)),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 10.5, height: 1.25)),
          ]),
        );

    return _card(
      key: const Key('campaign-measured'),
      child: Column(children: [
        Row(children: [
          tile(Icons.visibility_outlined, '${events.visits}',
              'Shop visits\nfrom links'),
          tile(Icons.shopping_bag_outlined, '${events.productViews}',
              'Product views\nfrom links'),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          tile(Icons.download_rounded, '${events.downloads}',
              'Images saved\nor sent'),
          tile(
              Icons.ios_share_rounded, '${events.shares}', 'Times you\nshared'),
        ]),
        // Store orders from the campaign's links: requests are buyers
        // asking, not sales, and none of these is a payment BROKA saw.
        if (events.orders case final orders?) ...[
          const SizedBox(height: 10),
          Row(key: const Key('campaign-orders'), children: [
            tile(Icons.receipt_long_outlined, '${orders.requests}',
                'Order requests\nfrom links'),
            tile(Icons.task_alt_rounded, '${orders.confirmed}',
                'Confirmed\nby buyers'),
            tile(Icons.inventory_2_outlined, '${orders.completed}',
                'Received\nby buyers'),
          ]),
        ],
        const SizedBox(height: 12),
        const Divider(height: 1, color: BrokaColors.border),
        const SizedBox(height: 10),
        const Text(
          'BROKA does not measure impressions, reach, advertising spend, sales or revenue '
          'for campaigns. Those numbers would be invented, so they are not shown.',
          style: TextStyle(
              color: BrokaColors.textMid, fontSize: 11.5, height: 1.4),
        ),
      ]),
    );
  }
}

class _CreativeEditor extends StatefulWidget {
  const _CreativeEditor({required this.creative});
  final CampaignCreative creative;

  @override
  State<_CreativeEditor> createState() => _CreativeEditorState();
}

class _CreativeEditorState extends State<_CreativeEditor> {
  late final _headline = TextEditingController(text: widget.creative.headline);
  late final _body = TextEditingController(text: widget.creative.body);
  late final _cta = TextEditingController(text: widget.creative.cta);
  late final _hashtags =
      TextEditingController(text: widget.creative.hashtags.join(', '));

  @override
  void dispose() {
    _headline.dispose();
    _body.dispose();
    _cta.dispose();
    _hashtags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              Text('Edit ${widget.creative.formatLabel}',
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text(
                  'This edits the campaign post. Your product listing is not changed.',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
              const SizedBox(height: 14),
              TextField(
                key: const Key('edit-headline'),
                controller: _headline,
                maxLength: 160,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: const InputDecoration(labelText: 'Headline'),
              ),
              TextField(
                key: const Key('edit-body'),
                controller: _body,
                maxLines: 8,
                minLines: 3,
                maxLength: 2200,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: const InputDecoration(labelText: 'Text'),
              ),
              TextField(
                key: const Key('edit-cta'),
                controller: _cta,
                maxLength: 160,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: const InputDecoration(labelText: 'Call to action'),
              ),
              TextField(
                key: const Key('edit-hashtags'),
                controller: _hashtags,
                style: const TextStyle(color: BrokaColors.textHigh),
                decoration: const InputDecoration(
                    labelText: 'Hashtags',
                    helperText: 'Separated by commas, without #'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('save-creative'),
                onPressed: () => Navigator.pop(context, (
                  headline: _headline.text.trim(),
                  body: _body.text.trim(),
                  cta: _cta.text.trim(),
                  hashtags: _hashtags.text
                      .split(',')
                      .map((t) => t.trim().replaceFirst(RegExp(r'^#+'), ''))
                      .where((t) => t.isNotEmpty)
                      .toList(),
                )),
                style: FilledButton.styleFrom(
                  backgroundColor: BrokaColors.gold,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(0, 48),
                ),
                child: const Text('Save changes'),
              ),
            ],
          ),
        ),
      );
}

// ── Copywriter ──────────────────────────────────────────────────────────────

/// Suggestions for a product's title, description or a caption. Nothing is
/// saved: the seller copies what they like and edits the listing themselves,
/// so AI output is never treated as permission to rewrite a listing.
Future<void> showCopywriterSheet(
  BuildContext context, {
  required StoresRepository repo,
  required String storeId,
  required String? listingId,
  required String productName,
  String currentTitle = '',
  String currentDescription = '',
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _CopywriterSheet(
        repo: repo,
        storeId: storeId,
        listingId: listingId,
        productName: productName,
        currentTitle: currentTitle,
        currentDescription: currentDescription,
      ),
    );

class _CopywriterSheet extends StatefulWidget {
  const _CopywriterSheet({
    required this.repo,
    required this.storeId,
    required this.listingId,
    required this.productName,
    required this.currentTitle,
    required this.currentDescription,
  });

  final StoresRepository repo;
  final String storeId;
  final String? listingId;
  final String productName;
  final String currentTitle;
  final String currentDescription;

  @override
  State<_CopywriterSheet> createState() => _CopywriterSheetState();
}

class _CopywriterSheetState extends State<_CopywriterSheet> {
  String _field = 'description';
  String _language = CampaignLanguage.en;
  bool _busy = false;
  CopySuggestions? _result;
  String? _error;

  String get _current => switch (_field) {
        'title' => widget.currentTitle,
        'caption' => widget.currentDescription,
        _ => widget.currentDescription,
      };

  Future<void> _suggest() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.repo.copySuggestions(
      widget.storeId,
      field: _field,
      listingId: widget.listingId,
      text: _current,
      language: _language,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Success(:final data):
          _result = data;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              Text('Improve copy - ${widget.productName}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text(
                'Suggestions only. Your listing stays as it is until you save a change '
                'in the normal editor.',
                style: TextStyle(
                    color: BrokaColors.textMid, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final field in const ['description', 'title', 'caption'])
                  _Chip(
                    key: Key('copy-field-$field'),
                    label: switch (field) {
                      'title' => 'Title',
                      'caption' => 'Social caption',
                      _ => 'Description',
                    },
                    selected: _field == field,
                    onTap: () => setState(() {
                      _field = field;
                      _result = null;
                    }),
                  ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                for (final language in CampaignLanguage.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _Chip(
                      label: CampaignLanguage.label(language),
                      selected: _language == language,
                      onTap: () => setState(() => _language = language),
                    ),
                  ),
              ]),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('suggest-copy'),
                onPressed: _busy ? null : _suggest,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.auto_fix_high_rounded, size: 18),
                label: Text(_busy ? 'Thinking...' : 'Suggest improvements'),
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 46),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: const TextStyle(
                        color: BrokaColors.danger, fontSize: 12.5)),
              ],
              if (_result != null) ...[
                const SizedBox(height: 14),
                if (!_result!.available)
                  Text(
                      _result!.message ??
                          'AI copy suggestions are not configured on the server.',
                      style: const TextStyle(
                          color: BrokaColors.textMid,
                          fontSize: 12.5,
                          height: 1.4))
                else if (_result!.items.isEmpty)
                  const Text(
                      'No suggestions came back. Try again, or edit it yourself.',
                      style:
                          TextStyle(color: BrokaColors.textMid, fontSize: 12.5))
                else
                  for (var i = 0; i < _result!.items.length; i++)
                    Container(
                      key: Key('copy-suggestion-$i'),
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: BrokaColors.bgCard.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: BrokaColors.border),
                      ),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(_result!.items[i].text,
                                style: const TextStyle(
                                    color: BrokaColors.textHigh,
                                    fontSize: 13,
                                    height: 1.45)),
                            if ((_result!.items[i].why ?? '').isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(_result!.items[i].why!,
                                  style: const TextStyle(
                                      color: BrokaColors.textLow,
                                      fontSize: 11.5,
                                      height: 1.35)),
                            ],
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () => _copy(context,
                                    _result!.items[i].text, 'Suggestion'),
                                icon: const Icon(Icons.copy_rounded, size: 16),
                                label: const Text('Copy'),
                              ),
                            ),
                          ]),
                    ),
                const SizedBox(height: 4),
                const Text(
                  'Check anything you use against the real product: the model is told not to '
                  'invent specifications, warranties or discounts, and it can still be wrong.',
                  style: TextStyle(
                      color: BrokaColors.textLow, fontSize: 11, height: 1.4),
                ),
              ],
            ],
          ),
        ),
      );
}
