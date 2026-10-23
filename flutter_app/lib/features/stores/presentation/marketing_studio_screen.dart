// BROKA — AI Marketing Studio.
//
// The seller's answer to "how do I promote this?" without a designer:
//
//   MarketingStudioTab  saved campaigns, and a way to start one
//   CampaignBuilderScreen  what to promote, for which platform, in which
//                          voice - then generate
//   CampaignDetailScreen    previews, edits, tracked links, observed
//                          counts, regenerate, delete
//   CopySheet               suggestions for a product's title, description
//                          or caption, which never change the listing by
//                          themselves
//
// Boundaries the screens keep, because the backend does:
//   * Product facts and prices come from the server's copy of the seller's
//     listings; the app only names product ids.
//   * Nothing is posted or scheduled. A TikTok script is shown as a script.
//   * No screen shows reach, impressions, ad spend, sales or revenue: BROKA
//     does not measure them, and the counts shown are the events the server
//     actually recorded.
//   * Generating replaces this campaign's creatives. Editing a caption edits
//     the campaign, never the seller's listing.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart' show BrokaColors;
import '../../../widgets/broka_image.dart';
import '../data/creative_share.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store.dart';
import '../domain/models/store_campaign.dart';
import '../domain/models/store_product.dart';

const _accent = BrokaColors.neonPurple;

Widget _card({Key? key, required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) =>
    Container(
      key: key,
      padding: padding,
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BrokaColors.border.withOpacity(0.8)),
      ),
      child: child,
    );

Widget _sectionLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(text.toUpperCase(), style: const TextStyle(
          color: BrokaColors.textMid, fontSize: 11, fontWeight: FontWeight.w700,
          letterSpacing: 1.1)),
    );

String _dateLabel(DateTime? date) {
  if (date == null) return '';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

Future<void> _copy(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$what copied')));
}

Future<bool> _openExternal(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Where each platform's post is written, once the seller has the copy. X
/// takes the text; WhatsApp takes it into a new message. The others open
/// their app/site - BROKA has no publishing permission there.
String _composeUrl(String platform, String text) {
  final encoded = Uri.encodeComponent(text);
  return switch (platform) {
    'whatsapp' => 'https://wa.me/?text=$encoded',
    'x' => 'https://x.com/intent/post?text=$encoded',
    'instagram' => 'https://www.instagram.com/',
    'tiktok' => 'https://www.tiktok.com/',
    'facebook' => 'https://www.facebook.com/',
    _ => 'https://broka.co.ke',
  };
}

// ── Tab ──────────────────────────────────────────────────────────────────────

class MarketingStudioTab extends StatefulWidget {
  const MarketingStudioTab({super.key, required this.store, required this.repo});
  final Store store;
  final StoresRepository repo;

  @override
  State<MarketingStudioTab> createState() => _MarketingStudioTabState();
}

class _MarketingStudioTabState extends State<MarketingStudioTab> {
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

  Future<void> _newCampaign() async {
    final campaign = await Navigator.of(context).push<MarketingCampaign>(
        MaterialPageRoute(builder: (_) => CampaignBuilderScreen(
            store: widget.store, repo: widget.repo)));
    if (campaign != null) {
      await _load();
      if (!mounted) return;
      await _open(campaign.id);
    }
  }

  Future<void> _open(String campaignId) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CampaignDetailScreen(
            store: widget.store, repo: widget.repo, campaignId: campaignId)));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: BrokaColors.gold,
      onRefresh: _load,
      child: ListView(
        key: const Key('marketing-list'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          _card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: _accent.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.auto_awesome_rounded, color: _accent, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(child: Text('Marketing Studio',
                    style: TextStyle(color: BrokaColors.textHigh, fontSize: 17,
                        fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 12),
              const Text(
                'Describe what you want to promote. BROKA writes posts for WhatsApp, '
                'Instagram, TikTok, Facebook and X from your real products - prices '
                'included, from the catalogue, not typed in again.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('new-campaign'),
                  onPressed: _newCampaign,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Create a campaign'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Nothing is posted by BROKA. You copy or share each post yourself, '
                'and every campaign link tells you which shop visits came from it.',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
              ),
            ]),
          ),
          const SizedBox(height: 22),
          Row(children: [
            Expanded(child: _sectionLabel('Your campaigns')),
            if (_total > 0)
              Text('$_total', style: const TextStyle(color: BrokaColors.textMid,
                  fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          if (_loading && _campaigns.isEmpty)
            const Padding(
              padding: EdgeInsets.all(28),
              child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)),
            )
          else if (_error != null)
            _card(
              key: const Key('marketing-error'),
              child: Column(children: [
                const Icon(Icons.cloud_off_rounded, color: BrokaColors.textMid, size: 32),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: _load, child: const Text('Try again')),
              ]),
            )
          else if (_campaigns.isEmpty)
            _card(
              key: const Key('marketing-empty'),
              child: Column(children: [
                const Icon(Icons.campaign_outlined, color: BrokaColors.textMid, size: 34),
                const SizedBox(height: 10),
                const Text('No campaigns yet', style: TextStyle(color: BrokaColors.textHigh,
                    fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                  'Your first campaign can promote the whole store or one product. '
                  'It takes about a minute.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
                ),
              ]),
            )
          else
            for (final campaign in _campaigns)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _CampaignCard(campaign: campaign, onTap: () => _open(campaign.id)),
              ),
        ],
      ),
    );
  }
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(campaign.titleOrObjective,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                      fontWeight: FontWeight.w700))),
              const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid),
            ]),
            const SizedBox(height: 4),
            Text([platforms, _dateLabel(campaign.createdAt)].where((s) => s.isNotEmpty).join(' · '),
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
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
  const _CountChip({required this.icon, required this.label, required this.tooltip});
  final IconData icon;
  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: BrokaColors.textMid),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5,
              fontWeight: FontWeight.w600)),
        ]),
      );
}

