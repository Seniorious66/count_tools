import 'dart:convert';
import 'cost_reference.dart';
import 'record_contract.dart';
import 'record_draft.dart';

/// Persistable business information, including fully blank and legacy entries.
/// No defaults, IDs or action timestamps are inferred here. RecordDraft remains
/// the complete quick-entry contract; saving uses this nullable contract.
final class RecordInformation {
  RecordInformation.fromMap(Map<String, Object?> input) : _raw = _clone(input) {
    for (final key in ['occurred_on', 'size_id', 'note']) {
      if (_raw[key] != null && _raw[key] is! String) {
        throw FormatException('记录字段格式无效：$key');
      }
    }
    if (_raw['occurred_on'] != null) {
      OccurredOn.parse(_raw['occurred_on'] as String);
    }
    if (_raw['size_id'] != null && (_raw['size_id'] as String).trim().isEmpty) {
      throw const FormatException('未知尺寸请留空');
    }
    if (_raw['quantity'] != null &&
        (_raw['quantity'] is! int || (_raw['quantity'] as int) <= 0)) {
      throw const FormatException('已知张数必须为正整数，未知请留空');
    }
    final members = _raw['member_ids'];
    if (members != null &&
        (members is! List ||
            members.any((id) => id is! String || id.trim().isEmpty) ||
            members.toSet().length != members.length)) {
      throw const FormatException('成员标识无效或重复');
    }
    final a = _raw['attributes'];
    final snapshots = _raw['member_snapshots'];
    if (snapshots != null) {
      if (snapshots is! List) throw const FormatException('名称快照格式无效');
      final seen = <String>{};
      for (final s in snapshots) {
        if (s is! Map ||
            s['member_id'] is! String ||
            !(memberIds ?? []).contains(s['member_id']) ||
            !seen.add(s['member_id'] as String) ||
            [
              'member_name',
              'group_name',
              'group_id',
            ].any((k) => s[k] != null && s[k] is! String) ||
            (s['group_id'] is String &&
                (s['group_id'] as String).trim().isEmpty) ||
            [
              'origin',
              'member_name_origin',
              'group_name_origin',
            ].any((k) => s[k] != null && !['entry', 'manual'].contains(s[k]))) {
          throw const FormatException('名称快照与参与成员不匹配或字段无效');
        }
      }
    }
    if (a != null) {
      if (a is! Map ||
          (a['kind'] != null &&
              !SignatureKind.values.any((k) => k.name == a['kind'])) ||
          (a['back_signed'] != null && a['back_signed'] is! bool)) {
        throw const FormatException('属性格式无效');
      }
      if (a['back_signed'] == true && a['kind'] != 'signed') {
        throw const FormatException('背签需明确带签；旧冲突留原始档案待补录');
      }
    }
    final batches = _raw['receipt_batches'];
    if (_raw['receipt_status_hint'] != null &&
        !ReceiptStatus.values.any(
          (s) => s.name == _raw['receipt_status_hint'],
        )) {
      throw const FormatException('领取状态无效');
    }
    if (batches != null) {
      if (batches is! List) throw const FormatException('领取批次格式无效');
      for (final batch in batches) {
        if (batch is! Map ||
            (batch['quantity'] != null &&
                (batch['quantity'] is! int ||
                    (batch['quantity'] as int) <= 0)) ||
            (batch['origin'] != null &&
                !ReceiptOrigin.values.any((o) => o.name == batch['origin']))) {
          throw const FormatException('已填写领取批次无效');
        }
        final origin = batch['origin'];
        final stamp = batch['received_at'];
        // Missing actual times may be completed later, never use created_at.
        if (stamp != null) {
          if (stamp is! String || origin == 'initial' || !_instant(stamp)) {
            throw const FormatException('领取时间或来源无效');
          }
          if (occurredOn != null &&
              OccurredOn.shanghaiDay(
                    DateTime.parse(stamp),
                  ).compareTo(occurredOn!) <
                  0) {
            throw const FormatException('领取日期不能早于发生日期');
          }
        }
      }
      final knownReceived = batches.fold<int>(
        0,
        (sum, b) => sum + (((b as Map)['quantity'] as int?) ?? 0),
      );
      if (quantity != null && knownReceived > quantity!) {
        throw const FormatException('领取张数超过总张数');
      }
      final initial = batches.where((b) => (b as Map)['origin'] == 'initial');
      if (initial.isNotEmpty &&
          (initial.length != 1 ||
              batches.length != 1 ||
              (_raw['receipt_status_hint'] != null &&
                  _raw['receipt_status_hint'] != 'received') ||
              (quantity != null &&
                  initial.single['quantity'] != null &&
                  initial.single['quantity'] != quantity))) {
        throw const FormatException('初始已领须为整笔，已知数量必须一致');
      }
    }
    CostReference.fromJson(_raw['cost_reference']);
    receiptStatus;
  }
  final Map<String, Object?> _raw;
  static Map<String, Object?> _clone(Map<String, Object?> input) {
    try {
      return Map<String, Object?>.from(jsonDecode(jsonEncode(input)) as Map);
    } on JsonUnsupportedObjectError {
      throw const FormatException('扩展信息必须为有限JSON数据');
    }
  }

