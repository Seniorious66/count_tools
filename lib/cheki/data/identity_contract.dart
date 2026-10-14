import 'catalog_contract.dart';

enum IdentityKind {
  person('同一人', 'cheki_persons'),
  member('成员', 'cheki_members');

  const IdentityKind(this.label, this.table);
  final String label;
  final String table;
}

class IdentityEntity {
  IdentityEntity.fromRow(
    this.kind,
    Map<String, Object?> row, {
    this.fallbackColorRgb,
  }) : _raw = copySqlRow(row) {
    CatalogEntity.fromRow(row);
    if (row['source'] != 'user') throw const FormatException('身份来源无效');
    if (kind == IdentityKind.member &&
        ((row['group_id'] != null &&
                (row['group_id'] is! String ||
                    (row['group_id'] as String).trim().isEmpty)) ||
            (row['person_id'] != null &&
                (row['person_id'] is! String ||
                    (row['person_id'] as String).trim().isEmpty)) ||
            (row['color_rgb'] != null &&
                (row['color_rgb'] is! int ||
                    (row['color_rgb'] as int) < 0 ||
                    (row['color_rgb'] as int) > 0xffffff)))) {
      throw const FormatException('成员归属或颜色无效');
    }
  }
  final IdentityKind kind;
  final Map<String, Object?> _raw;
  final int? fallbackColorRgb;
  String get id => _raw['id'] as String;
  String? get knownName => _raw['name'] as String?;
  String get name =>
      knownName == null || knownName!.trim().isEmpty ? '未填写名称' : knownName!;
  bool get active => _raw['active'] == 1;
  int get revision => _raw['revision'] as int;
  String get createdAt => _raw['created_at'] as String;
  String get updatedAt => _raw['updated_at'] as String;
  String? get groupId => _raw['group_id'] as String?;
  String? get personId => _raw['person_id'] as String?;
  int? get colorRgb => (_raw['color_rgb'] as int?) ?? fallbackColorRgb;
  Map<String, Object?> toRow() => copySqlRow(_raw);
}
