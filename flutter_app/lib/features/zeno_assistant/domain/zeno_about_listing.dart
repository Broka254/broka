// The listing a buyer opened Zeno from, to ask about it.
//
// The product screen's "Ask Zeno" card opens the assistant with one of
// these. Zeno's screen shows it pinned under its header and sends its id
// with every turn; the server reads the listing itself
// (backend/api/domains/zeno_assistant/listing_context.py), so nothing here
// is what Zeno is told - it is only what the buyer sees they are asking
// about.
import '../../../models/listing.dart';
import '../../../utils/price_unit.dart';

class ZenoAboutListing {
  const ZenoAboutListing({
    required this.id,
    required this.name,
    required this.priceLabel,
    this.emoji = '📦',
    this.photo,
    this.negotiable = true,
    this.delivers,
  });

  factory ZenoAboutListing.fromListing(Listing l) {
    final stored = l.photos;
    final legacy = (l.verifiedPhotos ?? '').split(',').where((s) => s.isNotEmpty);
    return ZenoAboutListing(
      id: l.id,
      name: l.name,
      priceLabel: PriceUnits.priceLabel(l.formattedPrice, l.priceUnit),
      emoji: l.emoji,
      // The small size: this is a 44px thumbnail.
      photo: stored.isNotEmpty ? stored.first.thumb : (legacy.isEmpty ? null : legacy.first),
      negotiable: l.priceNegotiable,
      delivers: l.deliveryAvailable,
    );
  }

  final String id;
  final String name;
  final String priceLabel;
  final String emoji;

  /// Anything BrokaImage renders, or null for the category emoji.
  final String? photo;

  final bool negotiable;

  /// Null when the seller hasn't said.
  final bool? delivers;
}
