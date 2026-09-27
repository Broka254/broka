// BROKA v3.0 - Core API Client
// Centralises HTTP logic: base URL, auth headers, error handling, retries.
// Feature repositories use this instead of calling http directly.

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  /// Why, in a form code can compare, when the server says: its
  /// X-Error-Code header, or the `code` of a structured `detail`
  /// ({"code": "AUCTION_TERMS_LOCKED", "message": ...}).
  final String? code;

  /// The rest of a structured `detail`, when there is one - a 402 from a
  /// premium feature says which plan would include it ("upgrade_to").
  final Map<String, dynamic>? details;

  const ApiException(this.statusCode, this.message, {this.code, this.details});
  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  static const String _baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'https://broka-dbjd.onrender.com',
  );

  String? _token;
  final http.Client _http;

  ApiClient({http.Client? client}) : _http = client ?? http.Client();

  // ── Session ───────────────────────────────────────────────────────────────

  Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('auth_token');
  }

  Future<void> saveToken(String token) async {
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
  }

  Future<void> clearToken() async {
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
  }

  bool get isAuthenticated => _token != null;

  /// Renews the session after a 401. Returns true if it did, in which case
  /// the request is sent once more with the new token.
  ///
  /// Access tokens last 15 minutes. This client used to have no way to
  /// renew one: it read the token once at startup and never again, so
  /// after a quarter of an hour every repository built on it (escrow,
  /// disputes, auctions, stores, buy-agent...) got 401 until the app was
  /// restarted. main.dart points this at ApiService.renewSession, which
  /// owns the refresh token and hands the new access token back through
  /// [saveToken].
  Future<bool> Function()? onUnauthorized;

  /// Sends [send], and on a 401 renews the session and sends it once more.
  ///
  /// [send] is called again for the retry, so it has to build its request
  /// from scratch - which also means it picks up the new token through
  /// [_headers]. A 401 on a request that carried no token is a guest
  /// hitting an account-only route, not an expired session, so it is
  /// returned as-is.
  Future<http.Response> _send(Future<http.Response> Function() send) async {
    final response = await send();
    final renew = onUnauthorized;
    if (response.statusCode != 401 || _token == null || renew == null) {
      return response;
    }
    if (!await renew()) return response;
    return send();
  }

  // ── Headers ───────────────────────────────────────────────────────────────

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  // ── HTTP Methods ──────────────────────────────────────────────────────────

  Future<dynamic> get(
    String path, {
    Map<String, String>? queryParams,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final uri = Uri.parse('$_baseUrl$path').replace(
      queryParameters: queryParams,
    );
    final response = await _send(
      () => _http.get(uri, headers: _headers).timeout(timeout),
    );
    return _handleResponse(response);
  }

  /// [headers] are sent as well as the auth headers - an
  /// X-Idempotency-Key, say.
  Future<dynamic> post(
    String path,
    dynamic body, {
    Duration timeout = const Duration(seconds: 60),
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await _send(
      () => _http
          .post(uri, headers: {..._headers, ...?headers}, body: jsonEncode(body))
          .timeout(timeout),
    );
    return _handleResponse(response);
  }

  /// POST multipart/form-data (used by evidence upload endpoint).
  Future<dynamic> postForm(
    String path,
    Map<String, String> fields, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    // A MultipartRequest can only be sent once, so each attempt builds its own.
    final response = await _send(() async {
      final request = http.MultipartRequest('POST', uri);
      // Copy auth headers (skip Content-Type — MultipartRequest sets it)
      _headers.forEach((k, v) {
        if (k.toLowerCase() != 'content-type') request.headers[k] = v;
      });
      request.fields.addAll(fields);
      final streamed = await _http.send(request).timeout(timeout);
      return http.Response.fromStream(streamed);
    });
    return _handleResponse(response);
  }

  /// POST one file as multipart/form-data under the field name "file",
  /// with [fields] alongside. [onProgress] gets (bytes sent, total bytes)
  /// as the body is written. Renews an expired session like every other
  /// method here; the body is rebuilt for the retry.
  Future<dynamic> uploadFile(
    String path, {
    required List<int> bytes,
    required String filename,
    Map<String, String> fields = const {},
    void Function(int sent, int total)? onProgress,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await _send(() async {
      final request = _ProgressMultipartRequest('POST', uri, onProgress);
      _headers.forEach((k, v) {
        if (k.toLowerCase() != 'content-type') request.headers[k] = v;
      });
      request.fields.addAll(fields);
      request.files.add(http.MultipartFile.fromBytes(
        'file', bytes,
        filename: filename,
        contentType: _imageContentType(filename),
      ));
      final streamed = await _http.send(request).timeout(timeout);
      return http.Response.fromStream(streamed);
    });
    return _handleResponse(response);
  }

  static MediaType _imageContentType(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return MediaType('image', 'png');
    if (lower.endsWith('.webp')) return MediaType('image', 'webp');
    if (lower.endsWith('.gif')) return MediaType('image', 'gif');
    return MediaType('image', 'jpeg');
  }

  Future<dynamic> patch(
    String path,
    dynamic body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await _send(
      () => _http
          .patch(uri, headers: _headers, body: jsonEncode(body))
          .timeout(timeout),
    );
    return _handleResponse(response);
  }

  Future<dynamic> delete(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await _send(() => _http.delete(uri, headers: _headers));
    return _handleResponse(response);
  }

  dynamic _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }

    String message = 'Request failed';
    String? code = response.headers['x-error-code'];
    Map<String, dynamic>? details;
    try {
      final decoded = jsonDecode(response.body);
      final detail = decoded is Map ? (decoded['detail'] ?? decoded['message']) : null;
      // `detail` comes in three shapes, and only the first used to be
      // read: the other two landed in the catch below, and the user was
      // shown the raw JSON of the response.
      if (detail is String) {
        message = detail;
      } else if (detail is Map) {
        message = detail['message'] as String? ?? message;
        code ??= detail['code'] as String?;
        details = detail.cast<String, dynamic>();
      } else if (detail is List && detail.isNotEmpty) {
        message = validationMessage(detail.first);
      }
    } catch (_) {
      message = response.body.isNotEmpty ? response.body : message;
    }

    throw ApiException(response.statusCode, message, code: code, details: details);
  }

  /// One of FastAPI's 422 errors ({"loc": ["body", "price"], "msg": ...})
  /// as a line to show. BROKA's own messages are sentences written for the
  /// user and shown as they are; the framework's generic ones ("Input
  /// should be greater than 0") are prefixed with the field they're about.
  static String validationMessage(dynamic error) {
    if (error is! Map) return 'Request failed';
    final msg = error['msg'] as String? ?? 'Invalid value';
    if (msg.endsWith('.')) return msg;
    final loc = error['loc'];
    final field = loc is List && loc.isNotEmpty ? loc.last.toString() : '';
    if (field.isEmpty || field == 'body') return msg;
    final label = field.replaceAll('_', ' ');
    return '${label[0].toUpperCase()}${label.substring(1)}: $msg';
  }

  String get baseUrl => _baseUrl;

  void dispose() {
    _http.close();
  }
}

// Singleton instance
final apiClient = ApiClient();

/// A multipart request that reports how much of its body has been written.
class _ProgressMultipartRequest extends http.MultipartRequest {
  _ProgressMultipartRequest(super.method, super.url, this.onProgress);

  final void Function(int sent, int total)? onProgress;

  @override
  http.ByteStream finalize() {
    final body = super.finalize();
    final report = onProgress;
    if (report == null) return body;
    final total = contentLength;
    var sent = 0;
    return http.ByteStream(body.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          sent += chunk.length;
          report(sent, total);
          sink.add(chunk);
        },
      ),
    ));
  }
}
