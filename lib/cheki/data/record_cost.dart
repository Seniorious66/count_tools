import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/ticket_information.dart';

/// Amounts are actual frozen consumption allocations, not current ticket
/// prices, purchase expenditure or a multiplication by participant count.
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
    if (linkedRecords == 0) return '花费：—（未关联扣券）';
    final value = knownQuantity == 0 ? '未知' : '¥${known.exact}';
    final missing = [
      if (unknownQuantity > 0) '$unknownQuantity 张券成本未知',
      if (unlinkedRecords > 0) '$unlinkedRecords 条未关联扣券',
    ];
    return '花费：$value${missing.isEmpty ? '' : '（${missing.join('，')}）'}';
  }
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
  return Map.unmodifiable(result);
}
