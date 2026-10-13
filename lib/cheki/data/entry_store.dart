import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/coupon_plan.dart';
import '../domain/cost_reference.dart';
import '../domain/record_information.dart';
import '../domain/ticket_information.dart';
import 'catalog_contract.dart';
import 'record_store.dart';
import 'ticket_store.dart';

/// Reuses both validated writers inside the SAME SQLite transaction.
/// This adapter cannot open, close, or independently commit the database.
class _TransactionDatabase implements Database {
  _TransactionDatabase(this.tx);
  final Transaction tx;
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => action(tx);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Only the owned transaction is available');
}

class EntryState {
  EntryState.fromRow(Map<String, Object?> row) : raw = copySqlRow(row) {
    if (row['record_id'] is! String ||
        row['operation_id'] is! String ||
        row['record_revision'] is! int ||
        (row['record_revision'] as int) < 1) {
      throw const FormatException('关联状态格式无效');
    }
    plan;
    children;
  }
  final Map<String, Object?> raw;
  String get recordId => raw['record_id'] as String;
  String get operationId => raw['operation_id'] as String;
  CouponPlan get plan => CouponPlan.decode(raw['plan_json'] as String);
  List<String> get children =>
      (jsonDecode(raw['children_json'] as String) as List).cast<String>();
  CostReference get costReference => plan.consuming
      ? CostReference.fromJson({'operation_id': operationId})
      : const CostReference.unassigned();
}

abstract final class EntrySchema {
  static const bindings = 'cheki_entry_ticket_bindings';
  static const states = 'cheki_entry_states',
      operations = 'cheki_entry_operations';
  static Future<void> create(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE $operations(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,record_id TEXT NOT NULL REFERENCES cheki_records(id) ON DELETE RESTRICT,request_json TEXT NOT NULL,result_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE $states(record_id TEXT PRIMARY KEY NOT NULL REFERENCES cheki_records(id) ON DELETE RESTRICT,operation_id TEXT NOT NULL UNIQUE REFERENCES $operations(id) ON DELETE RESTRICT,plan_json TEXT NOT NULL,children_json TEXT NOT NULL,record_revision INTEGER NOT NULL CHECK(record_revision>0))',
    );
    await db.execute(
      'CREATE TABLE $bindings(ticket_id TEXT PRIMARY KEY NOT NULL REFERENCES cheki_ticket_objects(id) ON DELETE RESTRICT,record_id TEXT NOT NULL REFERENCES cheki_records(id) ON DELETE RESTRICT)',
    );
  }

  static Future<void> validatePlan(
    DatabaseExecutor tx,
    RecordInformation info,
    CouponPlan plan, {
    bool actual = false,
    bool historical = false,
  }) async {
    if (actual &&
        (info.quantity == null ||
            info.occurredOn == null ||
            (info.memberIds ?? []).isEmpty ||
            plan.lines.isEmpty)) {
      throw const CatalogException('实际扣券需要已知发生日期、张数、成员和券种；可选择仅记录或用券信息待补录');
    }
    for (final line in plan.lines) {
      final member = line['member_id'], def = line['definition_id'];
      Map<String, Object?>? m, d;
      if (member != null) {
        final found = await tx.query(
          'cheki_members',
          where: 'id=?',
          whereArgs: [member],
        );
        if (found.length != 1 ||
            info.memberIds != null && !info.memberIds!.contains(member)) {
          throw const CatalogException('用券成员与参与成员不一致');
        }
        m = found.single;
      }
      if (def != null) {
        final found = await tx.query(
          TicketSchema.objects,
          where: 'id=? AND kind=?',
          whereArgs: [def, 'definition'],
        );
        if (found.length != 1) throw const CatalogException('券种不存在');
        d = TicketObject.fromRow(found.single).information.toMap();
      }
      if (actual) {
        if (!historical &&
            (m == null ||
                d == null ||
                d['group_id'] == null ||
                d['group_id'] != m['group_id'] ||
                !['personal', 'group'].contains(d['scope']) ||
                (d['scope'] == 'personal' && d['member_id'] != member))) {
          throw const CatalogException('券种与成员归属不一致，请明确选择适用券种');
        }
        final wanted = line['quantity'];
        var sum = 0;
        if (wanted is! int || wanted <= 0 || CouponPlan.pools(line).isEmpty) {
          throw const CatalogException('请补齐需用张数和逐池分配');
        }
        for (final p in CouponPlan.pools(line)) {
          if (p['quantity'] is! int ||
              p['pool'] == null ||
              (p['pool'] == 'dated' && p['expires_on'] == null)) {
            throw const CatalogException('请补齐各券池分配');
          }
          sum += p['quantity'] as int;
        }
        if (sum != wanted) {
          throw CatalogException('该券需用 $wanted 张，已分配 $sum 张；请核对差额');
        }
      }
    }
  }

