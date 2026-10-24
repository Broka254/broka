// BROKA — Store domain model
//
// Mirrors backend/api/domains/stores/service.py's _store_dict(). A store
// carries its OWN rating ([rating], from stores/rating.py) and its owner's
// seller record ([StoreOwnerFacts]). Two different numbers on purpose: the
// shop is judged on its own reviews, reply speed and tenure; the owner's
// record says who is behind the counter.
import '../../../../models/listing_photo.dart';
import 'store_billing.dart';

/// The store owner's seller record, as shown on the storefront.
class StoreOwnerFacts {
  /// Who runs the store. Null from backends before the store page had
  /// "Store details".
  final String? name;
  final bool verified;

  /// The owner's buyer-review average, 1-5. Null when nobody has reviewed
  /// them - not the 5.0 an account starts at, and not the shop's 0-10
  /// composite score ([Store.rating]).
  final double? rating;

  /// How many buyer reviews [rating] is over. Zero is "no rating yet".
  final int reviewCount;
  final int completedDeals;
  final DateTime? memberSince;

  /// The owner has had the app open in the last five minutes (the chat
  /// header's rule, backend api/core/presence.py).
  final bool online;

  /// "Active 3h ago", or null when the owner has never been seen - no
  /// guess stands in for it.
  final String? lastActive;

  const StoreOwnerFacts({
    this.name,
    this.verified = false,
    this.rating,
    this.reviewCount = 0,
    this.completedDeals = 0,
    this.memberSince,
    this.online = false,
    this.lastActive,
  });

  static StoreOwnerFacts? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = (j['name'] as String?)?.trim();
    return StoreOwnerFacts(
      name: name == null || name.isEmpty ? null : name,
      verified: j['verified'] as bool? ?? false,
      rating: (j['rating'] as num?)?.toDouble(),
      reviewCount: (j['review_count'] as num?)?.toInt() ?? 0,
      completedDeals: (j['completed_deals'] as num?)?.toInt() ?? 0,
      memberSince: DateTime.tryParse(j['member_since'] as String? ?? ''),
      online: j['online'] as bool? ?? false,
      lastActive: j['last_active'] as String?,
    );
  }

  /// A rating counts only with reviews behind it. Deals are not reviews:
  /// a seller can finish a hundred deals and still have been rated by
  /// nobody, and displaying the signup default then is the fake 5.0 this
  /// gate exists to prevent.
  double? get shownRating => reviewCount > 0 ? rating : null;
}

/// How a business trades: from premises a customer can visit, or online only.
/// A stored, validated backend field - not a label the app infers from a
/// missing pin or photo.
enum StoreType {
  physical('physical', 'Physical store', 'Customers can visit your business location.'),
  virtual('virtual', 'Virtual store', 'You sell online without a customer-facing shop.');

  const StoreType(this.value, this.label, this.description);
  final String value;
  final String label;
  final String description;

  static StoreType parse(Object? value) =>
      value == 'virtual' ? StoreType.virtual : StoreType.physical;
}

/// One day's opening times. [closed] and 24-hour days are explicit: a day
/// with no times is closed, and an all-day shop is not a typo.
class OpeningHoursDay {
  final bool allDay;
  final String? open;
  final String? close;

  const OpeningHoursDay({this.allDay = false, this.open, this.close});
  const OpeningHoursDay.closed() : allDay = false, open = null, close = null;

  bool get isClosed => !allDay && (open == null || close == null);

  /// True when closing is at or before opening: the window runs past
  /// midnight (20:00-02:00), the case a plain "today's hours" check misses.
  bool get crossesMidnight =>
      !isClosed && !allDay && _minutes(close!) <= _minutes(open!);

  String get label {
    if (allDay) return 'Open 24 hours';
    if (isClosed) return 'Closed';
    return '$open – $close';
  }

  Map<String, dynamic>? toJson() {
    if (allDay) return {'all_day': true};
    if (isClosed) return null;
    return {'open': open, 'close': close};
  }

