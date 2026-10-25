import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/member_pie.dart';
import 'package:count_tools/cheki/ui/spending_panel.dart';
import 'package:count_tools/cheki/ui/statistics_style.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'bi_fixture.dart';
import 'backup_test.dart' show contents;
import 'support/settle_io.dart';

class _Canvas implements Canvas {
  final calls = <Invocation>[];
  @override
  dynamic noSuchMethod(Invocation i) {
    calls.add(i);
    return null;
  }
}

void main() {
  final visual = Platform.environment['CHEKI_R6_VISUAL'];
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (visual != null) {
      for (final font in {
        'ChekiTest': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons':
            'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(font.value).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
    }
  });
  late BiFixture f;
  setUp(() async {
    f = BiFixture();
    await f.open();
  });
  tearDown(() => f.close());
  final boundary = GlobalKey();
  final body = find.byKey(const ValueKey('bi-statistics-body'));
  Future<void> amount(String member, int q, String? price) => f.records
      .save(
        RecordInformation.fromMap({
          'member_ids': [member],
          'quantity': q,
          'occurred_on': '2026-10-11',
          'legacy_raw': {'id': 1, 'price': price},
          'legacy_source': {
            'snapshot': '20261011_102725',
            'application_id': 'com.example.count_tools',
            'mapping': 'S25-user-confirmed-20261013',
          },
        }),
        operationId: 'amount-${f.n++}',
      )
      .then((_) {});
  Future<void> mount(
    WidgetTester t, {
    double width = 390,
    double scale = 1,
    bool management = false,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    addTearDown(t.view.reset);
    final theme = chekiTheme();
    await t.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(
            fontFamily: visual == null ? null : 'ChekiTest',
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
            reportsOnly: management,
            initialPeriod: BiPeriod(BiScope.all, '2026-10-14'),
          ),
        ),
      ),
    );
    await settleIo(t);
  }

  Future<void> reach(WidgetTester t, Finder finder, {double step = 150}) async {
    if (finder.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        finder,
        step,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 80,
      );
    }
    await Scrollable.ensureVisible(t.element(finder.first), alignment: .12);
    await settleIo(t);
  }

  Future<void> choose(WidgetTester t, String key) async {
    final chip = find.byKey(ValueKey(key));
    await reach(t, chip);
    await t.tap(chip);
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String label) async {
    if (visual == null) return;
    await t.runAsync(() async {
      final r =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await r.toImage(pixelRatio: 2);
      final data = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('$visual/$label.png').writeAsBytes(data!.buffer.asUint8List());
      im.dispose();
    });
  }

  for (final width in [320.0, 390.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('one shared area and three exclusive views $width x$scale', (
        t,
      ) async {
        await t.runAsync(() async {
          await amount(f.a, 3, '240');
          await amount(f.b, 2, '160');
          await f.record(15, null);
        });
        final before = await t.runAsync(() => contents(f.root));
        await mount(t, width: width, scale: scale);
        for (final mode in [
          'member-counts',
          'member-expenses',
          'group-expenses',
          'member-counts',
        ]) {
          await choose(t, mode);
          final chips = t
              .widgetList<ChoiceChip>(
                find.descendant(
                  of: find.byKey(const ValueKey('bi-view-selector')),
                  matching: find.byType(ChoiceChip),
                ),
              )
              .toList();
          expect(chips.length, 3);
          expect(chips.where((c) => c.selected).length, 1);
          expect(
            find.descendant(of: body, matching: find.byType(ChoiceChip)),
            findsNothing,
          );
          expect(
            t.getTopLeft(body).dy -
                t
                    .getBottomLeft(
                      find.byKey(const ValueKey('bi-view-selector')),
                    )
                    .dy,
            closeTo(12, .01),
          );
          final counts = find.byKey(const ValueKey('bi-view-members'));
          final members = find.byKey(const ValueKey('bi-view-memberExpenses'));
          final groups = find.byKey(const ValueKey('bi-view-groupExpenses'));
          expect(
            counts,
            mode == 'member-counts' ? findsOneWidget : findsNothing,
          );
          expect(
            members,
            mode == 'member-expenses' ? findsOneWidget : findsNothing,
          );
          expect(
            groups,
            mode == 'group-expenses' ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(SpendingPanel),
            mode == 'member-counts' ? findsNothing : findsOneWidget,
          );
          if (mode == 'member-counts') {
            expect(
              find.descendant(of: body, matching: find.text('20 张')),
              findsOneWidget,
            );
            expect(
              find.descendant(of: body, matching: find.text('3 张 · 15.0%')),
              findsOneWidget,
            );
            final bars = t
                .widgetList<Container>(
                  find.descendant(of: body, matching: find.byType(Container)),
                )
                .where((c) => c.decoration is BoxDecoration)
                .map((c) => c.decoration! as BoxDecoration)
                .where((d) => d.color == Colors.white && d.border != null);
            expect(
              bars.any(
                (d) =>
                    (d.border! as Border).top ==
                    const BorderSide(color: Colors.black, width: .5),
              ),
              isTrue,
            );
          } else {
            expect(
              find.descendant(of: body, matching: find.text('花费：¥400')),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: body,
                matching: find.byType(FractionallySizedBox),
              ),
              findsNothing,
            );
          }
          await capture(t, '$mode-${width.toInt()}-${(scale * 100).toInt()}');
          expect(t.takeException(), isNull);
        }
        final pie = find.byType(MemberPie);
        await reach(t, pie);
        await capture(t, 'pie-${width.toInt()}-${(scale * 100).toInt()}');
        expect(t.widget<MemberPie>(pie).denominator, 5);
        expect(await t.runAsync(() => contents(f.root)), before);
      });
    }
  }
  testWidgets(
    'group date filters and selection survive mode switch and record return',
    (t) async {
      await t.runAsync(() async {
        await amount(f.a, 3, '240');
        await amount(f.b, 2, '160');
      });
      await mount(t);
      await t.tap(find.text('所有团体'));
      await settleIo(t);
      await t.tap(find.text('晨星').last);
      await settleIo(t);
      await choose(t, 'member-expenses');
      expect(
        t.widget<Text>(find.byKey(const ValueKey('expense-total'))).data,
        '花费：¥240',
      );
      final member = find.byKey(ValueKey('expense-member-${f.a}'));
      await reach(t, member);
      await t.tap(member);
      await settleIo(t);
      final line = find
          .byWidgetPredicate(
            (w) =>
                w is ListTile &&
                w.key.toString().contains('expense-line-record:'),
          )
          .first;
      await reach(t, line);
      await t.tap(line);
      await settleIo(t);
      await t.pageBack();
      await settleIo(t);
      await choose(t, 'group-expenses');
      expect(
        t.widget<Text>(find.byKey(const ValueKey('expense-total'))).data,
        '花费：¥240',
      );
      await choose(t, 'member-counts');
      expect(
        find.descendant(of: body, matching: find.text('3 张')),
        findsOneWidget,
      );
      await reach(t, find.byKey(const ValueKey('bi-today')), step: -150);
      await t.tap(find.byKey(const ValueKey('bi-today')));
      await settleIo(t);
      await choose(t, 'member-expenses');
      expect(find.byKey(const ValueKey('expense-total')), findsNothing);
      expect(
        t
            .widget<ChoiceChip>(find.byKey(const ValueKey('member-expenses')))
            .selected,
        isTrue,
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('unknown costs stay hidden and explicit zero remains visible', (
    t,
  ) async {
    await t.runAsync(() => amount(f.a, 1, null));
    await mount(t);
    await choose(t, 'member-expenses');
    expect(find.byKey(const ValueKey('expense-total')), findsNothing);
    await t.runAsync(() => amount(f.b, 1, '0'));
    await settleIo(t);
    await choose(t, 'group-expenses');
    expect(
      t.widget<Text>(find.byKey(const ValueKey('expense-total'))).data,
      '花费：¥0',
    );
    expect(find.textContaining('另有金额未填写'), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets('management keeps its independent expense controls and CSV', (
    t,
  ) async {
    await t.runAsync(() => amount(f.a, 1, '50'));
    await mount(t, management: true);
    expect(find.byKey(const ValueKey('bi-view-selector')), findsNothing);
    await choose(t, 'group-expenses');
    expect(find.byType(SpendingPanel), findsOneWidget);
    await reach(t, find.text('导出花费明细'));
    expect(find.text('导出花费明细'), findsOneWidget);
  });
  testWidgets('spending marker preserves white fill and thin black edge', (
    t,
  ) async {
    await t.runAsync(() => amount(f.b, 1, '80'));
    await mount(t, scale: 2);
    await choose(t, 'member-expenses');
    final dot = find.byType(StatisticsDot);
    expect(dot, findsOneWidget);
    final box = t.widget<Container>(
      find.descendant(of: dot, matching: find.byType(Container)),
    );
    final decoration = box.decoration! as BoxDecoration;
    expect(decoration.color, Colors.white);
    expect(
      (decoration.border! as Border).top,
      const BorderSide(color: Colors.black, width: .5),
    );
    expect(box.constraints!.maxWidth, 12);
  });
  testWidgets('daily trend retains values and outlines the data points', (
    t,
  ) async {
    await t.runAsync(() async {
      await f.record(3, [f.a]);
      await f.record(1, [f.b], day: '2026-10-12');
    });
    await mount(t);
    final plot = find.byKey(const ValueKey('bi-daily-paint'));
    await reach(t, plot);
    final painter = t.widget<CustomPaint>(plot).painter!;
    final canvas = _Canvas();
    painter.paint(canvas, const Size(300, 120));
    final circles = canvas.calls
        .where((i) => i.memberName == #drawCircle)
        .toList();
    expect(circles.length, 4);
    expect(circles[0].positionalArguments[0], const Offset(8, 8));
    expect(circles[2].positionalArguments[0], Offset(292, 112 - 104 / 3));
    for (final index in [0, 2]) {
      expect(
        (circles[index].positionalArguments.last as Paint).color.toARGB32(),
        ChekiColors.blueInk.toARGB32(),
      );
      final outline = circles[index + 1].positionalArguments.last as Paint;
      expect(outline.color, Colors.black);
      expect(outline.strokeWidth, .5);
    }
  });
  test(
    'white tiny and same-color sectors retain exact sweeps with hairline edges',
    () {
      final slices = [
        const MemberPieSlice('a', 'A', 999, 0, Colors.white),
        const MemberPieSlice('b', 'B', 1, 0, Colors.white),
      ];
      final c = _Canvas();
      MemberPiePainter(
        slices,
        1000,
        selected: 'a',
      ).paint(c, const Size(300, 300));
      final arcs = c.calls.where((i) => i.memberName == #drawArc).toList();
      expect(arcs.length, 2);
      expect(arcs.first.positionalArguments[2], 2 * math.pi * 999 / 1000);
      expect(arcs.last.positionalArguments[2], 2 * math.pi / 1000);
      for (final a in arcs) {
        final p = a.positionalArguments.last as Paint;
        expect(p.color, Colors.white);
        expect(p.style, PaintingStyle.fill);
      }
      final outlines = c.calls
          .where((i) => i.memberName == #drawLine || i.memberName == #drawOval)
          .toList();
      expect(outlines.length, 3);
      for (final a in outlines) {
        final p = a.positionalArguments.last as Paint;
        expect(p.color, Colors.black);
        expect(p.strokeWidth, .5);
        expect(p.style, PaintingStyle.stroke);
      }
    },
  );
  test('zero denominator never paints a fabricated sector', () {
    final c = _Canvas();
    MemberPiePainter([
      const MemberPieSlice('a', 'A', 0, 1, Colors.white),
    ], 0).paint(c, const Size(300, 300));
    expect(c.calls, isEmpty);
  });
  test(
    'single white sector outline stays thin under large text and selection',
    () {
      final c = _Canvas();
      MemberPiePainter(
        [const MemberPieSlice('a', 'A', 1, 0, Colors.white)],
        1,
        scaler: TextScaler.linear(2),
        selected: 'a',
      ).paint(c, const Size(300, 300));
      final o = c.calls.where((i) => i.memberName == #drawOval).toList();
      expect(o.length, 2);
      expect((o.first.positionalArguments.last as Paint).color, Colors.white);
      final p = o.last.positionalArguments.last as Paint;
      expect(p.color, Colors.black);
      expect(p.strokeWidth, .5);
    },
  );
}
