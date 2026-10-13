import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/ticket_information.dart';
import '../domain/record_contract.dart';
import 'catalog_contract.dart';
import 'catalog_store.dart';

class TicketObject {
  TicketObject.fromRow(Map<String, Object?> row) : raw = copySqlRow(row) {
    if (row['id'] is! String ||
        (row['id'] as String).isEmpty ||
        row['seq'] is! int ||
        (row['seq'] as int) < 1 ||
        row['revision'] is! int ||
        (row['revision'] as int) < 1 ||
        ![
          'definition',
          'purchase',
          'adjustment',
          'setting',
        ].contains(row['kind']) ||
        ![0, 1].contains(row['posted']) ||
        !isActionStamp(row['created_at']) ||
        !isActionStamp(row['updated_at']) ||
        (row['updated_at'] as String).compareTo(row['created_at'] as String) <
            0) {
      throw const FormatException('券存储格式无效');
    }
    information;
    allocations;
  }
  final Map<String, Object?> raw;
  String get id => raw['id'] as String;
  int get seq => raw['seq'] as int;
  int get revision => raw['revision'] as int;
  String get kind => raw['kind'] as String;
  bool get posted => raw['posted'] == 1;
  TicketInformation get information =>
      TicketInformation.decode(raw['information_json'] as String);
  List<Map<String, Object?>> get allocations =>
      (jsonDecode(raw['allocations_json'] as String) as List)
          .map((e) => Map<String, Object?>.from(e as Map))
          .toList();
}

class TicketPool {
  TicketPool(this.definitionId, this.expiry, this.quantity);
  final String definitionId;
  final String? expiry;
  final int quantity;
  bool expired(String day) => expiry != null && expiry!.compareTo(day) < 0;
  bool near(String day, int days) =>
      expiry != null &&
      !expired(day) &&
      DateTime.parse(expiry!).difference(DateTime.parse(day)).inDays <= days;
}

class TicketModel {
  TicketModel(this.objects, this.groups, this.members, this.sizes, this.day) {
    validateLedger(objects);
  }
  final List<TicketObject> objects;
  final Map<String, String> groups, members, sizes;
  final String day;
  List<TicketObject> get definitions =>
      objects.where((e) => e.kind == 'definition').toList();
  int get reminderDays {
    final settings = objects.where((e) => e.kind == 'setting').toList();
    return settings.isEmpty
        ? 7
        : (settings.last.information.toMap()['reminder_days'] as int? ?? 7);
  }

  String label(TicketObject d) {
    final i = d.information;
    return '${groups[i.text('group_id')] ?? '团体未填写'} · ${i.text('name') ?? '券名未填写'}';
  }

  String scopeLabel(TicketObject d) => d.information.text('scope') == 'personal'
      ? '个人券 · ${members[d.information.text('member_id')] ?? '成员未填写'}'
      : d.information.text('scope') == 'group'
      ? '团体通用券'
      : '范围未填写';
  Map<String, int> get remaining => remainingLots(objects, day);
  List<TicketPool> pools(String id) {
    final result = <String?, int>{};
    final rest = remaining;
    for (final e in objects.where(
      (e) =>
          e.posted &&
          (e.information.quantity ?? 0) > 0 &&
          e.information.text('definition_id') == id &&
          e.information.day!.compareTo(day) <= 0,
    )) {
      final q = rest[e.id] ?? 0;
      if (q > 0) {
        result.update(
          e.information.expiry,
          (old) => old + q,
          ifAbsent: () => q,
        );
      }
    }
    return result.entries.map((e) => TicketPool(id, e.key, e.value)).toList()
      ..sort(
        (a, b) =>
            (a.expiry ?? '9999-99-99').compareTo(b.expiry ?? '9999-99-99'),
      );
  }

  List<TicketPool> get allPools =>
      definitions.expand((e) => pools(e.id)).toList();
  int get available =>
      allPools.where((p) => !p.expired(day)).fold(0, (q, p) => q + p.quantity);
  List<TicketObject> get drafts => objects
      .where((e) => !e.posted && ['purchase', 'adjustment'].contains(e.kind))
      .toList();
}

