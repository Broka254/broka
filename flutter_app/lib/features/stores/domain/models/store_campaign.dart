// BROKA — AI Marketing Studio models
//
// Mirrors backend/api/domains/stores/marketing.py's `_payload()`. The
// campaign carries the seller's real products (read from their listings on
// the server), generated creatives, a weekly plan and observed counts.
//
// There is deliberately no reach, impressions, spend or revenue field: BROKA
// does not measure those, and a model field for one would invite a screen to
// show it as if it had.
/// Where a campaign can be shared. Limits and shapes live on the server
/// (PLATFORM_SPECS) and are applied to generated copy before it gets here.
enum CampaignPlatform {
  whatsapp('whatsapp', 'WhatsApp', 'Messages and status'),
  instagram('instagram', 'Instagram', 'Feed, stories, reels'),
  tiktok('tiktok', 'TikTok', 'Vertical video'),
  facebook('facebook', 'Facebook', 'Posts and launches'),
  x('x', 'X', 'Short posts');

  const CampaignPlatform(this.value, this.label, this.hint);
  final String value;
  final String label;
  final String hint;

  static CampaignPlatform? parse(Object? value) {
    for (final p in values) {
      if (p.value == value) return p;
    }
    return null;
  }
}

enum CampaignObjective {
  newStore('new_store', 'Introduce my store', 'Tell people the shop exists'),
  product('product', 'Promote a product', 'One product, front and centre'),
  newStock('new_stock', 'Announce new stock', 'What just arrived'),
  discount('discount', 'Promote a real discount', 'You state the discount'),
  awareness('awareness', 'Build brand awareness', 'Get the name known'),
  seasonal('seasonal', 'Seasonal offer', 'A holiday or season'),
  storefront('storefront', 'Visit my storefront', 'Bring buyers to the shop'),
  enquiries('enquiries', 'Get enquiries', 'Start conversations');

  const CampaignObjective(this.value, this.label, this.hint);
  final String value;
  final String label;
  final String hint;

  static CampaignObjective parse(Object? value) {
    for (final o in values) {
      if (o.value == value) return o;
    }
    return CampaignObjective.product;
  }
}

enum CampaignTone {
  friendly('friendly', 'Friendly'),
  professional('professional', 'Professional'),
  bold('bold', 'Bold'),
  playful('playful', 'Playful'),
  premium('premium', 'Premium');

  const CampaignTone(this.value, this.label);
  final String value;
  final String label;

  static CampaignTone parse(Object? value) {
    for (final t in values) {
      if (t.value == value) return t;
    }
    return CampaignTone.friendly;
  }
}

/// English or Kiswahili, as the seller's customers speak.
class CampaignLanguage {
  static const en = 'en';
  static const sw = 'sw';
  static const values = [en, sw];
  static String label(String value) => value == sw ? 'Kiswahili' : 'English';
}

/// A product as the studio's payload carries it: the facts the server read
/// from the seller's listing, not a full Listing row. Prices here are the
/// server's, and the seller's app never sends one back as truth.
class CampaignProduct {
  final String id;
  final String name;
  final double? price;
  final String? priceUnit;
  final String? description;
  final String? category;
  final String? condition;
  final String? brand;
  final ({String? thumb, String? medium, String? large})? image;

  const CampaignProduct({
    required this.id,
    required this.name,
    this.price,
    this.priceUnit,
    this.description,
    this.category,
    this.condition,
    this.brand,
    this.image,
  });

  static CampaignProduct fromJson(Map<String, dynamic> json) {
    final asset = json['image'];
    ({String? thumb, String? medium, String? large})? image;
    if (asset is Map) {
      image = (
        thumb: asset['thumb'] as String?,
        medium: asset['medium'] as String?,
        large: asset['large'] as String?,
      );
    }
    return CampaignProduct(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      price: (json['price'] as num?)?.toDouble(),
      priceUnit: json['price_unit'] as String?,
      description: json['description'] as String?,
      category: json['category'] as String?,
      condition: json['condition'] as String?,
      brand: json['brand'] as String?,
      image: image,
    );
  }
}

class CampaignCreative {
  final String id;
  final String platform;
  final String format;
  final String headline;
  final String body;
  final List<String> hashtags;
  final String cta;

