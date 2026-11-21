// BROKA — AI Marketing Sidekick models.
//
// Mirrors backend/api/domains/stores/marketing_sidekick.py. Everything here
// is reading-side data: the Sidekick's answer, a platform playbook, a video
// script or a Meta Ads checklist. None of it is a record that something was
// posted, published or paid for.
//
// The honesty rules the payload carries are kept in the models rather than
// dropped at the edge: [SidekickReply.available] separates a model answer from
// BROKA's own guidance, [VideoScript.isVideo] is always false, and
// [AdsPlan.campaignCreated] is always false. A screen that ignored them would
// be lying with data the server never sent.
import 'package:flutter/foundation.dart';

typedef MarketingAssetImage = ({String? thumb, String? medium, String? large});

MarketingAssetImage? _imageFrom(Object? value) {
  if (value is! Map) return null;
  return (
    thumb: value['thumb'] as String?,
    medium: value['medium'] as String?,
    large: value['large'] as String?,
  );
}

List<String> _strings(Object? value) =>
    (value as List?)?.whereType<String>().toList() ?? const [];

/// A product the Sidekick referred to, as the server read it from the
/// seller's own listing. There is no editable price field: the screen never
/// sends one back as truth.
@immutable
class SidekickProduct {
  final String id;
  final String name;
  final double? price;
  final String? priceLabel;
  final MarketingAssetImage? image;

  const SidekickProduct({
    required this.id,
    required this.name,
    this.price,
    this.priceLabel,
    this.image,
  });

  static SidekickProduct fromJson(Map<String, dynamic> json) => SidekickProduct(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        price: (json['price'] as num?)?.toDouble(),
        priceLabel: json['price_label'] as String?,
        image: _imageFrom(json['image']),
      );
}

/// A real tool the Sidekick can open with the same context already chosen.
/// Nothing is created until the seller acts in that tool.
@immutable
class SidekickAction {
  final String
      type; // creative_studio | platform_guide | video_script | meta_ads
  final String label;
  final String description;
  final String? platform;
  final String? productId;
  final String? objective;
  final String? creativeFormat;

  const SidekickAction({
    required this.type,
    required this.label,
    this.description = '',
    this.platform,
    this.productId,
    this.objective,
    this.creativeFormat,
  });

  static SidekickAction fromJson(Map<String, dynamic> json) => SidekickAction(
        type: json['type'] as String? ?? '',
        label: json['label'] as String? ?? '',
        description: json['description'] as String? ?? '',
        platform: json['platform'] as String?,
        productId: json['product_id'] as String?,
        objective: json['objective'] as String?,
        creativeFormat: json['creative_format'] as String?,
      );
}

class SidekickReply {
  final String reply;
  final String provider;

  /// False when the reply is BROKA's deterministic guidance rather than a
  /// model's answer. The screen says which, so a fallback is never passed
  /// off as AI.
  final bool available;
  final String? fallbackReason;
  final String? platform;
  final List<SidekickProduct> products;
  final List<SidekickAction> actions;
  final List<String> suggestions;

  const SidekickReply({
    required this.reply,
    this.provider = 'template',
    this.available = false,
    this.fallbackReason,
    this.platform,
    this.products = const [],
    this.actions = const [],
    this.suggestions = const [],
  });

  static SidekickReply fromJson(Map<String, dynamic> json) => SidekickReply(
        reply: json['reply'] as String? ?? '',
        provider: json['provider'] as String? ?? 'template',
        available: json['available'] as bool? ?? false,
        fallbackReason: json['fallback_reason'] as String?,
        platform: json['platform'] as String?,
        products: [
          for (final p in json['products'] as List? ?? const [])
            if (p is Map) SidekickProduct.fromJson(p.cast<String, dynamic>()),
        ],
        actions: [
          for (final a in json['actions'] as List? ?? const [])
            if (a is Map) SidekickAction.fromJson(a.cast<String, dynamic>()),
        ],
        suggestions: _strings(json['suggestions']),
      );
}

class GuideFormat {
  final String value;
  final String label;
  final String tip;

  const GuideFormat({required this.value, required this.label, this.tip = ''});

  static GuideFormat fromJson(Map<String, dynamic> json) => GuideFormat(
        value: json['value'] as String? ?? '',
        label: json['label'] as String? ?? '',
        tip: json['tip'] as String? ?? '',
      );
}

class GuideSection {
  final String key;
  final String title;
  final String summary;
  final List<String> steps;

  const GuideSection({
    required this.key,
    required this.title,
    this.summary = '',
    this.steps = const [],
  });

