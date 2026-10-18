import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/transfer_information.dart';
import '../domain/ticket_information.dart';
import 'catalog_contract.dart';
import 'catalog_store.dart';
import 'ticket_store.dart';
import 'owned_transaction.dart';
import 'ticket_cost_link.dart';

class TransferObject {
  TransferObject.fromRow(Map<String, Object?> row) : raw = copySqlRow(row) {
    if (row['id'] is! String ||
        (row['id'] as String).isEmpty ||
        row['seq'] is! int ||
        row['revision'] is! int ||
        (row['revision'] as int) < 1 ||
        ![0, 1].contains(row['posted']) ||
        !isActionStamp(row['created_at']) ||
        !isActionStamp(row['updated_at']) ||
        (row['updated_at'] as String).compareTo(row['created_at'] as String) <
            0) {
      throw const FormatException('换送原档无效');
    }
    information;
    children;
  }
  final Map<String, Object?> raw;
  String get id => raw['id'] as String;
  int get revision => raw['revision'] as int;
  bool get posted => raw['posted'] == 1;
  TransferInformation get information =>
      TransferInformation.decode(raw['information_json'] as String);
  List<String> get children {
    final ids = (jsonDecode(raw['children_json'] as String) as List)
        .cast<String>();
    if (ids.toSet().length != ids.length || ids.any((id) => id.isEmpty)) {
      throw const FormatException('换送子流水重复');
    }
    return ids;
  }
}