  static OpeningHoursDay? fromJson(Object? value) {
    if (value is! Map) return null;
    if (value['all_day'] == true) return const OpeningHoursDay(allDay: true);
    final open = value['open'] as String?;
    final close = value['close'] as String?;
    if (open == null || close == null) return null;
    return OpeningHoursDay(open: open, close: close);
  }
}

const openingDayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const openingDayLabels = {
  'mon': 'Monday', 'tue': 'Tuesday', 'wed': 'Wednesday', 'thu': 'Thursday',
  'fri': 'Friday', 'sat': 'Saturday', 'sun': 'Sunday',
};
const openingDayShort = {
  'mon': 'Mon', 'tue': 'Tue', 'wed': 'Wed', 'thu': 'Thu',
  'fri': 'Fri', 'sat': 'Sat', 'sun': 'Sun',
};

/// A store's weekly schedule, keyed Mon..Sun. The backend is the authority;
/// this type only reads and edits a draft of it.
class StoreOpeningHours {
  final Map<String, OpeningHoursDay?> days;

  const StoreOpeningHours(this.days);

  static StoreOpeningHours? fromJson(Object? value) {
    if (value is! Map) return null;
    return StoreOpeningHours({
      for (final day in openingDayKeys)
        day: OpeningHoursDay.fromJson(value[day]),
    });
  }

  Map<String, dynamic> toJson() => {
        for (final day in openingDayKeys) day: days[day]?.toJson(),
      };

  OpeningHoursDay? operator [](String day) => days[day];

  StoreOpeningHours withDay(String day, OpeningHoursDay? hours) =>
      StoreOpeningHours({...days, day: hours});

  /// Every day, Mon..Sun, for the storefront's schedule list.
  List<({String day, String label, String short, String hours, bool closed})> get week => [
        for (final day in openingDayKeys)
          (
            day: day,
            label: openingDayLabels[day]!,
            short: openingDayShort[day]!,
            hours: (days[day] ?? const OpeningHoursDay.closed()).label,
            closed: days[day] == null,
          ),
      ];

  /// True when at least one day is set. An all-closed week is still a
  /// schedule (a shop taking a break), not "unavailable".
  bool get hasAny => days.values.any((d) => d != null);

  /// The status from the stored schedule and the current Africa/Nairobi
  /// time (UTC+3, no daylight saving). No network request: the app can
  /// refresh "Open now" on a timer while the screen is open.
  StoreOpenStatus statusAt(DateTime? now) {
    final nairobi = (now ?? DateTime.now().toUtc()).toUtc().add(const Duration(hours: 3));
    return computeStoreOpenStatus(this, nairobi);
  }
}

/// "Open now · closes 18:00", "Closed now · opens Tue 08:00", or an honest
/// "Opening hours unavailable" when nothing was provided.
class StoreOpenStatus {
  /// "open" | "closed" | "unknown"
  final String state;
  final String label;
  final String? opensAt;
  final String? closesAt;

  const StoreOpenStatus({
    required this.state,
    required this.label,
    this.opensAt,
    this.closesAt,
  });

  static StoreOpenStatus? fromJson(Object? value) {
    if (value is! Map) return null;
    return StoreOpenStatus(
      state: value['state'] as String? ?? 'unknown',
      label: value['label'] as String? ?? 'Opening hours unavailable',
      opensAt: value['opens_at'] as String?,
      closesAt: value['closes_at'] as String?,
    );
  }

  bool get isOpen => state == 'open';
  bool get isKnown => state != 'unknown';
}

int _minutes(String hhmm) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return 0;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

