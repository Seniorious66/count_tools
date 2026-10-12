import 'package:sqflite/sqflite.dart';

/// Relaxes business fields only, preserving rows, audits and extension objects.
/// Run in the existing version transaction. Never disable foreign keys.
abstract final class NullableSchema {
  static const tables = [
    'cheki_groups',
    'cheki_sizes',
    'cheki_persons',
    'cheki_members',
  ];
  static String quote(String name) => '"${name.replaceAll('"', '""')}"';

  static Future<void> migrate(DatabaseExecutor db) async {
    final definitions = <String, String>{};
    final objects = <String>[];
    // Unknown external references must not be deleted or cascaded by rebuilding.
    for (final row in await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )) {
      final name = row['name'] as String;
      if (tables.contains(name)) continue;
      for (final fk in await db.rawQuery(
        'PRAGMA foreign_key_list(${quote(name)})',
      )) {
        if (tables.contains(fk['table'])) {
          throw StateError(
            'Unsupported external entity reference; original database retained',
          );
        }
      }
    }
    for (final table in tables) {
      final sql =
          (await db.rawQuery(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
                [table],
              )).single['sql']
              as String;
      const nameField = 'name TEXT NOT NULL CHECK(length(trim(name))>0)';
      if (!sql.contains(nameField)) {
        throw StateError('Unsupported entity definition');
      }
      var relaxed = sql.replaceFirst(nameField, 'name TEXT');
      if (table == 'cheki_members') {
        const groupField = 'group_id TEXT NOT NULL REFERENCES';
        const colorField =
            "color_rgb INTEGER NOT NULL CHECK(typeof(color_rgb)='integer' AND color_rgb BETWEEN 0 AND 16777215)";
        if (!relaxed.contains(groupField) || !relaxed.contains(colorField)) {
          throw StateError('Unsupported member definition');
        }
        relaxed = relaxed
            .replaceFirst(groupField, 'group_id TEXT REFERENCES')
            .replaceFirst(
              colorField,
              "color_rgb INTEGER CHECK(color_rgb IS NULL OR (typeof(color_rgb)='integer' AND color_rgb BETWEEN 0 AND 16777215))",
            );
      }
      definitions[table] = relaxed;
      objects.addAll(
        (await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE tbl_name=? AND type IN('index','trigger') AND sql IS NOT NULL ORDER BY type,name",
          [table],
        )).map((r) => r['sql'] as String),
      );
      final staging = quote('_nullable_$table');
      await db.execute(
        'CREATE TEMP TABLE $staging AS SELECT * FROM ${quote(table)}',
      );
    }
    // Child first, parents next. Audits are untouched and have no entity FKs.
    for (final table in tables.reversed) {
      await db.execute('DROP TABLE ${quote(table)}');
    }
    for (final table in tables) {
      await db.execute(definitions[table]!);
      final columns = (await db.rawQuery('PRAGMA table_info(${quote(table)})'))
          .where((r) => r['hidden'] == null || r['hidden'] == 0)
          .map((r) => quote(r['name'] as String))
          .join(',');
      await db.execute(
        'INSERT INTO ${quote(table)} ($columns) SELECT $columns FROM ${quote('_nullable_$table')}',
      );
      await db.execute('DROP TABLE ${quote('_nullable_$table')}');
    }
    // Restore triggers after copying; migration must not replay business actions.
    for (final sql in objects) {
      await db.execute(sql);
    }
  }
}