  static Future<void> validate(DatabaseExecutor db) async {
    for (final table in [states, operations, bindings]) {
      if ((await db.rawQuery('PRAGMA foreign_key_check($table)')).isNotEmpty) {
        throw StateError('联动关联无效');
      }
    }
    final latest = <String, Map<String, Object?>>{};
    final usedChildren = <String, String>{};
    final ops = await db.query(operations, orderBy: 'seq');
    final global = {for (final o in ops) o['id']};
    for (final table in [
      'cheki_catalog_operations',
      'cheki_identity_operations',
      'cheki_record_operations',
      'cheki_ticket_operations',
    ]) {
      if ((await db.query(table)).any((r) => global.contains(r['id']))) {
        throw StateError('联动操作标识重复');
      }
    }
    for (final op in ops) {
      if (op['id'] is! String ||
          (op['id'] as String).isEmpty ||
          !isActionStamp(op['created_at'])) {
        throw StateError('联动动作无效');
      }
      final result = jsonDecode(op['result_json'] as String) as Map;
      final after = decodeSqlRow(result['state_json'] as String);
      final before = result['before_state_json'] == null
          ? null
          : decodeSqlRow(result['before_state_json'] as String);
      final state = EntryState.fromRow(after);
      final record = StoredRecord.fromRow(
        decodeSqlRow(result['record_json'] as String),
      );
      final request = jsonDecode(op['request_json'] as String) as Map;
      final recordOps = await db.query(
        RecordSchema.operations,
        where: 'id=?',
        whereArgs: ['${op['id']}:record'],
      );
      if (state.recordId != record.id ||
          state.operationId != op['id'] ||
          op['record_id'] != record.id ||
          after['record_revision'] != record.revision ||
          request['information_json'] != record.information.encode() ||
          request['plan_json'] != after['plan_json'] ||
          recordOps.length != 1 ||
          !sameSqlRow(
            decodeSqlRow(recordOps.single['result_json'] as String),
            record.toRow(),
          ) ||
          record.updatedAt != op['created_at'] ||
          (latest[record.id] == null
              ? before != null
              : before == null || !sameSqlRow(before, latest[record.id]!))) {
        throw StateError('联动原档或修订链无效');
      }
      final childRows = (jsonDecode(result['children_json'] as String) as List)
          .cast<String>()
          .map(decodeSqlRow)
          .toList();
      if (childRows.length != state.children.length ||
          childRows.map((r) => r['id']).toSet().length != childRows.length) {
        throw StateError('关联消费明细重复');
      }
      for (final child in childRows) {
        final entry = TicketObject.fromRow(child);
        if (!state.children.contains(entry.id) ||
            !entry.posted ||
            entry.kind != 'adjustment' ||
            entry.information.toMap()['linked_record_id'] != record.id ||
            (usedChildren[entry.id] != null &&
                usedChildren[entry.id] != record.id)) {
          throw StateError('消费不属于该记录');
        }
        final histories = await db.query(
          TicketSchema.history,
          where: 'object_id=?',
          whereArgs: [entry.id],
        );
        if (!histories.any(
          (h) => sameSqlRow(decodeSqlRow(h['after_json'] as String), child),
        )) {
          throw StateError('消费原档缺失');
        }
        usedChildren[entry.id] = record.id;
      }
      await validatePlan(
        db,
        record.information,
        state.plan,
        actual: state.plan.consuming,
        historical: true,
      );
      validateConsumption(record.information, state.plan, childRows);
      latest[record.id] = after;
    }
    final current = await db.query(states);
    if (current.length != latest.length) throw StateError('联动状态缺失');
    final currentChildren = <String>{};
    for (final row in current) {
      final state = EntryState.fromRow(row);
      final records = await db.query(
        RecordSchema.records,
        where: 'id=?',
        whereArgs: [state.recordId],
      );
      if (!sameSqlRow(row, latest[state.recordId]!) ||
          records.length != 1 ||
          records.single['revision'] != row['record_revision']) {
        throw StateError('当前记录与联动状态不同步');
      }
      final children = <Map<String, Object?>>[];
      for (final id in state.children) {
        if (!currentChildren.add(id)) throw StateError('消费明细被重复引用');
        final found = await db.query(
          TicketSchema.objects,
          where: 'id=?',
          whereArgs: [id],
        );
        if (found.length != 1 || found.single['posted'] != 1) {
          throw StateError('当前消费被单边修改');
        }
        children.add(found.single);
      }
      validateConsumption(
        StoredRecord.fromRow(records.single).information,
        state.plan,
        children,
      );
    }
    final bound = await db.query(bindings);
    if (bound.length != usedChildren.length) throw StateError('消费绑定缺失');
    for (final b in bound) {
      final id = b['ticket_id'] as String;
      if (usedChildren[id] != b['record_id']) throw StateError('消费归属无效');
      final row = (await db.query(
        TicketSchema.objects,
        where: 'id=?',
        whereArgs: [id],
      )).single;
      if (row['posted'] == 1 && !currentChildren.contains(id)) {
        throw StateError('关联消费缺少当前记录');
      }
    }
  }

