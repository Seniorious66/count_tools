/// Rules shared by storage, entry, editing and aggregate queries.
/// Legacy TEXT dates are deliberately not parsed by this new-record contract.
final class OccurredOn implements Comparable<OccurredOn> {
  OccurredOn._(this.value, this._date);

  factory OccurredOn.parse(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('发生日期必须为 YYYY-MM-DD');
    }
    final year = int.parse(value.substring(0, 4));
    final month = int.parse(value.substring(5, 7));
    final day = int.parse(value.substring(8, 10));
    final date = DateTime.utc(year, month, day);
    if (year < 1 ||
        date.year != year ||
        date.month != month ||
        date.day != day) {
      throw const FormatException('发生日期无效');
    }
    return OccurredOn._(value, date);
  }

  /// Derive a business day from a known instant; never fabricate an instant
  /// from a date. This works independently of the device's timezone.
  factory OccurredOn.shanghaiDay(DateTime instant) {
    final day = instant.toUtc().add(const Duration(hours: 8));
    return OccurredOn.parse(
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}',
    );
  }

  final String value;
  final DateTime _date;
  @override
  int compareTo(OccurredOn other) => _date.compareTo(other._date);
  @override
  bool operator ==(Object other) => other is OccurredOn && value == other.value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

enum SignatureKind {
  unsigned('无签'),
  signed('有签'),
  homework('宿题');

  const SignatureKind(this.label);
  final String label;
}

final class ChekiAttributes {
  ChekiAttributes({this.kind = SignatureKind.signed, this.backSigned = false}) {
    if (kind != SignatureKind.signed && backSigned) {
      throw ArgumentError('背签仅有签时可用');
    }
  }
  final SignatureKind kind;
  final bool backSigned;

  /// Changing away clears the dependent value; switching back never restores it.
  ChekiAttributes select(SignatureKind next) => ChekiAttributes(
    kind: next,
    backSigned: next == SignatureKind.signed && backSigned,
  );
  ChekiAttributes setBackSigned(bool value) =>
      ChekiAttributes(kind: kind, backSigned: value);
}

enum ReceiptOrigin { initial, actual, legacyUnknown }

enum ReceiptStatus {
  received('已领取'),
  partial('部分领取'),
  unreceived('未领取');

  const ReceiptStatus(this.label);
  final String label;
}

final class ReceiptBatch {
  ReceiptBatch({
    required this.quantity,
    required this.origin,
    this.receivedAt,
  }) {
    if (quantity <= 0) throw ArgumentError('领取张数必须为正整数');
    if (origin == ReceiptOrigin.actual && receivedAt == null) {
      throw ArgumentError('补领需要实际领取时间');
    }
    if (origin != ReceiptOrigin.actual && receivedAt != null) {
      throw ArgumentError('无实际时间的来源不能附带推测时间');
    }
  }
  final int quantity;
  final ReceiptOrigin origin;
  final DateTime? receivedAt;
}

final class ReceiptState {
  ReceiptState({
    required this.quantity,
    required this.occurredOn,
    required List<ReceiptBatch> batches,
  }) : batches = List.unmodifiable(batches) {
    if (quantity <= 0) throw ArgumentError('张数必须为正整数');
    if (receivedQuantity > quantity) throw ArgumentError('领取张数超过总张数');
    final initial = batches.where((b) => b.origin == ReceiptOrigin.initial);
    if (initial.isNotEmpty &&
        (initial.length != 1 ||
            initial.single.quantity != quantity ||
            batches.length != 1)) {
      throw ArgumentError('初始已领取不追踪时间，仅适用于整笔初始已领');
    }
    for (final batch in batches) {
      if (batch.receivedAt != null &&
          OccurredOn.shanghaiDay(batch.receivedAt!).compareTo(occurredOn) < 0) {
        throw ArgumentError('领取日期不能早于发生日期');
      }
    }
  }
  factory ReceiptState.initialReceived(int quantity, OccurredOn day) =>
      ReceiptState(
        quantity: quantity,
        occurredOn: day,
        batches: [
          ReceiptBatch(quantity: quantity, origin: ReceiptOrigin.initial),
        ],
      );
  final int quantity;
  final OccurredOn occurredOn;
  final List<ReceiptBatch> batches;
  int get receivedQuantity =>
      batches.fold(0, (total, batch) => total + batch.quantity);
  int get unreceivedQuantity => quantity - receivedQuantity;
  ReceiptStatus get status => receivedQuantity == 0
      ? ReceiptStatus.unreceived
      : receivedQuantity == quantity
      ? ReceiptStatus.received
      : ReceiptStatus.partial;
}
