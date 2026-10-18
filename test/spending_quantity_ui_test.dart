import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/transfer_store.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/ui/member_inputs.dart';
import 'package:count_tools/cheki/ui/quantity_stepper.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/ui/transfer_pages.dart';
import 'package:count_tools/cheki/ui/spending_page.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'bi_fixture.dart';
import 'support/settle_io.dart';

void main() {
  final visual = Platform.environment['CHEKI_SPENDING_VISUAL'];
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
    Widget child, {
    double width = 390,
    double scale = 1,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    addTearDown(t.view.reset);
    final theme = chekiTheme();
    await t.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          appBarTheme: theme.appBarTheme.copyWith(
            titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: visual == null ? null : 'ChekiTest',
            ),
          ),
          textTheme: theme.textTheme.apply(
            fontFamily: visual == null ? null : 'ChekiTest',
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
        home: child,
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
    await t.pumpAndSettle();
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (visual == null) return;
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final im =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('$visual/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  }

  testWidgets(
    'stepper blank positive limits invalid clear and semantic actions at narrow large text',
    (t) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      await host(
        t,
        Scaffold(
          body: QuantityStepper(controller: c, fieldKey: const ValueKey('q')),
        ),
        width: 320,
        scale: 2,
      );
      IconButton button(String label) => t.widget<IconButton>(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == label),
      );
      expect(button('减少一张').onPressed, isNull);
      await t.tap(find.byTooltip('增加一张'));
      await t.pump();
      expect(c.text, '1');
      await t.tap(find.byTooltip('增加一张'));
      await t.pump();
      expect(c.text, '2');
      await t.tap(find.byTooltip('减少一张'));
      await t.pump();
      expect(c.text, '1');
      await t.enterText(find.byKey(const ValueKey('q')), '2.5');
      await t.pump();
      expect(button('增加一张').onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('q')), '1000000000');
      await t.pump();
      expect(button('增加一张').onPressed, isNull);
      await t.tap(find.byTooltip('清空张数'));
      await t.pump();
      expect(c.text, '');
      expect(t.takeException(), isNull);
      await capture(t, 'stepper-320-200');
    },
  );
  testWidgets(
    'actual record stepper uses the same controller and editable keyboard',
    (t) async {
      await host(t, RecordEditPage(store: f.records), width: 320, scale: 2);
      await reach(t, find.byKey(const ValueKey('record-quantity')));
      await t.tap(find.byTooltip('增加一张').first);
      await settleIo(t);
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('record-quantity')))
            .controller!
            .text,
        '2',
      );
      await t.enterText(find.byKey(const ValueKey('record-quantity')), '3');
      await settleIo(t);
      await t.tap(find.byTooltip('减少一张').first);
      await settleIo(t);
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('record-quantity')))
            .controller!
            .text,
        '2',
      );
      await capture(t, 'record-320-200');
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('record-quantity')));
      await capture(t, 'record-keyboard-320-200');
      t.view.resetViewInsets();
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'purchase stepper keeps total amount and blank remains a draft option',
    (t) async {
      await host(
        t,
        TicketEditPage(store: f.tickets, kind: 'purchase'),
        width: 320,
        scale: 2,
      );
      await reach(t, find.byKey(const ValueKey('ticket-quantity')));
      await t.tap(find.byTooltip('增加一张'));
      await t.pump();
      await t.tap(find.byTooltip('增加一张'));
      await t.pump();
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('ticket-quantity')))
            .controller!
            .text,
        '2',
      );
      await reach(t, find.byKey(const ValueKey('ticket-total_price')));
      await t.enterText(
        find.byKey(const ValueKey('ticket-total_price')),
        '100',
      );
      await reach(t, find.byKey(const ValueKey('ticket-quantity')));
      await t.tap(find.byTooltip('增加一张'));
      await t.pump();
      await reach(t, find.byKey(const ValueKey('ticket-total_price')));
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('ticket-total_price')))
            .controller!
            .text,
        '100',
      );
      await capture(t, 'purchase-320-200');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'exchange has automatic source and long destination; defaults do not alter old draft',
    (t) async {
      await t.runAsync(() => f.finances());
      final store = TransferStore(f.records.database, clock: () => f.clock);
      await host(t, TransferEditPage(store: store, sourceDefinition: f.source));
      expect(
        find.byKey(const ValueKey('transfer-source-pool-long')),
        findsOneWidget,
      );
      await reach(t, find.byKey(const ValueKey('transfer-target-pool-long')));
      expect(
        find.byKey(const ValueKey('transfer-target-pool-long')),
        findsOneWidget,
      );
      await capture(t, 'exchange-defaults');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'member and group entry drill expense details and original record without doubling purchases',
    (t) async {
      await t.runAsync(() => f.finances());
      await host(
        t,
        Scaffold(
          body: BiPage(
            store: f.bi,
            records: f.records,
            initialPeriod: BiPeriod(BiScope.all, '2026-10-14'),
          ),
        ),
      );
      await reach(t, find.byKey(const ValueKey('member-expenses')));
      await t.tap(find.byKey(const ValueKey('member-expenses')));
      await settleIo(t);
      expect(find.byType(SpendingPage), findsOneWidget);
      expect(find.text('未分配到成员'), findsOneWidget);
      await capture(t, 'expenses-overview');
      await reach(t, find.byKey(ValueKey('expense-member-${f.b}')));
      await t.tap(find.byKey(ValueKey('expense-member-${f.b}')));
      await settleIo(t);
      expect(find.byKey(const ValueKey('expense-total')), findsOneWidget);
      final title = t.widget<Text>(find.byKey(const ValueKey('expense-total')));
      expect(title.data, '花费：¥30');
      await capture(t, 'member-expenses');
      final tile = find.byWidgetPredicate(
        (w) =>
            w is ListTile && w.key.toString().contains('expense-line-record:'),
      );
      await reach(t, tile.first);
      await t.tap(tile.first);
      await settleIo(t);
      expect(find.byType(RecordDetailPage), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'group expense narrow large text renders and exports exact underlying amounts',
    (t) async {
      await t.runAsync(() => f.finances());
      String? csv;
      await host(
        t,
        SpendingPage(
          store: f.bi,
          records: f.records,
          period: BiPeriod(BiScope.all, '2026-10-14'),
          groups: true,
          group: f.groupA,
          exportCsv: (value) async {
            csv = value;
            return true;
          },
        ),
        width: 320,
        scale: 2,
      );
      expect(
        t.widget<Text>(find.byKey(const ValueKey('expense-total'))).data,
        '花费：¥30',
      );
      await capture(t, 'group-expenses-320-200');
      t.view.physicalSize = const Size(430, 1000);
      await t.pumpAndSettle();
      await capture(t, 'group-expenses-430-200');
      await reach(t, find.text('导出花费明细'));
      await t.tap(find.text('导出花费明细'));
      await settleIo(t);
      expect(csv, contains('"amount_decimal"'));
      expect(csv, contains('"赠送"'));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'actual select-member then step quantity updates automatic pool and specific shortage',
    (t) async {
      await t.runAsync(() async {
        final d = await f.tickets.save(
          kind: 'definition',
          information: TicketInformation({
            'scope': 'personal',
            'group_id': f.groupA,
            'member_id': f.a,
            'active': true,
            'size_id': f.three,
            'signature': 'signed',
          }),
          operationId: 'd',
        );
        await f.buy(d.id, 2, unit: '10');
      });
      await host(t, RecordEditPage(store: f.records));
      await reach(t, find.text('选择成员'));
      await t.tap(find.text('选择成员'));
      await t.pumpAndSettle();
      await t.tap(find.text('晨星 · A').last);
      await t.pumpAndSettle();
      await t.tap(find.text('确定'));
      await settleIo(t);
      expect(
        t
            .widget<MemberMultiSelectField>(find.byType(MemberMultiSelectField))
            .selectedIds,
        [f.a],
      );
      await reach(t, find.byKey(const ValueKey('record-quantity')));
      await t.tap(find.byTooltip('增加一张'));
      await settleIo(t);
      await t.tap(find.byTooltip('增加一张'));
      await settleIo(t);
      await reach(t, find.textContaining('需要3张'));
      expect(find.textContaining('还差1张'), findsOneWidget);
      await capture(t, 'record-shortage');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'source default chooses earliest valid expiry and refreshes through event date',
    (t) async {
      await t.runAsync(() async {
        await f.finances();
        await f.buy(f.source, 1, unit: '5', expiry: '2026-10-15');
      });
      final store = TransferStore(f.records.database, clock: () => f.clock);
      await host(t, TransferEditPage(store: store, sourceDefinition: f.source));
      expect(
        find.byKey(const ValueKey('transfer-source-pool-dated')),
        findsOneWidget,
      );
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('transfer-source-expiry')),
            )
            .controller!
            .text,
        '2026-10-15',
      );
      await t.enterText(
        find.byKey(const ValueKey('transfer-day')),
        '2026-10-16',
      );
      await settleIo(t);
      expect(
        find.byKey(const ValueKey('transfer-source-pool-long')),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );
}