  static void validateConsumption(
    RecordInformation info,
    CouponPlan plan,
    List<Map<String, Object?>> children,
  ) {
    final expected = <String, int>{}, actual = <String, int>{};
    if (plan.consuming) {
      for (final line in plan.lines) {
        for (final p in CouponPlan.pools(line)) {
          if ((p['quantity'] as int?) == 0) continue;
          final key =
              '${line['member_id']}|${line['definition_id']}|${p['pool']}|${p['expires_on']}';
          expected.update(
            key,
            (q) => q + (p['quantity'] as int),
            ifAbsent: () => p['quantity'] as int,
          );
        }
      }
    }
    for (final child in children) {
      final e = TicketObject.fromRow(child), v = e.information.toMap();
      if (!e.posted ||
          v['quantity'] is! int ||
          (v['quantity'] as int) >= 0 ||
          e.information.day != info.occurredOn?.value) {
        throw StateError('消费日期或数量不同步');
      }
      final key =
          '${v['member_id']}|${v['definition_id']}|${v['pool']}|${v['expires_on']}';
      actual.update(
        key,
        (q) => q - (v['quantity'] as int),
        ifAbsent: () => -(v['quantity'] as int),
      );
    }
    if (jsonEncode(expected) != jsonEncode(actual)) {
      if (expected.length != actual.length ||
          expected.entries.any((e) => actual[e.key] != e.value)) {
        throw StateError('逐池消费与核对明细不一致');
      }
    }
  }
}

class EntryStore {
  EntryStore(
    this.database, {
    DateTime Function()? clock,
    this.afterRecord,
    this.afterTickets,
  }) : clock = clock ?? DateTime.now;
  final Future<Database> Function() database;
  final DateTime Function() clock;
  final Future<void> Function()? afterRecord, afterTickets;
  Future<EntryState?> state(String recordId) async {
    final db = await database();
    if ((await db.rawQuery("SELECT name FROM sqlite_master WHERE name=?", [
      EntrySchema.states,
    ])).isEmpty) {
      return null;
    }
    final rows = await db.query(
      EntrySchema.states,
      where: 'record_id=?',
      whereArgs: [recordId],
    );
    return rows.isEmpty ? null : EntryState.fromRow(rows.single);
  }

  Future<TicketModel> availability({String? recordId, String? day}) async {
    final model = await TicketStore(database, clock: clock).readModel(day: day);
    final linked = recordId == null ? null : await state(recordId);
    if (linked == null) return model;
    final adjusted = model.objects
        .map(
          (e) => linked.children.contains(e.id)
              ? TicketObject.fromRow({
                  ...e.raw,
                  'posted': 0,
                  'allocations_json': '[]',
                })
              : e,
        )
        .toList();
    return TicketModel(
      adjusted,
      model.groups,
      model.members,
      model.sizes,
      model.day,
    );
  }

