// lib/core/state/marketplace_state.dart
// Backs the Goods/Traders segmented toggle on the home screen (Design
// Journal Volume 6, Ch.5/Ch.26). Registered in main.dart via
// ChangeNotifierProvider; home_screen.dart reads it with
// context.watch<MarketplaceState>() to swap its body between Goods and
// Traders content.
import 'package:flutter/foundation.dart';

enum MarketplaceMode { goods, traders }

class MarketplaceState extends ChangeNotifier {
  MarketplaceMode _mode = MarketplaceMode.goods;
  String? _locationName;
  Map<String, dynamic> _activeFilters = {};

  MarketplaceMode get mode => _mode;
  String? get locationName => _locationName;
  Map<String, dynamic> get activeFilters => _activeFilters;

  void setMode(MarketplaceMode mode) {
    _mode = mode;
    notifyListeners();
  }

  void setLocation(String name) {
    _locationName = name;
    notifyListeners();
  }

  void setFilters(Map<String, dynamic> filters) {
    _activeFilters = filters;
    notifyListeners();
  }

  void clearFilters() {
    _activeFilters = {};
    notifyListeners();
  }
}
