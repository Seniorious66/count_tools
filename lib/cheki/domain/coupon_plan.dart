import 'dart:convert';
import 'record_contract.dart';

/// A user's allocation choice; missing information remains missing until supplied.
class CouponPlan {
  CouponPlan(Map<String, Object?> input)
    : _raw = Map<String, Object?>.from(jsonDecode(jsonEncode(input)) as Map) {
    if (mode != null && !['consume', 'record_only'].contains(mode)) {
      throw const FormatException('用券方式无效');
    }
    if (_raw['lines'] != null && _raw['lines'] is! List) {
      throw const FormatException('用券明细格式无效');
    }
    for (final line in lines) {
      for (final k in [
        'member_id',
        'definition_id',
        'member_name',
        'definition_name',
        'group_name',
      ]) {
        if (line[k] != null &&
            (line[k] is! String ||
                (k.endsWith('_id') && (line[k] as String).isEmpty))) {
          throw const FormatException('用券关联无效');
        }
      }
      final q = line['quantity'];
      if (q != null && (q is! int || q <= 0 || q > 1000000000)) {
        throw const FormatException('需用张数须为正整数，未知请留空');
      }
      if (line['pools'] != null && line['pools'] is! List) {
        throw const FormatException('券池格式无效');
      }
      final keys = <String>{};
      for (final p in pools(line)) {
        if (p['pool'] != null && !['long', 'dated'].contains(p['pool'])) {
          throw const FormatException('券池期限无效');
        }
        final date = p['expires_on'];
        if (date != null) {
          if (date is! String) throw const FormatException('券池日期格式无效');
          OccurredOn.parse(date);
        }
        if (p['pool'] == 'long' && date != null) {
          throw const FormatException('可用池不设截止日');
        }
        final n = p['quantity'];
        if (n != null && (n is! int || n < 0 || n > 1000000000)) {
          throw const FormatException('分配张数须为非负整数，未知请留空');
        }
        if (p['allow_expired'] != null && p['allow_expired'] is! bool) {
          throw const FormatException('过期确认格式无效');
        }
        if (p['pool'] != null && !keys.add('${p['pool']}:${date ?? ''}')) {
          throw const FormatException('同一券池不能重复列入一行');
        }
      }
    }
  }
  factory CouponPlan.decode(String value) =>
      CouponPlan(Map<String, Object?>.from(jsonDecode(value) as Map));
  final Map<String, Object?> _raw;
  String? get mode => _raw['mode'] as String?;
  bool get consuming => mode == 'consume';
  List<Map<String, Object?>> get lines => (_raw['lines'] as List? ?? [])
      .map((e) => Map<String, Object?>.from(e as Map))
      .toList();
  static List<Map<String, Object?>> pools(Map<String, Object?> line) =>
      (line['pools'] as List? ?? [])
          .map((e) => Map<String, Object?>.from(e as Map))
          .toList();
  String encode() => jsonEncode(_raw);
  Map<String, Object?> toMap() =>
      Map<String, Object?>.from(jsonDecode(encode()) as Map);
}
