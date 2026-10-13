import 'package:sqflite/sqflite.dart';
import '../../cheki/data/catalog_schema.dart';
import '../../cheki/data/identity_schema.dart';
import '../../cheki/data/nullable_schema.dart';
import '../../cheki/data/record_store.dart';
import '../../cheki/data/ticket_store.dart';
import '../../cheki/data/entry_store.dart';
import '../../cheki/data/transfer_store.dart';

/// Storage versions are independent of product versions. Never rewrite legacy facts.
class StorageSchema {
  static const version = 8;
  static const migrations = {
    2: 'preserve_legacy_v1',
    3: 'catalog_base_v1',
    4: 'identity_base_v1',
    5: 'nullable_business_v1',
    6: 'ticket_inventory_v1',
    7: 'cheki_coupon_link_v1',
    8: 'coupon_transfer_lineage_v1',
  };
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
    if (schema >= 2) {
      final entries = await db.query(migrationTable, orderBy: 'version');
      final expected = migrations.entries
          .where((entry) => entry.key <= schema)
          .toList();
      if (entries.length != expected.length ||
          entries.indexed.any(
            (pair) =>
                pair.$2['version'] != expected[pair.$1].key ||
                pair.$2['migration'] != expected[pair.$1].value,
          )) {
        throw StateError('Storage migration ledger is invalid');
      }
    }
    if (schema >= 3) await CatalogSchema.validate(db);
    if (schema >= 4) await IdentitySchema.validate(db);
    if (schema >= 5) await RecordSchema.validate(db);
    if (schema >= 6) await TicketSchema.validate(db);
    if (schema >= 7) await EntrySchema.validate(db);
    if (schema >= 8) await TransferSchema.validate(db);
  }

  /// Called only by sqflite version callbacks, which already run in one transaction.
  static Future<void> migrate(
    DatabaseExecutor db,
    int oldVersion,
    int newVersion, {
    Future<void> Function()? afterStep,
  }) async {
    if (oldVersion < 1 || oldVersion >= newVersion || newVersion > version) {
      throw StateError('Unsupported migration path');
    }
    await validate(db, oldVersion);
    for (var step = oldVersion + 1; step <= newVersion; step++) {
      if (step == 2) {
        await db.execute(
          'CREATE TABLE $migrationTable ('
          'version INTEGER PRIMARY KEY, migration TEXT NOT NULL)',
        );
      } else if (step == 3) {
        await CatalogSchema.create(db);
      } else if (step == 4) {
        await IdentitySchema.create(db);
      } else if (step == 5) {
        await NullableSchema.migrate(db);
        await RecordSchema.create(db);
      } else if (step == 6) {
        await TicketSchema.create(db);
      } else if (step == 7) {
        await EntrySchema.create(db);
      } else if (step == 8) {
        await TransferSchema.create(db);
      }
      await db.insert(migrationTable, {
        'version': step,
        'migration': migrations[step],
      });
      if (afterStep != null) await afterStep();
      await validate(db, step);
    }
  }
}
