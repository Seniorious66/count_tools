import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/ticket_information.dart';

/// Confirmed legacy amounts or actual frozen consumption allocations.
/// Never current prices, purchase expenditure or participant multiplication.
class RecordCost {
  TicketMoney known = TicketMoney(BigInt.zero, BigInt.one);
  int knownQuantity = 0,
      unknownQuantity = 0,
      linkedRecords = 0,
      unlinkedRecords = 0;
  void add(TicketMoney? amount, int quantity) {
    if (amount == null) {
      unknownQuantity += quantity;
    } else {
      known = TicketMoney.fromExact(
        TicketMoney(
          known.numerator * amount.denominator +
              amount.numerator * known.denominator,
          known.denominator * amount.denominator,
        ).exact,
      );
      knownQuantity += quantity;
    }
  }

  void addAllocations(Iterable<Map<String, Object?>> allocations) {
    for (final a in allocations) {
      add(
        a['cost'] == null ? null : TicketMoney.fromExact(a['cost'] as String),
        a['quantity'] as int,
      );
    }
  }

  void combine(RecordCost other) {
    if (other.knownQuantity > 0) add(other.known, other.knownQuantity);
    unknownQuantity += other.unknownQuantity;
    linkedRecords += other.linkedRecords;
    unlinkedRecords += other.unlinkedRecords;
  }

  String get label {
    final value = knownQuantity == 0 ? '—' : '¥${known.exact}';
    final missing = [
      if (knownQuantity > 0 && unknownQuantity + unlinkedRecords > 0) '另有金额未填写',
    ];
    return '花费：$value${missing.isEmpty ? '' : '（${missing.join('，')}）'}';
  }
}

/// Only the explicitly confirmed scoped legacy mapping may supply old amounts.
/// Invalid/missing text stays unknown and the raw JSON is never rewritten.
RecordCost? legacyRecordCost(Map<String, Object?> information) {
  final source = information['legacy_source'], raw = information['legacy_raw'];
  if (source is! Map ||
      source['snapshot'] != '20261011_102725' ||
      source['application_id'] != 'com.example.count_tools' ||
      source['mapping'] != 'S25-user-confirmed-20261013') {
    return null;
  }
  final result = RecordCost()..linkedRecords = 1;
  TicketMoney? amount;
  if (raw is Map &&
      raw['id'] is int &&
      (raw['id'] as int) > 0 &&
      raw['price'] is String) {
    try {
      amount = TicketMoney.parse(raw['price'] as String);
    } on FormatException {
      /* preserve the original unparseable amount */
    }
  }
  result.add(amount, 1);
  return result;
}

Future<Map<String, RecordCost>> recordCostsIn(DatabaseExecutor tx) async {
  if ((await tx.rawQuery(
    "SELECT name FROM sqlite_master WHERE name='cheki_entry_ticket_bindings'",
  )).isEmpty) {
    return const {};
  }
  final result = <String, RecordCost>{};
  for (final row in await tx.rawQuery(
    'SELECT b.record_id,t.allocations_json FROM cheki_entry_ticket_bindings b '
    'JOIN cheki_ticket_objects t ON t.id=b.ticket_id WHERE t.posted=1',
  )) {
    final id = row['record_id'] as String;
    final cost = result.putIfAbsent(id, () => RecordCost()..linkedRecords = 1);
    cost.addAllocations(
      (jsonDecode(row['allocations_json'] as String) as List).map(
        (a) => Map<String, Object?>.from(a as Map),
      ),
    );
  }
  for (final row in await tx.query(
    'cheki_records',
    columns: ['id', 'information_json'],
  )) {
    if (!(row['information_json'] as String).contains('"legacy_source"')) {
      continue;
    }
    final cost = legacyRecordCost(
      Map<String, Object?>.from(
        jsonDecode(row['information_json'] as String) as Map,
      ),
    );
    if (cost != null) result[row['id'] as String] = cost;
  }
  return Map.unmodifiable(result);
}
