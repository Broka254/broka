// The names a listing's seller is shown under (models/seller_names.dart).
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/models/seller_names.dart';

void main() {
  test('a business: its name, with the official name under it', () {
    final n = SellerNames.of(listingName: 'Clanix', profile: {
      'name': 'Xavier Bravin Odhaimbo', 'business_name': 'Clanix',
    });
    expect(n.headline, 'Clanix');
    expect(n.officialName, 'Xavier Bravin Odhaimbo');
  });

  test('before the profile loads, the listing\'s name alone', () {
    final n = SellerNames.of(listingName: 'Clanix', profile: null);
    expect(n.headline, 'Clanix');
    expect(n.officialName, isNull);
  });

  test('someone selling as themselves is not named twice', () {
    final n = SellerNames.of(listingName: 'Grace Akinyi', profile: {
      'name': 'Grace Akinyi', 'business_name': null,
    });
    expect(n.headline, 'Grace Akinyi');
    expect(n.officialName, isNull);
  });

  test('a business named after its owner is not named twice either', () {
    final n = SellerNames.of(listingName: 'Grace Akinyi', profile: {
      'name': 'Grace Akinyi', 'business_name': ' grace akinyi ',
    });
    expect(n.officialName, isNull);
  });

  test('blank names fall back to something sayable', () {
    expect(SellerNames.of(listingName: '  ', profile: {'name': 'Amina'}).headline, 'Amina');
    expect(SellerNames.of(listingName: null, profile: null).headline, 'Seller');
  });
}
