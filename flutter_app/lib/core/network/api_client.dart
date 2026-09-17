// BROKA v3.0 - Core API Client
// Centralises HTTP logic: base URL, auth headers, error handling, retries.
// Feature repositories use this instead of calling http directly.

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);
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
    final response = await _http.get(uri, headers: _headers).timeout(timeout);
    return _handleResponse(response);
  }

  Future<dynamic> post(
    String path,
    dynamic body, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await _http
        .post(uri, headers: _headers, body: jsonEncode(body))
        .timeout(timeout);
    return _handleResponse(response);
  }

  /// POST multipart/form-data (used by evidence upload endpoint).
  Future<dynamic> postForm(
    String path,
    Map<String, String> fields, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final request = http.MultipartRequest('POST', uri);
    // Copy auth headers (skip Content-Type — MultipartRequest sets it)
    _headers.forEach((k, v) {
      if (k.toLowerCase() != 'content-type') request.headers[k] = v;
    });
    request.fields.addAll(fields);
    final streamed = await _http.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    return _handleResponse(response);
  }

  Future<dynamic> patch(
    String path,
    dynamic body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await _http
        .patch(uri, headers: _headers, body: jsonEncode(body))
        .timeout(timeout);
    return _handleResponse(response);
  }

  Future<dynamic> delete(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await _http.delete(uri, headers: _headers);
    return _handleResponse(response);
  }

  dynamic _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(response.body);
    }

    String message = 'Request failed';
    try {
      final decoded = jsonDecode(response.body);
      message = decoded['detail'] ?? decoded['message'] ?? message;
    } catch (_) {
      message = response.body.isNotEmpty ? response.body : message;
    }

    throw ApiException(response.statusCode, message);
  }

  String get baseUrl => _baseUrl;

  void dispose() {
    _http.close();
  }
}

// Singleton instance
final apiClient = ApiClient();