  static GuideSection fromJson(Map<String, dynamic> json) => GuideSection(
        key: json['key'] as String? ?? '',
        title: json['title'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        steps: _strings(json['steps']),
      );
}

/// A caption starter built from one live product. It is a starting point the
/// seller edits - not a generated campaign.
class GuideExample {
  final String label;
  final String body;
  final List<String> hashtags;
  final String cta;
  final String note;

  const GuideExample({
    required this.label,
    required this.body,
    this.hashtags = const [],
    this.cta = '',
    this.note = '',
  });

  static GuideExample fromJson(Map<String, dynamic> json) => GuideExample(
        label: json['label'] as String? ?? '',
        body: json['body'] as String? ?? '',
        hashtags: _strings(json['hashtags']),
        cta: json['cta'] as String? ?? '',
        note: json['note'] as String? ?? '',
      );

  String get shareable => [
        body.trim(),
        if (hashtags.isNotEmpty) hashtags.map((t) => '#$t').join(' '),
      ].where((s) => s.isNotEmpty).join('\n\n');
}

class PlatformGuide {
  final String platform;
  final String label;
  final String summary;
  final String bestFor;
  final List<GuideFormat> formats;
  final List<GuideSection> sections;
  final SidekickProduct? product;
  final GuideExample? example;
  final List<SidekickAction> actions;
  final String note;

  const PlatformGuide({
    required this.platform,
    required this.label,
    this.summary = '',
    this.bestFor = '',
    this.formats = const [],
    this.sections = const [],
    this.product,
    this.example,
    this.actions = const [],
    this.note = '',
  });

  static PlatformGuide fromJson(Map<String, dynamic> json) => PlatformGuide(
        platform: json['platform'] as String? ?? '',
        label: json['label'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        bestFor: json['best_for'] as String? ?? '',
        formats: [
          for (final f in json['formats'] as List? ?? const [])
            if (f is Map) GuideFormat.fromJson(f.cast<String, dynamic>()),
        ],
        sections: [
          for (final s in json['sections'] as List? ?? const [])
            if (s is Map) GuideSection.fromJson(s.cast<String, dynamic>()),
        ],
        product: json['product'] is Map
            ? SidekickProduct.fromJson(
                (json['product'] as Map).cast<String, dynamic>())
            : null,
        example: json['example'] is Map
            ? GuideExample.fromJson(
                (json['example'] as Map).cast<String, dynamic>())
            : null,
        actions: [
          for (final a in json['actions'] as List? ?? const [])
            if (a is Map) SidekickAction.fromJson(a.cast<String, dynamic>()),
        ],
        note: json['note'] as String? ?? '',
      );
}

class VideoScene {
  final String shot;
  final String onScreenText;
  final String voiceOver;
  final int seconds;

  const VideoScene({
    required this.shot,
    this.onScreenText = '',
    this.voiceOver = '',
    this.seconds = 0,
  });

  static VideoScene fromJson(Map<String, dynamic> json) => VideoScene(
        shot: json['shot'] as String? ?? '',
        onScreenText: json['on_screen_text'] as String? ?? '',
        voiceOver: json['voice_over'] as String? ?? '',
        seconds: (json['seconds'] as num?)?.toInt() ?? 0,
      );
}

/// A concept, script or storyboard to film - never a video file.
class VideoScript {
  final String platform;
  final String kind;
  final String label;
  final bool isVideo;
  final String disclaimer;
  final String title;
  final String hook;
  final int durationSeconds;
  final String aspectRatio;
  final List<VideoScene> scenes;
  final String voiceOver;
  final String caption;
  final List<String> hashtags;
  final String cta;
  final String provider;
  final String? fallbackReason;

  const VideoScript({
    required this.platform,
    required this.kind,
    required this.label,
    required this.title,
    this.isVideo = false,
    this.disclaimer = '',
    this.hook = '',
    this.durationSeconds = 0,
    this.aspectRatio = '9:16',
    this.scenes = const [],
    this.voiceOver = '',
    this.caption = '',
    this.hashtags = const [],
    this.cta = '',
    this.provider = 'template',
    this.fallbackReason,
  });