abstract final class TransferSchema {
  static const objects = 'cheki_transfer_objects',
      operations = 'cheki_transfer_operations',
      bindings = 'cheki_transfer_bindings',
      lots = 'cheki_transfer_lots';
  static Future<void> create(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE $objects(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,information_json TEXT NOT NULL,children_json TEXT NOT NULL,posted INTEGER NOT NULL CHECK(posted IN (0,1)),revision INTEGER NOT NULL CHECK(revision>0),created_at TEXT NOT NULL,updated_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE $operations(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,object_id TEXT NOT NULL REFERENCES $objects(id) ON DELETE RESTRICT,request_json TEXT NOT NULL,before_json TEXT,result_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE $bindings(ticket_id TEXT PRIMARY KEY NOT NULL REFERENCES cheki_ticket_objects(id) ON DELETE RESTRICT,transfer_id TEXT NOT NULL REFERENCES $objects(id) ON DELETE RESTRICT)',
    );
    await db.execute(
      'CREATE TABLE $lots(ticket_id TEXT PRIMARY KEY NOT NULL REFERENCES cheki_ticket_objects(id) ON DELETE RESTRICT,source_id TEXT NOT NULL REFERENCES cheki_ticket_objects(id) ON DELETE RESTRICT,outgoing_id TEXT NOT NULL REFERENCES cheki_ticket_objects(id) ON DELETE RESTRICT,quantity INTEGER NOT NULL CHECK(quantity>0),unit_cost TEXT,source_json TEXT NOT NULL,source_unit_cost TEXT,created_at TEXT NOT NULL)',
    );
  }

  static Future<void> checkInput(
    DatabaseExecutor db,
    TransferInformation i, {
    required bool posted,
  }) async {
    for (final side in ['source', 'target']) {
      final id = i.text('${side}_definition_id');
      if (id != null &&
          (await db.query(
                TicketSchema.objects,
                where: 'id=? AND kind=?',
                whereArgs: [id, 'definition'],
              )).length !=
              1) {
        throw const CatalogException('券种关联不存在');
      }
    }
    if (!posted) return;
    if (i.text('kind') == null ||
        i.quantity == null ||
        i.text('occurred_on') == null ||
        i.text('source_definition_id') == null ||
        i.text('source_pool') == null ||
        i.text('source_pool') == 'dated' &&
            i.text('source_expires_on') == null) {
      throw const CatalogException('实际换送需补齐来源、日期、张数和期限；可先保存待补录');
    }
    if (i.text('kind') == 'exchange') {
      if (i.text('target_definition_id') == null ||
          i.text('target_pool') == null ||
          i.text('target_pool') == 'dated' &&
              i.text('target_expires_on') == null) {
        throw const CatalogException('请明确目标券种和期限');
      }
      if (i.text('source_definition_id') == i.text('target_definition_id') &&
          i.text('source_pool') == i.text('target_pool') &&
          i.text('source_expires_on') == i.text('target_expires_on')) {
        throw const CatalogException('请选择不同的目标券池');
      }
    }
  }

  static void matching(TransferObject r, List<TicketObject> children) {
    if (!r.posted) {
      if (children.isNotEmpty) throw StateError('草稿产生库存');
      return;
    }
    final i = r.information;
    var outgoing = 0, incoming = 0;
    for (final child in children) {
      final c = child.information;
      if (!child.posted ||
          c.day != i.text('occurred_on') ||
          c.toMap()['transfer_id'] != r.id) {
        throw StateError('换送子流水状态无效');
      }
      final side = c.quantity! < 0 ? 'source' : 'target';
      if (c.text('definition_id') != i.text('${side}_definition_id') ||
          c.text('pool') != i.text('${side}_pool') ||
          c.expiry != i.text('${side}_expires_on')) {
        throw StateError('换送子池不一致');
      }
      if (c.quantity! < 0) {
        outgoing -= c.quantity!;
      } else {
        incoming += c.quantity!;
      }
    }
    if (outgoing != i.quantity ||
        incoming != (i.text('kind') == 'exchange' ? i.quantity : 0)) {
      throw StateError('换送数量不守恒');
    }
  }

  static Future<void> validate(DatabaseExecutor db) async {
    for (final t in [objects, operations, bindings, lots]) {
      if ((await db.rawQuery('PRAGMA foreign_key_check($t)')).isNotEmpty) {
        throw StateError('换送外键无效');
      }
    }
    final all = (await db.query(objects)).map(TransferObject.fromRow).toList();
    final ops = await db.query(operations, orderBy: 'seq'),
        latest = <String, Map<String, Object?>>{},
        bound = <String, String>{};
    final opIds = {for (final o in ops) o['id']};
    for (final t in [
      'cheki_catalog_operations',
      'cheki_identity_operations',
      'cheki_record_operations',
      'cheki_ticket_operations',
      'cheki_entry_operations',
    ]) {
      if ((await db.query(t)).any((r) => opIds.contains(r['id']))) {
        throw StateError('换送操作标识跨服务重复');
      }
    }
    for (final op in ops) {
      if (op['id'] is! String ||
          (op['id'] as String).isEmpty ||
          !isActionStamp(op['created_at'])) {
        throw StateError('换送动作无效');
      }
      final result = jsonDecode(op['result_json'] as String) as Map;
      final r = TransferObject.fromRow(
        decodeSqlRow(result['object_json'] as String),
      );
      final before = op['before_json'] == null
              ? null
              : decodeSqlRow(op['before_json'] as String),
          prev = latest[r.id];
      final request = jsonDecode(op['request_json'] as String) as Map;
      if (op['object_id'] != r.id ||
          r.raw['updated_at'] != op['created_at'] ||
          (prev == null
              ? (before != null || r.revision != 1)
              : (before == null ||
                    !sameSqlRow(before, prev) ||
                    r.revision != (prev['revision'] as int) + 1 ||
                    r.raw['created_at'] != prev['created_at'] ||
                    r.raw['seq'] != prev['seq'])) ||
          request['information_json'] != r.information.encode() ||
          request['posted'] != r.posted ||
          request['id'] != (before == null ? null : r.id) ||
          request['revision'] != (before == null ? null : before['revision'])) {
        throw StateError('换送修订链无效');
      }
      await checkInput(db, r.information, posted: r.posted);
      final children = (jsonDecode(result['children_json'] as String) as List)
          .cast<String>()
          .map((s) => TicketObject.fromRow(decodeSqlRow(s)))
          .toList();
      if (children.length != r.children.length ||
          children.map((e) => e.id).toSet().length != children.length) {
        throw StateError('换送原档子流水重复');
      }
      for (final child in children) {
        if (!r.children.contains(child.id) ||
            child.kind != 'adjustment' ||
            (bound[child.id] != null && bound[child.id] != r.id)) {
          throw StateError('换送归属错误');
        }
        final h = await db.query(
          TicketSchema.history,
          where: 'object_id=?',
          whereArgs: [child.id],
        );
        if (!h.any(
          (h) => sameSqlRow(decodeSqlRow(h['after_json'] as String), child.raw),
        )) {
          throw StateError('换送子流水原档缺失');
        }
        bound[child.id] = r.id;
      }
      matching(r, children);
      latest[r.id] = r.raw;
    }
    final tickets = await loadTicketObjects(db),
        byId = {for (final t in tickets) t.id: t},
        current = <String>{};
    if (all.length != latest.length) throw StateError('换送当前状态缺失');
    for (final r in all) {
      if (latest[r.id] == null || !sameSqlRow(r.raw, latest[r.id]!)) {
        throw StateError('换送当前行与原档不一致');
      }
      matching(
        r,
        r.children.map((id) {
          if (!current.add(id) || byId[id] == null) {
            throw StateError('换送当前归属重复');
          }
          return byId[id]!;
        }).toList(),
      );
    }
    final links = await db.query(bindings);
    if (links.length != bound.length) throw StateError('换送绑定缺失');
    for (final b in links) {
      if (bound[b['ticket_id']] != b['transfer_id'] ||
          byId[b['ticket_id']]!.posted && !current.contains(b['ticket_id'])) {
        throw StateError('换送子流水单边修改');
      }
    }
    final bases = await db.query(lots), seenLots = <String>{};
    final costAudit = await CostLinkAudit.read(db);
    for (final b in [
      ...bases,
      ...costAudit.beforeLots,
      ...costAudit.afterLots,
    ]) {
      final incoming = byId[b['ticket_id']], outgoing = byId[b['outgoing_id']];
      if (incoming == null ||
          outgoing == null ||
          incoming.kind != 'adjustment' ||
          outgoing.kind != 'adjustment' ||
          (outgoing.information.quantity ?? 0) >= 0 ||
          !bound.containsKey(incoming.id) ||
          bound[incoming.id] != bound[outgoing.id] ||
          incoming.information.quantity != b['quantity'] ||
          incoming.information.quantity! <= 0 ||
          !isActionStamp(b['created_at']) ||
          b['created_at'] != incoming.raw['created_at']) {
        throw StateError('继承成本来源无效');
      }
      final source = TicketObject.fromRow(
        decodeSqlRow(b['source_json'] as String),
      );
      if (source.id != b['source_id'] ||
          source.information.quantity == null ||
          source.information.quantity! <= 0) {
        throw StateError('原成本批次无效');
      }
      final sourceHistory = await db.query(
        TicketSchema.history,
        where: 'object_id=?',
        whereArgs: [source.id],
      );
      if (!sourceHistory.any(
        (h) => sameSqlRow(decodeSqlRow(h['after_json'] as String), source.raw),
      )) {
        throw StateError('原来源历史缺失');
      }
      final unit = b['unit_cost'] == null
          ? null
          : TicketMoney.fromExact(b['unit_cost'] as String);
      if (b['source_unit_cost'] != b['unit_cost']) throw StateError('继承成本不守恒');
      final sourceBasis = bases
          .where((r) => r['ticket_id'] == source.id)
          .firstOrNull;
      final expectedUnit = sourceBasis == null
          ? source.information.unitCost?.exact
          : costAudit.historicalUnit(source, sourceBasis);
      if (b['unit_cost'] != expectedUnit || source.seq >= incoming.seq) {
        throw StateError('继承单位成本与原购入不一致');
      }
      final histories = await db.query(
        TicketSchema.history,
        where: 'object_id=?',
        whereArgs: [outgoing.id],
      );
      if (!histories.any((h) {
        final old = TicketObject.fromRow(
          decodeSqlRow(h['after_json'] as String),
        );
        return old.posted &&
            old.allocations.any(
              (a) =>
                  a['source_id'] == source.id &&
                  a['quantity'] == b['quantity'] &&
                  a['cost'] == unit?.times(b['quantity'] as int).exact,
            );
      })) {
        throw StateError('继承来源与转出分配不一致');
      }
      seenLots.add(incoming.id);
    }
    for (final outgoingId in bases.map((r) => r['outgoing_id']).toSet()) {
      final rows = bases.where((r) => r['outgoing_id'] == outgoingId).toList();
      final h = await db.query(
        TicketSchema.history,
        where: 'object_id=?',
        whereArgs: [outgoingId],
      );
      if (!h.any((r) {
        final old = TicketObject.fromRow(
          decodeSqlRow(r['after_json'] as String),
        );
        return old.posted &&
            old.allocations.length == rows.length &&
            old.allocations.every(
              (a) =>
                  rows
                      .where(
                        (b) =>
                            b['source_id'] == a['source_id'] &&
                            b['quantity'] == a['quantity'] &&
                            a['cost'] ==
                                (b['unit_cost'] == null
                                    ? null
                                    : TicketMoney.fromExact(
                                        b['unit_cost'] as String,
                                      ).times(b['quantity'] as int).exact),
                      )
                      .length ==
                  1,
            );
      })) {
        throw StateError('交换逐来源分配覆盖不一致');
      }
    }
    for (final id in bound.keys) {
      if (byId[id]!.information.quantity! > 0 && !seenLots.contains(id)) {
        throw StateError('继承成本批次缺失');
      }
    }
  }
}

class TransferStore {
  TransferStore(
    this.database, {
    DateTime Function()? clock,
    this.afterOutgoing,
    this.afterIncoming,
  }) : clock = clock ?? DateTime.now;
  final Future<Database> Function() database;
  final DateTime Function() clock;
  final Future<void> Function()? afterOutgoing, afterIncoming;
  Future<bool> exists(DatabaseExecutor db) async => (await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    [TransferSchema.objects],
  )).isNotEmpty;
  Future<List<TransferObject>> list() async {
    final db = await database();
    if (!await exists(db)) return [];
    return (await db.query(
      TransferSchema.objects,
      orderBy: 'seq',
    )).map(TransferObject.fromRow).toList();
  }

