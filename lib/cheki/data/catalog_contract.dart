import 'dart:convert';
import 'dart:typed_data';
import '../domain/record_contract.dart';

enum CatalogKind {
  group('团体', 'cheki_groups'),
  size('尺寸', 'cheki_sizes');

  const CatalogKind(this.label, this.table);
  final String label;
  final String table;
}

String actionStamp(DateTime instant) => DateTime.fromMillisecondsSinceEpoch(
  instant.toUtc().millisecondsSinceEpoch ~/ 1000 * 1000,
  isUtc: true,
).toIso8601String();

bool isActionStamp(Object? value) {
  if (value is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.000Z$').hasMatch(value)) {
    return false;
  }
  try {
    OccurredOn.parse(value.substring(0, 10));
    return DateTime.parse(value).toUtc().toIso8601String() == value;
  } on FormatException {
    return false;
  }
}

Map<String, Object?> copySqlRow(Map<String, Object?> row) => row.map(
  (key, value) =>
      MapEntry(key, value is Uint8List ? Uint8List.fromList(value) : value),
);

String encodeSqlRow(Map<String, Object?> row) => jsonEncode(
  row.map(
    (key, value) => MapEntry(
      key,
      value is Uint8List ? {'sqlite_blob_base64': base64Encode(value)} : value,
    ),
  ),
);

Map<String, Object?> decodeSqlRow(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('SQL row must be an object');
  }
  return decoded.map((key, raw) {
    if (raw is Map && raw.length == 1 && raw['sqlite_blob_base64'] is String) {
      return MapEntry(key, base64Decode(raw['sqlite_blob_base64'] as String));
    }
    if (raw != null && raw is! String && raw is! num) {
      throw const FormatException('Non SQL audit value');
    }
    return MapEntry(key, raw);
  });
}

bool sameSqlRow(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length || !a.keys.toSet().containsAll(b.keys)) return false;
  for (final key in a.keys) {
    final x = a[key], y = b[key];
    if (x is Uint8List && y is Uint8List) {
      if (base64Encode(x) != base64Encode(y)) return false;
    } else if (x != y) {
      return false;
    }
  }
  return true;
}

final class CatalogEntity {
  CatalogEntity.fromRow(Map<String, Object?> row) : _raw = copySqlRow(row) {
    if (row['id'] is! String ||
        (row['id'] as String).trim().isEmpty ||
        (row['name'] != null && row['name'] is! String) ||
        row['active'] is! int ||
        ![0, 1].contains(row['active']) ||
        row['revision'] is! int ||
        (row['revision'] as int) < 1 ||
        !['default', 'user'].contains(row['source']) ||
        !isActionStamp(row['created_at']) ||
        !isActionStamp(row['updated_at']) ||
        (row['updated_at'] as String).compareTo(row['created_at'] as String) <
            0 ||
        (row['ext'] != null && row['ext'] is! String)) {
      throw const FormatException('团体或尺寸数据无效');
    }
  }
  final Map<String, Object?> _raw;
  String get id => _raw['id'] as String;
  String? get knownName => _raw['name'] as String?;
  String get name =>
      knownName == null || knownName!.trim().isEmpty ? '未填写名称' : knownName!;
  bool get active => _raw['active'] == 1;
  int get revision => _raw['revision'] as int;
  String get createdAt => _raw['created_at'] as String;
  String get updatedAt => _raw['updated_at'] as String;
  Map<String, Object?> toRow() => copySqlRow(_raw);
}

class CatalogException implements Exception {
  const CatalogException(this.message);
  final String message;
  @override
  String toString() => message;
}
