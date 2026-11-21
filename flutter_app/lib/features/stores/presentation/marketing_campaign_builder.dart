part of 'marketing_studio_screen.dart';

// ── Builder ─────────────────────────────────────────────────────────────────

class CampaignBuilderScreen extends StatefulWidget {
  const CampaignBuilderScreen(
      {super.key, required this.store, required this.repo});
  final Store store;
  final StoresRepository repo;

  @override
  State<CampaignBuilderScreen> createState() => _CampaignBuilderScreenState();
}

class _CampaignBuilderScreenState extends State<CampaignBuilderScreen> {
  final _audience = TextEditingController();
  final _instructions = TextEditingController();
  final _cta = TextEditingController();
  final _productSearch = TextEditingController();

  bool _wholeStore = true;
  List<StoreProduct> _products = const [];
  bool _productsLoading = true;
  String? _productsError;
  final Set<String> _selected = {};

  CampaignObjective _objective = CampaignObjective.storefront;
  final Set<CampaignPlatform> _platforms = {CampaignPlatform.whatsapp};
  CampaignTone _tone = CampaignTone.friendly;
  String _language = CampaignLanguage.en;
  String? _format;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _audience.dispose();
    _instructions.dispose();
    _cta.dispose();
    _productSearch.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() {
      _productsLoading = true;
      _productsError = null;
    });
    // Only live products: the server refuses to promote anything buyers
    // can't see right now, so offering them here would only fail later.
    // The server's page ceiling: everything a seller can promote in one
    // campaign is reachable here, not just the first fifty products.
    final result = await widget.repo.getOwnerProducts(widget.store.id,
        state: StoreProductState.live, limit: 100);
    if (!mounted) return;
    setState(() {
      _productsLoading = false;
      switch (result) {
        case Success(:final data):
          _products = data.items;
        case Failure(:final message):
          _productsError = message;
      }
    });
  }

  bool get _needsProduct =>
      _objective == CampaignObjective.product ||
      _objective == CampaignObjective.newStock ||
      _objective == CampaignObjective.discount;

  /// The shapes this campaign's platform actually offers. With several
  /// platforms selected there is no single list - each gets its natural
  /// shape - so the picker only appears for one.
  List<String> get _availableFormats => switch (_platforms.length) {
        1 => switch (_platforms.single) {
            CampaignPlatform.whatsapp => const ['message', 'status'],
            CampaignPlatform.instagram => const [
                'caption',
                'story',
                'carousel'
              ],
            CampaignPlatform.tiktok => const ['script', 'video_plan'],
            CampaignPlatform.facebook => const ['post', 'story'],
            CampaignPlatform.x => const ['post'],
          },
        _ => const [],
      };

  static String _formatLabel(String format) => switch (format) {
        'message' => 'Chat message',
        'status' => 'Status',
        'caption' => 'Caption',
        'story' => 'Story',
        'carousel' => 'Carousel',
        'script' => 'Script',
        'video_plan' => 'Video plan',
        'post' => 'Post',
        _ => format,
      };

  String? _validate() {
    if (_platforms.isEmpty) return 'Choose at least one platform.';
    if (_needsProduct && _wholeStore) {
      // The server refuses a product objective without products; saying so
      // here points at the picker rather than at a hidden requirement.
      return 'This objective needs a product. Choose "Products" above and pick what to promote.';
    }
    if (!_wholeStore && _selected.isEmpty)
      return 'Choose the product or products to promote.';
    if (_selected.length > 10)
      return 'Choose at most 10 products for one campaign.';
    if (_objective == CampaignObjective.discount &&
        _instructions.text.trim().isEmpty) {
      return 'Describe the real discount (for example "10% off until Friday"). '
          "BROKA won't invent one.";
    }
    return null;
  }

  Future<void> _submit({required bool generate}) async {
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
      productIds: _wholeStore ? const [] : _selected.toList(),
      platforms: _platforms.map((p) => p.value).toList(),
      audience: _audience.text,
      tone: _tone.value,
      language: _language,
      instructions: _instructions.text,
      cta: _cta.text,
      creativeFormat: _format,
      generate: generate,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Success(:final data):
        Navigator.of(context).pop(data);
      case Failure(:final message):
        setState(() => _error = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _products.where((p) {
      final term = _productSearch.text.trim().toLowerCase();
      return term.isEmpty || p.listing.name.toLowerCase().contains(term);
    }).toList();

    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: BrokaColors.textHigh,
        title: const Text('New campaign',
            style: TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 17,
                fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _sectionLabel('What to promote'),
          Row(children: [
            Expanded(
                child: _Choice(
              key: const Key('promote-store'),
              label: 'Whole store',
              icon: Icons.storefront_rounded,
              selected: _wholeStore,
              onTap: () => setState(() => _wholeStore = true),
            )),
            const SizedBox(width: 10),
            Expanded(
                child: _Choice(
              key: const Key('promote-products'),
              label: 'Products',
              icon: Icons.inventory_2_outlined,
              selected: !_wholeStore,
              onTap: () => setState(() => _wholeStore = false),
            )),
          ]),
          if (!_wholeStore) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('campaign-product-search'),
              controller: _productSearch,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _fieldDecoration(
                  'Search your live products', Icons.search_rounded),
            ),
            const SizedBox(height: 8),
            if (_productsLoading)
              const Padding(
                  padding: EdgeInsets.all(18),
                  child: Center(
                      child:
                          CircularProgressIndicator(color: BrokaColors.gold)))
            else if (_productsError != null)
              _card(
                  child: Column(children: [
                Text(_productsError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12.5)),
                const SizedBox(height: 8),
                OutlinedButton(
                    onPressed: _loadProducts, child: const Text('Try again')),
              ]))
            else if (_products.isEmpty)
              _card(
                  child: const Text(
                      'No live products yet. A product buyers can see is one you can promote.',
                      style: TextStyle(
                          color: BrokaColors.textMid,
                          fontSize: 13,
                          height: 1.4)))
            else
              for (final product in visible)
                _ProductChoice(
                  key: Key('campaign-product-${product.id}'),
                  product: product,
                  selected: _selected.contains(product.id),
                  onTap: () => setState(() {
                    if (!_selected.remove(product.id))
                      _selected.add(product.id);
                  }),
                ),
          ],
          const SizedBox(height: 20),
          _sectionLabel('What the campaign should do'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final objective in CampaignObjective.values)
              _Chip(
                key: Key('objective-${objective.value}'),
                label: objective.label,
                selected: _objective == objective,
                onTap: () => setState(() {
                  _objective = objective;
                  // Objectives that are about a product need one chosen;
                  // switch the picker on so the form asks.
                  if (_needsProduct && _wholeStore) _wholeStore = false;
                }),
              ),
          ]),
          const SizedBox(height: 8),
          Text(_objective.hint,
              style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 12, height: 1.4)),
          const SizedBox(height: 20),
          _sectionLabel('Where you will post it'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final platform in CampaignPlatform.values)
              _Chip(
                key: Key('platform-${platform.value}'),
                label: platform.label,
                selected: _platforms.contains(platform),
                onTap: () => setState(() {
                  if (!_platforms.remove(platform)) _platforms.add(platform);
                  if (_format != null && !_availableFormats.contains(_format)) {
                    _format = null;
                  }
                }),
              ),
          ]),
          const SizedBox(height: 6),
          const Text(
              'Each platform gets its own shape and length - not the same copy five times.',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          if (_availableFormats.isNotEmpty) ...[
            const SizedBox(height: 14),
            _sectionLabel('Creative format'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final format in _availableFormats)
                _Chip(
                  key: Key('creative-format-$format'),
                  label: _formatLabel(format),
                  selected: _format == format,
                  onTap: () => setState(
                      () => _format = _format == format ? null : format),
                ),
            ]),
            const SizedBox(height: 6),
            const Text('Choose one, or leave it to BROKA.',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          ] else if (_platforms.length > 1) ...[
            const SizedBox(height: 6),
            const Text('With several platforms, each gets its natural format.',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          ],
          const SizedBox(height: 20),
          _sectionLabel('Voice and language'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final tone in CampaignTone.values)
              _Chip(
                label: tone.label,
                selected: _tone == tone,
                onTap: () => setState(() => _tone = tone),
              ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            for (final language in CampaignLanguage.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _Chip(
                  key: Key('language-$language'),
                  label: CampaignLanguage.label(language),
                  selected: _language == language,
                  onTap: () => setState(() => _language = language),
                ),
              ),
          ]),
          const SizedBox(height: 20),
          _sectionLabel('Anything else?'),
          TextField(
            key: const Key('campaign-cta'),
            controller: _cta,
            maxLength: 160,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: _fieldDecoration(
                'Call to action (optional)', Icons.touch_app_outlined,
                hint: 'e.g. Open the link and order today'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('campaign-audience'),
            controller: _audience,
            maxLength: 120,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: _fieldDecoration(
                'Who it is for (optional)', Icons.groups_outlined,
                hint: 'e.g. Students in Kisumu'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('campaign-instructions'),
            controller: _instructions,
            maxLength: 600,
            maxLines: 4,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: _fieldDecoration(
                'Instructions (optional)', Icons.edit_note_rounded,
                hint:
                    'e.g. Mention that we deliver same day. The discount is 10% off until Friday.'),
          ),
          const SizedBox(height: 8),
          const Text(
            'BROKA will not add warranties, specifications, discounts or delivery promises '
            'that you have not given it.',
            style: TextStyle(
                color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Container(
              key: const Key('campaign-error'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: BrokaColors.danger.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BrokaColors.danger.withOpacity(0.35)),
              ),
              child: Text(_error!,
                  style: const TextStyle(
                      color: BrokaColors.danger, fontSize: 12.5, height: 1.4)),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('generate-campaign'),
            onPressed: _busy ? null : () => _submit(generate: true),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_awesome_rounded, size: 19),
            label:
                Text(_busy ? 'Writing your campaign...' : 'Generate campaign'),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('save-campaign-draft'),
            onPressed: _busy ? null : () => _submit(generate: false),
            style: OutlinedButton.styleFrom(
              foregroundColor: BrokaColors.textHigh,
              side: const BorderSide(color: BrokaColors.border),
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Save as a draft'),
          ),
          const SizedBox(height: 10),
          const Text(
            'Generating can take up to half a minute. If the AI provider is unavailable, '
            'BROKA writes the campaign from your product details and says so.',
            style: TextStyle(
                color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(String label, IconData icon,
          {String? hint}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 13),
        labelStyle: const TextStyle(color: BrokaColors.textMid),
        prefixIcon: Icon(icon, color: BrokaColors.textMid, size: 19),
        filled: true,
        fillColor: BrokaColors.bgCard.withOpacity(0.55),
        counterStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 11),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: BrokaColors.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: BrokaColors.border)),
      );
}