// ── Builder ─────────────────────────────────────────────────────────────────

class CampaignBuilderScreen extends StatefulWidget {
  const CampaignBuilderScreen({super.key, required this.store, required this.repo});
  final Store store;
  final StoresRepository repo;

  @override
  State<CampaignBuilderScreen> createState() => _CampaignBuilderScreenState();
}

class _CampaignBuilderScreenState extends State<CampaignBuilderScreen> {
  final _audience = TextEditingController();
  final _instructions = TextEditingController();
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

  bool get _needsProduct => _objective == CampaignObjective.product ||
      _objective == CampaignObjective.newStock ||
      _objective == CampaignObjective.discount;

  String? _validate() {
    if (_platforms.isEmpty) return 'Choose at least one platform.';
    if (!_wholeStore && _selected.isEmpty) return 'Choose the product or products to promote.';
    if (_needsProduct && _selected.isEmpty) {
      return 'This objective needs a product. Choose what to promote.';
    }
    if (_selected.length > 10) return 'Choose at most 10 products for one campaign.';
    if (_objective == CampaignObjective.discount && _instructions.text.trim().isEmpty) {
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
        title: const Text('New campaign', style: TextStyle(color: BrokaColors.textHigh,
            fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _sectionLabel('What to promote'),
          Row(children: [
            Expanded(child: _Choice(
              key: const Key('promote-store'),
              label: 'Whole store',
              icon: Icons.storefront_rounded,
              selected: _wholeStore,
              onTap: () => setState(() => _wholeStore = true),
            )),
            const SizedBox(width: 10),
            Expanded(child: _Choice(
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
              decoration: _fieldDecoration('Search your live products', Icons.search_rounded),
            ),
            const SizedBox(height: 8),
            if (_productsLoading)
              const Padding(padding: EdgeInsets.all(18),
                  child: Center(child: CircularProgressIndicator(color: BrokaColors.gold)))
            else if (_productsError != null)
              _card(child: Column(children: [
                Text(_productsError!, textAlign: TextAlign.center,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _loadProducts, child: const Text('Try again')),
              ]))
            else if (_products.isEmpty)
              _card(child: const Text(
                  'No live products yet. A product buyers can see is one you can promote.',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 13, height: 1.4)))
            else
              for (final product in visible)
                _ProductChoice(
                  key: Key('campaign-product-${product.id}'),
                  product: product,
                  selected: _selected.contains(product.id),
                  onTap: () => setState(() {
                    if (!_selected.remove(product.id)) _selected.add(product.id);
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
          Text(_objective.hint, style: const TextStyle(
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
                }),
              ),
          ]),
          const SizedBox(height: 6),
          const Text('Each platform gets its own shape and length - not the same copy five times.',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
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
            key: const Key('campaign-audience'),
            controller: _audience,
            maxLength: 120,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: _fieldDecoration('Who it is for (optional)', Icons.groups_outlined,
                hint: 'e.g. Students in Kisumu'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('campaign-instructions'),
            controller: _instructions,
            maxLength: 600,
            maxLines: 4,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: _fieldDecoration('Instructions (optional)', Icons.edit_note_rounded,
                hint: 'e.g. Mention that we deliver same day. The discount is 10% off until Friday.'),
          ),
          const SizedBox(height: 8),
          const Text(
            'BROKA will not add warranties, specifications, discounts or delivery promises '
            'that you have not given it.',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
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
              child: Text(_error!, style: const TextStyle(color: BrokaColors.danger,
                  fontSize: 12.5, height: 1.4)),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('generate-campaign'),
            onPressed: _busy ? null : () => _submit(generate: true),
            icon: _busy
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_awesome_rounded, size: 19),
            label: Text(_busy ? 'Writing your campaign...' : 'Generate campaign'),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Save as a draft'),
          ),
          const SizedBox(height: 10),
          const Text(
            'Generating can take up to half a minute. If the AI provider is unavailable, '
            'BROKA writes the campaign from your product details and says so.',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(String label, IconData icon, {String? hint}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 13),
        labelStyle: const TextStyle(color: BrokaColors.textMid),
        prefixIcon: Icon(icon, color: BrokaColors.textMid, size: 19),
        filled: true,
        fillColor: BrokaColors.bgCard.withOpacity(0.55),
        counterStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: BrokaColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: BrokaColors.border)),
      );
}

class _Choice extends StatelessWidget {
  const _Choice({super.key, required this.label, required this.icon,
      required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? _accent.withOpacity(0.14) : BrokaColors.bgCard.withOpacity(0.55),
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
              Icon(icon, size: 18, color: selected ? _accent : BrokaColors.textMid),
              const SizedBox(width: 7),
              Text(label, style: TextStyle(
                  color: selected ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
            ]),
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? BrokaColors.gold.withOpacity(0.16) : BrokaColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: selected ? BrokaColors.gold : BrokaColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            child: Text(label, style: TextStyle(
                color: selected ? BrokaColors.gold : BrokaColors.textMid,
                fontSize: 12.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
          ),
        ),
      );
}

class _ProductChoice extends StatelessWidget {
  const _ProductChoice({super.key, required this.product, required this.selected,
      required this.onTap});
  final StoreProduct product;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final image = product.listing.photos.isNotEmpty ? product.listing.photos.first.thumb : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? BrokaColors.gold.withOpacity(0.08) : BrokaColors.bgCard.withOpacity(0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(color: selected ? BrokaColors.gold : BrokaColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: SizedBox(width: 46, height: 46,
                    child: image == null
                        ? Container(color: BrokaColors.bgMid,
                            child: const Icon(Icons.image_not_supported_outlined,
                                color: BrokaColors.textLow, size: 18))
                        : BrokaImage(image, fit: BoxFit.cover)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(product.listing.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5,
                        fontWeight: FontWeight.w600)),
                Text(product.listing.priceFormatted, style: const TextStyle(
                    color: BrokaColors.gold, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ])),
              Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected ? BrokaColors.gold : BrokaColors.textLow, size: 22),
            ]),
          ),
        ),
      ),
    );
  }
}

