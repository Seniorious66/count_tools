import 'dart:convert';
import 'record_contract.dart';

class TransferInformation {
  TransferInformation(Map<String, Object?> raw)
    : _raw = Map<String, Object?>.from(jsonDecode(jsonEncode(raw)) as Map) {
    for (final k in [
      'kind',
      'source_definition_id',
      'source_pool',
      'source_expires_on',
      'target_definition_id',
      'target_pool',
      'target_expires_on',
      'occurred_on',
      'note',
    ]) {
      if (_raw[k] != null && _raw[k] is! String) {
        throw FormatException('$k 格式无效');
      }
    }
    for (final k in ['source_definition_id', 'target_definition_id']) {
      if (text(k) != null && text(k)!.trim().isEmpty) {
        throw const FormatException('券种标识无效');
      }
    }
    for (final k in ['occurred_on', 'source_expires_on', 'target_expires_on']) {
      if (text(k) != null) OccurredOn.parse(text(k)!);
    }
    if (text('kind') != null && !['exchange', 'gift'].contains(text('kind'))) {
      throw const FormatException('操作类型无效');
    }
    for (final prefix in ['source', 'target']) {
      if (text('${prefix}_pool') != null &&
          !['long', 'dated'].contains(text('${prefix}_pool'))) {
        throw const FormatException('券池无效');
      }
      if (text('${prefix}_pool') == 'long' &&
          text('${prefix}_expires_on') != null) {
        throw const FormatException('长期券不填期限');
      }
    }
    if (_raw['quantity'] != null && _raw['quantity'] is! int) {
      throw const FormatException('张数格式无效');
    }
    if (quantity != null && (quantity! <= 0 || quantity! > 1000000000)) {
      throw const FormatException('张数需为正整数，未知可留空');
    }
    if (_raw['allow_expired'] != null && _raw['allow_expired'] is! bool) {
      throw const FormatException('过期确认无效');
    }
  }
  factory TransferInformation.decode(String value) =>
      TransferInformation(Map<String, Object?>.from(jsonDecode(value) as Map));
  final Map<String, Object?> _raw;
  String? text(String key) => _raw[key] as String?;
  int? get quantity => _raw['quantity'] as int?;
  bool get expiredConfirmed => _raw['allow_expired'] == true;
  String encode() => jsonEncode(_raw);
  Map<String, Object?> toMap() =>
      Map<String, Object?>.from(jsonDecode(encode()) as Map);
  TransferInformation patch(Map<String, Object?> updates) =>
      TransferInformation({..._raw, ...updates});
}
