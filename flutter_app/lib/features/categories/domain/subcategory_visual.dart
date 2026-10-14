// lib/features/categories/domain/subcategory_visual.dart
//
// The card artwork for every subcategory ("Electronics > Phones"), resolved
// by parent and name - the subcategory twin of category_visual.dart.
//
// Keyed by PARENT as well as name because the taxonomy reuses names:
// "Accessories" is a subcategory of Electronics, Gaming and Music &
// Instruments, and "Gaming" is both a top-level category and an Electronics
// subcategory. A name-only table would give a guitar strap a phone
// charger's picture.
//
// The pictures are the website's own (broka-website lib/<category>.ts),
// copied into assets/category_art/<category>/; several subcategories share
// one there and so share one here (Agriculture's produce, for instance).
// test/category_visual_test.dart parses the backend's seed.py and fails if
// a seeded subcategory has no artwork here or an entry names a file that
// isn't bundled. A subcategory added to the backend before this table falls
// back to its parent category's picture rather than an empty card.
import 'package:flutter/material.dart';

import 'category_visual.dart';

/// What one subcategory card draws: its picture and its parent's colours.
class SubcategoryVisual {
  const SubcategoryVisual({
    required this.parent,
    required this.name,
    required this.assetPath,
    required this.emoji,
    required this.gradient,
  });

  /// The parent category's visual - the subcategory's colours and emoji are
  /// its parent's, so Phones reads as part of Electronics.
  final CategoryVisual parent;
  final String name;

  /// Null only when neither the subcategory nor its parent has artwork
  /// ("Other" has no subcategories, so in practice never).
  final String? assetPath;
  final String emoji;
  final List<Color> gradient;
}

class SubcategoryVisuals {
  const SubcategoryVisuals._();

  static String _key(String name) => name.toLowerCase().trim();

