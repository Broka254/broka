// BROKA — a live location fix, as the store screens ask for one.
//
// Its own file because two screens need the type (the directory and a
// category's screen) and neither should import the other for it: a typedef
// in store_list_screen.dart would make store_category_screen.dart import
// the screen that imports it.
//
// The screens use it to make "near you" testable. Without an injection
// point, the nearby rail can only exist on a real phone with location
// granted - and that rail is exactly where the duplicate-shop bug lived.
typedef StoreLocator = Future<({double lat, double lng})?> Function();
