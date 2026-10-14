// Finding a listing's category by what the seller calls the item.
//
// The category step lists 21 categories and ~180 subcategories. A farmer
// selling maize shouldn't have to know it lives under Agriculture ->
// Cereals & Grains, so the step's search matches what people actually type
// - including Swahili and Sheng ("mahindi", "boda", "shamba", "mitumba") -
// against every subcategory at once.
//
// Keywords are keyed by subcategory NAME, exactly as the backend seeds it
// (backend/api/domains/categories/seed.py); a subcategory with no entry
// here is still found by its own name.
import 'models/category.dart';

class CategoryMatch {
  const CategoryMatch(this.node, this.subcategory, this.score);
  final CategoryNode node;

  /// Null when the match is the top-level category itself.
  final Category? subcategory;
  final int score;
}

class CategorySearch {
  CategorySearch._();

  static const Map<String, List<String>> keywords = {
    // Automobiles
    'Cars': ['car', 'saloon', 'suv', 'toyota', 'nissan', 'mazda', 'subaru', 'probox', 'vitz',
      'prado', 'mercedes', 'bmw', 'honda', 'hatchback', 'sedan', 'gari'],
    'Motorcycles & Boda Bodas': ['boda', 'bodaboda', 'motorbike', 'motorcycle', 'pikipiki',
      'tvs', 'bajaj', 'boxer', 'scooter'],
    'Pickups': ['pickup', 'pick up', 'hilux', 'dmax', 'd-max', 'navara', 'ranger', '4x4'],
    'Buses & Matatus': ['matatu', 'bus', 'nganya', 'shuttle', 'minibus'],
    'Trucks': ['lorry', 'truck', 'canter', 'tipper', 'trailer head'],
    'Vans': ['van', 'noah', 'voxy', 'hiace'],
    'Tuk-Tuks & Three-Wheelers': ['tuktuk', 'tuk tuk', 'tuk-tuk', 'three wheeler', 'bajaj re'],
    'Agricultural Vehicles': ['tractor'],
    'Boats & Watercraft': ['boat', 'dhow', 'jet ski', 'canoe'],
    'Parts & Accessories': ['spare', 'spares', 'parts', 'car battery', 'headlight', 'bumper'],
    'Tyres & Rims': ['tyre', 'tire', 'rims', 'wheel'],
    // Property
    'Houses': ['house', 'maisonette', 'bungalow', 'villa', 'mansion', 'nyumba'],
    'Apartments': ['apartment', 'flat', 'penthouse'],
    'Rentals': ['rent', 'bedsitter', 'single room', 'to let', 'rental', 'hostel'],
    'Short Stays & Airbnb': ['airbnb', 'bnb', 'holiday home', 'short stay'],
    'Commercial Property': ['commercial building', 'building'],
    'Offices': ['office space', 'offices'],
    'Shops': ['shop', 'stall', 'kiosk', 'duka'],
    'Warehouses & Godowns': ['warehouse', 'godown', 'yard'],
    'Farms': ['farm with house', 'ranch house'],
    // Land
    'Residential Plots': ['plot', '50x100', '50 by 100', 'eighth acre', 'quarter acre', 'ploti'],
    'Agricultural Land': ['shamba', 'farm land', 'farmland', 'acre', 'acres', 'acreage'],
    'Commercial Land': ['commercial plot'],
    'Industrial Land': ['industrial plot'],
    'Beach & Waterfront Land': ['beach', 'ocean', 'lake front', 'waterfront', 'diani', 'malindi'],
    'Ranches & Large Tracts': ['ranch'],
    'Land for Lease': ['lease', 'leasing'],
    // Electronics
    'Phones': ['phone', 'simu', 'iphone', 'samsung', 'tecno', 'infinix', 'itel', 'oppo',
      'xiaomi', 'redmi', 'smartphone', 'mobile'],
    'Laptops & Computers': ['laptop', 'computer', 'pc', 'desktop', 'macbook', 'hp', 'dell',
      'lenovo'],
    'Tablets': ['tablet', 'ipad'],
    'TVs': ['tv', 'television', 'smart tv', 'telly'],
    'Audio': ['speaker', 'headphones', 'earphones', 'soundbar', 'earbuds', 'airpods',
      'subwoofer', 'home theatre'],
    'Smartwatches & Wearables': ['smartwatch', 'smart watch', 'fitbit', 'fitness band'],
    'Cameras': ['camera', 'dslr', 'canon', 'nikon'],
    'Solar & Power Backup': ['solar', 'panel', 'inverter', 'generator', 'ups', 'power backup'],
    'Printers & Scanners': ['printer', 'scanner', 'photocopier'],
    'Computer Components': ['ssd', 'ram', 'monitor', 'keyboard', 'mouse', 'graphics card'],
    'Networking': ['router', 'wifi', 'modem', 'mifi'],
    'Accessories': ['charger', 'cable', 'phone cover', 'power bank'],
    // Fashion
    'Mtumba (Second-hand Clothes)': ['mtumba', 'mitumba', 'second hand', 'secondhand',
      'bale', 'camera grade', 'used clothes', 'gikomba'],
    "Men's Clothing": ['men', 'shirt', 'trouser', 'suit', 'jacket'],
    "Women's Clothing": ['dress', 'skirt', 'blouse', 'women', 'ladies'],
    "Kids' Clothing": ['kids clothes', 'baby clothes'],
    'Shoes': ['shoes', 'sneakers', 'sandals', 'heels', 'boots', 'viatu'],
    'Bags & Accessories': ['bag', 'handbag', 'backpack', 'wallet', 'belt'],
    'Jewelry & Watches': ['jewelry', 'jewellery', 'necklace', 'earrings', 'ring', 'watch'],
    'Traditional Wear': ['kitenge', 'ankara', 'dashiki', 'kanzu'],
    'Wedding Wear': ['wedding gown', 'bridal', 'wedding dress'],
    'Uniforms & Workwear': ['uniform', 'school uniform', 'overall', 'workwear'],
    'Fabrics & Textiles': ['fabric', 'material', 'cloth', 'kikoi', 'shuka'],
    // Agriculture
    'Cereals & Grains': ['maize', 'mahindi', 'beans', 'maharagwe', 'rice', 'mchele', 'wheat',
      'sorghum', 'millet', 'ndengu', 'green grams', 'cereal', 'grain'],
    'Fruits & Vegetables': ['tomato', 'nyanya', 'onion', 'potato', 'cabbage', 'sukuma',
      'avocado', 'mango', 'banana', 'ndizi', 'fruit', 'vegetable', 'kales', 'pineapple',
      'watermelon'],
    'Crops & Produce': ['tea', 'coffee', 'macadamia', 'sugarcane', 'miraa', 'cotton', 'produce',
      'harvest'],
    'Livestock': ['cow', 'cattle', 'goat', 'sheep', 'pig', 'ngombe', 'mbuzi', 'bull', 'heifer'],
    'Poultry': ['chicken', 'kuku', 'kienyeji', 'broilers', 'layers', 'chicks', 'ducks', 'turkey'],
    'Dairy & Eggs': ['milk', 'eggs', 'mayai', 'maziwa', 'ghee'],
    'Seeds': ['seed', 'mbegu'],
    'Seedlings & Nursery': ['seedling', 'nursery'],
    'Animal Feed': ['feed', 'dairy meal', 'chick mash', 'hay', 'napier'],
    'Fertilizers & Agrochemicals': ['fertilizer', 'fertiliser', 'dap', 'urea', 'pesticide',
      'manure', 'mbolea'],
    'Farm Equipment': ['plough', 'sprayer', 'chaff cutter', 'milking machine'],
    'Farm Tools': ['jembe', 'panga', 'hoe', 'wheelbarrow', 'slasher'],
    'Irrigation & Water Tanks': ['water tank', 'tank', 'drip', 'irrigation', 'pump'],
    'Beekeeping & Honey': ['honey', 'beehive', 'asali'],
    // Home & Furniture
    'Living Room': ['sofa', 'couch', 'coffee table', 'tv stand'],
    'Bedroom': ['wardrobe', 'dresser'],
    'Beds & Mattresses': ['bed', 'mattress', 'kitanda'],
    'Kitchen & Dining': ['dining table', 'dining chairs'],
    'Kitchenware & Cookware': ['sufuria', 'pots', 'pans', 'plates', 'cutlery', 'jiko'],
    'Appliances': ['fridge', 'cooker', 'microwave', 'washing machine', 'blender', 'gas cooker',
      'oven', 'iron box'],
    'Home Décor': ['decor', 'mirror', 'carpet', 'rug', 'vase'],
    'Bedding & Curtains': ['curtain', 'duvet', 'bedsheet', 'blanket', 'pillow'],
    'Lighting': ['bulb', 'lamp', 'chandelier'],
    'Office Furniture': ['office chair', 'office desk'],
    // Food & Beverages
    'Packaged Foods & Groceries': ['flour', 'unga', 'sugar', 'groceries'],
    'Beverages': ['soda', 'juice', 'drinking water', 'drinks'],
    'Bakery & Snacks': ['cake', 'bread', 'snacks', 'crisps', 'cookies'],
    'Meat & Fish': ['meat', 'nyama', 'samaki', 'beef'],
    'Spices, Oils & Condiments': ['spices', 'salt', 'cooking oil', 'masala'],
    'Ready Meals & Catering': ['catering', 'meals', 'food delivery'],
    // Construction
    'Building Materials': ['cement', 'sand', 'ballast', 'bricks', 'blocks', 'stones', 'timber'],
    'Roofing Materials': ['mabati', 'iron sheets', 'roofing'],
    'Steel & Metal Works': ['steel', 'rebar', 'metal'],
    'Doors, Windows & Gates': ['door', 'window', 'gate', 'grill'],
    'Tiles & Flooring': ['tiles', 'flooring'],
    'Plumbing & Electrical': ['pipes', 'cables', 'sockets', 'wires'],
    'Paint & Hardware': ['paint', 'nails', 'hardware'],
    'Hand & Power Tools': ['drill', 'grinder', 'tools'],
    'Heavy Machinery': ['excavator', 'bulldozer', 'grader', 'concrete mixer'],
    // Beauty & Personal Care
    'Skincare': ['lotion', 'cream', 'sunscreen', 'serum'],
    'Haircare': ['shampoo', 'hair oil', 'relaxer'],
    'Wigs & Hair Extensions': ['wig', 'weave', 'braids', 'extensions'],
    'Makeup': ['makeup', 'lipstick', 'foundation'],
    'Fragrances': ['perfume', 'cologne', 'body spray'],
    "Men's Grooming": ['shaver', 'trimmer', 'beard'],
    // Health & Medical
    'Medical Equipment': ['stethoscope', 'hospital bed', 'oxygen'],
    'Health Monitors': ['bp machine', 'glucometer', 'thermometer', 'oximeter'],
    'Mobility Aids': ['wheelchair', 'crutches', 'walker'],
    'Vitamins & Supplements': ['vitamins', 'supplements', 'protein'],
    // Baby & Kids
    'Toys & Games': ['toys', 'lego', 'doll'],
    'Strollers & Car Seats': ['stroller', 'pram', 'car seat'],
    'Cots & Baby Furniture': ['cot', 'crib', 'high chair'],
    'Feeding & Nursing': ['feeding bottle', 'breast pump'],
    'Diapers & Baby Care': ['diapers', 'pampers', 'wipes'],
    // Gaming
    'Consoles': ['playstation', 'ps4', 'ps5', 'xbox', 'nintendo'],
    'Games': ['fifa', 'video game'],
    'Controllers': ['controller', 'gamepad'],
    'PC Gaming': ['gaming pc'],
    // Sports & Fitness
    'Fitness Equipment': ['gym', 'dumbbells', 'treadmill', 'weights'],
    'Team Sports': ['football', 'jersey', 'basketball', 'rugby'],
    'Cycling': ['bicycle', 'baiskeli', 'bike'],
    // Books & Education
    'Textbooks': ['textbook', 'cbc books', 'cbc'],
    'Revision Books & Past Papers': ['past papers', 'kcse', 'kcpe', 'revision'],
    // Music & Instruments
    'Guitars': ['guitar'],
    'Keyboards & Pianos': ['piano', 'keyboard piano'],
    'DJ & Studio Equipment': ['dj', 'mixer', 'microphone'],
    'PA & Sound Systems': ['pa system', 'amplifier'],
    // Arts & Crafts
    'Paintings & Wall Art': ['painting', 'canvas', 'wall art'],
    'Carvings & Sculptures': ['carving', 'sculpture', 'soapstone'],
    'Beadwork': ['beads', 'maasai beads', 'beaded'],
    'Baskets & Weaving': ['kiondo', 'basket'],
    // Business & Industrial
    'Wholesale & Bulk Stock': ['wholesale', 'bulk', 'stock clearance'],
    'Restaurant & Catering Equipment': ['deep fryer', 'fryer', 'display fridge', 'chapati machine'],
    'Retail & Shop Fixtures': ['shelves', 'display stand'],
    'Printing & Branding Equipment': ['printing machine', 'heat press'],
    'Welding & Workshop Equipment': ['welding machine'],
    'Safety & Security Equipment': ['cctv', 'safe', 'alarm'],
    // Pets & Animals
    'Dogs': ['dog', 'puppy', 'mbwa', 'german shepherd'],
    'Cats': ['cat', 'kitten', 'paka'],
    'Birds': ['parrot', 'pigeon'],
    'Fish & Aquarium': ['aquarium', 'fish tank'],
    'Rabbits & Small Pets': ['rabbit', 'sungura'],
    // Services
    'Home Services': ['plumber', 'electrician', 'fundi', 'mama fua'],
    'Cleaning Services': ['cleaning', 'laundry', 'fumigation'],
    'Repair & Maintenance': ['repair', 'fix'],
    'Construction & Renovation': ['builder', 'contractor', 'renovation'],
    'Transport & Moving': ['movers', 'transport', 'lorry hire'],
    'Automotive Services': ['mechanic', 'car wash', 'garage'],
    'Beauty & Wellness': ['salon', 'barber', 'massage', 'makeup artist'],
    'IT & Tech Services': ['website', 'it support', 'software'],
    'Photography & Videography': ['photographer', 'videographer'],
    'Tutoring & Lessons': ['tuition', 'tutor', 'lessons', 'driving school'],
    'Professional Services': ['lawyer', 'accountant', 'consultant'],
  };

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9 ]"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static int _nameScore(String name, String q) {
    final n = _norm(name);
    if (n == q) return 120;
    if (n.startsWith(q)) return 100;
    if (n.split(' ').any((w) => w.startsWith(q))) return 90;
    if (n.contains(q)) return 70;
    return 0;
  }

  static int _keywordScore(String name, String q) {
    final words = keywords[name];
    if (words == null) return 0;
    var best = 0;
    for (final raw in words) {
      final k = _norm(raw);
      if (k == q) return 95;
      if (k.startsWith(q) && q.length >= 2) best = best < 85 ? 85 : best;
      // "dry maize 90kg" mentions "maize".
      if (' $q '.contains(' $k ') && k.length >= 3) best = best < 88 ? 88 : best;
    }
    return best;
  }

  /// The subcategories (and categories) [query] most likely means, best
  /// first; empty for a query under two characters.
  static List<CategoryMatch> search(String query, List<CategoryNode> tree, {int limit = 12}) {
    final q = _norm(query);
    if (q.length < 2) return const [];
    final matches = <CategoryMatch>[];
    for (final node in tree) {
      final top = _nameScore(node.category.name, q);
      if (top > 0) matches.add(CategoryMatch(node, null, top - 5));
      for (final sub in node.subcategories) {
        final score = [_nameScore(sub.name, q), _keywordScore(sub.name, q)]
            .reduce((a, b) => a > b ? a : b);
        if (score > 0) matches.add(CategoryMatch(node, sub, score));
      }
    }
    // Stable: equal scores keep the taxonomy's own order.
    final indexed = matches.asMap().entries.toList()
      ..sort((a, b) {
        final byScore = b.value.score.compareTo(a.value.score);
        return byScore != 0 ? byScore : a.key.compareTo(b.key);
      });
    return indexed.take(limit).map((e) => e.value).toList();
  }
}

/// Subcategories BROKA calls out wherever they are listed.
class SubcategoryHighlights {
  SubcategoryHighlights._();

  static const mtumba = 'Mtumba (Second-hand Clothes)';

  static const Map<String, ({String emoji, String label})> _highlights = {
    mtumba: (emoji: '♻️', label: 'Popular'),
  };

  static ({String emoji, String label})? of(String? name) =>
      name == null ? null : _highlights[name];
}