  Future<TransferObject?> forTicket(String id) async {
    final db = await database();
    if (!await exists(db)) return null;
    final rows = await db.query(
      TransferSchema.bindings,
      where: 'ticket_id=?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return TransferObject.fromRow(
      (await db.query(
        TransferSchema.objects,
        where: 'id=?',
        whereArgs: [rows.single['transfer_id']],
      )).single,
    );
  }

  Future<List<Map<String, Object?>>> history(String id) async =>
      (await database()).query(
        TransferSchema.operations,
        where: 'object_id=?',
        whereArgs: [id],
        orderBy: 'seq',
      );
  Future<List<TicketObject>> dependents(Iterable<String> sources) async {
    return (await database()).transaction((db) async {
      final objects = await loadTicketObjects(db);
      final bases = await exists(db)
          ? await db.query(TransferSchema.lots)
          : <Map<String, Object?>>[];
      final found = <String>{}, reach = sources.toSet();
      bool again = true;
      while (again) {
        again = false;
        for (final o in objects) {
          if (o.posted &&
              !reach.contains(o.id) &&
              o.allocations.any((a) => reach.contains(a['source_id'])) &&
              found.add(o.id)) {
            reach.add(o.id);
            again = true;
          }
        }
        for (final b in bases) {
          if (reach.contains(b['outgoing_id']) &&
              !reach.contains(b['ticket_id']) &&
              objects.any((o) => o.id == b['ticket_id'] && o.posted)) {
            reach.add(b['ticket_id'] as String);
            found.add(b['ticket_id'] as String);
            again = true;
          }
        }
      }
      return objects.where((o) => found.contains(o.id)).toList();
    });
  }

