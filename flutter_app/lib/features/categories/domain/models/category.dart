// lib/features/categories/domain/models/category.dart
class Category {
  final String id;
  final String name;
  final String? icon;
  final String? parentId;
  Category({required this.id, required this.name, this.icon, this.parentId});
  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: json['id'] as String,
        name: json['name'] as String,
        icon: json['icon'] as String?,
        parentId: json['parent_id'] as String?,
      );
}

class CategoryFilterField {
  final String fieldName;
  final String fieldType;
  final List<String>? options;
  CategoryFilterField({required this.fieldName, required this.fieldType, this.options});
  factory CategoryFilterField.fromJson(Map<String, dynamic> json) => CategoryFilterField(
        fieldName: json['field_name'] as String,
        fieldType: json['field_type'] as String,
        options: (json['options'] as List?)?.map((e) => e.toString()).toList(),
      );
}
