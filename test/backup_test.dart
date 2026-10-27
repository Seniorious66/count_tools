import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;

Future<void> fixture(
  Directory live, {
  int schema = StorageSchema.version,
}) async {
  await live.create(recursive: true);
  final path = '${live.path}/user_database.db';
  await legacyFixture(path);
  final db = await openDatabase(path, singleInstance: false);
  if (schema > 1) {
    await db.transaction((t) => StorageSchema.migrate(t, 1, schema));
  }
  await db.setVersion(schema);
  await db.execute(
    'CREATE TABLE future_values(id INTEGER PRIMARY KEY AUTOINCREMENT,raw BLOB,unknown TEXT)',
  );
  await db.insert('future_values', {
    'id': 97,
    'raw': Uint8List.fromList([0, 255, 1]),
    'unknown': null,
  });
  await db.execute('CREATE INDEX future_index ON future_values(unknown)');
  await db.close();
  await Directory('${live.path}/attachments').create();
  await File('${live.path}/attachments/原文.bin').writeAsBytes([0, 255, 254]);
}

Future<Map<String, Object?>> contents(Directory live) async {
  final db = await openDatabase(
    '${live.path}/user_database.db',
    readOnly: true,
    singleInstance: false,
  );
  try {
    return {
      for (final r in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      ))
        r['name'] as String: await db.query(r['name'] as String),
    };
  } finally {
    await db.close();
  }
}

