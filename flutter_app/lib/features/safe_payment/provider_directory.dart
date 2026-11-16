// The escrow providers BROKA lists, as the server describes them
// (GET /escrow-providers/compare, backend api/domains/escrow_directory).
//
// THE SERVER COMPUTES, THE APP SHOWS. Fee estimates, the wording for an
// unpublished fee, how current each provider's information is, whether a
// ranking may be claimed - all decided on the server, once, and tested there
// in plain Python. This file only reads that answer and keeps it honest on the
// way: a field the server left out is null here and "Not documented" on screen,
// never a guess; a provider whose address is not on its own website is dropped
// (isOfficialUrl) rather than shown with a warning.
//
// There is no list of providers in the app any more (2026-11). It used to
// carry one for when the server could not be reached; that list named a
// provider BROKA has since suspended, and no release can take a name back off
// a phone that does not update. Offline, the app shows its last saved copy
// with the date it was fetched and, past a limit, nothing (CachePolicies).

/// The notice BROKA must show wherever it shows a provider. The server sends
/// it with every response; this is the copy used when none has arrived (an
/// old saved response), so the screen is never without it. A test pins it to
/// the owner's wording.
const String kRequiredNotice =
    "Broka does not operate these escrow services and does not hold, receive or release your "
    "money. The services are provided independently by their respective operators. Broka does "
    "not guarantee their performance or independently control their funds. Review the "
    "provider's current fees, conditions, refund policy and dispute procedures before paying.";

const List<String> kDisclosurePoints = [
  'Each provider has its own terms and privacy policy. Read them before you use it.',
  'When you use a provider you enter into a separate agreement with it, not with Broka.',
  "A provider's protection applies only according to that provider's own rules.",
  'Broka cannot guarantee that a dispute will end in a refund.',
  "Open the provider's official website yourself, or follow Broka's exact approved https "
      'link. Never use a link, paybill, till or phone number someone sends you in a chat.',
];

/// Whether [url] is an https address on exactly [domain] (or www.[domain]):
/// the same rule as the server's links.official_url. Exact host match, never
/// "ends with"; no user-info, no odd port, no punycode.
bool isOfficialUrl(Object? url, Object? domain) {
  if (url is! String || domain is! String || url.length > 300) return false;
  if (!RegExp(r'^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,23}$')
      .hasMatch(domain)) {
    return false;
  }
  if (domain.startsWith('www.') || domain.split('.').any((l) => l.startsWith('xn--'))) return false;
  if (RegExp('[\\s\\\\<>"\'`\\u0000-\\u001f\\u007f]').hasMatch(url)) return false;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) return false;
  if (uri.hasPort && uri.port != 443) return false;
  return uri.host == domain || uri.host == 'www.$domain';
}