// ── Detail ──────────────────────────────────────────────────────────────────

class CampaignDetailScreen extends StatefulWidget {
  const CampaignDetailScreen({super.key, required this.store, required this.repo,
      required this.campaignId, this.share = const DeviceCreativeShare()});
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
    final result = await widget.repo.getCampaign(widget.store.id, widget.campaignId);
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
        title: const Text('Write this campaign again?', style: TextStyle(color: BrokaColors.textHigh)),
        content: const Text(
            'The campaign keeps its setup and products. Its current captions are '
            'replaced with new ones - copy anything you want to keep first.',
            style: TextStyle(color: BrokaColors.textMid, height: 1.45)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Rewrite')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final result = await widget.repo.regenerateCampaign(widget.store.id, widget.campaignId);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case Success(:final data):
        setState(() => _campaign = data);
      case Failure(:final message):
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        title: const Text('Delete this campaign?', style: TextStyle(color: BrokaColors.textHigh)),
        content: const Text(
            'Its drafts, creatives and tracked links stop working. Shop visits already '
            'counted stay in your store numbers.',
            style: TextStyle(color: BrokaColors.textMid, height: 1.45)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('confirm-delete-campaign'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete', style: TextStyle(color: BrokaColors.danger,
                fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final result = await widget.repo.deleteCampaign(widget.store.id, widget.campaignId);
    if (!mounted) return;
    switch (result) {
      case Success():
        Navigator.of(context).pop();
      case Failure(:final message):
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _editCreative(CampaignCreative creative) async {
    final edited = await showModalBottomSheet<({
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _copyCaption(CampaignCreative creative) async {
    _record('shared', creative.platform);
    await _copy(context, creative.caption, 'Caption');
  }

  /// Saves or sends the campaign's rendered poster - the one file the
  /// studio actually produced. Recorded as `downloaded`: the image has left
  /// BROKA for the seller's own use, not been posted by BROKA.
  Future<void> _saveImage(CampaignCreative creative) async {
    final image = creative.image?.large ?? creative.image?.medium ?? creative.image?.thumb;
    if (image == null) return;
    final ok = await widget.share.image(
      image,
      caption: creative.caption,
      fileName: 'broka-${creative.platform}-${creative.id}.png',
      origin: _shareOrigin(),
    );
    if (!mounted) return;
    if (ok) {
      _record('downloaded', creative.platform);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Image saved or sent')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't get the image ready - copy the caption instead.")));
    }
  }

  /// Hands the written post (with its tracked link) to any app on the phone.
  Future<void> _sharePost(CampaignCreative creative) async {
    final link = _campaign?.linkFor(creative.platform) ?? '';
    final text = [creative.caption, if (link.isNotEmpty) link].join('\n\n');
    final ok = await widget.share.text(text, origin: _shareOrigin());
    if (!mounted) return;
    if (ok) {
      _record('shared', creative.platform);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't open the share sheet - copy the caption instead.")));
    }
  }

  Future<void> _copyLink(MarketingCampaign campaign, String platform) async {
    final link = campaign.linkFor(platform);
    if (link.isEmpty) return;
    _record('shared', platform);
    await _copy(context, link, 'Campaign link');
  }

  Future<void> _openPlatform(CampaignCreative creative, MarketingCampaign campaign) async {
    final link = campaign.linkFor(creative.platform);
    final text = [creative.caption, if (link.isNotEmpty) link].join('\n\n');
    _record('shared', creative.platform);
    final ok = await _openExternal(_composeUrl(creative.platform, text));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open that app on this phone - copy the caption instead.")));
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
        title: const Text('Campaign', style: TextStyle(color: BrokaColors.textHigh,
            fontSize: 17, fontWeight: FontWeight.w800)),
        actions: [
          if (campaign != null)
            IconButton(
              key: const Key('delete-campaign'),
              tooltip: 'Delete campaign',
              icon: const Icon(Icons.delete_outline_rounded, color: BrokaColors.textMid),
              onPressed: _delete,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: BrokaColors.gold))
          : campaign == null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(
                  mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_off_rounded, color: BrokaColors.textMid, size: 36),
                  const SizedBox(height: 10),
                  Text(_error ?? "Couldn't load this campaign.",
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: BrokaColors.textMid)),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: const Text('Try again')),
                ])))
              : AbsorbPointer(
                  absorbing: _busy,
                  child: ListView(
                    key: const Key('campaign-detail-list'),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      _HeaderCard(campaign: campaign, busy: _busy, onRegenerate: _regenerate),
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
                            const Icon(Icons.edit_note_rounded, color: BrokaColors.textMid, size: 32),
                            const SizedBox(height: 8),
                            const Text('Saved as a draft', style: TextStyle(
                                color: BrokaColors.textHigh, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            const Text(
                              'No posts written yet. Rewrite the campaign to generate them now - '
                              'its setup is kept.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
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
                              onCopyLink: () => _copyLink(campaign, creative.platform),
                              onOpenPlatform: () => _openPlatform(creative, campaign),
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
                                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  SizedBox(width: 78, child: Text(item.day,
                                      style: const TextStyle(color: BrokaColors.gold,
                                          fontSize: 12.5, fontWeight: FontWeight.w700))),
                                  Expanded(child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text([item.platform, item.format]
                                            .whereType<String>()
                                            .where((s) => s.isNotEmpty)
                                            .join(' · '),
                                        style: const TextStyle(color: BrokaColors.textHigh,
                                            fontSize: 12.5, fontWeight: FontWeight.w600)),
                                    if ((item.product ?? '').isNotEmpty)
                                      Text(item.product!, style: const TextStyle(
                                          color: BrokaColors.textMid, fontSize: 12)),
                                    if ((item.note ?? '').isNotEmpty)
                                      Text(item.note!, style: const TextStyle(
                                          color: BrokaColors.textMid, fontSize: 12,
                                          height: 1.35)),
                                  ])),
                                ]),
                              ),
                          ]),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'A plan, not a schedule: BROKA does not post for you.',
                          style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5),
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
                            style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
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
  const _HeaderCard({required this.campaign, required this.busy, required this.onRegenerate});
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
        Text(campaign.titleOrObjective, style: const TextStyle(color: BrokaColors.textHigh,
            fontSize: 19, fontWeight: FontWeight.w800, height: 1.25)),
        const SizedBox(height: 6),
        Text([objective, platforms].where((s) => s.isNotEmpty).join(' · '),
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
        const SizedBox(height: 4),
        Text([
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
            Icon(campaign.isAiGenerated ? Icons.auto_awesome_rounded : Icons.notes_rounded,
                size: 17, color: _accent),
            const SizedBox(width: 9),
            Expanded(child: Text(
              campaign.isAiGenerated
                  ? 'Written by ${campaign.generation['provider']} from your product details, '
                      'then checked for claims it cannot support.'
                  : (campaign.fallbackReason ??
                      'Written from your product details by BROKA\'s template writer'
                      '${campaign.generation['provider'] != null ? ', because ${campaign.generation['provider']} was unavailable' : ''}.'),
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
        child: SizedBox(width: 42, height: 42,
            child: image == null
                ? Container(color: BrokaColors.bgMid,
                    child: const Icon(Icons.image_not_supported_outlined,
                        color: BrokaColors.textLow, size: 17))
                : BrokaImage(image, fit: BoxFit.cover)),
      ),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(product.name, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13,
                fontWeight: FontWeight.w600)),
        if (product.price != null)
          Text(product.priceUnit == null
                  ? 'KES ${product.price!.toStringAsFixed(0)}'
                  : 'KES ${product.price!.toStringAsFixed(0)} ${product.priceUnit}',
              style: const TextStyle(color: BrokaColors.gold, fontSize: 12,
                  fontWeight: FontWeight.w700)),
      ])),
      if ((product.brand ?? '').isNotEmpty)
        Text(product.brand!, style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
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
            child: Text(creative.formatLabel, style: const TextStyle(color: _accent,
                fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
          ),
          const Spacer(),
          if (ratio != null)
            Text(ratio, style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
          IconButton(
            key: Key('edit-creative-${creative.id}'),
            tooltip: 'Edit this text',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 18, color: BrokaColors.textMid),
            onPressed: onEdit,
          ),
        ]),
        if (image != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: ratio == '9:16' ? 9 / 16 : (ratio == '16:9' ? 16 / 9 : 1),
              child: BrokaImage(image, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 4),
          Text('Poster built from your product photo - a starting point, not a finished design.',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 10.5, height: 1.3)),
        ],
        if (creative.headline.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          SelectableText(creative.headline, style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800,
              height: 1.3)),
        ],
        if (creative.body.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(creative.body, style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 13, height: 1.5)),
        ],
        if (creative.hashtags.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(creative.hashtags.map((t) => '#$t').join(' '),
              style: const TextStyle(color: _accent, fontSize: 12.5)),
        ],
        if (creative.cta.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.arrow_forward_rounded, size: 15, color: BrokaColors.gold),
            const SizedBox(width: 5),
            Expanded(child: Text(creative.cta, style: const TextStyle(
                color: BrokaColors.gold, fontSize: 12.5, fontWeight: FontWeight.w600))),
          ]),
        ],
        if (campaign.linkFor(creative.platform).isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(campaign.linkFor(creative.platform), maxLines: 1,
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
              style: TextButton.styleFrom(foregroundColor: BrokaColors.gold,
                  visualDensity: VisualDensity.compact),
            ),
          TextButton.icon(
            key: Key('share-post-${creative.id}'),
            onPressed: onSharePost,
            icon: const Icon(Icons.ios_share_rounded, size: 16),
            label: const Text('Share post'),
            style: TextButton.styleFrom(foregroundColor: BrokaColors.textHigh,
                visualDensity: VisualDensity.compact),
          ),
          TextButton.icon(
            key: Key('copy-caption-${creative.id}'),
            onPressed: onCopyCaption,
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('Copy caption'),
            style: TextButton.styleFrom(foregroundColor: BrokaColors.textHigh,
                visualDensity: VisualDensity.compact),
          ),
          TextButton.icon(
            key: Key('copy-link-${creative.id}'),
            onPressed: onCopyLink,
            icon: const Icon(Icons.link_rounded, size: 16),
            label: const Text('Copy link'),
            style: TextButton.styleFrom(foregroundColor: BrokaColors.textHigh,
                visualDensity: VisualDensity.compact),
          ),
          TextButton.icon(
            key: Key('open-platform-${creative.id}'),
            onPressed: onOpenPlatform,
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text('Open ${creative.platformLabel}'),
            style: TextButton.styleFrom(foregroundColor: _accent,
                visualDensity: VisualDensity.compact),
          ),
        ]),
      ]),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.platform, required this.link, required this.onCopy});
  final String platform;
  final String link;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final label = CampaignPlatform.parse(platform)?.label ?? platform;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(width: 82, child: Text(label, style: const TextStyle(
            color: BrokaColors.textHigh, fontSize: 12.5, fontWeight: FontWeight.w600))),
        Expanded(child: Text(link.isEmpty ? 'Link unavailable' : link,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: link.isEmpty ? BrokaColors.textLow : BrokaColors.textMid,
                fontSize: 11.5))),
        IconButton(
          tooltip: 'Copy $label link',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy_rounded, size: 17, color: BrokaColors.textMid),
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
            Text(value, style: const TextStyle(color: BrokaColors.textHigh,
                fontSize: 17, fontWeight: FontWeight.w800)),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 10.5, height: 1.25)),
          ]),
        );

    return _card(
      key: const Key('campaign-measured'),
      child: Column(children: [
        Row(children: [
          tile(Icons.visibility_outlined, '${events.visits}', 'Shop visits\nfrom links'),
          tile(Icons.shopping_bag_outlined, '${events.productViews}', 'Product views\nfrom links'),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          tile(Icons.download_rounded, '${events.downloads}', 'Images saved\nor sent'),
          tile(Icons.ios_share_rounded, '${events.shares}', 'Times you\nshared'),
        ]),
        const SizedBox(height: 12),
        const Divider(height: 1, color: BrokaColors.border),
        const SizedBox(height: 10),
        const Text(
          'BROKA does not measure impressions, reach, advertising spend, sales or revenue '
          'for campaigns. Those numbers would be invented, so they are not shown.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5, height: 1.4),
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
  late final _hashtags = TextEditingController(text: widget.creative.hashtags.join(', '));

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
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              Text('Edit ${widget.creative.formatLabel}', style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('This edits the campaign post. Your product listing is not changed.',
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
                    labelText: 'Hashtags', helperText: 'Separated by commas, without #'),
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
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              Text('Improve copy - ${widget.productName}', maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text(
                'Suggestions only. Your listing stays as it is until you save a change '
                'in the normal editor.',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.4),
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
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
                Text(_error!, style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5)),
              ],
              if (_result != null) ...[
                const SizedBox(height: 14),
                if (!_result!.available)
                  Text(_result!.message ?? 'AI copy suggestions are not configured on the server.',
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5,
                          height: 1.4))
                else if (_result!.items.isEmpty)
                  const Text('No suggestions came back. Try again, or edit it yourself.',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5))
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
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SelectableText(_result!.items[i].text, style: const TextStyle(
                            color: BrokaColors.textHigh, fontSize: 13, height: 1.45)),
                        if ((_result!.items[i].why ?? '').isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(_result!.items[i].why!, style: const TextStyle(
                              color: BrokaColors.textLow, fontSize: 11.5, height: 1.35)),
                        ],
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _copy(context, _result!.items[i].text, 'Suggestion'),
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
                  style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.4),
                ),
              ],
            ],
          ),
        ),
      );
}