  Future<List<Map<String, Object?>>> preview(
    RecordInformation info,
    CouponPlan plan, {
    String? recordId,
  }) async {
    if (!plan.consuming) return [];
    final db = await database();
    return db.transaction((tx) async {
      await EntrySchema.validatePlan(tx, info, plan, actual: true);
      final states = recordId == null
          ? <Map<String, Object?>>[]
          : await tx.query(
              EntrySchema.states,
              where: 'record_id=?',
              whereArgs: [recordId],
            );
      final previous = states.isEmpty
          ? null
          : EntryState.fromRow(states.single);
      final priorRecords = recordId == null
          ? <Map<String, Object?>>[]
          : await tx.query(
              RecordSchema.records,
              where: 'id=?',
              whereArgs: [recordId],
            );
      if (previous != null &&
          previous.plan.encode() == plan.encode() &&
          priorRecords.isNotEmpty &&
          StoredRecord.fromRow(priorRecords.single).information.occurredOn ==
              info.occurredOn) {
        final frozen = <Map<String, Object?>>[];
        for (final id in previous.children) {
          final child = TicketObject.fromRow(
            (await tx.query(
              TicketSchema.objects,
              where: 'id=?',
              whereArgs: [id],
            )).single,
          );
          for (final allocation in child.allocations) {
            frozen.add({
              'definition_id': child.information.text('definition_id'),
              'quantity': allocation['quantity'],
              'cost': allocation['cost'],
              'preserved': true,
            });
          }
        }
        return frozen;
      }
      final objects = (await loadTicketObjects(tx))
          .map(
            (e) => previous?.children.contains(e.id) == true
                ? TicketObject.fromRow({
                    ...e.raw,
                    'posted': 0,
                    'allocations_json': '[]',
                  })
                : e,
          )
          .toList();
      final balance = remainingLots(objects, info.occurredOn!.value),
          out = <Map<String, Object?>>[];
      for (final line in plan.lines) {
        for (final pool in CouponPlan.pools(line)) {
          var left = pool['quantity'] as int;
          if (pool['expires_on'] != null &&
              (pool['expires_on'] as String).compareTo(info.occurredOn!.value) <
                  0 &&
              pool['allow_expired'] != true) {
            throw const CatalogException('请明确确认使用过期券');
          }
          final sources =
              objects
                  .where(
                    (e) =>
                        e.posted &&
                        (e.information.quantity ?? 0) > 0 &&
                        e.information.text('definition_id') ==
                            line['definition_id'] &&
                        e.information.text('pool') == pool['pool'] &&
                        e.information.expiry == pool['expires_on'] &&
                        e.information.day!.compareTo(info.occurredOn!.value) <=
                            0,
                  )
                  .toList()
                ..sort((a, b) {
                  final d = a.information.day!.compareTo(b.information.day!);
                  return d != 0 ? d : a.seq.compareTo(b.seq);
                });
          for (final source in sources) {
            final n = left < (balance[source.id] ?? 0)
                ? left
                : (balance[source.id] ?? 0);
            if (n > 0) {
              out.add({
                'definition_id': line['definition_id'],
                'quantity': n,
                'cost': source.unitCost?.times(n).exact,
                'preserved': false,
              });
            }
            balance[source.id] = (balance[source.id] ?? 0) - n;
            left -= n;
          }
          if (left > 0) throw const CatalogException('该发生日期共享库存不足，请返回核对');
        }
      }
      return out;
    });
  }

