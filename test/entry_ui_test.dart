import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/ui/coupon_entry.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;
import 'catalog_pages_test.dart' show settleIo;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late Directory temp;
  late RecordStore records;
  late TicketStore tickets;
  late EntryStore entries;
  late String member, definition;
  setUp(() async {
    await DatabaseHelper().close();
    temp = await Directory.systemTemp.createTemp('cheki-entry-ui-');
    await legacyFixture('${temp.path}/db');
    DatabaseHelper.pathResolver = () async => '${temp.path}/db';
    records = RecordStore(
      () => DatabaseHelper().database,
      clock: () => DateTime.utc(2026, 10, 13, 7),
    );
    entries = EntryStore(records.database, clock: records.clock);
    tickets = TicketStore(records.database, clock: records.clock);
    final g = await CatalogStore(
      records.database,
    ).create(CatalogKind.group, name: '晨星', operationId: 'g');
    member = (await IdentityStore(records.database).createMember(
      name: 'A',
      groupId: g.id,
      colorRgb: 0x123456,
      operationId: 'a',
    )).id;
    definition = (await tickets.save(
      kind: 'definition',
      information: TicketInformation({
        'name': '基础券',
        'scope': 'group',
        'group_id': g.id,
        'active': true,
      }),
      operationId: 'd',
    )).id;
    for (final row in [
      {'pool': 'long', 'quantity': 30, 'unit_price': '20'},
      {
        'pool': 'dated',
        'quantity': 4,
        'expires_on': '2026-10-15',
        'unit_price': '30',
      },
    ]) {
      await tickets.save(
        kind: 'purchase',
        information: TicketInformation({
          ...row,
          'definition_id': definition,
          'occurred_on': '2026-10-10',
        }),
        operationId: 'buy-${row['pool']}',
        posted: true,
      );
    }
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await temp.delete(recursive: true);
  });
  Future<void> reach(WidgetTester t, Finder f) async {
    if (f.evaluate().isNotEmpty) {
      await t.ensureVisible(f);
      await t.pumpAndSettle();
      return;
    }
    await t.scrollUntilVisible(
      f,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await t.ensureVisible(f);
    await t.pumpAndSettle();
  }

  Future<void> host(WidgetTester t, Widget page, {double scale = 1}) async {
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
    'actual two page default consumption, independent pools review return and atomic save',
    (t) async {
      await host(t, RecordEditPage(store: records));
      await reach(t, find.text('选择成员'));
      await t.tap(find.text('选择成员'));
      await t.pumpAndSettle();
      await t.tap(find.text('晨星 · A').last);
      await t.pumpAndSettle();
      await t.tap(find.text('确定'));
      await settleIo(t);
      await t.drag(find.byType(Scrollable).first, const Offset(0, 600));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('record-quantity')));
      await t.enterText(find.byKey(const ValueKey('record-quantity')), '5');
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('coupon-pool-0-1')));
      expect(
        t
            .widget<Semantics>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('use-consume')),
                    matching: find.byType(Semantics),
                  )
                  .first,
            )
            .properties
            .selected,
        true,
      );
      expect(find.text('扣券明细'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      await reach(t, find.byKey(const ValueKey('coupon-pool-0-0')));
      await t.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('coupon-pool-0-0')),
          matching: find.byType(TextField),
        ),
        '2',
      );
      await t.tap(find.text('核对'));
      await settleIo(t);
      expect(find.textContaining('请核对差额'), findsOneWidget);
      await reach(t, find.byKey(const ValueKey('coupon-pool-0-1')));
      await t.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('coupon-pool-0-1')),
          matching: find.byType(TextField),
        ),
        '3',
      );
      await t.tap(find.text('核对'));
      await settleIo(t);
      expect(find.text('预计花费：¥120'), findsOneWidget);
      expect(find.text('扣券成本明细'), findsNothing);
      expect(find.text('保存'), findsOneWidget);
      await t.binding.handlePopRoute();
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('coupon-pool-0-0')));
      expect(
        t
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('coupon-pool-0-0')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '2',
      );
      await t.tap(find.text('核对'));
      await settleIo(t);
      await t.tap(find.text('保存'));
      await settleIo(t);
      final r = (await t.runAsync(records.list))!.single;
      expect(r.information.quantity, 5);
      expect(r.information.toMap()['attributes'], {
        'kind': 'signed',
        'back_signed': false,
      });
      expect((await t.runAsync(tickets.readModel))!.available, 29);
      expect((await t.runAsync(() => entries.state(r.id)))!.children.length, 2);
      await t.runAsync(() => validateRecords(records));
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'pending blank business info preserves NULL and missing plan fields in actual review save',
    (t) async {
      await host(t, RecordEditPage(store: records, historical: true));
      expect(find.byKey(const ValueKey('use-unknown')), findsNothing);
      await t.pumpAndSettle();
      await t.tap(find.text('核对'));
      await settleIo(t);
      await t.tap(find.text('保存'));
      await settleIo(t);
      final r = (await t.runAsync(records.list))!.single;
      expect(r.information.toMap(), {});
      final state = (await t.runAsync(() => entries.state(r.id)))!;
      expect(state.plan.toMap(), isEmpty);
      expect(state.children, isEmpty);
      expect((await t.runAsync(tickets.readModel))!.available, 34);
      await t.pumpWidget(const SizedBox());
    },
  );
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'portrait $width 200 percent keyboard retains multi-digit manual input and retry',
      (t) async {
        t.view.physicalSize = Size(width, 932);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final info = RecordInformation.fromMap({
          'quantity': 5,
          'occurred_on': '2026-10-13',
          'member_ids': [member],
        });
        final c = CouponEntryController(store: entries, initialMode: 'consume');
        await t.runAsync(() => c.load(info));
        await host(
          t,
          Scaffold(
            body: SingleChildScrollView(
              child: CouponEntryEditor(controller: c, info: info),
            ),
          ),
          scale: 2,
        );
        await reach(t, find.byKey(const ValueKey('coupon-wanted-0')));
        final f = find.descendant(
          of: find.byKey(const ValueKey('coupon-wanted-0')),
          matching: find.byType(TextField),
        );
        await t.enterText(f, '12');
        await t.pumpAndSettle();
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
        await t.pumpAndSettle();
        expect(t.widget<TextField>(f).controller!.text, '12');
        c.error = '券库存读取失败，请重试';
        c.notifyListeners();
        await t.pumpAndSettle();
        await reach(t, find.text('券库存读取失败，请重试'));
        await t.tap(find.text('券库存读取失败，请重试'));
        await settleIo(t);
        expect(c.lines.single['quantity'], 12);
        c.restoreAutomatic();
        await t.pumpAndSettle();
        expect(c.lines.single['quantity'], 12);
        expect(CouponPlan.pools(c.lines.single).map((p) => p['quantity']), [
          4,
          8,
        ]);
        t.view.resetViewInsets();
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
  final visual = Platform.environment['COUNT_TOOLS_ENTRY_VISUALS'];
  if (visual != null) {
    testWidgets(
      'optional portrait actual coupon editor and review visual evidence',
      (t) async {
        expect(File('$visual/.cheki-ui-evidence').existsSync(), true);
        for (final item in [
          ('EntryPreview', r'C:\Windows\Fonts\msyh.ttc'),
          (
            'MaterialIcons',
            r'C:\Users\Aphoe\.cache\count-tools-runtime\flutter-3.47.5\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
          ),
        ]) {
          final loader = FontLoader(item.$1);
          loader.addFont(
            Future.value(ByteData.sublistView(File(item.$2).readAsBytesSync())),
          );
          await t.runAsync(loader.load);
        }
        final info = RecordInformation.fromMap({
          'quantity': 5,
          'occurred_on': '2026-10-13',
          'member_ids': [member],
        });
        final c = CouponEntryController(store: entries, initialMode: 'consume');
        await t.runAsync(() => c.load(info));
        for (final width in [320.0, 430.0, 360.0]) {
          final key = GlobalKey();
          t.view.physicalSize = Size(width, 1000);
          t.view.devicePixelRatio = 1;
          await t.pumpWidget(
            MaterialApp(
              theme: chekiTheme().copyWith(
                textTheme: chekiTheme().textTheme.apply(
                  fontFamily: 'EntryPreview',
                ),
                appBarTheme: chekiTheme().appBarTheme.copyWith(
                  titleTextStyle: chekiTheme().appBarTheme.titleTextStyle!
                      .copyWith(fontFamily: 'EntryPreview'),
                ),
              ),
              builder: (ctx, child) => MediaQuery(
                data: MediaQuery.of(
                  ctx,
                ).copyWith(textScaler: TextScaler.linear(width == 320 ? 2 : 1)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: key,
                child: width == 360
                    ? RecordReviewPage(
                        store: records,
                        information: info,
                        couponPlan: c.plan,
                        operationId: 'visual-only',
                      )
                    : Scaffold(
                        appBar: AppBar(title: const Text('扣券明细')),
                        body: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: CouponEntryEditor(controller: c, info: info),
                        ),
                      ),
              ),
            ),
          );
          await settleIo(t);
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          await t.runAsync(() async {
            final img = await boundary.toImage();
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '$visual/entry-$width.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            img.dispose();
          });
        }
        await t.pumpWidget(const SizedBox());
        c.dispose();
        t.view.reset();
      },
    );
  }
  final restored = Platform.environment['COUNT_TOOLS_ENTRY_RESTORED'];
  if (restored != null) {
    testWidgets(
      'restored compound entry and actual detail cost in fresh read-only Flutter process',
      (t) async {
        expect(
          File(
            '${Directory(restored).parent.path}/.count-tools-isolated.json',
          ).existsSync(),
          true,
        );
        final db = (await t.runAsync(
          () => databaseFactory.openDatabase(
            '$restored/database.sqlite',
            options: OpenDatabaseOptions(readOnly: true),
          ),
        ))!;
        final s = RecordStore(() => Future.value(db));
        await t.runAsync(() => StorageSchema.validate(db, 7));
        final rows = (await t.runAsync(s.list))!;
        expect(rows.length, 4);
        final r = rows.firstWhere((r) => r.information.note == '补录备注');
        final e = EntryStore(s.database);
        final p = (await t.runAsync(() => e.state(r.id)))!;
        final costs = (await t.runAsync(
          () => e.preview(r.information, p.plan, recordId: r.id),
        ))!;
        expect(costs.map((c) => c['cost']), ['30', null]);
        expect(costs.every((c) => c['preserved'] == true), true);
        await host(t, RecordDetailPage(store: s, record: r));
        await reach(t, find.text('扣券成本明细'));
        expect(find.textContaining('保留原分配'), findsWidgets);
        expect(
          jsonDecode(
            File('$restored/settings/preferences.json').readAsStringSync(),
          )['unknown'],
          ['原文'],
        );
        expect(
          File('$restored/attachments/synthetic-attachment').readAsBytesSync(),
          [0, 255, 1, 2],
        );
        await t.pumpWidget(const SizedBox());
        await t.runAsync(db.close);
      },
    );
  }
}

// Keep the database future inside the real-IO zone in widget tests.
Future<void> validateRecords(RecordStore s) async =>
    StorageSchema.validate(await s.database(), StorageSchema.version);
