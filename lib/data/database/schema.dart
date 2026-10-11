import 'package:sqflite/sqflite.dart';

/// Storage versions are independent of product versions. Never rewrite legacy facts.
class StorageSchema {
  static const version = 2;
  static const migrationTable = 'count_tools_migrations';
  static const columns = <String, List<String>>{
    'users': ['id', 'username', 'user_key', 'ext'],
    'project_data': ['id', 'title', 'subTitle', 'count', 'ext'],
    'sub_project_data': [
      'id',
      'name',
      'count',
      'countPre',
      'color',
      'textColor',
      'parentId',
      'ext',
    ],
    'item_data': [
      'id',
      'price',
      'eventName',
      'type',
      'date',
      'itemName',
      'parentId',
      'projectId',
      'ext',
    ],
  };

  static Future<void> validate(DatabaseExecutor db, int schema) async {
    if (schema < 1 || schema > version) {
      throw StateError('Unsupported storage version');
    }
    final integrity = await db.rawQuery('PRAGMA integrity_check');
    if (integrity.length != 1 || integrity.single.values.single != 'ok') {
      throw StateError('Database integrity check failed');
    }
    for (final entry in columns.entries) {
      final info = await db.rawQuery('PRAGMA table_info("${entry.key}")');
      final names = info.map((row) => row['name']).toSet();
      if (!names.containsAll(entry.value)) {
        throw StateError('Required storage columns missing');
      }
      final rows = await db.query(entry.key);
      for (final row in rows) {
        if (row['id'] is! int || (row['id'] as int) <= 0) {
          throw StateError('Invalid record ID');
        }
        for (final field in entry.value.where((name) => name != 'id')) {
          if (row[field] != null && row[field] is! String) {
            throw StateError('Invalid legacy field storage type');
          }
        }
        if (entry.key == 'project_data' || entry.key == 'sub_project_data') {
          final count = row['count'];
          if (count is! String || !RegExp(r'^\d+$').hasMatch(count)) {
            throw StateError('Invalid legacy count');
          }
        }
      }
    }
    const checks = [
      'SELECT COUNT(*) FROM sub_project_data s LEFT JOIN project_data p ON s.parentId=p.id WHERE p.id IS NULL',
      'SELECT COUNT(*) FROM item_data i LEFT JOIN sub_project_data s ON i.parentId=s.id LEFT JOIN project_data p ON i.projectId=p.id WHERE s.id IS NULL OR p.id IS NULL OR CAST(i.projectId AS TEXT) != CAST(s.parentId AS TEXT)',
      'SELECT COUNT(*) FROM sub_project_data s WHERE CAST(s.count AS INTEGER) != (SELECT COUNT(*) FROM item_data i WHERE i.parentId=s.id)',
      'SELECT COUNT(*) FROM project_data p WHERE CAST(p.count AS INTEGER) != (SELECT COUNT(*) FROM sub_project_data s WHERE s.parentId=p.id)',
    ];
    for (final sql in checks) {
      if (Sqflite.firstIntValue(await db.rawQuery(sql)) != 0) {
        throw StateError('Legacy relationships or counts are inconsistent');
      }
    }
    if (schema == 2) {
      final entries = await db.query(migrationTable);
      if (entries.length != 1 ||
          entries.single['version'] != 2 ||
          entries.single['migration'] != 'preserve_legacy_v1') {
        throw StateError('Storage migration ledger is invalid');
      }
    }
  }

  /// Called only by sqflite version callbacks, which already run in one transaction.
  static Future<void> migrate(
    DatabaseExecutor db,
    int oldVersion,
    int newVersion, {
    Future<void> Function()? afterStep,
  }) async {
    if (oldVersion != 1 || newVersion != 2) {
      throw StateError('Unsupported migration path');
    }
    await validate(db, oldVersion);
    await db.execute(
      'CREATE TABLE $migrationTable ('
      'version INTEGER PRIMARY KEY, migration TEXT NOT NULL)',
    );
    await db.insert(migrationTable, {
      'version': 2,
      'migration': 'preserve_legacy_v1',
    });
    if (afterStep != null) await afterStep();
    await validate(db, newVersion);
  }
}
