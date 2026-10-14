// What the signed-in user has done with a listing - liked it, saved it -
// and, on their own listing, how many people have (GET /listings/{id}/
// engagement). Other buyers never get the counts: which products are
// moving is what a rival would price against.

class ListingEngagement {
  const ListingEngagement({
    this.liked = false,
    this.saved = false,
    this.likes,
    this.saves,
  });

  final bool liked;
  final bool saved;

  /// Only for the listing's seller; null for everyone else.
  final int? likes;
  final int? saves;

  factory ListingEngagement.fromJson(Map<String, dynamic> j) => ListingEngagement(
        liked: j['liked'] == true,
        saved: j['saved'] == true,
        likes: (j['likes'] as num?)?.toInt(),
        saves: (j['saves'] as num?)?.toInt(),
      );

  ListingEngagement copyWith({bool? liked, bool? saved}) => ListingEngagement(
        liked: liked ?? this.liked,
        saved: saved ?? this.saved,
        likes: likes,
        saves: saves,
      );
}
