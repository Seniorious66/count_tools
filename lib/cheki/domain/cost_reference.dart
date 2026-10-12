import 'dart:convert';

/// A reference to a later allocation operation, never an amount or valuation.
/// Absence means unassigned, not zero. M2 owns existence checks and calculation.
final class CostReference {
  const CostReference.unassigned() : _raw = null;
  factory CostReference.fromJson(Object? value) {
    if (value == null) return const CostReference.unassigned();
    if (value is! Map<String, Object?> ||
        value['operation_id'] is! String ||
        (value['operation_id'] as String).trim().isEmpty) {
      throw const FormatException('成本引用格式无效');
    }
    try {
      return CostReference._(
        Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map),
      );
    } on JsonUnsupportedObjectError {
      throw const FormatException('成本扩展数据格式无效');
    }
  }
  CostReference._(this._raw);
  final Map<String, Object?>? _raw;
  bool get hasReference => _raw != null;
  String? get operationId => _raw?['operation_id'] as String?;
  Object? toJson() => _raw == null
      ? null
      : Map<String, Object?>.from(jsonDecode(jsonEncode(_raw)) as Map);
}