class _Choice extends StatelessWidget {
  const _Choice(
      {super.key,
      required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected
            ? _accent.withOpacity(0.14)
            : BrokaColors.bgCard.withOpacity(0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? _accent : BrokaColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon,
                  size: 18, color: selected ? _accent : BrokaColors.textMid),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      color:
                          selected ? BrokaColors.textHigh : BrokaColors.textMid,
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500)),
            ]),
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(
      {super.key,
      required this.label,
      required this.selected,
      required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color:
            selected ? BrokaColors.gold.withOpacity(0.16) : BrokaColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
              color: selected ? BrokaColors.gold : BrokaColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            child: Text(label,
                style: TextStyle(
                    color: selected ? BrokaColors.gold : BrokaColors.textMid,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          ),
        ),
      );
}

class _ProductChoice extends StatelessWidget {
  const _ProductChoice(
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
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? BrokaColors.gold.withOpacity(0.08)
            : BrokaColors.bgCard.withOpacity(0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(
              color: selected ? BrokaColors.gold : BrokaColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(
                    width: 46,
                    height: 46,
                    child: image == null
                        ? Container(
                            color: BrokaColors.bgMid,
                            child: const Icon(
                                Icons.image_not_supported_outlined,
                                color: BrokaColors.textLow,
                                size: 18))
                        : BrokaImage(image, fit: BoxFit.cover)),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(product.listing.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600)),
                    Text(product.listing.priceFormatted,
                        style: const TextStyle(
                            color: BrokaColors.gold,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700)),
                  ])),
              Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? BrokaColors.gold : BrokaColors.textLow,
                  size: 22),
            ]),
          ),
        ),
      ),
    );
  }
}