String _s(Object? v) => v is String ? v.trim() : '';
String? _sn(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
int? _i(Object? v) => v is int ? v : (v is num && v == v.truncate() ? v.toInt() : null);
List<String> _ss(Object? v) => v is List ? [for (final x in v) if (x is String && x.trim().isNotEmpty) x.trim()] : const [];
Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

/// How current something is, as the server judged it. [state] is
/// "current", "expired" or "unverified"; only "current" is good news.
class Freshness {
  const Freshness({required this.state, required this.label, this.verifiedOn, this.expiresOn, this.warning});

  final String state;
  final String label;
  final String? verifiedOn;
  final String? expiresOn;
  final String? warning;

  bool get isCurrent => state == 'current';

  factory Freshness.fromJson(Object? json) {
    final j = _m(json);
    final state = _s(j['state']);
    return Freshness(
      // An unknown or missing state is "unverified": never current by default.
      state: const {'current', 'expired', 'unverified'}.contains(state) ? state : 'unverified',
      label: _sn(j['label']) ?? 'Not yet verified by BROKA',
      verifiedOn: _sn(j['verified_on']),
      expiresOn: _sn(j['expires_on']) ?? _sn(j['next_review']),
      warning: _sn(j['warning']),
    );
  }
}

/// One charge in an estimate, as the server calculated it.
class FeeLine {
  const FeeLine({required this.label, required this.status, this.amount, this.note = '', this.estimated = false});

  final String label;
  final String status; // calculated | not_available | out_of_range
  final int? amount;
  final String note;
  final bool estimated;

  factory FeeLine.fromJson(Object? json) {
    final j = _m(json);
    final percent = _i(j['percent_part']);
    final fixed = _i(j['fixed_part']);
    return FeeLine(
      label: _sn(j['label']) ?? 'Charge',
      status: _s(j['status']),
      amount: percent == null && fixed == null ? null : (percent ?? 0) + (fixed ?? 0),
      note: _s(j['note']),
      estimated: j['estimated'] == true,
    );
  }
}

/// What the buyer would pay so that the seller receives [sellerReceives].
/// Every figure is null unless the server could calculate it from the
/// provider's published pricing; [message] says why not.
class FeeEstimate {
  const FeeEstimate({
    required this.status,
    required this.sellerReceives,
    required this.message,
    this.commission,
    this.fixedCharges,
    this.otherCharges,
    this.otherNote = '',
    this.totalBuyerPayment,
    this.effectivePercent,
    this.lines = const [],
    this.assumptions = const [],
    this.needsPayoutDestination = false,
    this.comparable = false,
    this.includesEstimatedCharges = false,
  });

  /// estimated | partial | unavailable | out_of_range | invalid_amount
  final String status;
  final int sellerReceives;
  final String message;
  final int? commission;
  final int? fixedCharges;
  final int? otherCharges;
  final String otherNote;
  final int? totalBuyerPayment;
  final double? effectivePercent;
  final List<FeeLine> lines;
  final List<String> assumptions;
  final bool needsPayoutDestination;
  final bool comparable;
  final bool includesEstimatedCharges;

  /// A total exists: only when every charge was calculated.
  bool get hasTotal => status == 'estimated' && totalBuyerPayment != null;

  factory FeeEstimate.fromJson(Object? json) {
    final j = _m(json);
    final pct = j['effective_fee_percent'];
    return FeeEstimate(
      status: _s(j['status']),
      sellerReceives: _i(j['seller_receives']) ?? 0,
      message: _s(j['message']),
      commission: _i(j['commission']),
      fixedCharges: _i(j['fixed_charges']),
      otherCharges: _i(j['mpesa_or_payout_charges']),
      otherNote: _s(j['mpesa_or_payout_note']),
      totalBuyerPayment: _i(j['total_buyer_payment']),
      effectivePercent: pct is num ? pct.toDouble() : null,
      lines: j['lines'] is List ? [for (final l in j['lines'] as List) FeeLine.fromJson(l)] : const [],
      assumptions: _ss(j['assumptions']),
      needsPayoutDestination: j['needs_payout_destination'] == true,
      comparable: j['comparable'] == true,
      includesEstimatedCharges: j['includes_estimated_charges'] == true,
    );
  }
}

/// A document the app can read: a labelled source reference.
class SourceRef {
  const SourceRef(this.label, this.url);
  final String label;
  final String url;
}

class NotToBeConfused {
  const NotToBeConfused(this.name, this.domain);
  final String name;
  final String domain;
  String get text => 'Not the same company as $name ($domain).';
}

class EscrowListing {
  const EscrowListing({
    required this.id,
    required this.name,
    required this.status,
    required this.reviewLabel,
    required this.websiteUrl,
    required this.domain,
    required this.feeSummary,
    required this.pricingFreshness,
    required this.recordFreshness,
    required this.warnings,
    required this.summaries,
    required this.json,
    this.tagline,
    this.estimate,
    this.notToBeConfusedWith = const [],
    this.undocumented = const [],
    this.sources = const [],
    this.publicNotice,
  });

  final String id;
  final String name;
  final String? tagline;

  /// approved | under_review (only these are ever listed)
  final String status;
  final String reviewLabel;
  final String websiteUrl;
  final String domain;
  final String feeSummary;
  final Freshness pricingFreshness;
  final Freshness recordFreshness;
  final List<String> warnings;
  final Map<String, String> summaries;
  final FeeEstimate? estimate;
  final List<NotToBeConfused> notToBeConfusedWith;
  final List<String> undocumented;
  final List<SourceRef> sources;
  final String? publicNotice;

  /// The whole record as the server sent it, for the detail screen's
  /// sections. Read only through the accessors below.
  final Map<String, dynamic> json;

  bool get isReviewed => status == 'approved';

  /// Whether to show a warning banner: not reviewed, or out of date.
  bool get needsWarning => !isReviewed || !pricingFreshness.isCurrent || warnings.isNotEmpty;

  String get site => websiteUrl.replaceFirst(RegExp(r'^https?://(www\.)?'), '').replaceFirst(RegExp(r'/$'), '');

  Map<String, dynamic> get identity => _m(json['identity']);
  Map<String, dynamic> get pricing => _m(json['pricing']);
  Map<String, dynamic> get conditions => _m(json['conditions']);
  Map<String, dynamic> get protection => _m(json['protection']);
  Map<String, dynamic> get trust => _m(json['trust']);

  /// The provider's own words for [key] in its protection section, or null:
  /// the screen says "Not documented" for a null, never a placeholder fact.
  String? protectionText(String key) => _sn(protection[key]);

  /// null when the provider cannot be shown safely: no id or name, a status
  /// other than a listed one, or a website that is not on its own domain.
  static EscrowListing? tryParse(Object? raw) {
    final j = _m(raw);
    final id = _sn(j['id']);
    final name = _sn(j['name']);
    final domain = _sn(j['canonical_domain']);
    final status = _s(j['status']);
    final url = j['website_url'];
    if (id == null || name == null || (status != 'approved' && status != 'under_review')) return null;
    if (!isOfficialUrl(url, domain)) return null;
    final fresh = _m(j['freshness']);
    final summaries = <String, String>{
      for (final e in _m(j['summaries']).entries)
        if (e.value is String) e.key: (e.value as String).trim(),
    };
    return EscrowListing(
      id: id,
      name: name,
      tagline: _sn(j['tagline']),
      status: status,
      reviewLabel: _sn(j['review_label']) ?? (status == 'approved' ? 'Reviewed by Broka' : 'Under review'),
      websiteUrl: url as String,
      domain: domain!,
      feeSummary: _sn(j['fee_summary']) ?? 'Pricing under review – confirm before paying',
      pricingFreshness: Freshness.fromJson(fresh['pricing']),
      recordFreshness: Freshness.fromJson(fresh['record']),
      warnings: _ss(fresh['warnings']),
      summaries: summaries,
      estimate: j['estimate'] is Map ? FeeEstimate.fromJson(j['estimate']) : null,
      notToBeConfusedWith: [
        for (final c in (j['not_to_be_confused_with'] is List ? j['not_to_be_confused_with'] as List : const []))
          if (c is Map && _sn(c['name']) != null && _sn(c['domain']) != null)
            NotToBeConfused(_s(c['name']), _s(c['domain'])),
      ],
      undocumented: _ss(j['undocumented']),
      sources: [
        for (final s in (j['sources'] is List ? j['sources'] as List : const []))
          if (s is Map && _sn(s['label']) != null && isOfficialUrl(s['url'], domain))
            SourceRef(_s(s['label']), _s(s['url'])),
      ],
      publicNotice: _sn(j['public_notice']),
      json: j,
    );
  }
}

/// A provider BROKA does not list, with what it chose to say about it.
class ProviderNotice {
  const ProviderNotice(this.name, this.domain, this.message);
  final String name;
  final String domain;
  final String message;
}

/// What the server said about which provider is cheapest - or that it will not say.
class Ranking {
  const Ranking({required this.claimAllowed, required this.headline, this.rankedIds = const [], this.notRanked = const {}});

  final bool claimAllowed;
  final String headline;
  final List<String> rankedIds;

  /// provider id -> why it is not in the ranking.
  final Map<String, String> notRanked;

  static Ranking? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    return Ranking(
      claimAllowed: j['claim_allowed'] == true,
      headline: _s(j['headline']),
      rankedIds: [for (final r in (j['ranked'] is List ? j['ranked'] as List : const [])) _s(_m(r)['id'])],
      notRanked: {
        for (final n in (j['not_ranked'] is List ? j['not_ranked'] as List : const []))
          _s(_m(n)['id']): _s(_m(n)['reason']),
      },
    );
  }
}