/// The same rules as backend api/domains/stores/opening_hours.py, so the two
/// surfaces cannot disagree. [nairobiNow] must already be Nairobi local time.
StoreOpenStatus computeStoreOpenStatus(StoreOpeningHours? hours, DateTime nairobiNow) {
  if (hours == null || !hours.hasAny) {
    return const StoreOpenStatus(
      state: 'unknown', label: 'Opening hours unavailable');
  }
  final dayIndex = nairobiNow.weekday - 1; // Monday = 0
  final today = openingDayKeys[dayIndex];
  final yesterday = openingDayKeys[(dayIndex + 6) % 7];
  final minutes = nairobiNow.hour * 60 + nairobiNow.minute;

  final previous = hours[yesterday];
  if (previous != null && !previous.allDay && previous.crossesMidnight) {
    if (minutes < _minutes(previous.close!)) {
      return StoreOpenStatus(state: 'open', label: 'Open now · closes ${previous.close}',
          closesAt: previous.close);
    }
  }
  final value = hours[today];
  if (value != null) {
    if (value.allDay) {
      return const StoreOpenStatus(state: 'open', label: 'Open now · 24 hours');
    }
    final openM = _minutes(value.open!);
    final closeM = _minutes(value.close!);
    if (value.crossesMidnight) {
      if (minutes >= openM) {
        return StoreOpenStatus(state: 'open', label: 'Open now · closes ${value.close}',
            closesAt: value.close);
      }
    } else if (minutes >= openM && minutes < closeM) {
      return StoreOpenStatus(state: 'open', label: 'Open now · closes ${value.close}',
          closesAt: value.close);
    }
    // A crossing-midnight window still opens later today; treating it as
    // "not open and not opening today" pushed the next opening a week out.
    if (minutes < openM) {
      return StoreOpenStatus(state: 'closed', label: 'Closed now · opens ${value.open}',
          opensAt: value.open);
    }
  }
  for (var step = 1; step <= 7; step++) {
    final day = openingDayKeys[(dayIndex + step) % 7];
    final next = hours[day];
    if (next == null) continue;
    final opens = next.allDay ? '24 hours' : next.open!;
    return StoreOpenStatus(
      state: 'closed',
      label: 'Closed now · opens ${openingDayShort[day]} $opens',
      opensAt: opens,
    );
  }
  return const StoreOpenStatus(state: 'closed', label: 'Closed now');
}

class Store {
  final String id;
  final String name;

  /// The link name: the `clanix` in broka.co.ke/store/clanix. Fixed.
  final String slug;

  /// The full shareable link, built by the backend.
  final String url;

  /// One of BROKA's top-level categories. The primary: the first category
  /// the store chose (index 0 of [categories]).
  final String? category;

  /// Every category the store sells in, primary first (backend phase 3).
  /// A store with two or more is listed under the "Wholesale and General"
  /// facet. Older responses carry only [category], which becomes the
  /// single entry here.
  final List<String> categories;
  final String? description;
  final String country;
  final String? county;
  final String? subcounty;
  final String? locationDescription;

  /// Optional. Only a verified address is ever shown or mailed.
  final String? businessEmail;
  final bool businessEmailVerified;

  // Images. [logo]/[cover]/[photoImages] are stored images in three sizes;
  // [logoUrl]/[photos] are the plain strings older responses carry (a URL,
  // or base64 for a store the backend hasn't converted yet) - render any of
  // them with BrokaImage.
  final ListingPhoto? logo;
  final ListingPhoto? cover;
  final List<ListingPhoto> photoImages;
  final String? logoUrl;
  final List<String> photos;

  final StoreOwnerFacts? owner;
  final bool isActive;

  /// Physical premises or online-only. Backends before store types send
  /// nothing, which reads as physical: every store that existed was one.
  final StoreType storeType;

  /// The owner's weekly schedule, null when none was provided. The server's
  /// status is [serverOpenStatus]; [liveOpenStatus] recomputes from this
  /// schedule without another request.
  final StoreOpeningHours? openingHours;
  final bool openingHoursAvailable;
  final StoreOpenStatus? serverOpenStatus;

  /// Where the store delivers/serves: Kenyan counties, or ["Nationwide"].
  /// Separate from [county], which is where a physical shop is.
  final List<String> serviceAreas;
  final String? deliveryNote;

