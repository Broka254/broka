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
import '../domain/models/marketing_sidekick.dart';
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

Future<bool> _copy(BuildContext context, String text, String what) async {
  var copied = false;
  try {
    await Clipboard.setData(ClipboardData(text: text));
    copied = true;
  } catch (_) {
    // A clipboard write can fail on a locked device; the caller must not
    // report a copy that never happened.
  }
  if (!context.mounted) return copied;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(copied ? '$what copied' : "Couldn't copy $what")));
  return copied;
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

/// The shape's name in the Creative Studio. The campaign builder has its own
/// copy of this wording for its form; both must read the same to the seller.
String _creativeShapeLabel(String format) => switch (format) {
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

// ── Studio shell ────────────────────────────────────────────────────────────
//
// Four areas, in the order a seller works: what is happening (Overview), what
// to do next (Sidekick), make the creative (Creative Studio), and pay for
// reach (Ads Guidance). The campaign builder and detail screens below are the
// engine; this shell organises them instead of replacing them.
//
// Nothing here is a new source of truth: counts come from the campaign
// payload (observed events only), product facts come from the server, and the
// Ads checklist says plainly that BROKA has not created a campaign.

enum _StudioSection {
  overview('Overview', Icons.insights_rounded),
  sidekick('Sidekick', Icons.auto_awesome_rounded),
  creative('Creative', Icons.palette_outlined),
  ads('Ads', Icons.campaign_outlined);

  const _StudioSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

class MarketingStudioTab extends StatefulWidget {
  const MarketingStudioTab(
      {super.key, required this.store, required this.repo});
  final Store store;
  final StoresRepository repo;

  @override
  State<MarketingStudioTab> createState() => _MarketingStudioTabState();
}

class _MarketingStudioTabState extends State<MarketingStudioTab> {
  _StudioSection _section = _StudioSection.overview;

  // What the Sidekick (or a platform guide) already knows, handed to the
  // tools so the seller does not choose the same product twice.
  int _creativeSeed = 0;
  String? _creativeProductId;
  String? _creativePlatform;
  String? _creativeObjective;
  String? _creativeFormat;
  int _adsSeed = 0;
  String? _adsProductId;

  void _go(_StudioSection section) => setState(() => _section = section);

  void _openCreative(SidekickAction action) {
    setState(() {
      _creativeSeed++;
      _creativeProductId = action.productId ?? _creativeProductId;
      _creativePlatform = action.platform ?? _creativePlatform;
      _creativeObjective = action.objective ?? _creativeObjective;
      _creativeFormat = action.creativeFormat ?? _creativeFormat;
      _section = _StudioSection.creative;
    });
  }

  void _openAds(SidekickAction action) {
    setState(() {
      _adsSeed++;
      _adsProductId = action.productId ?? _adsProductId;
      _section = _StudioSection.ads;
    });
  }

  Future<void> _handleAction(SidekickAction action) async {
    switch (action.type) {
      case 'creative_studio':
        _openCreative(action);
      case 'meta_ads':
        _openAds(action);
      case 'platform_guide':
        if (action.platform != null) {
          await showPlatformGuideSheet(
            context,
            repo: widget.repo,
            storeId: widget.store.id,
            platform: action.platform!,
            onAction: _handleAction,
          );
        }
      case 'video_script':
        await showVideoScriptSheet(
          context,
          repo: widget.repo,
          storeId: widget.store.id,
          initialPlatform: action.platform,
          initialProductId: action.productId,
        );
      default:
        break;
    }
  }

  Future<void> _openCampaign(String campaignId) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => CampaignDetailScreen(
            store: widget.store, repo: widget.repo, campaignId: campaignId)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('marketing-studio'),
      children: [
        _StudioHeader(store: widget.store),
        _StudioNav(section: _section, onSelect: _go),
        Expanded(
          child: IndexedStack(
            index: _section.index,
            children: [
              _MarketingOverviewTab(
                store: widget.store,
                repo: widget.repo,
                onAskSidekick: () => _go(_StudioSection.sidekick),
                onCreateCreative: () => _openCreative(const SidekickAction(
                    type: 'creative_studio', label: 'Create')),
                onPlanAds: () => _openAds(
                    const SidekickAction(type: 'meta_ads', label: 'Plan')),
                onOpenCampaign: _openCampaign,
                onAction: _handleAction,
              ),
              _SidekickTab(
                store: widget.store,
                repo: widget.repo,
                onAction: _handleAction,
              ),
              _CreativeStudioTab(
                key: ValueKey('creative-$_creativeSeed'),
                store: widget.store,
                repo: widget.repo,
                initialProductId: _creativeProductId,
                initialPlatform: _creativePlatform,
                initialObjective: _creativeObjective,
                initialFormat: _creativeFormat,
              ),
              _AdsGuidanceTab(
                key: ValueKey('ads-$_adsSeed'),
                store: widget.store,
                repo: widget.repo,
                initialProductId: _adsProductId,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StudioHeader extends StatelessWidget {
  const _StudioHeader({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _accent.withOpacity(0.20),
            BrokaColors.bgCard.withOpacity(0.75),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _accent.withOpacity(0.30)),
      ),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.18),
            borderRadius: BorderRadius.circular(14),
          ),
          child:
              const Icon(Icons.auto_awesome_rounded, color: _accent, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Marketing Studio',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2)),
            const SizedBox(height: 2),
            Text(store.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12.5)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: BrokaColors.bgMid.withOpacity(0.65),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Text('You publish',
              style: TextStyle(
                  color: BrokaColors.textMid,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class _StudioNav extends StatelessWidget {
  const _StudioNav({required this.section, required this.onSelect});
  final _StudioSection section;
  final ValueChanged<_StudioSection> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          for (final item in _StudioSection.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: item == section
                    ? BrokaColors.gold.withOpacity(0.14)
                    : BrokaColors.bgCard.withOpacity(0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: BorderSide(
                      color: item == section
                          ? BrokaColors.gold
                          : BrokaColors.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: Key('marketing-section-${item.name}'),
                  onTap: () => onSelect(item),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(item.icon,
                          size: 16,
                          color: item == section
                              ? BrokaColors.gold
                              : BrokaColors.textMid),
                      const SizedBox(width: 6),
                      Text(item.label,
                          style: TextStyle(
                              color: item == section
                                  ? BrokaColors.gold
                                  : BrokaColors.textMid,
                              fontSize: 12.5,
                              fontWeight: item == section
                                  ? FontWeight.w700
                                  : FontWeight.w500)),
                    ]),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Overview ────────────────────────────────────────────────────────────────

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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          _card(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(
                  child: Text('What your marketing is doing',
                      style: TextStyle(
                          color: BrokaColors.textHigh,
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                ),
                if (_loading)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: BrokaColors.gold)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _StatTile(value: '$_total', label: 'Campaigns'),
                _StatTile(value: '$visits', label: 'Shop visits\nfrom links'),
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
            ]),
          ),
          const SizedBox(height: 16),
          _sectionLabel('Do something now'),
          Row(children: [
            Expanded(
                child: _ActionTile(
              key: const Key('overview-ask-sidekick'),
              icon: Icons.auto_awesome_rounded,
              title: 'Ask the Sidekick',
              subtitle: 'Get a plan for your store',
              onTap: widget.onAskSidekick,
            )),
            const SizedBox(width: 10),
            Expanded(
                child: _ActionTile(
              key: const Key('overview-create-creative'),
              icon: Icons.palette_outlined,
              title: 'Creative Studio',
              subtitle: 'Image, caption, hashtags',
              onTap: widget.onCreateCreative,
            )),
          ]),
          const SizedBox(height: 10),
          _ActionTile(
            key: const Key('overview-plan-ads'),
            icon: Icons.campaign_outlined,
            title: 'Plan a Meta ad',
            subtitle:
                'A step-by-step checklist in KES - you finish in Ads Manager',
            onTap: widget.onPlanAds,
          ),
          const SizedBox(height: 20),
          _sectionLabel('Platform guides'),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final platform in CampaignPlatform.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      key: Key('overview-guide-${platform.value}'),
                      avatar: const Icon(Icons.menu_book_outlined,
                          size: 15, color: BrokaColors.textMid),
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
              Text('$_total',
                  style: const TextStyle(
                      color: BrokaColors.textMid,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
          ]),
          if (_loading && _campaigns.isEmpty)
            const Padding(
              padding: EdgeInsets.all(26),
              child: Center(
                  child: CircularProgressIndicator(color: BrokaColors.gold)),
            )
          else if (_error != null)
            _card(
              key: const Key('marketing-error'),
              child: Column(children: [
                const Icon(Icons.cloud_off_rounded,
                    color: BrokaColors.textMid, size: 30),
                const SizedBox(height: 8),
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12.5)),
                const SizedBox(height: 10),
                OutlinedButton(
                    onPressed: _load, child: const Text('Try again')),
              ]),
            )
          else if (_campaigns.isEmpty)
            _card(
              key: const Key('marketing-empty'),
              child: Column(children: [
                const Icon(Icons.campaign_outlined,
                    color: BrokaColors.textMid, size: 32),
                const SizedBox(height: 8),
                const Text('No campaigns yet',
                    style: TextStyle(
                        color: BrokaColors.textHigh,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                  'Make your first post in Creative Studio, or ask the Sidekick which '
                  'platform to start with.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  key: const Key('empty-start-creative'),
                  onPressed: widget.onCreateCreative,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Create a creative'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ]),
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
                onPressed: () async {
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
                },
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

class _ActionTile extends StatelessWidget {
  const _ActionTile(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap});
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
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 17, color: _accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title,
                        style: const TextStyle(
                            color: BrokaColors.textHigh,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            color: BrokaColors.textMid,
                            fontSize: 11,
                            height: 1.3)),
                  ])),
            ]),
          ),
        ),
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
                          fontSize: 15,
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

// ── Sidekick ────────────────────────────────────────────────────────────────

class _ChatEntry {
  _ChatEntry.user(this.text)
      : role = 'user',
        reply = null,
        error = null,
        pending = false;
  _ChatEntry.pending()
      : role = 'assistant',
        text = '',
        reply = null,
        error = null,
        pending = true;
  _ChatEntry.answer(SidekickReply answer)
      : role = 'assistant',
        text = answer.reply,
        reply = answer,
        error = null,
        pending = false;
  _ChatEntry.failed(this.error)
      : role = 'assistant',
        text = '',
        reply = null,
        pending = false;

  final String role;
  final String text;
  final SidekickReply? reply;
  final String? error;
  final bool pending;
}

class _SidekickTab extends StatefulWidget {
  const _SidekickTab(
      {required this.store, required this.repo, required this.onAction});
  final Store store;
  final StoresRepository repo;
  final ValueChanged<SidekickAction> onAction;

  @override
  State<_SidekickTab> createState() => _SidekickTabState();
}

class _SidekickTabState extends State<_SidekickTab>
    with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatEntry> _entries = [];
  CampaignPlatform? _platform;
  bool _busy = false;
  String? _lastFailed;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<({String role, String text})> get _history => [
        for (final entry in _entries)
          if (!entry.pending && entry.error == null)
            (
              role: entry.role,
              text: entry.role == 'assistant'
                  ? (entry.reply?.reply ?? '')
                  : entry.text
            ),
      ]
          .where((turn) => turn.text.trim().isNotEmpty)
          .toList()
          .reversed
          .take(8)
          .toList()
          .reversed
          .toList();

  Future<void> _send([String? preset]) async {
    if (_busy) return;
    final text = (preset ?? _controller.text).trim();
    if (text.isEmpty) return;
    final history = _history;
    setState(() {
      _entries.add(_ChatEntry.user(text));
      _entries.add(_ChatEntry.pending());
      _busy = true;
      _lastFailed = null;
      _controller.clear();
    });
    _scrollToEnd();
    final result = await widget.repo.sidekickChat(
      widget.store.id,
      message: text,
      platform: _platform?.value,
      history: history,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _entries.removeLast();
      switch (result) {
        case Success(:final data):
          _entries.add(_ChatEntry.answer(data));
          _lastFailed = null;
        case Failure(:final message):
          _entries.add(_ChatEntry.failed(message));
          _lastFailed = text;
      }
    });
    _scrollToEnd();
  }

  Future<void> _retry() async {
    final text = _lastFailed;
    if (text == null || _busy) return;
    setState(() {
      _entries.removeLast();
      _busy = true;
      _lastFailed = null;
    });
    final history = _history;
    setState(() => _entries.add(_ChatEntry.pending()));
    final result = await widget.repo.sidekickChat(
      widget.store.id,
      message: text,
      platform: _platform?.value,
      history: history,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _entries.removeLast();
      switch (result) {
        case Success(:final data):
          _entries.add(_ChatEntry.answer(data));
        case Failure(:final message):
          _entries.add(_ChatEntry.failed(message));
          _lastFailed = text;
      }
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent + 200,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lastReply = _entries.reversed
        .where((e) => e.reply != null)
        .map((e) => e.reply!)
        .firstOrNull;
    final suggestions = lastReply?.suggestions.isNotEmpty == true
        ? lastReply!.suggestions
        : const [
            'How should I market my store?',
            'Which social media platform suits my business?',
            'What content should I post this week?',
          ];
    return Column(
      key: const Key('marketing-sidekick'),
      children: [
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            children: [
              _PlatformChip(
                key: const Key('sidekick-platform-any'),
                label: 'Any platform',
                selected: _platform == null,
                onTap: () => setState(() => _platform = null),
              ),
              for (final platform in CampaignPlatform.values)
                _PlatformChip(
                  key: Key('sidekick-platform-${platform.value}'),
                  label: platform.label,
                  selected: _platform == platform,
                  onTap: () => setState(() =>
                      _platform = _platform == platform ? null : platform),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            key: const Key('sidekick-conversation'),
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              if (_entries.isEmpty) _sidekickWelcome(suggestions),
              for (final entry in _entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: entry.role == 'user'
                      ? _UserBubble(text: entry.text)
                      : entry.pending
                          ? const _TypingBubble()
                          : entry.error != null
                              ? _ErrorBubble(
                                  message: entry.error!, onRetry: _retry)
                              : _AnswerBubble(
                                  reply: entry.reply!,
                                  onAction: widget.onAction,
                                  onSuggestion: _send,
                                ),
                ),
              if (_entries.isNotEmpty && !_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final suggestion in suggestions.take(3))
                      ActionChip(
                        key: Key('sidekick-followup-${suggestion.hashCode}'),
                        label: Text(suggestion,
                            style: const TextStyle(
                                color: BrokaColors.textMid, fontSize: 11.5)),
                        backgroundColor: BrokaColors.bgCard.withOpacity(0.55),
                        side: const BorderSide(color: BrokaColors.border),
                        onPressed: () => _send(suggestion),
                      ),
                  ]),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('sidekick-input'),
                  controller: _controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(
                      color: BrokaColors.textHigh, fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: _platform == null
                        ? 'Ask about marketing your store...'
                        : 'Ask about marketing on ${_platform!.label}...',
                    hintStyle: const TextStyle(
                        color: BrokaColors.textLow, fontSize: 13),
                    filled: true,
                    fillColor: BrokaColors.bgCard.withOpacity(0.6),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide:
                            const BorderSide(color: BrokaColors.border)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide:
                            const BorderSide(color: BrokaColors.border)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                height: 46,
                child: FilledButton(
                  key: const Key('sidekick-send'),
                  onPressed: _busy ? null : () => _send(),
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    backgroundColor: _accent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(23)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.arrow_upward_rounded,
                          size: 20, color: Colors.white),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _sidekickWelcome(List<String> suggestions) => _card(
        key: const Key('sidekick-welcome'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.16),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.auto_awesome_rounded,
                  color: _accent, size: 18),
            ),
            const SizedBox(width: 10),
            const Expanded(
                child: Text('Your marketing Sidekick',
                    style: TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 15,
                        fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: 10),
          const Text(
            'Ask a real question about this store. Answers use your live products and '
            'their prices, and can open Creative Studio with the product already chosen.',
            style: TextStyle(
                color: BrokaColors.textMid, fontSize: 12.5, height: 1.45),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < suggestions.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: BrokaColors.bgMid.withOpacity(0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: BrokaColors.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: Key('sidekick-suggestion-$i'),
                  onTap: () => _send(suggestions[i]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 11, vertical: 10),
                    child: Row(children: [
                      Expanded(
                          child: Text(suggestions[i],
                              style: const TextStyle(
                                  color: BrokaColors.textHigh,
                                  fontSize: 12.5))),
                      const Icon(Icons.arrow_forward_rounded,
                          size: 15, color: BrokaColors.textMid),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}

class _PlatformChip extends StatelessWidget {
  const _PlatformChip(
      {super.key,
      required this.label,
      required this.selected,
      required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: selected
              ? BrokaColors.gold.withOpacity(0.16)
              : BrokaColors.bgCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
                color: selected ? BrokaColors.gold : BrokaColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(label,
                  style: TextStyle(
                      color: selected ? BrokaColors.gold : BrokaColors.textMid,
                      fontSize: 12,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500)),
            ),
          ),
        ),
      );
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82),
          padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.18),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(color: _accent.withOpacity(0.35)),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: BrokaColors.textHigh, fontSize: 13, height: 1.4)),
        ),
      );
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) => Row(children: [
        const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: BrokaColors.gold)),
        const SizedBox(width: 9),
        Text('Thinking about your store...',
            style: TextStyle(
                color: BrokaColors.textMid.withOpacity(0.9), fontSize: 12.5)),
      ]);
}

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _card(
        key: const Key('sidekick-error'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.cloud_off_rounded, size: 17, color: BrokaColors.textMid),
            SizedBox(width: 8),
            Text('The Sidekick did not answer',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(message,
              style: const TextStyle(
                  color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('sidekick-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Try again'),
            style: OutlinedButton.styleFrom(
              foregroundColor: BrokaColors.textHigh,
              side: const BorderSide(color: BrokaColors.border),
            ),
          ),
        ]),
      );
}

class _AnswerBubble extends StatelessWidget {
  const _AnswerBubble(
      {required this.reply,
      required this.onAction,
      required this.onSuggestion});
  final SidekickReply reply;
  final ValueChanged<SidekickAction> onAction;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (reply.available ? _accent : BrokaColors.gold)
                  .withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              reply.available ? 'AI answer' : 'BROKA guidance',
              style: TextStyle(
                  color: reply.available ? _accent : BrokaColors.gold,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2),
            ),
          ),
          if (reply.platform != null) ...[
            const SizedBox(width: 6),
            Text(
                CampaignPlatform.parse(reply.platform)?.label ??
                    reply.platform!,
                style: const TextStyle(
                    color: BrokaColors.textLow, fontSize: 10.5)),
          ],
        ]),
        const SizedBox(height: 9),
        SelectableText(reply.reply,
            style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 13, height: 1.5)),
        if (reply.fallbackReason != null) ...[
          const SizedBox(height: 8),
          Text(reply.fallbackReason!,
              style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11, height: 1.4)),
        ],
        if (reply.products.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.inventory_2_outlined,
                size: 14, color: BrokaColors.textMid),
            const SizedBox(width: 6),
            Expanded(
                child: Text(
              reply.products
                  .map((p) => [p.name, p.priceLabel]
                      .whereType<String>()
                      .where((s) => s.isNotEmpty)
                      .join(' · '))
                  .join('  |  '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
            )),
          ]),
        ],
        if (reply.actions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final action in reply.actions)
              OutlinedButton(
                key: Key('sidekick-action-${action.type}'
                    '${action.platform == null ? '' : '-${action.platform}'}'),
                onPressed: () => onAction(action),
                style: OutlinedButton.styleFrom(
                  foregroundColor: action.type == 'creative_studio'
                      ? BrokaColors.gold
                      : BrokaColors.textHigh,
                  side: BorderSide(
                      color: action.type == 'creative_studio'
                          ? BrokaColors.gold.withOpacity(0.7)
                          : BrokaColors.border),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(action.label,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
          ]),
        ],
        if (reply.suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final suggestion in reply.suggestions.take(2))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: InkWell(
                onTap: () => onSuggestion(suggestion),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    const Icon(Icons.north_east_rounded,
                        size: 12, color: BrokaColors.textLow),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(suggestion,
                            style: const TextStyle(
                                color: BrokaColors.textMid, fontSize: 11.5))),
                  ]),
                ),
              ),
            ),
        ],
      ]),
    );
  }
}

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
            const Text('Make one post',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 15,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            const Text(
              'One product, one platform, one format. BROKA writes the caption, hashtags '
              'and a poster from your real listing - you publish it.',
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
                child: Text(_error!,
                    style: const TextStyle(
                        color: BrokaColors.danger, fontSize: 12, height: 1.4)),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('creative-generate'),
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.auto_awesome_rounded, size: 18),
              label:
                  Text(_busy ? 'Making your creative...' : 'Generate creative'),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
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

// ── Ads Guidance ────────────────────────────────────────────────────────────

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
    final budget = rawBudget.isEmpty ? null : int.tryParse(rawBudget);
    if (rawBudget.isNotEmpty && (budget == null || budget < 100)) {
      setState(() =>
          _error = 'Enter a daily budget of at least KES 100, or leave it '
              'empty for a suggestion.');
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
      budgetKes: budget,
      audience: _audience.text,
      location: _location.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Success(:final data):
          _plan = data;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  Future<void> _copyPlan(AdsPlan plan) async {
    final text = [
      'Meta ads plan for ${plan.productName ?? widget.store.name}',
      'Objective: ${plan.objectiveLabel}',
      'Audience: ${plan.audience}',
      'Location: ${plan.location}',
      'Budget: ${plan.currency} ${plan.budget.dailyKes}/day for '
          '${plan.budget.trialDays} days',
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        _card(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.campaign_outlined, size: 19, color: _accent),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('Meta ads, explained step by step',
                      style: TextStyle(
                          color: BrokaColors.textHigh,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800))),
            ]),
            const SizedBox(height: 6),
            const Text(
              'BROKA prepares the decisions and the wording. You create and pay for the '
              'campaign inside Meta Ads Manager - BROKA does not create, publish or bill ads.',
              style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 12, height: 1.45),
            ),
            const SizedBox(height: 14),
            _StudioStep(number: 1, title: 'Product'),
            if (_productsLoading)
              const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(
                      child: CircularProgressIndicator(
                          color: BrokaColors.gold, strokeWidth: 2.5)))
            else if (_productsError != null)
              _InlineError(message: _productsError!, onRetry: _loadProducts)
            else if (_products.isEmpty)
              const Text(
                  'Add a live product first; an ad needs something real to show.',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5))
            else
              SizedBox(
                height: 42,
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
            _StudioStep(number: 2, title: 'Objective'),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final entry in _adsObjectives.entries)
                _Chip(
                  key: Key('ads-objective-${entry.key}'),
                  label: entry.value,
                  selected: _objective == entry.key,
                  onTap: () => setState(() => _objective = entry.key),
                ),
            ]),
            const SizedBox(height: 14),
            _StudioStep(number: 3, title: 'Budget and audience'),
            TextField(
              key: const Key('ads-budget'),
              controller: _budget,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: _studioField(
                  'Daily budget in KES (optional)', Icons.payments_outlined,
                  hint: 'e.g. 500 - leave empty for a starting suggestion'),
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
                        color: BrokaColors.danger, fontSize: 12, height: 1.4)),
              ),
            ],
            const SizedBox(height: 8),
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
              label: Text(_busy ? 'Building your plan...' : 'Build my ad plan'),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ]),
        ),
        if (plan != null) ...[
          const SizedBox(height: 16),
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
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                OutlinedButton.icon(
                  key: const Key('ads-open-manager'),
                  onPressed: () => _openManager(plan.managerUrl),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Open Meta Ads Manager'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BrokaColors.textHigh,
                    side: const BorderSide(color: BrokaColors.border),
                  ),
                ),
                TextButton.icon(
                  key: const Key('ads-copy-plan'),
                  onPressed: () => _copyPlan(plan),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy plan'),
                ),
              ]),
            ]),
          ),
          const SizedBox(height: 14),
          _card(
            child: Row(children: [
              _PlanFact(label: 'Objective', value: plan.objectiveLabel),
              _PlanFact(label: 'Audience', value: plan.audience),
              _PlanFact(label: 'Location', value: plan.location),
              _PlanFact(
                  label: 'Daily',
                  value: '${plan.currency} ${plan.budget.dailyKes}'),
            ]),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 8),
            child: Text(
              'About ${plan.currency} ${plan.budget.totalKes} over '
              '${plan.budget.trialDays} days. ${plan.budget.note}',
              style: const TextStyle(
                  color: BrokaColors.textLow, fontSize: 11, height: 1.4),
            ),
          ),
          _sectionLabel('Your checklist'),
          for (final stage in plan.stages)
            _AdsStageCard(key: Key('ads-stage-${stage.key}'), stage: stage),
        ],
      ],
    );
  }
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
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: BrokaColors.gold.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(stage.suggestion,
                    style: const TextStyle(
                        color: BrokaColors.gold,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
              ),
            ],
            if (stage.steps.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final step in stage.steps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 5),
                          child: Icon(Icons.circle,
                              size: 5, color: BrokaColors.textLow),
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