class Excluded {
  const Excluded(this.id, this.name, this.reason);
  final String id;
  final String name;
  final String reason;
}

/// The server's whole answer, plus when this copy of it was fetched.
class ProviderDirectory {
  const ProviderDirectory({
    required this.providers,
    required this.notices,
    required this.notice,
    required this.points,
    required this.fetchedAt,
    this.excluded = const [],
    this.ranking,
    this.estimateNote = '',
    this.fromCache = false,
  });

  final List<EscrowListing> providers;
  final List<ProviderNotice> notices;

  /// The required "Broka does not operate these services" text.
  final String notice;
  final List<String> points;
  final List<Excluded> excluded;
  final Ranking? ranking;
  final String estimateNote;

  /// When this copy came from the server. Shown beside anything read from the
  /// phone's saved copy, so an old answer never reads as today's.
  final DateTime fetchedAt;
  final bool fromCache;

  /// A saved copy more than this old is shown with a warning (it is never
  /// older than CachePolicies.escrowProviders.keepFor: older is discarded).
  static const staleAfter = Duration(hours: 6);

  bool isStale(DateTime now) => fromCache && now.difference(fetchedAt) > staleAfter;

  ProviderDirectory asCached() => ProviderDirectory(
        providers: providers, notices: notices, notice: notice, points: points, fetchedAt: fetchedAt,
        excluded: excluded, ranking: ranking, estimateNote: estimateNote, fromCache: true,
      );

  static ProviderDirectory? tryParse(Object? raw, {required DateTime fetchedAt}) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final listKey = j['results'] is List ? 'results' : 'providers';
    if (j[listKey] is! List) return null;
    final disclosures = _m(j['disclosures']);
    return ProviderDirectory(
      providers: [
        for (final p in j[listKey] as List)
          if (EscrowListing.tryParse(p) case final EscrowListing ok) ok,
      ],
      notices: [
        for (final n in (j['notices'] is List ? j['notices'] as List : const []))
          if (n is Map && _sn(n['public_notice']) != null)
            ProviderNotice(_s(n['name']), _s(n['canonical_domain']), _s(n['public_notice'])),
      ],
      notice: _sn(disclosures['main']) ?? kRequiredNotice,
      points: _ss(disclosures['points']).isEmpty ? kDisclosurePoints : _ss(disclosures['points']),
      fetchedAt: fetchedAt,
      excluded: [
        for (final e in (j['excluded'] is List ? j['excluded'] as List : const []))
          Excluded(_s(_m(e)['id']), _s(_m(e)['name']), _s(_m(e)['reason'])),
      ],
      ranking: Ranking.tryParse(j['ranking']),
      estimateNote: _s(j['estimate_note']),
    );
  }

  /// A provider by id, or null.
  EscrowListing? byId(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// Format whole shillings: 5316 -> "KSh 5,316".
String formatKes(int amount) {
  final digits = amount.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}KSh $buffer';
}
