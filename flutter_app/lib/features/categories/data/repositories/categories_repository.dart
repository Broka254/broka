// lib/features/categories/data/repositories/categories_repository.dart
import '../../../../core/cache/screen_cache.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/category.dart';
import '../../../../core/errors/user_facing_error.dart';

class CategoriesRepository {
  final ApiClient _client;
  CategoriesRepository({ApiClient? client}) : _client = client ?? apiClient;

  /// The top-level categories, from the phone's copy while it is younger
  /// than CachePolicies.categories (they change with a release, not by the
  /// minute - Home asked for them on every open). [forceRefresh] (a pull)
  /// asks the server; a failed request falls back to the saved copy, however
  /// old, rather than an empty rail.
  Future<Result<List<Category>>> getTopLevel({bool forceRefresh = false}) async {
    final key = CacheKey.public(CacheFeature.categories);
    final cache = ScreenCache.instance;
    final saved = await cache.read(key, CachePolicies.categories);
    List<Category>? parse(Object? data) {
      if (data is! List) return null;
      try {
        return data.map((e) => Category.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        return null;
      }
    }

    if (!forceRefresh && saved != null && saved.isFresh) {
      final cached = parse(saved.data);
      if (cached != null && cached.isNotEmpty) return Success(cached);
    }
    try {
      final res = await cache.fetch(key, () => _client.get('/categories'));
      return Success((res as List).map((e) => Category.fromJson(e)).toList());
    } on ApiException catch (e) {
      final cached = parse(saved?.data);
      if (cached != null && cached.isNotEmpty) return Success(cached);
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      final cached = parse(saved?.data);
      if (cached != null && cached.isNotEmpty) return Success(cached);
      return Failure(userFacingError(e));
    }
  }

  /// Every category with its subcategories in one request - the sell
  /// wizard's category step searches all of them at once.
  Future<Result<List<CategoryNode>>> getTree() async {
    try {
      final res = await _client.get('/categories/tree');
      return Success((res as List)
          .map((e) => CategoryNode.fromJson(e as Map<String, dynamic>))
          .toList());
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  /// A category's types of item, from the phone's copy while it is younger
  /// than CachePolicies.categoryInfo. Every visit to a Category Zone asked
  /// for them again; they change when BROKA seeds a new type.
  Future<Result<List<Category>>> getSubcategories(String categoryId,
          {bool forceRefresh = false}) =>
      _cachedList(
        CacheKey.public(CacheFeature.categoryInfo, {'subcategories': categoryId}),
        () => _client.get('/categories/$categoryId/subcategories'),
        (e) => Category.fromJson(e as Map<String, dynamic>),
        forceRefresh: forceRefresh,
      );

  /// A category's (or a type's) filter fields, the same way.
  Future<Result<List<CategoryFilterField>>> getFilters(String categoryId,
          {bool forceRefresh = false}) =>
      _cachedList(
        CacheKey.public(CacheFeature.categoryInfo, {'filters': categoryId}),
        () => _client.get('/categories/$categoryId/filters'),
        (e) => CategoryFilterField.fromJson(e as Map<String, dynamic>),
        forceRefresh: forceRefresh,
      );

  /// The saved copy when it is current; else the server, falling back to
  /// the saved copy (however old) if the server can't be reached. An empty
  /// list is a real answer (a category with no types) and is kept too.
  Future<Result<List<T>>> _cachedList<T>(
    CacheKey key,
    Future<Object?> Function() load,
    T Function(Object? json) parseOne, {
    bool forceRefresh = false,
  }) async {
    final cache = ScreenCache.instance;
    final saved = await cache.read(key, CachePolicies.categoryInfo);
    List<T>? parse(Object? data) {
      if (data is! List) return null;
      try {
        return data.map(parseOne).toList();
      } catch (_) {
        return null;
      }
    }

    if (!forceRefresh && saved != null && saved.isFresh) {
      final cached = parse(saved.data);
      if (cached != null) return Success(cached);
    }
    try {
      final res = await cache.fetch(key, load);
      return Success((res as List).map(parseOne).toList());
    } on ApiException catch (e) {
      final cached = parse(saved?.data);
      if (cached != null) return Success(cached);
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      final cached = parse(saved?.data);
      if (cached != null) return Success(cached);
      return Failure(userFacingError(e));
    }
  }
}

final categoriesRepository = CategoriesRepository();
