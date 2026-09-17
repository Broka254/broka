// BROKA v3.0 - Auth Repository
// Single source of truth for auth operations. Feature screens call this,
// not ApiService or http directly.

import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/user.dart';

class AuthRepository {
  final ApiClient _client;

  AuthRepository({ApiClient? client}) : _client = client ?? apiClient;

  // ── Session state ─────────────────────────────────────────────────────────

  String? _currentUserId;
  String? _currentUserName;
  String? _currentUserNickname;
  String? _currentUserEmail;
  String? _currentUserPhone;
  double? _currentUserLat;
  double? _currentUserLng;
  String  _currentUserLanguage = 'english';
  String? _currentUserPhoto;

  String? get currentUserId       => _currentUserId;
  String? get currentUserName     => _currentUserName;
  String? get currentUserNickname => _currentUserNickname;
  String? get currentUserEmail    => _currentUserEmail;
  String? get currentUserPhone    => _currentUserPhone;
  double? get currentUserLat      => _currentUserLat;
  double? get currentUserLng      => _currentUserLng;
  String  get currentUserLanguage => _currentUserLanguage;
  String? get currentUserPhoto    => _currentUserPhoto;
  bool    get isLoggedIn          => _client.isAuthenticated;

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> loadSavedSession() async {
    await _client.loadToken();
    final prefs = await SharedPreferences.getInstance();
    _currentUserId       = prefs.getString('user_id');
    _currentUserName     = prefs.getString('user_name');
    _currentUserNickname = prefs.getString('user_nickname');
    _currentUserEmail    = prefs.getString('user_email');
    _currentUserPhoto    = prefs.getString('user_photo');
    _currentUserLat      = prefs.getDouble('user_lat');
    _currentUserLng      = prefs.getDouble('user_lng');
    _currentUserLanguage = prefs.getString('user_language') ?? 'english';
    _currentUserPhone    = prefs.getString('user_phone');
  }

  Future<void> _persistSession(Map<String, dynamic> data, {
    required String email,
    String? password,
    double? lat,
    double? lng,
    String? phone,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final token  = data['access_token'] as String;
    final userId = data['user_id']      as String;
    await _client.saveToken(token);
    _currentUserId       = userId;
    _currentUserName     = data['name']          as String?;
    _currentUserNickname = data['nickname']       as String?;
    _currentUserEmail    = email;
    _currentUserPhoto    = data['profile_photo']  as String?;
    _currentUserLat      = lat ?? (data['lat'] as num?)?.toDouble();
    _currentUserLng      = lng ?? (data['lng'] as num?)?.toDouble();
    _currentUserPhone    = phone;
    await prefs.setString('user_id',    userId);
    await prefs.setString('user_email', email);
    if (_currentUserName     != null) await prefs.setString('user_name',     _currentUserName!);
    if (_currentUserNickname != null) await prefs.setString('user_nickname', _currentUserNickname!);
    if (_currentUserPhoto    != null) await prefs.setString('user_photo',    _currentUserPhoto!);
    if (_currentUserLat      != null) await prefs.setDouble('user_lat',      _currentUserLat!);
    if (_currentUserLng      != null) await prefs.setDouble('user_lng',      _currentUserLng!);
    if (phone                != null) await prefs.setString('user_phone',    phone);
    if (password             != null) await prefs.setString('user_password', password);
  }

  Future<void> clearSession() async {
    await _client.clearToken();
    _currentUserId = _currentUserName = _currentUserNickname =
        _currentUserEmail = _currentUserPhoto = _currentUserPhone = null;
    _currentUserLat = _currentUserLng = null;
    _currentUserLanguage = 'english';
    final prefs = await SharedPreferences.getInstance();
    for (final k in ['user_id','user_name','user_nickname','user_email',
        'user_photo','user_lat','user_lng','user_language','user_phone',
        'user_password']) {
      await prefs.remove(k);
    }
  }

  // ── Auth Operations ───────────────────────────────────────────────────────

  Future<Result<BrokaUser>> register({
    required String name,
    required String email,
    required String phone,
    required String password,
    required double lat,
    required double lng,
    String? nickname,
    String? profilePhoto,
  }) async {
    try {
      final data = await _client.post('/auth/register', {
        'name': name, 'email': email, 'phone': phone,
        'password': password, 'lat': lat, 'lng': lng,
        if (nickname     != null) 'nickname':      nickname,
        if (profilePhoto != null) 'profile_photo': profilePhoto,
      });
      await _persistSession(data, email: email, password: password,
          lat: lat, lng: lng, phone: phone);
      return Success(BrokaUser.fromJson({...data, 'email': email}));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<BrokaUser>> login({
    required String email,
    required String password,
  }) async {
    try {
      final data = await _client.post('/auth/login', {
        'email': email, 'password': password,
      });
      await _persistSession(data, email: email, password: password);
      return Success(BrokaUser.fromJson({...data, 'email': email}));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<BrokaUser>> getMe() async {
    try {
      final data = await _client.get('/auth/me');
      return Success(BrokaUser.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<void>> updateProfile({
    String? nickname,
    String? profilePhoto,
  }) async {
    try {
      await _client.patch('/auth/profile', {
        if (nickname     != null) 'nickname':      nickname,
        if (profilePhoto != null) 'profile_photo': profilePhoto,
      });
      if (nickname     != null) _currentUserNickname = nickname;
      if (profilePhoto != null) {
        _currentUserPhoto = profilePhoto;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_photo', profilePhoto);
      }
      return const Success(null);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<void>> updateLocation(double lat, double lng) async {
    try {
      _currentUserLat = lat;
      _currentUserLng = lng;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('user_lat', lat);
      await prefs.setDouble('user_lng', lng);
      await _client.patch(
        '/auth/location?lat=$lat&lng=$lng', {},
      );
      return const Success(null);
    } on ApiException catch (e) {
      return Failure(e.message);
    } catch (_) {
      return const Success(null); // silent failure for location updates
    }
  }

  Future<Result<void>> setLanguage(String language) async {
    try {
      _currentUserLanguage = language;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_language', language);
      await _client.patch('/auth/language?language=$language', {});
      return const Success(null);
    } catch (_) {
      return const Success(null);
    }
  }

  Future<Result<BrokaUser>> getUserProfile(String userId) async {
    try {
      final params = <String, String>{};
      if (_currentUserLat != null) params['lat'] = _currentUserLat.toString();
      if (_currentUserLng != null) params['lng'] = _currentUserLng.toString();
      final data = await _client.get('/auth/user/$userId', queryParams: params);
      return Success(BrokaUser.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<List<BrokaUser>>> searchUsers(String q) async {
    try {
      final params = <String, String>{'q': q};
      if (_currentUserLat != null) params['lat'] = _currentUserLat.toString();
      if (_currentUserLng != null) params['lng'] = _currentUserLng.toString();
      final data = await _client.get('/auth/search', queryParams: params) as List;
      return Success(data.map((e) => BrokaUser.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

// Singleton
final authRepository = AuthRepository();