  /// Parent (lower-case) -> subcategory (lower-case) -> asset.
  static const Map<String, Map<String, String>> artwork = {
    'automobiles': {
      'cars': 'assets/category_art/automobiles/cars.webp',
      'motorcycles & boda bodas': 'assets/category_art/automobiles/motorcycles-boda-bodas.webp',
      'pickups': 'assets/category_art/automobiles/pickups.webp',
      'buses & matatus': 'assets/category_art/automobiles/buses-matatus.webp',
      'trucks': 'assets/category_art/automobiles/trucks.webp',
      'vans': 'assets/category_art/automobiles/vans.webp',
      'tuk-tuks & three-wheelers': 'assets/category_art/automobiles/tuk-tuks-three-wheelers.webp',
      'agricultural vehicles': 'assets/category_art/automobiles/agricultural-vehicles.webp',
      'trailers': 'assets/category_art/automobiles/trailers.webp',
      'boats & watercraft': 'assets/category_art/automobiles/boats-watercraft.webp',
      'parts & accessories': 'assets/category_art/automobiles/parts-accessories.webp',
      'tyres & rims': 'assets/category_art/automobiles/tyres-rims.webp',
    },
    'property': {
      'houses': 'assets/category_art/property/houses.webp',
      'apartments': 'assets/category_art/property/apartments.webp',
      'rentals': 'assets/category_art/property/rentals.webp',
      'short stays & airbnb': 'assets/category_art/property/short-stays-airbnb.webp',
      'commercial property': 'assets/category_art/property/commercial-property.webp',
      'offices': 'assets/category_art/property/offices.webp',
      'shops': 'assets/category_art/property/shops.webp',
      'warehouses & godowns': 'assets/category_art/property/warehouses-godowns.webp',
      'farms': 'assets/category_art/property/farms.webp',
    },
    'land': {
      'residential plots': 'assets/category_art/land/residential-plots.webp',
      'agricultural land': 'assets/category_art/land/agricultural-land.webp',
      'commercial land': 'assets/category_art/land/commercial-land.webp',
      'industrial land': 'assets/category_art/land/industrial-land.webp',
      'beach & waterfront land': 'assets/category_art/land/beach-waterfront-land.webp',
      'ranches & large tracts': 'assets/category_art/land/ranches-large-tracts.webp',
      'land for lease': 'assets/category_art/land/land-for-lease.webp',
    },
    'electronics': {
      'phones': 'assets/category_art/electronics/phones.webp',
      'laptops & computers': 'assets/category_art/electronics/laptops-tablets.webp',
      'tablets': 'assets/category_art/electronics/tablets.webp',
      'tvs': 'assets/category_art/electronics/tvs.webp',
      'audio': 'assets/category_art/electronics/audio.webp',
      'smartwatches & wearables': 'assets/category_art/electronics/wearables.webp',
      'cameras': 'assets/category_art/electronics/cameras.webp',
      'solar & power backup': 'assets/category_art/electronics/power-charging.webp',
      'printers & scanners': 'assets/category_art/electronics/printers-scanners.webp',
      'computer components': 'assets/category_art/electronics/computer-components.webp',
      'networking': 'assets/category_art/electronics/networking.webp',
      'gaming': 'assets/category_art/gaming.webp',
      'accessories': 'assets/category_art/electronics/accessories.webp',
    },
    'fashion': {
      'mtumba (second-hand clothes)': 'assets/category_art/fashion/mtumba-second-hand-clothes.webp',
      'men\'s clothing': 'assets/category_art/fashion/mens-clothing.webp',
      'women\'s clothing': 'assets/category_art/fashion/womens-clothing.webp',
      'kids\' clothing': 'assets/category_art/fashion/kids-clothing.webp',
      'shoes': 'assets/category_art/fashion/shoes.webp',
      'bags & accessories': 'assets/category_art/fashion/bags-accessories.webp',
      'jewelry & watches': 'assets/category_art/fashion/jewelry-watches.webp',
      'traditional wear': 'assets/category_art/fashion/traditional-wear.webp',
      'wedding wear': 'assets/category_art/fashion/wedding-wear.webp',
      'uniforms & workwear': 'assets/category_art/fashion/uniforms-workwear.webp',
      'fabrics & textiles': 'assets/category_art/fashion/fabrics-textiles.webp',
    },
    'agriculture': {
      'cereals & grains': 'assets/category_art/agriculture/produce.webp',
      'fruits & vegetables': 'assets/category_art/agriculture/produce.webp',
      'crops & produce': 'assets/category_art/agriculture/produce.webp',
      'livestock': 'assets/category_art/agriculture/livestock.webp',
      'poultry': 'assets/category_art/agriculture/poultry.webp',
      'dairy & eggs': 'assets/category_art/agriculture/livestock.webp',
      'seeds': 'assets/category_art/agriculture/seeds.webp',
      'seedlings & nursery': 'assets/category_art/agriculture/seeds.webp',
      'animal feed': 'assets/category_art/agriculture/livestock.webp',
      'fertilizers & agrochemicals': 'assets/category_art/agriculture/seeds.webp',
      'farm equipment': 'assets/category_art/agriculture/equipment.webp',
      'farm tools': 'assets/category_art/agriculture/equipment.webp',
      'irrigation & water tanks': 'assets/category_art/agriculture/equipment.webp',
      'beekeeping & honey': 'assets/category_art/agriculture/produce.webp',
      'agricultural supplies': 'assets/category_art/agriculture/equipment.webp',
    },
    'home & furniture': {
      'living room': 'assets/category_art/home-and-furniture/living-room.webp',
      'bedroom': 'assets/category_art/home-and-furniture/bedroom.webp',
      'beds & mattresses': 'assets/category_art/home-and-furniture/beds-mattresses.webp',
      'kitchen & dining': 'assets/category_art/home-and-furniture/kitchen-dining.webp',
      'kitchenware & cookware': 'assets/category_art/home-and-furniture/kitchenware-cookware.webp',
      'appliances': 'assets/category_art/home-and-furniture/appliances.webp',
      'home décor': 'assets/category_art/home-and-furniture/home-decor.webp',
      'bedding & curtains': 'assets/category_art/home-and-furniture/bedding-curtains.webp',
      'lighting': 'assets/category_art/home-and-furniture/lighting.webp',
      'office furniture': 'assets/category_art/home-and-furniture/office-furniture.webp',
      'outdoor & garden': 'assets/category_art/home-and-furniture/outdoor-garden.webp',
      'storage & organization': 'assets/category_art/home-and-furniture/storage-organization.webp',
    },
    'food & beverages': {
      'packaged foods & groceries': 'assets/category_art/food-and-beverages/packaged-foods-groceries.webp',
      'beverages': 'assets/category_art/food-and-beverages/beverages.webp',
      'bakery & snacks': 'assets/category_art/food-and-beverages/bakery-snacks.webp',
      'meat & fish': 'assets/category_art/food-and-beverages/meat-fish.webp',
      'spices, oils & condiments': 'assets/category_art/food-and-beverages/spices-oils-condiments.webp',
      'ready meals & catering': 'assets/category_art/food-and-beverages/ready-meals-catering.webp',
    },
    'construction': {
      'building materials': 'assets/category_art/construction/materials.webp',
      'roofing materials': 'assets/category_art/construction/structure.webp',
      'steel & metal works': 'assets/category_art/construction/structure.webp',
      'doors, windows & gates': 'assets/category_art/construction/doors-windows.webp',
      'tiles & flooring': 'assets/category_art/construction/finishes.webp',
      'plumbing & electrical': 'assets/category_art/construction/finishes.webp',
      'paint & hardware': 'assets/category_art/construction/finishes.webp',
      'hand & power tools': 'assets/category_art/construction/tools-machinery.webp',
      'heavy machinery': 'assets/category_art/construction/tools-machinery.webp',
      'scaffolding & safety gear': 'assets/category_art/construction/structure.webp',
    },
    'beauty & personal care': {
      'skincare': 'assets/category_art/beauty-and-personal-care/skincare.webp',
      'haircare': 'assets/category_art/beauty-and-personal-care/haircare.webp',
      'wigs & hair extensions': 'assets/category_art/beauty-and-personal-care/wigs-hair-extensions.webp',
      'makeup': 'assets/category_art/beauty-and-personal-care/makeup.webp',
      'fragrances': 'assets/category_art/beauty-and-personal-care/fragrances.webp',
      'nails': 'assets/category_art/beauty-and-personal-care/nails.webp',
      'men\'s grooming': 'assets/category_art/beauty-and-personal-care/mens-grooming.webp',
      'personal hygiene': 'assets/category_art/beauty-and-personal-care/personal-hygiene.webp',
      'salon & spa equipment': 'assets/category_art/beauty-and-personal-care/salon-spa-equipment.webp',
    },
    'health & medical': {
      'medical equipment': 'assets/category_art/health-and-medical/medical-equipment.webp',
      'health monitors': 'assets/category_art/health-and-medical/health-monitors.webp',
      'mobility aids': 'assets/category_art/health-and-medical/mobility-aids.webp',
      'first aid & supplies': 'assets/category_art/health-and-medical/first-aid-supplies.webp',
      'vitamins & supplements': 'assets/category_art/health-and-medical/vitamins-supplements.webp',
    },
    'baby & kids': {
      'toys & games': 'assets/category_art/baby-and-kids/toys-games.webp',
      'strollers & car seats': 'assets/category_art/baby-and-kids/strollers-car-seats.webp',
      'cots & baby furniture': 'assets/category_art/baby-and-kids/cots-baby-furniture.webp',
      'feeding & nursing': 'assets/category_art/baby-and-kids/feeding-nursing.webp',
      'diapers & baby care': 'assets/category_art/baby-and-kids/diapers-baby-care.webp',
      'maternity': 'assets/category_art/baby-and-kids/maternity.webp',
    },
    'gaming': {
      'consoles': 'assets/category_art/gaming/consoles.webp',
      'games': 'assets/category_art/gaming/games.webp',
      'controllers': 'assets/category_art/gaming/controllers.webp',
      'pc gaming': 'assets/category_art/gaming/pc-gaming.webp',
      'accessories': 'assets/category_art/gaming/accessories.webp',
    },
    'sports & fitness': {
      'fitness equipment': 'assets/category_art/sports-and-fitness/fitness-equipment.webp',
      'team sports': 'assets/category_art/sports-and-fitness/team-sports.webp',
      'cycling': 'assets/category_art/sports-and-fitness/cycling.webp',
      'sportswear': 'assets/category_art/sports-and-fitness/sportswear.webp',
      'racket sports': 'assets/category_art/sports-and-fitness/racket-sports.webp',
      'outdoor & camping': 'assets/category_art/sports-and-fitness/outdoor-camping.webp',
      'swimming': 'assets/category_art/sports-and-fitness/swimming.webp',
    },
    'books & education': {
      'textbooks': 'assets/category_art/books-and-education/textbooks.webp',
      'revision books & past papers': 'assets/category_art/books-and-education/revision-books-past-papers.webp',
      'fiction': 'assets/category_art/books-and-education/fiction.webp',
      'non-fiction': 'assets/category_art/books-and-education/non-fiction.webp',
      'children\'s books': 'assets/category_art/books-and-education/childrens-books.webp',
      'religious books': 'assets/category_art/books-and-education/religious-books.webp',
      'stationery & supplies': 'assets/category_art/books-and-education/stationery-supplies.webp',
      'educational materials': 'assets/category_art/books-and-education/educational-materials.webp',
    },
    'music & instruments': {
      'guitars': 'assets/category_art/music-and-instruments/guitars.webp',
      'keyboards & pianos': 'assets/category_art/music-and-instruments/keyboards-pianos.webp',
      'drums & percussion': 'assets/category_art/music-and-instruments/drums-percussion.webp',
      'wind instruments': 'assets/category_art/music-and-instruments/wind-instruments.webp',
      'traditional instruments': 'assets/category_art/music-and-instruments/traditional-instruments.webp',
      'dj & studio equipment': 'assets/category_art/music-and-instruments/dj-studio-equipment.webp',
      'pa & sound systems': 'assets/category_art/music-and-instruments/pa-sound-systems.webp',
      'accessories': 'assets/category_art/music-and-instruments/accessories.webp',
    },
    'arts & crafts': {
      'paintings & wall art': 'assets/category_art/arts-and-crafts/paintings-wall-art.webp',
      'carvings & sculptures': 'assets/category_art/arts-and-crafts/carvings-sculptures.webp',
      'beadwork': 'assets/category_art/arts-and-crafts/beadwork.webp',
      'baskets & weaving': 'assets/category_art/arts-and-crafts/baskets-weaving.webp',
      'antiques & collectibles': 'assets/category_art/arts-and-crafts/antiques-collectibles.webp',
      'art & craft supplies': 'assets/category_art/arts-and-crafts/art-craft-supplies.webp',
    },
    'business & industrial': {
      'wholesale & bulk stock': 'assets/category_art/business-and-industrial/wholesale-bulk-stock.webp',
      'office equipment': 'assets/category_art/business-and-industrial/office-equipment.webp',
      'industrial machinery': 'assets/category_art/business-and-industrial/industrial-machinery.webp',
      'restaurant & catering equipment': 'assets/category_art/business-and-industrial/restaurant-catering-equipment.webp',
      'retail & shop fixtures': 'assets/category_art/business-and-industrial/retail-shop-fixtures.webp',
      'printing & branding equipment': 'assets/category_art/business-and-industrial/printing-branding-equipment.webp',
      'welding & workshop equipment': 'assets/category_art/business-and-industrial/welding-workshop-equipment.webp',
      'safety & security equipment': 'assets/category_art/business-and-industrial/safety-security-equipment.webp',
      'packaging supplies': 'assets/category_art/business-and-industrial/packaging-supplies.webp',
    },
    'pets & animals': {
      'dogs': 'assets/category_art/pets-and-animals/dogs.webp',
      'cats': 'assets/category_art/pets-and-animals/cats.webp',
      'birds': 'assets/category_art/pets-and-animals/birds.webp',
      'fish & aquarium': 'assets/category_art/pets-and-animals/fish-aquarium.webp',
      'rabbits & small pets': 'assets/category_art/pets-and-animals/rabbits-small-pets.webp',
      'pet food': 'assets/category_art/pets-and-animals/pet-food.webp',
      'pet supplies & accessories': 'assets/category_art/pets-and-animals/pet-supplies-accessories.webp',
    },
    'services': {
      'home services': 'assets/category_art/services/home-services.webp',
      'cleaning services': 'assets/category_art/services/cleaning-services.webp',
      'repair & maintenance': 'assets/category_art/services/repair-maintenance.webp',
      'construction & renovation': 'assets/category_art/services/construction-renovation.webp',
      'transport & moving': 'assets/category_art/services/transport-moving.webp',
      'automotive services': 'assets/category_art/services/automotive-services.webp',
      'beauty & wellness': 'assets/category_art/services/beauty-wellness.webp',
      'it & tech services': 'assets/category_art/services/it-tech-services.webp',
      'photography & videography': 'assets/category_art/services/photography-videography.webp',
      'events & entertainment': 'assets/category_art/services/events-entertainment.webp',
      'tutoring & lessons': 'assets/category_art/services/tutoring-lessons.webp',
      'professional services': 'assets/category_art/services/professional-services.webp',
    },
  };

  /// The visual for [name] under [parentName]. Never throws: an unknown
  /// subcategory gets its parent's picture, an unknown parent the "Other"
  /// visual (CategoryVisuals.resolve).
  static SubcategoryVisual resolve(String? parentName, String name) {
    final parent = CategoryVisuals.resolve(parentName);
    final own = artwork[_key(parent.categoryName)]?[_key(name)];
    return SubcategoryVisual(
      parent: parent,
      name: name,
      assetPath: own ?? parent.assetPath,
      emoji: parent.emoji,
      gradient: parent.gradient,
    );
  }

  /// Whether [name] under [parentName] has a picture of its own rather than
  /// its parent's.
  static bool hasOwnArtwork(String? parentName, String name) =>
      artwork[_key(CategoryVisuals.resolve(parentName).categoryName)]
          ?.containsKey(_key(name)) ??
      false;
}