  static VideoScript fromJson(Map<String, dynamic> json) => VideoScript(
        platform: json['platform'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        label: json['label'] as String? ?? 'Video script',
        title: json['title'] as String? ?? '',
        isVideo: json['is_video'] as bool? ?? false,
        disclaimer: json['disclaimer'] as String? ?? '',
        hook: json['hook'] as String? ?? '',
        durationSeconds: (json['duration_seconds'] as num?)?.toInt() ?? 0,
        aspectRatio: json['aspect_ratio'] as String? ?? '9:16',
        scenes: [
          for (final s in json['scenes'] as List? ?? const [])
            if (s is Map) VideoScene.fromJson(s.cast<String, dynamic>()),
        ],
        voiceOver: json['voice_over'] as String? ?? '',
        caption: json['caption'] as String? ?? '',
        hashtags: _strings(json['hashtags']),
        cta: json['cta'] as String? ?? '',
        provider: json['provider'] as String? ?? 'template',
        fallbackReason: json['fallback_reason'] as String?,
      );

  String get captionWithTags => [
        caption.trim(),
        if (hashtags.isNotEmpty) hashtags.map((t) => '#$t').join(' '),
      ].where((s) => s.isNotEmpty).join('\n\n');
}

class AdsObjectiveOption {
  final String value;
  final String label;
  final String when;

  const AdsObjectiveOption(
      {required this.value, required this.label, this.when = ''});

  static AdsObjectiveOption fromJson(Map<String, dynamic> json) =>
      AdsObjectiveOption(
        value: json['value'] as String? ?? '',
        label: json['label'] as String? ?? '',
        when: json['when'] as String? ?? '',
      );
}

class AdsBudget {
  final int dailyKes;
  final int trialDays;
  final int totalKes;
  final String note;

  const AdsBudget({
    required this.dailyKes,
    this.trialDays = 5,
    this.totalKes = 0,
    this.note = '',
  });

  static AdsBudget fromJson(Map<String, dynamic> json) => AdsBudget(
        dailyKes: (json['daily_kes'] as num?)?.toInt() ?? 0,
        trialDays: (json['trial_days'] as num?)?.toInt() ?? 5,
        totalKes: (json['total_kes'] as num?)?.toInt() ?? 0,
        note: json['note'] as String? ?? '',
      );
}

class AdsStage {
  final String key;
  final String title;
  final String summary;
  final String suggestion;
  final List<String> steps;

  const AdsStage({
    required this.key,
    required this.title,
    this.summary = '',
    this.suggestion = '',
    this.steps = const [],
  });

  static AdsStage fromJson(Map<String, dynamic> json) => AdsStage(
        key: json['key'] as String? ?? '',
        title: json['title'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        suggestion:
            json['suggestion'] is String ? json['suggestion'] as String : '',
        steps: _strings(json['steps']),
      );
}

/// A checklist the seller completes in Meta Ads Manager. Never a campaign
/// BROKA created: [campaignCreated] is false and stays false.
class AdsPlan {
  final String? productName;
  final String? priceLabel;
  final String currency;
  final String objective;
  final String objectiveLabel;
  final List<AdsObjectiveOption> objectiveOptions;
  final String audience;
  final String location;
  final AdsBudget budget;
  final List<AdsStage> stages;
  final String managerUrl;
  final bool campaignCreated;
  final String disclaimer;

  const AdsPlan({
    this.productName,
    this.priceLabel,
    this.currency = 'KES',
    this.objective = 'traffic',
    this.objectiveLabel = '',
    this.objectiveOptions = const [],
    this.audience = '',
    this.location = '',
    this.budget = const AdsBudget(dailyKes: 0),
    this.stages = const [],
    this.managerUrl = '',
    this.campaignCreated = false,
    this.disclaimer = '',
  });

  static AdsPlan fromJson(Map<String, dynamic> json) => AdsPlan(
        productName: (json['product'] as Map?)?['name'] as String?,
        priceLabel: (json['product'] as Map?)?['price_label'] as String?,
        currency: json['currency'] as String? ?? 'KES',
        objective: json['objective'] as String? ?? 'traffic',
        objectiveLabel: json['objective_label'] as String? ?? '',
        objectiveOptions: [
          for (final o in json['objective_options'] as List? ?? const [])
            if (o is Map)
              AdsObjectiveOption.fromJson(o.cast<String, dynamic>()),
        ],
        audience: json['audience'] as String? ?? '',
        location: json['location'] as String? ?? '',
        budget: json['budget'] is Map
            ? AdsBudget.fromJson(
                (json['budget'] as Map).cast<String, dynamic>())
            : const AdsBudget(dailyKes: 0),
        stages: [
          for (final s in json['stages'] as List? ?? const [])
            if (s is Map) AdsStage.fromJson(s.cast<String, dynamic>()),
        ],
        managerUrl: json['manager_url'] as String? ?? '',
        campaignCreated: json['campaign_created'] as bool? ?? false,
        disclaimer: json['disclaimer'] as String? ?? '',
      );
}