  Future<StoredRecord> save(
    RecordInformation info, {
    required CouponPlan plan,
    required String operationId,
    StoredRecord? original,
  }) async {
    if (operationId.trim().isEmpty) throw const CatalogException('操作标识缺失');
    final request = jsonEncode({
      'id': original?.id,
      'revision': original?.revision,
      'information_json': info.encode(),
      'plan_json': plan.encode(),
    });
    final db = await database();
    var changed = false;
    final saved = await db.transaction((tx) async {
      final previous = await tx.query(
        EntrySchema.operations,
        where: 'id=?',
        whereArgs: [operationId],
      );
      if (previous.isNotEmpty) {
        if (previous.single['request_json'] != request) {
          throw const CatalogException('该操作标识已用于其他修改');
        }
        final old = jsonDecode(previous.single['result_json'] as String) as Map;
        return StoredRecord.fromRow(decodeSqlRow(old['record_json'] as String));
      }
      if ((await tx.rawQuery(
            "SELECT name FROM sqlite_master WHERE name='cheki_transfer_operations'",
          )).isNotEmpty &&
          (await tx.query(
            'cheki_transfer_operations',
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('操作标识已用于交换赠送');
      }
      for (final table in [
        'cheki_catalog_operations',
        'cheki_identity_operations',
        'cheki_record_operations',
        'cheki_ticket_operations',
      ]) {
        if ((await tx.query(
          table,
          where: 'id=?',
          whereArgs: [operationId],
        )).isNotEmpty) {
          throw const CatalogException('操作标识已占用');
        }
      }
      Map<String, Object?>? before;
      if (original != null) {
        final row = await tx.query(
          RecordSchema.records,
          where: 'id=?',
          whereArgs: [original.id],
        );
        if (row.length != 1 || row.single['revision'] != original.revision) {
          throw const CatalogException('记录已修改，请重新打开');
        }
        final states = await tx.query(
          EntrySchema.states,
          where: 'record_id=?',
          whereArgs: [original.id],
        );
        before = states.isEmpty ? null : states.single;
      }
      await EntrySchema.validatePlan(tx, info, plan, actual: plan.consuming);
      final scoped = _TransactionDatabase(tx);
      final tickets = TicketStore(
        () => Future.value(scoped),
        clock: clock,
        managedEntry: true,
      );
      final oldState = before == null ? null : EntryState.fromRow(before);
      final oldIds = oldState?.children ?? [];
      final same =
          oldState != null &&
          oldState.plan.encode() == plan.encode() &&
          original!.information.occurredOn == info.occurredOn;
      final children = <TicketObject>[];
      if (!same) {
        for (final id in oldIds) {
          final source = TicketObject.fromRow(
            (await tx.query(
              TicketSchema.objects,
              where: 'id=?',
              whereArgs: [id],
            )).single,
          );
          await tickets.save(
            kind: source.kind,
            information: source.information,
            original: source,
            operationId: '$operationId:release:$id',
            posted: false,
          );
        }
      }
      final record = await RecordStore(
        () => Future.value(scoped),
        clock: clock,
        managedEntry: true,
      ).save(info, original: original, operationId: '$operationId:record');
      if (afterRecord != null) await afterRecord!();
      if (same) {
        for (final id in oldIds) {
          children.add(
            TicketObject.fromRow(
              (await tx.query(
                TicketSchema.objects,
                where: 'id=?',
                whereArgs: [id],
              )).single,
            ),
          );
        }
      } else if (plan.consuming) {
        var index = 0;
        for (final line in plan.lines) {
          for (final p in CouponPlan.pools(line)) {
            final n = p['quantity'] as int;
            if (n == 0) continue;
            final child = await tickets.save(
              kind: 'adjustment',
              information: TicketInformation({
                'definition_id': line['definition_id'],
                'member_id': line['member_id'],
                'quantity': -n,
                'occurred_on': info.occurredOn!.value,
                'pool': p['pool'],
                if (p['expires_on'] != null) 'expires_on': p['expires_on'],
                'linked_record_id': record.id,
                'linked_operation_id': operationId,
                'reason': 'Cheki用券',
              }),
              operationId: '$operationId:ticket:${index++}',
              posted: true,
              allowExpired: p['allow_expired'] == true,
            );
            await tx.insert(EntrySchema.bindings, {
              'ticket_id': child.id,
              'record_id': record.id,
            });
            children.add(child);
          }
        }
      }
      if (afterTickets != null) await afterTickets!();
      final stateRow = <String, Object?>{
        'record_id': record.id,
        'operation_id': operationId,
        'plan_json': plan.encode(),
        'children_json': jsonEncode(children.map((e) => e.id).toList()),
        'record_revision': record.revision,
      };
      final result = jsonEncode({
        'record_json': encodeSqlRow(record.toRow()),
        'state_json': encodeSqlRow(stateRow),
        'before_state_json': before == null ? null : encodeSqlRow(before),
        'children_json': jsonEncode(
          children.map((e) => encodeSqlRow(e.raw)).toList(),
        ),
      });
      await tx.insert(EntrySchema.operations, {
        'id': operationId,
        'record_id': record.id,
        'request_json': request,
        'result_json': result,
        'created_at': record.updatedAt,
      });
      if (before == null) {
        await tx.insert(EntrySchema.states, stateRow);
      } else {
        await tx.update(
          EntrySchema.states,
          stateRow,
          where: 'record_id=?',
          whereArgs: [record.id],
        );
      }
      await EntrySchema.validate(tx);
      changed = true;
      return record;
    });
    if (changed) {
      RecordStore.invalidateReads();
      TicketStore.invalidateReads();
    }
    return saved;
  }
}
