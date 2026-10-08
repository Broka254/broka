// BROKA - API Service
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/listing.dart';
import '../models/models.dart';
// BidRejection - the typed refusal placeBid throws. Lives with the auction
// model because it is part of that contract, not a transport concern.
import '../features/auctions/domain/models/auction.dart' show BidRejection;
import '../core/network/api_client.dart';
import 'last_screen_tracker.dart';
import 'sell_draft_store.dart';

class ApiService {
  // api.broka.co.ke, a custom domain on the Railway service (broka-api). The
  // compiled-in address stays on installed phones for good, so it names our
  // domain, not a host's: moving hosts again is a DNS change, not a release.
  // Point a build elsewhere with --dart-define=API_URL=... and
  // API_WS_URL=... together. The WebSocket
  // default lives in deal_ws_client.dart and auction_ws_client.dart, and a
  // build that moves only one sends requests to one backend and live deal
  // and auction updates to the other (test/api_endpoints_test.dart).
  static const String baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'https://api.broka.co.ke',
  );

  static String? _token;
  static String? currentUserId;
  static String? currentUserName;
  static String? currentUserNickname;
  static String? currentUserEmail;
  static String? currentUserPhone;
  // 'buyer' | 'buyer_seller'. Every account starts as buyer; upgraded via
  // ApiService.upgradeToSeller(). Kept in sync with /auth/me on profile load.
  static String  currentUserAccountType = 'buyer';
  static double? currentUserLat;
  static double? currentUserLng;
  static String  currentUserLanguage = 'english';
  static String? currentUserPhoto;   // base64 selfie
  static String? _refreshToken;       // JWT refresh token (v4)

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  static Future<void> loadSavedSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token                = prefs.getString('auth_token');
    currentUserId         = prefs.getString('user_id');
    currentUserName       = prefs.getString('user_name');
    currentUserNickname   = prefs.getString('user_nickname');
    currentUserEmail      = prefs.getString('user_email');
    currentUserPhone      = prefs.getString('user_phone');
    currentUserAccountType = prefs.getString('user_account_type') ?? 'buyer';
    currentUserPhoto      = prefs.getString('user_photo');
    final lat = prefs.getDouble('user_lat');
    final lng = prefs.getDouble('user_lng');
    if (lat != null) currentUserLat = lat;
    if (lng != null) currentUserLng = lng;
    currentUserLanguage = prefs.getString('user_language') ?? 'english';
    _refreshToken = prefs.getString('refresh_token');
    // Builds before 2026-09 kept the account password here, in plain text,
    // to log back in with - where Android's auto-backup copied it into the
    // user's Google Drive. It is never written any more; remove any copy
    // an earlier build left behind.
    if (prefs.containsKey(_legacyPasswordKey)) {
      await prefs.remove(_legacyPasswordKey);
    }
  }

  static const _legacyPasswordKey = 'user_password';

  static Future<void> _saveSession(
    String token,
    String userId, {
    String? name,
    String? nickname,
    String? email,
    String? phone,
    String? accountType,
    double? lat,
    double? lng,
    String? photo,
    String? refreshToken,
  }) async {
    _token                = token;
    currentUserId         = userId;
    currentUserName       = name;
    currentUserNickname   = nickname;
    currentUserEmail      = email;
    if (phone != null) currentUserPhone = phone;
    if (accountType != null) currentUserAccountType = accountType;
    currentUserLat        = lat;
    currentUserLng        = lng;
    if (photo != null) currentUserPhoto = photo;
    if (refreshToken != null) _refreshToken = refreshToken;
    // Keeps the newer ApiClient-based repositories (Categories, Trending,
    // Traders, Auctions, Buy-Agent, ...) authenticated too - they read
    // from apiClient's own in-memory token, not this class's.
    await apiClient.saveToken(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('user_id', userId);
    if (name         != null) await prefs.setString('user_name',      name);
    if (nickname     != null) await prefs.setString('user_nickname',  nickname);
    if (email        != null) await prefs.setString('user_email',     email);
    if (phone        != null) await prefs.setString('user_phone',     phone);
    if (accountType  != null) await prefs.setString('user_account_type', accountType);
    if (lat          != null) await prefs.setDouble('user_lat',       lat);
    if (lng          != null) await prefs.setDouble('user_lng',       lng);
    if (photo        != null) await prefs.setString('user_photo',     photo);
    if (refreshToken != null) await prefs.setString('refresh_token',  refreshToken);
  }

  static Future<void> clearSession() async {
    _token                = null;
    currentUserId         = null;
    currentUserName       = null;
    currentUserNickname   = null;
    currentUserEmail      = null;
    currentUserPhone      = null;
    currentUserAccountType = 'buyer';
    currentUserLat        = null;
    currentUserLng        = null;
    currentUserLanguage   = 'english';
    currentUserPhoto      = null;
    await apiClient.clearToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_id');
    await prefs.remove('user_name');
    await prefs.remove('user_nickname');
    await prefs.remove('user_email');
    await prefs.remove('user_phone');
    await prefs.remove('user_account_type');
    await prefs.remove(_legacyPasswordKey);
    await prefs.remove('user_lat');
    await prefs.remove('user_lng');
    await prefs.remove('user_language');
    await prefs.remove('user_photo');
    await prefs.remove('refresh_token');
    _refreshToken = null;
    await LastScreenTracker.clear();
    // A stale sell draft left behind after logout would otherwise route
    // whoever's logged into this device next (possibly a different
    // account entirely, shared-device case) straight into an unfinished
    // listing that isn't theirs the next time the app cold-starts after
    // being killed — see splash_screen.dart's unconditional draft check.
    await SellDraftStore.clear();
  }

  /// Signs this phone out: revokes its refresh token on the server, then
  /// forgets the session here.
  ///
  /// Sign-out used to be clearSession() alone. The refresh token stayed valid
  /// on the server for the rest of its life, so a copy lifted from the phone
  /// (a backup, a rooted device) went on minting access tokens after the user
  /// had signed out. Revoking is best effort - a phone with no signal still
  /// signs out locally.
  static Future<void> signOut() async {
    // While still signed in: this phone stops getting this account's calls
    // and messages. Before, a phone that changed hands kept ringing for
    // whoever had signed out of it.
    final pushToken = registeredPushToken;
    if (pushToken != null) {
      await unregisterPushToken(pushToken);
      registeredPushToken = null;
    }
    final refreshToken = _refreshToken;
    if (refreshToken != null) {
      try {
        await apiClient.post('/auth/token/revoke', {'refresh_token': refreshToken},
            timeout: const Duration(seconds: 8));
      } catch (_) {}
    }
    await clearSession();
  }

  /// Revokes every refresh token this account holds - every phone it is
  /// signed in on - and then signs this one out. Unlike [signOut] this is not
  /// best effort: if the server didn't confirm, nothing is cleared and the
  /// error is rethrown, because "signed out everywhere" must not be claimed
  /// for sessions that are still alive.
  static Future<void> signOutEverywhere() async {
    await apiClient.post('/auth/token/revoke-all', const <String, dynamic>{},
        timeout: const Duration(seconds: 15));
    registeredPushToken = null;
    await clearSession();
  }

  static Future<void> setLanguage(String language) async {
    currentUserLanguage = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_language', language);
    try {
      await http.patch(
        Uri.parse('$baseUrl/auth/language?language=$language'),
        headers: _headers,
      );
    } catch (_) {}
  }

  static Future<void> enrollBiometric(String biometricType) async {
    try {
      await http.patch(
        Uri.parse('$baseUrl/auth/biometric-enroll?biometric_type=$biometricType'),
        headers: _headers,
      );
    } catch (_) {}
  }

  static Future<void> setLocationVisible(bool visible) async {
    try {
      await http.patch(
        Uri.parse('$baseUrl/auth/location-visibility?visible=$visible'),
        headers: _headers,
      );
    } catch (_) {}
  }

  static bool   get isLoggedIn => _token != null;
  static String? get authToken  => _token;

  static Future<bool>? _renewal;

  /// Renews an expired session: refresh token first, stored credentials
  /// second. Returns true if a new access token is in place - in BOTH
  /// clients, this class's and [apiClient], which the feature repositories
  /// use and which calls this itself on a 401 (see main.dart).
  ///
  /// One renewal at a time: every request that finds the token expired at
  /// the same moment (Home loads several repositories at once) waits on the
  /// same attempt instead of each starting its own - and the refresh token
  /// rotates on use, so two concurrent refreshes would revoke each other.
  static Future<bool> renewSession() =>
      _renewal ??= _refreshSession().whenComplete(() => _renewal = null);

  /// Called when the server has ended this session for good: the refresh
  /// token was refused (expired, revoked, signed out elsewhere) or there is
  /// none. The session is already cleared by then; main.dart points this at
  /// the sign-in screen.
  static void Function()? onSessionEnded;

  /// Exchanges the refresh token for a new access token.
  ///
  /// There is deliberately no other way back in. Earlier builds fell back
  /// to logging in again with the account password, which meant keeping
  /// the password on the phone in plain text - and Android's auto-backup
  /// copied it to the user's Google Drive. Now the refresh token is the
  /// only credential kept, and when the server refuses it the user signs
  /// in again.
  ///
  /// A failure that says nothing about the session - no network, a timeout,
  /// a server error - leaves the session as it is: the next request tries
  /// again. Only the server refusing the token (401/403), or having no
  /// token to send, ends it.
  static Future<bool> _refreshSession() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) {
      await _endSession();
      return false;
    }
    final http.Response res;
    try {
      res = await http.post(
        Uri.parse('$baseUrl/auth/token/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refreshToken}),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {
      return false;
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      await _endSession();
      return false;
    }
    if (res.statusCode != 200) return false;
    try {
      final data  = jsonDecode(res.body) as Map<String, dynamic>;
      final token = data['access_token'] as String?;
      final newRt = data['refresh_token'] as String?;
      if (token == null) return false;
      _token = token;
      // Hand the new token to apiClient too - it persists it under the
      // same 'auth_token' key. This used to update only this class,
      // leaving every ApiClient-based repository sending the expired token
      // until the app was restarted.
      await apiClient.saveToken(token);
      if (newRt != null) {
        _refreshToken = newRt;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('refresh_token', newRt);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The session can't be renewed: clear it and tell the app. Nothing to do
  /// for a guest, who had no session to end.
  static Future<void> _endSession() async {
    if (currentUserId == null && _token == null) return;
    await clearSession();
    onSessionEnded?.call();
  }

  // Keep old name as alias so unchanged call-sites still compile
  static Future<bool> _tryRelogin() => renewSession();

  /// Sends once, and once more after renewing the session when the server
  /// says the access token has expired. Access tokens last 15 minutes
  /// (ACCESS_TOKEN_EXPIRE_MINUTES); the chat's requests had no retry, so
  /// past that point a message, a receipt or a history fetch failed
  /// silently until some other request happened to renew the token.
  /// [send] must build its request when called, so the retry carries the
  /// new token.
  static Future<http.Response> _sendAuthed(
      Future<http.Response> Function() send) async {
    final response = await send();
    if (response.statusCode == 401 && _token != null && await _tryRelogin()) {
      return send();
    }
    return response;
  }

  // ── Auth ───────────────────────────────────────────────────────────────────

  /// Step 1 of registration: sends a 6-digit SMS code to [phone].
  /// Throws with the server's error message (e.g. "already registered") if
  /// the request fails — callers should surface `e` to the user as-is.
  /// [appSignature] is the Android SMS Retriever hash for this build, from
  /// SmsAutofillService.appSignature(). When supplied, the server formats the
  /// SMS so the app can read it and fill the code with no user prompt. Null
  /// (iOS, or Play Services unavailable) simply yields the plain SMS.
  static Future<Map<String, dynamic>> requestOtp(
    String phone, {
    String? appSignature,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/otp/request'),
      headers: _headers,
      body: jsonEncode({
        'phone': phone,
        if (appSignature != null) 'app_signature': appSignature,
      }),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail']?.toString() ?? 'Could not send verification code');
    }
    return data;
  }

  /// Requests an emailed verification code. Email is optional at signup, so
  /// this is only called when the user actually supplies an address.
  static Future<Map<String, dynamic>> requestEmailOtp(String email) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/email/otp/request'),
      headers: _headers,
      body: jsonEncode({'email': email}),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail']?.toString() ?? 'Could not send the verification email');
    }
    return data;
  }

  /// Verifies an emailed code and returns an `email_verify_token` for
  /// [register]. Throws on a wrong or expired code.
  static Future<String> verifyEmailOtp(String email, String code) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/email/otp/verify'),
      headers: _headers,
      body: jsonEncode({'email': email, 'code': code}),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail']?.toString() ?? 'Incorrect code');
    }
    return data['email_verify_token'] as String;
  }

  /// Step 2: verifies the code, returns a `phone_verify_token` to pass to
  /// [register]. Throws on wrong/expired code.
  static Future<String> verifyOtp(String phone, String code) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/otp/verify'),
      headers: _headers,
      body: jsonEncode({'phone': phone, 'code': code}),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail']?.toString() ?? 'Incorrect code');
    }
    return data['phone_verify_token'] as String;
  }

  // ── Forgotten / changed password ──────────────────────────────────────────
  // An SMS code to the account's number proves who is resetting it - the
  // number is the account. Through [apiClient]; each throws [ApiException]
  // with the server's reason ("No BROKA account uses this number",
  // "Incorrect code", ...), which the screens show as it is.

  /// Sends a reset code to [phone]. [appSignature] as for [requestOtp].
  static Future<Map<String, dynamic>> requestPasswordReset(
    String phone, {
    String? appSignature,
  }) async =>
      await apiClient.post('/auth/password/forgot', {
        'phone': phone,
        if (appSignature != null) 'app_signature': appSignature,
      }, timeout: const Duration(seconds: 30)) as Map<String, dynamic>;

  /// Checks the code and returns the token that lets [resetPassword] set a
  /// new password.
  static Future<String> verifyPasswordReset(String phone, String code) async {
    final data = await apiClient.post('/auth/password/forgot/verify',
        {'phone': phone, 'code': code},
        timeout: const Duration(seconds: 30)) as Map<String, dynamic>;
    return data['reset_token'] as String;
  }

  /// Sets the new password and signs this phone in with it, as [login]
  /// does. Every other phone on the account is signed out by the server.
  static Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) async {
    final data = await apiClient.post('/auth/password/reset',
        {'reset_token': resetToken, 'new_password': newPassword},
        timeout: const Duration(seconds: 30)) as Map<String, dynamic>;
    await _saveSession(
      data['access_token'] as String, data['user_id'] as String,
      name: data['name'] as String?,
      nickname: data['nickname'] as String?,
      phone: data['phone'] as String?,
      accountType: data['account_type'] as String?,
      lat: (data['lat'] as num?)?.toDouble(),
      lng: (data['lng'] as num?)?.toDouble(),
      photo: data['profile_photo'] as String?,
      refreshToken: data['refresh_token'] as String?,
    );
  }

  /// Changes the signed-in account's password. The server signs every other
  /// phone out and hands this one a new session, kept here so it stays
  /// signed in.
  static Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final data = await apiClient.post('/auth/password/change',
        {'current_password': currentPassword, 'new_password': newPassword},
        timeout: const Duration(seconds: 30)) as Map<String, dynamic>;
    final token = data['access_token'] as String?;
    final refresh = data['refresh_token'] as String?;
    if (token != null) {
      _token = token;
      await apiClient.saveToken(token);
    }
    if (refresh != null) {
      _refreshToken = refresh;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('refresh_token', refresh);
    }
  }

  static Future<Map<String, dynamic>> register({
    // OTP is optional at signup — null here means the user chose to skip
    // phone verification for now (Step 1 or Step 2 of the wizard) and can
    // verify later from Profile. When present, the server derives the
    // actual phone from the token (it wins over the raw value below).
    String? phoneVerifyToken,
    required String phone,
    required String name,
    required String password,
    required double lat,
    required double lng,
    String? nickname,
    /// "male" | "female" | "prefer_not_to_say", or null to skip.
    ///
    /// Optional by design. It is used so Zeno never mis-genders someone
    /// when referring to them in a message to the other party - see
    /// backend api/core/nudge_templates.py. Omitting it and choosing
    /// "prefer not to say" produce identical output everywhere, so
    /// skipping the question costs the user nothing.
    String? gender,
    String? email,
    /// From [verifyEmailOtp]. Present means the address was proven, and the
    /// server then takes the email from the token rather than [email].
    String? emailVerifyToken,
    /// "buyer" (default) or "buyer_seller", chosen on the first wizard step.
    String? accountType,
    /// "short_term" or "long_term". Ignored by the server for a buyer.
    String? sellerTier,
    /// Business identity, only collected from a long-term seller. The server
    /// composes the public display name from these.
    String? businessName,
    String? businessCategory,
    String? businessLocation,
    String? businessDescription,
    String? profilePhoto,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      headers: _headers,
      body: jsonEncode({
        if (phoneVerifyToken != null) 'phone_verify_token': phoneVerifyToken,
        'phone': phone,
        'name': name, 'password': password, 'lat': lat, 'lng': lng,
        if (nickname     != null) 'nickname':      nickname,
        if (gender       != null) 'gender':        gender,
        if (email        != null) 'email':         email,
        if (emailVerifyToken != null) 'email_verify_token': emailVerifyToken,
        if (accountType  != null) 'account_type':  accountType,
        if (sellerTier   != null) 'seller_tier':   sellerTier,
        if (businessName != null) 'business_name': businessName,
        if (businessCategory != null) 'business_category': businessCategory,
        if (businessLocation != null) 'business_location': businessLocation,
        if (businessDescription != null) 'business_description': businessDescription,
        if (profilePhoto != null) 'profile_photo': profilePhoto,
      }),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 201) {
      await _saveSession(
        data['access_token'], data['user_id'],
        name: data['name'],
        nickname: data['nickname'] as String?,
        email: email,
        phone: (data['phone'] as String?) ?? phone,
        accountType: data['account_type'] as String?,
        lat: lat,
        lng: lng,
        photo: data['profile_photo'] as String?,
        // Signup returns a refresh token just like login. It used to be
        // dropped here, so a new account could only be renewed by logging
        // in again with the stored password.
        refreshToken: data['refresh_token'] as String?,
      );
    }
    return data;
  }

  static Future<Map<String, dynamic>> login({
    required String phone,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: _headers,
      body: jsonEncode({'phone': phone, 'password': password}),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode == 200) {
      await _saveSession(
        data['access_token'], data['user_id'],
        name: data['name'],
        nickname: data['nickname'] as String?,
        phone: (data['phone'] as String?) ?? phone,
        accountType: data['account_type'] as String?,
        lat: (data['lat'] as num?)?.toDouble(),
        lng: (data['lng'] as num?)?.toDouble(),
        photo: data['profile_photo'] as String?,
        refreshToken: data['refresh_token'] as String?,
      );
    }
    return data;
  }

  /// Lets a buyer start selling, with the answers signup would have taken:
  /// [sellerTier] 'short_term' (a few items - nothing else needed) or
  /// 'long_term' (a business - name, category and location required). The
  /// server generates the display name (e.g. "Clanix · Wholesale · Sira")
  /// from those fields; the seller never free-types it.
  ///
  /// Through [apiClient], so an expired session is renewed rather than
  /// failing the last step of the setup. Throws [ApiException].
  static Future<Map<String, dynamic>> upgradeToSeller({
    required String sellerTier,
    String? businessName,
    String? businessCategory,
    String? businessLocation,
    String? businessDescription,
  }) async {
    final data = await apiClient.post('/auth/upgrade-to-seller', {
      'seller_tier': sellerTier,
      if (businessName != null) 'business_name': businessName,
      if (businessCategory != null) 'business_category': businessCategory,
      if (businessLocation != null) 'business_location': businessLocation,
      if (businessDescription != null && businessDescription.isNotEmpty)
        'business_description': businessDescription,
    }, timeout: const Duration(seconds: 30)) as Map<String, dynamic>;
    await rememberAccountType(data['account_type'] as String? ?? 'buyer_seller');
    return data;
  }

  /// Records an account-type change made elsewhere (e.g. the store
  /// wizard's upgrade step), so Profile and friends see it immediately.
  static Future<void> rememberAccountType(String accountType) async {
    currentUserAccountType = accountType;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_account_type', accountType);
  }

  static Future<Map<String, dynamic>> getMe() async {
    final response = await http.get(
      Uri.parse('$baseUrl/auth/me'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> updateProfile({
    String? nickname,
    String? profilePhoto,
  }) async {
    await http.patch(
      Uri.parse('$baseUrl/auth/profile'),
      headers: _headers,
      body: jsonEncode({
        if (nickname     != null) 'nickname':      nickname,
        if (profilePhoto != null) 'profile_photo': profilePhoto,
      }),
    ).timeout(const Duration(seconds: 30));
    if (nickname     != null) currentUserNickname = nickname;
    if (profilePhoto != null) {
      currentUserPhoto = profilePhoto;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_photo', profilePhoto);
    }
  }

  static Future<List<dynamic>> searchUsers(String q) async {
    final lat = currentUserLat;
    final lng = currentUserLng;
    final uri = Uri.parse('$baseUrl/auth/search').replace(queryParameters: {
      'q': q,
      if (lat != null) 'lat': lat.toString(),
      if (lng != null) 'lng': lng.toString(),
    });
    final response = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as List<dynamic>;
  }

  static Future<Map<String, dynamic>> getUserProfile(String userId) async {
    final lat = currentUserLat;
    final lng = currentUserLng;
    final uri = Uri.parse('$baseUrl/auth/user/$userId').replace(queryParameters: {
      if (lat != null) 'lat': lat.toString(),
      if (lng != null) 'lng': lng.toString(),
    });
    final response = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // Platform-wide, anonymised dispute-resolution stats (Volume 2 §2.3).
  // Public endpoint (no auth required), cheap Redis-cached read on the
  // backend. Returns null fields (not 0) when there's no resolved-dispute
  // data yet - callers should hide the stat rather than print "0%"/"null%".
  static Future<Map<String, dynamic>> getDisputeSummaryStats() async {
    final uri = Uri.parse('$baseUrl/disputes/v2/stats/summary');
    final response = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ── Location ──────────────────────────────────────────────────────────────

  static Future<void> updateLocation(double lat, double lng) async {
    try {
      currentUserLat = lat;
      currentUserLng = lng;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('user_lat', lat);
      await prefs.setDouble('user_lng', lng);
      await http.patch(
        Uri.parse('$baseUrl/auth/location').replace(
          queryParameters: {'lat': lat.toString(), 'lng': lng.toString()},
        ),
        headers: _headers,
      );
    } catch (_) {}
  }

  // ── Inbox ──────────────────────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getInbox() async {
    final uid = currentUserId;
    if (uid == null) return [];
    var response = await http.get(
      Uri.parse('$baseUrl/negotiate/inbox/$uid'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    // FIX (2026-08-13): same expired-token gap as checkIncomingCall above.
    // GlobalPollerService's every-~7s poll drives BOTH new-message and
    // incoming-call notifications through this one call, so an unhandled
    // 401 here silently killed both, not just the inbox screen itself.
    if (response.statusCode == 401 && await _tryRelogin()) {
      response = await http.get(
        Uri.parse('$baseUrl/negotiate/inbox/$uid'),
        headers: _headers,
      ).timeout(const Duration(seconds: 20));
    }
    if (response.statusCode == 200) {
      final List data = jsonDecode(response.body);
      return data.cast<Map<String, dynamic>>();
    }
    // Any non-200 (transient 5xx from a cold-starting server, an expired
    // token, a proxy error page, etc.) must THROW rather than return [] -
    // the caller (inbox_screen.dart) treats a returned value as "this is a
    // real, fresh, empty inbox" and caches it as such, which would
    // overwrite - and permanently destroy - whatever inbox was previously
    // cached on-device. Throwing lets the caller's existing catch block do
    // what it already correctly does: keep showing cached/stale data
    // instead of wiping it.
    throw Exception('Inbox request failed (${response.statusCode})');
  }

  // ── Listings ───────────────────────────────────────────────────────────────

  /// Real on-platform price comparison against similar active listings.
  /// has_enough_data is false when fewer than 3 comparable listings exist
  /// yet - the caller should fall back to general guidance in that case
  /// rather than presenting a misleading average.
  static Future<Map<String, dynamic>> getPriceComparison(String listingId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/$listingId/price-comparison'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Fetches the active deal's state for this listing/buyer pair, used to
  /// decide which delivery-confirmation buttons to show on the AI screen.
  static Future<Map<String, dynamic>> getDealStatus(
    String listingId, {
    String? buyerId,
  }) async {
    final uri = Uri.parse('$baseUrl/negotiate/deal-status/$listingId').replace(
      queryParameters: buyerId != null ? {'buyer_id': buyerId} : null,
    );
    final response = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getStats() async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/stats'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<List<Listing>> getListings({
    String? category,
    String? listingType,
    String? sellerId,
    double? minPrice,
    double? maxPrice,
    String? location,
    int limit = 20,
    int offset = 0,
  }) async {
    final uri = Uri.parse('$baseUrl/listings/').replace(queryParameters: {
      if (category    != null) 'category':     category,
      if (listingType != null) 'listing_type': listingType,
      if (sellerId    != null) 'seller_id':    sellerId,
      if (minPrice    != null) 'min_price':    minPrice.toString(),
      if (maxPrice    != null) 'max_price':    maxPrice.toString(),
      if (location != null && location.trim().isNotEmpty) 'location': location.trim(),
      'limit':  limit.toString(),
      'offset': offset.toString(),
    });
    final response = await http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30));
    final List data = jsonDecode(response.body);
    return data.map((e) => Listing.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<Listing> getListing(String listingId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/$listingId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    return Listing.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Real revenue-over-time for the seller dashboard chart, aggregated
  /// server-side from actually-completed deals. [period] is 'week' (7 daily
  /// buckets) or 'month' (6 weekly buckets).
  static Future<Map<String, dynamic>> getSellerRevenue(
      String sellerId, {String period = 'week'}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/seller/$sellerId/revenue?period=$period'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Failed to load revenue (${response.statusCode})');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Seller standing, daily history, and the advice cards.
  ///
  /// Own metrics only - the backend rejects any other seller_id with 403,
  /// because response time, backlog and rank position are competitive
  /// information and rank tells a rival exactly how far they have to climb.
  static Future<Map<String, dynamic>> getSellerMetrics(
      String sellerId, {int days = 90}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/seller/$sellerId/metrics?days=$days'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Failed to load seller metrics (${response.statusCode})');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Per-listing performance, history and advice.
  ///
  /// Own listings only - the backend returns 403 otherwise. View and like
  /// counts tell a competitor which of your products are moving and which
  /// are dead stock.
  static Future<Map<String, dynamic>> getListingMetrics(
      String listingId, {int days = 60}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/$listingId/metrics?days=$days'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Failed to load listing metrics (${response.statusCode})');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Completed payments on this seller's deals. Own receipts only.
  static Future<Map<String, dynamic>> getSellerReceipts(String sellerId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/seller/$sellerId/receipts'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Failed to load receipts (${response.statusCode})');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Update price and/or photos on your own listing.
  ///
  /// Price edits are rate-limited server-side: two per rolling week, at
  /// least 12 hours apart, and blocked outright while a deal is open on the
  /// listing. Those come back as 429 and 409 respectively, with a message
  /// written to be shown to the seller as-is.
  static Future<Map<String, dynamic>> updateListing(
      String listingId, {
      double? price,
      String? verifiedPhotos,
      String? showcaseImageUrl,
      }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/listings/$listingId'),
      headers: _headers,
      body: jsonEncode({
        if (price != null) 'price': price,
        if (verifiedPhotos != null) 'verified_photos': verifiedPhotos,
        if (showcaseImageUrl != null) 'showcase_image_url': showcaseImageUrl,
      }),
    ).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      // Surfaces the server's own wording - it explains WHY the limit
      // exists, and a generic "update failed" would make a deliberate rule
      // look like a bug.
      String msg = 'Could not update listing (${response.statusCode})';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (body['detail'] is String) msg = body['detail'] as String;
      } catch (_) {}
      throw Exception(msg);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// AI Showcase/Cover Image - pre-creation preview (2026-08-29). Called
  /// from the listing wizard's Showcase step, before the listing exists -
  /// see api/domains/showcase/service.py's generate_showcase_preview_
  /// standalone docstring. 120s timeout, same as creating the listing:
  /// image generation is the slowest call in this app by a wide margin
  /// (fal.ai's own poll budget server-side is 90s), so it gets the same
  /// generous headroom rather than the shorter default used elsewhere.
  static Future<Map<String, dynamic>> generateShowcasePreview(
      Map<String, dynamic> payload) async {
    final client = http.Client();
    try {
      var response = await client.post(
        Uri.parse('$baseUrl/showcase/preview'),
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 120));
      if (response.statusCode == 401) {
        final relogged = await _tryRelogin();
        if (relogged) {
          response = await client.post(
            Uri.parse('$baseUrl/showcase/preview'),
            headers: _headers,
            body: jsonEncode(payload),
          ).timeout(const Duration(seconds: 120));
        }
      }
      if (response.statusCode != 200) {
        throw Exception(
            'Showcase generation failed: ${response.statusCode} ${response.body}');
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  static Future<List<MatchResult>> getMatches(String listingId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/listings/$listingId/matches'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    final List data = jsonDecode(response.body);
    return data.map((e) => MatchResult.fromJson(e)).toList();
  }

  static Future<Map<String, dynamic>> expressInterest(
      String listingId, double? offerPrice) async {
    final response = await http.post(
      Uri.parse('$baseUrl/listings/$listingId/interest'),
      headers: _headers,
      body: jsonEncode({'offer_price': offerPrice}),
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ── Negotiate ──────────────────────────────────────────────────────────────

  /// POST /negotiate/chat, the endpoint behind [freeChat], [xxenoChat] and
  /// [zenoChat].
  ///
  /// The route requires sign-in and is rate-limited per user. It used to
  /// ignore the token entirely, so these callers never needed 401 recovery
  /// and never had it; an expired token now renews the session and retries
  /// once. Any other failure (429, 422, 5xx) throws with the server's
  /// message, so each screen's own catch shows its "Zeno is unavailable"
  /// text - [zenoChat] used to return '' instead, which rendered as an
  /// empty reply bubble.
  static Future<Map<String, dynamic>> _postChat(Map<String, dynamic> body) async {
    Future<http.Response> send() => http.post(
      Uri.parse('$baseUrl/negotiate/chat'),
      headers: _headers,
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 60));

    var response = await send();
    if (response.statusCode == 401 && _token != null && await _tryRelogin()) {
      response = await send();
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail']?.toString() ?? 'Zeno request failed (${response.statusCode})');
    }
    return data;
  }

  static Future<Message> freeChat({
    required String content,
    required List<Map<String, String>> history,
    String? userName,
  }) async {
    final data = await _postChat({
      'content':   content,
      'history':   history,
      'user_name': userName ?? currentUserName,
    });
    return Message.fromJson(data);
  }

  // Design Journal Volume 6, Ch.29 - ai_assistant_screen.dart's Advisor
  // persona posts here instead of /negotiate/chat. Path is
  // /negotiate/shopping-advisor, not /ai-broker/shopping-advisor as the
  // source spec assumed - main.py mounts ai_broker_router at /negotiate
  // (deliberately, to avoid a documented path-collision bug with the
  // legacy negotiate.router; see the comment there), not /ai-broker.
  static Future<ShoppingAdvisorResult> shoppingAdvisor({
    required String query,
    required List<Map<String, String>> history,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/negotiate/shopping-advisor'),
      headers: _headers,
      body: jsonEncode({'query': query, 'history': history}),
    ).timeout(const Duration(seconds: 60));
    return ShoppingAdvisorResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Pre-fills the Buy-Agent sheet's category/max_price/must_have_features
  /// from one free-text sentence. Returns nulls (never throws on a bad
  /// parse) so the caller can fall back to the buyer filling the same
  /// fields in by hand - matches the endpoint's own no-error contract.
  static Future<Map<String, dynamic>> parseBuyRequest(String text) async {
    final response = await http.post(
      Uri.parse('$baseUrl/buy-agent-requests/parse'),
      headers: _headers,
      body: jsonEncode({'text': text}),
    ).timeout(const Duration(seconds: 60));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // Legacy alias - calls the backend with the updated 'zeno' system override.
  // Kept for any callers not yet migrated to zenoChat().
  static Future<Message> xxenoChat({
    required String content,
    required List<Map<String, String>> history,
    String? userName,
    String? language,
  }) async {
    final data = await _postChat({
      'content':         content,
      'history':         history,
      'user_name':       userName ?? currentUserName,
      'system_override': 'zeno',  // updated: was 'xxeno'
      'language':        language ?? currentUserLanguage,
    });
    return Message.fromJson(data);
  }

  static Future<Message> sendNegotiationMessage({
    required String listingId,
    required String senderRole,
    required String senderId,
    required String content,
    String? buyerName,
    String? sellerName,
    double? buyerLat,
    double? buyerLng,
    double? sellerLat,
    double? sellerLng,
    // When seller sends a reply, pass the buyer's ID so the backend can scope
    // the broker replies to the correct buyer conversation thread.
    String? buyerIdForThread,
    // Explicit Zeno-screen intent: "opening_greeting" | "translate_for_me" |
    // null for a normal conversation message. See backend MessageIn docs.
    String? intent,
    String? imageBase64,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/negotiate/message'),
      headers: _headers,
      body: jsonEncode({
        'listing_id':  listingId,
        'sender_role': senderRole,
        'sender_id':   senderId,
        'content':     content,
        if (buyerName        != null) 'buyer_name':  buyerName,
        if (sellerName       != null) 'seller_name': sellerName,
        if (buyerLat         != null) 'buyer_lat':   buyerLat,
        if (buyerLng         != null) 'buyer_lng':   buyerLng,
        if (sellerLat        != null) 'seller_lat':  sellerLat,
        if (sellerLng        != null) 'seller_lng':  sellerLng,
        if (buyerIdForThread != null) 'buyer_id':    buyerIdForThread,
        if (intent           != null) 'intent':      intent,
        if (imageBase64      != null) 'image_base64': imageBase64,
        'language': currentUserLanguage,
      }),
    ).timeout(const Duration(seconds: 60));
    return Message.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  static Future<List<Message>> getNegotiationHistory(
    String listingId, {
    String? buyerId,
  }) async {
    final uri = Uri.parse('$baseUrl/negotiate/$listingId/history').replace(
      queryParameters: buyerId != null ? {'buyer_id': buyerId} : null,
    );
    final response = await _sendAuthed(() => http.get(uri, headers: _headers)
        .timeout(const Duration(seconds: 30)));
    // Explicit status check (rather than relying on non-2xx bodies
    // happening to fail the `as List` cast below) so a server error always
    // throws and never gets treated as "a real, empty conversation" -
    // negotiate_screen.dart/negotiation_screen.dart cache whatever this
    // returns, and an accidental empty-but-200 response would wipe that
    // cache exactly like the inbox bug did.
    if (response.statusCode != 200) {
      throw Exception('History request failed (${response.statusCode})');
    }
    final List data = jsonDecode(response.body);
    return data.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Tells the backend "I've read this thread up to right now" - drives
  /// both the inbox unread badge and the counterpart's "seen" ticks on
  /// their own sent messages. Fire-and-forget: a failed mark-read shouldn't
  /// block or error out the chat screen.
  /// Records that this device has RECEIVED a thread's messages, without
  /// claiming the user has looked at them. Distinct from markThreadRead:
  /// this is what turns the sender's single tick into a double tick.
  /// Ask Zeno for an SMS draft to the other party in a thread, or send one.
  ///
  /// Two-step by design: call with [text] null to get a draft, let the user
  /// edit it, then call again with their text and send: true. A one-shot
  /// draft-and-send would put Zeno's first attempt on someone's phone under
  /// the user's name with nobody having read it.
  static Future<Map<String, dynamic>?> zenoDraftSms({
    required String listingId,
    String? buyerId,
    String? text,
    bool send = false,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/negotiate/zeno-action/draft-sms'),
        headers: _headers,
        body: jsonEncode({
          'listing_id': listingId,
          if (buyerId != null) 'buyer_id': buyerId,
          if (text != null) 'text': text,
          'send': send,
        }),
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> markThreadDelivered(String listingId, {String? buyerId}) async {
    try {
      await _sendAuthed(() => http.post(
        Uri.parse('$baseUrl/negotiate/$listingId/mark-delivered'),
        headers: _headers,
        body: jsonEncode({if (buyerId != null) 'buyer_id': buyerId}),
      ).timeout(const Duration(seconds: 10)));
    } catch (_) {}
  }

  static Future<void> markThreadRead(String listingId, {String? buyerId}) async {
    try {
      await _sendAuthed(() => http.post(
        Uri.parse('$baseUrl/negotiate/$listingId/mark-read'),
        headers: _headers,
        body: jsonEncode({if (buyerId != null) 'buyer_id': buyerId}),
      ).timeout(const Duration(seconds: 10)));
    } catch (_) {}
  }

  /// When each side's device last received, and last read, this thread -
  /// {'buyer_last_read', 'seller_last_read', 'buyer_last_delivered',
  /// 'seller_last_delivered'} - used to compute per-message ticks.
  ///
  /// Null when the request failed. It used to return all-null watermarks
  /// instead, which the chat applied: one failed poll turned every "seen"
  /// tick back to a single grey one.
  static Future<Map<String, DateTime?>?> getReadStatus(
    String listingId, {
    String? buyerId,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/negotiate/$listingId/read-status').replace(
        queryParameters: buyerId != null ? {'buyer_id': buyerId} : null,
      );
      final response = await _sendAuthed(() => http.get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10)));
      if (response.statusCode == 200) {
        final m = jsonDecode(response.body) as Map<String, dynamic>;
        DateTime? at(String key) {
          final v = m[key];
          // Watermarks arrive as UTC ISO strings with a trailing Z, and so
          // does message.created_at, so both parse to absolute instants and
          // isBefore/isAfter compare them correctly whatever the device's
          // timezone. toLocal() here is purely so anything that later
          // formats one of these for display doesn't have to remember to.
          return v is String ? DateTime.tryParse(v)?.toLocal() : null;
        }
        return {
          'buyer_last_read':       at('buyer_last_read'),
          'seller_last_read':      at('seller_last_read'),
          'buyer_last_delivered':  at('buyer_last_delivered'),
          'seller_last_delivered': at('seller_last_delivered'),
        };
      }
    } catch (_) {}
    return null;
  }

  // ── Auction ────────────────────────────────────────────────────────────────

  /// Place a bid. Throws [BidRejection] when the backend refuses it.
  ///
  /// The refusal carries a machine-readable code, and it matters that this
  /// surfaces rather than being swallowed: the caller used to get an opaque
  /// map back on every outcome, so a REJECTED bid was indistinguishable
  /// from an accepted one and the auction screen "helpfully" drew the bid
  /// into the leaderboard anyway. A bid the server said no to must never
  /// appear to have worked.
  static Future<Map<String, dynamic>> placeBid({
    required String listingId,
    required double amount,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auction/bid'),
      headers: _headers,
      body: jsonEncode({'listing_id': listingId, 'amount': amount}),
    ).timeout(const Duration(seconds: 30));

    final body = jsonDecode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body as Map<String, dynamic>;
    }
    // FastAPI wraps our {"code", "message"} under "detail"; a plain string
    // detail (or anything unexpected) still becomes a rejection the UI can
    // show, just without a specific code to react to.
    final detail = (body is Map) ? body['detail'] : null;
    if (detail is Map) {
      throw BidRejection(
        detail['code'] as String? ?? 'BID_REJECTED',
        detail['message'] as String? ?? 'That bid was not accepted.',
      );
    }
    throw BidRejection(
      'BID_REJECTED',
      detail?.toString() ?? 'That bid was not accepted.',
    );
  }

  static Future<List<dynamic>> getLeaderboard(String listingId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/auction/$listingId/leaderboard'),
      headers: _headers,
    ).timeout(const Duration(seconds: 30));
    return jsonDecode(response.body) as List<dynamic>;
  }

  // ── Deal ───────────────────────────────────────────────────────────────────

  /// [quantity] is how many of the listing's units the deal is for (null:
  /// one); the backend refuses more than are left.
  static Future<Map<String, dynamic>> finalizeDeal({
    required String listingId,
    required String buyerId,
    required double agreedPrice,
    int? quantity,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/deal/finalize'),
      headers: _headers,
      body: jsonEncode({
        'listing_id':   listingId,
        'buyer_id':     buyerId,
        'agreed_price': agreedPrice,
        if (quantity != null) 'quantity': quantity,
      }),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    // This previously returned the raw decoded body unconditionally, so an
    // error response - e.g. {"detail": "..."} when a deal already exists
    // for this listing/buyer - was handled as if it were a real deal. The
    // caller then held a "deal" with no id and no commission: the M-Pesa
    // dialog showed "KES 0" (commission missing) and crashed with
    // "type 'Null' is not a subtype of type 'String' in type cast" the
    // moment Pay tried to read an id that was never there.
    // Any 2xx: POST /deal/finalize answers 201 Created. Checking for 200
    // alone turned every agreed deal into "Could not finalize deal" while
    // the deal sat created on the server, so nobody ever reached Pay.
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data['detail'] ?? 'Could not finalize deal');
    }
    return data;
  }

  // ── M-Pesa ─────────────────────────────────────────────────────────────────

  /// Initiates STK Push. Requires the user's BROKA password for authorization.
  /// Returns checkout_request_id on success.
  static Future<Map<String, dynamic>> mpesaStkPush({
    required String dealId,
    required String phoneNumber,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/mpesa/stk-push'),
      headers: _headers,
      body: jsonEncode({
        'deal_id':      dealId,
        'phone_number': phoneNumber,
        'password':     password,
      }),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail'] ?? 'STK push failed');
    }
    return data;
  }

  /// Polls Safaricom for the payment result.
  static Future<Map<String, dynamic>> mpesaQuery({
    required String checkoutRequestId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/mpesa/query'),
      headers: _headers,
      body: jsonEncode({'checkout_request_id': checkoutRequestId}),
    ).timeout(const Duration(seconds: 20));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Gets the latest payment status for a deal.
  static Future<Map<String, dynamic>> mpesaStatus(String dealId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/mpesa/status/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ── E-Confirm marketplace escrow (2026-09) ─────────────────────────────
  // Replaces mpesaStkPush above for the deal GOODS-PRICE payment only —
  // Daraja stays in place for featured/verification payments, which are
  // unrelated. See api/domains/escrow/router.py's /deal/{deal_id}/...
  // endpoints and api/core/econfirm_client.py.

  /// Real buyer-facing total (goods price + BROKA commission + E-Confirm's
  /// own fee) — call before showing the payment dialog so the amount
  /// shown is never a guess.
  static Future<Map<String, dynamic>> getEConfirmFeeQuote(String dealId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/deal/$dealId/fee-quote'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail'] ?? 'Could not get a payment quote');
    }
    return data;
  }

  /// Funds a deal's escrow through E-Confirm — creates the escrow first if
  /// one doesn't exist yet, then triggers the M-Pesa STK push, in one call.
  /// Safe to call again if a previous attempt's outcome was unclear: an
  /// existing escrow is reused server-side, never duplicated.
  static Future<Map<String, dynamic>> fundDealEscrow({
    required String dealId,
    required String payerPhone,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/deal/$dealId/fund'),
      headers: _headers,
      body: jsonEncode({'payer_phone': payerPhone}),
    ).timeout(const Duration(seconds: 30));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail'] ?? 'Could not start payment');
    }
    return data;
  }

  /// Polls BROKA — never E-Confirm directly — for this deal's current
  /// payment state. See screens/econfirm_payment_screen.dart.
  static Future<Map<String, dynamic>> getDealPaymentStatus(String dealId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/deal/$dealId/payment-status'),
      headers: _headers,
    ).timeout(const Duration(seconds: 20));
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw Exception(data['detail'] ?? 'Could not check payment status');
    }
    return data;
  }

  // ── Zeno AI Chat ────────────────────────────────────────────────────────────
  static Future<String> zenoChat({
    required String message,
    required List<Map<String, String>> history,
    String? language,
    String? imageBase64,
    String systemOverride = 'zeno',
  }) async {
    final data = await _postChat({
      'content':         message,
      'history':         history,
      'user_name':       currentUserName,
      'system_override': systemOverride,
      'language':        language ?? currentUserLanguage,
      if (imageBase64 != null) 'image_base64': imageBase64,
    });
    return data['content'] as String? ?? data['message'] as String? ?? '';
  }

  // ── Direct Chat (no AI mediation) ───────────────────────────────────────────

  /// Sends a direct-chat message and returns the server's copy of it (id,
  /// created_at, client_msg_id), or null from a server too old to send one.
  /// Throws when the message did not get there.
  ///
  /// It used to swallow every failure and return nothing, so the chat could
  /// neither say "not sent" nor tell the stored message from the one it was
  /// showing - it guessed by refetching the whole thread, and the guess
  /// raced the poll into a second bubble. [clientMsgId] is the chat's own
  /// id for the message; sending the same one again returns the row the
  /// first attempt stored rather than storing it twice.
  static Future<Map<String, dynamic>?> sendDirectMessage({
    required String listingId,
    required String senderRole,
    required String senderId,
    required String content,
    String? buyerIdForThread,
    String? buyerId,
    String? clientMsgId,
  }) async {
    final body = jsonEncode({
      'listing_id':  listingId,
      'sender_role': senderRole,
      'sender_id':   senderId,
      'content':     content,
      if (buyerIdForThread != null) 'buyer_id': buyerIdForThread,
      if (buyerId          != null) 'buyer_id': buyerId,
      if (clientMsgId      != null) 'client_msg_id': clientMsgId,
    });
    final response = await _sendAuthed(() => http.post(
      Uri.parse('$baseUrl/negotiate/direct-message'),
      headers: _headers,
      body: body,
    ).timeout(const Duration(seconds: 20)));
    if (response.statusCode != 200) {
      throw Exception(_extractError(response.body));
    }
    try {
      final data = jsonDecode(response.body);
      final message = data is Map ? data['message'] : null;
      return message is Map ? Map<String, dynamic>.from(message) : null;
    } catch (_) {
      return null;
    }
  }

  // ── Media upload (voice notes + images) ────────────────────────────────────
  static Future<Map<String, dynamic>> uploadMedia({
    required String listingId,
    required String senderRole,
    required String senderId,
    required String contentType,   // "audio" | "image"
    required Uint8List fileBytes,
    required String fileName,
    required String mimeType,
    String?  buyerId,
    int?     durationSecs,
    // The chat's own id for this voice note or photo - see sendDirectMessage.
    String?  clientMsgId,
  }) async {
    final uri = Uri.parse('$baseUrl/media/upload');
    // A request can be sent once, so the retry after a renewal builds anew.
    Future<http.Response> send() async {
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${_token ?? ""}'
        ..fields['listing_id']   = listingId
        ..fields['sender_role']  = senderRole
        ..fields['sender_id']    = senderId
        ..fields['content_type'] = contentType
        ..files.add(http.MultipartFile.fromBytes('file', fileBytes,
            filename: fileName,
            contentType: MediaType.parse(mimeType)));
      if (buyerId      != null) request.fields['buyer_id']      = buyerId;
      if (durationSecs != null) request.fields['duration_secs'] = durationSecs.toString();
      if (clientMsgId  != null) request.fields['client_msg_id'] = clientMsgId;
      final streamed = await request.send().timeout(const Duration(seconds: 60));
      return http.Response.fromStream(streamed);
    }

    final res = await _sendAuthed(send);
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Online presence ────────────────────────────────────────────────────────
  /// Call this periodically to update the user's last_seen timestamp.
  static Future<void> updateLastSeen() async {
    try {
      // Backend route is `@router.patch("/auth/heartbeat")` - this used to
      // call .post(), which 405'd on every single call (silently swallowed
      // below), so last_seen never updated and "online"/"last seen" never
      // worked anywhere in the app.
      await http.patch(
        Uri.parse('$baseUrl/auth/heartbeat'),
        headers: _headers,
      ).timeout(const Duration(seconds: 5));
    } catch (_) {} // non-fatal
  }

  // ── FCM / Push Notifications ───────────────────────────────────────────────

  /// This phone's FCM token as last registered, so signing out can take it
  /// off the account.
  static String? registeredPushToken;

  /// Register this device's FCM token with the backend so we can receive
  /// calls, messages and alerts on it with the app closed.
  static Future<bool?> registerFcmToken(String token) =>
      registerPushToken(token, tokenType: 'fcm');

  /// Registers a push token for this phone. Returns whether the server can
  /// push at all (`push_enabled`), or null when registering failed.
  ///
  /// [tokenType] is 'fcm' (Android, and iOS non-call notifications) or
  /// 'apns_voip' (iOS PushKit). They are different tokens delivered over
  /// different transports and must be stored separately - iOS needs a VoIP
  /// push, not a normal alert, to wake a terminated app for a call.
  ///
  /// Through [apiClient], which renews an expired session and retries: the
  /// raw request this used to be sent the access token as it was - often
  /// expired by the time a restored session got here - and ignored the 401.
  static Future<bool?> registerPushToken(String token,
      {String tokenType = 'fcm'}) async {
    try {
      final res = await apiClient.post('/calls/register-token', {
        'fcm_token': token,
        'token_type': tokenType,
        'platform': _platformName,
      }, timeout: const Duration(seconds: 15));
      if (tokenType == 'fcm') registeredPushToken = token;
      return res is Map ? res['push_enabled'] == true : false;
    } catch (_) {
      return null;
    }
  }

  /// Take this phone off the signed-in account, so it stops getting that
  /// account's calls and messages. Best effort - signing out never waits
  /// on it for long.
  static Future<void> unregisterPushToken(String token) async {
    try {
      await apiClient.post('/calls/unregister-token', {'fcm_token': token},
          timeout: const Duration(seconds: 6));
    } catch (_) {}
  }

  static String get _platformName {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return defaultTargetPlatform.name;
    }
  }

  /// Tell the server this phone is ringing with [roomId], so the caller's
  /// screen says "Ringing". Authorized by the call token the incoming-call
  /// push (or GET /calls/pending) carries - it works from a closed app,
  /// whose access token is usually long expired.
  ///
  /// [CallAlertResult.over] means the call already ended: the push arrived
  /// late, and whatever is ringing should stop.
  static Future<CallAlertResult> reportCallAlerted(
      String roomId, String callToken) async {
    if (roomId.isEmpty || callToken.isEmpty) return CallAlertResult.unknown;
    try {
      final res = await http
          .post(
            Uri.parse('$baseUrl/calls/${Uri.encodeComponent(roomId)}/alerted'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'call_token': callToken}),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) return CallAlertResult.ringing;
      if (res.statusCode == 404 || res.statusCode == 410) {
        return CallAlertResult.over;
      }
    } catch (_) {}
    return CallAlertResult.unknown;
  }

  /// Tell the server the callee answered [roomId] - the moment Accept is
  /// pressed, not when the call's connection comes up seconds later. The
  /// server stops reporting the call as ringing (so this phone does not
  /// ring for it again while it connects) and stops the callee's other
  /// phones ringing. Best effort: joining the call says the same, later.
  static Future<void> answerCall(String roomId, String callToken) async {
    if (roomId.isEmpty || callToken.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse('$baseUrl/calls/${Uri.encodeComponent(roomId)}/answer'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'call_token': callToken}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// The call ringing for me right now, on any listing: one request instead
  /// of one per chat thread. `supported` is false against a server without
  /// GET /calls/incoming, so the caller can fall back to asking per listing.
  /// `known` is false when the server could not be asked (no signal, a
  /// timeout): "no call" then means "don't know", and nothing that is
  /// ringing may be taken down on the strength of it.
  static Future<({bool supported, bool known, Map<String, dynamic>? call})>
      checkAnyIncomingCall() async {
    Future<http.Response> send() => http
        .get(Uri.parse('$baseUrl/calls/incoming'), headers: _headers)
        .timeout(const Duration(seconds: 5));
    try {
      var response = await send();
      if (response.statusCode == 401 && await _tryRelogin()) {
        response = await send();
      }
      if (response.statusCode == 404 || response.statusCode == 405) {
        return (supported: false, known: false, call: null);
      }
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data['has_call'] == true) {
          return (supported: true, known: true, call: Map<String, dynamic>.from(data));
        }
        return (supported: true, known: true, call: null);
      }
    } catch (_) {}
    return (supported: true, known: false, call: null);
  }

  /// Notify the seller (via FCM) that a call is incoming, and get back the
  /// server-generated room_id + a call_token scoped to it for the caller's
  /// own WebSocket connection. Returns null on failure (network error, or
  /// a 401 that survives a relogin attempt) - the caller must not navigate
  /// to the VoIP screen in that case, since there's no valid room_id/token
  /// to connect with.
  static Future<Map<String, dynamic>?> initiateCall({
    required String listingId,
    required String listingName,
    String callType = 'audio', // 'audio' | 'video'
    String? calleeId, // required when the SELLER is calling - see calls.py's initiate_call()
  }) async {
    Future<http.Response> send() => http.post(
      Uri.parse('$baseUrl/calls/initiate'),
      headers: _headers,
      body: jsonEncode({
        'listing_id':   listingId,
        'caller_name':  currentUserName ?? 'Buyer',
        'listing_name': listingName,
        'call_type':    callType,
        if (calleeId != null) 'callee_id': calleeId,
      }),
    ).timeout(const Duration(seconds: 10));
    try {
      var response = await send();
      // FIX (2026-08-13): this used to swallow every outcome, including a
      // 401 - meaning if the CALLER's own access token had expired, the
      // call never registered server-side and the buyer would sit on the
      // VoIP screen believing it was ringing while the seller's poll
      // correctly found nothing to return at all. One retry after a
      // successful refresh/relogin covers this.
      if (response.statusCode == 401 && await _tryRelogin()) {
        response = await send();
      }
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      // One call at a time (calls.py _admit_call): the server would not
      // place it, and says why - {code, message, call?}. Returned as
      // {'refused': ...}; NotificationService.handleCallRefused acts on it.
      if (response.statusCode == 409) {
        final detail = (jsonDecode(response.body) as Map)['detail'];
        if (detail is Map) {
          return {'refused': Map<String, dynamic>.from(detail)};
        }
      }
    } catch (_) {}
    return null;
  }

  /// Record a call's outcome ("completed" | "missed" | "declined") so both
  /// buyer and seller see a call-history card in their direct-chat thread.
  ///
  /// roomId is now required (Section 16, V2 hardening) - the backend
  /// derives listing/buyer/caller-role from the authoritative call
  /// session instead of trusting client-supplied values, and only an
  /// actual participant of that call can log its result. listingId/
  /// buyerId/callerRole are still sent for backward-compat with any
  /// older backend build, but a current one ignores them in favor of
  /// what it derives from roomId.
  static Future<void> logCallResult({
    required String roomId,
    required String listingId,
    required String buyerId,
    required String outcome,
    required String callerRole,
    int? durationSecs,
    String callType = 'audio', // 'audio' | 'video'
  }) async {
    final body = jsonEncode({
      'room_id':      roomId,
      'listing_id':   listingId,
      'buyer_id':     buyerId,
      'outcome':      outcome,
      'caller_role':  callerRole,
      if (durationSecs != null) 'duration_secs': durationSecs,
      'call_type':    callType,
    });
    Future<http.Response> send() => http.post(
      Uri.parse('$baseUrl/calls/log-result'),
      headers: _headers,
      body: body,
    ).timeout(const Duration(seconds: 10));
    try {
      // Same 401-retry-once as the other /calls requests. This one matters
      // more than it looks: "declined" is also how the caller learns they
      // were declined, and Decline on the incoming-call notification is
      // often pressed from an app that has sat in the background past the
      // 15-minute access token - without the retry the caller just kept
      // ringing.
      final response = await send();
      if (response.statusCode == 401 && await _tryRelogin()) {
        await send();
      }
    } catch (_) {} // non-fatal - don't block call teardown on logging
  }

  // ── WebRTC (Cloudflare TURN credentials) ───────────────────────────────────

  /// Fetches short-lived Cloudflare TURN/STUN ICE server credentials for
  /// the call about to start. Returns null on any failure (backend not
  /// configured, network error, non-200) so WebRtcService can fall back to
  /// STUN-only ICE and still attempt a direct P2P connection instead of
  /// failing the call outright.
  static Future<Map<String, dynamic>?> getTurnCredentials() async {
    try {
      var response = await http.get(
        Uri.parse('$baseUrl/calls/turn-credentials'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));
      // Same 401-retry-once pattern as the other /calls endpoints above -
      // an expired access token shouldn't silently fail call setup when a
      // refresh/relogin could recover it.
      if (response.statusCode == 401 && await _tryRelogin()) {
        response = await http.get(
          Uri.parse('$baseUrl/calls/turn-credentials'),
          headers: _headers,
        ).timeout(const Duration(seconds: 10));
      }
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {} // non-fatal - caller falls back to STUN-only ICE
    return null;
  }

  // ── Featured Listing Boost ─────────────────────────────────────────────────

  static Future<List<Map<String, dynamic>>> getMyBoostableListings() async {
    final res = await http.get(
      Uri.parse('$baseUrl/featured/my-listings'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(data['listings'] as List);
  }

  static Future<Map<String, dynamic>> boostListing({
    required String listingId,
    required String plan,
    required String phone,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/featured/boost'),
      headers: _headers,
      body: jsonEncode({
        'listing_id':   listingId,
        'plan':         plan,
        'phone_number': phone,
      }),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> checkBoostStatus(String listingId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/featured/status/$listingId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Seller Verification ────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> buyVerification({
    required String tier,
    required String phone,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/verify/purchase'),
      headers: _headers,
      body: jsonEncode({
        'tier':         tier,
        'phone_number': phone,
      }),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> checkVerificationStatus() async {
    final res = await http.get(
      Uri.parse('$baseUrl/verify/status'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Dispute Assistant ──────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> openDispute({
    required String dealId,
    required String issueType,
    required String description,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/disputes/open'),
      headers: _headers,
      body: jsonEncode({
        'deal_id':     dealId,
        'issue_type':  issueType,
        'description': description,
      }),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> mediateDispute({
    required String disputeId,
    String? buyerReply,
    String? mpesaReceipt,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/disputes/mediate'),
      headers: _headers,
      body: jsonEncode({
        'dispute_id':  disputeId,
        if (buyerReply    != null) 'buyer_reply':   buyerReply,
        if (mpesaReceipt  != null) 'mpesa_receipt': mpesaReceipt,
      }),
    ).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> disputeChat({
    required String disputeId,
    required String message,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/disputes/chat'),
      headers: _headers,
      body: jsonEncode({
        'dispute_id': disputeId,
        'message':    message,
      }),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> executeDispute({
    required String disputeId,
    required String zacCode,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/disputes/execute'),
      headers: _headers,
      body: jsonEncode({
        'dispute_id': disputeId,
        'zac_code':   zacCode,
      }),
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }



  // ──────────────────────────────────────────────────────────────────────
  // Speech-to-Text (Whisper)
  // ──────────────────────────────────────────────────────────────────────

  /// Uploads a recorded audio file to /stt/transcribe and returns the text.
  /// [audioBytes] should be raw bytes (m4a/mp3/wav/ogg/webm). [filename] is the
  /// hint shown to the server (used for the multipart filename field).
  static Future<String> transcribeAudio({
    required List<int> audioBytes,
    String filename = 'audio.m4a',
    String language = 'english',
  }) async {
    final uri = Uri.parse('$baseUrl/stt/transcribe');
    final req = http.MultipartRequest('POST', uri);
    if (_token != null) {
      req.headers['Authorization'] = 'Bearer $_token';
    }
    req.fields['language'] = language;
    req.files.add(http.MultipartFile.fromBytes('file', audioBytes, filename: filename));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200) {
      throw Exception(_extractError(res.body));
    }
    final m = jsonDecode(res.body) as Map<String, dynamic>;
    return (m['text'] ?? '').toString();
  }

  // ──────────────────────────────────────────────────────────────────────
  // Escrow
  // ──────────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> confirmDelivery(String dealId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/escrow/confirm-delivery/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getEscrowState(String dealId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/escrow/state/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> freezeForDispute(String dealId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/escrow/open-dispute/$dealId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  // Admin (only callable by users with is_admin=true on the backend)
  // ──────────────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> adminSummary() async {
    final res = await http.get(
      Uri.parse('$baseUrl/admin/summary'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception(_extractError(res.body));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static String _extractError(String body) {
    try {
      final m = jsonDecode(body) as Map;
      return m['detail']?.toString() ?? 'Unknown error';
    } catch (_) {
      return body.length > 120 ? '${body.substring(0, 120)}…' : body;
    }
  }
  // ── Incoming call check (polls for active call rooms) ─────────────────────
  static Future<Map<String, dynamic>?> checkIncomingCall(String listingId) async =>
      (await checkIncomingCallStatus(listingId)).call;

  /// The call ringing me on [listingId], if any - and whether the server
  /// answered at all. `known` is false on a timeout, a network error or a
  /// 5xx: "couldn't tell", which must never be read as "no call". Read
  /// that way, a live call whose check timed out on a weak signal was
  /// taken down and marked done, and never rang (review, 2026-10-08).
  static Future<({bool known, Map<String, dynamic>? call})>
      checkIncomingCallStatus(String listingId) async {
    try {
      var response = await http.get(
        Uri.parse('$baseUrl/calls/pending/$listingId'),
        headers: _headers,
      ).timeout(const Duration(seconds: 3));
      // FIX (2026-08-13, reported as "callee never sees an incoming call"):
      // a 401 here (access token expired - ACCESS_TOKEN_EXPIRE_MINUTES is
      // 15) used to just fall through to "no call", with no recovery.
      // GlobalPollerService calls this every ~7s in the background - once
      // the token expired, incoming-call detection silently stopped
      // working for the rest of the session, with nothing visibly wrong
      // anywhere (no error, no crash, just permanent silence). One retry
      // after a successful refresh/relogin (_tryRelogin, now that
      // register()/login() actually issue a refresh token - see
      // AuthService._issue_refresh_token on the backend) covers the
      // common case.
      if (response.statusCode == 401 && await _tryRelogin()) {
        response = await http.get(
          Uri.parse('$baseUrl/calls/pending/$listingId'),
          headers: _headers,
        ).timeout(const Duration(seconds: 3));
      }
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (
          known: true,
          call: data is Map<String, dynamic> && data['has_call'] == true ? data : null,
        );
      }
      if (response.statusCode == 404) return (known: true, call: null);
    } catch (_) {}
    return (known: false, call: null);
  }

}


/// What the server said when this phone reported an incoming call ringing.
enum CallAlertResult {
  /// The call is still ringing; the caller now sees "Ringing".
  ringing,

  /// The call is over (answered elsewhere, declined, missed, ended).
  over,

  /// No answer from the server - assume it is still ringing.
  unknown,
}