  Future<List<Map<String, Object?>>> preview(
    TransferInformation i, {
    TransferObject? original,
    bool posted = true,
  }) async {
    final db = await database();
    return db.transaction((tx) async {
      await TransferSchema.checkInput(tx, i, posted: posted);
      final objects = await loadTicketObjects(tx);
      if (original != null) {
        final dependency = objects.where(
          (o) =>
              o.posted &&
              !original.children.contains(o.id) &&
              o.allocations.any(
                (a) => original.children.contains(a['source_id']),
              ),
        );
        if (dependency.isNotEmpty) {
          throw const CatalogException('已有下游操作，只可查看依赖，不能修改');
        }
      }
      if (!posted) return [];
      final effective = objects
              .where((o) => original?.children.contains(o.id) != true)
              .toList(),
          day = i.text('occurred_on')!;
      final rest = remainingLots(effective, day),
          out = <Map<String, Object?>>[];
      var left = i.quantity!;
      if (i.text('source_expires_on') != null &&
          i.text('source_expires_on')!.compareTo(day) < 0 &&
          !i.expiredConfirmed) {
        throw const CatalogException('请明确确认使用过期券');
      }
      final candidates =
          effective
              .where(
                (o) =>
                    o.posted &&
                    (o.information.quantity ?? 0) > 0 &&
                    o.information.day!.compareTo(day) <= 0 &&
                    o.information.text('definition_id') ==
                        i.text('source_definition_id') &&
                    o.information.text('pool') == i.text('source_pool') &&
                    o.information.expiry == i.text('source_expires_on'),
              )
              .toList()
            ..sort((a, b) {
              final c = a.information.day!.compareTo(b.information.day!);
              return c != 0 ? c : a.seq.compareTo(b.seq);
            });
      for (final source in candidates) {
        final n = left < (rest[source.id] ?? 0) ? left : (rest[source.id] ?? 0);
        if (n > 0) {
          out.add({
            'source_id': source.id,
            'quantity': n,
            'cost': source.unitCost?.times(n).exact,
          });
        }
        left -= n;
      }
      if (left != 0) {
        throw CatalogException(
          '该发生日期库存不足：需要${i.quantity}张，可用${i.quantity! - left}张，还差$left张；不能借未来库存',
        );
      }
      return out;
    });
  }

