// lib/features/categories/data/repositories/categories_repository.dart
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/category.dart';

class CategoriesRepository {
  final ApiClient _client;
  CategoriesRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<List<Category>>> getTopLevel() async {
    try {
      final res = await _client.get('/categories');
      return Success((res as List).map((e) => Category.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<List<Category>>> getSubcategories(String categoryId) async {
    try {
      final res = await _client.get('/categories/$categoryId/subcategories');
      return Success((res as List).map((e) => Category.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<List<CategoryFilterField>>> getFilters(String categoryId) async {
    try {
      final res = await _client.get('/categories/$categoryId/filters');
      return Success((res as List).map((e) => CategoryFilterField.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final categoriesRepository = CategoriesRepository();
