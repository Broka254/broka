// BROKA — Store domain model
//
// Mirrors api/domains/stores/service.py's _store_dict() exactly. No
// rating/completed_deals/dcr fields here on purpose - the backend never
// sends fabricated reputation numbers (spec §7/§19), and this model
// shouldn't invent a place to put ones a UI might be tempted to fill in
// locally. listingCount is the only real, backend-computed count.
class Store {
  final String id;
  // Hardening-pass: the backend no longer sends owner_id on any Store
  // response (unnecessary internal-id exposure with no consumer - the
  // "is this my store" check elsewhere compares store ids, not this).
  // Kept as a nullable field rather than deleted outright, in case a
  // real future need for it reintroduces it server-side.
  final String? ownerId;
  final String name;
  final String slug;
  final String? logoUrl;
  final List<String> photos;
  final String? specialization;
  final String? description;
  final String country;
  final String? county;
  final String? subcounty;
  final String? locationDescription;
  final String? officialPhone;
  final String? officialWhatsapp;
  final String? officialEmail;
  final bool isActive;
  final int listingCount;
  final String? createdAt;
  final String? updatedAt;

  const Store({
    required this.id,
    this.ownerId,
    required this.name,
    required this.slug,
    this.logoUrl,
    this.photos = const [],
    this.specialization,
    this.description,
    this.country = 'Kenya',
    this.county,
    this.subcounty,
    this.locationDescription,
    this.officialPhone,
    this.officialWhatsapp,
    this.officialEmail,
    this.isActive = true,
    this.listingCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  factory Store.fromJson(Map<String, dynamic> json) => Store(
        id:      json['id']      as String,
        ownerId: json['owner_id'] as String?,
        name:    json['name']    as String,
        slug:    json['slug']    as String,
        logoUrl: json['logo_url'] as String?,
        photos:  (json['photos'] as List?)?.cast<String>() ?? const [],
        specialization: json['specialization'] as String?,
        description:    json['description']    as String?,
        country:   json['country']   as String? ?? 'Kenya',
        county:    json['county']    as String?,
        subcounty: json['subcounty'] as String?,
        locationDescription: json['location_description'] as String?,
        officialPhone:     json['official_phone']     as String?,
        officialWhatsapp:  json['official_whatsapp']  as String?,
        officialEmail:     json['official_email']      as String?,
        isActive:     json['is_active']     as bool? ?? true,
        listingCount: (json['listing_count'] as num?)?.toInt() ?? 0,
        createdAt: json['created_at'] as String?,
        updatedAt: json['updated_at'] as String?,
      );

  /// A short "County, Subcounty" style line for card/header display, or
  /// null if nothing structured was given - mirrors
  /// SellWizardData.location's derivation on the listing side.
  String? get locationLine {
    final parts = [subcounty, county]
        .where((s) => s != null && s.trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts.join(', ');
  }
}
