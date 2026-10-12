import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'catalog_contract.dart';

abstract final class CatalogSchema {
  static const operations = 'cheki_catalog_operations';
  static const history = 'cheki_catalog_history';
  static const entityColumns = [
    'id',
    'name',
    'active',
    'created_at',
    'updated_at',
    'revision',
    'source',
    'ext',
  ];
  static const operationColumns = [
    'id',
    'kind',
    'entity_id',
    'request_json',
    'result_json',
    'created_at',
  ];
  static const historyColumns = [
    'id',
    'kind',
    'entity_id',
    'operation_id',
    'before_json',
    'after_json',
    'created_at',
  ];
  static const defaultSizes = {'size-3inch': '三寸', 'size-5inch': '五寸'};

  static Future<void> create(DatabaseExecutor db) async {
    for (final kind in CatalogKind.values) {
      await db.execute(
        'CREATE TABLE ${kind.table} ('
        'id TEXT PRIMARY KEY NOT NULL CHECK(length(trim(id))>0), '
        'name TEXT NOT NULL CHECK(length(trim(name))>0), '
        'active INTEGER NOT NULL CHECK(active IN(0,1)), '
        'created_at TEXT NOT NULL,updated_at TEXT NOT NULL, '
        'revision INTEGER NOT NULL CHECK(revision>0), '
        "source TEXT NOT NULL CHECK(source IN('default','user')),ext TEXT)",
      );
    }
    await db.execute(
      'CREATE TABLE $operations ('
      'id TEXT PRIMARY KEY NOT NULL CHECK(length(trim(id))>0),'
      "kind TEXT NOT NULL CHECK(kind IN('group','size')),entity_id TEXT NOT NULL,"
      'request_json TEXT NOT NULL,result_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE $history ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      "kind TEXT NOT NULL CHECK(kind IN('group','size')),entity_id TEXT NOT NULL,"
      'operation_id TEXT NOT NULL UNIQUE REFERENCES $operations(id) ON DELETE RESTRICT,'
      'before_json TEXT,after_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX cheki_catalog_entity_history ON $history(kind,entity_id,id)',
    );
    final stamp = actionStamp(DateTime.now());
    for (final entry in defaultSizes.entries) {
      await db.insert(CatalogKind.size.table, {
        'id': entry.key,
        'name': entry.value,
        'active': 1,
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 1,
        'source': 'default',
        'ext': null,
      });
    }
  }

