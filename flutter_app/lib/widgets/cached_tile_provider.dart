// Map tiles kept on the phone.
//
// flutter_map's default provider keeps tiles in memory only, so every
// visit to a map downloaded the same streets again - 15-30 KB a tile, a
// few dozen tiles a screen. These go through their own disk store
// (MapTileCache), which also keeps BROKA within OpenStreetMap's tile usage
// policy: download a tile once, not on every view.
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import '../core/cache/image_cache_managers.dart';

class CachedTileProvider extends TileProvider {
  CachedTileProvider();

  /// One for every map: a TileLayer built with a new provider on each
  /// rebuild may treat it as a change of tile source and reload its tiles.
  static final CachedTileProvider shared = CachedTileProvider();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      CachedNetworkImageProvider(
        getTileUrl(coordinates, options),
        // Carries the User-Agent TileLayer adds from userAgentPackageName.
        headers: headers,
        cacheManager: MapTileCache.instance,
      );
}
