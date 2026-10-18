import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/data/transfer_store.dart';
import 'package:count_tools/cheki/data/record_cost.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/spending_query.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/transport_store.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/domain/transfer_information.dart';
import 'bi_fixture.dart';
import 'transport_test.dart' show state;
import 'storage_migration_test.dart' show legacyFixture;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late BiFixture f;
  late String third;
  setUp(() async {
    f = BiFixture();
    await f.open();
    Future<String> def(String group, String id) async => (await f.tickets.save(
      kind: 'definition',
      operationId: id,
      information: TicketInformation({
        'scope': 'group',
        'group_id': group,
        'active': true,
      }),
    )).id;
    f.source = await def(f.groupA, 'cost-source');
    f.target = await def(f.groupB, 'cost-target');
    third = await def(f.groupA, 'cost-third');
  });
  tearDown(() => f.close());
  Future<TicketObject> current(String id) async =>
      (await f.tickets.readModel()).objects.singleWhere((t) => t.id == id);
  Future<TicketObject> edit(
    TicketObject original,
    String? total, {
    TicketStore? store,
    String? op,
  }) => (store ?? f.tickets).save(
    kind: 'purchase',
    original: original,
    posted: true,
    operationId: op ?? 'price-${f.n++}',
    information: TicketInformation({
      ...original.information.toMap(),
      'total_price': total,
      'unit_price': null,
    }),
  );
  Future<TransferObject> transfer(
    String source,
    int q, {
    String? target,
    TransferObject? original,
    bool posted = true,
  }) => TransferStore(f.records.database, clock: () => f.clock).save(
    TransferInformation({
      'kind': target == null ? 'gift' : 'exchange',
      'quantity': q,
      'occurred_on': '2026-10-14',
      'source_definition_id': source,
      'source_pool': 'long',
      'target_definition_id': ?target,
      if (target != null) 'target_pool': 'long',
    }),
    original: original,
    posted: posted,
    operationId: 'transfer-${f.n++}',
  );
  Future<void> consume(String source, int q, {bool target = false}) async {
    final m = target ? f.b : f.a;
    await EntryStore(f.records.database, clock: () => f.clock).save(
      RecordInformation.fromMap({
        'quantity': q,
        'member_ids': [m],
        'occurred_on': '2026-10-14',
      }),
      plan: CouponPlan({
        'mode': 'consume',
        'lines': [
          {
            'member_id': m,
            'definition_id': source,
            'quantity': q,
            'pools': [
              {'pool': 'long', 'quantity': q},
            ],
          },
        ],
      }),
      operationId: 'consume-${f.n++}',
    );
  }

  Future<void> valid() async {
    final db = await f.records.database();
    await TicketSchema.validate(db);
    await EntrySchema.validate(db);
    await TransferSchema.validate(db);
  }

  Future<BiReport> report() async =>
      (await f.bi.read()).report(BiPeriod(BiScope.all, '2026-10-14'));
  test(
    'original purchase edit cascades consumption gift exchange inventory without changing facts',
    () async {
      final buy = await f.buy(f.source, 4, total: '375');
      await consume(f.source, 1);
      await transfer(f.source, 1);
      await transfer(f.source, 2, target: f.target);
      await consume(f.target, 1, target: true);
      final db = await f.records.database();
      final before = await state(f.root),
          originalRows = await db.query(TicketSchema.history, orderBy: 'id');
      final quantityBefore = (await f.tickets.readModel()).remaining;
      expect((await report()).consumedRecordCost.known.exact, '375/2');
      await edit(buy, '400', op: 'direct-price');
      final r = await report();
      expect(r.purchase.known.exact, '400');
      expect(r.consumedRecordCost.known.exact, '200');
      expect(
        r.flows['gift']?.cost.known.exact ??
            r.flows.values.singleWhere((x) => x.kind == '赠送').cost.known.exact,
        '100',
      );
      expect(r.stocks.values.fold(0, (int a, b) => a + b.available), 1);
      expect(
        r.stocks.values.singleWhere((x) => x.available > 0).cost.known.exact,
        '100',
      );
      final spending = SpendingReport(
        await f.bi.read(),
        BiPeriod(BiScope.all, '2026-10-14'),
      );
      expect(spending.total(spending.lines).known.exact, '300');
      expect((await f.tickets.readModel()).remaining, quantityBefore);
      final after = await state(f.root);
      for (final t in [
        'cheki_records',
        'cheki_entry_states',
        'cheki_entry_operations',
        'cheki_transfer_objects',
        'cheki_transfer_operations',
        'cheki_entry_ticket_bindings',
        'cheki_transfer_bindings',
        'item_data',
        'sub_project_data',
        'project_data',
      ]) {
        expect(after[t], before[t], reason: t);
      }
      final histories = await db.query(TicketSchema.history, orderBy: 'id');
      expect(histories.take(originalRows.length).toList(), originalRows);
      for (final t in (await f.tickets.readModel()).objects) {
        final old = (before[TicketSchema.objects] as List)
            .cast<Map>()
            .singleWhere((x) => x['id'] == t.id);
        for (final key in ['id', 'seq', 'kind', 'created_at', 'posted']) {
          expect(t.raw[key], old[key]);
        }
        final oi = TicketInformation.decode(old['information_json'] as String);
        expect(t.information.quantity, oi.quantity);
        expect(t.information.day, oi.day);
        expect(
          t.allocations.map((a) => [a['source_id'], a['quantity']]).toList(),
          (jsonDecode(old['allocations_json'] as String) as List)
              .map((dynamic a) => [a['source_id'], a['quantity']])
              .toList(),
        );
      }
      await valid();
    },
  );
  test(
    'mixed-source multi-level exchanges only change the edited purchase contribution',
    () async {
      final buy = await f.buy(f.source, 4, total: '375');
      await f.buy(f.source, 2, total: '50');
      await consume(f.source, 2);
      await transfer(f.source, 4, target: f.target);
      await transfer(f.target, 3);
      await transfer(f.target, 1, target: third);
      await edit(buy, '400');
      await valid();
      final r = await report();
      expect(r.purchase.known.exact, '450');
      expect(r.consumedRecordCost.known.exact, '200');
      final spending = SpendingReport(
        await f.bi.read(),
        BiPeriod(BiScope.all, '2026-10-14'),
      );
      expect(
        spending.total(spending.lines.where((l) => l.kind == '赠送')).known.exact,
        '225',
      );
      expect(
        r.stocks.values.singleWhere((s) => s.available > 0).cost.known.exact,
        '25',
      );
    },
  );
  test(
    'edit again and back after new downstream exchange preserves historical basis revisions',
    () async {
      var buy = await f.buy(f.source, 6, total: '375');
      await transfer(f.source, 4, target: f.target);
      buy = await edit(buy, '600');
      await transfer(f.target, 2, target: third);
      await consume(third, 1);
      buy = await edit(buy, '660');
      await valid();
      expect((await report()).consumedRecordCost.known.exact, '110');
      await edit(buy, '375');
      await valid();
      expect((await report()).consumedRecordCost.known.exact, '125/2');
    },
  );
  test(
    'inactive old exchange children and archived bases remain valid after price changes',
    () async {
      var buy = await f.buy(f.source, 8, total: '800');
      var exchange = await transfer(f.source, 2, target: f.target);
      await transfer(f.target, 1, target: third);
      buy = await edit(buy, '880');
      final transfers = await TransferStore(f.records.database).list();
      final second = transfers.last;
      await transfer(
        f.target,
        1,
        target: third,
        original: second,
        posted: false,
      );
      exchange = await transfer(
        f.source,
        3,
        target: f.target,
        original: exchange,
      );
      await edit(buy, '960');
      await valid();
      expect(exchange.posted, isTrue);
      expect((await f.tickets.readModel()).available, 8);
    },
  );
  test(
    'cost edit handles unknown and zero without turning unknown into zero',
    () async {
      var buy = await f.buy(f.source, 3);
      await transfer(f.source, 2, target: f.target);
      await consume(f.target, 1, target: true);
      buy = await edit(buy, '0');
      await valid();
      expect((await report()).consumedRecordCost.label, '0');
      buy = await edit(buy, '100');
      await valid();
      expect((await report()).consumedRecordCost.known.exact, '100/3');
      await edit(buy, null);
      await valid();
      expect((await report()).consumedRecordCost.hasAmount, isFalse);
      expect((await report()).consumedRecordCost.label, '');
    },
  );
  test(
    'structural edits still blocked and repeated price operation idempotent',
    () async {
      final buy = await f.buy(f.source, 4, total: '375');
      await transfer(f.source, 1);
      final edited = await edit(buy, '400', op: 'one-price');
      final snapshot = await state(f.root);
      expect((await edit(buy, '400', op: 'one-price')).id, edited.id);
      expect(await state(f.root), snapshot);
      await expectLater(
        f.tickets.save(
          kind: 'purchase',
          original: edited,
          posted: true,
          operationId: 'bad-qty',
          information: TicketInformation({
            ...edited.information.toMap(),
            'quantity': 5,
          }),
        ),
        throwsFormatException,
      );
      expect(await state(f.root), snapshot);
      await expectLater(edit(buy, '420'), throwsFormatException);
      expect(await state(f.root), snapshot);
    },
  );
  test(
    'simultaneous stale editors commit only one complete price revision',
    () async {
      final buy = await f.buy(f.source, 4, total: '375');
      await transfer(f.source, 2, target: f.target);
      await consume(f.target, 1, target: true);
      final outcomes = await Future.wait(
        [edit(buy, '400'), edit(buy, '440')].map((future) async {
          try {
            await future;
            return true;
          } on FormatException {
            return false;
          }
        }),
      );
      expect(outcomes.where((ok) => ok).length, 1);
      await valid();
      final amount = (await current(buy.id)).information.unitCost!;
      expect((await report()).consumedRecordCost.known.exact, amount.exact);
    },
  );
  test(
    'SQL failure halfway through dependent updates rolls back complete ledger and audit',
    () async {
      final buy = await f.buy(f.source, 4, total: '375');
      await transfer(f.source, 2, target: f.target);
      await consume(f.target, 1, target: true);
      final db = await f.records.database();
      final child =
          (await db.query(TransferSchema.lots)).first['ticket_id'] as String;
      await db.execute(
        "CREATE TRIGGER cost_fault BEFORE INSERT ON ${TicketSchema.history} WHEN NEW.object_id='$child' BEGIN SELECT RAISE(ABORT,'synthetic cost failure'); END",
      );
      final before = await state(f.root);
      await expectLater(edit(buy, '400'), throwsA(anything));
      expect(await state(f.root), before);
      await db.execute('DROP TRIGGER cost_fault');
      await valid();
    },
  );
  test(
    'failure after all dependent writes still rolls back and allows retry',
    () async {
      final buy = await f.buy(f.source, 4, total: '375');
      await transfer(f.source, 2, target: f.target);
      final before = await state(f.root);
      await expectLater(
        edit(
          buy,
          '400',
          store: TicketStore(
            f.records.database,
            clock: () => f.clock,
            afterWrite: () async =>
                throw StateError('synthetic commit failure'),
          ),
          op: 'retry-price',
        ),
        throwsStateError,
      );
      expect(await state(f.root), before);
      await edit(buy, '400', op: 'retry-price');
      await valid();
    },
  );
  test(
    'linked costs full snapshot transaction transport and Python restoration remain equivalent',
    () async {
      var buy = await f.buy(f.source, 6, total: '375');
      await transfer(f.source, 4, target: f.target);
      buy = await edit(buy, '600');
      await transfer(f.target, 2, target: third);
      await consume(third, 1);
      await edit(buy, '660');
      await valid();
      final attachment = File('${f.root.path}/attachments/cost-source.bin');
      await attachment.parent.create();
      await attachment.writeAsBytes([0, 255, 42]);
      var settings = <String, Object?>{
        'nullText': 'null',
        'list': <String>['中文', '001'],
      };
      final before = await state(f.root);
      final backups = BackupStore(
        documents: f.root,
        readSettings: () async => Map.of(settings),
        writeSettings: (v) async {
          settings = Map.of(v);
        },
        closeMain: DatabaseHelper().close,
      );
      final transport = TransportStore(backups),
          bytes = await transport.export();
      final preview = await transport.prepare(bytes, TransportMode.snapshot);
      await transport.apply(preview);
      expect(await state(f.root), before);
      expect(settings, {
        'nullText': 'null',
        'list': <String>['中文', '001'],
      });
      await valid();
      final transactionBytes = await transport.export(
        mode: TransportMode.transactions,
      );
      final python = Platform.environment['CHEKI_PYTHON'] ?? 'python';
      final marker = File('${Directory.current.path}/.count-tools-workspace');
      final repo = await marker.exists()
          ? (await marker.readAsString()).trim()
          : Directory.current.path;
      const code = '''
import sys,json,tempfile
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import recovery
source=Path(sys.argv[2]).resolve(strict=True)
assert source.parent.name.startswith('cheki-bi-')
before=recovery.database_audit(source)
assert before['version']==8
with tempfile.TemporaryDirectory(prefix='cheki-cost-python-') as work:
    root=Path(work)
    inputs=root/'input';inputs.mkdir()
    prefs=inputs/'preferences.json';prefs.write_text(sys.argv[3],encoding='utf-8')
    attachment=source.parent/'attachments/cost-source.bin'
    recovery.snapshot(source,prefs,root/'bundle',[attachment])
    recovery.init_root(root/'restored')
    recovery.restore(root/'bundle',root/'restored')
    current=root/'restored/current'
    assert recovery.database_audit(current/'database.sqlite')==before
    assert (current/'settings/preferences.json').read_bytes()==prefs.read_bytes()
    assert (current/'attachments/cost-source.bin').read_bytes()==attachment.read_bytes()
    recovery.snapshot(current/'database.sqlite',current/'settings/preferences.json',root/'again',[current/'attachments/cost-source.bin'])
    assert recovery.verify_bundle(root/'again')['database']==json.loads(json.dumps(before))
''';
      final result = await Process.run(python, [
        '-c',
        code,
        '$repo/scripts',
        '${f.root.path}/user_database.db',
        jsonEncode(settings),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      // Exercise actual transaction append into a fresh legacy-only target as well.
      final clean = await Directory.systemTemp.createTemp('cheki-cost-replay-');
      Map<String, Object?> cleanSettings = {};
      BackupStore? cleanBackup;
      try {
        final path = '${clean.path}/user_database.db';
        await legacyFixture(path);
        final empty = await openDatabase(
          path,
          version: 8,
          onUpgrade: (db, old, next) => StorageSchema.migrate(db, old, next),
        );
        // Transaction append requires a shared bootstrap, including default
        // catalog timestamps. Do not weaken the real conflicting-ID refusal.
        for (final size in await (await f.records.database()).query(
          'cheki_sizes',
          where: 'source=?',
          whereArgs: ['default'],
        )) {
          await empty.update(
            'cheki_sizes',
            size,
            where: 'id=?',
            whereArgs: [size['id']],
          );
        }
        await StorageSchema.validate(empty, 8);
        await empty.close();
        cleanBackup = BackupStore(
          documents: clean,
          readSettings: () async => Map.of(cleanSettings),
          writeSettings: (s) async {
            cleanSettings = Map.of(s);
          },
          closeMain: () async {},
        );
        // Append the full corrected lineage into an independent legacy-only
        // ledger; the earlier check already exercised complete snapshot restore.
        final target = TransportStore(cleanBackup);
        final p = await target.prepare(
          transactionBytes,
          TransportMode.transactions,
        );
        await target.apply(p);
        expect(await state(clean), before);
      } finally {
        await clean.delete(recursive: true);
        if (cleanBackup != null && await cleanBackup.recovery.exists()) {
          await cleanBackup.recovery.delete(recursive: true);
        }
      }
      if (await backups.recovery.exists()) {
        await backups.recovery.delete(recursive: true);
      }
    },
  );
  test(
    'later-created backdated purchase can revalue an earlier edited outgoing',
    () async {
      await f.buy(f.source, 2, total: '100', expiry: '2026-10-31');
      final old = await f.tickets.save(
        kind: 'adjustment',
        posted: true,
        operationId: 'old-out',
        information: TicketInformation({
          'definition_id': f.source,
          'quantity': -1,
          'occurred_on': '2026-10-14',
          'pool': 'dated',
          'expires_on': '2026-10-31',
        }),
      );
      final buy = await f.buy(f.source, 2, total: '200');
      await f.tickets.save(
        kind: 'adjustment',
        original: old,
        posted: true,
        operationId: 'change-out-pool',
        information: TicketInformation({
          ...old.information.toMap(),
          'pool': 'long',
          'expires_on': null,
        }),
      );
      await edit(buy, '220');
      await valid();
      expect((await current(old.id)).allocations.single['cost'], '110');
    },
  );
  test(
    'altered cost-basis before-image is refused instead of accepted as history',
    () async {
      final buy = await f.buy(f.source, 4, total: '375');
      await transfer(f.source, 2, target: f.target);
      await edit(buy, '400');
      await valid();
      final db = await f.records.database();
      final ops = await db.query(TicketSchema.operations);
      final op = ops.firstWhere((r) {
        final req = jsonDecode(r['request_json'] as String) as Map;
        return req['__cheki_cost_link_v1'] is Map &&
            (req['__cheki_cost_link_v1'] as Map)['before_lot'] != null;
      });
      final req = jsonDecode(op['request_json'] as String) as Map;
      final tag = req['__cheki_cost_link_v1'] as Map;
      final before = decodeSqlRow(tag['before_lot'] as String);
      tag['before_lot'] = encodeSqlRow({
        ...before,
        'unit_cost': '1',
        'source_unit_cost': '1',
      });
      await db.update(
        TicketSchema.operations,
        {'request_json': jsonEncode(req)},
        where: 'id=?',
        whereArgs: [op['id']],
      );
      await expectLater(TransferSchema.validate(db), throwsStateError);
    },
  );
  test(
    'display yuan and decimal exports never round underlying arithmetic',
    () {
      expect(TicketMoney.fromExact('375/4').roundedYuan, '94');
      expect(TicketMoney.parse('37.5').roundedYuan, '38');
      expect(TicketMoney.fromExact('100/3').decimal, '33.333333333333');
      final known = RecordCost()
        ..add(TicketMoney.parse('100'), 1)
        ..add(null, 1);
      expect(known.label, '花费：¥100');
      expect((RecordCost()..add(null, 1)).label, '');
      expect((RecordCost()..add(TicketMoney.parse('0'), 1)).label, '花费：¥0');
      final amount = BiAmount()
        ..add(TicketMoney.parse('375'), 4)
        ..add(null, 2);
      expect(amount.average, '94');
      expect(amount.displayLabel, '375');
      expect(amount.known.exact, '375');
    },
  );
}