  Future<TransferObject> save(
    TransferInformation i, {
    required String operationId,
    bool posted = false,
    TransferObject? original,
  }) async {
    if (operationId.trim().isEmpty) throw const CatalogException('操作标识缺失');
    final request = jsonEncode({
      'id': original?.id,
      'revision': original?.revision,
      'information_json': i.encode(),
      'posted': posted,
    });
    var changed = false;
    final result = await (await database()).transaction((tx) async {
      final repeated = await tx.query(
        TransferSchema.operations,
        where: 'id=?',
        whereArgs: [operationId],
      );
      if (repeated.isNotEmpty) {
        if (repeated.single['request_json'] != request) {
          throw const CatalogException('该操作标识用于其他修改');
        }
        return TransferObject.fromRow(
          decodeSqlRow(
            (jsonDecode(repeated.single['result_json'] as String)
                    as Map)['object_json']
                as String,
          ),
        );
      }
      for (final t in [
        'cheki_catalog_operations',
        'cheki_identity_operations',
        'cheki_record_operations',
        'cheki_ticket_operations',
        'cheki_entry_operations',
      ]) {
        if ((await tx.query(
          t,
          where: 'id=?',
          whereArgs: [operationId],
        )).isNotEmpty) {
          throw const CatalogException('操作标识已占用');
        }
      }
      await TransferSchema.checkInput(tx, i, posted: posted);
      final all = await loadTicketObjects(tx);
      Map<String, Object?>? before;
      if (original != null) {
        final r = await tx.query(
          TransferSchema.objects,
          where: 'id=?',
          whereArgs: [original.id],
        );
        if (r.length != 1 || r.single['revision'] != original.revision) {
          throw const CatalogException('操作已修改，请重新打开');
        }
        before = r.single;
        if (all.any(
          (o) =>
              o.posted &&
              !original.children.contains(o.id) &&
              o.allocations.any(
                (a) => original.children.contains(a['source_id']),
              ),
        )) {
          throw const CatalogException('已有下游操作，只展示依赖并阻止修改');
        }
      }
      final stamp = actionStamp(clock());
      if (before != null &&
          stamp.compareTo(before['updated_at'] as String) < 0) {
        throw const CatalogException('系统时间早于上次修改');
      }
      final row = before == null
          ? <String, Object?>{'id': newOperationId(), 'created_at': stamp}
          : copySqlRow(before);
      row.addAll({
        'information_json': i.encode(),
        'children_json': '[]',
        'posted': posted ? 1 : 0,
        'revision': before == null ? 1 : (before['revision'] as int) + 1,
        'updated_at': stamp,
      });
      if (before == null) {
        await tx.insert(TransferSchema.objects, row);
        row['seq'] = (await tx.query(
          TransferSchema.objects,
          columns: ['seq'],
          where: 'id=?',
          whereArgs: [row['id']],
        )).single['seq'];
      }
      final writer = TicketStore(
        () => Future.value(OwnedTransactionDatabase(tx)),
        clock: clock,
        managedTransfer: true,
      );
      if (original != null) {
        // Release incoming first; no downstream has been allowed through the guard.
        final old = all.where((o) => original.children.contains(o.id)).toList()
          ..sort(
            (a, b) =>
                b.information.quantity!.compareTo(a.information.quantity!),
          );
        for (final c in old) {
          await writer.save(
            kind: c.kind,
            information: c.information,
            original: c,
            operationId: '$operationId:release:${c.id}',
            posted: false,
          );
        }
      }
      final children = <TicketObject>[];
      if (posted) {
        final outgoing = await writer.save(
          kind: 'adjustment',
          information: TicketInformation({
            'definition_id': i.text('source_definition_id'),
            'quantity': -i.quantity!,
            'occurred_on': i.text('occurred_on'),
            'pool': i.text('source_pool'),
            'expires_on': i.text('source_expires_on'),
            'reason': i.text('kind') == 'exchange' ? '交换转出' : '赠送',
            'transfer_id': row['id'],
          }),
          operationId: '$operationId:out',
          posted: true,
          allowExpired: i.expiredConfirmed,
        );
        children.add(outgoing);
        if (afterOutgoing != null) await afterOutgoing!();
        if (i.text('kind') == 'exchange') {
          var n = 0;
          for (final allocation in outgoing.allocations) {
            final source = all.singleWhere(
              (s) => s.id == allocation['source_id'],
            );
            final incoming = await writer.save(
              kind: 'adjustment',
              information: TicketInformation({
                'definition_id': i.text('target_definition_id'),
                'quantity': allocation['quantity'],
                'occurred_on': i.text('occurred_on'),
                'pool': i.text('target_pool'),
                'expires_on': i.text('target_expires_on'),
                'reason': '交换转入',
                'transfer_id': row['id'],
              }),
              operationId: '$operationId:in:${n++}',
              posted: true,
            );
            await tx.insert(TransferSchema.lots, {
              'ticket_id': incoming.id,
              'source_id': source.id,
              'outgoing_id': outgoing.id,
              'quantity': allocation['quantity'],
              'unit_cost': source.unitCost?.exact,
              'source_json': encodeSqlRow(source.raw),
              'source_unit_cost': source.unitCost?.exact,
              'created_at': stamp,
            });
            children.add(incoming);
          }
        }
        if (afterIncoming != null) await afterIncoming!();
        for (final child in children) {
          await tx.insert(TransferSchema.bindings, {
            'ticket_id': child.id,
            'transfer_id': row['id'],
          });
        }
      }
      row['children_json'] = jsonEncode(children.map((c) => c.id).toList());
      await tx.update(
        TransferSchema.objects,
        row,
        where: 'id=?',
        whereArgs: [row['id']],
      );
      await tx.insert(TransferSchema.operations, {
        'id': operationId,
        'object_id': row['id'],
        'request_json': request,
        'before_json': before == null ? null : encodeSqlRow(before),
        'result_json': jsonEncode({
          'object_json': encodeSqlRow(row),
          'children_json': jsonEncode(
            children.map((c) => encodeSqlRow(c.raw)).toList(),
          ),
        }),
        'created_at': stamp,
      });
      await TicketSchema.validate(tx);
      await TransferSchema.validate(tx);
      changed = true;
      return TransferObject.fromRow(row);
    });
    if (changed) TicketStore.invalidateReads();
    return result;
  }
}
