// Kenya's 47 counties and their subcounties, for location pickers.
//
// Subcounties here are the 290 constituencies (IEBC), which is how most
// people name the area they're in ("Westlands", "Ruiru", "Kisumu
// Central"). Administrative sub-county boundaries differ in places, so
// every picker using this list also lets the person type an area that
// isn't in it - a list that can't be escaped is worse than no list.
//
// Counties are in the official order (code 001 Mombasa to 047 Nairobi).
class KenyaLocations {
  KenyaLocations._();

  static const Map<String, List<String>> subcountiesByCounty = {
    'Mombasa': ['Changamwe', 'Jomvu', 'Kisauni', 'Nyali', 'Likoni', 'Mvita'],
    'Kwale': ['Msambweni', 'Lunga Lunga', 'Matuga', 'Kinango'],
    'Kilifi': ['Kilifi North', 'Kilifi South', 'Kaloleni', 'Rabai', 'Ganze', 'Malindi', 'Magarini'],
    'Tana River': ['Garsen', 'Galole', 'Bura'],
    'Lamu': ['Lamu East', 'Lamu West'],
    'Taita Taveta': ['Taveta', 'Wundanyi', 'Mwatate', 'Voi'],
    'Garissa': ['Garissa Township', 'Balambala', 'Lagdera', 'Dadaab', 'Fafi', 'Ijara'],
    'Wajir': ['Wajir North', 'Wajir East', 'Tarbaj', 'Wajir West', 'Eldas', 'Wajir South'],
    'Mandera': ['Mandera West', 'Banissa', 'Mandera North', 'Mandera South', 'Mandera East', 'Lafey'],
    'Marsabit': ['Moyale', 'North Horr', 'Saku', 'Laisamis'],
    'Isiolo': ['Isiolo North', 'Isiolo South'],
    'Meru': [
      'Igembe South', 'Igembe Central', 'Igembe North', 'Tigania West', 'Tigania East',
      'North Imenti', 'Buuri', 'Central Imenti', 'South Imenti',
    ],
    'Tharaka Nithi': ['Maara', "Chuka/Igambang'ombe", 'Tharaka'],
    'Embu': ['Manyatta', 'Runyenjes', 'Mbeere South', 'Mbeere North'],
    'Kitui': [
      'Mwingi North', 'Mwingi West', 'Mwingi Central', 'Kitui West', 'Kitui Rural',
      'Kitui Central', 'Kitui East', 'Kitui South',
    ],
    'Machakos': [
      'Masinga', 'Yatta', 'Kangundo', 'Matungulu', 'Kathiani', 'Mavoko', 'Machakos Town', 'Mwala',
    ],
    'Makueni': ['Mbooni', 'Kilome', 'Kaiti', 'Makueni', 'Kibwezi West', 'Kibwezi East'],
    'Nyandarua': ['Kinangop', 'Kipipiri', 'Ol Kalou', 'Ol Jorok', 'Ndaragwa'],
    'Nyeri': ['Tetu', 'Kieni', 'Mathira', 'Othaya', 'Mukurweini', 'Nyeri Town'],
    'Kirinyaga': ['Mwea', 'Gichugu', 'Ndia', 'Kirinyaga Central'],
    "Murang'a": ['Kangema', 'Mathioya', 'Kiharu', 'Kigumo', 'Maragwa', 'Kandara', 'Gatanga'],
    'Kiambu': [
      'Gatundu South', 'Gatundu North', 'Juja', 'Thika Town', 'Ruiru', 'Githunguri', 'Kiambu',
      'Kiambaa', 'Kabete', 'Kikuyu', 'Limuru', 'Lari',
    ],
    'Turkana': [
      'Turkana North', 'Turkana West', 'Turkana Central', 'Loima', 'Turkana South', 'Turkana East',
    ],
    'West Pokot': ['Kapenguria', 'Sigor', 'Kacheliba', 'Pokot South'],
    'Samburu': ['Samburu West', 'Samburu North', 'Samburu East'],
    'Trans Nzoia': ['Kwanza', 'Endebess', 'Saboti', 'Kiminini', 'Cherangany'],
    'Uasin Gishu': ['Soy', 'Turbo', 'Moiben', 'Ainabkoi', 'Kapseret', 'Kesses'],
    'Elgeyo Marakwet': ['Marakwet East', 'Marakwet West', 'Keiyo North', 'Keiyo South'],
    'Nandi': ['Tinderet', 'Aldai', 'Nandi Hills', 'Chesumei', 'Emgwen', 'Mosop'],
    'Baringo': [
      'Tiaty', 'Baringo North', 'Baringo Central', 'Baringo South', 'Mogotio', 'Eldama Ravine',
    ],
    'Laikipia': ['Laikipia West', 'Laikipia East', 'Laikipia North'],
    'Nakuru': [
      'Molo', 'Njoro', 'Naivasha', 'Gilgil', 'Kuresoi South', 'Kuresoi North', 'Subukia',
      'Rongai', 'Bahati', 'Nakuru Town West', 'Nakuru Town East',
    ],
    'Narok': ['Kilgoris', 'Emurua Dikirr', 'Narok North', 'Narok East', 'Narok South', 'Narok West'],
    'Kajiado': ['Kajiado North', 'Kajiado Central', 'Kajiado East', 'Kajiado West', 'Kajiado South'],
    'Kericho': ['Kipkelion East', 'Kipkelion West', 'Ainamoi', 'Bureti', 'Belgut', 'Sigowet/Soin'],
    'Bomet': ['Sotik', 'Chepalungu', 'Bomet East', 'Bomet Central', 'Konoin'],
    'Kakamega': [
      'Lugari', 'Likuyani', 'Malava', 'Lurambi', 'Navakholo', 'Mumias West', 'Mumias East',
      'Matungu', 'Butere', 'Khwisero', 'Shinyalu', 'Ikolomani',
    ],
    'Vihiga': ['Vihiga', 'Sabatia', 'Hamisi', 'Luanda', 'Emuhaya'],
    'Bungoma': [
      'Mt. Elgon', 'Sirisia', 'Kabuchai', 'Bumula', 'Kanduyi', 'Webuye East', 'Webuye West',
      'Kimilili', 'Tongaren',
    ],
    'Busia': ['Teso North', 'Teso South', 'Nambale', 'Matayos', 'Butula', 'Funyula', 'Budalangi'],
    'Siaya': ['Ugenya', 'Ugunja', 'Alego Usonga', 'Gem', 'Bondo', 'Rarieda'],
    'Kisumu': [
      'Kisumu East', 'Kisumu West', 'Kisumu Central', 'Seme', 'Nyando', 'Muhoroni', 'Nyakach',
    ],
    'Homa Bay': [
      'Kasipul', 'Kabondo Kasipul', 'Karachuonyo', 'Rangwe', 'Homa Bay Town', 'Ndhiwa',
      'Suba North', 'Suba South',
    ],
    'Migori': [
      'Rongo', 'Awendo', 'Suna East', 'Suna West', 'Uriri', 'Nyatike', 'Kuria West', 'Kuria East',
    ],
    'Kisii': [
      'Bonchari', 'South Mugirango', 'Bomachoge Borabu', 'Bobasi', 'Bomachoge Chache',
      'Nyaribari Masaba', 'Nyaribari Chache', 'Kitutu Chache North', 'Kitutu Chache South',
    ],
    'Nyamira': ['Kitutu Masaba', 'West Mugirango', 'North Mugirango', 'Borabu'],
    'Nairobi': [
      'Westlands', 'Dagoretti North', 'Dagoretti South', "Lang'ata", 'Kibra', 'Roysambu',
      'Kasarani', 'Ruaraka', 'Embakasi South', 'Embakasi North', 'Embakasi Central',
      'Embakasi East', 'Embakasi West', 'Makadara', 'Kamukunji', 'Starehe', 'Mathare',
    ],
  };

