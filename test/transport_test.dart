import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/transport_codec.dart';
import 'package:count_tools/cheki/data/transport_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'bi_fixture.dart';
import 'backup_test.dart' show contents;

Future<Map<String, Object?>> state(Directory dir) async {
  final result = await contents(dir);
  // sqlite_sequence is a keyed set; insertion order is not a history fact.
  final sequence = List.of(result['sqlite_sequence'] as List)
    ..sort(
      (dynamic a, dynamic b) =>
          (a['name'] as String).compareTo(b['name'] as String),
    );
  result['sqlite_sequence'] = sequence;
  return result;
}

Uint8List editPack(
  Uint8List bytes,
  void Function(Map<String, Uint8List>, Map<String, dynamic>) edit,
) {
  final files = TransportZip.decode(bytes),
      manifest =
          jsonDecode(utf8.decode(files['manifest.json']!))
              as Map<String, dynamic>;
  edit(files, manifest);
  files['manifest.json'] = Uint8List.fromList(
    utf8.encode(jsonEncode(manifest)),
  );
  return TransportZip.encode(files);
}

void editTable(
  Map<String, Uint8List> files,
  Map<String, dynamic> manifest,
  String name,
  void Function(List<List<String>>) edit,
) {
  final file =
          (manifest['tables'] as List).cast<Map>().singleWhere(
                (t) => t['name'] == name,
              )['file']
              as String,
      rows = TransportCsv.decode(utf8.decode(files[file]!));
  edit(rows);
  files[file] = Uint8List.fromList(utf8.encode(TransportCsv.encode(rows)));
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late BiFixture f;
  late BackupStore backups;
  late TransportStore store;
  late Map<String, Object?> settings;
  String? fault;
  setUp(() async {
    f = BiFixture();
    await f.open();
    settings = {
      '原文': '{"NULL":null,"missing":{}}',
      'list': <String>['=原文', '中文'],
    };
    fault = null;
    backups = BackupStore(
      documents: f.root,
      readSettings: () async => Map.of(settings),
      writeSettings: (v) async {
        settings = Map.of(v);
      },
      closeMain: DatabaseHelper().close,
      fault: (phase) async {
        if (phase == fault) throw StateError('injected');
      },
    );
    store = TransportStore(backups);
  });
  tearDown(() async {
    final recovery = backups.recovery;
    await f.close();
    if (await recovery.exists()) await recovery.delete(recursive: true);
  });
  test(
    'CSV round trip keeps unicode multiline quotes formula text and empty cells',
    () {
      final input = [
        ['null', '"=公式"', '"中文,\n"引号""', '', '-1', '"001"'],
        ['a', 'b', 'c', 'd', 'e', 'f'],
      ];
      expect(TransportCsv.decode(TransportCsv.encode(input)), input);
      expect(() => TransportCsv.decode('"broken'), throwsFormatException);
      expect(() => TransportCsv.decode('"x"tail'), throwsFormatException);
    },
  );
  test('ZIP external corruption duplicate case and traversal refused', () {
    final data = TransportZip.encode({'中文/a.csv': utf8.encode('原文')});
    expect(utf8.decode(TransportZip.decode(data)['中文/a.csv']!), '原文');
    final corrupt = Uint8List.fromList(data);
    corrupt[42] ^= 1;
    expect(() => TransportZip.decode(corrupt), throwsA(anything));
    expect(
      () => TransportZip.encode({
        '../file': [1],
      }),
      throwsFormatException,
    );
    expect(
      () => TransportZip.decode(
        TransportZip.encode({
          'A': [1],
          'a': [2],
        }),
      ),
      throwsFormatException,
    );
  });
  test(
    'duplicate JSON manifest keys and source checksum corruption are rejected',
    () async {
      final bytes = await store.export(),
          files = TransportZip.decode(bytes),
          before = await state(f.root);
      final text = utf8.decode(files['manifest.json']!);
      files['manifest.json'] = Uint8List.fromList(
        utf8.encode('{"version":1,${text.substring(1)}'),
      );
      await expectLater(
        store.prepare(TransportZip.encode(files), TransportMode.snapshot),
        throwsFormatException,
      );
      final damaged = TransportZip.decode(bytes),
          seed = jsonDecode(utf8.decode(damaged['seed.chekibackup']!)) as Map;
      seed['checksum'] = 'wrong';
      damaged['seed.chekibackup'] = Uint8List.fromList(
        utf8.encode(jsonEncode(seed)),
      );
      await expectLater(
        store.prepare(TransportZip.encode(damaged), TransportMode.snapshot),
        throwsFormatException,
      );
      expect(await state(f.root), before);
    },
  );
  test(
    'standard deflate ZIP independently repacked by Python preserves complete state',
    () async {
      final root = Platform.environment['CHEKI_TRANSPORT_REPACK'];
      late Uint8List pack;
      Map<String, Object?>? before;
      if (root != null) {
        expect(
          await File('$root/.transport-synthetic').readAsString(),
          'count_tools',
        );
        pack = await File('$root/deflated.chekicsv.zip').readAsBytes();
      } else {
        // Always run the cross-runtime regression. No stale external fixture or
        // environment switch is required for the ordinary full-suite command.
        await f.quantities();
        await f.finances(unknown: true);
        await f.records.save(
          RecordInformation.fromMap({}),
          operationId: 'deflate-empty',
        );
        final db = await f.records.database();
        await db.execute(
          'CREATE TABLE unknown_future(id INTEGER PRIMARY KEY, raw BLOB)',
        );
        await db.insert('unknown_future', {
          'id': 1,
          'raw': Uint8List.fromList([0, 255]),
        });
        before = await state(f.root);
        final scratch = await Directory.systemTemp.createTemp(
          'cheki-python-deflate-',
        );
        try {
          final source = '${scratch.path}/source.zip',
              target = '${scratch.path}/deflated.zip';
          await File(source).writeAsBytes(await store.export());
          final result = await Process.run(
            Platform.environment['CHEKI_PYTHON'] ?? 'python',
            [
              '-c',
              'import sys,zipfile\nwith zipfile.ZipFile(sys.argv[1]) as src, zipfile.ZipFile(sys.argv[2],"w",compression=zipfile.ZIP_DEFLATED) as dst:\n for n in src.namelist(): dst.writestr(n,src.read(n))',
              source,
              target,
            ],
          );
          expect(
            result.exitCode,
            0,
            reason: 'Independent Python deflate failed: ${result.stderr}',
          );
          pack = await File(target).readAsBytes();
        } finally {
          await scratch.delete(recursive: true);
        }
      }
      await store.apply(await store.prepare(pack, TransportMode.snapshot));
      final db = await f.records.database();
      await StorageSchema.validate(db, 8);
      expect((await db.query('unknown_future')).single['raw'], [0, 255]);
      expect(await f.records.list(), hasLength(5));
      if (before != null) expect(await state(f.root), before);
    },
  );
  test(
    'complete snapshot tables unknown BLOB sequences settings attachments and cold read equal',
    () async {
      await f.quantities();
      await f.finances(unknown: true);
      await f.record(
        null,
        null,
        day: null,
        signature: null,
        back: null,
        receipt: null,
      );
      final db = await f.records.database();
      await db.execute(
        'CREATE TABLE unknown_future(id INTEGER PRIMARY KEY AUTOINCREMENT, raw BLOB, text_value TEXT)',
      );
      await db.insert('unknown_future', {
        'id': 99,
        'raw': Uint8List.fromList([0, 255]),
        'text_value': '=原文,\n"001"',
      });
      await db.execute(
        "UPDATE sqlite_sequence SET seq=150 WHERE name='unknown_future'",
      );
      await Directory('${f.root.path}/attachments').create();
      await File('${f.root.path}/attachments/原文.bin').writeAsBytes([0, 255, 1]);
      await DatabaseHelper().close();
      final before = await state(f.root),
          pref = jsonEncode(settings),
          pack = await store.export();
      final zip = TransportZip.decode(pack),
          manifest = jsonDecode(utf8.decode(zip['manifest.json']!)) as Map;
      expect((manifest['tables'] as List).length, before.length);
      await f.record(9, [f.a]);
      settings = {'replaced': true};
      final preview = await store.prepare(pack, TransportMode.snapshot);
      expect(await state(f.root), isNot(before));
      await store.apply(preview);
      expect(await state(f.root), before);
      expect(jsonEncode(settings), pref);
      expect(await File('${f.root.path}/attachments/原文.bin').readAsBytes(), [
        0,
        255,
        1,
      ]);
      final reopened = await openDatabase(
        '${f.root.path}/user_database.db',
        readOnly: true,
        singleInstance: false,
      );
      await StorageSchema.validate(reopened, 8);
      await reopened.close();
      // A second full backup and CSV snapshot still carry the imported raw state.
      final second = await store.export();
      await store.apply(await store.prepare(second, TransportMode.snapshot));
      expect(await state(f.root), before);
      final output = Platform.environment['CHEKI_TRANSPORT_EVIDENCE'];
      if (output != null) {
        final root = Directory(output);
        expect(
          await File('$output/.transport-synthetic').readAsString(),
          'count_tools',
        );
        expect(
          root.absolute.path.startsWith(
            r'E:\OneDrive\Code\artifacts\count-tools-workflow\',
          ),
          true,
        );
        await DatabaseHelper().close();
        await File(
          '${f.root.path}/user_database.db',
        ).copy('$output/database.sqlite');
        await File(
          '$output/preferences.json',
        ).writeAsString(jsonEncode(settings));
        await File('$output/synthetic-attachment').writeAsBytes([0, 255, 1]);
        await File('$output/full.chekicsv.zip').writeAsBytes(second);
        await File(
          '$output/app.chekibackup',
        ).writeAsBytes(await backups.snapshot());
      }
    },
  );
  test(
    'transactions append full linked cost graph once and same batch idempotently skips',
    () async {
      final base = await backups.snapshot();
      await f.quantities();
      await f.finances();
      await DatabaseHelper().close();
      final all = await state(f.root),
          pack = await store.export(mode: TransportMode.transactions);
      await backups.apply(await backups.prepare(base));
      final preview = await store.prepare(pack, TransportMode.transactions);
      expect(preview.added, greaterThan(0));
      expect((await state(f.root))['cheki_records'], isEmpty);
      await store.apply(preview);
      expect(await state(f.root), all);
      final repeated = await store.prepare(pack, TransportMode.transactions);
      expect(repeated.added, 0);
      expect(repeated.unchanged, greaterThan(0));
      await store.apply(repeated);
      expect(await state(f.root), all);
      final changed = editPack(pack, (files, m) {
        editTable(files, m, 'cheki_records', (rows) {
          final c = rows.first.indexOf('information_json'),
              v = jsonDecode(jsonDecode(rows[1][c]) as String) as Map;
          v['note'] = 'changed';
          rows[1][c] = jsonEncode(jsonEncode(v));
        });
      });
      await expectLater(
        store.prepare(changed, TransportMode.transactions),
        throwsFormatException,
      );
      expect(await state(f.root), all);
    },
  );
  test(
    'snapshot never adds balances to existing purchase and consumption',
    () async {
      await f.finances();
      final pack = await store.export();
      final before = await state(f.root);
      await store.apply(await store.prepare(pack, TransportMode.snapshot));
      await store.apply(await store.prepare(pack, TransportMode.snapshot));
      expect(await state(f.root), before);
    },
  );
  test(
    'template contains every table header without business defaults and cannot replace snapshot',
    () async {
      final bytes = await store.export(
            template: true,
            mode: TransportMode.transactions,
          ),
          files = TransportZip.decode(bytes),
          manifest = jsonDecode(utf8.decode(files['manifest.json']!)) as Map;
      for (final table in manifest['tables'] as List) {
        expect(
          TransportCsv.decode(utf8.decode(files[table['file']]!)).length,
          1,
        );
      }
      final seed = files['seed.chekibackup']!,
          outer = jsonDecode(utf8.decode(seed)) as Map,
          payload = jsonDecode(outer['payload'] as String) as Map;
      expect(payload['settings'], isEmpty);
      expect((payload['files'] as Map).keys, ['user_database.db']);
      final scaffold = await backups.prepare(seed);
      expect((scaffold.after['tables'] as Map)['cheki_members'], 0);
      expect((scaffold.after['tables'] as Map)['cheki_groups'], 0);
      expect((scaffold.after['tables'] as Map)['cheki_records'], 0);
      final before = await state(f.root);
      await store.apply(await store.prepare(bytes, TransportMode.transactions));
      expect(await state(f.root), before);
      final invalid = editPack(bytes, (_, m) {
        m['mode'] = 'snapshot';
      });
      await expectLater(
        store.prepare(invalid, TransportMode.snapshot),
        throwsFormatException,
      );
    },
  );
  for (final problem in [
    'duplicate',
    'missing table',
    'wrong column',
    'invalid date',
    'invalid relation',
    'negative quantity',
    'invalid amount',
    'mode',
    'duplicate manifest key',
    'lowered sequence',
  ]) {
    test(
      '$problem is refused without changing any live data or settings',
      () async {
        await f.quantities();
        await f.finances();
        final bytes = await store.export(),
            before = await state(f.root),
            prefs = jsonEncode(settings);
        final changed = editPack(bytes, (files, m) {
          if (problem == 'mode') {
            m['mode'] = 'transactions';
            return;
          }
          if (problem == 'duplicate manifest key') {
            files['README.txt'] = Uint8List.fromList([1]);
            m['tables'] = [
              ...(m['tables'] as List),
              (m['tables'] as List).first,
            ];
            return;
          }
          if (problem == 'missing table') {
            files.remove((m['tables'] as List).first['file']);
            return;
          }
          if (problem == 'lowered sequence') {
            editTable(files, m, 'sqlite_sequence', (rows) {
              rows[1][rows.first.indexOf('seq')] = '0';
            });
            return;
          }
          editTable(files, m, 'cheki_records', (rows) {
            if (problem == 'duplicate') {
              rows.add(List.of(rows[1]));
              return;
            }
            if (problem == 'wrong column') {
              rows.first[0] = 'wrong';
              return;
            }
            final c = rows.first.indexOf('information_json'),
                info = jsonDecode(jsonDecode(rows[1][c]) as String) as Map;
            if (problem == 'invalid date') info['occurred_on'] = '2026-02-30';
            if (problem == 'invalid relation') {
              info['member_ids'] = ['no-such-member'];
            }
            if (problem == 'negative quantity') info['quantity'] = -1;
            if (problem == 'invalid amount') {
              info['attributes'] = {'kind': 'unsigned', 'back_signed': true};
            }
            rows[1][c] = jsonEncode(jsonEncode(info));
          });
        });
        await expectLater(
          store.prepare(changed, TransportMode.snapshot),
          throwsFormatException,
        );
        expect(await state(f.root), before);
        expect(jsonEncode(settings), prefs);
      },
    );
  }
  test(
    'transaction conflict retains target plus its later revisions',
    () async {
      await f.quantities();
      final pack = await store.export(mode: TransportMode.transactions);
      final first = (await f.records.list()).first;
      await f.records.save(
        first.information.patch({'note': 'later'}),
        original: first,
        operationId: 'later',
      );
      await DatabaseHelper().close();
      final before = await state(f.root);
      await expectLater(
        store.prepare(pack, TransportMode.transactions),
        throwsFormatException,
      );
      expect(await state(f.root), before);
    },
  );
  for (final nullableKey in [false, true]) {
    test(
      'unkeyed multiplicity and nullable primary keys preserve every source row ($nullableKey)',
      () async {
        final db = await f.records.database();
        await db.execute(
          'CREATE TABLE extra_rows(${nullableKey ? 'id TEXT PRIMARY KEY,' : ''}label TEXT,raw BLOB)',
        );
        for (var i = 0; i < 2; i++) {
          await db.insert('extra_rows', {
            'label': 'same',
            'raw': Uint8List.fromList([0, 255]),
          });
        }
        final transaction = await store.export(
              mode: TransportMode.transactions,
            ),
            snapshot = await store.export();
        final live = await f.records.database();
        await live.delete(
          'extra_rows',
          where: 'rowid=(SELECT MIN(rowid) FROM extra_rows)',
        );
        await DatabaseHelper().close();
        final before = await state(f.root);
        await expectLater(
          store.prepare(transaction, TransportMode.transactions),
          throwsFormatException,
        );
        expect(await state(f.root), before);
        await store.apply(
          await store.prepare(snapshot, TransportMode.snapshot),
        );
        expect((await state(f.root))['extra_rows'], hasLength(2));
        await store.apply(
          await store.prepare(transaction, TransportMode.transactions),
        );
        expect((await state(f.root))['extra_rows'], hasLength(2));
      },
    );
  }
  test(
    'foreign keys in unknown extension tables are checked before commit',
    () async {
      final db = await f.records.database();
      await db.execute(
        'CREATE TABLE extra_links(member TEXT REFERENCES cheki_members(id))',
      );
      final bytes = await store.export(), before = await state(f.root);
      final invalid = editPack(bytes, (files, m) {
        editTable(files, m, 'extra_links', (rows) {
          rows.add([jsonEncode('missing')]);
        });
      });
      await expectLater(
        store.prepare(invalid, TransportMode.snapshot),
        throwsFormatException,
      );
      expect(await state(f.root), before);
    },
  );
  test(
    'intervening writes or settings after preview cannot be overwritten',
    () async {
      await f.quantities();
      final pack = await store.export();
      final preview = await store.prepare(pack, TransportMode.snapshot);
      await f.record(9, [f.a]);
      await DatabaseHelper().close();
      final before = await state(f.root);
      await expectLater(store.apply(preview), throwsA(anything));
      expect(await state(f.root), before);
      final other = await store.prepare(pack, TransportMode.snapshot);
      settings['later'] = 'keep';
      await expectLater(store.apply(other), throwsA(anything));
      expect(settings['later'], 'keep');
    },
  );
  test(
    'generation captured before preparation is explicitly guarded',
    () async {
      final base = await backups.snapshot(),
          fingerprint = BackupStore.snapshotFingerprint(base);
      await f.record(1, [f.a]);
      await DatabaseHelper().close();
      await expectLater(
        backups.prepare(base, expectedBaseline: fingerprint),
        throwsA(anything),
      );
      expect((await state(f.root))['cheki_records'], hasLength(1));
    },
  );
  for (final phase in ['old-moved', 'new-installed', 'settings-written']) {
    test(
      'transport commit fault $phase rolls back complete generation',
      () async {
        await f.quantities();
        final pack = await store.export();
        await f.record(9, [f.a]);
        await DatabaseHelper().close();
        final before = await state(f.root), pref = jsonEncode(settings);
        final preview = await store.prepare(pack, TransportMode.snapshot);
        fault = phase;
        await expectLater(store.apply(preview), throwsStateError);
        expect(await state(f.root), before);
        expect(jsonEncode(settings), pref);
        expect(await backups.journal.exists(), false);
      },
    );
  }
}
