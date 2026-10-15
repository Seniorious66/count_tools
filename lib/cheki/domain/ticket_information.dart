import 'dart:convert';
import 'record_contract.dart';
import '../data/catalog_contract.dart' show isActionStamp;

/// Exact source amounts. No rounding policy or zero for an unknown amount.
class TicketMoney {
  TicketMoney(this.numerator, this.denominator);
  factory TicketMoney.fromExact(String value) {
    if (!RegExp(r'^\d+(?:/[1-9]\d*)?$').hasMatch(value) || value.length > 200) {
      throw const FormatException('成本比例无效');
    }
    final parts = value.split('/');
    return TicketMoney(
      BigInt.parse(parts[0]),
      parts.length == 1 ? BigInt.one : BigInt.parse(parts[1]),
    );
  }
  factory TicketMoney.parse(String text) {
    if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(text) || text.length > 80) {
      throw const FormatException('金额请填写非负十进制数');
    }
    final pieces = text.split('.');
    return TicketMoney(
      BigInt.parse(pieces.join()),
      BigInt.from(10).pow(pieces.length == 1 ? 0 : pieces[1].length),
    );
  }
  final BigInt numerator, denominator;
  TicketMoney times(int q) =>
      TicketMoney(numerator * BigInt.from(q), denominator);
  TicketMoney divided(int q) =>
      TicketMoney(numerator, denominator * BigInt.from(q));
  bool same(TicketMoney other) =>
      numerator * other.denominator == other.numerator * denominator;
  String get exact {
    final gcd = numerator.gcd(denominator);
    final n = numerator ~/ gcd, d = denominator ~/ gcd;
    return d == BigInt.one ? '$n' : '$n/$d';
  }
}

/// JSON deliberately retains absent keys, NULL and unrecognised fields.
class TicketInformation {
  TicketInformation(Map<String, Object?> values)
    : _values = Map<String, Object?>.from(
        jsonDecode(jsonEncode(values)) as Map,
      ) {
    if (_values['recorded_at'] != null &&
        !isActionStamp(_values['recorded_at'])) {
      throw const FormatException('录入时间格式无效');
    }
    for (final key in [
      'name',
      'group_id',
      'member_id',
      'size_id',
      'signature',
      'scope',
      'definition_id',
      'occurred_on',
      'pool',
      'expires_on',
      'unit_price',
      'total_price',
      'note',
      'reason',
    ]) {
      if (_values[key] != null && _values[key] is! String) {
        throw FormatException('$key 格式无效');
      }
    }
    for (final key in ['group_id', 'member_id', 'size_id', 'definition_id']) {
      if (_values[key] is String && (_values[key] as String).trim().isEmpty) {
        throw FormatException('$key 关联无效');
      }
    }
    for (final key in ['occurred_on', 'expires_on']) {
      if (_values[key] != null) OccurredOn.parse(_values[key] as String);
    }
    for (final key in ['unit_price', 'total_price']) {
      if (_values[key] != null) TicketMoney.parse(_values[key] as String);
    }
    final q = _values['quantity'];
    if (q != null && (q is! int || q == 0 || q.abs() > 1000000000)) {
      throw const FormatException('已填张数必须是非零整数');
    }
    for (final entry in {
      'scope': ['personal', 'group'],
      'pool': ['long', 'dated'],
      'signature': ['unsigned', 'signed', 'homework'],
    }.entries) {
      if (_values[entry.key] != null &&
          !entry.value.contains(_values[entry.key])) {
        throw FormatException('${entry.key} 选项无效');
      }
    }
    if (_values['scope'] == 'group' && _values['member_id'] != null) {
      throw const FormatException('通用券不能指定个人成员');
    }
    if (_values['pool'] == 'long' && _values['expires_on'] != null) {
      throw const FormatException('长期券不设截止日');
    }
    if (_values['active'] != null && _values['active'] is! bool) {
      throw const FormatException('券种状态无效');
    }
  }
  factory TicketInformation.decode(String text) =>
      TicketInformation(Map<String, Object?>.from(jsonDecode(text) as Map));
  final Map<String, Object?> _values;
  Map<String, Object?> toMap() =>
      Map<String, Object?>.from(jsonDecode(encode()) as Map);
  String encode() => jsonEncode(_values);
  String? text(String key) => _values[key] as String?;
  int? get quantity => _values['quantity'] as int?;
  String? get day => text('occurred_on');
  String? get expiry => text('expires_on');
  TicketMoney? get unitCost {
    final unit = text('unit_price'), total = text('total_price'), q = quantity;
    if (unit != null &&
        total != null &&
        q != null &&
        !TicketMoney.parse(
          unit,
        ).times(q.abs()).same(TicketMoney.parse(total))) {
      return null; // Conflicting input is preserved, not silently resolved.
    }
    if (total != null && q != null) {
      return TicketMoney.parse(total).divided(q.abs());
    }
    return unit == null ? null : TicketMoney.parse(unit);
  }

  bool get costConflict =>
      text('unit_price') != null &&
      text('total_price') != null &&
      quantity != null &&
      unitCost == null;
}