  /// All 47 counties, in official order.
  static List<String> get counties => subcountiesByCounty.keys.toList(growable: false);

  /// The county's subcounties, or empty for an unknown county.
  static List<String> subcountiesOf(String? county) =>
      subcountiesByCounty[canonicalCounty(county)] ?? const [];

  /// The list's spelling of [value] ("nairobi", "Muranga", "Tharaka-Nithi"
  /// all find their county), or null when it isn't a county.
  static String? canonicalCounty(String? value) {
    final key = _key(value);
    if (key.isEmpty) return null;
    for (final c in subcountiesByCounty.keys) {
      if (_key(c) == key) return c;
    }
    return null;
  }

  /// The list's spelling of [value] within [county], or null.
  static String? canonicalSubcounty(String? county, String? value) {
    final key = _key(value);
    if (key.isEmpty) return null;
    for (final s in subcountiesOf(county)) {
      if (_key(s) == key) return s;
    }
    return null;
  }

  /// Best guess at a county named inside free text such as a signup
  /// business location ("Sira, Nairobi", "Kisumu CBD"), for pre-filling.
  static String? guessCounty(String? text) {
    final words = _key(text);
    if (words.isEmpty) return null;
    for (final c in subcountiesByCounty.keys) {
      if (words.contains(_key(c))) return c;
    }
    // Subcounty names only when long enough not to hide inside other
    // words ("Gem", "Soy" and "Seme" are subcounties too).
    for (final entry in subcountiesByCounty.entries) {
      for (final s in entry.value) {
        final k = _key(s);
        if (k.length >= 5 && words.contains(k)) return entry.key;
      }
    }
    return null;
  }

  static String _key(String? value) =>
      (value ?? '').toLowerCase().replaceAll(RegExp(r"[^a-z]"), '');
}
