import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/bi_date_picker.dart';
import 'package:count_tools/cheki/ui/identity_pages.dart';
import 'package:count_tools/cheki/ui/member_inputs.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'bi_fixture.dart';
import 'catalog_pages_test.dart' show settleIo;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (Platform.environment['CHEKI_R4_VISUAL'] != null) {
      for (final entry in {
        'Roboto': 'C:/Windows/Fonts/msyh.ttc',
        'Ahem': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons':
            'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(entry.key);
        loader.addFont(
          Future.value(
            ByteData.sublistView(await File(entry.value).readAsBytes()),
          ),
        );
        await loader.load();
      }
    }
  });
  late BiFixture f;
  setUp(() async {
    f = BiFixture();
    await f.open();
    await f.quantities();
  });
  tearDown(() async => f.close());
  Future<Object> audit() async {
    final db = await f.records.database();
    final names = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    return {
      for (final n in names) n['name']: await db.query(n['name'] as String),
    };
  }

  final boundary = GlobalKey();
  Future<void> host(
    WidgetTester t,
    Widget child, {
    double width = 390,
    double scale = 1,
  }) async {
    final base = chekiTheme();
    final theme = Platform.environment['CHEKI_R4_VISUAL'] == null
        ? base
        : base.copyWith(
            appBarTheme: base.appBarTheme.copyWith(
              titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
                fontFamily: 'Roboto',
              ),
            ),
          );
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 900);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (c, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: Scaffold(body: child),
      ),
    );
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    final folder = Platform.environment['CHEKI_R4_VISUAL'];
    if (folder == null) return;
    await settleIo(t);
    await t.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await Directory(folder).create(recursive: true);
      await File('$folder/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Widget bi({BiStore? store, bool reports = false, BiPeriod? period}) => BiPage(
    store: store ?? f.bi,
    records: f.records,
    reportsOnly: reports,
    initialPeriod: period ?? BiPeriod(BiScope.month, '2026-10-14'),
  );

  test(
    'availability preserves four independent states and unknown group semantics',
    () {
      for (final own in [true, false]) {
        for (final group in [true, false]) {
          final a = MemberAvailability(memberActive: own, groupActive: group);
          expect(a.available, own && group);
          expect(a.reasons, [if (!own) '成员已停用', if (!group) '团体已停用']);
        }
      }
      expect(const MemberAvailability(memberActive: true).description, isNull);
      expect(
        const MemberAvailability(
          memberActive: true,
          groupMissing: true,
        ).description,
        '团体信息不可用',
      );
    },
  );
  test(
    'service gives exact reasons, retains old selections, and group reactivation never enables stopped member',
    () async {
      final db = await f.records.database();
      final groups = await f.catalog.list(CatalogKind.group);
      var group = groups.singleWhere((g) => g.id == f.groupA);
      await db.update(
        'cheki_members',
        {'active': 0, 'group_id': f.groupA},
        where: 'id=?',
        whereArgs: [f.b],
      );
      final membersBefore = await db.query('cheki_members');
      group = await f.catalog.edit(
        CatalogKind.group,
        original: group,
        name: group.name,
        active: false,
        operationId: 'stop-group',
      );
      expect(await db.query('cheki_members'), membersBefore);
      await expectLater(
        f.identities.validateSelection([f.a]),
        throwsA(
          isA<CatalogException>().having(
            (e) => e.toString(),
            'reason',
            contains('团体已停用'),
          ),
        ),
      );
      await expectLater(
        f.identities.validateSelection([f.b]),
        throwsA(
          isA<CatalogException>().having(
            (e) => e.toString(),
            'reasons',
            contains('成员已停用、团体已停用'),
          ),
        ),
      );
      expect(
        (await f.identities.validateSelection(
          [f.b],
          retainedIds: {f.b},
        )).single.id,
        f.b,
      );
      await f.catalog.edit(
        CatalogKind.group,
        original: group,
        name: group.name,
        active: true,
        operationId: 'resume-group',
      );
      expect(await db.query('cheki_members'), membersBefore);
      expect((await f.identities.validateSelection([f.a])).single.id, f.a);
      await expectLater(
        f.identities.validateSelection([f.b]),
        throwsA(
          isA<CatalogException>().having(
            (e) => e.toString(),
            'reason',
            contains('成员已停用'),
          ),
        ),
      );
    },
  );
  for (final pair in [(320.0, 1.0), (390.0, 1.0), (430.0, 2.0)]) {
    testWidgets(
      'member grid and retained chooser show both reasons at ${pair.$1}/${pair.$2}',
      (t) async {
        final db = await t.runAsync(f.records.database);
        await t.runAsync(() async {
          await db!.update(
            'cheki_members',
            {'active': 0},
            where: 'id=?',
            whereArgs: [f.a],
          );
          await db.update(
            'cheki_groups',
            {'active': 0},
            where: 'id=?',
            whereArgs: [f.groupA],
          );
        });
        final before = await t.runAsync(audit);
        await host(
          t,
          IdentityListPage(kind: IdentityKind.member, store: f.identities),
          width: pair.$1,
          scale: pair.$2,
        );
        expect(find.text('成员已停用、团体已停用'), findsOneWidget);
        expect(find.text('团体已停用'), findsNothing);
        await capture(t, 'inactive-grid-${pair.$1}-${pair.$2}');
        expect(t.takeException(), isNull);
        await host(
          t,
          MemberMultiSelectField(
            options: [
              MemberOption(
                id: f.a,
                group: '晨星',
                name: 'A',
                color: Colors.blue,
                available: false,
                unavailableReason: '成员已停用、团体已停用',
              ),
            ],
            selectedIds: [f.a],
            onChanged: (_) {},
          ),
          width: pair.$1,
          scale: pair.$2,
        );
        expect(find.text('成员已停用、团体已停用'), findsOneWidget);
        await t.tap(find.text('已选 1 位 · 修改'));
        await settleIo(t);
        expect(find.text('成员已停用、团体已停用'), findsWidgets);
        await capture(t, 'inactive-chooser-${pair.$1}-${pair.$2}');
        expect(t.takeException(), isNull);
        await t.tap(find.text('取消'));
        await settleIo(t);
        expect(await t.runAsync(audit), before);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'today from all uses Shanghai click-time day, preserves member filter and all raw rows',
    (t) async {
      var clock = DateTime.utc(2026, 10, 13, 15, 59);
      final store = BiStore(f.records.database, clock: () => clock),
          before = await t.runAsync(audit);
      await host(
        t,
        bi(store: store, period: BiPeriod(BiScope.all, '2026-09-01')),
      );
      // The group selector is below the time toolbar and remains controlled.
      await t.tap(find.text('所有团体'));
      await settleIo(t);
      await t.tap(find.text('晨星').last);
      await settleIo(t);
      await t.ensureVisible(find.byKey(const ValueKey('bi-today')));
      await t.tap(find.byKey(const ValueKey('bi-today')));
      await settleIo(t);
      expect(find.text('2026-10-13'), findsWidgets);
      clock = DateTime.utc(2026, 10, 13, 16, 1);
      await t.tap(find.byKey(const ValueKey('bi-today')));
      await settleIo(t);
      expect(find.text('2026-10-14'), findsWidgets);
      expect(find.text('所有时间'), findsNothing);
      expect(find.text('晨星'), findsWidgets);
      expect(
        t.widget<ChoiceChip>(find.byKey(const ValueKey('bi-today'))).selected,
        isTrue,
      );
      expect(find.widgetWithText(ChoiceChip, '日'), findsNothing);
      await capture(t, 'today-preserves-group');
      expect(await t.runAsync(audit), before);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'month year buttons cross periods, calendar cancels then confirms and report stays shared',
    (t) async {
      final before = await t.runAsync(audit);
      await host(
        t,
        bi(reports: true, period: BiPeriod(BiScope.month, '2026-12-31')),
      );
      await t.tap(find.byTooltip('下月'));
      await settleIo(t);
      expect(find.text('2027-01-01 — 2027-01-31'), findsOneWidget);
      await t.tap(find.text('年'));
      await settleIo(t);
      await t.tap(find.byTooltip('上一年'));
      await settleIo(t);
      expect(find.text('2026-01-01 — 2026-12-31'), findsOneWidget);
      await capture(t, 'statistics-year-controls');
      await t.tap(find.text('2026-01-01 — 2026-12-31'));
      await settleIo(t);
      expect(find.byType(TextField), findsNothing);
      final cal = t.widget<CalendarDatePicker>(find.byType(CalendarDatePicker));
      cal.onDateChanged(DateTime(2024, 2, 29));
      await t.pump();
      await t.tap(find.text('取消'));
      await settleIo(t);
      expect(find.text('2026-01-01 — 2026-12-31'), findsOneWidget);
      await t.tap(find.text('2026-01-01 — 2026-12-31'));
      await settleIo(t);
      t
          .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
          .onDateChanged(DateTime(2024, 2, 29));
      await t.pump();
      await t.tap(find.text('确定'));
      await settleIo(t);
      expect(find.text('2024-01-01 — 2024-12-31'), findsOneWidget);
      expect(await t.runAsync(audit), before);
      await t.pumpWidget(const SizedBox());
    },
  );
  for (final pair in [(320.0, 1.0), (360.0, 2.0), (430.0, 2.0)]) {
    testWidgets(
      'calendar portrait ${pair.$1}/${pair.$2}, month/year controls, bounds and cancel',
      (t) async {
        String? selected = 'unchanged';
        await host(
          t,
          Builder(
            builder: (c) => TextButton(
              onPressed: () async {
                selected = await chooseBiDate(
                  c,
                  '2024-02-29',
                  from: '2024-02-01',
                  through: '2024-02-29',
                );
              },
              child: const Text('open'),
            ),
          ),
          width: pair.$1,
          scale: pair.$2,
        );
        await t.tap(find.text('open'));
        await settleIo(t);
        final cal = t.widget<CalendarDatePicker>(
          find.byType(CalendarDatePicker),
        );
        expect(cal.firstDate, DateTime(2024, 2, 1));
        expect(cal.lastDate, DateTime(2024, 2, 29));
        expect(find.byType(TextField), findsNothing);
        expect(find.text('确定').hitTestable(), findsOneWidget);
        if (Platform.environment['CHEKI_R4_VISUAL'] != null) {
          expect(
            t
                .renderObject<RenderParagraph>(find.text('29').last)
                .getBoxesForSelection(
                  const TextSelection(baseOffset: 0, extentOffset: 2),
                ),
            hasLength(1),
          );
        }
        await capture(t, 'calendar-${pair.$1}-${pair.$2}');
        expect(t.takeException(), isNull);
        await t.tap(find.text('取消'));
        await settleIo(t);
        expect(selected, isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  test(
    'period dates keep leap and min max boundary semantics without writes',
    () {
      expect(
        BiPeriod(BiScope.month, '2024-01-31').move(1).through,
        '2024-02-29',
      );
      expect(BiPeriod(BiScope.month, '2024-02-29').move(-1).from, '2024-01-01');
      expect(BiPeriod(BiScope.year, '2024-02-29').move(1).from, '2025-01-01');
      expect(BiPeriod(BiScope.month, '0001-01-01').from, '0001-01-01');
      expect(BiPeriod(BiScope.year, '9999-12-31').through, '9999-12-31');
    },
  );
  testWidgets(
    'actual calendar month arrows, year selection and system back stay draft',
    (t) async {
      String? selected = 'unchanged';
      await host(
        t,
        Builder(
          builder: (c) => TextButton(
            onPressed: () async {
              selected = await chooseBiDate(c, '2026-12-31');
            },
            child: const Text('open'),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settleIo(t);
      expect(find.text('2026年12月'), findsOneWidget);
      await t.tap(find.byTooltip('下个月'));
      await settleIo(t);
      expect(find.text('2027年1月'), findsOneWidget);
      expect(selected, 'unchanged');
      await t.tap(find.text('2027年1月'));
      await settleIo(t);
      expect(find.byType(YearPicker), findsOneWidget);
      final yearLabel = MaterialLocalizations.of(
        t.element(find.byType(YearPicker)),
      ).formatYear(DateTime(2024));
      await t.tap(find.text(yearLabel));
      await settleIo(t);
      expect(find.text('2024年1月'), findsOneWidget);
      await capture(t, 'calendar-year-navigation');
      await t.binding.handlePopRoute();
      await settleIo(t);
      expect(selected, isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  test(
    'null group is allowed while missing known group is unavailable without invented inactive state',
    () async {
      final member = await f.identities.createMember(
        name: '资料未齐',
        groupId: null,
        colorRgb: null,
        operationId: 'blank-group',
      );
      expect(MemberAvailability.fromMember(member, null).available, isTrue);
      expect(
        (await f.identities.validateSelection([member.id])).single.id,
        member.id,
      );
      final original = (await f.identities.list(
        IdentityKind.member,
      )).firstWhere((m) => m.id == f.a);
      final missing = MemberAvailability.fromMember(original, null);
      expect(missing.reasons, ['团体信息不可用']);
      expect(missing.available, isFalse);
    },
  );
}
