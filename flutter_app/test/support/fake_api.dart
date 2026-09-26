// Shared fake HttpClient for widget tests.
//
// Extracted from home_collapsing_scroll_test.dart during the category
// alignment pass, so the Home tests and the Category Zone tests drive the same
// fake backend instead of keeping two copies of ~150 lines of HttpClient
// boilerplate that could disagree about response shapes.
//
// Faking the transport rather than the repositories is deliberate: the
// repositories are const globals, swapping them would mean changing production
// code to suit a test, and going through the real ApiClient means the widgets
// under test are built from real BrokaListing.fromJson / Category.fromJson
// parsing - the JSON shapes here have to match what the backend actually
// returns or the tests fail, which is the point.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Routes a request to a JSON body. Return null to fall through to the
/// defaults in [defaultRoute], or a [FakeResponse] for a status other than
/// 200 or an answer that takes time to arrive.
typedef FakeRoute = Object? Function(Uri uri);

/// A response with a chosen status and/or delay. [delay] runs on the test's
/// clock, so `tester.pump(duration)` is what lets it arrive - which is how a
/// test makes an older request answer after a newer one.
class FakeResponse {
  const FakeResponse(this.body, {this.statusCode = 200, this.delay = Duration.zero});

  /// A server error with FastAPI's error shape.
  const FakeResponse.error({this.statusCode = 500, this.delay = Duration.zero})
      : body = const {'detail': 'Internal Server Error'};

  final Object? body;
  final int statusCode;
  final Duration delay;
}

/// The handler consulted at REQUEST time, not at client-construction time.
///
/// It has to be mutable and read late: ApiClient is a lazily-initialised
/// global that builds its HttpClient once, on first use, so a route captured
/// when the client was created could never be changed by a later test. This
/// way a single test can swap in an empty-results or failing backend with
/// [setFakeRoute] and the very next request picks it up.
FakeRoute? _activeRoute;

/// Installs the fake for the whole test file. Call from setUpAll.
void installFakeApi({FakeRoute? route}) {
  _activeRoute = route;
  HttpOverrides.global = _FakeHttpOverrides();
}

/// Swaps the handler for one test. Pass null to go back to [defaultRoute].
void setFakeRoute(FakeRoute? route) => _activeRoute = route;

/// One request the app made, with its body - for asserting on what was sent,
/// not only where.
class FakeRequest {
  FakeRequest(this.method, this.uri, this.body);
  final String method;
  final Uri uri;
  final String body;

