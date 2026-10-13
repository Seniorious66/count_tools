import 'dart:convert';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import 'catalog_contract.dart';
import 'catalog_schema.dart';
import 'identity_schema.dart';

String newOperationId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class CatalogStore {
  CatalogStore(this.database, {DateTime Function()? clock, this.afterWrite})
    : clock = clock ?? DateTime.now;
  final Future<Database> Function() database;
  final DateTime Function() clock;
  final Future<void> Function()?
  afterWrite; // Fault injection; unset in application.

  Future<List<CatalogEntity>> list(
    CatalogKind kind, {
    bool includeInactive = true,
  }) async {
    final db = await database();
    return (await db.query(
      kind.table,
      where: includeInactive ? null : 'active=1',
      orderBy: 'created_at,id',
    )).map(CatalogEntity.fromRow).toList();
  }

  Future<List<Map<String, Object?>>> history(
    CatalogKind kind,
    String id,
  ) async => (await database()).query(
    CatalogSchema.history,
    where: 'kind=? AND entity_id=?',
    whereArgs: [kind.name, id],
    orderBy: 'id',
  );

  Future<CatalogEntity> create(
    CatalogKind kind, {
    required String name,
    required String operationId,
  }) => _write(kind, name: name, active: true, operationId: operationId);

  Future<CatalogEntity> edit(
    CatalogKind kind, {
    required CatalogEntity original,
    required String name,
    required bool active,
    required String operationId,
  }) => _write(
    kind,
    name: name,
    active: active,
    operationId: operationId,
    original: original,
  );

  Future<CatalogEntity> _write(
    CatalogKind kind, {
    required String name,
    required bool active,
    required String operationId,
    CatalogEntity? original,
  }) async {
    final cleaned = name.trim().isEmpty ? null : name.trim();
    if (operationId.trim().isEmpty) {
      throw const CatalogException('操作标识缺失，请重新打开表单');
    }
    final request = jsonEncode({
      'kind': kind.name,
      'action': original == null ? 'create' : 'edit',
      'id': original?.id,
      'revision': original?.revision,
      'name': cleaned,
      'active': active,
    });
    final db = await database();
    return db.transaction((tx) async {
      final oldOperation = await tx.query(
        CatalogSchema.operations,
        where: 'id=?',
        whereArgs: [operationId],
      );
      if (oldOperation.isNotEmpty) {
        if (oldOperation.single['request_json'] != request) {
          throw const CatalogException('此操作已用于其他修改，请重新核对');
        }
        return CatalogEntity.fromRow(
          decodeSqlRow(oldOperation.single['result_json'] as String),
        );
      }
      final identityTables = await tx.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [IdentitySchema.operations],
      );
      final recordTables = await tx.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cheki_record_operations'",
      );
      if (recordTables.isNotEmpty &&
          (await tx.query(
            'cheki_record_operations',
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('此操作已用于其他修改，请重新核对');
      }
      if (identityTables.isNotEmpty &&
          (await tx.query(
            IdentitySchema.operations,
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('此操作已用于其他修改，请重新核对');
      }
      if ((await tx.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='cheki_ticket_operations'",
          )).isNotEmpty &&
          (await tx.query(
            'cheki_ticket_operations',
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('操作已用于其他修改');
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
      if ((await tx.rawQuery(
            "SELECT name FROM sqlite_master WHERE name='cheki_entry_operations'",
          )).isNotEmpty &&
          (await tx.query(
            'cheki_entry_operations',
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('此操作标识已用于关联记录');
      }
      Map<String, Object?>? before;
      if (original != null) {
        final rows = await tx.query(
          kind.table,
          where: 'id=?',
          whereArgs: [original.id],
        );
        if (rows.isEmpty || rows.single['revision'] != original.revision) {
          throw const CatalogException('内容已被修改，请返回列表重新打开');
        }
        before = rows.single;
      }
      final stamp = actionStamp(clock());
      if (before != null &&
          stamp.compareTo(before['updated_at'] as String) < 0) {
        throw const CatalogException('系统时间早于上次修改，请校准后重试');
      }
      final row = before == null
          ? <String, Object?>{
              'id': newOperationId(),
              'name': cleaned,
              'active': 1,
              'created_at': stamp,
              'updated_at': stamp,
              'revision': 1,
              'source': 'user',
              'ext': null,
            }
          : {
              ...copySqlRow(before),
              'name': cleaned,
              'active': active ? 1 : 0,
              'updated_at': stamp,
              'revision': (before['revision'] as int) + 1,
            };
      if (before == null) {
        await tx.insert(
          kind.table,
          row,
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
        // Include defaults and unknown extension columns in the audited fact.
        final stored = (await tx.query(
          kind.table,
          where: 'id=?',
          whereArgs: [row['id']],
        )).single;
        row
          ..clear()
          ..addAll(copySqlRow(stored));
      } else {
        final fields = {...row}..remove('id');
        final changed = await tx.update(
          kind.table,
          fields,
          where: 'id=? AND revision=?',
          whereArgs: [original!.id, original.revision],
        );
        if (changed != 1) throw const CatalogException('内容已变化，请重新核对');
      }
      final result = encodeSqlRow(row);
      await tx.insert(CatalogSchema.operations, {
        'id': operationId,
        'kind': kind.name,
        'entity_id': row['id'],
        'request_json': request,
        'result_json': result,
        'created_at': stamp,
      });
      await tx.insert(CatalogSchema.history, {
        'kind': kind.name,
        'entity_id': row['id'],
        'operation_id': operationId,
        'before_json': before == null ? null : encodeSqlRow(before),
        'after_json': result,
        'created_at': stamp,
      });
      if (afterWrite != null) await afterWrite!();
      return CatalogEntity.fromRow(row);
    });
  }
}
