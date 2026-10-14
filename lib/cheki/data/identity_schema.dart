import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'catalog_contract.dart';
import 'catalog_schema.dart';
import 'identity_contract.dart';

abstract final class IdentitySchema {
  static const operations = 'cheki_identity_operations';
  static const history = 'cheki_identity_history';
  static const memberColumns = [
    ...CatalogSchema.entityColumns,
    'group_id',
    'person_id',
    'color_rgb',
  ];
  static Set<String> mutableFields(IdentityKind kind) => {
    'name',
    'active',
    if (kind == IdentityKind.member) ...['person_id', 'color_rgb'],
  };

  static Future<void> create(DatabaseExecutor db) async {
    for (final kind in IdentityKind.values) {
      await db.execute(
        'CREATE TABLE ${kind.table} ('
        'id TEXT PRIMARY KEY NOT NULL CHECK(length(trim(id))>0),'
        'name TEXT NOT NULL CHECK(length(trim(name))>0),'
        'active INTEGER NOT NULL CHECK(active IN(0,1)),'
        'created_at TEXT NOT NULL,updated_at TEXT NOT NULL,'
        'revision INTEGER NOT NULL CHECK(revision>0),'
        "source TEXT NOT NULL CHECK(source='user'),ext TEXT"
        '${kind == IdentityKind.member ? ',group_id TEXT NOT NULL REFERENCES cheki_groups(id) ON DELETE RESTRICT,person_id TEXT REFERENCES cheki_persons(id) ON DELETE RESTRICT,color_rgb INTEGER NOT NULL CHECK(typeof(color_rgb)=\'integer\' AND color_rgb BETWEEN 0 AND 16777215)' : ''})',
      );
    }
    await db.execute(
      'CREATE TABLE $operations ('
      'id TEXT PRIMARY KEY NOT NULL CHECK(length(trim(id))>0),'
      "kind TEXT NOT NULL CHECK(kind IN('person','member')),entity_id TEXT NOT NULL,"
      'request_json TEXT NOT NULL,result_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE $history ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      "kind TEXT NOT NULL CHECK(kind IN('person','member')),entity_id TEXT NOT NULL,"
      'operation_id TEXT NOT NULL UNIQUE REFERENCES $operations(id) ON DELETE RESTRICT,'
      'before_json TEXT,after_json TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE INDEX cheki_member_group ON cheki_members(group_id,active,id)',
    );
    await db.execute(
      'CREATE INDEX cheki_member_person ON cheki_members(person_id,id)',
    );
    await db.execute(
      'CREATE INDEX cheki_identity_entity_history ON $history(kind,entity_id,id)',
    );
  }

  static Future<void> validate(DatabaseExecutor db) async {
    final expected = {
      IdentityKind.person.table: CatalogSchema.entityColumns,
      IdentityKind.member.table: memberColumns,
      operations: CatalogSchema.operationColumns,
      history: CatalogSchema.historyColumns,
    };
    for (final entry in expected.entries) {
      final columns = (await db.rawQuery(
        'PRAGMA table_info("${entry.key}")',
      )).map((r) => r['name']).toSet();
      if (!columns.containsAll(entry.value)) {
        throw StateError('Identity columns missing');
      }
      if ((await db.rawQuery(
        'PRAGMA foreign_key_check("${entry.key}")',
      )).isNotEmpty) {
        throw StateError('Identity foreign key violation');
      }
    }
    final groupIds = (await db.query(
      CatalogKind.group.table,
    )).map((r) => r['id']).toSet();
    final personIds = (await db.query(
      IdentityKind.person.table,
    )).map((r) => r['id']).toSet();
    void references(Map<String, Object?> row) {
      if ((row['group_id'] != null && !groupIds.contains(row['group_id'])) ||
          (row['person_id'] != null && !personIds.contains(row['person_id']))) {
        throw StateError('Member relationship invalid');
      }
    }

    final operationRows = await db.query(operations);
    final opMap = {for (final row in operationRows) row['id']: row};
    if (opMap.length != operationRows.length) {
      throw StateError('Duplicate identity operation');
    }
    final catalogOpIds = (await db.query(
      CatalogSchema.operations,
      columns: ['id'],
    )).map((r) => r['id']).toSet();
    if (opMap.keys.any(catalogOpIds.contains)) {
      throw StateError('Operation ID reused across services');
    }
    final linked = <Object?>{};
    final last = <String, Map<String, Object?>>{};
    for (final h in await db.query(history, orderBy: 'id')) {
      try {
        final kind = IdentityKind.values.singleWhere(
          (k) => k.name == h['kind'],
        );
        final op = opMap[h['operation_id']];
        if (h['id'] is! int ||
            (h['id'] as int) <= 0 ||
            op == null ||
            op['id'] is! String ||
            (op['id'] as String).trim().isEmpty ||
            !linked.add(op['id']) ||
            op['kind'] != kind.name ||
            op['entity_id'] != h['entity_id'] ||
            op['created_at'] != h['created_at'] ||
            !isActionStamp(h['created_at'])) {
          throw StateError('Identity history relationship invalid');
        }
        final request = jsonDecode(op['request_json'] as String) as Map;
        final fields = (request['fields'] as Map).cast<String, Object?>();
        if (request.containsKey('color_fallback_cleared') &&
            (request['color_fallback_cleared'] != true ||
                kind != IdentityKind.member ||
                request['action'] != 'edit' ||
                fields['color_rgb'] != null)) {
          throw StateError('Invalid explicit color clear');
        }
        if (request.containsKey('inherited_color_rgb') &&
            (request['inherited_color_rgb'] is! int ||
                (request['inherited_color_rgb'] as int) < 0 ||
                (request['inherited_color_rgb'] as int) > 0xffffff ||
                kind != IdentityKind.member ||
                request['transfer'] is! Map ||
                fields['color_rgb'] != null)) {
          throw StateError('Invalid inherited color snapshot');
        }
        final after = decodeSqlRow(h['after_json'] as String);
        final entity = IdentityEntity.fromRow(kind, after);
        final result = decodeSqlRow(op['result_json'] as String);
        final before = h['before_json'] == null
            ? null
            : decodeSqlRow(h['before_json'] as String);
        if (request.containsKey('group_correction') &&
            (request['group_correction'] != true ||
                kind != IdentityKind.member ||
                request['action'] != 'edit' ||
                before == null ||
                request['transfer'] != null ||
                !fields.containsKey('group_id') ||
                before['group_id'] == after['group_id'])) {
          throw StateError('Invalid group correction');
        }
        final key = '${kind.name}:${entity.id}';
        final previous = last[key];
        final allowed = {
          ...mutableFields(kind),
          if (kind == IdentityKind.member &&
              (before == null || fields.containsKey('group_id')))
            'group_id',
        };
        if (fields['active'] is! int ||
            (kind == IdentityKind.member &&
                fields['color_rgb'] != null &&
                fields['color_rgb'] is! int)) {
          throw StateError('Identity request field type invalid');
        }
        if (request['kind'] != kind.name ||
            entity.id != h['entity_id'] ||
            !sameSqlRow(after, result) ||
            entity.updatedAt != h['created_at'] ||
            fields.keys.toSet().length != allowed.length ||
            !fields.keys.toSet().containsAll(allowed) ||
            fields.entries.any((entry) => after[entry.key] != entry.value)) {
          throw StateError('Identity request/result mismatch');
        }
        if (kind == IdentityKind.member) references(after);
        if (before == null) {
          if (previous != null ||
              entity.revision != 1 ||
              entity.createdAt != entity.updatedAt ||
              request['action'] != 'create' ||
              request['id'] != null ||
              request['revision'] != null) {
            throw StateError('Identity creation history invalid');
          }
          if (request['transfer'] != null) {
            final transfer = request['transfer'] as Map;
            if (transfer.keys.toSet().length != 2 ||
                !transfer.keys.toSet().containsAll(['id', 'revision']) ||
                transfer['id'] is! String ||
                transfer['revision'] is! int) {
              throw StateError('Transfer request shape invalid');
            }
            final source = last['member:${transfer['id']}'];
            if (kind != IdentityKind.member ||
                source == null ||
                source['person_id'] == null ||
                source['revision'] != transfer['revision'] ||
                source['group_id'] == after['group_id'] ||
                source['person_id'] != after['person_id'] ||
                source['color_rgb'] != after['color_rgb'] ||
                (source['updated_at'] as String).compareTo(entity.updatedAt) >
                    0) {
              throw StateError('Transfer starting fact invalid');
            }
          }
        } else {
          IdentityEntity.fromRow(kind, before);
          final changed = {...mutableFields(kind), 'updated_at', 'revision'};
          if (kind == IdentityKind.member && fields.containsKey('group_id')) {
            if (request['group_correction'] != true &&
                (before['group_id'] != null || after['group_id'] == null)) {
              throw StateError('Only unknown group may be completed in place');
            }
            changed.add('group_id');
          }
          final a = copySqlRow(before)
            ..removeWhere((key, _) => changed.contains(key));
          final b = copySqlRow(after)
            ..removeWhere((key, _) => changed.contains(key));
          if (previous == null ||
              !sameSqlRow(before, previous) ||
              !sameSqlRow(a, b) ||
              entity.revision != (before['revision'] as int) + 1 ||
              entity.updatedAt.compareTo(before['updated_at'] as String) < 0 ||
              request['action'] != 'edit' ||
              request['id'] != entity.id ||
              request['revision'] is! int ||
              request['revision'] != before['revision'] ||
              request['transfer'] != null) {
            throw StateError('Identity revision chain invalid');
          }
          if (kind == IdentityKind.member) references(before);
        }
        last[key] = after;
      } on FormatException {
        throw StateError('Identity audit JSON invalid');
      } on TypeError {
        throw StateError('Identity audit shape invalid');
      }
    }
    if (linked.length != operationRows.length) {
      throw StateError('Identity operation without history');
    }
    final found = <String>{};
    for (final kind in IdentityKind.values) {
      for (final row in await db.query(kind.table)) {
        final entity = IdentityEntity.fromRow(kind, row);
        if (kind == IdentityKind.member) references(row);
        final key = '${kind.name}:${entity.id}';
        found.add(key);
        if (last[key] == null || !sameSqlRow(row, last[key]!)) {
          throw StateError('Identity current/history mismatch');
        }
      }
    }
    if (!found.containsAll(last.keys)) {
      throw StateError('Identity history references missing entity');
    }
  }
}