  /// Layout hints the studio can render: aspect_ratio, template, slides,
  /// scenes, duration_seconds. They describe a design, not a file.
  final Map<String, dynamic> media;
  final ({String? thumb, String? medium, String? large})? image;
  final String source; // "ai" | "template"

  const CampaignCreative({
    required this.id,
    required this.platform,
    required this.format,
    required this.headline,
    required this.body,
    required this.hashtags,
    required this.cta,
    required this.media,
    this.image,
    this.source = 'template',
  });

  static CampaignCreative fromJson(Map<String, dynamic> json) {
    final asset = json['asset'];
    ({String? thumb, String? medium, String? large})? image;
    if (asset is Map) {
      image = (
        thumb: asset['thumb'] as String?,
        medium: asset['medium'] as String?,
        large: asset['large'] as String?,
      );
    }
    return CampaignCreative(
      id: json['id'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      format: json['format'] as String? ?? '',
      headline: json['headline'] as String? ?? '',
      body: json['body'] as String? ?? '',
      hashtags: (json['hashtags'] as List?)?.whereType<String>().toList() ?? const [],
      cta: json['cta'] as String? ?? '',
      media: (json['media'] as Map?)?.cast<String, dynamic>() ?? const {},
      image: image,
      source: json['source'] as String? ?? 'template',
    );
  }

  /// The platform's own name, for a label. Falls back to the raw value so a
  /// new platform the app hasn't learned yet still shows something true.
  String get platformLabel => CampaignPlatform.parse(platform)?.label ?? platform;

  /// "Instagram caption", "TikTok script" - a script is named a script.
  String get formatLabel => format.isEmpty ? platformLabel : '$platformLabel $format';

  String get caption => [
        if (body.trim().isNotEmpty) body.trim(),
        if (hashtags.isNotEmpty) hashtags.map((t) => '#$t').join(' '),
      ].join('\n\n');
}

/// A day in the suggested week. Nothing here has been posted or scheduled:
/// BROKA has no publishing integration in this release.
class CampaignPlanItem {
  final String day;
  final String? platform;
  final String? format;
  final String? product;
  final String? note;

  const CampaignPlanItem({required this.day, this.platform, this.format, this.product, this.note});

  static CampaignPlanItem fromJson(Map<String, dynamic> json) => CampaignPlanItem(
        day: (json['day'] ?? json['when'] ?? '').toString(),
        platform: json['platform'] as String?,
        format: json['format'] as String?,
        product: json['product'] as String?,
        note: (json['note'] ?? json['idea'] ?? json['tip']) as String?,
      );
}

class CampaignEvents {
  final Map<String, int> byKind;
  final Map<String, int> byPlatform;
  final List<String> measured;
  final List<String> notMeasured;

  const CampaignEvents({
    this.byKind = const {},
    this.byPlatform = const {},
    this.measured = const [],
    this.notMeasured = const [],
  });

  static CampaignEvents fromJson(Object? value) {
    if (value is! Map) return const CampaignEvents();
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    return CampaignEvents(
      byKind: (value['by_kind'] as Map?)
              ?.map((k, v) => MapEntry(k.toString(), n(v))) ??
          const {},
      byPlatform: (value['by_platform'] as Map?)
              ?.map((k, v) => MapEntry(k.toString(), n(v))) ??
          const {},
      measured: (value['measured'] as List?)?.whereType<String>().toList() ?? const [],
      notMeasured:
          (value['not_measured'] as List?)?.whereType<String>().toList() ?? const [],
    );
  }

  int get downloads => byKind['downloaded'] ?? 0;
  int get shares => byKind['shared'] ?? 0;
  int get visits => byKind['visit'] ?? 0;
  int get productViews => byKind['product_view'] ?? 0;
}

class MarketingCampaign {
  final String id;
  final String title;
  final String objective;
  final String? audience;
  final String tone;
  final String language;
  final String? instructions;
  final List<String> productIds;
  final List<CampaignProduct> products;
  final List<String> platforms;
  final String status;
  final String linkToken;

  /// Platform -> tracked storefront link carrying this campaign's token.
  final Map<String, String> links;
  final String storeUrl;
  final List<CampaignCreative> creatives;
  final List<CampaignPlanItem> plan;
  final CampaignEvents events;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// "ai" | "template" and why, when it fell back. Shown to the seller so a
  /// template-written campaign is never passed off as model output.
  final Map<String, dynamic> generation;

