import 'dart:convert';
import 'dart:io';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/ui/coupon_entry.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late Directory temp;
  late RecordStore records;
  late TicketStore tickets;
  late EntryStore entries;
  late String a, b, base, note;
  var count = 0;
  final clock = DateTime.utc(2026, 10, 13, 7);
  RecordInformation info({
    int q = 1,
    List<String>? ids,
    String day = '2026-10-13',
  }) => RecordInformation.fromMap({
    'quantity': q,
    'occurred_on': day,
    'member_ids': ids ?? [a],
    'ext': {
      '原文': [null, '保留'],
    },
  });
  Map<String, Object?> line(
    String member,
    String def,
    int q, {
    String? expiry,
    bool expired = false,
  }) => {
    'member_id': member,
    'definition_id': def,
    'quantity': q,
    'pools': [
      {
        'pool': expiry == null ? 'long' : 'dated',
        'expires_on': ?expiry,
        'quantity': q,
        if (expired) 'allow_expired': true,
      },
    ],
  };
  CouponPlan plan(List<Map<String, Object?>> lines) => CouponPlan({
    'mode': 'consume',
    'lines': lines,
    'ext': {'来源': '合成', 'nullable': null},
  });
  Future<TicketObject> buy(
    String def,
    int q, {
    String? price,
    String? expiry,
    String day = '2026-10-10',
  }) => tickets.save(
    kind: 'purchase',
    information: TicketInformation({
      'definition_id': def,
      'quantity': q,
      'occurred_on': day,
      'pool': expiry == null ? 'long' : 'dated',
      'expires_on': ?expiry,
      'unit_price': ?price,
    }),
    operationId: 'buy-${count++}',
    posted: true,
  );
  setUp(() async {
    count = 0;
    await DatabaseHelper().close();
    temp = await Directory.systemTemp.createTemp('cheki-linked-');
    final path = '${temp.path}/database';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () => Future.value(path);
    records = RecordStore(() => DatabaseHelper().database, clock: () => clock);
    tickets = TicketStore(records.database, clock: () => clock);
    entries = EntryStore(records.database, clock: () => clock);
    final group = await CatalogStore(
      records.database,
      clock: () => clock,
    ).create(CatalogKind.group, name: '晨星', operationId: 'group');
    final identities = IdentityStore(records.database, clock: () => clock);
    a = (await identities.createMember(
      name: 'A',
      groupId: group.id,
      colorRgb: 0x123456,
      operationId: 'member-a',
    )).id;
    b = (await identities.createMember(
      name: 'B',
      groupId: group.id,
      colorRgb: 0x654321,
      operationId: 'member-b',
    )).id;
    base = (await tickets.save(
      kind: 'definition',
      information: TicketInformation({
        'name': '基础券',
        'scope': 'group',
        'group_id': group.id,
        'active': true,
      }),
      operationId: 'base-definition',
    )).id;
    note = (await tickets.save(
      kind: 'definition',
      information: TicketInformation({
        'name': '留言券',
        'scope': 'group',
        'group_id': group.id,
        'active': true,
      }),
      operationId: 'note-definition',
    )).id;
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await temp.delete(recursive: true);
  });
  Future<void> valid() async =>
      StorageSchema.validate(await records.database(), 7);
  test(
    'one Cheki multiple coupons and member participation only actual record quantity',
    () async {
      await buy(base, 2, price: '30');
      await buy(base, 2, price: '20');
      await buy(note, 3, price: '5');
      final r = await entries.save(
        info(),
        plan: plan([line(a, base, 1), line(a, note, 1)]),
        operationId: 'one',
      );
      expect((await records.list()).single.id, r.id);
      expect((await records.list()).single.information.quantity, 1);
      final m = await tickets.readModel();
      expect(m.pools(base).single.quantity, 3);
      expect(m.pools(note).single.quantity, 2);
      final state = (await entries.state(r.id))!;
      expect(state.children.length, 2);
      expect(state.costReference.hasReference, true);
      expect(
        m.objects
            .singleWhere((e) => e.id == state.children.first)
            .allocations
            .single['cost'],
        '30',
      );
      await valid();
      final shared = await entries.save(
        info(q: 2, ids: [a, b]),
        plan: plan([line(a, base, 1), line(b, base, 1)]),
        operationId: 'joint',
      );
      expect(shared.information.quantity, 2);
      expect((await tickets.readModel()).pools(base).single.quantity, 1);
      await valid();
    },
  );
  test(
    'shared pool shortage and independent pool mismatch leave all objects unchanged',
    () async {
      await buy(base, 2);
      final db = await records.database();
      final before = await db.query(TicketSchema.objects);
      await expectLater(
        entries.save(
          info(ids: [a, b]),
          plan: plan([line(a, base, 2), line(b, base, 1)]),
          operationId: 'short',
        ),
        throwsA(anyOf(isA<FormatException>(), isA<CatalogException>())),
      );
      expect(await records.list(), isEmpty);
      expect(await db.query(TicketSchema.objects), before);
      expect(await db.query(EntrySchema.operations), isEmpty);
      final broken = line(a, base, 2)
        ..['pools'] = [
          {'pool': 'long', 'quantity': 1},
        ];
      await expectLater(
        entries.save(info(), plan: plan([broken]), operationId: 'gap'),
        throwsA(isA<CatalogException>()),
      );
      await valid();
    },
  );
  test(
    'failures after record and after allocated coupons rollback audit balances and notifications',
    () async {
      await buy(base, 4, price: '30');
      var notices = 0;
      final s1 = RecordStore.changes.listen((_) => notices++),
          s2 = TicketStore.changes.listen((_) => notices++);
      for (final phase in ['record', 'coupons']) {
        final fail = EntryStore(
          records.database,
          clock: () => clock,
          afterRecord: phase == 'record'
              ? () async => throw StateError('injected')
              : null,
          afterTickets: phase == 'coupons'
              ? () async => throw StateError('injected')
              : null,
        );
        await expectLater(
          fail.save(
            info(),
            plan: plan([line(a, base, 3)]),
            operationId: 'fail-$phase',
          ),
          throwsStateError,
        );
        expect(await records.list(), isEmpty);
        expect((await tickets.readModel()).available, 4);
        expect(
          await (await records.database()).query(EntrySchema.bindings),
          isEmpty,
        );
        await valid();
      }
      await Future<void>.delayed(Duration.zero);
      expect(notices, 0);
      await s1.cancel();
      await s2.cancel();
    },
  );
  test(
    'repeated and simultaneous requests do not double consume; changed same ID rejected',
    () async {
      await buy(base, 3, price: '30');
      final input = info();
      final p = plan([line(a, base, 1)]);
      final result = await Future.wait([
        entries.save(input, plan: p, operationId: 'repeat'),
        entries.save(input, plan: p, operationId: 'repeat'),
      ]);
      expect(result.first.id, result.last.id);
      expect((await tickets.readModel()).available, 2);
      expect((await records.list()).length, 1);
      await expectLater(
        entries.save(info(q: 2), plan: p, operationId: 'repeat'),
        throwsA(isA<CatalogException>()),
      );
      await valid();
    },
  );
  test(
    'competing different requests cannot overdraw a shared last coupon',
    () async {
      await buy(base, 1);
      final results = await Future.wait([
        for (final id in ['compete-a', 'compete-b'])
          entries
              .save(info(), plan: plan([line(a, base, 1)]), operationId: id)
              .then<Object>((r) => r)
              .catchError((Object e) => e),
      ]);
      expect(results.whereType<StoredRecord>().length, 1);
      expect((await records.list()).length, 1);
      expect((await tickets.readModel()).available, 0);
      await valid();
    },
  );
  test(
    'unknown cost stays NULL; expired explicit and historical future stock guard',
    () async {
      await buy(base, 2, expiry: '2026-10-12');
      await expectLater(
        entries.save(
          info(),
          plan: plan([line(a, base, 1, expiry: '2026-10-12')]),
          operationId: 'expired-no',
        ),
        throwsFormatException,
      );
      final r = await entries.save(
        info(),
        plan: plan([line(a, base, 1, expiry: '2026-10-12', expired: true)]),
        operationId: 'expired-yes',
      );
      final m = await tickets.readModel();
      final state = (await entries.state(r.id))!;
      final child = m.objects.singleWhere((e) => e.id == state.children.single);
      expect(child.allocations.single['cost'], null);
      await buy(note, 1, day: '2026-10-14');
      await expectLater(
        entries.save(
          info(),
          plan: plan([line(a, note, 1)]),
          operationId: 'borrow-future',
        ),
        throwsFormatException,
      );
      await valid();
    },
  );
  test(
    'blank record and unknown coupon info save then fill without fabricated defaults',
    () async {
      final raw = RecordInformation.fromMap({
        'quantity': null,
        'legacy_raw': {
          'date': '旧原文',
          'ext': null,
          'unknown': [null, '原文'],
        },
      });
      final draft = await entries.save(
        raw,
        plan: CouponPlan({
          'mode': null,
          'lines': null,
          'ext': {'未知': null},
        }),
        operationId: 'blank',
      );
      expect(draft.information.toMap().containsKey('occurred_on'), false);
      expect((await entries.state(draft.id))!.children, isEmpty);
      await buy(base, 2, price: '30');
      final filled = await entries.save(
        raw.patch({
          'quantity': 1,
          'occurred_on': '2026-10-13',
          'member_ids': [a],
        }),
        original: draft,
        plan: plan([line(a, base, 1)]),
        operationId: 'fill',
      );
      expect(filled.id, draft.id);
      expect(filled.createdAt, draft.createdAt);
      expect(
        filled.information.toMap()['legacy_raw'],
        raw.toMap()['legacy_raw'],
      );
      expect(filled.information.toMap().containsKey('attributes'), false);
      await valid();
    },
  );
  test(
    'record-only release is atomic, old consumption audit preserved, receipt edits keep allocation',
    () async {
      await buy(base, 2, price: '30');
      await buy(base, 2, price: '20');
      final p = plan([line(a, base, 1)]);
      final first = await entries.save(info(), plan: p, operationId: 'create');
      final child = (await entries.state(first.id))!.children.single;
      final noteEdit = await records.save(
        first.information.patch({'note': '只补备注'}),
        original: first,
        operationId: 'note-edit',
      );
      expect((await entries.state(first.id))!.children, [child]);
      expect((await tickets.readModel()).available, 3);
      await valid();
      final changed = await entries.save(
        noteEdit.information.patch({'quantity': 2}),
        original: noteEdit,
        plan: plan([line(a, base, 2)]),
        operationId: 'increase',
      );
      expect(changed.id, first.id);
      expect((await tickets.readModel()).available, 2);
      expect(
        (await tickets.readModel()).objects
            .singleWhere((e) => e.id == child)
            .posted,
        false,
      );
      await valid();
      final only = await entries.save(
        changed.information,
        original: changed,
        plan: CouponPlan({'mode': 'record_only', 'lines': []}),
        operationId: 'only',
      );
      expect((await tickets.readModel()).available, 4);
      expect((await entries.state(only.id))!.children, isEmpty);
      await valid();
    },
  );
  test(
    'wrong personal ownership, stale edit and direct single-side stock changes rejected',
    () async {
      final model = await tickets.readModel();
      final group = model.definitions.first.information.text('group_id');
      final personal = await tickets.save(
        kind: 'definition',
        information: TicketInformation({
          'name': 'A券',
          'group_id': group,
          'scope': 'personal',
          'member_id': a,
          'active': true,
        }),
        operationId: 'personal',
      );
      await buy(personal.id, 2);
      await expectLater(
        entries.save(
          info(ids: [b]),
          plan: plan([line(b, personal.id, 1)]),
          operationId: 'wrong-member',
        ),
        throwsA(isA<CatalogException>()),
      );
      final first = await entries.save(
        info(),
        plan: plan([line(a, personal.id, 1)]),
        operationId: 'right',
      );
      final firstState = (await entries.state(first.id))!;
      final child = (await tickets.readModel()).objects.singleWhere(
        (e) => e.id == firstState.children.single,
      );
      await expectLater(
        tickets.save(
          kind: child.kind,
          information: child.information,
          original: child,
          operationId: 'single-side',
          posted: false,
        ),
        throwsA(isA<CatalogException>()),
      );
      await entries.save(
        first.information.patch({'note': '新版'}),
        original: first,
        plan: plan([line(a, personal.id, 1)]),
        operationId: 'edit',
      );
      await expectLater(
        entries.save(
          first.information,
          original: first,
          plan: CouponPlan({'mode': 'record_only', 'lines': []}),
          operationId: 'stale',
        ),
        throwsA(isA<CatalogException>()),
      );
      await valid();
    },
  );
  test(
    'automatic controller FEFO independent edits return and shared allocation never invent demand',
    () async {
      await buy(base, 8);
      await buy(base, 4, expiry: '2026-10-15');
      final c = CouponEntryController(store: entries, initialMode: 'consume');
      await c.load(info(q: 5));
      c.selectDefinition(0, base);
      expect(CouponPlan.pools(c.lines.single).map((p) => p['quantity']), [
        4,
        1,
      ]);
      c.editPool(0, 0, '2');
      expect(CouponPlan.pools(c.lines.single).last['quantity'], 1);
      await expectLater(
        c.checked(info(q: 5)),
        throwsA(isA<CatalogException>()),
      );
      c.editPool(0, 1, '3');
      expect((await c.checked(info(q: 5))).lines.single['quantity'], 5);
      c.suggest(reset: true);
      expect(CouponPlan.pools(c.lines.single).map((p) => p['quantity']), [
        4,
        1,
      ]);
      c.selectMode('record_only');
      expect(c.lines.length, 1);
      c.selectMode('consume');
      expect(CouponPlan.pools(c.lines.single).map((p) => p['quantity']), [
        4,
        1,
      ]);
      await c.sync(info(q: 2, ids: [a, b]));
      for (var n = 0; n < c.lines.length; n++) {
        c.selectDefinition(n, base);
      }
      c.suggest(reset: true);
      final q = c.lines
          .expand(CouponPlan.pools)
          .where((p) => p['expires_on'] != null)
          .fold(0, (v, p) => v + (p['quantity'] as int));
      expect(q, 4);
      c.dispose();
    },
  );
  test(
    'read-only preview exact costs, earlier date shortage and failed edit preserve all previous allocations',
    () async {
      await buy(base, 2, price: '30', day: '2026-10-10');
      await buy(base, 2, price: '20', day: '2026-10-12');
      final p = plan([line(a, base, 3)]);
      final db = await records.database();
      final before = await db.query(TicketSchema.objects);
      final suggested = await entries.preview(info(q: 3), p);
      expect(suggested.map((e) => e['cost']), ['60', '20']);
      expect(await db.query(TicketSchema.objects), before);
      final first = await entries.save(
        info(q: 3),
        plan: p,
        operationId: 'cost',
      );
      final frozen = await entries.preview(
        first.information,
        p,
        recordId: first.id,
      );
      expect(frozen.every((e) => e['preserved'] == true), true);
      final oldRows = await db.query(TicketSchema.objects),
          oldState = (await entries.state(first.id))!.raw;
      final earlier = first.information.patch({'occurred_on': '2026-10-11'});
      await expectLater(
        entries.preview(earlier, p, recordId: first.id),
        throwsA(anyOf(isA<CatalogException>(), isA<FormatException>())),
      );
      await expectLater(
        entries.save(earlier, plan: p, original: first, operationId: 'earlier'),
        throwsA(anyOf(isA<CatalogException>(), isA<FormatException>())),
      );
      expect(await db.query(TicketSchema.objects), oldRows);
      expect((await entries.state(first.id))!.raw, oldState);
      expect((await records.list()).single.toRow(), first.toRow());
      await valid();
    },
  );
  test(
    'unknown plan keys NULL missing and manual quantity survive controller retry and note editing',
    () async {
      final p = CouponPlan({
        'mode': null,
        'lines': null,
        'ext': {
          '未知': [null, '原文'],
        },
      });
      final r = await entries.save(
        RecordInformation.fromMap({}),
        plan: p,
        operationId: 'unknown-plan',
      );
      final c = CouponEntryController(
        store: entries,
        initialMode: 'record_only',
        recordId: r.id,
      );
      await c.load(r.information);
      expect(c.plan.toMap(), p.toMap());
      expect(c.mode, null);
      final edited = await entries.save(
        r.information.patch({'note': '只补备注'}),
        original: r,
        plan: c.plan,
        operationId: 'unknown-note',
      );
      expect((await entries.state(edited.id))!.plan.toMap(), p.toMap());
      expect(edited.information.toMap().containsKey('occurred_on'), false);
      c.dispose();
      await valid();
    },
  );
  test('schema6 to7 fault rollback and prior facts unchanged', () async {
    final path = '${temp.path}/six';
    await legacyFixture(path);
    final db = await openDatabase(path);
    await db.transaction((tx) => StorageSchema.migrate(tx, 1, 6));
    await db.setVersion(6);
    final before = await db.query('item_data');
    await expectLater(
      db.transaction(
        (tx) => StorageSchema.migrate(
          tx,
          6,
          7,
          afterStep: () async => throw StateError('fail'),
        ),
      ),
      throwsStateError,
    );
    expect(await db.getVersion(), 6);
    expect(await db.query('item_data'), before);
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE name='cheki_entry_states'",
      ),
      isEmpty,
    );
    await db.transaction((tx) => StorageSchema.migrate(tx, 6, 7));
    await db.setVersion(7);
    await StorageSchema.validate(db, 7);
    expect(await db.query('item_data'), before);
    await db.close();
  });
  test(
    'partially known pending use can save; invalid manual entry stays dirty; shared suggestions and pool extension survive reset',
    () async {
      await buy(base, 8);
      await buy(base, 4, expiry: '2026-10-15');
      final pending = await entries.save(
        RecordInformation.fromMap({}),
        plan: CouponPlan({
          'mode': null,
          'lines': [
            {
              'member_id': a,
              'definition_id': base,
              'quantity': null,
              'pools': null,
              'ext': {'future': null},
            },
          ],
        }),
        operationId: 'partial',
      );
      expect((await entries.state(pending.id))!.children, isEmpty);
      final c = CouponEntryController(store: entries, initialMode: 'consume');
      await c.load(info(q: 5, ids: [a, b]));
      c.selectDefinition(0, base);
      c.editPool(0, 0, '2');
      c.editPool(0, 1, '3');
      c.selectDefinition(1, base);
      expect(CouponPlan.pools(c.lines[1]).map((p) => p['quantity']), [2, 3]);
      c.lines[0]['pools'] = [
        {
          'pool': 'dated',
          'expires_on': '2026-10-15',
          'quantity': 2,
          'ext': {'原文': null},
        },
        {'pool': 'long', 'quantity': 3},
      ];
      c.editQuantity(0, '2');
      c.restoreAutomatic();
      expect(c.lines[0]['quantity'], 2);
      expect(CouponPlan.pools(c.lines[0]).first['ext'], {'原文': null});
      c.editQuantity(0, '');
      expect(c.changed, true);
      c.editQuantity(0, 'invalid');
      expect(c.changed, true);
      await expectLater(
        c.checked(info(q: 5, ids: [a, b])),
        throwsFormatException,
      );
      c.dispose();
      await valid();
    },
  );
  test(
    'linked edit failure after release and new allocation preserves complete earlier generation',
    () async {
      await buy(base, 5, price: '30');
      final r = await entries.save(
        info(),
        plan: plan([line(a, base, 1)]),
        operationId: 'before',
      );
      final db = await records.database();
      final tables = [
        RecordSchema.records,
        RecordSchema.operations,
        RecordSchema.history,
        TicketSchema.objects,
        TicketSchema.operations,
        TicketSchema.history,
        EntrySchema.operations,
        EntrySchema.states,
        EntrySchema.bindings,
      ];
      final before = {for (final t in tables) t: await db.query(t)};
      final failing = EntryStore(
        records.database,
        clock: () => clock,
        afterTickets: () async => throw StateError('injected'),
      );
      await expectLater(
        failing.save(
          r.information.patch({'quantity': 2}),
          original: r,
          plan: plan([line(a, base, 2)]),
          operationId: 'edit-fails',
        ),
        throwsStateError,
      );
      for (final t in tables) {
        expect(await db.query(t), before[t]);
      }
      await valid();
    },
  );
  test(
    'actual Dart schema7 synthetic combined export for full recovery',
    () async {
      await buy(base, 2, price: '30');
      await buy(base, 2, price: '20');
      await buy(note, 3);
      final first = await entries.save(
        info(),
        plan: plan([line(a, base, 1), line(a, note, 1)]),
        operationId: 'one',
      );
      await records.save(
        first.information.patch({'note': '补录备注'}),
        original: first,
        operationId: 'note-edit',
      );
      await entries.save(
        info(q: 2, ids: [a, b]),
        plan: plan([line(a, base, 1), line(b, base, 1)]),
        operationId: 'joint',
      );
      await entries.save(
        RecordInformation.fromMap({}),
        plan: CouponPlan({
          'mode': null,
          'lines': null,
          'ext': {
            '原文': [null, '未知'],
          },
        }),
        operationId: 'blank',
      );
      final old = await entries.save(
        RecordInformation.fromMap({
          'quantity': null,
          'legacy_raw': {
            'price': '25.00',
            'date': '旧时间',
            'ext': null,
            'unknown': ['原文', null],
          },
        }),
        plan: CouponPlan({'mode': 'record_only', 'lines': []}),
        operationId: 'old',
      );
      expect(old.information.occurredOn, null);
      await valid();
      await DatabaseHelper().close();
      expect((await records.list()).length, 4);
      await valid();
      final export = Platform.environment['COUNT_TOOLS_ENTRY_ACCEPTANCE'];
      if (export != null) {
        final root = Directory(export);
        expect(root.path.contains('artifacts'), true);
        await root.create(recursive: true);
        expect(File('${root.path}/database.sqlite').existsSync(), false);
        await (await records.database()).execute(
          'PRAGMA wal_checkpoint(TRUNCATE)',
        );
        await DatabaseHelper().close();
        await File(
          '${temp.path}/database',
        ).copy('${root.path}/database.sqlite');
        await File('${root.path}/preferences.json').writeAsString(
          jsonEncode({
            'theme': 0,
            'isDarkMode': false,
            'unknown': ['原文'],
          }),
        );
        await File(
          '${root.path}/synthetic-attachment',
        ).writeAsBytes([0, 255, 1, 2]);
        await File('${root.path}/.entry-acceptance.json').writeAsString(
          jsonEncode({'project': 'count_tools', 'purpose': 'entry-synthetic'}),
        );
      }
    },
  );
}
