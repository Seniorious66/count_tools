import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/ui/entity_grid.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/schema.dart';
import 'bi_fixture.dart';
import 'catalog_pages_test.dart' show settleIo;

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
  Future<IdentityEntity> correct(
    String id,
    String? group,
    String op, {
    IdentityStore? store,
  }) async {
    final m = await f.member(id);
    return (store ?? f.identities).editMember(
      original: m,
      name: m.knownName ?? '',
      colorRgb: m.colorRgb,
      personId: m.personId,
      active: m.active,
      correctGroup: true,
      correctedGroupId: group,
      operationId: op,
    );
  }

  Future<Map<String, List<Map<String, Object?>>>> snapshot() async {
    final db = await f.records.database();
    return {
      for (final row in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      ))
        row['name'] as String: await db.query(row['name'] as String),
    };
  }

  test(
    'wrong group correction and clear retain snapshots, IDs, creation and unknown metadata',
    () async {
      final r = await f.records.save(
        RecordInformation.fromMap({
          'quantity': 1,
          'member_ids': [f.a],
          'member_snapshots': [
            {
              'member_id': f.a,
              'member_name': '旧A',
              'group_id': f.groupA,
              'group_name': '当时团',
              'origin': 'manual',
            },
          ],
          'ext': {
            '未知': [null, '原文'],
          },
        }),
        operationId: 'r',
      );
      final before = r.toRow(), member = await f.member(f.a);
      final changed = await correct(f.a, f.groupB, 'correct');
      expect(changed.id, member.id);
      expect(changed.createdAt, member.createdAt);
      final model = await f.records.readModel();
      expect(model.recordMemberLabel(r.information, f.a), '夜航-A');
      expect(model.historicalMemberLabel(r.information, f.a), contains('当时团'));
      expect(model.records.single.toRow(), before);
      final cleared = await correct(f.a, null, 'clear');
      expect(cleared.groupId, isNull);
      expect((await f.records.readModel()).memberLabel(f.a), 'A');
      await correct(f.a, f.groupA, 'refill');
      await StorageSchema.validate(await f.records.database(), 8);
      final proof = Platform.environment['COUNT_TOOLS_DAILY_ACCEPTANCE'];
      if (proof != null) {
        final root = Directory(proof);
        expect(File('$proof/.daily-acceptance.json').existsSync(), isTrue);
        await f.record(
          null,
          null,
          day: null,
          signature: null,
          back: null,
          receipt: null,
        );
        await f.records.save(
          RecordInformation.fromMap({}),
          operationId: 'empty',
        );
        await f.finances();
        final db = await f.records.database();
        await StorageSchema.validate(db, 8);
        await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
        await File(db.path).copy('${root.path}/database.sqlite');
        await File('${root.path}/preferences.json').writeAsString(
          jsonEncode({
            'isNotFirstEnter': true,
            'member_color': 0,
            'unknown': '{"nullable":null,"原文":"保留"}',
          }),
        );
        await File(
          '${root.path}/synthetic-attachment',
        ).writeAsBytes([0, 255, 13, 10]);
      }
    },
  );
  test(
    'App full-backup restores correction audits, costs, settings and attachments into isolated generation',
    () async {
      await correct(f.a, f.groupB, 'correction');
      await correct(f.a, null, 'clear-group');
      await correct(f.a, f.groupA, 'fill-group');
      await f.finances();
      final source = await f.records.database();
      await source.rawQuery('PRAGMA wal_checkpoint(FULL)');
      final live = Directory('${f.root.path}/isolated-app');
      await live.create();
      await File(source.path).copy('${live.path}/user_database.db');
      await Directory('${live.path}/attachments').create();
      await File(
        '${live.path}/attachments/raw.bin',
      ).writeAsBytes([0, 255, 13, 10]);
      Map<String, Object?> settings = {
        'enabled': true,
        'unknown': ['原文', '保留'],
        'empty': '',
      };
      final savedSettings = Map<String, Object?>.from(settings);
      final store = BackupStore(
        documents: live,
        readSettings: () async => Map.from(settings),
        writeSettings: (v) async {
          settings = Map.from(v);
        },
        closeMain: () async {},
      );
      final original = await store.snapshot();
      settings = {'changed': true};
      await File('${live.path}/attachments/raw.bin').writeAsBytes([1]);
      final preview = await store.prepare(original);
      expect(preview.sourceSchema, 8);
      expect(settings, {'changed': true});
      await store.apply(preview);
      expect(settings, savedSettings);
      expect(await File('${live.path}/attachments/raw.bin').readAsBytes(), [
        0,
        255,
        13,
        10,
      ]);
      final restored = await openDatabase(
        '${live.path}/user_database.db',
        readOnly: true,
        singleInstance: false,
      );
      try {
        await StorageSchema.validate(restored, 8);
        final model = await RecordStore(
          () => Future.value(restored),
        ).readModel();
        expect(model.costFor(model.records.map((r) => r.id)).known.exact, '30');
        expect(
          await restored.query('cheki_identity_operations'),
          await source.query('cheki_identity_operations'),
        );
        expect(
          await restored.query('cheki_records'),
          await source.query('cheki_records'),
        );
        expect(
          await restored.query('sqlite_sequence'),
          await source.query('sqlite_sequence'),
        );
      } finally {
        await restored.close();
      }
      final again = await store.prepare(await store.snapshot());
      expect(again.after['files'], 2);
    },
  );

  test('correction failure rolls back all tables and audits', () async {
    final before = await snapshot();
    final faulty = IdentityStore(
      f.records.database,
      clock: () => f.clock,
      afterWrite: () async => throw StateError('fault'),
    );
    await expectLater(
      correct(f.a, f.groupB, 'fail', store: faulty),
      throwsStateError,
    );
    expect(await snapshot(), before);
    await StorageSchema.validate(await f.records.database(), 8);
  });
  test(
    'personal ticket conflict and group consumption dependency prevent incorrect correction',
    () async {
      await f.tickets.save(
        kind: 'definition',
        information: TicketInformation({
          'name': '保留旧券名',
          'scope': 'personal',
          'member_id': f.a,
          'group_id': f.groupA,
          'active': true,
        }),
        operationId: 'personal',
      );
      final before = await snapshot();
      await expectLater(
        correct(f.a, f.groupB, 'invalid'),
        throwsA(
          isA<CatalogException>().having(
            (e) => e.message,
            'dependencies',
            contains('个人券'),
          ),
        ),
      );
      expect(await snapshot(), before);
      await f.finances();
      final bound = await snapshot();
      await expectLater(
        correct(f.b, f.groupA, 'bound'),
        throwsA(
          isA<CatalogException>().having(
            (e) => e.message,
            'dependencies',
            contains('记录'),
          ),
        ),
      );
      expect(await snapshot(), bound);
    },
  );
  test(
    'deactivated group keeps history and stock, prevents new selection, retains original editing choice',
    () async {
      await f.finances();
      final g = (await f.catalog.list(
        CatalogKind.group,
      )).singleWhere((g) => g.id == f.groupA);
      await f.catalog.edit(
        CatalogKind.group,
        original: g,
        name: g.name,
        active: false,
        operationId: 'stop',
      );
      await expectLater(
        f.identities.validateSelection([f.a]),
        throwsA(isA<CatalogException>()),
      );
      expect(
        (await f.identities.validateSelection(
          [f.a],
          retainedIds: {f.a},
        )).single.id,
        f.a,
      );
      await expectLater(
        f.identities.createMember(
          name: '新',
          groupId: f.groupA,
          operationId: 'bad',
        ),
        throwsA(isA<CatalogException>()),
      );
      final tickets = await f.tickets.readModel();
      expect(tickets.available, 2);
      expect(tickets.definitions.first.information.toMap()['active'], true);
    },
  );
  test(
    'derived ticket titles hide old name while preserving original data and different IDs',
    () async {
      await f.finances();
      final p = await f.tickets.save(
        kind: 'definition',
        information: TicketInformation({
          'name': '旧文本',
          'scope': 'personal',
          'group_id': f.groupA,
          'member_id': f.a,
          'signature': 'signed',
          'size_id': f.three,
        }),
        operationId: 'p',
      );
      final m = await f.tickets.readModel();
      expect(m.label(p), '晨星-A');
      expect(m.scopeLabel(p), '个人券 · 三寸 · 带签');
      expect(m.label(m.definitions.first), '晨星');
      expect(p.information.text('name'), '旧文本');
      expect(m.definitions.map((d) => d.id).toSet().length, 3);
      expect(
        (await f.bi.read())
            .report(BiPeriod(BiScope.all, '2026-10-14'))
            .definitionLabel(p.id),
        '晨星-A',
      );
    },
  );
  test(
    'actual consumed cost matches BI, ignores purchase totals and does not multiply participants',
    () async {
      await f.finances();
      final r = await f.records.readModel();
      final report = (await f.bi.read()).report(
        BiPeriod(BiScope.all, '2026-10-14'),
      );
      expect(
        r
            .costFor(r.records.map((x) => x.id))
            .known
            .same(report.consumedRecordCost.known),
        true,
      );
      expect(r.costFor(r.records.map((x) => x.id)).known.exact, '30');
      expect(report.purchase.known.exact, '100');
      final extra = await f.record(1, [f.a, f.b]);
      final mixed = (await f.records.readModel()).costFor([
        ...r.records.map((x) => x.id),
        extra.id,
      ]);
      expect(mixed.known.exact, '30');
      expect(mixed.unlinkedRecords, 1);
      expect(mixed.label, '花费：¥30');
      expect((await f.records.readModel()).costFor([extra.id]).label, '');
    },
  );
  test(
    'exact fractional and partially unknown consumption survives aggregate and no duplicate record IDs',
    () async {
      final def = await f.tickets.save(
        kind: 'definition',
        information: TicketInformation({
          'scope': 'group',
          'group_id': f.groupA,
          'active': true,
        }),
        operationId: 'def',
      );
      await f.buy(def.id, 3, total: '10');
      await f.buy(def.id, 1);
      Future<StoredRecord> consume(int q, List<String> ids, String op) =>
          EntryStore(f.records.database, clock: () => f.clock).save(
            RecordInformation.fromMap({
              'quantity': q,
              'occurred_on': '2026-10-13',
              'member_ids': ids,
            }),
            plan: CouponPlan({
              'mode': 'consume',
              'lines': [
                {
                  'member_id': f.a,
                  'definition_id': def.id,
                  'quantity': q,
                  'pools': [
                    {'pool': 'long', 'quantity': q},
                  ],
                },
              ],
            }),
            operationId: op,
          );
      final joint = await consume(1, [f.a, f.b], 'joint');
      final mixed = await consume(3, [f.a], 'mixed');
      final model = await f.records.readModel();
      expect(model.costFor([joint.id]).known.exact, '10/3');
      final total = model.costFor([joint.id, joint.id, mixed.id]);
      expect(total.known.exact, '10');
      expect(total.unknownQuantity, 1);
      expect(total.label, '花费：¥10');
      final report = (await f.bi.read()).report(
        BiPeriod(BiScope.all, '2026-10-14'),
      );
      expect(total.known.same(report.consumedRecordCost.known), true);
      expect(report.consumedRecordCost.unknownQuantity, 1);
    },
  );
  testWidgets(
    'new ticket defaults, no ticket name and group filters with explicit invalidation',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: TicketEditPage(store: f.tickets, kind: 'definition'),
        ),
      );
      await settleIo(tester);
      DropdownButtonFormField<String> select(String key) => tester.widget(
        find.descendant(
          of: find.byKey(ValueKey('ticket-$key')),
          matching: find.byType(DropdownButtonFormField<String>),
        ),
      );
      expect(select('scope').initialValue, 'personal');
      expect(select('signature').initialValue, 'signed');
      expect(select('active').initialValue, 'yes');
      expect(select('size_id').initialValue, f.three);
      expect(find.byKey(const ValueKey('ticket-name')), findsNothing);
      Future<void> choose(String key, String label) async {
        await tester.ensureVisible(find.byKey(ValueKey('ticket-$key')));
        await tester.tap(find.byKey(ValueKey('ticket-$key')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await choose('group_id', '晨星');
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.descendant(
                of: find.byKey(const ValueKey('ticket-member_id')),
                matching: find.byType(DropdownButton<String>),
              ),
            )
            .items!
            .map((e) => e.value),
        contains(f.a),
      );
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.descendant(
                of: find.byKey(const ValueKey('ticket-member_id')),
                matching: find.byType(DropdownButton<String>),
              ),
            )
            .items!
            .map((e) => e.value),
        isNot(contains(f.b)),
      );
      await choose('member_id', 'A');
      await choose('group_id', '夜航');
      expect(select('member_id').initialValue, isNull);
      expect(find.text('已清空不属于该团体的成员，请重新选择'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'record edit saves back to list and name backfill controls are absent',
    (tester) async {
      final r = await tester.runAsync(() => f.record(1, [f.a]));
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: RecordListPage(store: f.records),
        ),
      );
      await settleIo(tester);
      expect(find.byTooltip('补录旧信息'), findsNothing);
      await tester.ensureVisible(find.byKey(ValueKey('record-${r!.id}')));
      await tester.tap(find.byKey(ValueKey('record-${r.id}')));
      await settleIo(tester);
      await tester.ensureVisible(find.text('修改记录'));
      await tester.tap(find.text('修改记录'));
      await settleIo(tester);
      expect(find.text('记录名称'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('record-day')),
        '2026-10-10',
      );
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.byType(RecordDetailPage), findsNothing);
      expect(find.text('Cheki记录'), findsOneWidget);
      expect(
        (await tester.runAsync(
          f.records.list,
        ))!.single.information.occurredOn!.value,
        '2026-10-10',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final width in [320.0, 360.0, 390.0, 430.0]) {
    testWidgets('portrait grids fit measured names at $width and 200% text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: CompactEntityGrid(
                  items: [
                    for (var i = 0; i < 25; i++)
                      EntityGridItem(
                        id: 'g$i',
                        name: i % 2 == 0 ? '五个中文名' : 'Mito',
                        subtitle: 'Long Group',
                        color: Colors.blue,
                        inactive: i == 2,
                        onTap: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final g = tester.widget<GridView>(find.byType(GridView));
        final d = g.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(d.crossAxisCount, scale == 1 ? isIn([3, 4]) : isIn([1, 2]));
        expect(
          tester.getSize(find.byKey(const ValueKey('g0'))).width,
          greaterThanOrEqualTo(44),
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
  final copy = Platform.environment['COUNT_TOOLS_DAILY_READONLY_COPY'];
  if (copy != null) {
    test(
      'latest exported S25 read-only copy uses filled groups without editing history',
      () async {
        final db = await openDatabase(
          copy,
          readOnly: true,
          singleInstance: false,
        );
        try {
          final before = await db.query('cheki_records');
          final members = await db.query('cheki_members');
          final model = await RecordStore(() => Future.value(db)).readModel();
          // A new store points only at the saved copy, never at a live device.
          final store = IdentityStore(() => Future.value(db));
          final directory = await store.directory();
          expect(directory.members.length, 25);
          expect(directory.members.where((m) => m.groupId != null).length, 25);
          expect(model.records.length, 343);
          expect(
            model.costFor(model.records.map((r) => r.id)).linkedRecords,
            0,
          );
          for (final r in model.records) {
            for (final id in r.information.memberIds ?? <String>[]) {
              expect(
                model.recordMemberLabel(r.information, id),
                isNot(contains('录入时')),
              );
              expect(
                model.recordMemberLabel(r.information, id),
                isNot(contains('团体名称未填写')),
              );
            }
          }
          expect(before.length, 343);
          await StorageSchema.validate(db, 8);
          expect(await db.query('cheki_records'), before);
          expect(await db.query('cheki_members'), members);
        } finally {
          await db.close();
        }
      },
    );
  }
}