/// Balances are derived from source entries and immutable allocation references.
/// Replay checks every business date; an early outgoing cannot borrow future lots.
Map<String, int> remainingLots(List<TicketObject> objects, String day) {
  final result = <String, int>{};
  final ordered = objects.where((e) => e.posted).toList()
    ..sort((a, b) {
      final c = a.information.day!.compareTo(b.information.day!);
      return c != 0 ? c : a.seq.compareTo(b.seq);
    });
  final incoming = <String, TicketObject>{};
  for (final e in ordered) {
    if (e.information.day!.compareTo(day) > 0) continue;
    final q = e.information.quantity!;
    if (q > 0) {
      result[e.id] = q;
      incoming[e.id] = e;
    } else {
      var sum = 0;
      for (final a in e.allocations) {
        final id = a['source_id'];
        final n = a['quantity'];
        final source = incoming[id];
        if (id is! String ||
            n is! int ||
            n <= 0 ||
            source == null ||
            source.information.text('definition_id') !=
                e.information.text('definition_id') ||
            source.information.text('pool') != e.information.text('pool') ||
            source.information.expiry != e.information.expiry ||
            (result[id] ?? 0) < n ||
            a['cost'] != source.information.unitCost?.times(n).exact) {
          throw const FormatException('库存或成本分配不一致');
        }
        result[id] = result[id]! - n;
        sum += n;
      }
      if (sum != -q) throw const FormatException('库存转出数量不一致');
    }
  }
  return result;
}

void validateLedger(List<TicketObject> objects) {
  for (final e in objects) {
    final i = e.information;
    if (e.kind == 'setting') {
      final days = i.toMap()['reminder_days'];
      if (days != null && (days is! int || days < 0 || days > 365)) {
        throw const FormatException('提醒天数需为0至365');
      }
    }
    if (e.posted) {
      if (!['purchase', 'adjustment'].contains(e.kind) ||
          i.quantity == null ||
          i.day == null ||
          i.text('definition_id') == null ||
          i.text('pool') == null ||
          (i.text('pool') == 'dated' && i.expiry == null) ||
          (e.kind == 'purchase' && i.quantity! < 0) ||
          i.costConflict) {
        throw const FormatException('实际入账需要已知券种、张数、日期和期限；金额冲突请先核对');
      }
      if (i.quantity! > 0 && e.allocations.isNotEmpty) {
        throw const FormatException('入库不应有转出分配');
      }
    } else if (e.allocations.isNotEmpty) {
      throw const FormatException('草稿不应有库存分配');
    }
  }
  remainingLots(objects, '9999-12-31');
}

