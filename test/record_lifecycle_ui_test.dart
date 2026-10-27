import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/ui/coupon_entry.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'bi_fixture.dart';
import 'support/settle_io.dart';

void main() {
  final visual = Platform.environment['CHEKI_LIFECYCLE_VISUAL'];
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (visual != null) {
      for (final f in {
        'ChekiTest': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons':
            'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(f.key)
              ..addFont(File(f.value).readAsBytes().then(ByteData.sublistView)))
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
  Future<void> host(
    WidgetTester t,
    Widget page, {
    double width = 390,
    double scale = 1,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 950);
    addTearDown(t.view.reset);
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
        builder: (context, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: page,
      ),
    );
    await settleIo(t);
  }

  Future<void> shot(WidgetTester t, String name) async {
    expect(t.takeException(), isNull);
    if (visual == null) return;
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final b =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await b.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = File('$visual/$name.png');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> reach(WidgetTester t, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        finder,
        160,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await t.ensureVisible(finder);
    await settleIo(t);
  }

  for (final width in [320.0, 390.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'two equal options and amount keyboard portrait $width/$scale',
        (t) async {
          final c = CouponEntryController(
            store: EntryStore(f.records.database, clock: () => f.clock),
            initialMode: null,
          );
          final r = await t.runAsync(() => f.record(2, [f.a]));
          await t.runAsync(() => c.load(r!.information));
          await host(
            t,
            Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: CouponEntryEditor(
                  controller: c,
                  info: r!.information,
                  autoLoad: false,
                ),
              ),
            ),
            width: width,
            scale: scale,
          );
          final left = find.byKey(const ValueKey('use-consume')),
              right = find.byKey(const ValueKey('use-record-only'));
          expect(find.byKey(const ValueKey('use-unknown')), findsNothing);
          expect(t.getSize(left).width, t.getSize(right).width);
          expect(t.getTopLeft(left).dy, t.getTopLeft(right).dy);
          await t.tap(right);
          await t.pump();
          t.view.viewInsets = const FakeViewPadding(bottom: 300);
          final amount = find.byKey(const ValueKey('direct-amount'));
          await t.ensureVisible(amount);
          await settleIo(t);
          await t.enterText(amount, '80.50');
          expect(c.plan.directAmount!.roundedYuan, '81');
          await shot(t, 'amount-${width.toInt()}-${scale.toInt()}');
          await t.tap(left);
          await t.pump();
          expect(amount, findsNothing);
          expect(c.plan.expenseOrigin, 'coupons');
          await t.tap(right);
          await t.pump();
          expect(c.amount.text, '80.50');
          await t.pumpWidget(const SizedBox());
          c.dispose();
        },
      );
    }
  }
  testWidgets(
    'active homework selection chooses record only, user overrides, review returns draft intact',
    (t) async {
      await host(t, RecordEditPage(store: f.records));
      await reach(t, find.text('宿题'));
      await t.tap(find.text('宿题'));
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('direct-amount')));
      await t.enterText(find.byKey(const ValueKey('direct-amount')), '80.50');
      await shot(t, 'homework-direct');
      await reach(t, find.text('核对').last);
      await t.tap(find.text('核对').last);
      await settleIo(t);
      expect(find.text('实际总支出：¥81'), findsOneWidget);
      await shot(t, 'review-direct');
      await t.pageBack();
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('direct-amount')));
      expect(find.text('80.50'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('use-consume')));
      await settleIo(t);
      expect(find.byKey(const ValueKey('direct-amount')), findsNothing);
      await reach(t, find.text('带签'));
      await t.tap(find.text('带签'));
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('use-consume')));
      expect(find.byKey(const ValueKey('direct-amount')), findsNothing);
    },
  );
  testWidgets(
    'single delete cancellation keeps data, confirmed deletion returns list and excludes expense',
    (t) async {
      final r = await t.runAsync(() => f.record(1, [f.a]));
      await host(
        t,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      RecordDetailPage(store: f.records, record: r!),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('delete-record')));
      await t.tap(find.byKey(const ValueKey('delete-record')));
      await settleIo(t);
      await shot(t, 'delete-confirm');
      await t.tap(find.text('取消'));
      await settleIo(t);
      expect((await t.runAsync(() => f.records.list()))!, hasLength(1));
      await t.tap(find.byKey(const ValueKey('delete-record')));
      await settleIo(t);
      await t.tap(find.byKey(const ValueKey('confirm-delete-records')));
      await settleIo(t);
      expect(find.text('打开'), findsOneWidget);
      expect((await t.runAsync(() => f.records.list()))!, isEmpty);
    },
  );
  testWidgets(
    'bundle confirmation states whole group while individual detail deletes only one',
    (t) async {
      await t.runAsync(() async {
        await f.record(1, [f.a]);
        await f.record(1, [f.a]);
      });
      await host(t, RecordListPage(store: f.records));
      await t.tap(
        find.byKey(
          ValueKey(
            'record-${(await t.runAsync(() => f.records.list()))!.first.id}',
          ),
        ),
      );
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('delete-record-bundle')));
      await t.tap(find.byKey(const ValueKey('delete-record-bundle')));
      await settleIo(t);
      expect(find.text('删除这组合并记录？'), findsOneWidget);
      await shot(t, 'delete-bundle-confirm');
      await t.tap(find.byKey(const ValueKey('confirm-delete-records')));
      await settleIo(t);
      expect((await t.runAsync(() => f.records.list()))!, isEmpty);
    },
  );
  testWidgets('loading existing homework keeps legacy use choice unchanged', (
    t,
  ) async {
    final r = await t.runAsync(() async {
      final r = await f.record(1, [f.a], signature: 'homework');
      return EntryStore(f.records.database, clock: () => f.clock).save(
        r.information,
        original: r,
        plan: CouponPlan({'mode': null}),
        operationId: 'old-homework',
      );
    });
    await host(t, RecordEditPage(store: f.records, original: r));
    await reach(t, find.byKey(const ValueKey('use-record-only')));
    expect(find.byKey(const ValueKey('direct-amount')), findsNothing);
    expect(
      (await t.runAsync(
        () => EntryStore(f.records.database).state(r!.id),
      ))!.plan.mode,
      isNull,
    );
  });
  testWidgets(
    'review shows one explicit source instead of old amount preview',
    (t) async {
      final r = await t.runAsync(() => f.record(2, [f.a]));
      final info = r!.information.patch({
        'legacy_source': {
          'snapshot': '20261011_102725',
          'application_id': 'com.example.count_tools',
          'mapping': 'S25-user-confirmed-20261013',
        },
        'legacy_raw': {'id': 1, 'price': '120'},
      });
      final plan = CouponPlan({
        'mode': 'record_only',
        'expense_origin': 'direct',
        'direct_amount': '80.50',
      });
      final store = EntryStore(f.records.database, clock: () => f.clock);
      await host(
        t,
        Scaffold(
          body: Column(
            children: [
              CouponPlanView(plan: plan, store: store),
              CouponCostPreview(info: info, plan: plan, store: store),
            ],
          ),
        ),
      );
      expect(find.text('实际总支出：¥81'), findsOneWidget);
      expect(find.textContaining('120'), findsNothing);
    },
  );
  testWidgets(
    'deleting an original row leaves the rest of merged group intact',
    (t) async {
      final rows = await t.runAsync(
        () async => [
          await f.record(1, [f.a]),
          await f.record(1, [f.a]),
        ],
      );
      final targetId = (await t.runAsync(() => f.records.list()))!.first.id;
      await host(t, RecordListPage(store: f.records));
      await t.tap(find.byKey(ValueKey('record-$targetId')));
      await settleIo(t);
      await t.tap(find.byKey(ValueKey('record-$targetId')));
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('delete-record')));
      await t.tap(find.byKey(const ValueKey('delete-record')));
      await settleIo(t);
      await t.tap(find.byKey(const ValueKey('confirm-delete-records')));
      await settleIo(t);
      final remaining = (await t.runAsync(() => f.records.list()))!;
      expect(
        remaining.map((r) => r.id),
        rows!.where((r) => r.id != targetId).map((r) => r.id),
      );
      expect(
        find.byKey(ValueKey('record-${remaining.single.id}')),
        findsOneWidget,
      );
    },
  );
}
