import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/spending_panel.dart';
import 'package:count_tools/cheki/ui/spending_page.dart';
import 'package:count_tools/cheki/ui/member_pie.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'bi_fixture.dart';
import 'transport_ui_test.dart' show settleIo;
import 'backup_test.dart' show contents;

void main() {
  final visual = Platform.environment['CHEKI_R5_VISUAL'];
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (visual != null) {
      for (final pair in [
        ('ChekiTest', 'C:/Windows/Fonts/msyh.ttc'),
        (
          'MaterialIcons',
          'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
      ]) {
        final f = FontLoader(pair.$1)
          ..addFont(File(pair.$2).readAsBytes().then(ByteData.sublistView));
        await f.load();
      }
    }
  });
  late BiFixture f;
  late String person;
  final boundary = GlobalKey();
  setUp(() async {
    f = BiFixture();
    await f.open();
    await f.record(3, [f.a]);
    await f.record(2, [f.b]);
    await f.record(15, null);
    final p = await f.identities.createPerson(
      name: '不显示内部同人名',
      operationId: 'person',
    );
    person = p.id;
    for (final id in [f.a, f.b]) {
      final m = await f.member(id);
      await f.identities.editMember(
        original: m,
        name: m.name,
        colorRgb: m.colorRgb,
        personId: p.id,
        active: id == f.b,
        operationId: 'link-$id',
      );
    }
  });
  tearDown(() => f.close());
  Future<void> mount(WidgetTester t, double width, double scale) async {
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
            initialPeriod: BiPeriod(BiScope.all, '2026-10-14'),
          ),
        ),
      ),
    );
    await settleIo(t);
  }

  Future<void> reach(WidgetTester t, Finder target, {double step = 180}) async {
    await t.scrollUntilVisible(
      target,
      step,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 80,
    );
    await Scrollable.ensureVisible(t.element(target.first), alignment: .15);
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (visual == null) return;
    await t.runAsync(() async {
      final r =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await r.toImage(pixelRatio: 1),
          data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$visual/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final width in [320.0, 390.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'inline toggles and linked rows use global20 at $width x$scale',
        (t) async {
          final before = await t.runAsync(() => contents(f.root));
          await mount(t, width, scale);
          final member = find.byKey(const ValueKey('member-expenses')),
              group = find.byKey(const ValueKey('group-expenses'));
          await reach(t, group);
          await t.tap(group);
          await settleIo(t);
          expect(t.widget<ChoiceChip>(group).selected, isTrue);
          expect(find.byType(SpendingPage), findsNothing);
          await reach(t, member, step: -160);
          await t.tap(member);
          await settleIo(t);
          expect(t.widget<ChoiceChip>(member).selected, isTrue);
          expect(find.byType(SpendingPanel), findsOneWidget);
          final linked = find.byKey(ValueKey('bi-linked-person:$person'));
          await reach(t, linked);
          await t.tap(linked);
          await settleIo(t);
          await reach(t, find.text('晨星-A'));
          expect(find.text('3 张 · 15.0%'), findsOneWidget);
          expect(find.text('2 张 · 10.0%'), findsOneWidget);
          expect(find.text('5 张 · 25.0%'), findsOneWidget);
          expect(find.text('不显示内部同人名'), findsNothing);
          final bars = t
              .widgetList<FractionallySizedBox>(
                find.descendant(
                  of: linked,
                  matching: find.byType(FractionallySizedBox),
                ),
              )
              .map((b) => b.widthFactor);
          expect(bars, containsAll([.25, .15, .1]));
          await capture(t, 'linked-${width.toInt()}-${(scale * 100).toInt()}');
          expect(t.takeException(), isNull);
          final chart = find.byType(MemberPie);
          await reach(t, chart);
          expect(t.widget<MemberPie>(chart).denominator, 5);
          expect(await t.runAsync(() => contents(f.root)), before);
        },
      );
    }
  }
}
