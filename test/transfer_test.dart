import 'dart:io';
import 'dart:convert';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/data/transfer_store.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/domain/transfer_information.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
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
  late Directory root;
  late TicketStore tickets;
  late TransferStore transfers;
  late String source, target, third, member;
  var n = 0;
  final clock = DateTime.utc(2026, 10, 13, 8);
  setUp(() async {
    await DatabaseHelper().close();
    root = await Directory.systemTemp.createTemp('cheki-transfer-');
    await legacyFixture('${root.path}/db');
    DatabaseHelper.pathResolver = () async => '${root.path}/db';
    n = 0;
    tickets = TicketStore(() => DatabaseHelper().database, clock: () => clock);
    transfers = TransferStore(tickets.database, clock: () => clock);
    final catalog = CatalogStore(tickets.database);
    final g = await catalog.create(
      CatalogKind.group,
      name: '晨星',
      operationId: 'g',
    );
    final h = await catalog.create(
      CatalogKind.group,
      name: '夜航',
      operationId: 'h',
    );
    member = (await IdentityStore(
      tickets.database,
    ).createMember(name: 'A', groupId: h.id, operationId: 'member')).id;
    Future<String> definition(
      String name,
      String group, {
      String? person,
    }) async => (await tickets.save(
      kind: 'definition',
      information: TicketInformation({
        'name': name,
        'scope': person == null ? 'group' : 'personal',
        'member_id': person,
        'group_id': group,
        'active': true,
      }),
      operationId: name,
    )).id;
    source = await definition('基础', g.id);
    target = await definition('个人', h.id, person: member);
    third = await definition('通用', h.id);
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await root.delete(recursive: true);
  });
  Future<TicketObject> buy(
    String d,
    int q, {
    String? unit,
    String? total,
    String? expiry,
    String day = '2026-10-10',
  }) => tickets.save(
    kind: 'purchase',
    information: TicketInformation({
      'definition_id': d,
      'quantity': q,
      'unit_price': unit,
      'total_price': total,
      'occurred_on': day,
      'pool': expiry == null ? 'long' : 'dated',
      'expires_on': expiry,
    }),
    operationId: 'buy-${n++}',
    posted: true,
  );
  TransferInformation info({
    String kind = 'exchange',
    int q = 3,
    String? from,
    String? to,
    String? expiry,
    String? targetExpiry,
    String day = '2026-10-13',
    bool expired = false,
  }) => TransferInformation({
    'kind': kind,
    'source_definition_id': from ?? source,
    'source_pool': expiry == null ? 'long' : 'dated',
    'source_expires_on': expiry,
    'target_definition_id': kind == 'gift' ? null : to ?? target,
    'target_pool': kind == 'gift'
        ? null
        : targetExpiry == null
        ? 'long'
        : 'dated',
    'target_expires_on': targetExpiry,
    'quantity': q,
    'occurred_on': day,
    'allow_expired': expired,
    'ext': {
      '原文': [null, '保留'],
    },
  });
  Future<void> valid() async =>
      StorageSchema.validate(await tickets.database(), 8);
  test(
    'cross group personal exchange per source cost, gift and subsequent Cheki conserve without purchases or Cheki from exchange',
    () async {
      await buy(source, 2, unit: '30');
      await buy(source, 2, unit: '20');
      final r = await transfers.save(
        info(),
        operationId: 'exchange',
        posted: true,
      );
      var m = await tickets.readModel();
      expect(m.pools(source).single.quantity, 1);
      expect(m.pools(target).single.quantity, 3);
      final incoming = m.objects
          .where(
            (e) => r.children.contains(e.id) && e.information.quantity! > 0,
          )
          .toList();
      expect(incoming.map((e) => e.unitCost?.exact), ['30', '20']);
      expect(incoming.map((e) => e.information.quantity), [2, 1]);
      expect(m.objects.where((e) => e.kind == 'purchase').length, 2);
      expect(await RecordStore(tickets.database).list(), isEmpty);
      final next = await transfers.save(
        info(from: target, to: third, q: 2),
        operationId: 'second',
        posted: true,
      );
      expect(
        (await tickets.readModel()).objects
            .singleWhere(
              (e) =>
                  next.children.contains(e.id) && e.information.quantity! > 0,
            )
            .unitCost
            ?.exact,
        '30',
      );
      final gift = await transfers.save(
        info(kind: 'gift', from: third, q: 1),
        operationId: 'gift',
        posted: true,
      );
      expect(gift.children.length, 1);
      final record = await EntryStore(tickets.database, clock: () => clock)
          .save(
            RecordInformation.fromMap({
              'quantity': 1,
              'member_ids': [member],
              'occurred_on': '2026-10-13',
            }),
            plan: CouponPlan({
              'mode': 'consume',
              'lines': [
                {
                  'member_id': member,
                  'definition_id': target,
                  'quantity': 1,
                  'pools': [
                    {'pool': 'long', 'quantity': 1},
                  ],
                },
              ],
            }),
            operationId: 'cheki',
          );
      final state = (await EntryStore(tickets.database).state(record.id))!;
      final child = (await tickets.readModel()).objects.singleWhere(
        (e) => e.id == state.children.single,
      );
      expect(child.allocations.single['cost'], '20');
      expect((await RecordStore(tickets.database).list()).length, 1);
      await valid();
    },
  );
  test(
    'exact rational inherited cost and unknown cost never become zero or averaged',
    () async {
      await buy(source, 3, total: '10');
      await buy(source, 2);
      final r = await transfers.save(
        info(q: 4),
        operationId: 'ratio',
        posted: true,
      );
      final m = await tickets.readModel();
      final incoming = m.objects
          .where(
            (e) => r.children.contains(e.id) && e.information.quantity! > 0,
          )
          .toList();
      expect(incoming.map((e) => e.unitCost?.exact), ['10/3', null]);
      final gift = await transfers.save(
        info(kind: 'gift', from: target, q: 2),
        operationId: 'ratio-gift',
        posted: true,
      );
      expect(
        (await tickets.readModel()).objects
            .singleWhere((e) => e.id == gift.children.single)
            .allocations
            .single['cost'],
        '20/3',
      );
      await valid();
    },
  );
  test(
    'repeated concurrent same request one exchange, changed ID reuse and shared last stock rejected',
    () async {
      await buy(source, 1, unit: '30');
      final p = info(q: 1);
      final results = await Future.wait([
        transfers.save(p, operationId: 'same', posted: true),
        transfers.save(p, operationId: 'same', posted: true),
      ]);
      expect(results[0].id, results[1].id);
      expect((await tickets.readModel()).pools(target).single.quantity, 1);
      await expectLater(
        transfers.save(info(q: 2), operationId: 'same', posted: true),
        throwsA(isA<CatalogException>()),
      );
      await expectLater(
        transfers.save(p, operationId: 'last', posted: true),
        throwsFormatException,
      );
      await valid();
    },
  );
  test(
    'outgoing incoming faults rollback stock audit all transfer objects and notifications',
    () async {
      await buy(source, 3, unit: '30');
      final db = await tickets.database();
      final before = await db.query(TicketSchema.objects);
      var notices = 0;
      final s = TicketStore.changes.listen((_) => notices++);
      for (final phase in ['out', 'in']) {
        final t = TransferStore(
          tickets.database,
          clock: () => clock,
          afterOutgoing: phase == 'out'
              ? () async => throw StateError('fault')
              : null,
          afterIncoming: phase == 'in'
              ? () async => throw StateError('fault')
              : null,
        );
        await expectLater(
          t.save(info(q: 1), operationId: 'fault-$phase', posted: true),
          throwsStateError,
        );
        expect(await db.query(TicketSchema.objects), before);
        expect(await transfers.list(), isEmpty);
        expect(await db.query(TransferSchema.lots), isEmpty);
        await valid();
      }
      expect(notices, 0);
      await s.cancel();
    },
  );
  test(
    'no downstream edit and revoke keep IDs creation and histories; downstream chain read-only blocks every writer',
    () async {
      await buy(source, 4, unit: '30');
      final first = await transfers.save(
        info(q: 2),
        operationId: 'first',
        posted: true,
      );
      final edited = await transfers.save(
        first.information.patch({'quantity': 1}),
        original: first,
        operationId: 'edit',
        posted: true,
      );
      expect(edited.id, first.id);
      expect(edited.raw['created_at'], first.raw['created_at']);
      expect((await tickets.readModel()).pools(target).single.quantity, 1);
      final next = await transfers.save(
        info(from: target, to: third, q: 1),
        operationId: 'next',
        posted: true,
      );
      await transfers.save(
        info(kind: 'gift', from: third, q: 1),
        operationId: 'gift',
        posted: true,
      );
      final dependency = await transfers.dependents(edited.children);
      expect(dependency.length, 3);
      expect(next.children.length, 2);
      await expectLater(
        transfers.save(
          edited.information,
          original: edited,
          operationId: 'blocked',
          posted: false,
        ),
        throwsA(isA<CatalogException>()),
      );
      final child = (await tickets.readModel()).objects.singleWhere(
        (e) => e.id == edited.children.last,
      );
      await expectLater(
        tickets.save(
          kind: child.kind,
          information: child.information,
          original: child,
          operationId: 'single',
          posted: false,
        ),
        throwsA(isA<CatalogException>()),
      );
      expect((await transfers.history(first.id)).length, 2);
      await valid();
    },
  );
  test(
    'cancelled exchange releases all pools atomically without erasing source cost history',
    () async {
      await buy(source, 2, unit: '30');
      final r = await transfers.save(
        info(q: 1),
        operationId: 'create',
        posted: true,
      );
      final revoke = await transfers.save(
        r.information,
        original: r,
        operationId: 'revoke',
        posted: false,
      );
      expect(revoke.children, isEmpty);
      expect((await tickets.readModel()).pools(source).single.quantity, 2);
      expect((await tickets.readModel()).pools(target), isEmpty);
      expect((await transfers.history(r.id)).length, 2);
      await valid();
    },
  );
  test(
    'expired explicit, target new expiry, future borrowing and no-op exchange rejected',
    () async {
      await buy(source, 2, unit: '30', expiry: '2026-10-12');
      await expectLater(
        transfers.save(
          info(q: 1, expiry: '2026-10-12'),
          operationId: 'expired-no',
          posted: true,
        ),
        throwsFormatException,
      );
      await transfers.save(
        info(
          q: 1,
          expiry: '2026-10-12',
          expired: true,
          targetExpiry: '2026-10-20',
        ),
        operationId: 'expired-yes',
        posted: true,
      );
      expect(
        (await tickets.readModel()).pools(target).single.expiry,
        '2026-10-20',
      );
      await buy(third, 1, day: '2026-10-14');
      await expectLater(
        transfers.save(
          info(from: third, to: target, q: 1),
          operationId: 'future',
          posted: true,
        ),
        throwsFormatException,
      );
      await expectLater(
        transfers.save(
          info(q: 1, to: source),
          operationId: 'noop',
          posted: true,
        ),
        throwsA(isA<CatalogException>()),
      );
      await valid();
    },
  );
  test(
    'all empty and known partial draft fill keep missing NULL ext creation and do not fabricate zero',
    () async {
      final r = await transfers.save(
        TransferInformation({}),
        operationId: 'blank',
      );
      expect(r.information.toMap(), {});
      expect(r.children, isEmpty);
      final partial = await transfers.save(
        TransferInformation({
          'source_definition_id': source,
          'quantity': null,
          'ext': {'原文': null},
        }),
        operationId: 'partial',
      );
      expect(partial.information.toMap().containsKey('occurred_on'), false);
      await buy(source, 1);
      final filled = await transfers.save(
        partial.information.patch(info(q: 1).toMap()),
        operationId: 'fill',
        original: partial,
        posted: true,
      );
      expect(filled.id, partial.id);
      expect(filled.raw['created_at'], partial.raw['created_at']);
      await valid();
    },
  );
  test(
    'schema7 to8 migration failure preserves prior tables values and version',
    () async {
      final path = '${root.path}/seven';
      await legacyFixture(path);
      final db = await openDatabase(path);
      await db.transaction((t) => StorageSchema.migrate(t, 1, 7));
      await db.setVersion(7);
      final before = await db.query('item_data');
      await expectLater(
        db.transaction(
          (t) => StorageSchema.migrate(
            t,
            7,
            8,
            afterStep: () async => throw StateError('fault'),
          ),
        ),
        throwsStateError,
      );
      expect(await db.getVersion(), 7);
      expect(await db.query('item_data'), before);
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='cheki_transfer_lots'",
        ),
        isEmpty,
      );
      await db.transaction((t) => StorageSchema.migrate(t, 7, 8));
      await db.setVersion(8);
      await StorageSchema.validate(db, 8);
      expect(await db.query('item_data'), before);
      await db.close();
    },
  );
  test(
    'actual schema8 synthetic export with inherited chain and blank information',
    () async {
      await buy(source, 2, unit: '30');
      await buy(source, 2, unit: '20');
      await transfers.save(
        info(),
        operationId: 'export-exchange',
        posted: true,
      );
      await transfers.save(
        info(kind: 'gift', from: target, q: 1),
        operationId: 'export-gift',
        posted: true,
      );
      await transfers.save(
        TransferInformation({}),
        operationId: 'export-blank',
      );
      await EntryStore(tickets.database, clock: () => clock).save(
        RecordInformation.fromMap({
          'quantity': 1,
          'member_ids': [member],
          'occurred_on': '2026-10-13',
          'note': '交换后拍切',
        }),
        plan: CouponPlan({
          'mode': 'consume',
          'lines': [
            {
              'member_id': member,
              'definition_id': target,
              'quantity': 1,
              'pools': [
                {'pool': 'long', 'quantity': 1},
              ],
            },
          ],
        }),
        operationId: 'export-cheki',
      );
      final records = RecordStore(tickets.database, clock: () => clock);
      await records.save(
        RecordInformation.fromMap({}),
        operationId: 'export-record-blank',
      );
      await records.save(
        RecordInformation.fromMap({
          'legacy_raw': {'id': 91, 'date': '2024-01-02 13:14:15', 'ext': null},
          'ext': {
            '缺键': [null, '原文'],
          },
        }),
        operationId: 'export-legacy-information',
      );
      await tickets.save(
        kind: 'purchase',
        information: TicketInformation({
          'quantity': null,
          'ext': {'原文': null},
        }),
        operationId: 'export-ticket-blank',
      );
      await tickets.save(
        kind: 'setting',
        information: TicketInformation({'reminder_days': 3}),
        operationId: 'export-setting',
      );
      await buy(source, 3, total: '10', day: '2026-10-11');
      await buy(source, 2, day: '2026-10-12');
      await transfers.save(
        info(q: 2),
        operationId: 'export-rational',
        posted: true,
      );
      await transfers.save(
        info(q: 4),
        operationId: 'export-unknown',
        posted: true,
      );
      await valid();
      final export = Platform.environment['COUNT_TOOLS_TRANSFER_ACCEPTANCE'];
      if (export != null) {
        final dir = Directory(export);
        await dir.create(recursive: true);
        expect(File('$export/database.sqlite').existsSync(), false);
        await (await tickets.database()).execute(
          'PRAGMA wal_checkpoint(TRUNCATE)',
        );
        await DatabaseHelper().close();
        await File('${root.path}/db').copy('$export/database.sqlite');
        await File('$export/preferences.json').writeAsString(
          jsonEncode({
            'theme': 0,
            'unknown': ['原文'],
          }),
        );
        await File('$export/synthetic-attachment').writeAsBytes([0, 255, 1]);
        await File('$export/.transfer-acceptance.json').writeAsString(
          jsonEncode({
            'project': 'count_tools',
            'purpose': 'transfer-synthetic',
          }),
        );
      }
    },
  );
  test(
    'target FIFO follows exchange day and operation order instead of original purchase date',
    () async {
      await buy(source, 3, unit: '30', day: '2026-01-01');
      await buy(target, 1, unit: '20', day: '2026-10-11');
      await transfers.save(info(q: 2), operationId: 'dated-fifo', posted: true);
      final gift = await transfers.save(
        info(kind: 'gift', from: target, q: 1),
        operationId: 'target-fifo',
        posted: true,
      );
      final child = (await tickets.readModel()).objects.singleWhere(
        (r) => gift.children.contains(r.id),
      );
      expect(child.allocations.single['cost'], '20');
      await valid();
    },
  );
  test(
    'corrupt unknown inherited basis and source snapshot are rejected by storage preflight',
    () async {
      await buy(source, 2);
      await transfers.save(
        info(q: 1),
        operationId: 'unknown-basis',
        posted: true,
      );
      final db = await tickets.database();
      await db.update(TransferSchema.lots, {
        'unit_cost': '0',
        'source_unit_cost': '0',
      });
      await expectLater(
        StorageSchema.validate(db, StorageSchema.version),
        throwsStateError,
      );
      await db.update(TransferSchema.lots, {
        'unit_cost': null,
        'source_unit_cost': null,
      });
      await valid();
      await db.update(TransferSchema.lots, {'source_json': '{}'});
      await expectLater(
        StorageSchema.validate(db, StorageSchema.version),
        throwsA(anything),
      );
      expect(
        () => TransferInformation({'quantity': '1'}),
        throwsFormatException,
      );
    },
  );
}