  /// The body as JSON, or null when it isn't JSON.
  Object? get json {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}

/// Every request since the last [clearFakeRequests], oldest first.
final List<FakeRequest> fakeRequests = [];

void clearFakeRequests() => fakeRequests.clear();

/// The canonical taxonomy, as the backend's /categories endpoint returns it.
/// Ids are the names themselves so a test can assert on them readably.
const List<String> fakeTopLevelCategories = [
  'Automobiles', 'Property', 'Land', 'Electronics', 'Fashion', 'Agriculture',
  'Home & Furniture', 'Food & Beverages', 'Construction',
  'Beauty & Personal Care', 'Health & Medical', 'Baby & Kids', 'Gaming',
  'Sports & Fitness', 'Books & Education', 'Music & Instruments',
  'Arts & Crafts', 'Business & Industrial', 'Pets & Animals', 'Services',
  'Other',
];

Map<String, dynamic> fakeListingJson(int i,
        {double price = 1300, String category = 'Electronics'}) =>
    {
      'id': 'listing-$i',
      'seller_id': 'seller-$i',
      'name': 'Test item $i',
      'category': category,
      'price': price,
      'lat': -1.28,
      'lng': 36.8,
      'location_name': 'Nairobi',
      'created_at': '2026-09-18T10:00:00',
      'seller_name': 'Xavier Bravin',
      'seller_verified': true,
      'seller_completed_deals': 3,
      'seller_rating': 4.8,
    };

Object? defaultRoute(Uri uri) {
  final path = uri.path;
  if (path.contains('/subcategories')) {
    return [
      for (final name in const ['Sub One', 'Sub Two', 'Sub Three'])
        {'id': 'sub-$name', 'name': name, 'icon': null, 'parent_id': 'parent'},
    ];
  }
  if (path.contains('/filters')) return <Object?>[];
  if (path.startsWith('/categories')) {
    return [
      for (final name in fakeTopLevelCategories)
        {'id': name, 'name': name, 'icon': null, 'parent_id': null},
    ];
  }
  if (path.startsWith('/listings')) {
    final offset = int.tryParse(uri.queryParameters['offset'] ?? '0') ?? 0;
    // Listings come back in the category they were asked for. The Category
    // Zone tests rely on this: a card in the Vehicles zone shows the Vehicles
    // visual because its own category says so, which is what the real backend
    // returns too.
    final category = uri.queryParameters['category_id'] ?? 'Electronics';
    final items = [
      for (int i = 0; i < 20; i++)
        fakeListingJson(offset + i, price: 15000, category: category),
    ];
    // The Zone asks for with_total=true and gets {items, total}; Home asks
    // without it and gets a bare list. Both shapes come from the same
    // endpoint in the real API, so the fake mirrors that.
    if (uri.queryParameters['with_total'] == 'true') {
      return {'items': items, 'total': 128};
    }
    return items;
  }
  if (path.startsWith('/trending')) {
    return [for (int i = 0; i < 12; i++) fakeListingJson(i, price: 15000)];
  }
  if (path.startsWith('/auctions')) {
    final status = uri.queryParameters['status'] ?? 'live';
    return [
      for (int i = 0; i < 14; i++) fakeAuctionJson(i, status: status),
    ];
  }
  if (path.startsWith('/traders')) {
    return [for (int i = 0; i < 14; i++) fakeTraderJson(i)];
  }
  if (path.startsWith('/stores')) {
    return [for (int i = 0; i < 14; i++) fakeStoreJson(i)];
  }
  // Buy-agent "no active request" and anything else.
  return null;
}

Map<String, dynamic> fakeAuctionJson(int i,
        {String status = 'live', double? currentBid = 1500000}) =>
    {
      'id': 'auction-$i',
      'name': 'Auction item $i',
      'status': status,
      'current_bid': currentBid,
      'bid_count': i,
      'min_bid_increment': 500.0,
      // Far enough out that the countdown is stable across a test run.
      'ends_at': '2030-01-01T00:00:00Z',
    };

Map<String, dynamic> fakeTraderJson(int i) => {
      'id': 'trader-$i',
      'business_name': 'Trader $i',
      'is_verified': i.isEven,
      'rating': 4.5,
      'completed_deals': 7,
      'listing_count': 12,
      'location_name': 'Nairobi',
    };

Map<String, dynamic> fakeStoreJson(int i) => {
      'id': 'store-$i',
      'name': 'Store $i',
      'slug': 'store-$i',
      'specialization': 'Electronics',
      'county': 'Nairobi',
      'listing_count': 9,
    };

// ── Plumbing ─────────────────────────────────────────────────────────────────
// Only the slice http's IOClient actually touches: openUrl, a request whose
// close() yields a response, and a response that is a Stream<List<int>>.
// Everything else routes to noSuchMethod and would throw loudly if a code path
// under test ever needed it.

class _FakeHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

Future<_FakeHttpClientResponse> _respond(Uri uri) async {
  final routed = _activeRoute?.call(uri) ?? defaultRoute(uri);
  if (routed is FakeResponse) {
    if (routed.delay > Duration.zero) await Future<void>.delayed(routed.delay);
    return _FakeHttpClientResponse(utf8.encode(jsonEncode(routed.body)),
        statusCode: routed.statusCode);
  }
  return _FakeHttpClientResponse(utf8.encode(jsonEncode(routed)));
}

class _FakeHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  Duration? connectionTimeout;
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpClientRequest(method, url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.method, this.uri);

  @override
  final String method;
  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  bool bufferOutput = true;
  @override
  Encoding encoding = utf8;

  final List<int> _body = [];

  @override
  void add(List<int> data) => _body.addAll(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _body.addAll(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() {
    fakeRequests.add(FakeRequest(method, uri, utf8.decode(_body, allowMalformed: true)));
    return _respond(uri);
  }

  @override
  Future<HttpClientResponse> get done => close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.body, {this.statusCode = 200});

  final List<int> body;

  @override
  final int statusCode;
  @override
  String get reasonPhrase => statusCode == 200 ? 'OK' : 'Error';
  @override
  int get contentLength => body.length;
  @override
  HttpHeaders get headers => _FakeHttpHeaders();
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  List<Cookie> get cookies => const [];
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([body]).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = ['$value'];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add('$value');
  }

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);

  @override
  ContentType? get contentType => ContentType.json;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
