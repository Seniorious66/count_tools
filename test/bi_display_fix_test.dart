import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/member_pie.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'bi_fixture.dart';
import 'backup_test.dart' show contents;
import 'transport_ui_test.dart' show settleIo;

void main() {
  final visual = Platform.environment['CHEKI_BI_FIX_VISUAL'];
  final boundary = GlobalKey();
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (visual != null) {
      final font = FontLoader('ChekiTest')
        ..addFont(
          File(
            'C:/Windows/Fonts/msyh.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });
  late BiFixture f;
  setUp(() async {
    f = BiFixture();
    await f.open();
  });
  tearDown(() => f.close());
  final pie = find.byType(MemberPie);
  Future<void> mount(
    WidgetTester t, {
    double width = 390,
    double scale = 1,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    final theme = chekiTheme();
    await t.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(
            fontFamily: visual == null ? null : 'ChekiTest',
          ),
          appBarTheme: theme.appBarTheme.copyWith(
            titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: visual == null ? null : 'ChekiTest',
            ),
          ),
        ),
        builder: (c, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: BiPage(
            store: f.bi,
            records: f.records,
            initialPeriod: BiPeriod(BiScope.month, '2026-10-14'),
          ),
        ),
      ),
    );
    await settleIo(t);
  }

  Future<void> reveal(
    WidgetTester t,
    Finder target, {
    double delta = 240,
  }) async {
    if (target.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        target,
        delta,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 80,
      );
    }
    await Scrollable.ensureVisible(t.element(target.first), alignment: 0.1);
    await settleIo(t);
  }

  Future<void> tap(WidgetTester t, Finder target, {double delta = 240}) async {
    await reveal(t, target, delta: delta);
    await t.tap(target.first);
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (visual == null) return;
    if (name.startsWith('many-') && !name.endsWith('-last')) {
      await reveal(t, find.text('成员占比'), delta: -240);
    }
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await render.toImage(pixelRatio: 1),
          bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('$visual/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  }

  testWidgets(
    'member shares use participation9 not physical7, no sorting or receipt panel, raw archive and CSV unchanged',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(f.quantities);
      final before = await t.runAsync(() => contents(f.root));
      await mount(t);
      await reveal(t, pie);
      final chart = t.widget<MemberPie>(pie);
      expect(chart.denominator, 9);
      expect(chart.slices.map((s) => s.quantity), [5, 4]);
      expect(find.semantics.byLabel('晨星-A · 5 张 · 55.6%'), findsOneWidget);
      expect(find.semantics.byLabel('夜航-B · 4 张 · 44.4%'), findsOneWidget);
      expect(chart.slices.first.color, const Color(0xff123456));
      expect(chart.slices.last.color, Colors.white);
      expect(find.text('按姓名排序'), findsNothing);
      expect(find.text('按张数排序'), findsNothing);
      final visibleLabels = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .join('\n');
      expect(visibleLabels, isNot(contains('已知已领')));
      expect(visibleLabels, isNot(contains('待领 4 张')));
      await capture(t, 'shares-390');
      final report = (await t.runAsync(
        f.bi.read,
      ))!.report(BiPeriod(BiScope.month, '2026-10-14'));
      expect(report.receipts, {'unreceived': 3, 'received': 2, 'partial': 2});
      expect(report.csv(), contains('"member","${f.a}","晨星-A","","5","7"'));
      expect(await t.runAsync(() => contents(f.root)), before);
    },
  );
  for (final days in [0, 1, 5, 6, 16]) {
    testWidgets(
      '$days dates: five-row summary, complete timeline pie and original all-date drill',
      (t) async {
        addTearDown(t.view.reset);
        await t.runAsync(() async {
          for (var d = 1; d <= days; d++) {
            await f.record(1, [
              f.a,
            ], day: '2026-10-${d.toString().padLeft(2, '0')}');
          }
        });
        await mount(t);
        final daily = find.byKey(const ValueKey('bi-daily-section'));
        await reveal(t, daily);
        expect(
          find.descendant(of: daily, matching: find.byType(ListTile)),
          findsNWidgets(days > 5 ? 5 : days),
        );
        expect(
          find.byKey(const ValueKey('bi-all-days')),
          days > 5 ? findsOneWidget : findsNothing,
        );
        if (days > 0) {
          final semantics = t.widgetList<Semantics>(
            find.descendant(of: daily, matching: find.byType(Semantics)),
          );
          expect(
            semantics.any(
              (s) => s.properties.label?.contains('趋势，$days个日期') == true,
            ),
            true,
          );
        }
        if (days == 6) {
          await reveal(t, find.text('每日张数'));
          await capture(t, 'six-dates-daily');
        }
        await reveal(t, pie);
        expect(t.widget<MemberPie>(pie).denominator, days);
        if (days == 6) await capture(t, 'six-dates-shares');
        if (days > 5) {
          await tap(t, find.byKey(const ValueKey('bi-all-days')), delta: -240);
          await tap(t, find.text('2026-10-01'));
          expect(find.textContaining('1 张 · 2026-10-01'), findsOneWidget);
        }
      },
    );
  }
  testWidgets(
    'fixed quantity order and same-person mode use the existing shared report',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        final person = await f.identities.createPerson(
          name: '同一成员',
          operationId: 'bi-fix-person',
        );
        for (final id in [f.a, f.b]) {
          final member = await f.member(id);
          await f.identities.editMember(
            original: member,
            name: member.name,
            colorRgb: member.colorRgb,
            personId: person.id,
            active: true,
            operationId: 'link-$id',
          );
        }
        await f.record(1, [f.a]);
        // Both identities are active: make recency explicit instead of relying
        // on random stable-ID ordering for two records on the same day.
        await f.record(10, [f.b], day: '2026-10-12');
      });
      await mount(t);
      await reveal(t, pie);
      expect(find.widgetWithText(ChoiceChip, '同人关联'), findsNothing);
      final chart = t.widget<MemberPie>(pie);
      expect(chart.denominator, 11);
      expect(chart.slices.length, 1);
      expect(chart.slices.single.label, '夜航-B');
      expect(find.semantics.byLabel('夜航-B · 11 张 · 100.0%'), findsOneWidget);
      await capture(t, 'person-share');
    },
  );
  testWidgets(
    'all five periods and group filtering update pie and bars together',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(f.quantities);
      await mount(t);
      for (final entry in {'日': 0, '周': 0, '月': 9, '年': 9, '所有': 9}.entries) {
        await tap(t, find.widgetWithText(ChoiceChip, entry.key), delta: -240);
        await reveal(t, pie);
        expect(t.widget<MemberPie>(pie).denominator, entry.value);
      }
      await tap(t, find.text('所有团体'), delta: -240);
      await tap(t, find.text('晨星').last);
      await reveal(t, pie);
      expect(t.widget<MemberPie>(pie).denominator, 5);
      expect(t.widget<MemberPie>(pie).slices.single.id, f.a);
      expect(find.semantics.byLabel('晨星-A · 5 张 · 100.0%'), findsOneWidget);
    },
  );
  testWidgets(
    'receipt filter survives panel removal; edits and management-return colour invalidation refresh the chart',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(f.quantities);
      await mount(t);
      await tap(t, find.text('更多筛选'));
      final field = find.byKey(const ValueKey('领取:null'));
      await tap(t, field);
      await tap(t, find.text('已领取').last);
      await reveal(t, pie);
      expect(t.widget<MemberPie>(pie).denominator, 2);
      expect(t.widget<MemberPie>(pie).slices.single.id, f.b);
      await reveal(t, find.text('更多筛选'), delta: -240);
      // The existing tile can be rebuilt collapsed when scrolled out of view.
      // Reopen it through the same user entry before clearing its filters.
      if (find.text('清除更多筛选').evaluate().isEmpty) {
        await tap(t, find.text('更多筛选'));
      }
      await tap(t, find.text('清除更多筛选'));
      await reveal(t, pie);
      expect(t.widget<MemberPie>(pie).denominator, 9);
      await t.runAsync(() async {
        final r = (await f.records.list()).singleWhere(
          (r) => r.information.quantity == 3,
        );
        await f.records.save(
          r.information.patch({'occurred_on': '2026-09-11'}),
          original: r,
          operationId: 'bi-fix-edit',
        );
        final member = await f.member(f.a);
        await f.identities.editMember(
          original: member,
          name: member.name,
          colorRgb: 0xff88aa,
          personId: member.personId,
          active: true,
          operationId: 'bi-fix-color',
        );
        // This is the same invalidation emitted on return from real management.
        RecordStore.invalidateReads();
      });
      await settleIo(t);
      await reveal(t, pie);
      expect(t.widget<MemberPie>(pie).denominator, 6);
      expect(
        t.widget<MemberPie>(pie).slices.singleWhere((s) => s.id == f.a).color,
        const Color(0xffff88aa),
      );
    },
  );
  testWidgets(
    'unknown counts are never zero-percent sectors and an empty report has no fake full circle',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(() => f.record(null, [f.a]));
      await mount(t);
      await reveal(t, pie);
      expect(find.byKey(const ValueKey('bi-pie-paint')), findsNothing);
      expect(find.text('暂无可统计张数'), findsOneWidget);
      expect(
        find.semantics.byLabel('晨星-A · 张数未填写 · — · 1 条张数未填写'),
        findsOneWidget,
      );
      await capture(t, 'unknown-only');
      await t.runAsync(() => f.record(2, [f.b]));
      await settleIo(t);
      await reveal(t, pie);
      expect(t.widget<MemberPie>(pie).denominator, 2);
      expect(
        find.semantics.byLabel('晨星-A · 张数未填写 · — · 1 条张数未填写'),
        findsOneWidget,
      );
      expect(find.semantics.byLabel('夜航-B · 2 张 · 100.0%'), findsOneWidget);
      await capture(t, 'unknown-shares');
    },
  );
  testWidgets(
    'many long member names, white sectors, portrait widths and large-font legend remain readable and semantic',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(f.quantities);
      await t.runAsync(() async {
        for (var i = 0; i < 24; i++) {
          final member = await f.identities.createMember(
            name: '很长的成员名称-$i-longname',
            groupId: f.groupA,
            colorRgb: i % 2 == 0 ? 0xffffff : 0x99ccff,
            operationId: 'long-$i',
          );
          await f.record(1, [member.id]);
        }
      });
      final semantics = t.ensureSemantics();
      for (final width in [320.0, 360.0, 390.0, 430.0]) {
        await mount(t, width: width);
        await reveal(t, pie);
        expect(t.widget<MemberPie>(pie).slices.length, 26);
        expect(find.semantics.byLabel(RegExp(r'晨星-A · 5 张 ·')), findsOneWidget);
        expect(t.takeException(), isNull);
        await capture(t, 'many-${width.toInt()}');
        await t.pumpWidget(const SizedBox());
        await settleIo(t);
      }
      await mount(t, width: 320, scale: 2);
      await reveal(t, pie);
      await capture(t, 'many-320-large');
      final last = t.widget<MemberPie>(pie).slices.last;
      expect(
        find.semantics.byLabel(
          last.description(t.widget<MemberPie>(pie).denominator),
        ),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('bi-pie-legend-${last.id}')), findsNothing);
      expect(t.takeException(), isNull);
      await capture(t, 'many-320-large-last');
      semantics.dispose();
    },
  );
}
