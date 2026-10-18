import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/ticket_information.dart';
import 'catalog_contract.dart';
import 'ticket_store.dart';

const _auditKey = '__cheki_cost_link_v1';

Object? _ordered(Object? value) => value is Map
    ? {
        for (final k in value.keys.cast<String>().toList()..sort())
          k: _ordered(value[k]),
      }
    : value is List
    ? value.map(_ordered).toList()
    : value;
bool _same(Object? a, Object? b) =>
    jsonEncode(_ordered(a)) == jsonEncode(_ordered(b));

/// Only money changes get this exception. Never relax inventory dependencies.
bool purchaseMoneyEdit(
  TicketObject before,
  TicketInformation next,
  bool posted,
) {
  if (before.kind != 'purchase' ||
      !before.posted ||
      !posted ||
      (before.information.quantity ?? 0) <= 0) {
    return false;
  }
  final a = before.information.toMap(), b = next.toMap();
  for (final k in ['unit_price', 'total_price']) {
    a.remove(k);
    b.remove(k);
  }
  return _same(a, b);
}

/// A normal purchase edit and all dependent valuations share one owned transaction.
/// Existing audit rows and entry/transfer snapshots are never overwritten.
Future<TicketObject> linkPurchaseCost(
  DatabaseExecutor tx, {
  required TicketObject original,
  required TicketInformation information,
  required String operationId,
  required String request,
  required String stamp,
  required List<TicketObject> all,
}) async {
  final bases = <String, Map<String, Object?>>{};
  if ((await tx.rawQuery(
    "SELECT name FROM sqlite_master WHERE name='cheki_transfer_lots'",
  )).isNotEmpty) {
    for (final b in await tx.query('cheki_transfer_lots')) {
      bases[b['ticket_id'] as String] = b;
    }
  }
  final current = {for (final t in all) t.id: t};
  Future<TicketObject> write(
    TicketObject old,
    Map<String, Object?> row,
    String op,
    String req,
  ) async {
    if (stamp.compareTo(old.raw['updated_at'] as String) < 0) {
      throw const FormatException('系统时间早于上次修改，请校准后重试');
    }
    row['revision'] = old.revision + 1;
    row['updated_at'] = stamp;
    final after = encodeSqlRow(row);
    await tx.update(
      TicketSchema.objects,
      row,
      where: 'id=?',
      whereArgs: [old.id],
    );
    await tx.insert(TicketSchema.operations, {
      'id': op,
      'object_id': old.id,
      'request_json': req,
      'result_json': after,
      'created_at': stamp,
    });
    await tx.insert(TicketSchema.history, {
      'object_id': old.id,
      'operation_id': op,
      'before_json': encodeSqlRow(old.raw),
      'after_json': after,
      'created_at': stamp,
    });
    final b = bases[old.id];
    return TicketObject.fromRow(
      row,
      inheritedBasis: b != null,
      inheritedUnitCost: b?['unit_cost'] == null
          ? null
          : TicketMoney.fromExact(b!['unit_cost'] as String),
    );
  }

  final root = await write(
    original,
    {...original.raw, 'information_json': information.encode()},
    operationId,
    request,
  );
  current[root.id] = root;
  // Exchange basis ancestry is ordered by sequence. Revalue incoming lots first,
  // then outgoing allocations; a backdated source may have been created later
  // than an edited outgoing row, without being future business inventory.
  final ordered = all
      .where((e) => (e.information.quantity ?? 0) > 0)
      .followedBy(all.where((e) => (e.information.quantity ?? 0) < 0));
  for (final old in ordered) {
    if (old.id == root.id || !old.posted) continue;
    final row = copySqlRow(old.raw), basis = bases[old.id];
    Map<String, Object?>? beforeLot, afterLot;
    if (basis != null) {
      final source = current[basis['source_id']];
      if (source == null || source.seq >= old.seq) {
        throw const FormatException('成本来源链无效，原账未改变');
      }
      final cost = source.unitCost?.exact;
      if (cost != basis['unit_cost']) {
        beforeLot = copySqlRow(basis);
        afterLot = {
          ...basis,
          'unit_cost': cost,
          'source_unit_cost': cost,
          'source_json': encodeSqlRow(source.raw),
        };
        bases[old.id] = afterLot;
      }
    }
    final allocations = old.allocations;
    var changed = afterLot != null;
    for (final a in allocations) {
      final source = current[a['source_id']];
      if (source == null || a['quantity'] is! int) {
        throw const FormatException('成本分配来源无效，原账未改变');
      }
      final cost = source.unitCost?.times(a['quantity'] as int).exact;
      if (a['cost'] != cost) {
        a['cost'] = cost;
        changed = true;
      }
    }
    if (!changed) continue;
    row['allocations_json'] = jsonEncode(allocations);
    final op = '$operationId:cost:${old.id}';
    final req = jsonEncode({
      'kind': old.kind,
      'id': old.id,
      'revision': old.revision,
      'information_json': row['information_json'],
      'posted': old.posted,
      _auditKey: {
        'root_operation': operationId,
        'before_lot': beforeLot == null ? null : encodeSqlRow(beforeLot),
        'after_lot': afterLot == null ? null : encodeSqlRow(afterLot),
      },
    });
    if (afterLot != null) {
      await tx.update(
        'cheki_transfer_lots',
        afterLot,
        where: 'ticket_id=?',
        whereArgs: [old.id],
      );
    }
    current[old.id] = await write(old, row, op, req);
  }
  validateLedger(current.values.toList());
  return root;
}