abstract final class TicketSchema {
  static const objects = 'cheki_ticket_objects',
      operations = 'cheki_ticket_operations',
      history = 'cheki_ticket_history';
  static Future<void> create(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE $objects(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,information_json TEXT NOT NULL,posted INTEGER NOT NULL CHECK(posted IN (0,1)),allocations_json TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>0),created_at TEXT NOT NULL,updated_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE $operations(id TEXT PRIMARY KEY NOT NULL,object_id TEXT NOT NULL REFERENCES $objects(id) ON DELETE RESTRICT,request_json TEXT NOT NULL,result_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE $history(id INTEGER PRIMARY KEY AUTOINCREMENT,object_id TEXT NOT NULL REFERENCES $objects(id) ON DELETE RESTRICT,operation_id TEXT NOT NULL UNIQUE REFERENCES $operations(id) ON DELETE RESTRICT,before_json TEXT,after_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute('CREATE INDEX cheki_ticket_kind ON $objects(kind,seq)');
  }

  static Future<void> references(DatabaseExecutor db, TicketObject e) async {
    final i = e.information;
    for (final entry in {
      'group_id': 'cheki_groups',
      'member_id': 'cheki_members',
      'size_id': 'cheki_sizes',
      'definition_id': objects,
    }.entries) {
      final id = i.text(entry.key);
      if (id == null) continue;
      final rows = await db.query(entry.value, where: 'id=?', whereArgs: [id]);
      if (rows.length != 1 ||
          (entry.key == 'definition_id' &&
              rows.single['kind'] != 'definition')) {
        throw const FormatException('关联不存在，请重新选择');
      }
      if (entry.key == 'member_id' &&
          i.text('group_id') != null &&
          rows.single['group_id'] != i.text('group_id')) {
        throw const FormatException('个人券成员与团体不一致');
      }
    }
    if (e.posted) {
      final def = TicketObject.fromRow(
        (await db.query(
          objects,
          where: 'id=?',
          whereArgs: [i.text('definition_id')],
        )).single,
      );
      if (def.information.text('group_id') == null ||
          def.information.text('scope') == null ||
          (def.information.text('scope') == 'personal' &&
              def.information.text('member_id') == null)) {
        throw const FormatException('入账前请补齐券种归属');
      }
    }
  }

  static Future<void> validate(DatabaseExecutor db) async {
    for (final t in [objects, operations, history]) {
      if ((await db.rawQuery('PRAGMA foreign_key_check($t)')).isNotEmpty) {
        throw StateError('券关联无效');
      }
    }
    final entities = (await db.query(
      objects,
    )).map(TicketObject.fromRow).toList();
    for (final e in entities) {
      await references(db, e);
    }
    validateLedger(entities);
    final ops = {for (final r in await db.query(operations)) r['id']: r};
    for (final t in [
      'cheki_catalog_operations',
      'cheki_identity_operations',
      'cheki_record_operations',
    ]) {
      if ((await db.query(t)).any((r) => ops.containsKey(r['id']))) {
        throw StateError('券操作标识重复');
      }
    }
    final latest = <Object?, Map<String, Object?>>{};
    final seen = <Object?>{};
    for (final h in await db.query(history, orderBy: 'id')) {
      final op = ops[h['operation_id']];
      final after = decodeSqlRow(h['after_json'] as String);
      final a = TicketObject.fromRow(after);
      final before = h['before_json'] == null
          ? null
          : decodeSqlRow(h['before_json'] as String);
      final previous = latest[h['object_id']];
      if (op == null ||
          !seen.add(op['id']) ||
          op['object_id'] != a.id ||
          h['object_id'] != a.id ||
          op['created_at'] != h['created_at'] ||
          a.raw['updated_at'] != h['created_at'] ||
          op['result_json'] != h['after_json'] ||
          !isActionStamp(h['created_at']) ||
          (previous == null && (before != null || a.revision != 1)) ||
          (previous != null &&
              (before == null ||
                  !sameSqlRow(previous, before) ||
                  a.revision != (previous['revision'] as int) + 1 ||
                  before['seq'] != after['seq'] ||
                  before['created_at'] != after['created_at'] ||
                  before['kind'] != after['kind']))) {
        throw StateError('券修订历史无效');
      }
      final request = jsonDecode(op['request_json'] as String) as Map;
      if (request['kind'] != a.kind ||
          request['information_json'] != after['information_json'] ||
          request['posted'] != a.posted ||
          request['id'] != (before == null ? null : a.id) ||
          request['revision'] != (before == null ? null : before['revision'])) {
        throw StateError('券操作请求无效');
      }
      latest[a.id] = after;
    }
    if (seen.length != ops.length ||
        latest.length != entities.length ||
        entities.any((e) => !sameSqlRow(e.raw, latest[e.id]!))) {
      throw StateError('券原档不完整');
    }
  }
}

class TicketStore {
  TicketStore(this.database, {DateTime Function()? clock, this.afterWrite})
    : clock = clock ?? DateTime.now;
  final Future<Database> Function() database;
  final DateTime Function() clock;
  final Future<void> Function()? afterWrite;
  static final _changes = StreamController<void>.broadcast(sync: true);
  static Stream<void> get changes => _changes.stream;
  static void invalidateReads() => _changes.add(null);
  Future<TicketModel> readModel({String? day}) async {
    final db = await database();
    return db.transaction((tx) async {
      Future<Map<String, String>> names(String table) async => {
        for (final r in await tx.query(table))
          r['id'] as String: (r['name'] as String?) ?? '名称未填写',
      };
      return TicketModel(
        (await tx.query(
          TicketSchema.objects,
          orderBy: 'seq',
        )).map(TicketObject.fromRow).toList(),
        await names('cheki_groups'),
        await names('cheki_members'),
        await names('cheki_sizes'),
        day ?? OccurredOn.shanghaiDay(clock()).value,
      );
    });
  }

  Future<List<Map<String, Object?>>> history(String id) async =>
      (await database()).query(
        TicketSchema.history,
        where: 'object_id=?',
        whereArgs: [id],
        orderBy: 'id',
      );

  /// Ordered FEFO suggestion, no expired or future purchases. Cost is never averaged.
  Future<List<TicketPool>> suggest(
    String definitionId,
    int quantity,
    String day,
  ) async {
    if (quantity <= 0) throw const FormatException('张数需大于零');
    final m = await readModel(day: day);
    var left = quantity;
    final out = <TicketPool>[];
    for (final p in m.pools(definitionId).where((p) => !p.expired(day))) {
      final n = left < p.quantity ? left : p.quantity;
      if (n > 0) out.add(TicketPool(definitionId, p.expiry, n));
      left -= n;
    }
    if (left > 0) throw const FormatException('库存不足');
    return out;
  }

  Future<TicketObject> save({
    required String kind,
    required TicketInformation information,
    required String operationId,
    TicketObject? original,
    bool posted = false,
    bool allowExpired = false,
  }) async {
    if (operationId.trim().isEmpty) throw const FormatException('操作标识缺失');
    final request = jsonEncode({
      'kind': kind,
      'id': original?.id,
      'revision': original?.revision,
      'information_json': information.encode(),
      'posted': posted,
      'allow_expired': allowExpired,
    });
    final db = await database();
    var changed = false;
    final saved = await db.transaction((tx) async {
      final used = await tx.query(
        TicketSchema.operations,
        where: 'id=?',
        whereArgs: [operationId],
      );
      if (used.isNotEmpty) {
        if (used.single['request_json'] != request) {
          throw const FormatException('此操作已用于其他修改');
        }
        return TicketObject.fromRow(
          decodeSqlRow(used.single['result_json'] as String),
        );
      }
      for (final table in [
        'cheki_catalog_operations',
        'cheki_identity_operations',
        'cheki_record_operations',
      ]) {
        if ((await tx.query(
          table,
          where: 'id=?',
          whereArgs: [operationId],
        )).isNotEmpty) {
          throw const FormatException('操作标识已占用');
        }
      }
      final all = (await tx.query(
        TicketSchema.objects,
        orderBy: 'seq',
      )).map(TicketObject.fromRow).toList();
      Map<String, Object?>? before;
      if (original != null) {
        final matches = all.where((e) => e.id == original.id).toList();
        if (matches.length != 1 ||
            matches.single.revision != original.revision ||
            matches.single.kind != kind) {
          throw const FormatException('条目已修改，请重新打开');
        }
        before = matches.single.raw;
        if (all.any(
          (e) =>
              e.id != original.id &&
              e.allocations.any((a) => a['source_id'] == original.id),
        )) {
          throw const FormatException('此条目已有下游库存操作，保留原账；请先检查依赖流水');
        }
        if (kind == 'definition' &&
            all.any(
              (e) =>
                  e.posted &&
                  e.information.text('definition_id') == original.id,
            )) {
          for (final k in ['group_id', 'scope', 'member_id']) {
            if (original.information.text(k) != information.text(k)) {
              throw const FormatException('已有库存流水，不能改写券种归属；可另建券种');
            }
          }
        }
      }
      final stamp = actionStamp(clock());
      if (before != null &&
          stamp.compareTo(before['updated_at'] as String) < 0) {
        throw const FormatException('系统时间早于上次修改');
      }
      final row = before == null
          ? <String, Object?>{
              'id': newOperationId(),
              'kind': kind,
              'revision': 1,
              'created_at': stamp,
            }
          : copySqlRow(before);
      row.addAll({
        'information_json': information.encode(),
        'posted': posted ? 1 : 0,
        'updated_at': stamp,
        'revision': before == null ? 1 : (before['revision'] as int) + 1,
        'allocations_json': '[]',
      });
      if (before == null) {
        await tx.insert(TicketSchema.objects, row);
        row['seq'] = (await tx.query(
          TicketSchema.objects,
          columns: ['seq'],
          where: 'id=?',
          whereArgs: [row['id']],
        )).single['seq'];
      }
      if (posted && (information.quantity ?? 0) < 0) {
        final day = information.day;
        if (day == null) throw const FormatException('入账日期未填写');
        final def = all
            .where((e) => e.id == information.text('definition_id'))
            .toList();
        if (def.length != 1 ||
            def.single.information.toMap()['active'] != true) {
          throw const FormatException('券种未启用');
        }
        if (information.expiry != null &&
            information.expiry!.compareTo(day) < 0 &&
            !allowExpired) {
          throw const FormatException('此券已过期，请明确确认使用过期库存');
        }
        final others = all.where((e) => e.id != original?.id).toList();
        final rest = remainingLots(others, day);
        final sources =
            others
                .where(
                  (e) =>
                      e.posted &&
                      (e.information.quantity ?? 0) > 0 &&
                      e.information.text('definition_id') ==
                          information.text('definition_id') &&
                      e.information.text('pool') == information.text('pool') &&
                      e.information.expiry == information.expiry &&
                      e.information.day!.compareTo(day) <= 0,
                )
                .toList()
              ..sort((a, b) {
                final c = a.information.day!.compareTo(b.information.day!);
                return c != 0 ? c : a.seq.compareTo(b.seq);
              });
        var left = -information.quantity!;
        final allocations = <Map<String, Object?>>[];
        for (final s in sources) {
          final n = left < (rest[s.id] ?? 0) ? left : (rest[s.id] ?? 0);
          if (n > 0) {
            allocations.add({
              'source_id': s.id,
              'quantity': n,
              'cost': s.information.unitCost?.times(n).exact,
            });
          }
          left -= n;
        }
        if (left != 0) throw const FormatException('该日期库存不足，不能借用未来购入库存');
        row['allocations_json'] = jsonEncode(allocations);
      }
      if (posted && (information.quantity ?? 0) > 0) {
        final defs = all
            .where((e) => e.id == information.text('definition_id'))
            .toList();
        if (defs.length != 1 ||
            defs.single.information.toMap()['active'] != true) {
          throw const FormatException('券种未启用');
        }
      }
      await tx.update(
        TicketSchema.objects,
        row,
        where: 'id=?',
        whereArgs: [row['id']],
      );
      final entity = TicketObject.fromRow(row);
      await TicketSchema.references(tx, entity);
      validateLedger([...all.where((e) => e.id != entity.id), entity]);
      final after = encodeSqlRow(row);
      await tx.insert(TicketSchema.operations, {
        'id': operationId,
        'object_id': entity.id,
        'request_json': request,
        'result_json': after,
        'created_at': stamp,
      });
      await tx.insert(TicketSchema.history, {
        'object_id': entity.id,
        'operation_id': operationId,
        'before_json': before == null ? null : encodeSqlRow(before),
        'after_json': after,
        'created_at': stamp,
      });
      if (afterWrite != null) await afterWrite!();
      changed = true;
      return entity;
    });
    if (changed) invalidateReads();
    return saved;
  }
}
