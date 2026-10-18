import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/transfer_store.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/domain/transfer_information.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/ui/transfer_pages.dart';
import 'package:count_tools/cheki/ui/spending_page.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'bi_fixture.dart';
import 'support/settle_io.dart';

void main() {
  final visual = Platform.environment['CHEKI_COST_VISUAL'];
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
    f.source = (await f.tickets.save(
      kind: 'definition',
      operationId: 'ui-cost-def',
      information: TicketInformation({
        'scope': 'personal',
        'group_id': f.groupA,
        'member_id': f.a,
        'active': true,
      }),
    )).id;
    f.target = (await f.tickets.save(
      kind: 'definition',
      operationId: 'ui-target-def',
      information: TicketInformation({
        'scope': 'group',
        'group_id': f.groupB,
        'active': true,
      }),
    )).id;
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
    t.view.physicalSize = Size(width, 1000);
    addTearDown(t.view.reset);
    final theme = chekiTheme();
    await t.pumpWidget(
      MaterialApp(
        theme: visual == null
            ? theme
            : theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'ChekiTest'),
                appBarTheme: theme.appBarTheme.copyWith(
                  titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                    fontFamily: 'ChekiTest',
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
        home: page,
      ),
    );
    await settleIo(t);
  }

  Future<void> reach(WidgetTester t, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        finder,
        180,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await t.ensureVisible(finder);
    await settleIo(t);
  }

  void cleanMoney() {
    final text = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .join('\n');
    expect(text, isNot(contains('375/4')));
    expect(text, isNot(contains('另有金额')));
    expect(text, isNot(contains('未进入均价分母')));
    expect(text, isNot(contains('金额保留精确值')));
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (visual == null) return;
    await settleIo(t);
    await t.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await render.toImage();
      final data = await im.toByteData(format: ui.ImageByteFormat.png);
      await Directory(visual).create(recursive: true);
      await File('$visual/$name.png').writeAsBytes(data!.buffer.asUint8List());
      im.dispose();
    });
  }

  Future<TransferObject> give({bool exchange = false}) =>
      TransferStore(f.records.database, clock: () => f.clock).save(
        TransferInformation({
          'kind': exchange ? 'exchange' : 'gift',
          'quantity': 1,
          'source_definition_id': f.source,
          'source_pool': 'long',
          'occurred_on': '2026-10-14',
          if (exchange) 'target_definition_id': f.target,
          if (exchange) 'target_pool': 'long',
        }),
        posted: true,
        operationId: 'gift-${f.n++}',
      );
  for (final pair in [(320.0, 2.0), (430.0, 1.0)]) {
    testWidgets(
      'normal purchase editor saves downstream price with keyboard ${pair.$1}',
      (t) async {
        final buy = await f.buy(f.source, 4, unit: '93.75', total: '375');
        await give();
        await host(
          t,
          Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.push(
                    c,
                    MaterialPageRoute<void>(
                      builder: (_) => TicketEditPage(
                        store: f.tickets,
                        kind: 'purchase',
                        original: buy,
                      ),
                    ),
                  ),
                  child: const Text('打开购券'),
                ),
              ),
            ),
          ),
          width: pair.$1,
          scale: pair.$2,
        );
        await t.tap(find.text('打开购券'));
        await settleIo(t);
        final amount = find.byKey(const ValueKey('ticket-total_price'));
        await reach(t, amount);
        await t.enterText(amount, '400');
        t.view.viewInsets = const FakeViewPadding(bottom: 280);
        await t.pump();
        await reach(t, amount);
        cleanMoney();
        await capture(t, 'edit-${pair.$1}-keyboard');
        await t.testTextInput.receiveAction(TextInputAction.done);
        t.view.resetViewInsets();
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pump();
        await t.tap(find.text('核对'));
        await settleIo(t);
        cleanMoney();
        await capture(t, 'review-${pair.$1}');
        expect(find.text('更正成本'), findsNothing);
        await t.tap(find.text('确认保存'));
        await settleIo(t);
        expect(find.text('打开购券'), findsOneWidget);
        final m = await t.runAsync(() => f.tickets.readModel());
        final edited = m!.objects.singleWhere((x) => x.id == buy.id);
        expect(edited.information.text('total_price'), '400');
        expect(edited.unitCost!.exact, '100');
        expect(
          m.objects
              .where((x) => x.allocations.isNotEmpty)
              .single
              .allocations
              .single['cost'],
          '100',
        );
        expect(edited.information.text('unit_price'), isNull);
      },
    );
    testWidgets(
      'statistics and ticket and exchange details display yuan ${pair.$1}',
      (t) async {
        await f.buy(f.source, 4, total: '375');
        final exchange = await give(exchange: true);
        await host(
          t,
          Scaffold(
            body: BiPage(
              store: f.bi,
              records: f.records,
              initialPeriod: BiPeriod(BiScope.all, '2026-10-14'),
            ),
          ),
          width: pair.$1,
          scale: pair.$2,
        );
        await reach(t, find.text('购券与成本'));
        cleanMoney();
        await capture(t, 'statistics-${pair.$1}');
        await reach(t, find.text('购入均价'));
        expect(find.text('已知成本购入均价'), findsNothing);
        await host(
          t,
          TicketDetailPage(store: f.tickets, id: f.source),
          width: pair.$1,
          scale: pair.$2,
        );
        await reach(t, find.text('购入与库存流水'));
        cleanMoney();
        await capture(t, 'ticket-${pair.$1}');
        await host(
          t,
          TransferDetailPage(
            store: TransferStore(f.records.database, clock: () => f.clock),
            id: exchange.id,
          ),
          width: pair.$1,
          scale: pair.$2,
        );
        await reach(t, find.text('继承每张成本 94'));
        cleanMoney();
        await capture(t, 'exchange-${pair.$1}');
        expect(find.textContaining('375/4'), findsNothing);
      },
    );
  }
  testWidgets(
    'already mounted record list refreshes linked cost after purchase save',
    (t) async {
      final buy = await f.buy(f.source, 4, total: '375');
      await EntryStore(f.records.database, clock: () => f.clock).save(
        RecordInformation.fromMap({
          'quantity': 1,
          'member_ids': [f.a],
          'occurred_on': '2026-10-14',
        }),
        plan: CouponPlan({
          'mode': 'consume',
          'lines': [
            {
              'member_id': f.a,
              'definition_id': f.source,
              'quantity': 1,
              'pools': [
                {'pool': 'long', 'quantity': 1},
              ],
            },
          ],
        }),
        operationId: 'ui-cost-record',
      );
      await host(t, RecordListPage(store: f.records));
      expect(find.text('花费：¥94'), findsOneWidget);
      await t.runAsync(
        () => f.tickets.save(
          kind: 'purchase',
          original: buy,
          posted: true,
          information: TicketInformation({
            ...buy.information.toMap(),
            'total_price': '400',
          }),
          operationId: 'ui-cost-refresh',
        ),
      );
      await settleIo(t);
      expect(find.text('花费：¥100'), findsOneWidget);
      expect(find.text('花费：¥94'), findsNothing);
      await capture(t, 'record-refreshed');
    },
  );
  testWidgets(
    'unknown-only expense hides monetary card while keeping member and record',
    (t) async {
      await f.record(1, [f.a], day: '2026-10-14');
      await host(
        t,
        SpendingPage(
          store: f.bi,
          records: f.records,
          period: BiPeriod(BiScope.all, '2026-10-14'),
          member: f.a,
        ),
      );
      expect(find.byKey(const ValueKey('expense-total')), findsNothing);
      expect(find.text('晨星-A'), findsWidgets);
      expect(find.textContaining('2026-10-14 · Cheki'), findsOneWidget);
      cleanMoney();
      await capture(t, 'unknown-expense');
    },
  );
  testWidgets(
    'known plus unknown and explicit zero have clean expense totals',
    (t) async {
      await f.buy(f.source, 1, total: '0');
      await give();
      await f.record(1, [f.a], day: '2026-10-14');
      await host(
        t,
        SpendingPage(
          store: f.bi,
          records: f.records,
          period: BiPeriod(BiScope.all, '2026-10-14'),
          member: f.a,
        ),
        width: 320,
        scale: 2,
      );
      expect(find.byKey(const ValueKey('expense-total')), findsOneWidget);
      expect(find.text('花费：¥0'), findsWidgets);
      cleanMoney();
      await capture(t, 'zero-with-unknown');
    },
  );
}
