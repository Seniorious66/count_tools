import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/spending_page.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backup_test.dart' show contents;
import 'bi_fixture.dart';
import 'support/settle_io.dart';

void main() {
  final visual = Platform.environment['CHEKI_R7_VISUAL'];
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
  final all = BiPeriod(BiScope.all, '2026-10-14');
  Future<void> link() async {
    final p = await f.identities.createPerson(
      name: '同人',
      operationId: 'person',
    );
    for (final id in [f.a, f.b]) {
      final m = await f.member(id);
      await f.identities.editMember(
        original: m,
        name: m.name,
        colorRgb: m.colorRgb,
        personId: p.id,
        active: false,
        operationId: 'link-$id',
      );
    }
  }

  test(
    'headcount is distinct people, not photos, participation or catalogue size',
    () async {
      await f.record(2, [f.a, f.b]);
      await f.record(3, [f.a], day: '2026-10-12');
      await f.identities.createMember(name: 'unused', operationId: 'unused');
      final before = await contents(f.root);
      final r = (await f.bi.read()).report(all);
      expect(r.personCount, 2);
      expect(r.summary.knownQuantity, 5);
      expect(r.memberQuantity, 7);
      expect(r.personQuantity, 7);
      expect(await contents(f.root), before);
    },
  );
  test(
    'manual same-person links deduplicate even stopped historical identities',
    () async {
      await f.record(2, [f.a]);
      await f.record(3, [f.b]);
      await link();
      final before = await contents(f.root), s = await f.bi.read();
      expect(s.report(all).personCount, 1);
      expect(s.report(all).summary.knownQuantity, 5);
      expect(s.report(all, groupId: f.groupA).personCount, 1);
      expect(
        s.report(all, filter: BiRecordFilter(memberId: f.a)).personCount,
        1,
      );
      expect(await contents(f.root), before);
    },
  );
  test('unlinked identical names are two people', () async {
    final b = await f.member(f.b);
    await f.identities.editMember(
      original: b,
      name: 'A',
      colorRgb: b.colorRgb,
      personId: null,
      active: true,
      operationId: 'rename',
    );
    await f.record(2, [f.a, f.b]);
    expect((await f.bi.read()).report(all).personCount, 2);
  });
  test(
    'period, group, member and attribute filters restrict the same people',
    () async {
      await f.record(2, [f.a], day: '2026-10-11', signature: 'unsigned');
      await f.record(3, [f.b], day: '2026-10-12');
      final s = await f.bi.read();
      expect(s.report(all).personCount, 2);
      expect(s.report(BiPeriod(BiScope.day, '2026-10-11')).personCount, 1);
      expect(s.report(all, groupId: f.groupA).personCount, 1);
      expect(
        s.report(all, filter: BiRecordFilter(memberId: f.b)).personCount,
        1,
      );
      expect(
        s
            .report(all, filter: const BiRecordFilter(signature: 'unsigned'))
            .personCount,
        1,
      );
      expect(
        s.report(all, filter: BiRecordFilter(sizeId: f.five)).personCount,
        0,
      );
      expect(s.report(BiPeriod(BiScope.day, '2026-10-01')).personCount, 0);
    },
  );
  test(
    'known identity with unknown quantity counts; unknown identity does not',
    () async {
      await f.record(null, [f.a]);
      await f.record(4, null, day: null);
      final before = await contents(f.root), s = await f.bi.read();
      final day = s.report(BiPeriod(BiScope.day, '2026-10-11'));
      expect(day.personCount, 1);
      expect(day.summary.quantityLabel, '未填写');
      expect(s.report(all).personCount, 1);
      expect(s.report(all).summary.knownQuantity, 4);
      expect(await contents(f.root), before);
    },
  );
  test(
    'unresolvable historic ID is excluded from people without changing source row',
    () async {
      final row = await f.record(2, [f.a]);
      final s = await f.bi.read();
      final info = RecordInformation.fromMap({
        'quantity': 2,
        'occurred_on': '2026-10-11',
        'member_ids': [f.a, 'historic-missing'],
      });
      final raw = {...row.toRow(), 'information_json': info.encode()};
      final model = RecordReadModel(
        records: [StoredRecord.fromRow(raw)],
        groups: s.records.groups.values,
        members: s.records.members.values,
        sizes: s.records.sizes.values,
      );
      final isolated = BiSnapshot(
        model,
        s.persons,
        s.tickets,
        s.entryBindings,
        s.transferKinds,
        s.today,
      );
      expect(isolated.report(all).personCount, 1);
      expect(isolated.report(all).summary.knownQuantity, 2);
      expect(model.records.single.toRow(), raw);
    },
  );

  final boundary = GlobalKey();
  Future<void> amount() => f.records
      .save(
        RecordInformation.fromMap({
          'member_ids': [f.a],
          'quantity': 2,
          'occurred_on': '2026-10-11',
          'legacy_raw': {'id': 1, 'price': '160'},
          'legacy_source': {
            'snapshot': '20261011_102725',
            'application_id': 'com.example.count_tools',
            'mapping': 'S25-user-confirmed-20261013',
          },
        }),
        operationId: 'cost',
      )
      .then((_) {});
  Future<void> mount(
    WidgetTester t, {
    double width = 390,
    double scale = 1,
    bool management = false,
    BiPeriod? period,
    BiStore? store,
    Widget? child,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    addTearDown(t.view.reset);
    final base = chekiTheme();
    await t.pumpWidget(
      MaterialApp(
        theme: base.copyWith(
          appBarTheme: base.appBarTheme.copyWith(
            titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: visual == null ? null : 'ChekiTest',
            ),
          ),
          textTheme: base.textTheme.apply(
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
          body:
              child ??
              BiPage(
                store: store ?? f.bi,
                records: f.records,
                reportsOnly: management,
                initialPeriod: period ?? all,
              ),
        ),
      ),
    );
    await settleIo(t);
  }

  Future<void> reach(WidgetTester t, Finder target) async {
    if (target.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        target,
        150,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
    }
    await Scrollable.ensureVisible(t.element(target.first), alignment: .15);
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (visual == null) return;
    await t.runAsync(() async {
      final b =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await b.toImage(pixelRatio: 2);
      final data = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('$visual/$name.png').writeAsBytes(data!.buffer.asUint8List());
      im.dispose();
    });
  }

  final toolbar = find.byKey(const ValueKey('bi-period-options'));
  final count = find.byKey(const ValueKey('bi-person-count'));
  final expense = find.byKey(const ValueKey('expense-total'));
  Finder periodChip(String key) => find.byKey(ValueKey('bi-period-$key'));
  Future<void> choose(WidgetTester t, String key) async {
    final target = find.byKey(ValueKey(key));
    await reach(t, target);
    await t.tap(target);
    await settleIo(t);
  }

  for (final width in [320.0, 390.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'portrait toolbar, headcount and expense size $width/$scale',
        (t) async {
          await t.runAsync(() async {
            await amount();
            await f.record(3, [f.b]);
          });
          final before = await t.runAsync(() => contents(f.root));
          await mount(t, width: width, scale: scale);
          expect(find.widgetWithText(ChoiceChip, '日'), findsNothing);
          final chips = find.descendant(
            of: toolbar,
            matching: find.byType(ChoiceChip),
          );
          expect(chips, findsNWidgets(5));
          final tops = [
            for (final el in chips.evaluate())
              t.getCenter(find.byWidget(el.widget)).dy,
          ];
          expect(tops.every((dy) => (dy - tops.first).abs() < .01), isTrue);
          if (scale == 1) {
            for (final el in chips.evaluate()) {
              final rect = t.getRect(find.byWidget(el.widget));
              expect(rect.left, greaterThanOrEqualTo(16));
              expect(rect.right, lessThanOrEqualTo(width - 16));
            }
          }
          await capture(t, 'period-$width-$scale');
          await reach(t, count);
          expect(t.widget<Text>(count).data, '· 共 2 人');
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('bi-member-summary')),
              matching: find.text('5 张'),
            ),
            findsOneWidget,
          );
          await capture(t, 'summary-$width-$scale');
          for (final mode in ['member-expenses', 'group-expenses']) {
            await choose(t, mode);
            await reach(t, expense);
            final text = t.widget<Text>(expense),
                theme = Theme.of(t.element(expense));
            expect(text.style!.fontSize, theme.textTheme.bodyMedium!.fontSize);
            expect(
              text.style!.fontWeight,
              theme.textTheme.headlineLarge!.fontWeight,
            );
            expect(text.style!.color, theme.textTheme.headlineLarge!.color);
            expect(text.data, '花费：¥160');
            expect(count, findsNothing);
            await capture(t, '$mode-$width-$scale');
          }
          await choose(t, 'member-counts');
          await reach(t, count);
          expect(t.widget<Text>(count).data, '· 共 2 人');
          expect(await t.runAsync(() => contents(f.root)), before);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'historical day stays queryable without selecting today; calendar and CSV retain day',
    (t) async {
      await t.runAsync(() => f.record(2, [f.a]));
      await mount(t, period: BiPeriod(BiScope.day, '2026-10-11'));
      expect(find.widgetWithText(ChoiceChip, '日'), findsNothing);
      expect(
        t.widget<ChoiceChip>(find.byKey(const ValueKey('bi-today'))).selected,
        isFalse,
      );
      await t.tap(find.byTooltip('后一天'));
      await settleIo(t);
      expect(find.text('2026-10-12'), findsOneWidget);
      await t.tap(find.text('2026-10-12'));
      await settleIo(t);
      t
          .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
          .onDateChanged(DateTime(2026, 10, 11));
      await t.pump();
      await t.tap(find.text('确定'));
      await settleIo(t);
      expect(find.text('2026-10-11'), findsWidgets);
      final csv = (await t.runAsync(
        () => f.bi.read(),
      ))!.report(BiPeriod(BiScope.day, '2026-10-11')).csv();
      expect(csv, contains('"day"'));
      expect(csv, contains('2026-10-11'));
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'large toolbar scrolls to all and today uses click-time Shanghai day',
    (t) async {
      var now = DateTime.utc(2026, 10, 13, 15, 59);
      await mount(
        t,
        width: 320,
        scale: 2,
        store: BiStore(f.records.database, clock: () => now),
      );
      final horizontal = find.descendant(
        of: toolbar,
        matching: find.byType(Scrollable),
      );
      expect(
        t.state<ScrollableState>(horizontal).position.maxScrollExtent,
        greaterThan(0),
      );
      await t.drag(toolbar, const Offset(-700, 0));
      await settleIo(t);
      await t.tap(periodChip('all'));
      await settleIo(t);
      expect(find.text('所有时间'), findsOneWidget);
      await t.drag(toolbar, const Offset(700, 0));
      await settleIo(t);
      await t.tap(find.byKey(const ValueKey('bi-today')));
      await settleIo(t);
      expect(find.text('2026-10-13'), findsOneWidget);
      now = DateTime.utc(2026, 10, 13, 16, 1);
      await t.tap(find.byKey(const ValueKey('bi-today')));
      await settleIo(t);
      expect(find.text('2026-10-14'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'group filter updates member headcount and persists through expense modes',
    (t) async {
      await t.runAsync(() async {
        await amount();
        await f.record(3, [f.b]);
      });
      await mount(t);
      await t.tap(find.text('所有团体'));
      await settleIo(t);
      await t.tap(find.text('晨星').last);
      await settleIo(t);
      await reach(t, count);
      expect(t.widget<Text>(count).data, '· 共 1 人');
      await choose(t, 'member-expenses');
      await reach(t, expense);
      expect(t.widget<Text>(expense).data, '花费：¥160');
      await choose(t, 'member-counts');
      await reach(t, count);
      expect(t.widget<Text>(count).data, '· 共 1 人');
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('management shares single period row and small expense total', (
    t,
  ) async {
    await t.runAsync(amount);
    await mount(t, management: true, width: 320, scale: 2);
    expect(find.widgetWithText(ChoiceChip, '日'), findsNothing);
    expect(
      find.descendant(of: toolbar, matching: find.byType(ChoiceChip)),
      findsNWidgets(5),
    );
    await reach(t, expense);
    expect(t.widget<Text>(expense).style!.fontSize, 15);
    expect(count, findsNothing);
    await capture(t, 'management-320-2');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'controlled legacy spending page uses the same body size, retaining its weight',
    (t) async {
      await t.runAsync(amount);
      await mount(
        t,
        child: SpendingPage(store: f.bi, records: f.records, period: all),
        scale: 2,
      );
      await reach(t, expense);
      expect(t.widget<Text>(expense).style!.fontSize, 15);
      expect(
        t.widget<Text>(expense).style!.fontWeight,
        chekiTheme().textTheme.headlineSmall!.fontWeight,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
}