/// Frozen exchange snapshots can predate a later purchase cost edit.
/// Preserve and validate every basis revision rather than rewriting old snapshots.
class CostLinkAudit {
  final beforeLots = <Map<String, Object?>>[],
      afterLots = <Map<String, Object?>>[];
  final _revisions =
      <String, List<(int, Map<String, Object?>, Map<String, Object?>)>>{};
  static Future<CostLinkAudit> read(DatabaseExecutor db) async {
    final result = CostLinkAudit();
    final histories = await db.query(TicketSchema.history, orderBy: 'id');
    final operations = {
      for (final o in await db.query(TicketSchema.operations)) o['id']: o,
    };
    final byOp = {for (final h in histories) h['operation_id']: h};
    for (final h in histories) {
      final request =
          jsonDecode(operations[h['operation_id']]!['request_json'] as String)
              as Map;
      if (!request.containsKey(_auditKey)) continue;
      final tag = request[_auditKey];
      if (tag is! Map ||
          tag['root_operation'] is! String ||
          h['before_json'] == null) {
        throw StateError('金额联动审计无效');
      }
      final rootHistory = byOp[tag['root_operation']];
      if (rootHistory == null || rootHistory['before_json'] == null) {
        throw StateError('金额联动原操作缺失');
      }
      final rootBefore = TicketObject.fromRow(
        decodeSqlRow(rootHistory['before_json'] as String),
      );
      final rootAfter = TicketObject.fromRow(
        decodeSqlRow(rootHistory['after_json'] as String),
      );
      if (!purchaseMoneyEdit(
            rootBefore,
            rootAfter.information,
            rootAfter.posted,
          ) ||
          h['created_at'] != rootHistory['created_at']) {
        throw StateError('金额联动不属于购券金额修改');
      }
      final before = TicketObject.fromRow(
        decodeSqlRow(h['before_json'] as String),
      );
      final after = TicketObject.fromRow(
        decodeSqlRow(h['after_json'] as String),
      );
      if (before.kind != 'adjustment' ||
          !before.posted ||
          !after.posted ||
          before.information.encode() != after.information.encode() ||
          !_same(
            before.allocations.map((a) => {...a}..remove('cost')).toList(),
            after.allocations.map((a) => {...a}..remove('cost')).toList(),
          )) {
        throw StateError('金额联动改变库存事实');
      }
      final b = tag['before_lot'], a = tag['after_lot'];
      if ((b == null) != (a == null)) throw StateError('金额联动批次审计不完整');
      if (b == null) {
        if ((before.information.quantity ?? 0) >= 0) {
          throw StateError('金额联动缺少批次历史');
        }
        continue;
      }
      final old = decodeSqlRow(b as String), next = decodeSqlRow(a as String);
      if (old['ticket_id'] != before.id ||
          next['ticket_id'] != after.id ||
          !_same(
            {...old}
              ..remove('unit_cost')
              ..remove('source_unit_cost')
              ..remove('source_json'),
            {...next}
              ..remove('unit_cost')
              ..remove('source_unit_cost')
              ..remove('source_json'),
          )) {
        throw StateError('金额联动改变批次来源');
      }
      final revisions = result._revisions.putIfAbsent(before.id, () => []);
      if (revisions.isNotEmpty && !sameSqlRow(revisions.last.$3, old)) {
        throw StateError('批次金额修订链断裂');
      }
      revisions.add((after.revision, old, next));
      result.beforeLots.add(old);
      result.afterLots.add(next);
    }
    if (result._revisions.isNotEmpty) {
      final lots = {
        for (final b in await db.query('cheki_transfer_lots'))
          b['ticket_id']: b,
      };
      for (final entry in result._revisions.entries) {
        if (lots[entry.key] == null ||
            !sameSqlRow(lots[entry.key]!, entry.value.last.$3)) {
          throw StateError('当前批次金额与审计不符');
        }
      }
    }
    return result;
  }

  Object? historicalUnit(TicketObject source, Map<String, Object?> basis) {
    final revisions = _revisions[source.id];
    if (revisions == null) return basis['unit_cost'];
    Object? cost = revisions.first.$2['unit_cost'];
    for (final revision in revisions) {
      if (revision.$1 <= source.revision) cost = revision.$3['unit_cost'];
    }
    return cost;
  }
}
