// A store's cart, kept on the phone.
//
// One cart per store: an order belongs to one store, so one seller and one
// escrow (STORES_PLAN.md phase 4). The cart never takes money itself. Until
// single-payment checkout exists, checkout hands each item to its deal
// room, where it is agreed with the store and paid by M-Pesa into BROKA's
// escrow like any other purchase (presentation/store_cart_screen.dart).
//
// Prices here are what the listing said when it was added - a display
// total, never a price anyone pays: the deal room reads the listing again.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../models/listing_photo.dart';
import '../../listings/domain/models/listing.dart';

class CartItem {
  const CartItem({
    required this.listingId,
    required this.name,
    required this.price,
    this.priceUnit,
    this.image,
    this.category = '',
    this.maxQuantity = 1,
    this.quantity = 1,
  });

  final String listingId;
  final String name;

  /// The price of one unit (of [priceUnit] when there is one).
  final double price;
  final String? priceUnit;

  /// A BrokaImage source for the thumbnail; null shows the category emoji.
  final String? image;
  final String category;

  /// How many the listing has for sale - one for a single item.
  final int maxQuantity;
  final int quantity;

  double get total => price * quantity;

  CartItem withQuantity(int q) => CartItem(
        listingId: listingId,
        name: name,
        price: price,
        priceUnit: priceUnit,
        image: image,
        category: category,
        maxQuantity: maxQuantity,
        quantity: q,
      );

  /// From either listing model's fields. [unitsLeft] (when the listing says
  /// how many are still free) wins over [quantity], the stock it started with.
  factory CartItem.fromFields({
    required String id,
    required String name,
    required double price,
    required String category,
    String? priceUnit,
    int? quantity,
    int? unitsLeft,
    ListingPhoto? cover,
    List<ListingPhoto> photos = const [],
  }) {
    final max = unitsLeft ?? quantity ?? 1;
    return CartItem(
      listingId: id,
      name: name,
      price: price,
      priceUnit: priceUnit,
      image: _smallImage(cover, photos),
      category: category,
      maxQuantity: max < 1 ? 1 : max,
    );
  }

  factory CartItem.fromListing(BrokaListing l) => CartItem.fromFields(
        id: l.id,
        name: l.name,
        price: l.price,
        category: l.category,
        priceUnit: l.priceUnit,
        quantity: l.quantity,
        cover: l.cover,
        photos: l.photos,
      );

  /// Only stored images' URLs are kept: a legacy base64 photo can be
  /// megabytes, too much to write to the phone's preferences on every tap.
  static String? _smallImage(ListingPhoto? cover, List<ListingPhoto> photos) {
    final source = cover?.thumb ?? (photos.isEmpty ? null : photos.first.thumb);
    if (source == null) return null;
    return source.startsWith('http') || source.startsWith('/') ? source : null;
  }

  Map<String, dynamic> toJson() => {
        'id': listingId,
        'name': name,
        'price': price,
        'unit': priceUnit,
        'image': image,
        'category': category,
        'max': maxQuantity,
        'qty': quantity,
      };

  static CartItem? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['name'] is! String || j['price'] is! num) {
      return null;
    }
    final max = (j['max'] as num?)?.toInt() ?? 1;
    final qty = (j['qty'] as num?)?.toInt() ?? 1;
    return CartItem(
      listingId: j['id'] as String,
      name: j['name'] as String,
      price: (j['price'] as num).toDouble(),
      priceUnit: j['unit'] as String?,
      image: j['image'] as String?,
      category: j['category'] as String? ?? '',
      maxQuantity: max < 1 ? 1 : max,
      quantity: qty.clamp(1, max < 1 ? 1 : max),
    );
  }
}

class StoreCart extends ChangeNotifier {
  StoreCart._(this.storeId);

  final String storeId;

  static final _open = <String, StoreCart>{};

  /// The cart for [storeId], shared by every screen showing that store, and
  /// loaded from the phone the first time it's asked for.
  static StoreCart of(String storeId) =>
      _open.putIfAbsent(storeId, () => StoreCart._(storeId)..load());

  /// Tests start each case with no carts in memory.
  @visibleForTesting
  static void resetAll() => _open.clear();

  String get _key => 'store_cart_v1_$storeId';

  List<CartItem> _items = [];
  Future<void>? _loading;

  List<CartItem> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;

  /// Units, not lines: two of one phone and a charger are three.
  int get count => _items.fold(0, (n, i) => n + i.quantity);
  double get subtotal => _items.fold(0.0, (sum, i) => sum + i.total);

  int quantityOf(String listingId) {
    for (final i in _items) {
      if (i.listingId == listingId) return i.quantity;
    }
    return 0;
  }

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final saved = (jsonDecode(raw) as List).map(CartItem.fromJson).whereType<CartItem>();
      // Anything added while this was reading stays as it is: the saved
      // copy is older than the tap.
      final added = {for (final i in _items) i.listingId};
      _items = [..._items, ...saved.where((i) => !added.contains(i.listingId))];
      notifyListeners();
    } catch (_) {
      // A cart that can't be read starts empty; it's a convenience, and
      // nothing in it is a promise.
    }
  }

  /// Adds one of [item]. False when the listing has no more units to add.
  bool add(CartItem item) {
    final at = _items.indexWhere((i) => i.listingId == item.listingId);
    if (at == -1) {
      _items = [..._items, item.withQuantity(1)];
    } else {
      final current = _items[at];
      if (current.quantity >= current.maxQuantity) return false;
      _items = [..._items]..[at] = current.withQuantity(current.quantity + 1);
    }
    _changed();
    return true;
  }

  /// Sets how many of a listing are in the cart: zero or less takes it
  /// out, and no more than the listing has can be asked for.
  void setQuantity(String listingId, int quantity) {
    final at = _items.indexWhere((i) => i.listingId == listingId);
    if (at == -1) return;
    if (quantity <= 0) {
      remove(listingId);
      return;
    }
    final item = _items[at];
    final q = quantity.clamp(1, item.maxQuantity);
    if (q == item.quantity) return;
    _items = [..._items]..[at] = item.withQuantity(q);
    _changed();
  }

  void remove(String listingId) {
    final before = _items.length;
    _items = _items.where((i) => i.listingId != listingId).toList();
    if (_items.length != before) _changed();
  }

  void clear() {
    if (_items.isEmpty) return;
    _items = [];
    _changed();
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_items.isEmpty) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, jsonEncode([for (final i in _items) i.toJson()]));
      }
    } catch (_) {
      // Kept for this session only.
    }
  }
}
