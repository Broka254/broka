// The BROKA API this build talks to - HTTP and WebSocket in one place.
//
// The address is compiled into the APK, so it stays on installed phones for
// good: a change here only reaches phones through a new release. BROKA's API
// runs on Render, at https://broka-a6vh.onrender.com.
//
// Point a build somewhere else with BOTH definitions:
//   flutter build apk --dart-define=API_URL=https://... \
//                     --dart-define=API_WS_URL=wss://...
// A build that moves only one sends requests to one backend and live deal
// and auction updates to the other, where the process-local WebSocket hubs
// never hear about the deal - nothing errors, updates just never arrive
// (test/api_endpoints_test.dart).
class ApiConfig {
  /// The HTTP base URL, with no trailing slash and no path prefix: the API
  /// mounts its routes at the root (/auth/login, /listings, /stores...).
  static const String baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'https://broka-a6vh.onrender.com',
  );

  /// The same backend over WebSocket: wss://broka-a6vh.onrender.com.
  static const String wsBaseUrl = String.fromEnvironment(
    'API_WS_URL',
    defaultValue: 'wss://broka-a6vh.onrender.com',
  );
}
