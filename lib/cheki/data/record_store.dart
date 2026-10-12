import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/record_information.dart';
import 'catalog_contract.dart';
import 'catalog_schema.dart';
import 'catalog_store.dart';
import 'identity_schema.dart';
import 'identity_store.dart';
import 'identity_contract.dart';
import 'record_query.dart';

class StoredRecord {
  StoredRecord.fromRow(Map<String, Object?> row) : _raw = copySqlRow(row) {
    if (row['id'] is! String ||
        (row['id'] as String).trim().isEmpty ||
        row['revision'] is! int ||
        (row['revision'] as int) < 1 ||
        !isActionStamp(row['created_at']) ||
        !isActionStamp(row['updated_at']) ||
        (row['updated_at'] as String).compareTo(row['created_at'] as String) <
            0 ||
        row['information_json'] is! String) {
      throw const FormatException('记录存储格式无效');
    }
    information;
  }
  final Map<String, Object?> _raw;
  String get id => _raw['id'] as String;
  int get revision => _raw['revision'] as int;
  String get createdAt => _raw['created_at'] as String;
  String get updatedAt => _raw['updated_at'] as String;
  RecordInformation get information =>
      RecordInformation.decode(_raw['information_json'] as String);
  Map<String, Object?> toRow() => copySqlRow(_raw);
}

abstract final class RecordSchema {
  static const records = 'cheki_records',
      operations = 'cheki_record_operations',
      history = 'cheki_record_history';
  static Future<void> create(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE $records(id TEXT PRIMARY KEY NOT NULL,information_json TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,revision INTEGER NOT NULL CHECK(revision>0))',
    );
    await db.execute(
      'CREATE TABLE $operations(id TEXT PRIMARY KEY NOT NULL,record_id TEXT NOT NULL REFERENCES $records(id) ON DELETE RESTRICT,request_json TEXT NOT NULL,result_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE $history(id INTEGER PRIMARY KEY AUTOINCREMENT,record_id TEXT NOT NULL REFERENCES $records(id) ON DELETE RESTRICT,operation_id TEXT NOT NULL UNIQUE REFERENCES $operations(id) ON DELETE RESTRICT,before_json TEXT,after_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX cheki_record_revisions ON $history(record_id,id)',
    );
  }

  static Future<void> validate(DatabaseExecutor db) async {
    for (final entry in {
      records: [
        'id',
        'information_json',
        'created_at',
        'updated_at',
        'revision',
      ],
      operations: [
        'id',
        'record_id',
        'request_json',
        'result_json',
        'created_at',
      ],
      history: [
        'id',
        'record_id',
        'operation_id',
        'before_json',
        'after_json',
        'created_at',
      ],
    }.entries) {
      if (!(await db.rawQuery(
            'PRAGMA table_info(${entry.key})',
          )).map((r) => r['name']).toSet().containsAll(entry.value) ||
          (await db.rawQuery(
            'PRAGMA foreign_key_check(${entry.key})',
          )).isNotEmpty) {
        throw StateError('Record schema or relationship invalid');
      }
    }
    final ops = {for (final r in await db.query(operations)) r['id']: r};
    for (final table in [CatalogSchema.operations, IdentitySchema.operations]) {
      if ((await db.query(table)).any((r) => ops.containsKey(r['id']))) {
        throw StateError('Record operation ID reused');
      }
    }
    final last = <String, Map<String, Object?>>{};
    final seen = <Object?>{};
    for (final h in await db.query(history, orderBy: 'id')) {
      final op = ops[h['operation_id']];
      if (op == null ||
          !seen.add(op['id']) ||
          op['id'] is! String ||
          (op['id'] as String).trim().isEmpty ||
          h['id'] is! int ||
          (h['id'] as int) <= 0 ||
          op['record_id'] != h['record_id'] ||
          op['created_at'] != h['created_at'] ||
          !isActionStamp(h['created_at'])) {
        throw StateError('Record history relationship invalid');
      }
      final after = decodeSqlRow(h['after_json'] as String);
      final entity = StoredRecord.fromRow(after);
      final before = h['before_json'] == null
          ? null
          : decodeSqlRow(h['before_json'] as String);
      final request = jsonDecode(op['request_json'] as String) as Map;
      if (entity.id != h['record_id'] ||
          entity.updatedAt != h['created_at'] ||
          !sameSqlRow(after, decodeSqlRow(op['result_json'] as String)) ||
          request['information_json'] != after['information_json']) {
        throw StateError('Record result mismatch');
      }
      if (before == null) {
        if (last.containsKey(entity.id) ||
            entity.revision != 1 ||
            entity.createdAt != entity.updatedAt ||
            request['id'] != null ||
            request['revision'] != null) {
          throw StateError('Record creation audit invalid');
        }
      } else {
        final original = StoredRecord.fromRow(before);
        final a = copySqlRow(before)
          ..removeWhere(
            (k, _) =>
                ['information_json', 'updated_at', 'revision'].contains(k),
          );
        final b = copySqlRow(after)
          ..removeWhere(
            (k, _) =>
                ['information_json', 'updated_at', 'revision'].contains(k),
          );
        if (last[entity.id] == null ||
            !sameSqlRow(before, last[entity.id]!) ||
            !sameSqlRow(a, b) ||
            entity.revision != original.revision + 1 ||
            entity.updatedAt.compareTo(original.updatedAt) < 0 ||
            request['id'] != original.id ||
            request['revision'] != original.revision) {
          throw StateError('Record revision invalid');
        }
      }
      await RecordStore.referencesIn(
        db,
        entity.information,
        retained: entity.information,
        validatePersons: false,
      );
      last[entity.id] = after;
    }
    if (seen.length != ops.length) {
      throw StateError('Record operation missing history');
    }
    final rows = await db.query(records);
    if (rows.length != last.length) {
      throw StateError('Record missing history');
    }
    for (final row in rows) {
      final r = StoredRecord.fromRow(row);
      if (last[r.id] == null || !sameSqlRow(row, last[r.id]!)) {
        throw StateError('Record current/history mismatch');
      }
      await RecordStore.referencesIn(
        db,
        r.information,
        retained: r.information,
      );
    }
  }
}

