// The signed-in account, as GET /auth/me returns it - what the Menu, Profile
// and Settings screens show.
//
// Profile used to read these one by one out of a raw map, including two keys
// the endpoint has never sent (listing_count, volume_traded), so its
// "Listings" and "Traded" figures were always 0. Only fields /auth/me really
// returns are here; the active-listing count is fetched separately
// (AccountRepository.activeListingCount) and "traded" is gone until
// something computes it.
class MyAccount {
  final String id;
  final String name;
  final String? nickname;
  final String? email;
  final bool emailVerified;
  final String? phone;
  final String? photo;
  final String accountType;
  final String? sellerTier;
  final bool isVerified;
  final double? rating;
  final int completedDeals;
  final bool locationVisible;
  final String? createdAt;

  const MyAccount({
    required this.id,
    required this.name,
    this.nickname,
    this.email,
    this.emailVerified = false,
    this.phone,
    this.photo,
    this.accountType = 'buyer',
    this.sellerTier,
    this.isVerified = false,
    this.rating,
    this.completedDeals = 0,
    this.locationVisible = true,
    this.createdAt,
  });

  factory MyAccount.fromJson(Map<String, dynamic> j) => MyAccount(
        id: j['id'] as String? ?? '',
        name: (j['name'] as String?)?.trim() ?? '',
        nickname: (j['nickname'] as String?)?.trim(),
        email: (j['email'] as String?)?.trim(),
        emailVerified: j['email_verified'] as bool? ?? false,
        phone: j['phone'] as String?,
        photo: j['profile_photo'] as String?,
        accountType: j['account_type'] as String? ?? 'buyer',
        sellerTier: j['seller_tier'] as String?,
        isVerified: j['is_verified'] as bool? ?? false,
        rating: (j['rating'] as num?)?.toDouble(),
        completedDeals: (j['completed_deals'] as num?)?.toInt() ?? 0,
        locationVisible: j['location_visible'] as bool? ?? true,
        createdAt: j['created_at'] as String?,
      );

  bool get isSeller => accountType == 'buyer_seller';

  /// The preferred name when there is one - it's what the user asked to be
  /// called.
  String get displayName {
    final nick = nickname;
    if (nick != null && nick.isNotEmpty) return nick;
    return name.isNotEmpty ? name : 'BROKA user';
  }

  String get initials {
    final parts = displayName.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return parts.isEmpty ? 'B' : parts.first[0].toUpperCase();
  }

  /// A rating only means something once someone has rated a finished deal;
  /// before that the column holds its default, which is not a score anyone
  /// gave.
  String get ratingLabel =>
      completedDeals > 0 && rating != null ? rating!.toStringAsFixed(1) : 'New';

  /// Phone first - it's how BROKA accounts are identified - else email.
  String? get contactLine {
    if (phone != null && phone!.isNotEmpty) return phone;
    if (email != null && email!.isNotEmpty) return email;
    return null;
  }

  /// "Sep 2026", from created_at.
  String? get memberSince {
    final d = DateTime.tryParse(createdAt ?? '');
    if (d == null) return null;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.year}';
  }
}