// ── Platform guide sheet ────────────────────────────────────────────────────

Future<void> showPlatformGuideSheet(
  BuildContext context, {
  required StoresRepository repo,
  required String storeId,
  required String platform,
  required ValueChanged<SidekickAction> onAction,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _PlatformGuideSheet(
        repo: repo,
        storeId: storeId,
        platform: platform,
        onAction: onAction,
      ),
    );

class _PlatformGuideSheet extends StatefulWidget {
  const _PlatformGuideSheet({
    required this.repo,
    required this.storeId,
    required this.platform,
    required this.onAction,
  });
  final StoresRepository repo;
  final String storeId;
  final String platform;
  final ValueChanged<SidekickAction> onAction;

  @override
  State<_PlatformGuideSheet> createState() => _PlatformGuideSheetState();
}

class _PlatformGuideSheetState extends State<_PlatformGuideSheet> {
  PlatformGuide? _guide;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result =
        await widget.repo.getPlatformGuide(widget.storeId, widget.platform);
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Success(:final data):
          _guide = data;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  void _run(SidekickAction action) {
    Navigator.of(context).pop();
    widget.onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final guide = _guide;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: ListView(
          key: const Key('platform-guide-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Text(guide?.label ?? 'Platform guide',
                style: const TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(
                      child:
                          CircularProgressIndicator(color: BrokaColors.gold)))
            else if (_error != null)
              _InlineError(message: _error!, onRetry: _load)
            else if (guide != null) ...[
              Text(guide.summary,
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 12.5, height: 1.5)),
              const SizedBox(height: 6),
              Text('Best for: ${guide.bestFor}',
                  style: const TextStyle(
                      color: BrokaColors.textLow, fontSize: 11.5, height: 1.4)),
              const SizedBox(height: 12),
              if (guide.formats.isNotEmpty) ...[
                _sectionLabel('Formats'),
                for (final format in guide.formats)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.rectangle_outlined,
                              size: 14, color: BrokaColors.textMid),
                          const SizedBox(width: 7),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(format.label,
                                    style: const TextStyle(
                                        color: BrokaColors.textHigh,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600)),
                                if (format.tip.isNotEmpty)
                                  Text(format.tip,
                                      style: const TextStyle(
                                          color: BrokaColors.textMid,
                                          fontSize: 11.5,
                                          height: 1.35)),
                              ])),
                        ]),
                  ),
                const SizedBox(height: 8),
              ],
              for (final section in guide.sections)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    key: Key('guide-section-${section.key}'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: BrokaColors.bgCard.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: BrokaColors.border),
                    ),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(section.title,
                              style: const TextStyle(
                                  color: BrokaColors.textHigh,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
                          if (section.summary.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(section.summary,
                                style: const TextStyle(
                                    color: BrokaColors.textMid,
                                    fontSize: 11.5,
                                    height: 1.4)),
                          ],
                          const SizedBox(height: 7),
                          for (final step in section.steps)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.only(top: 5),
                                      child: Icon(Icons.circle,
                                          size: 5, color: BrokaColors.textLow),
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
                        ]),
                  ),
                ),
              if (guide.example != null) ...[
                _sectionLabel('Caption starter from your store'),
                Container(
                  key: const Key('guide-example'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: BrokaColors.bgCard.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: BrokaColors.gold.withOpacity(0.4)),
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(guide.example!.label,
                            style: const TextStyle(
                                color: BrokaColors.gold,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        SelectableText(guide.example!.body,
                            style: const TextStyle(
                                color: BrokaColors.textHigh,
                                fontSize: 12.5,
                                height: 1.45)),
                        if (guide.example!.hashtags.isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                              guide.example!.hashtags
                                  .map((t) => '#$t')
                                  .join(' '),
                              style: const TextStyle(
                                  color: _accent, fontSize: 11.5)),
                        ],
                        const SizedBox(height: 6),
                        Text(guide.example!.note,
                            style: const TextStyle(
                                color: BrokaColors.textLow,
                                fontSize: 10.5,
                                height: 1.35)),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _copy(
                                context, guide.example!.shareable, 'Caption'),
                            icon: const Icon(Icons.copy_rounded, size: 15),
                            label: const Text('Copy'),
                          ),
                        ),
                      ]),
                ),
              ],
              if (guide.actions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final action in guide.actions)
                    OutlinedButton(
                      key: Key('guide-action-${action.type}'),
                      onPressed: () => _run(action),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BrokaColors.textHigh,
                        side: const BorderSide(color: BrokaColors.border),
                      ),
                      child: Text(action.label),
                    ),
                ]),
              ],
              const SizedBox(height: 8),
              Text(guide.note,
                  style: const TextStyle(
                      color: BrokaColors.textLow, fontSize: 10.5, height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Video script sheet ──────────────────────────────────────────────────────

Future<void> showVideoScriptSheet(
  BuildContext context, {
  required StoresRepository repo,
  required String storeId,
  String? initialPlatform,
  String? initialProductId,
  String initialKind = 'script',
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => _VideoScriptSheet(
        repo: repo,
        storeId: storeId,
        initialPlatform: initialPlatform,
        initialProductId: initialProductId,
        initialKind: initialKind,
      ),
    );

class _VideoScriptSheet extends StatefulWidget {
  const _VideoScriptSheet({
    required this.repo,
    required this.storeId,
    this.initialPlatform,
    this.initialProductId,
    this.initialKind = 'script',
  });
  final StoresRepository repo;
  final String storeId;
  final String? initialPlatform;
  final String? initialProductId;
  final String initialKind;

  @override
  State<_VideoScriptSheet> createState() => _VideoScriptSheetState();
}

class _VideoScriptSheetState extends State<_VideoScriptSheet> {
  late String _platform =
      const ['tiktok', 'instagram', 'facebook'].contains(widget.initialPlatform)
          ? widget.initialPlatform!
          : 'tiktok';
  late String _kind = widget.initialKind;
  VideoScript? _script;
  bool _busy = false;
  String? _error;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.repo.generateVideoScript(
      widget.storeId,
      platform: _platform,
      kind: _kind,
      productIds: widget.initialProductId == null
          ? const []
          : [widget.initialProductId!],
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      switch (result) {
        case Success(:final data):
          _script = data;
        case Failure(:final message):
          _error = message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final script = _script;
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: ListView(
          key: const Key('video-script-sheet'),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            const Text('Video script',
                style: TextStyle(
                    color: BrokaColors.textHigh,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
              'A concept and shot list to film on your phone. BROKA does not make a '
              'video file.',
              style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final platform in const {
                'tiktok': 'TikTok',
                'instagram': 'Instagram',
                'facebook': 'Facebook',
              }.entries)
                _Chip(
                  key: Key('sheet-video-platform-${platform.key}'),
                  label: platform.value,
                  selected: _platform == platform.key,
                  onTap: () => setState(() => _platform = platform.key),
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
                  key: Key('sheet-video-kind-${kind.key}'),
                  label: kind.value,
                  selected: _kind == kind.key,
                  onTap: () => setState(() => _kind = kind.key),
                ),
            ]),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const Key('sheet-video-generate'),
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.description_outlined, size: 17),
              label: Text(_busy ? 'Writing the script...' : 'Generate script'),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 46),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              _InlineError(message: _error!, onRetry: _generate),
            ],
            if (script != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: BrokaColors.gold.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Icon(Icons.movie_creation_outlined,
                            size: 15, color: BrokaColors.gold),
                        const SizedBox(width: 7),
                        Expanded(
                            child: Text(script.label,
                                style: const TextStyle(
                                    color: BrokaColors.gold,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700))),
                        Text(
                            '${script.aspectRatio} · ${script.durationSeconds}s',
                            style: const TextStyle(
                                color: BrokaColors.textLow, fontSize: 10.5)),
                      ]),
                      const SizedBox(height: 4),
                      Text(script.disclaimer,
                          style: const TextStyle(
                              color: BrokaColors.textMid,
                              fontSize: 10.5,
                              height: 1.35)),
                    ]),
              ),
              const SizedBox(height: 10),
              Text(script.title,
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
              if (script.hook.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Hook: ${script.hook}',
                    style: const TextStyle(
                        color: BrokaColors.textMid, fontSize: 12, height: 1.4)),
              ],
              const SizedBox(height: 10),
              for (var i = 0; i < script.scenes.length; i++)
                Container(
                  key: Key('video-scene-$i'),
                  margin: const EdgeInsets.only(bottom: 7),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: BrokaColors.bgCard.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: BrokaColors.border),
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text('Shot ${i + 1}',
                              style: const TextStyle(
                                  color: _accent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                          const Spacer(),
                          if (script.scenes[i].seconds > 0)
                            Text('${script.scenes[i].seconds}s',
                                style: const TextStyle(
                                    color: BrokaColors.textLow,
                                    fontSize: 10.5)),
                        ]),
                        const SizedBox(height: 3),
                        Text(script.scenes[i].shot,
                            style: const TextStyle(
                                color: BrokaColors.textHigh,
                                fontSize: 12,
                                height: 1.35)),
                        if (script.scenes[i].onScreenText.isNotEmpty)
                          Text('On screen: ${script.scenes[i].onScreenText}',
                              style: const TextStyle(
                                  color: BrokaColors.textMid,
                                  fontSize: 11.5,
                                  height: 1.35)),
                        if (script.scenes[i].voiceOver.isNotEmpty)
                          Text('Voice-over: ${script.scenes[i].voiceOver}',
                              style: const TextStyle(
                                  color: BrokaColors.textMid,
                                  fontSize: 11.5,
                                  height: 1.35)),
                      ]),
                ),
              if (script.caption.isNotEmpty) ...[
                _sectionLabel('Caption'),
                SelectableText(script.captionWithTags,
                    style: const TextStyle(
                        color: BrokaColors.textHigh,
                        fontSize: 12.5,
                        height: 1.45)),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('video-copy-caption'),
                    onPressed: () =>
                        _copy(context, script.captionWithTags, 'Caption'),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('Copy caption'),
                  ),
                ),
              ],
              if (script.voiceOver.isNotEmpty) ...[
                _sectionLabel('Voice-over'),
                SelectableText(script.voiceOver,
                    style: const TextStyle(
                        color: BrokaColors.textMid,
                        fontSize: 12,
                        height: 1.45)),
              ],
              if (script.fallbackReason != null) ...[
                const SizedBox(height: 8),
                Text(script.fallbackReason!,
                    style: const TextStyle(
                        color: BrokaColors.textLow,
                        fontSize: 10.5,
                        height: 1.4)),
              ],
            ],
          ],
        ),
      ),
    );
  }
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

  bool get _needsProduct => _objective == CampaignObjective.product ||
      _objective == CampaignObjective.newStock ||
      _objective == CampaignObjective.discount;

  /// The shapes this campaign's platform actually offers. With several
  /// platforms selected there is no single list - each gets its natural
  /// shape - so the picker only appears for one.
  List<String> get _availableFormats => switch (_platforms.length) {
        1 => switch (_platforms.single) {
            CampaignPlatform.whatsapp => const ['message', 'status'],
            CampaignPlatform.instagram => const ['caption', 'story', 'carousel'],
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
    if (!_wholeStore && _selected.isEmpty) return 'Choose the product or products to promote.';
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
                  if (_format != null && !_availableFormats.contains(_format)) {
                    _format = null;
                  }
                }),
              ),
          ]),
          const SizedBox(height: 6),
          const Text('Each platform gets its own shape and length - not the same copy five times.',
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
    final image = creative.image?.large ?? creative.image?.medium ?? creative.image?.thumb;
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
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Image saved or sent')));
      case CreativeShareOutcome.dismissed:
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nothing was saved.')));
      case CreativeShareOutcome.unconfirmed:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("The sheet closed without confirming a save, so it wasn't counted.")));
      case CreativeShareOutcome.failed:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't get the image ready - copy the caption instead.")));
    }
  }

  /// Hands the written post (with its tracked link) to any app on the phone.
  Future<void> _sharePost(CampaignCreative creative) async {
    final outcome = await widget.share.text(
        _captionWithLink(creative), origin: _shareOrigin());
    if (!mounted) return;
    switch (outcome) {
      case CreativeShareOutcome.shared:
        _record('shared', creative.platform);
      case CreativeShareOutcome.dismissed:
        break;
      case CreativeShareOutcome.unconfirmed:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("The sheet closed without confirming it was sent, so it wasn't counted.")));
      case CreativeShareOutcome.failed:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't open the share sheet - copy the caption instead.")));
    }
  }

  Future<void> _copyLink(MarketingCampaign campaign, String platform) async {
    final link = campaign.linkFor(platform);
    if (link.isEmpty) return;
    // Copying the link proves nothing about where it went; only a share
    // sheet result is recorded.
    await _copy(context, link, 'Campaign link');
  }

  Future<void> _openPlatform(CampaignCreative creative, MarketingCampaign campaign) async {
    final ok = await _openExternal(_composeUrl(creative.platform, _captionWithLink(creative)));
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
            child: Text(creative.formatLabel, style: const TextStyle(color: _accent,
                fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
          ),
          const Spacer(),
          if (ratio != null || duration != null)
            Text([
              if (ratio != null) ratio,
              if (duration != null) '${duration}s',
            ].join(' · '), style: const TextStyle(color: BrokaColors.textLow, fontSize: 11)),
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
        if (scenes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.movie_creation_outlined, size: 15, color: BrokaColors.textMid),
            const SizedBox(width: 6),
            Text('Shot list', style: const TextStyle(color: BrokaColors.textHigh,
                fontSize: 12.5, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          for (var i = 0; i < scenes.length; i++) _SceneRow(index: i, scene: scenes[i]),
          Text('A script and shot list to film yourself - BROKA has not filmed, '
              'published or scheduled anything here.',
              style: const TextStyle(color: BrokaColors.textLow, fontSize: 10.5, height: 1.3)),
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
          Text('Shot ${index + 1}', style: const TextStyle(color: _accent,
              fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
          const Spacer(),
          if (seconds != null)
            Text('${seconds}s', style: const TextStyle(
                color: BrokaColors.textLow, fontSize: 11)),
        ]),
        if (shot.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(shot, style: const TextStyle(color: BrokaColors.textHigh,
              fontSize: 12.5, height: 1.35)),
        ],
        if (onScreen.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text('On screen: $onScreen', style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 11.5, height: 1.35)),
        ],
        if (voice.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text('Voice-over: $voice', style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 11.5, height: 1.35)),
        ],
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
        // Store orders from the campaign's links: requests are buyers
        // asking, not sales, and none of these is a payment BROKA saw.
        if (events.orders case final orders?) ...[
          const SizedBox(height: 10),
          Row(key: const Key('campaign-orders'), children: [
            tile(Icons.receipt_long_outlined, '${orders.requests}', 'Order requests\nfrom links'),
            tile(Icons.task_alt_rounded, '${orders.confirmed}', 'Confirmed\nby buyers'),
            tile(Icons.inventory_2_outlined, '${orders.completed}', 'Received\nby buyers'),
          ]),
        ],
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