  static bool _instant(String s) {
    try {
      if (!RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:\d{3})?Z$',
      ).hasMatch(s)) {
        return false;
      }
      OccurredOn.parse(s.substring(0, 10));
      return DateTime.parse(s).toUtc().toIso8601String() == s;
    } on FormatException {
      return false;
    }
  }

  factory RecordInformation.fromDraft(RecordDraft draft) =>
      RecordInformation.fromMap(draft.toMap());
  factory RecordInformation.decode(String json) {
    final data = jsonDecode(json);
    if (data is! Map<String, dynamic>) throw const FormatException('记录必须为对象');
    return RecordInformation.fromMap(data);
  }
  Map<String, Object?> toMap() => _clone(_raw);
  String encode() => jsonEncode(_raw);
  OccurredOn? get occurredOn => _raw['occurred_on'] == null
      ? null
      : OccurredOn.parse(_raw['occurred_on'] as String);
  int? get quantity => _raw['quantity'] as int?;
  String? get sizeId => _raw['size_id'] as String?;
  List<String>? get memberIds => _raw['member_ids'] == null
      ? null
      : List<String>.unmodifiable((_raw['member_ids'] as List).cast<String>());
  String? get note => _raw['note'] as String?;
  Map<String, Object?>? memberSnapshot(String id) {
    for (final s in _raw['member_snapshots'] as List? ?? []) {
      if ((s as Map)['member_id'] == id) {
        return _clone(Map<String, Object?>.from(s));
      }
    }
    return null;
  }

  SignatureKind? get signature =>
      _raw['attributes'] is! Map || (_raw['attributes'] as Map)['kind'] == null
      ? null
      : SignatureKind.values.singleWhere(
          (k) => k.name == (_raw['attributes'] as Map)['kind'],
        );
  bool? get backSigned => _raw['attributes'] is! Map
      ? null
      : (_raw['attributes'] as Map)['back_signed'] as bool?;
  int? get receivedQuantity {
    final batches = _raw['receipt_batches'];
    if (batches == null ||
        (batches as List).any((b) => (b as Map)['quantity'] == null)) {
      return null;
    }
    return batches.fold<int>(
      0,
      (total, b) => total + ((b as Map)['quantity'] as int),
    );
  }

  ReceiptStatus? get receiptStatus {
    final received = receivedQuantity;
    if (received == 0 &&
        ['received', 'partial'].contains(_raw['receipt_status_hint'])) {
      throw const FormatException('已知领取数量与状态不一致');
    }
    if (received == null || quantity == null) {
      final batches = _raw['receipt_batches'];
      if (_raw['receipt_status_hint'] == null &&
          batches is List &&
          batches.length == 1 &&
          (batches.single as Map)['origin'] == 'initial') {
        return ReceiptStatus
            .received; // Explicit whole-receipt source, not a default.
      }
      return _raw['receipt_status_hint'] == null
          ? null
          : ReceiptStatus.values.singleWhere(
              (s) => s.name == _raw['receipt_status_hint'],
            );
    }
    final status = received == 0
        ? ReceiptStatus.unreceived
        : received == quantity
        ? ReceiptStatus.received
        : ReceiptStatus.partial;
    if (_raw['receipt_status_hint'] != null &&
        _raw['receipt_status_hint'] != status.name) {
      throw const FormatException('领取状态与已知批次数量不一致');
    }
    return status;
  }

  List<String> get missingFields => [
    if (occurredOn == null) '发生日期',
    if (quantity == null) '张数',
    if (sizeId == null) '尺寸',
    if (memberIds == null || memberIds!.isEmpty) '参与成员',
    if (signature == null) '签名分类',
    if (signature == SignatureKind.signed && backSigned == null) '背签',
    if (_raw['receipt_batches'] == null) '领取信息',
    if (_raw['receipt_batches'] is List &&
        (_raw['receipt_batches'] as List).any(
          (b) => (b as Map)['quantity'] == null,
        ))
      '领取张数',
    if (_raw['receipt_batches'] is List &&
        (_raw['receipt_batches'] as List).any(
          (b) => (b as Map)['origin'] == null,
        ))
      '领取来源',
    if (_raw['receipt_batches'] is List &&
        (_raw['receipt_batches'] as List).any(
          (b) => (b as Map)['origin'] == 'actual' && b['received_at'] == null,
        ))
      '实际领取时间',
  ];

  /// Edits replace only supplied fields; unrelated originals/NULLs are retained.
  RecordInformation patch(Map<String, Object?> changed) =>
      RecordInformation.fromMap({...toMap(), ...changed});
}
