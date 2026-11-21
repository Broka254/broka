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

part 'marketing_studio_components.dart';
part 'marketing_overview_section.dart';
part 'marketing_sidekick_section.dart';
part 'marketing_creative_section.dart';
part 'marketing_ads_section.dart';
part 'marketing_platform_guide_sheet.dart';
part 'marketing_video_script_sheet.dart';
part 'marketing_campaign_builder.dart';
part 'marketing_campaign_detail.dart';

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
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _accent.withOpacity(0.18),
            borderRadius: BorderRadius.circular(12),
          ),
          child:
              const Icon(Icons.auto_awesome_rounded, color: _accent, size: 19),
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
                  fontSize: 10,
                  fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// The four areas as one segmented control rather than a row of filter chips.
///
/// All four stay visible on a narrow phone, so nothing has to be discovered by
/// scrolling sideways, and the selected area is marked three ways (fill, icon,
/// weight) instead of colour alone. This sits inside the store screen's body -
/// it is not a second navigation bar.
class _StudioNav extends StatelessWidget {
  const _StudioNav({required this.section, required this.onSelect});
  final _StudioSection section;
  final ValueChanged<_StudioSection> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.55),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(
          children: [
            for (final item in _StudioSection.values)
              Expanded(
                child: Semantics(
                  selected: item == section,
                  button: true,
                  label: item.label,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: Key('marketing-section-${item.name}'),
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onSelect(item),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOut,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: item == section
                              ? BrokaColors.gold.withOpacity(0.16)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(item.icon,
                                size: 16,
                                color: item == section
                                    ? BrokaColors.gold
                                    : BrokaColors.textMid),
                            const SizedBox(height: 3),
                            Text(item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: item == section
                                        ? BrokaColors.gold
                                        : BrokaColors.textMid,
                                    fontSize: 11,
                                    letterSpacing: -0.1,
                                    fontWeight: item == section
                                        ? FontWeight.w800
                                        : FontWeight.w500)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