  /// The store's own rating, 0-10, from its reviews, its own reply time and
  /// its tenure (backend stores/rating.py). Null only from a backend that
  /// predates the rating - and then the card shows nothing rather than a
  /// guess. It is deliberately NOT [StoreOwnerFacts.rating]: a shop's record
  /// is about the shop, not the person behind it.
  final double? rating;

  /// How many reviews the rating counts. Zero is honest: "no reviews yet",
  /// not "rated 0".
  final int reviewCount;

  /// The store's measured average reply time in minutes. Null means
  /// unmeasured, which is not the same as fast.
  final double? responseMinutes;

  /// Owner-only: the working behind the rating, so the dashboard can explain
  /// it. Null on every public read.
  final StoreRatingBreakdown? ratingBreakdown;
  final String? ratingExplanation;

  /// The store's plan state on the owner's own reads, and null everywhere
  /// else: public reads carry null, and so does every read while
  /// STORE_BILLING_ENABLED is off. The app shows billing surfaces only
  /// when this is not null (a fresh store's screen, My Store's card).
  final StoreBilling? billing;
  final int listingCount;
  /// Straight-line km from the viewer, one decimal, to the owner's
  /// approximate point (±1 km) - null when the viewer sent no location,
  /// the owner hid theirs, or either side has none. Backends before store
  /// distances send none.
  final double? distanceKm;
  /// '6 km from you' label for the card, null with distanceKm. The
  /// server prefixes '≈ ' when the distance is [distanceApproximate].
  final String? distanceLabel;

  /// The distance was measured to the shop's declared area
  /// (county/subcounty point), not to a shop pin or the owner's point:
  /// true for shops opened before pins existed that never set one.
  /// Backends before area distances send none (false).
  final bool distanceApproximate;

  /// The shop's own pin, exactly as set - only on the owner's own reads.
  final double? lat;
  final double? lng;

  /// Where the map may put the shop: the pin (or the owner's point) at
  /// ±1 km rounding, never exact. Null when the shop has no mappable
  /// point at all.
  final double? approxLat;
  final double? approxLng;
  final bool hasLocation;
  final String? createdAt;
  final String? updatedAt;

  const Store({
    required this.id,
    required this.name,
    required this.slug,
    this.url = '',
    this.category,
    this.categories = const [],
    this.description,
    this.country = 'Kenya',
    this.county,
    this.subcounty,
    this.locationDescription,
    this.businessEmail,
    this.businessEmailVerified = false,
    this.logo,
    this.cover,
    this.photoImages = const [],
    this.logoUrl,
    this.photos = const [],
    this.owner,
    this.isActive = true,
    this.storeType = StoreType.physical,
    this.openingHours,
    this.openingHoursAvailable = false,
    this.serverOpenStatus,
    this.serviceAreas = const [],
    this.deliveryNote,
    this.rating,
    this.reviewCount = 0,
    this.responseMinutes,
    this.ratingBreakdown,
    this.ratingExplanation,
    this.billing,
    this.listingCount = 0,
    this.distanceKm,
    this.distanceLabel,
    this.distanceApproximate = false,
    this.lat,
    this.lng,
    this.approxLat,
    this.approxLng,
    this.hasLocation = false,
    this.createdAt,
    this.updatedAt,
  });

