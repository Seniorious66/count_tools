import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/spending_query.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/transport_store.dart';
import 'package:count_tools/cheki/data/transport_codec.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/ui/coupon_entry.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'bi_fixture.dart';
import 'transport_test.dart' show state;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late BiFixture f;
  late EntryStore entries;
  setUp(() async {
    f = BiFixture();
    await f.open();
    entries = EntryStore(f.records.database, clock: () => f.clock);
  });
  tearDown(() => f.close());
  CouponPlan direct(String? value) => CouponPlan({
    'mode': 'record_only',
    'expense_origin': 'direct',
    'direct_amount': value,
  });
  Future<StoredRecord> cash(String? value, {StoredRecord? original}) async =>
      entries.save(
        original?.information ??
            RecordInformation.fromMap({
              'quantity': 3,
              'occurred_on': '2026-10-11',
              'member_ids': [f.a],
              'opaque': {'缺键': {}, 'null': null},
            }),
        plan: direct(value),
        original: original,
        operationId: 'cash-${f.n++}',
      );
  Future<SpendingReport> report() async =>
      SpendingReport(await f.bi.read(), BiPeriod(BiScope.all, '2026-10-14'));
  Future<String> definition() async => (await f.tickets.save(
    kind: 'definition',
    information: TicketInformation({
      'scope': 'personal',
      'member_id': f.a,
      'group_id': f.groupA,
      'active': true,
    }),
    operationId: 'def',
  )).id;
  CouponPlan consume(String def, int q, {String? expiry}) => CouponPlan({
    'mode': 'consume',
    'expense_origin': 'coupons',
    'lines': [
      {
        'member_id': f.a,
        'definition_id': def,
        'quantity': q,
        'pools': [
          {
            'pool': expiry == null ? 'long' : 'dated',
            'expires_on': expiry,
            'quantity': q,
          },
        ],
      },
    ],
  });
  Future<StoredRecord> use(
    String def,
    int q, {
    String? expiry,
    StoredRecord? original,
  }) async => entries.save(
    original?.information ??
        RecordInformation.fromMap({
          'quantity': q,
          'occurred_on': '2026-10-11',
          'member_ids': [f.a],
        }),
    plan: consume(def, q, expiry: expiry),
    original: original,
    operationId: 'use-${f.n++}',
  );

  test(
    'v8 migration adds only ledger, fault rolls back, old transport upgrades in isolation',
    () async {
      final r = await f.record(
        null,
        null,
        day: null,
        signature: null,
        back: null,
      );
      final backups = BackupStore(
        documents: f.root,
        readSettings: () async => {'raw': '001'},
        writeSettings: (_) async {},
        closeMain: DatabaseHelper().close,
      );
      final store = TransportStore(backups);
      final files = TransportZip.decode(await store.export());
      final manifest =
          jsonDecode(utf8.decode(files['manifest.json']!))
              as Map<String, dynamic>;
      await DatabaseHelper().close();
      final path = '${f.root.path}/user_database.db';
      final db = await openDatabase(path, singleInstance: false);
      await db.delete(StorageSchema.migrationTable, where: 'version=9');
      await db.setVersion(8);
      await db.close();
      final before = await state(f.root);
      final faultDb = await openDatabase(path, singleInstance: false);
      await expectLater(
        faultDb.transaction(
          (tx) => StorageSchema.migrate(
            tx,
            8,
            9,
            afterStep: () async {
              throw StateError('injected');
            },
          ),
        ),
        throwsStateError,
      );
      await faultDb.close();
      expect(await state(f.root), before);
      files['seed.chekibackup'] = await backups.snapshot();
      manifest['schema'] = 8;
      final descriptor = (manifest['tables'] as List).cast<Map>().singleWhere(
        (t) => t['name'] == StorageSchema.migrationTable,
      );
      final csvName = descriptor['file'] as String;
      final rows = TransportCsv.decode(utf8.decode(files[csvName]!));
      final versionColumn = rows.first.indexOf('version');
      rows.removeWhere((r) => r[versionColumn] == '9');
      files[csvName] = Uint8List.fromList(
        utf8.encode(TransportCsv.encode(rows)),
      );
      files['manifest.json'] = Uint8List.fromList(
        utf8.encode(jsonEncode(manifest)),
      );
      // Main upgrade preserves every preexisting table value and raw record.
      final upgraded = await f.records.database();
      expect(await upgraded.getVersion(), 9);
      final after = await state(f.root);
      for (final table in before.keys.where(
        (k) => k != StorageSchema.migrationTable,
      )) {
        expect(after[table], before[table]);
      }
      expect(
        (await f.records.list()).single.information.encode(),
        r.information.encode(),
      );
      final current = await state(f.root);
      final preview = await store.prepare(
        TransportZip.encode(files),
        TransportMode.snapshot,
      );
      expect(await state(f.root), current);
      await store.apply(preview);
      expect(await state(f.root), current);
      if (await backups.recovery.exists()) {
        await backups.recovery.delete(recursive: true);
      }
    },
  );
  test(
    'schema9 Dart archive passes independent Python audit and complete restore',
    () async {
      await cash('80.50000000000001');
      final r = await cash(null);
      await entries.deleteRecords([r], operationId: 'python-void');
      await DatabaseHelper().close();
      final marker = File('${Directory.current.path}/.count-tools-workspace');
      final repo = await marker.exists()
          ? (await marker.readAsString()).trim()
          : Directory.current.path;
      final result =
          await Process.run(Platform.environment['CHEKI_PYTHON'] ?? 'python', [
            '-c',
            '''import sys,json,tempfile
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import recovery
source=Path(sys.argv[2]).resolve(strict=True)
before=recovery.database_audit(source)
assert before['version']==9
with tempfile.TemporaryDirectory(prefix='cheki-r8-python-') as work:
 p=Path(work);inputs=p/'inputs';inputs.mkdir();prefs=inputs/'preferences.json';prefs.write_text('{"raw":"001"}',encoding='utf-8')
 recovery.snapshot(source,prefs,p/'bundle',[])
 recovery.init_root(p/'restored');recovery.restore(p/'bundle',p/'restored')
 assert recovery.database_audit(p/'restored/current/database.sqlite')==before
print('schema9 full audit restore passed')
''',
            '$repo/scripts',
            '${f.root.path}/user_database.db',
          ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );
  test(
    'all empty record can be deleted without creating coupon inventory',
    () async {
      final r = await f.records.save(
        RecordInformation.fromMap({}),
        operationId: 'blank',
      );
      await entries.deleteRecords([r], operationId: 'blank-delete');
      expect(await f.records.list(), isEmpty);
      expect((await f.tickets.readModel()).objects, isEmpty);
      await StorageSchema.validate(await f.records.database(), 9);
    },
  );
  test(
    'direct expense is a record total, exact before rounding and unique across every reader',
    () async {
      final r = await cash('80.50');
      final m = await f.records.readModel();
      expect(m.costFor([r.id]).known.exact, '161/2');
      expect(m.costFor([r.id]).label, '花费：¥81');
      final s = await report();
      expect(s.total(s.lines).known.exact, '161/2');
      expect(s.total(s.assigned(member: f.a)).known.exact, '161/2');
      expect(s.total(s.assigned(group: f.groupA)).known.exact, '161/2');
      expect(s.csv(s.lines), contains('80.5'));
      expect((await f.tickets.readModel()).objects, isEmpty);
      final edited = await cash('19.125', original: r);
      expect(edited.createdAt, r.createdAt);
      final after = await report();
      expect(after.total(after.lines).known.exact, '153/8');
      expect(
        (await entries.state(r.id))!.plan.toMap()['direct_amount'],
        '19.125',
      );
    },
  );
  test(
    'explicit zero displays, blank stays unknown, invalid values do not write',
    () async {
      final r = await cash('0');
      expect((await f.records.readModel()).costFor([r.id]).label, '花费：¥0');
      await cash(null, original: r);
      expect((await f.records.readModel()).costFor([r.id]).hasAmount, isFalse);
      for (final bad in ['-1', 'NaN', '375/4', '1.', ' 1', '1e3']) {
        expect(() => direct(bad), throwsFormatException);
      }
      expect(
        () => CouponPlan({
          'mode': 'consume',
          'expense_origin': 'direct',
          'direct_amount': '2',
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'mode changes release coupons and never add manual expense to stock cost',
    () async {
      final d = await definition();
      await f.buy(d, 5, unit: '10');
      final first = await use(d, 2);
      expect(
        (await f.records.readModel()).costFor([first.id]).known.exact,
        '20',
      );
      final second = await cash('80.50', original: first);
      expect((await f.tickets.readModel()).pools(d).single.quantity, 5);
      expect(
        (await f.records.readModel()).costFor([first.id]).known.exact,
        '161/2',
      );
      await use(d, 2, original: second);
      expect((await f.tickets.readModel()).pools(d).single.quantity, 3);
      expect(
        (await f.records.readModel()).costFor([first.id]).known.exact,
        '20',
      );
    },
  );
  test(
    'unchanged legacy raw amount remains, explicit current source replaces it',
    () async {
      final r = await f.records.save(
        RecordInformation.fromMap({
          'quantity': 2,
          'occurred_on': '2026-10-11',
          'member_ids': [f.a],
          'legacy_source': {
            'snapshot': '20261011_102725',
            'application_id': 'com.example.count_tools',
            'mapping': 'S25-user-confirmed-20261013',
          },
          'legacy_raw': {'id': 23, 'price': '123.75', 'ext': null},
        }),
        operationId: 'legacy',
      );
      expect(
        (await f.records.readModel()).costFor([r.id]).known.exact,
        '495/4',
      );
      final c = CouponEntryController(
        store: entries,
        initialMode: null,
        recordId: r.id,
      );
      await c.load(r.information);
      expect(c.plan.toMap(), isEmpty);
      expect(c.amount.text, '123.75');
      c.selectMode('record_only');
      c.amount.text = '40.25';
      c.amountTouched = true;
      final changed = await entries.save(
        r.information,
        plan: c.plan,
        original: r,
        operationId: 'legacy-direct',
      );
      expect(changed.information.encode(), r.information.encode());
      final s = await report();
      expect(s.total(s.lines).known.exact, '161/4');
      expect(
        (await f.records.readModel()).costFor([r.id]).known.exact,
        '161/4',
      );
      c.dispose();
    },
  );
  test(
    'delete releases multiple original cost lots, keeps raw history, replays only same request',
    () async {
      final d = await definition();
      await f.buy(d, 1, unit: '10');
      await f.buy(d, 3, unit: '20');
      final r = await use(d, 3);
      final before = r.toRow();
      final other = await use(d, 1);
      expect((await f.tickets.readModel()).available, 0);
      await entries.deleteRecords([r], operationId: 'delete-one');
      expect((await f.tickets.readModel()).pools(d).single.quantity, 3);
      expect((await f.records.list()).map((r) => r.id), [other.id]);
      final history = await f.records.history(r);
      expect(history, hasLength(2));
      expect(jsonDecode(history.last['before_json'] as String), isNotNull);
      final raw = (await (await f.records.database()).query(
        RecordSchema.records,
        where: 'id=?',
        whereArgs: [r.id],
      )).single;
      expect(raw['created_at'], before['created_at']);
      expect(raw['revision'], r.revision + 1);
      expect(StoredRecord.fromRow(raw).information.isVoided, isTrue);
      final snapshot = await state(f.root);
      await entries.deleteRecords([r], operationId: 'delete-one');
      expect(await state(f.root), snapshot);
      await expectLater(
        entries.deleteRecords([r], operationId: 'delete-again'),
        throwsException,
      );
      await expectLater(
        f.records.save(
          r.information,
          original: StoredRecord.fromRow(raw),
          operationId: 'resurrect',
        ),
        throwsException,
      );
      final s = await report();
      expect(s.lines.map((l) => l.record?.id), [other.id]);
      await StorageSchema.validate(await f.records.database(), 9);
    },
  );
  test(
    'delete after purchase amount correction returns current original lot cost without touching gift/exchange',
    () async {
      await f.finances();
      final all = await f.records.list();
      expect(all, hasLength(1));
      final beforeTickets = await (await f.records.database()).query(
        'cheki_transfer_operations',
      );
      final purchase = (await f.tickets.readModel()).objects.firstWhere(
        (t) => t.kind == 'purchase',
      );
      await f.tickets.save(
        kind: purchase.kind,
        information: TicketInformation({
          ...purchase.information.toMap(),
          'total_price': '100',
          'unit_price': null,
        }),
        original: purchase,
        posted: true,
        operationId: 'cost-correct',
      );
      await entries.deleteRecords(all, operationId: 'delete-descendant');
      expect(
        await (await f.records.database()).query('cheki_transfer_operations'),
        beforeTickets,
      );
      expect((await f.tickets.readModel()).pools(f.target).single.quantity, 1);
      expect((await report()).lines.every((l) => l.kind == '赠送'), isTrue);
    },
  );
  test(
    'expired lot returns to original expiry rather than long or fresh pool',
    () async {
      final d = await definition();
      await f.buy(d, 2, unit: '8', expiry: '2026-10-12');
      final r = await use(d, 1, expiry: '2026-10-12');
      await entries.deleteRecords([r], operationId: 'delete-expired');
      final pool = (await f.tickets.readModel(
        day: '2026-10-14',
      )).pools(d).single;
      expect(pool.expiry, '2026-10-12');
      expect(pool.quantity, 2);
      expect(pool.expired('2026-10-14'), isTrue);
    },
  );
  test(
    'bundle delete all or nothing on stale row, failure after release and duplicate IDs',
    () async {
      final d = await definition();
      await f.buy(d, 4, unit: '5');
      final a = await use(d, 1), b = await use(d, 1);
      final original = await state(f.root);
      var calls = 0;
      final failing = EntryStore(
        f.records.database,
        clock: () => f.clock,
        afterTickets: () async {
          if (++calls == 2) throw StateError('injected');
        },
      );
      await expectLater(
        failing.deleteRecords([a, b], operationId: 'batch-fault'),
        throwsStateError,
      );
      expect(await state(f.root), original);
      final b2 = await f.records.save(
        b.information.patch({'note': 'new'}),
        original: b,
        operationId: 'edit-b',
      );
      final revised = await state(f.root);
      await expectLater(
        entries.deleteRecords([a, b], operationId: 'stale'),
        throwsException,
      );
      expect(await state(f.root), revised);
      await expectLater(
        entries.deleteRecords([a, a], operationId: 'duplicate'),
        throwsException,
      );
      expect(await state(f.root), revised);
      await entries.deleteRecords([b2, a], operationId: 'batch');
      expect(await f.records.list(), isEmpty);
      expect((await f.tickets.readModel()).pools(d).single.quantity, 4);
      final complete = await state(f.root);
      await entries.deleteRecords([a, b2], operationId: 'batch');
      expect(await state(f.root), complete);
      await expectLater(
        entries.deleteRecords([a], operationId: 'batch'),
        throwsException,
      );
    },
  );
  test(
    'concurrent edits/delete yield one consistent outcome and no double refund',
    () async {
      final d = await definition();
      await f.buy(d, 3, unit: '5');
      final r = await use(d, 2);
      final results = await Future.wait([
        entries
            .deleteRecords([r], operationId: 'race-a')
            .then((_) => true)
            .catchError((_) => (false)),
        entries
            .deleteRecords([r], operationId: 'race-b')
            .then((_) => true)
            .catchError((_) => (false)),
      ]);
      expect(results.where((x) => x), hasLength(1));
      expect((await f.tickets.readModel()).pools(d).single.quantity, 3);
      await StorageSchema.validate(await f.records.database(), 9);
    },
  );
  test(
    'legacy null and homework are loaded without mutating amount, mode or database',
    () async {
      final r = await f.records.save(
        RecordInformation.fromMap({
          'attributes': {'kind': 'homework'},
          'unrecognized': [null, {}],
        }),
        operationId: 'homework',
      );
      final before = await state(f.root);
      final c = CouponEntryController(
        store: entries,
        initialMode: null,
        recordId: r.id,
      );
      await c.load(r.information);
      expect(c.mode, isNull);
      expect(c.changed, isFalse);
      expect(c.plan.toMap(), isEmpty);
      expect(await state(f.root), before);
      c.dispose();
    },
  );
  test(
    'complete restore and CSV transport preserve deleted state raw audit and direct exact amounts',
    () async {
      final a = await cash('80.5000');
      final b = await cash('0');
      await entries.deleteRecords([b], operationId: 'void-cash');
      var settings = <String, Object?>{'nullText': 'null', 'precision': '001'};
      final file = File('${f.root.path}/attachments/data.bin');
      await file.parent.create();
      await file.writeAsBytes([0, 2, 255]);
      final backups = BackupStore(
        documents: f.root,
        readSettings: () async => Map.of(settings),
        writeSettings: (s) async {
          settings = Map.of(s);
        },
        closeMain: DatabaseHelper().close,
      );
      final transport = TransportStore(backups);
      final before = await state(f.root), s = await report();
      await transport.apply(
        await transport.prepare(
          await transport.export(),
          TransportMode.snapshot,
        ),
      );
      expect(await state(f.root), before);
      expect(settings, {'nullText': 'null', 'precision': '001'});
      expect((await f.records.list()).map((r) => r.id), [a.id]);
      expect(
        (await entries.state(a.id))!.plan.toMap()['direct_amount'],
        '80.5000',
      );
      final after = await report();
      expect(after.csv(after.lines), s.csv(s.lines));
      final saved = await backups.snapshot();
      final preview = await backups.prepare(saved);
      await backups.apply(preview);
      expect(await state(f.root), before);
      if (await backups.recovery.exists()) {
        await backups.recovery.delete(recursive: true);
      }
    },
  );
}