  static Future<void> validate(DatabaseExecutor db) async {
    final expected = {
      for (final kind in CatalogKind.values) kind.table: entityColumns,
      operations: operationColumns,
      history: historyColumns,
    };
    for (final entry in expected.entries) {
      final columns = (await db.rawQuery(
        'PRAGMA table_info("${entry.key}")',
      )).map((r) => r['name']).toSet();
      if (!columns.containsAll(entry.value)) {
        throw StateError('Catalog columns missing');
      }
    }
    if ((await db.rawQuery('PRAGMA foreign_key_check($history)')).isNotEmpty) {
      throw StateError('Catalog foreign key violation');
    }
    final operationRows = await db.query(operations);
    final operationMap = {for (final row in operationRows) row['id']: row};
    final historyRows = await db.query(history, orderBy: 'id');
    final linked = <Object?>{};
    final last = <String, Map<String, Object?>>{};
    for (final row in historyRows) {
      final kind = row['kind'];
      final entityId = row['entity_id'];
      final operation = operationMap[row['operation_id']];
      if (!CatalogKind.values.any((k) => k.name == kind) ||
          row['id'] is! int ||
          (row['id'] as int) <= 0 ||
          operation == null ||
          operation['kind'] != kind ||
          operation['entity_id'] != entityId ||
          operation['id'] is! String ||
          (operation['id'] as String).trim().isEmpty ||
          !linked.add(operation['id']) ||
          !isActionStamp(row['created_at']) ||
          operation['created_at'] != row['created_at']) {
        throw StateError('Catalog operation/history relationship invalid');
      }
      try {
        final request = jsonDecode(operation['request_json'] as String) as Map;
        final after = decodeSqlRow(row['after_json'] as String);
        final entity = CatalogEntity.fromRow(after);
        final result = decodeSqlRow(operation['result_json'] as String);
        final before = row['before_json'] == null
            ? null
            : decodeSqlRow(row['before_json'] as String);
        final key = '$kind:$entityId';
        final previous = last[key];
        if (request['kind'] != kind ||
            request['name'] != entity.knownName ||
            request['active'] != entity.active ||
            entity.id != entityId ||
            !sameSqlRow(after, result) ||
            entity.updatedAt != row['created_at'] ||
            (before == null &&
                (previous != null ||
                    entity.revision != 1 ||
                    after['source'] != 'user' ||
                    entity.createdAt != entity.updatedAt ||
                    request['action'] != 'create' ||
                    request['id'] != null ||
                    request['revision'] != null)) ||
            (before != null &&
                (CatalogEntity.fromRow(before).id != entityId ||
                    entity.revision != (before['revision'] as int) + 1 ||
                    entity.createdAt != before['created_at'] ||
                    after['source'] != before['source'] ||
                    request['action'] != 'edit' ||
                    request['id'] != entity.id ||
                    request['revision'] != before['revision'] ||
                    entity.updatedAt.compareTo(before['updated_at'] as String) <
                        0 ||
                    (previous != null && !sameSqlRow(before, previous))))) {
          throw StateError('Catalog audit chain invalid');
        }
        if (previous == null &&
            before != null &&
            !(kind == 'size' &&
                before['source'] == 'default' &&
                before['revision'] == 1 &&
                defaultSizes[entityId] == before['name'] &&
                before['active'] == 1 &&
                before['created_at'] == before['updated_at'])) {
          throw StateError('Catalog history has no starting fact');
        }
        if (before != null) {
          final preservedBefore = copySqlRow(before)
            ..removeWhere(
              (key, _) =>
                  ['name', 'active', 'updated_at', 'revision'].contains(key),
            );
          final preservedAfter = copySqlRow(after)
            ..removeWhere(
              (key, _) =>
                  ['name', 'active', 'updated_at', 'revision'].contains(key),
            );
          if (!sameSqlRow(preservedBefore, preservedAfter)) {
            throw StateError('Catalog immutable or unknown field changed');
          }
        }
        last[key] = after;
      } on FormatException {
        throw StateError('Catalog audit JSON invalid');
      } on TypeError {
        throw StateError('Catalog audit JSON shape invalid');
      }
    }
    if (linked.length != operationRows.length) {
      throw StateError('Catalog operation without history');
    }
    final found = <String>{};
    for (final kind in CatalogKind.values) {
      final rows = await db.query(kind.table);
      for (final row in rows) {
        final entity = CatalogEntity.fromRow(row);
        final isDefault =
            kind == CatalogKind.size && defaultSizes.containsKey(entity.id);
        if ((row['source'] == 'default') != isDefault) {
          throw StateError('Catalog default identity invalid');
        }
        final key = '${kind.name}:${entity.id}';
        found.add(key);
        final audited = last[key];
        if (audited == null) {
          if (!(kind == CatalogKind.size &&
              row['source'] == 'default' &&
              entity.revision == 1 &&
              defaultSizes[entity.id] == entity.name &&
              entity.active &&
              entity.createdAt == entity.updatedAt)) {
            throw StateError('Catalog entity missing history');
          }
        } else if (!sameSqlRow(row, audited)) {
          throw StateError('Catalog current row differs from history');
        }
      }
    }
    if (!found.containsAll(last.keys)) {
      throw StateError('Catalog history references missing entity');
    }
    for (final id in defaultSizes.keys) {
      if (!found.contains('size:$id')) throw StateError('Default size missing');
    }
  }
}