  factory Store.fromJson(Map<String, dynamic> json) {
    final slug = json['slug'] as String;
    // `specialization` is what backends before phase 2 send.
    final category = json['category'] as String? ?? json['specialization'] as String?;
    return Store(
      id:   json['id']   as String,
      name: json['name'] as String,
      slug: slug,
      url:  json['url'] as String? ?? 'https://broka.co.ke/store/$slug',
      category: category,
      // Backends before phase 3 send no `categories`; the single category
      // is then the store's whole set.
      categories: (json['categories'] as List?)?.whereType<String>().toList(growable: false) ??
          [if (category != null) category],
      description: json['description'] as String?,
      country:   json['country']   as String? ?? 'Kenya',
      county:    json['county']    as String?,
      subcounty: json['subcounty'] as String?,
      locationDescription: json['location_description'] as String?,
      businessEmail: json['business_email'] as String?,
      businessEmailVerified: json['business_email_verified'] as bool? ?? false,
      logo:  ListingPhoto.fromJson(json['logo']),
      cover: ListingPhoto.fromJson(json['cover']),
      photoImages: ListingPhoto.listFromJson(json['photo_images']),
      logoUrl: json['logo_url'] as String?,
      photos:  (json['photos'] as List?)?.whereType<String>().toList() ?? const [],
      owner: StoreOwnerFacts.fromJson(json['owner']),
      isActive:     json['is_active']     as bool? ?? true,
      storeType: StoreType.parse(json['store_type']),
      openingHours: StoreOpeningHours.fromJson(json['opening_hours']),
      openingHoursAvailable: json['opening_hours_available'] as bool? ?? false,
      serverOpenStatus: StoreOpenStatus.fromJson(json['open_status']),
      serviceAreas: (json['service_areas'] as List?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const [],
      deliveryNote: json['delivery_note'] as String?,
      rating: (json['rating'] as num?)?.toDouble(),
      reviewCount: (json['review_count'] as num?)?.toInt() ?? 0,
      responseMinutes: (json['response_minutes'] as num?)?.toDouble(),
      ratingBreakdown: StoreRatingBreakdown.fromJson(json['rating_breakdown']),
      ratingExplanation: json['rating_explanation'] as String?,
      billing:      StoreBilling.fromJson(json['billing']),
      listingCount: (json['listing_count'] as num?)?.toInt() ?? 0,
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
      distanceLabel: json['distance_label'] as String?,
      distanceApproximate: json['distance_approximate'] as bool? ?? false,
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
      approxLat: (json['approx_lat'] as num?)?.toDouble(),
      approxLng: (json['approx_lng'] as num?)?.toDouble(),
      hasLocation: json['has_location'] as bool? ?? false,
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }

  bool get isVirtual => storeType == StoreType.virtual;

  /// The live "Open now" status, calculated from the stored schedule and the
  /// phone's clock in Nairobi time. Falls back to the server's answer when
  /// the schedule itself isn't in the payload (an older backend), and to
  /// "unavailable" when neither exists - never to "closed", which BROKA
  /// cannot know.
  StoreOpenStatus get liveOpenStatus {
    final schedule = openingHours;
    if (schedule != null && schedule.hasAny) return schedule.statusAt(null);
    return serverOpenStatus ??
        const StoreOpenStatus(state: 'unknown', label: 'Opening hours unavailable');
  }

  /// "Delivers to Nairobi, Kisumu" / "Delivers nationwide", or null when the
  /// owner hasn't said. Delivery coverage is not the shop's address.
  String? get deliveryCoverageLabel {
    if (serviceAreas.isEmpty) return null;
    if (serviceAreas.length == 1 && serviceAreas.first.toLowerCase() == 'nationwide') {
      return 'Delivers nationwide';
    }
    if (serviceAreas.length <= 3) return 'Delivers to ${serviceAreas.join(', ')}';
    return 'Delivers to ${serviceAreas.take(2).join(', ')} and '
        '${serviceAreas.length - 2} more counties';
  }

  /// The point the in-app map opens at, or null when there is none.
  ({double lat, double lng})? get mapPoint {
    // A virtual store has no premises; a pin left over from an earlier
    // physical setup is not a shopfront and must not be shown as one.
    if (storeType == StoreType.virtual) return null;
    if (approxLat != null && approxLng != null) {
      return (lat: approxLat!, lng: approxLng!);
    }
    if (lat != null && lng != null) return (lat: lat!, lng: lng!);
    return null;
  }

  /// "Subcounty, County", or null when neither is set.
  String? get locationLine {
    final parts = [subcounty, county]
        .where((s) => s != null && s.trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// How far still counts as near, in km. Beyond it a shop is not near
  /// you, and the card shows the place instead of a number.
  static const double nearRadiusKm = 25;

  /// '6 km from you' for the card: the server's label when present, else
  /// formatted locally from distanceKm so older backends still read right.
  /// Null beyond [nearRadiusKm], and when neither is known - a missing
  /// distance is unknown, never 0 km.
  String? get nearLabel => _distanceLabel(capped: true);

  /// The same label without the near cap, for "nearest to you" lists
  /// where every shop is honestly beyond [nearRadiusKm] and the distance
  /// is the point. Null only when the distance itself is unknown.
  String? get anyDistanceLabel => _distanceLabel(capped: false);

  String? _distanceLabel({required bool capped}) {
    final km = distanceKm;
    if (km != null && (km.isNaN || km.isInfinite || km < 0)) return null;
    if (capped && km != null && km > nearRadiusKm) return null;
    if (distanceLabel != null && distanceLabel!.trim().isNotEmpty) return distanceLabel;
    if (km == null) return null;
    final String body;
    if (km < 1.0) {
      final m = (km * 1000).round();
      body = m == 1 ? '1 m from you' : '$m m from you';
    } else if (km < 10) {
      body = '${km.toStringAsFixed(1)} km from you';
    } else {
      body = '${km.toStringAsFixed(0)} km from you';
    }
    // Locally formatted labels carry the approximation mark themselves;
    // the server's labels already arrive with it.
    return distanceApproximate ? '≈ $body' : body;
  }

  /// The link without the scheme, for display: "broka.co.ke/store/clanix".
  String get displayUrl => url.replaceFirst(RegExp(r'^https?://'), '');

  /// [url] tagged with where it's being shared, so the owner's stats can
  /// say where visitors came from.
  String shareUrl(String via) {
    final uri = Uri.parse(url);
    return uri.replace(queryParameters: {...uri.queryParameters, 'via': via}).toString();
  }

  /// One of the store's products on the web storefront
  /// (…/store/clanix/p/<id>), which opens in the app when it's installed.
  String productUrl(String listingId, {String? via}) {
    final uri = Uri.parse(url);
    return uri.replace(
      path: '${uri.path}/p/$listingId',
      queryParameters: via == null ? null : {'via': via},
    ).toString();
  }

  /// Best image for a small square (logo), as a BrokaImage source.
  String? get logoSource => logo?.thumb ?? logoUrl;

  /// Best image for a wide header, as a BrokaImage source.
  String? get coverSource =>
      cover?.medium ??
      (photoImages.isNotEmpty ? photoImages.first.medium : null) ??
      (photos.isNotEmpty ? photos.first : null);

  /// Every picture of the shop - the cover first, then the shop photos -
  /// as BrokaImage sources: [thumb] for a strip, [large] for full screen.
  /// Older responses carry only [photos], one size each.
  List<({String thumb, String large})> get shopPhotos => [
        if (cover != null) (thumb: cover!.medium, large: cover!.large),
        if (photoImages.isNotEmpty)
          for (final p in photoImages) (thumb: p.medium, large: p.large)
        else
          for (final p in photos) (thumb: p, large: p),
      ];

  /// When the store opened, or null when the response has no date.
  DateTime? get openedAt => DateTime.tryParse(createdAt ?? '');
}

/// The working behind a store rating, as the owner sees it.
///
/// Each component is 0..1; the weights say how much of the headline number
/// it carries. The server computes both sides, so the bars on the screen
/// add up to the number beside them rather than being re-derived here.
class StoreRatingBreakdown {
  final double review;
  final double response;
  final double tenure;
  final double confidence;

  const StoreRatingBreakdown({
    this.review = 0,
    this.response = 0,
    this.tenure = 0,
    this.confidence = 0,
  });

  static StoreRatingBreakdown? fromJson(Object? json) {
    if (json is! Map) return null;
    return StoreRatingBreakdown(
      review: (json['review'] as num?)?.toDouble() ?? 0,
      response: (json['response'] as num?)?.toDouble() ?? 0,
      tenure: (json['tenure'] as num?)?.toDouble() ?? 0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// One entry of a store's category rail.
class StoreCategoryCount {
  final String name;
  final int count;
  const StoreCategoryCount(this.name, this.count);

  factory StoreCategoryCount.fromJson(Map<String, dynamic> j) =>
      StoreCategoryCount(j['name'] as String, (j['count'] as num).toInt());
}

/// The result of the setup wizard's live link check.
class LinkNameCheck {
  final String name;
  final bool available;
  final String? reason;
  final String? suggestion;
  final String? url;

  const LinkNameCheck({
    required this.name,
    required this.available,
    this.reason,
    this.suggestion,
    this.url,
  });

  factory LinkNameCheck.fromJson(Map<String, dynamic> j) => LinkNameCheck(
        name: j['name'] as String? ?? '',
        available: j['available'] as bool? ?? false,
        reason: j['reason'] as String?,
        suggestion: j['suggestion'] as String?,
        url: j['url'] as String?,
      );
}

/// The owner's numbers for the last few days (GET /stores/{id}/stats).
class StoreStats {
  final int days;
  final int visits;
  final List<({DateTime date, int count})> visitsByDay;
  final Map<String, int> visitsBySource;
  final Map<String, int> visitsBySurface;
  final int shares;
  final Map<String, int> sharesByChannel;

  const StoreStats({
    required this.days,
    required this.visits,
    required this.visitsByDay,
    required this.visitsBySource,
    required this.visitsBySurface,
    required this.shares,
    required this.sharesByChannel,
  });

  factory StoreStats.fromJson(Map<String, dynamic> j) {
    final visits = (j['visits'] as Map?)?.cast<String, dynamic>() ?? const {};
    final shares = (j['shares'] as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, int> counts(Object? m) => m is Map
        ? m.map((k, v) => MapEntry(k as String, (v as num?)?.toInt() ?? 0))
        : const {};
    return StoreStats(
      days: (j['days'] as num?)?.toInt() ?? 7,
      visits: (visits['total'] as num?)?.toInt() ?? 0,
      visitsByDay: [
        for (final d in (visits['by_day'] as List? ?? const []))
          if (d is Map && DateTime.tryParse(d['date'] as String? ?? '') != null)
            (date: DateTime.parse(d['date'] as String), count: (d['count'] as num?)?.toInt() ?? 0),
      ],
      visitsBySource: counts(visits['by_source']),
      visitsBySurface: counts(visits['by_surface']),
      shares: (shares['total'] as num?)?.toInt() ?? 0,
      sharesByChannel: counts(shares['by_channel']),
    );
  }
}

/// What the store wizard needs to know about the signed-in seller
/// (GET /auth/me): whether they can open a store yet, and the business
/// details to pre-fill it with.
class StoreOwnerProfile {
  final String? name;
  final String accountType;
  final String? sellerTier;
  final String? businessName;
  final String? businessCategory;
  final String? businessLocation;
  final String? businessDescription;
  final String? email;
  final bool emailVerified;

  const StoreOwnerProfile({
    this.name,
    this.accountType = 'buyer',
    this.sellerTier,
    this.businessName,
    this.businessCategory,
    this.businessLocation,
    this.businessDescription,
    this.email,
    this.emailVerified = false,
  });

  factory StoreOwnerProfile.fromJson(Map<String, dynamic> j) => StoreOwnerProfile(
        name: j['name'] as String?,
        accountType: j['account_type'] as String? ?? 'buyer',
        sellerTier: j['seller_tier'] as String?,
        businessName: j['business_name'] as String?,
        businessCategory: j['business_category'] as String?,
        businessLocation: j['business_location'] as String?,
        businessDescription: j['business_description'] as String?,
        email: j['email'] as String?,
        emailVerified: j['email_verified'] as bool? ?? false,
      );

  /// Only long-term sellers (who gave BROKA their business details) can
  /// open a store; everyone else adds those details first.
  bool get canOpenStore => accountType == 'buyer_seller' && sellerTier == 'long_term';
}
