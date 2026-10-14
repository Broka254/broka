// A listing or store image as the backend describes it: one stored image in
// three sizes. `thumb` is for cards and grids, `medium` for the product page,
// `large` for full-screen viewing.
class ListingPhoto {
  final String id;
  final String thumb;
  final String medium;
  final String large;
  // Only set on a listing's cover: "showcase" when the card is showing the
  // showcase image, "photo" when it is the first photo.
  final String? kind;

  const ListingPhoto({
    required this.id,
    required this.thumb,
    required this.medium,
    required this.large,
    this.kind,
  });

  static ListingPhoto? fromJson(Object? j) {
    if (j is! Map) return null;
    final thumb = j['thumb'], medium = j['medium'], large = j['large'];
    if (thumb is! String || medium is! String || large is! String) return null;
    return ListingPhoto(
      id: j['id'] as String? ?? '',
      thumb: thumb,
      medium: medium,
      large: large,
      kind: j['kind'] as String?,
    );
  }

  static List<ListingPhoto> listFromJson(Object? j) => j is List
      ? j.map(ListingPhoto.fromJson).whereType<ListingPhoto>().toList()
      : const [];
}