Uint8List modified(
  Uint8List bytes,
  void Function(Map<String, dynamic>) change,
) {
  final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      payload =
          jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
  change(payload);
  envelope['payload'] = jsonEncode(payload);
  envelope['checksum'] = sha256
      .convert(utf8.encode(envelope['payload'] as String))
      .toString();
  return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  final processRoot = Platform.environment['CHEKI_BACKUP_PROCESS_ROOT'];
  if (processRoot != null) {
    test('independent process journal recovery', () async {
      final base = Directory(processRoot),
          live = Directory('$processRoot/live'),
          settingsFile = File('$processRoot/settings.json');
      final phase = Platform.environment['CHEKI_BACKUP_CRASH_PHASE'];
      Future<Map<String, Object?>> read() async => Map<String, Object?>.from(
        jsonDecode(await settingsFile.readAsString()) as Map,
      );
      Future<void> write(Map<String, Object?> s) =>
          settingsFile.writeAsString(jsonEncode(s), flush: true);
      final store = BackupStore(
        documents: live,
        readSettings: read,
        writeSettings: write,
        closeMain: () async {},
        fault: (s) async {
          if (s == phase) {
            await File(
              '$processRoot/crash-phase',
            ).writeAsString(s, flush: true);
            exit(71);
          }
        },
      );
      if (phase != null) {
        expect(await base.exists(), false);
        await base.create(recursive: true);
        await fixture(live);
        await write({'state': 'before', 'isNotFirstEnter': true});
        final backup = await store.snapshot();
        await File('$processRoot/backup').writeAsBytes(backup);
        await write({'state': 'after', 'isNotFirstEnter': true});
        await File('${live.path}/attachments/current').writeAsString('current');
        final p = await store.prepare(backup);
        await store.apply(p);
        fail('Crash phase not reached');
      } else {
        await store.recoverPending();
        final opened = await openDatabase(
          '${live.path}/user_database.db',
          readOnly: true,
          singleInstance: false,
        );
        await StorageSchema.validate(opened, StorageSchema.version);
        await opened.close();
        final committed =
            Platform.environment['CHEKI_BACKUP_EXPECT_COMMITTED'] == '1';
        expect((await read())['state'], committed ? 'before' : 'after');
        expect(
          await File('${live.path}/attachments/current').exists(),
          !committed,
        );
        expect(await store.journal.exists(), false);
      }
    });
    return;
  }
  late Directory base, live;
  late Map<String, Object?> settings;
  late BackupStore store;
  setUp(() async {
    base = await Directory.systemTemp.createTemp('cheki-backup-');
    live = Directory('${base.path}/live');
    await fixture(live);
    settings = {
      'isNotFirstEnter': true,
      'unknown': ['原文'],
      'scale': 1.5,
      'flag': false,
      'count': 7,
    };
    store = BackupStore(
      documents: live,
      readSettings: () async => Map.from(settings),
      writeSettings: (s) async {
        settings = Map.from(s);
      },
      closeMain: () async {},
    );
  });
  tearDown(() async {
    await base.delete(recursive: true);
  });
  test(
    'complete backup preserves SQLite objects BLOB NULL sequence settings attachments and rebackup',
    () async {
      final original = await contents(live),
          oldSettings = Map.of(settings),
          backup = await store.snapshot();
      settings = {'changed': true};
      await File('${live.path}/attachments/new.bin').writeAsBytes([4]);
      final preview = await store.prepare(backup);
      expect(settings, {'changed': true});
      expect(preview.before['files'], 3);
      expect(preview.after['files'], 2);
      await store.apply(preview);
      expect(await contents(live), original);
      expect(settings, oldSettings);
      expect(await File('${live.path}/attachments/new.bin').exists(), false);
      expect(await File('${live.path}/attachments/原文.bin').readAsBytes(), [
        0,
        255,
        254,
      ]);
      final generations = await store.recovery.list().toList();
      expect(
        generations.whereType<Directory>().any(
          (d) => d.path.contains('previous-'),
        ),
        true,
      );
      final repeated = await store.prepare(await store.snapshot());
      await store.apply(repeated);
      expect(await contents(live), original);
    },
  );
  test(
    'schema1 through7 isolated migration preserves all original facts and sequences',
    () async {
      for (final schema in [1, 2, 3, 4, 5, 6, 7]) {
        final source = Directory('${base.path}/old$schema');
        await fixture(source, schema: schema);
        final old = BackupStore(
          documents: source,
          readSettings: () async => settings,
          writeSettings: (s) async {},
          closeMain: () async {},
        );
        final before = await contents(source),
            preview = await store.prepare(await old.snapshot());
        expect(preview.sourceSchema, schema);
        expect(await contents(source), before);
        await store.apply(preview);
        final restored = await contents(live);
        for (final k in before.keys.where(
          (k) => k != 'count_tools_migrations' && k != 'sqlite_sequence',
        )) {
          expect(restored[k], before[k], reason: 'schema $schema $k');
        }
        expect((restored['future_values'] as List).single['id'], 97);
      }
    },
  );
  test(
    'corrupt checksum path traversal duplicate filenames and missing DB rejected before current replacement',
    () async {
      final backup = await store.snapshot(), before = await contents(live);
      final bad = jsonDecode(utf8.decode(backup)) as Map;
      bad['checksum'] = 'bad';
      for (final bytes in [
        Uint8List.fromList(utf8.encode(jsonEncode(bad))),
        modified(backup, (p) {
          (p['files'] as Map)['../outside'] = 'AA==';
        }),
        modified(backup, (p) {
          (p['files'] as Map)['USER_DATABASE.DB'] =
              (p['files'] as Map)['user_database.db'];
        }),
        modified(backup, (p) {
          (p['files'] as Map).remove('user_database.db');
        }),
        modified(backup, (p) {
          p['schema'] = 99;
        }),
      ]) {
        await expectLater(store.prepare(bytes), throwsA(anything));
        expect(await contents(live), before);
      }
    },
  );
  test(
    'schema future or invalid old relationships cannot be restored',
    () async {
      final backup = await store.snapshot();
      for (final sql in [
        'PRAGMA user_version=99',
        "UPDATE item_data SET projectId='99999'",
      ]) {
        final temp = File('${base.path}/bad.db'),
            raw =
                jsonDecode(
                      (jsonDecode(utf8.decode(backup)) as Map)['payload']
                          as String,
                    )
                    as Map;
        await temp.writeAsBytes(
          base64Decode((raw['files'] as Map)['user_database.db'] as String),
        );
        final db = await openDatabase(temp.path, singleInstance: false);
        await db.execute(sql);
        await db.close();
        final bytes = modified(backup, (p) {
          (p['files'] as Map)['user_database.db'] = base64Encode(
            temp.readAsBytesSync(),
          );
        });
        await expectLater(store.prepare(bytes), throwsA(anything));
      }
    },
  );
  test(
    'stale current attachment or settings and tampered staged generation refused',
    () async {
      final backup = await store.snapshot(), p = await store.prepare(backup);
      settings['extra'] = 'current';
      await expectLater(store.apply(p), throwsA(anything));
      expect(settings['extra'], 'current');
      final fresh = await store.prepare(backup);
      await File('${fresh.folder.path}/attachments/原文.bin').writeAsBytes([9]);
      await expectLater(store.apply(fresh), throwsA(anything));
      expect(settings['extra'], 'current');
    },
  );
  for (final phase in ['old-moved', 'new-installed', 'settings-written']) {
    test('$phase fault rolls back complete generation and settings', () async {
      final backup = await store.snapshot();
      settings = {'current': true};
      await File('${live.path}/attachments/current').writeAsString('now');
      final before = await contents(live), p = await store.prepare(backup);
      final failing = BackupStore(
        documents: live,
        readSettings: () async => settings,
        writeSettings: (s) async {
          settings = Map.from(s);
        },
        closeMain: () async {},
        fault: (s) async {
          if (s == phase) throw StateError('fault');
        },
      );
      await expectLater(failing.apply(p), throwsStateError);
      expect(settings, {'current': true});
      expect(await contents(live), before);
      expect(
        await File('${live.path}/attachments/current').readAsString(),
        'now',
      );
      expect(await store.journal.exists(), false);
    });
  }
  test(
    'failed settings rollback remains fail-closed until cold recovery succeeds',
    () async {
      final backup = await store.snapshot();
      settings = {'current': true};
      final p = await store.prepare(backup);
      var maintenance = false;
      final failing = BackupStore(
        documents: live,
        readSettings: () async => settings,
        writeSettings: (s) async {
          throw StateError('settings unavailable');
        },
        closeMain: () async {},
        maintenance: (v) => maintenance = v,
      );
      await expectLater(failing.apply(p), throwsStateError);
      expect(await store.journal.exists(), true);
      expect(maintenance, true);
      await store.recoverPending();
      expect(settings, {'current': true});
      expect(await store.journal.exists(), false);
    },
  );
  test('WAL committed rows survive closed full snapshot', () async {
    final db = await openDatabase(
      '${live.path}/user_database.db',
      singleInstance: false,
    );
    await db.execute('PRAGMA journal_mode=WAL');
    await db.insert('future_values', {
      'raw': Uint8List.fromList([7]),
      'unknown': 'WAL',
    });
    final closing = BackupStore(
      documents: live,
      readSettings: () async => settings,
      writeSettings: (s) async {
        settings = Map.from(s);
      },
      closeMain: db.close,
    );
    final backup = await closing.snapshot(), p = await store.prepare(backup);
    await store.apply(p);
    expect((await contents(live))['future_values'], hasLength(2));
  });
  test(
    'duplicate envelope or payload keys are refused instead of discarding facts',
    () async {
      final backup = await store.snapshot(), text = utf8.decode(backup);
      await expectLater(
        store.prepare(
          Uint8List.fromList(
            utf8.encode(
              text.replaceFirst('"format":', '"format":"wrong","format":'),
            ),
          ),
        ),
        throwsFormatException,
      );
      final e = jsonDecode(text) as Map;
      e['payload'] = (e['payload'] as String).replaceFirst(
        '"settings":',
        '"settings":{},"settings":',
      );
      e['checksum'] = sha256
          .convert(utf8.encode(e['payload'] as String))
          .toString();
      await expectLater(
        store.prepare(Uint8List.fromList(utf8.encode(jsonEncode(e)))),
        throwsFormatException,
      );
    },
  );
}
