import 'dart:convert';
import 'record_contract.dart';
import 'cost_reference.dart';

Map<String, Object?> _copyJson(Map<String, Object?> value) {
  try {
    // Reject non-JSON values/nonfinite numbers instead of dropping opaque data.
    return Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
  } on JsonUnsupportedObjectError {
    throw const FormatException('记录扩展数据格式无效');
  }
}

DateTime _receiptInstant(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:\d{3})?Z$',
      ).hasMatch(value)) {
    throw const FormatException('领取时间存储格式无效');
  }
  OccurredOn.parse(value.substring(0, 10));
  final instant = DateTime.parse(value);
  if (instant.toUtc().toIso8601String() != value) {
    throw const FormatException('领取时间存储格式无效');
  }
  return instant;
}

/// New-record input contract only. Entity resolution, Person collision policy,
/// persisted IDs/action stamps and actual write operations belong to services.
/// This is neither an import adapter for old records nor a database row.
final class RecordDraft {
  RecordDraft.fromMap(Map<String, Object?> input) : _raw = _copyJson(input) {
    const required = [
      'occurred_on',
      'quantity',
      'size_id',
      'member_ids',
      'attributes',
      'receipt_batches',
      'note',
    ];
    if (!required.every(_raw.containsKey) ||
        _raw['occurred_on'] is! String ||
        _raw['quantity'] is! int ||
        _raw['size_id'] is! String ||
        (_raw['size_id'] as String).trim().isEmpty ||
        _raw['member_ids'] is! List ||
        _raw['attributes'] is! Map ||
        _raw['receipt_batches'] is! List ||
        (_raw['note'] != null && _raw['note'] is! String)) {
      throw const FormatException('记录字段格式无效');
    }
    final ids = _raw['member_ids'] as List;
    if (ids.isEmpty ||
        ids.any((id) => id is! String || id.trim().isEmpty) ||
        ids.toSet().length != ids.length) {
      throw const FormatException('请选择成员，同一身份不能重复');
    }
    final attributes = _raw['attributes'] as Map;
    if (!SignatureKind.values.any((kind) => kind.name == attributes['kind']) ||
        attributes['back_signed'] is! bool) {
      throw const FormatException('属性格式无效');
    }
    // Validate the complete state now, not only when a getter happens to run.
    this.attributes;
    receipt;
    costReference;
  }
  factory RecordDraft.create({
    required OccurredOn occurredOn,
    required int quantity,
    required String sizeId,
    required List<String> memberIds,
    required ChekiAttributes attributes,
    required ReceiptState receipt,
    String? note,
  }) {
    if (receipt.quantity != quantity || receipt.occurredOn != occurredOn) {
      throw ArgumentError('领取与记录的张数和日期必须一致');
    }
    return RecordDraft.fromMap({
      'occurred_on': occurredOn.value,
      'quantity': quantity,
      'size_id': sizeId,
      'member_ids': memberIds,
      'attributes': {
        'kind': attributes.kind.name,
        'back_signed': attributes.backSigned,
      },
      'receipt_batches': [
        for (final batch in receipt.batches)
          {
            'quantity': batch.quantity,
            'origin': batch.origin.name,
            'received_at': batch.receivedAt?.toUtc().toIso8601String(),
          },
      ],
      'note': note,
      'cost_reference': null,
    });
  }
  final Map<String, Object?> _raw;
  OccurredOn get occurredOn => OccurredOn.parse(_raw['occurred_on'] as String);
  int get quantity => _raw['quantity'] as int;
  String get sizeId => _raw['size_id'] as String;
  List<String> get memberIds =>
      List.unmodifiable((_raw['member_ids'] as List).cast<String>());
  String? get note => _raw['note'] as String?;
  CostReference get costReference =>
      CostReference.fromJson(_raw['cost_reference']);
  ChekiAttributes get attributes {
    final value = _raw['attributes'] as Map;
    return ChekiAttributes(
      kind: SignatureKind.values.singleWhere((k) => k.name == value['kind']),
      backSigned: value['back_signed'] as bool,
    );
  }

  ReceiptState get receipt => ReceiptState(
    quantity: quantity,
    occurredOn: occurredOn,
    batches: [
      for (final raw in _raw['receipt_batches'] as List) _readBatch(raw),
    ],
  );
  static ReceiptBatch _readBatch(Object? raw) {
    if (raw is! Map ||
        !['quantity', 'origin', 'received_at'].every(raw.containsKey) ||
        raw['quantity'] is! int ||
        !ReceiptOrigin.values.any((origin) => origin.name == raw['origin'])) {
      throw const FormatException('领取批次格式无效');
    }
    return ReceiptBatch(
      quantity: raw['quantity'] as int,
      origin: ReceiptOrigin.values.singleWhere((o) => o.name == raw['origin']),
      receivedAt: raw['received_at'] == null
          ? null
          : _receiptInstant(raw['received_at']),
    );
  }

  Map<String, Object?> toMap() => _copyJson(_raw);
  String encode() => jsonEncode(_raw);
  factory RecordDraft.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('记录必须为对象');
    }
    return RecordDraft.fromMap(decoded);
  }
  RecordDraft changeOccurrence(OccurredOn day) =>
      RecordDraft.fromMap({...toMap(), 'occurred_on': day.value});
  RecordDraft changeAttributes(ChekiAttributes value) => RecordDraft.fromMap({
    ...toMap(),
    'attributes': {
      ...(_raw['attributes'] as Map),
      'kind': value.kind.name,
      'back_signed': value.backSigned,
    },
  });
}
