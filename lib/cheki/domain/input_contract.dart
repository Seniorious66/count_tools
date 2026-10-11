import 'record_contract.dart';

int parsePositiveQuantity(String raw) {
  if (!RegExp(r'^[0-9]+$').hasMatch(raw)) {
    throw const FormatException('请输入正整数张数');
  }
  final value = int.tryParse(raw);
  if (value == null || value <= 0) {
    throw const FormatException('张数必须大于 0');
  }
  return value;
}

/// A wall-clock entry in the fixed Shanghai business zone, never an occurrence
/// date converted into a made-up instant. The user must supply both day and time.
DateTime parseReceiptTime(String raw) {
  final match = RegExp(
    r'^(\d{4}-\d{2}-\d{2}) (\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?$',
  ).firstMatch(raw);
  if (match == null) {
    throw const FormatException('请填写领取日期和时间');
  }
  final date = OccurredOn.parse(match[1]!);
  final hour = int.parse(match[2]!);
  final minute = int.parse(match[3]!);
  final second = int.parse(match[4] ?? '0');
  final fraction = int.parse((match[5] ?? '').padRight(6, '0'));
  if (hour > 23 || minute > 59 || second > 59) {
    throw const FormatException('领取时间无效');
  }
  final parts = date.value.split('-').map(int.parse).toList();
  return DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    hour,
    minute,
    second,
    fraction ~/ 1000,
    fraction % 1000,
  ).subtract(const Duration(hours: 8));
}

String receiptTimeText(DateTime instant) {
  final local = instant.toUtc().add(const Duration(hours: 8));
  final text = local.toIso8601String().replaceFirst('T', ' ');
  return local.millisecond == 0 && local.microsecond == 0
      ? text.substring(0, 19)
      : text.substring(0, text.length - 1);
}

final class ReceiptInputBatch {
  const ReceiptInputBatch({
    required this.key,
    this.quantity = '',
    this.time = '',
    this.origin = ReceiptOrigin.actual,
  });
  final String key;
  final String quantity;
  final String time;
  final ReceiptOrigin origin;
  ReceiptInputBatch copyWith({String? quantity, String? time}) =>
      ReceiptInputBatch(
        key: key,
        quantity: quantity ?? this.quantity,
        time: time ?? this.time,
        origin: origin,
      );
}

/// Invalid raw input is retained here; conversion happens only for review/save.
final class ReceiptInput {
  ReceiptInput({
    this.status = ReceiptStatus.received,
    this.allowInitial = true,
    List<ReceiptInputBatch> batches = const [],
  }) : batches = List.unmodifiable(batches) {
    if (batches.map((b) => b.key).toSet().length != batches.length ||
        batches.any((b) => b.key.isEmpty)) {
      throw ArgumentError('领取输入标识不能重复或为空');
    }
    if (batches.any(
      (b) =>
          b.origin == ReceiptOrigin.initial ||
          (b.origin == ReceiptOrigin.legacyUnknown && b.time.isNotEmpty),
    )) {
      throw ArgumentError('领取来源与实际时间不一致');
    }
  }
  factory ReceiptInput.fromState(ReceiptState state) => ReceiptInput(
    status: state.status,
    allowInitial:
        state.batches.length == 1 &&
        state.batches.single.origin == ReceiptOrigin.initial,
    batches: [
      for (final (index, batch) in state.batches.indexed)
        if (batch.origin != ReceiptOrigin.initial)
          ReceiptInputBatch(
            key: 'existing-$index',
            quantity: '${batch.quantity}',
            time: batch.receivedAt == null
                ? ''
                : receiptTimeText(batch.receivedAt!),
            origin: batch.origin,
          ),
    ],
  );
  final ReceiptStatus status;
  final bool allowInitial;
  final List<ReceiptInputBatch> batches;
  bool get needsBatches =>
      status != ReceiptStatus.unreceived &&
      !(status == ReceiptStatus.received && allowInitial);
  ReceiptInput select(ReceiptStatus value) =>
      ReceiptInput(status: value, allowInitial: allowInitial, batches: batches);
  ReceiptInput replaceBatches(List<ReceiptInputBatch> value) =>
      ReceiptInput(status: status, allowInitial: allowInitial, batches: value);
  ReceiptState validate({
    required int quantity,
    required OccurredOn occurredOn,
  }) {
    if (status == ReceiptStatus.unreceived) {
      return ReceiptState(
        quantity: quantity,
        occurredOn: occurredOn,
        batches: [],
      );
    }
    if (status == ReceiptStatus.received && allowInitial) {
      return ReceiptState.initialReceived(quantity, occurredOn);
    }
    if (batches.isEmpty) throw const FormatException('请添加领取批次');
    final state = ReceiptState(
      quantity: quantity,
      occurredOn: occurredOn,
      batches: [
        for (final batch in batches)
          ReceiptBatch(
            quantity: parsePositiveQuantity(batch.quantity),
            origin: batch.origin,
            receivedAt: batch.origin == ReceiptOrigin.actual
                ? parseReceiptTime(batch.time)
                : null,
          ),
      ],
    );
    if (state.status != status) {
      throw FormatException(
        status == ReceiptStatus.partial ? '部分领取张数必须小于总张数' : '已领取张数必须等于总张数',
      );
    }
    return state;
  }
}