class RecordStore {
  RecordStore(this.database, {DateTime Function()? clock, this.afterWrite})
    : clock = clock ?? DateTime.now;
  final Future<Database> Function() database;
  final DateTime Function() clock;
  final Future<void> Function()? afterWrite;
  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get changes => _changes.stream;

  /// Also invalidates names after returning from entity management.
  static void invalidateReads() => _changes.add(null);
  Future<RecordReadModel> readModel() async => (await database()).transaction(
    (tx) async => RecordReadModel(
      records: (await tx.query(
        RecordSchema.records,
        orderBy: 'created_at DESC,id',
      )).map(StoredRecord.fromRow),
      groups: (await tx.query(
        CatalogKind.group.table,
      )).map(CatalogEntity.fromRow),
      members: (await tx.query(
        IdentityKind.member.table,
      )).map((r) => IdentityEntity.fromRow(IdentityKind.member, r)),
      sizes: (await tx.query(
        CatalogKind.size.table,
      )).map(CatalogEntity.fromRow),
    ),
  );
  Future<List<StoredRecord>> list() async => (await (await database()).query(
    RecordSchema.records,
    orderBy: 'created_at DESC,id',
  )).map(StoredRecord.fromRow).toList();
  Future<List<Map<String, Object?>>> history(StoredRecord r) async =>
      (await database()).query(
        RecordSchema.history,
        where: 'record_id=?',
        whereArgs: [r.id],
        orderBy: 'id',
      );
  static Future<void> referencesIn(
    DatabaseExecutor tx,
    RecordInformation info, {
    RecordInformation? retained,
    bool validatePersons = true,
  }) async {
    if (validatePersons) {
      await IdentityStore.selectionIn(
        tx,
        info.memberIds ?? [],
        retainedIds: (retained?.memberIds ?? []).toSet(),
      );
    } else {
      for (final id in info.memberIds ?? <String>[]) {
        await IdentityStore.selectionIn(tx, [id], retainedIds: {id});
      }
    }
    if (info.sizeId != null) {
      final rows = await tx.query(
        CatalogKind.size.table,
        where: 'id=?',
        whereArgs: [info.sizeId],
      );
      if (rows.isEmpty ||
          (rows.single['active'] != 1 && info.sizeId != retained?.sizeId)) {
        throw const CatalogException('尺寸已变化，请重新选择');
      }
    }
    for (final s in info.toMap()['member_snapshots'] as List? ?? []) {
      final groupId = (s as Map)['group_id'];
      if (groupId != null &&
          (await tx.query(
            CatalogKind.group.table,
            where: 'id=?',
            whereArgs: [groupId],
          )).isEmpty) {
        throw const CatalogException('记录名称引用的团体不存在');
      }
    }
    if (info.toMap()['cost_reference'] != null) {
      throw const CatalogException('M1尚未接入券成本，请保留原档案并仅记录');
    }
  }

