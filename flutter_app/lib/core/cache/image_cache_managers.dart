// Where downloaded pictures are kept on the phone.
//
// CachedNetworkImage's default store keeps 200 files. A Home feed, a few
// product pages and a store or two pass that in one sitting - card
// thumbnails, store logos, avatars, gallery photos - and from then on every
// return to Home downloaded thumbnails it had already fetched that day.
// BROKA's image files never change once written (each size of each upload
// is its own immutable URL, served with a one-year max-age), so keeping
// many of them for a long time costs only disk, and saves the same bytes
// over and over on mobile data.
//
// Map tiles get a store of their own: a few hundred tiles from one look at
// the map would otherwise push product photos out of the image store.
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class BrokaImageCache {
  BrokaImageCache._();

  static const key = 'brokaImages';

  /// About 1,500 thumbnails is 30-60 MB: a phone's cache directory, which
  /// Android may clear on its own when space runs short.
  static final CacheManager instance = CacheManager(Config(
    key,
    stalePeriod: const Duration(days: 60),
    maxNrOfCacheObjects: 1500,
  ));
}

class MapTileCache {
  MapTileCache._();

  static const key = 'brokaMapTiles';

  /// OpenStreetMap asks apps to keep the tiles they download rather than
  /// fetch them again (its tile usage policy); a stale tile is revalidated
  /// with its ETag, so an unchanged one costs a few hundred bytes.
  static final CacheManager instance = CacheManager(Config(
    key,
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 800,
  ));
}