  const MarketingCampaign({
    required this.id,
    required this.title,
    required this.objective,
    this.audience,
    this.tone = 'friendly',
    this.language = 'en',
    this.instructions,
    this.productIds = const [],
    this.products = const [],
    this.platforms = const [],
    this.status = 'draft',
    this.linkToken = '',
    this.links = const {},
    this.storeUrl = '',
    this.creatives = const [],
    this.plan = const [],
    this.events = const CampaignEvents(),
    this.createdAt,
    this.updatedAt,
    this.generation = const {},
  });

  static MarketingCampaign fromJson(Map<String, dynamic> json) => MarketingCampaign(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        objective: json['objective'] as String? ?? 'product',
        audience: json['audience'] as String?,
        tone: json['tone'] as String? ?? 'friendly',
        language: json['language'] as String? ?? 'en',
        instructions: json['instructions'] as String?,
        productIds:
            (json['product_ids'] as List?)?.whereType<String>().toList() ?? const [],
        products: [
          for (final p in json['products'] as List? ?? const [])
            if (p is Map) CampaignProduct.fromJson(p.cast<String, dynamic>()),
        ],
        platforms: (json['platforms'] as List?)?.whereType<String>().toList() ?? const [],
        status: json['status'] as String? ?? 'draft',
        linkToken: json['link_token'] as String? ?? '',
        links: (json['links'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            const {},
        storeUrl: json['store_url'] as String? ?? '',
        creatives: [
          for (final c in json['creatives'] as List? ?? const [])
            CampaignCreative.fromJson(c as Map<String, dynamic>),
        ],
        plan: [
          for (final p in json['plan'] as List? ?? const [])
            if (p is Map) CampaignPlanItem.fromJson(p.cast<String, dynamic>()),
        ],
        events: CampaignEvents.fromJson(json['events']),
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
        generation: (json['generation'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  String get titleOrObjective {
    if (title.trim().isNotEmpty) return title.trim();
    return CampaignObjective.parse(objective).label;
  }

  bool get isAiGenerated => generation['provider'] != null &&
      generation['provider'] != 'template' &&
      generation['fallback'] != true;

  /// Why a template campaign was written instead of by the model, when the
  /// server said so. Null when the model wrote it or no reason was given.
  String? get fallbackReason => generation['reason'] as String?;

  CampaignCreative? creativeFor(String platform) =>
      creatives.where((c) => c.platform == platform).firstOrNull;

  /// The tracked link for a platform, or the campaign's store link. Only an
  /// http(s) URL is returned - a payload without one is a blank link, not a
  /// broken one to share.
  String linkFor(String platform) {
    final link = links[platform] ?? storeUrl;
    return link.startsWith('http') ? link : '';
  }
}

/// One suggestion from the Smart product copywriter. Nothing is written to
/// the listing: the seller copies or applies it through the normal editor.
class CopySuggestion {
  final String text;

  /// Why the model changed what it did, in one sentence, when it said.
  final String? why;

  const CopySuggestion({required this.text, this.why});

  static CopySuggestion fromJson(Map<String, dynamic> json) => CopySuggestion(
        text: (json['text'] ?? json['suggestion'] ?? json['copy'] ?? '').toString(),
        why: json['why'] as String?,
      );
}

/// The copywriter's answer. [available] false means the server has no AI
/// provider configured - an honest state, with the listing untouched.
class CopySuggestions {
  final String field;
  final String language;
  final bool available;
  final String? message;
  final String? provider;
  final List<CopySuggestion> items;

  const CopySuggestions({
    required this.field,
    this.language = 'en',
    this.available = false,
    this.message,
    this.provider,
    this.items = const [],
  });

  static CopySuggestions fromJson(Map<String, dynamic> json) => CopySuggestions(
        field: json['field'] as String? ?? '',
        language: json['language'] as String? ?? 'en',
        available: json['available'] as bool? ?? false,
        message: json['message'] as String?,
        provider: json['provider'] as String?,
        items: [
          for (final s in json['suggestions'] as List? ?? const [])
            if (s is Map) CopySuggestion.fromJson(s.cast<String, dynamic>()),
        ],
      );
}