  Future<StoredRecord> save(
    RecordInformation info, {
    StoredRecord? original,
    required String operationId,
  }) async {
    if (operationId.trim().isEmpty) {
      throw const CatalogException('操作标识缺失');
    }
    final request = jsonEncode({
      'id': original?.id,
      'revision': original?.revision,
      'information_json': info.encode(),
    });
    final saved = await (await database()).transaction((tx) async {
      final existing = await tx.query(
        RecordSchema.operations,
        where: 'id=?',
        whereArgs: [operationId],
      );
      if (existing.isNotEmpty) {
        if (existing.single['request_json'] != request) {
          throw const CatalogException('操作已用于其他修改');
        }
        return StoredRecord.fromRow(
          decodeSqlRow(existing.single['result_json'] as String),
        );
      }
      for (final table in [
        CatalogSchema.operations,
        IdentitySchema.operations,
      ]) {
        if ((await tx.query(
          table,
          where: 'id=?',
          whereArgs: [operationId],
        )).isNotEmpty) {
          throw const CatalogException('操作已用于其他修改');
        }
      }
      Map<String, Object?>? before;
      if (original != null) {
        final r = await tx.query(
          RecordSchema.records,
          where: 'id=?',
          whereArgs: [original.id],
        );
        if (r.isEmpty || r.single['revision'] != original.revision) {
          throw const CatalogException('记录已修改，请重新打开');
        }
        before = r.single;
      }
      await referencesIn(
        tx,
        info,
        retained: before == null
            ? null
            : StoredRecord.fromRow(before).information,
      );
      final stamp = actionStamp(clock());
      if (before != null &&
          stamp.compareTo(before['updated_at'] as String) < 0) {
        throw const CatalogException('系统时间早于上次修改');
      }
      final row = before == null
          ? <String, Object?>{
              'id': newOperationId(),
              'information_json': info.encode(),
              'created_at': stamp,
              'updated_at': stamp,
              'revision': 1,
            }
          : {
              ...copySqlRow(before),
              'information_json': info.encode(),
              'updated_at': stamp,
              'revision': (before['revision'] as int) + 1,
            };
      if (before == null) {
        await tx.insert(RecordSchema.records, row);
        row.addAll(
          (await tx.query(
            RecordSchema.records,
            where: 'id=?',
            whereArgs: [row['id']],
          )).single,
        );
      } else {
        await tx.update(
          RecordSchema.records,
          {...row}..remove('id'),
          where: 'id=? AND revision=?',
          whereArgs: [original!.id, original.revision],
        );
      }
      final result = encodeSqlRow(row);
      await tx.insert(RecordSchema.operations, {
        'id': operationId,
        'record_id': row['id'],
        'request_json': request,
        'result_json': result,
        'created_at': stamp,
      });
      await tx.insert(RecordSchema.history, {
        'record_id': row['id'],
        'operation_id': operationId,
        'before_json': before == null ? null : encodeSqlRow(before),
        'after_json': result,
        'created_at': stamp,
      });
      if (afterWrite != null) await afterWrite!();
      return StoredRecord.fromRow(row);
    });
    invalidateReads();
    return saved;
  }
}
