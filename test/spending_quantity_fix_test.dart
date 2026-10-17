import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/data/spending_query.dart';
import 'package:count_tools/cheki/data/transfer_store.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/transport_store.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/transfer_information.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/ui/coupon_entry.dart';
import 'bi_fixture.dart';
import 'transport_test.dart' show state;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late BiFixture f;
  setUp(() async {
    f = BiFixture();
    await f.open();
  });
  tearDown(() => f.close());
  test(
    'new expense view survives complete isolated restore with precise fractions settings and attachments',
    () async {
      await f.finances(unknown: true, future: true);
      await f.buy(f.source, 3, total: '100');
      await TransferStore(f.records.database, clock: () => f.clock).save(
        TransferInformation({
          'kind': 'gift',
          'quantity': 3,
          'source_definition_id': f.source,
          'source_pool': 'long',
          'occurred_on': '2026-10-14',
        }),
        posted: true,
        operationId: 'restore-fraction-gift',
      );
      await f.records.save(
        RecordInformation.fromMap({
          'ext': {'missing': {}, 'null': null},
        }),
        operationId: 'restore-blank',
      );
      final attachment = File('${f.root.path}/attachments/source.bin');
      await attachment.parent.create();
      await attachment.writeAsBytes([0, 255, 12]);
      final before = await state(f.root);
      final period = BiPeriod(BiScope.all, '2026-10-14');
      final original = SpendingReport(await f.bi.read(), period);
      expect(original.total(original.lines).known.exact, '400/3');
      var settings = <String, Object?>{
        'opaque': '001',
        'zero': 0,
        'empty': <String>[],
      };
      final backup = BackupStore(
        documents: f.root,
        readSettings: () async => Map.of(settings),
        writeSettings: (v) async {
          settings = Map.of(v);
        },
        closeMain: DatabaseHelper().close,
      );
      final transport = TransportStore(backup);
      final bytes = await transport.export();
      final preview = await transport.prepare(bytes, TransportMode.snapshot);
      expect(await state(f.root), before);
      await transport.apply(preview);
      expect(await state(f.root), before);
      expect(settings, {'opaque': '001', 'zero': 0, 'empty': <String>[]});
      final after = SpendingReport(await f.bi.read(), period);
      expect(after.csv(after.lines), original.csv(original.lines));
      expect(
        after.total(after.lines).label,
        original.total(original.lines).label,
      );
      if (await backup.recovery.exists()) {
        await backup.recovery.delete(recursive: true);
      }
    },
  );
  Future<String> def({
    bool group = false,
    String? member,
    String? groupId,
  }) async => (await f.tickets.save(
    kind: 'definition',
    information: TicketInformation({
      'scope': group ? 'group' : 'personal',
      'group_id': groupId ?? f.groupA,
      if (!group) 'member_id': member ?? f.a,
      'size_id': f.three,
      'signature': 'signed',
      'active': true,
    }),
    operationId: 'd-${f.n++}',
  )).id;
  RecordInformation info(int? q, {List<String>? ids}) =>
      RecordInformation.fromMap({
        'quantity': q,
        'member_ids': ids ?? [f.a],
        'occurred_on': '2026-10-14',
        'size_id': f.three,
        'attributes': {'kind': 'signed'},
      });
  Future<void> gift(String d, int q, {String kind = 'gift', String? target}) =>
      TransferStore(f.records.database, clock: () => f.clock).save(
        TransferInformation({
          'kind': kind,
          'quantity': q,
          'source_definition_id': d,
          'source_pool': 'long',
          'occurred_on': '2026-10-14',
          'target_definition_id': ?target,
          if (target != null) 'target_pool': 'long',
        }),
        posted: true,
        operationId: 't-${f.n++}',
      );
  Future<void> consume(String d, {String? member}) =>
      EntryStore(f.records.database, clock: () => f.clock).save(
        info(1, ids: [member ?? f.a]),
        plan: CouponPlan({
          'mode': 'consume',
          'lines': [
            {
              'member_id': member ?? f.a,
              'definition_id': d,
              'quantity': 1,
              'pools': [
                {'pool': 'long', 'quantity': 1},
              ],
            },
          ],
        }),
        operationId: 'e-${f.n++}',
      );
  Future<void> legacy(
    String price,
    List<String> members, {
    Map<String, Object?> extra = const {},
  }) async {
    await f.records.save(
      RecordInformation.fromMap({
        ...info(1, ids: members).toMap(),
        'legacy_source': {
          'snapshot': '20261011_102725',
          'application_id': 'com.example.count_tools',
          'mapping': 'S25-user-confirmed-20261013',
        },
        'legacy_raw': {'id': ++f.n, 'price': price},
        ...extra,
      }),
      operationId: 'l-${f.n++}',
    );
  }

  SpendingReport report(BiSnapshot s) =>
      SpendingReport(s, BiPeriod(BiScope.all, '2026-10-14'));

  test(
    'gift is expense, exchange inherits only, purchase excluded; member and group reconcile',
    () async {
      final personal = await def(),
          common = await def(group: true),
          target = await def(member: f.b, groupId: f.groupB);
      await f.buy(personal, 3, unit: '30');
      await f.buy(common, 2, unit: '10');
      await legacy('40', [f.a]);
      await consume(personal);
      await gift(personal, 1);
      await gift(common, 1);
      await gift(personal, 1, kind: 'exchange', target: target);
      final r = report(await f.bi.read());
      expect(r.total(r.assigned(member: f.a)).known.exact, '100');
      expect(r.total(r.assigned(group: f.groupA)).known.exact, '110');
      expect(r.total(r.assigned(member: f.b)).knownQuantity, 0);
      expect(r.lines.where((l) => l.kind == '赠送').length, 2);
      await consume(target, member: f.b);
      final after = report(await f.bi.read());
      expect(after.total(after.assigned(member: f.b)).known.exact, '30');
      expect(after.total(after.lines).known.exact, '140');
    },
  );
  test(
    'precise source slices aggregate before half-up display and CSV keeps fractions',
    () async {
      final d = await def();
      await f.buy(d, 3, total: '100');
      await gift(d, 2);
      final r = report(await f.bi.read());
      expect(r.total(r.lines).known.exact, '200/3');
      expect(r.total(r.lines).label, '花费：¥67');
      expect(r.csv(r.lines), contains('"200/3"'));
      expect(TicketMoney.parse('0.5').roundedYuan, '1');
      expect(TicketMoney.parse('0.49').roundedYuan, '0');
      expect(
        TicketMoney.parse('99999999999999999999.5').roundedYuan,
        '100000000000000000000',
      );
    },
  );
  test(
    'multiple source batches never use a current price or average of the pool',
    () async {
      final d = await def();
      await f.buy(d, 1, total: '10.4');
      await f.buy(d, 2, total: '41.2');
      await gift(d, 2);
      final r = report(await f.bi.read());
      expect(r.total(r.lines).known.exact, '31');
      expect(r.total(r.lines).label, '花费：¥31');
    },
  );
  test(
    'joint legacy prices are not copied to participants and snapshots preserve event affiliation',
    () async {
      await legacy('80', [f.a, f.b]);
      await legacy('40', [f.a]);
      await legacy(
        '15',
        [f.a],
        extra: {
          'member_snapshots': [
            {'member_id': f.a, 'group_id': null},
          ],
        },
      );
      await legacy(
        '25',
        [f.a],
        extra: {
          'member_snapshots': [
            {'member_id': f.a, 'group_id': f.groupB},
          ],
        },
      );
      final r = report(await f.bi.read());
      expect(r.total(r.assigned(member: f.a)).known.exact, '80');
      expect(r.total(r.shared(member: f.a)).known.exact, '80');
      expect(r.total(r.assigned(group: f.groupA)).known.exact, '55');
      expect(r.total(r.assigned(group: f.groupB)).known.exact, '25');
      expect(r.total(r.shared()).known.exact, '80');
    },
  );
  test(
    'unknown and explicit zero are distinct; period ignores recorded timestamp',
    () async {
      final d = await def();
      await f.buy(d, 3);
      await gift(d, 1);
      await legacy('0', [f.a]);
      final r = report(await f.bi.read());
      expect(r.total(r.lines).known.exact, '0');
      expect(r.total(r.lines).unknownQuantity, 1);
      expect(r.total(r.lines).label, contains('另有金额未填写'));
      final outside = SpendingReport(
        await f.bi.read(),
        BiPeriod(BiScope.day, '2026-10-13'),
      );
      expect(outside.lines, isEmpty);
    },
  );
  test(
    'report and precise export are read-only across all tables and sequences',
    () async {
      await f.finances();
      final db = await f.records.database();
      Future<String> snapshot() async {
        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        );
        return jsonEncode({
          for (final t in tables)
            t['name'] as String: await db.query(t['name'] as String),
        });
      }

      final before = await snapshot();
      final r = report(await f.bi.read());
      r.csv(r.lines);
      r.total(r.lines);
      expect(await snapshot(), before);
    },
  );
  test(
    'manual choice of definition still follows record quantity 1 to 3 to 2 and blank',
    () async {
      final d = await def();
      await f.buy(d, 4, unit: '10');
      final c = CouponEntryController(
        store: EntryStore(f.records.database),
        initialMode: 'consume',
      );
      await c.load(info(1));
      c.selectDefinition(0, d);
      await c.sync(info(3));
      expect(c.lines.single['definition_id'], d);
      expect(c.lines.single['quantity'], 3);
      expect(CouponPlan.pools(c.lines.single).single['quantity'], 3);
      await c.sync(info(2));
      expect(CouponPlan.pools(c.lines.single).single['quantity'], 2);
      await c.checked(info(2));
      await c.sync(info(null));
      expect(c.lines.single['quantity'], isNull);
      c.dispose();
    },
  );
  test(
    'direct wanted-quantity updates pools but genuine manual pool splits remain',
    () async {
      final d = await def();
      await f.buy(d, 5, unit: '10');
      final c = CouponEntryController(
        store: EntryStore(f.records.database),
        initialMode: 'consume',
      );
      await c.load(info(1));
      c.editQuantity(0, '3');
      expect(CouponPlan.pools(c.lines.single).single['quantity'], 3);
      c.editPool(0, 0, '1');
      c.editQuantity(0, '4');
      expect(CouponPlan.pools(c.lines.single).single['quantity'], 1);
      await c.sync(info(4));
      expect(CouponPlan.pools(c.lines.single).single['quantity'], 1);
      await expectLater(c.checked(info(4)), throwsA(isA<Exception>()));
      c.restoreAutomatic();
      await c.checked(info(4));
      c.dispose();
    },
  );
  test(
    'shared stock is reserved once for manual definitions and automatic members',
    () async {
      final other = await f.identities.createMember(
        name: 'C',
        groupId: f.groupA,
        operationId: 'c',
      );
      final d = await def(group: true);
      await f.buy(d, 3, unit: '10');
      final c = CouponEntryController(
        store: EntryStore(f.records.database),
        initialMode: 'consume',
      );
      await c.load(info(1, ids: [f.a, other.id]));
      c.selectDefinition(0, d);
      await c.sync(info(2, ids: [f.a, other.id]));
      final allocated = c.lines
          .expand(CouponPlan.pools)
          .fold<int>(0, (n, p) => n + (p['quantity'] as int? ?? 0));
      expect(allocated, 3);
      await expectLater(
        c.checked(info(2, ids: [f.a, other.id])),
        throwsA(isA<Exception>()),
      );
      c.editQuantity(0, '1');
      expect(CouponPlan.pools(c.lines[1]).single['quantity'], 2);
      await c.checked(info(2, ids: [f.a, other.id]));
      c.dispose();
    },
  );
  test(
    'editing explicit quantity retains identity and creation stamp then atomically replaces frozen use',
    () async {
      final d = await def();
      await f.buy(d, 5, unit: '30');
      await consume(d);
      final original = (await f.records.list()).single;
      final store = EntryStore(f.records.database, clock: () => f.clock);
      final c = CouponEntryController(
        store: store,
        initialMode: 'consume',
        recordId: original.id,
      );
      await c.load(original.information);
      expect(c.changed, isFalse);
      final before = report(
        await f.bi.read(),
      ).total(report(await f.bi.read()).lines).known.exact;
      expect(before, '30');
      final changed = original.information.patch({'quantity': 2});
      await c.sync(changed);
      expect(c.lines.single['quantity'], 2);
      expect(CouponPlan.pools(c.lines.single).single['quantity'], 2);
      final p = await c.checked(changed);
      final saved = await store.save(
        changed,
        plan: p,
        operationId: 'edit-record-quantity',
        original: original,
      );
      expect(saved.id, original.id);
      expect(saved.createdAt, original.createdAt);
      final r = report(await f.bi.read());
      expect(r.total(r.lines).known.exact, '60');
      expect((await f.tickets.readModel()).available, 3);
      c.dispose();
    },
  );
  test(
    'invalid wanted amount cannot create negative pool reservations or bypass shared capacity',
    () async {
      final d = await def();
      await f.buy(d, 5, unit: '10');
      final c = CouponEntryController(
        store: EntryStore(f.records.database),
        initialMode: 'consume',
      );
      await c.load(info(1));
      c.editQuantity(0, 'bad');
      expect(CouponPlan.pools(c.lines.single), isEmpty);
      await expectLater(c.checked(info(1)), throwsA(isA<Exception>()));
      c.dispose();
    },
  );
}
