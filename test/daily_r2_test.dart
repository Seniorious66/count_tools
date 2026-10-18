import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/record_cost.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/ui/catalog_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/schema.dart';
import 'bi_fixture.dart';
import 'catalog_pages_test.dart' show settleIo;

Map<String, Object?> legacy(Object? price, {int id = 1}) => {
  'quantity': 1,
  'occurred_on': '2025-06-26',
  'legacy_raw': {'id': id, 'price': price, 'ext': null},
  'legacy_source': {
    'snapshot': '20261011_102725',
    'application_id': 'com.example.count_tools',
    'mapping': 'S25-user-confirmed-20261013',
  },
};
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
    'confirmed old amounts preserve original facts and override new cost without duplicating expense',
    () async {
      final a = await f.records.save(
        RecordInformation.fromMap(legacy('100')),
        operationId: 'old-a',
      );
      final b = await f.records.save(
        RecordInformation.fromMap(legacy('100', id: 2)),
        operationId: 'old-b',
      );
      final z = await f.records.save(
        RecordInformation.fromMap(legacy('0', id: 3)),
        operationId: 'zero',
      );
      final missing = await f.records.save(
        RecordInformation.fromMap(legacy(null, id: 4)),
        operationId: 'missing',
      );
      final invalid = await f.records.save(
        RecordInformation.fromMap(legacy('原文待核', id: 5)),
        operationId: 'invalid',
      );
      final raw = await f.records.list();
      final model = await f.records.readModel();
      expect(model.costFor([a.id, b.id, a.id]).known.exact, '200');
      expect(model.costFor([z.id]).label, '花费：¥0');
      expect(model.costFor([missing.id, invalid.id]).label, '');
      expect(
        legacyRecordCost({
          'legacy_raw': {'id': 1, 'price': '100'},
        }),
        isNull,
      );
      final report = (await f.bi.read()).report(
        BiPeriod(BiScope.all, '2026-10-14'),
      );
      expect(report.consumedRecordCost.known.exact, '200');
      expect(report.consumedRecordCost.unknownQuantity, 2);
      expect(report.purchase.known.exact, '0');
      expect(report.csv(), contains('record_expense'));
      expect(report.csv(), contains('legacy_raw'));
      expect(
        (await f.records.list()).map((r) => r.toRow()).toList(),
        raw.map((r) => r.toRow()).toList(),
      );
      expect((await f.tickets.readModel()).objects, isEmpty);
    },
  );
  test(
    'new actual consumption remains 30, old 100 adds once and unlinked record remains unknown',
    () async {
      await f.finances();
      final old = await f.records.save(
        RecordInformation.fromMap(legacy('100')),
        operationId: 'old',
      );
      final unknown = await f.record(1, [f.a, f.b]);
      final model = await f.records.readModel();
      expect(model.costFor(model.records.map((r) => r.id)).known.exact, '130');
      expect(model.costFor([old.id, old.id]).known.exact, '100');
      expect(model.costFor([unknown.id]).knownQuantity, 0);
      final report = (await f.bi.read()).report(
        BiPeriod(BiScope.all, '2026-10-14'),
      );
      expect(report.consumedRecordCost.known.exact, '130');
      expect(report.purchase.known.exact, '100');
      final labels = await f.records.readLabels();
      expect(labels.records, isEmpty);
      expect(labels.costs, isEmpty);
      expect(labels.memberLabel(f.a), '晨星-A');
      await StorageSchema.validate(await f.records.database(), 8);
    },
  );
  test(
    'posted long purchase does not require expiry and reports the specific missing field',
    () async {
      final base = {
        'definition_id': 'def',
        'quantity': 2,
        'occurred_on': '2026-10-15',
        'pool': 'long',
        'total_price': '160',
      };
      expect(postedTicketError('purchase', TicketInformation(base)), isNull);
      expect(
        postedTicketError(
          'purchase',
          TicketInformation({...base, 'occurred_on': null}),
        ),
        contains('入库日期'),
      );
      expect(
        postedTicketError(
          'purchase',
          TicketInformation({...base, 'pool': 'dated'}),
        ),
        contains('截止日期'),
      );
      expect(
        postedTicketError(
          'purchase',
          TicketInformation({...base, 'definition_id': null}),
        ),
        contains('券种'),
      );
      expect(
        () => TicketInformation({...base, 'recorded_at': 'invalid'}),
        throwsFormatException,
      );
    },
  );
  test(
    'complete App restore retains recorded purchase stamp, original amounts and exact frozen costs',
    () async {
      await f.finances();
      await f.records.save(
        RecordInformation.fromMap(legacy('100')),
        operationId: 'legacy',
      );
      await f.records.save(RecordInformation.fromMap({}), operationId: 'blank');
      await f.tickets.save(
        kind: 'purchase',
        information: TicketInformation({
          'definition_id': f.source,
          'quantity': 2,
          'pool': 'long',
          'occurred_on': '2026-10-14',
          'recorded_at': '2026-10-14T01:00:00.000Z',
          'total_price': '160',
          'note': null,
          'ext': {'原文': '保留', '未知': null},
        }),
        operationId: 'r2-purchase',
        posted: true,
      );
      final source = await f.records.database();
      await source.rawQuery('PRAGMA wal_checkpoint(FULL)');
      final live = Directory('${f.root.path}/isolated-roundtrip');
      await live.create();
      await File(source.path).copy('${live.path}/user_database.db');
      await Directory('${live.path}/attachments').create();
      await File(
        '${live.path}/attachments/raw.bin',
      ).writeAsBytes([0, 255, 13, 10]);
      Map<String, Object?> settings = {
        '原文': '保留',
        'unknown': '{"nullable":null}',
        'enabled': true,
      };
      final expected = Map<String, Object?>.from(settings);
      final backup = BackupStore(
        documents: live,
        readSettings: () async => Map.from(settings),
        writeSettings: (v) async {
          settings = Map.from(v);
        },
        closeMain: () async {},
      );
      final bytes = await backup.snapshot();
      settings = {'changed': true};
      await backup.apply(await backup.prepare(bytes));
      expect(settings, expected);
      final restored = await openDatabase(
        '${live.path}/user_database.db',
        readOnly: true,
        singleInstance: false,
      );
      try {
        await StorageSchema.validate(restored, 8);
        for (final row in await source.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        )) {
          final name = row['name'] as String;
          expect(
            await restored.query(name),
            await source.query(name),
            reason: name,
          );
        }
        final records = RecordStore(() async => restored);
        expect(
          (await records.readModel())
              .costFor((await records.list()).map((r) => r.id))
              .known
              .exact,
          '130',
        );
      } finally {
        await restored.close();
      }
      final output = Platform.environment['COUNT_TOOLS_R2_ACCEPTANCE'];
      if (output != null) {
        expect(File('$output/.r2-acceptance.json').existsSync(), isTrue);
        await File(source.path).copy('$output/database.sqlite');
        await File(
          '$output/preferences.json',
        ).writeAsString(jsonEncode(expected));
        await File(
          '$output/synthetic-attachment',
        ).writeAsBytes([0, 255, 13, 10]);
      }
      expect((await backup.prepare(await backup.snapshot())).sourceSchema, 8);
    },
  );
  test(
    'saved copy legacy amount interpretation is read-only and retains every table',
    () async {
      final path = Platform.environment['COUNT_TOOLS_R2_READONLY'];
      if (path == null) return;
      final db = await openDatabase(
        path,
        readOnly: true,
        singleInstance: false,
      );
      try {
        final tables = (await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        )).map((r) => r['name'] as String).toList();
        Future<Map<String, Object?>> snapshot() async => {
          for (final t in tables) t: await db.query(t),
        };
        final before = await snapshot();
        final model = await RecordStore(() async => db).readModel();
        final old = model.records
            .where((r) => legacyRecordCost(r.information.toMap()) != null)
            .toList();
        expect(old.length, 342);
        expect(model.costFor(old.map((r) => r.id)).known.exact, '27355');
        expect(
          old.where((r) => model.costs[r.id]!.known.exact == '0').length,
          70,
        );
        expect(await snapshot(), before);
      } finally {
        await db.close();
      }
    },
  );
  Future<void> mount(
    WidgetTester t,
    Widget page, {
    double width = 360,
    double scale = 1,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    await t.pumpWidget(
      MaterialApp(
        theme: chekiTheme(),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: page,
      ),
    );
    await settleIo(t);
  }

  testWidgets(
    'home symmetric actions, zero pending hidden and cutting routes to entry',
    (t) async {
      addTearDown(t.view.reset);
      for (final width in [320.0, 360.0, 390.0, 430.0]) {
        await mount(
          t,
          Scaffold(
            body: RecordHomePage(store: f.records, ticketStore: f.tickets),
          ),
          width: width,
        );
        final cut = find.byKey(const ValueKey('home-action-切')),
            coupon = find.byKey(const ValueKey('home-action-券'));
        expect(t.getSize(cut), t.getSize(coupon));
        expect(t.getTopLeft(cut).dy, t.getTopLeft(coupon).dy);
        expect(t.getSize(cut).width, (width - 32) / 2);
        expect(find.text('记一笔'), findsNothing);
        expect(find.byKey(const ValueKey('home-pending')), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      }
      await mount(
        t,
        Scaffold(
          body: RecordHomePage(store: f.records, ticketStore: f.tickets),
        ),
        width: 320,
        scale: 2,
      );
      await t.tap(find.byKey(const ValueKey('home-action-切')));
      await settleIo(t);
      expect(find.byType(RecordEditPage), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'pending unknown count is shown, fixed merged records and clearing all filters',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(
        () => f.records.save(
          RecordInformation.fromMap({
            'member_ids': [f.a],
            'receipt_status_hint': 'unreceived',
          }),
          operationId: 'pending-unknown',
        ),
      );
      await mount(
        t,
        Scaffold(
          body: RecordHomePage(store: f.records, ticketStore: f.tickets),
        ),
      );
      expect(find.byKey(const ValueKey('home-pending')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await mount(
        t,
        RecordListPage(
          store: f.records,
          initialFilter: RecordFilter(
            selection: RecordSelection.awaitingReceipt,
            memberId: f.b,
            sizeId: f.five,
            from: '2026-10-12',
            through: '2026-10-13',
          ),
        ),
      );
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.text('合并显示'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '待补录'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '无日期'), findsNothing);
      await t.tap(find.byKey(const ValueKey('record-clear-filters')));
      await settleIo(t);
      expect(
        t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部')).selected,
        isTrue,
      );
      expect(
        t
            .widget<ActionChip>(
              find.byKey(const ValueKey('record-clear-filters')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('成员：夜航-B'), findsNothing);
      expect(find.text('2026-10-12 至 2026-10-13'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'two tickets total160 long save without maintaining any date, original prices retained',
    (t) async {
      addTearDown(t.view.reset);
      final def = await t.runAsync(
        () => f.tickets.save(
          kind: 'definition',
          information: TicketInformation({
            'scope': 'personal',
            'group_id': f.groupA,
            'member_id': f.a,
            'active': true,
          }),
          operationId: 'personal',
        ),
      );
      await mount(
        t,
        TicketEditPage(
          store: f.tickets,
          kind: 'purchase',
          definitionId: def!.id,
        ),
        width: 320,
        scale: 2,
      );
      expect(find.byKey(const ValueKey('ticket-occurred_on')), findsNothing);
      expect(find.byKey(const ValueKey('ticket-expires_on')), findsNothing);
      expect(find.byKey(const ValueKey('ticket-unit_price')), findsNothing);
      expect(find.byKey(const ValueKey('ticket-reason')), findsNothing);
      expect(find.text('录入日期：2026-10-14'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('ticket-quantity')), '2');
      await t.enterText(
        find.byKey(const ValueKey('ticket-total_price')),
        '160',
      );
      await t.ensureVisible(find.text('核对'));
      await t.tap(find.text('核对'));
      await settleIo(t);
      expect(find.text('日期：2026-10-14'), findsOneWidget);
      expect(find.textContaining('截止'), findsNothing);
      await t.ensureVisible(find.text('确认保存'));
      await t.tap(find.text('确认保存'));
      await settleIo(t);
      final m = (await t.runAsync(f.tickets.readModel))!;
      expect(m.available, 2);
      final buy = m.objects.singleWhere((e) => e.kind == 'purchase');
      expect(buy.posted, isTrue);
      expect(buy.information.text('total_price'), '160');
      expect(buy.information.day, '2026-10-14');
      expect(buy.information.expiry, isNull);
      expect(buy.information.toMap().containsKey('unit_price'), isFalse);
      expect(buy.unitCost!.exact, '80');
      expect(buy.information.text('recorded_at'), isNotNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'purchase errors are actionable before review and empty information can remain draft',
    (t) async {
      addTearDown(t.view.reset);
      await mount(t, TicketEditPage(store: f.tickets, kind: 'purchase'));
      await t.ensureVisible(find.text('核对'));
      await t.tap(find.text('核对'));
      await settleIo(t);
      expect(find.text('请选择券种后再计入库存'), findsOneWidget);
      expect(find.textContaining('FormatException'), findsNothing);
      expect(find.text('确认保存'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'management titles align and ticket detail has four actions without edit',
    (t) async {
      addTearDown(t.view.reset);
      await mount(t, CatalogManagementPage(store: f.catalog));
      final titles = ['旧版项目', 'Cheki记录', '券种管理', '成员'];
      final xs = titles.map((x) => t.getTopLeft(find.text(x)).dx).toList();
      expect(xs.every((x) => (x - xs.first).abs() < 1), isTrue);
      await t.pumpWidget(const SizedBox());
      await mount(
        t,
        Scaffold(
          body: TicketActionRow(
            children: [
              for (final label in ['购券', '调整库存', '换券', '送券'])
                TextButton(onPressed: () {}, child: Text(label)),
            ],
          ),
        ),
      );
      final ys = [
        '购券',
        '调整库存',
        '换券',
        '送券',
      ].map((x) => t.getTopLeft(find.text(x)).dy).toList();
      expect(ys.every((y) => (y - ys.first).abs() < 1), isTrue);
      expect(find.text('修改券种'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
}
