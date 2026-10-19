import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/catalog_pages.dart';
import 'package:count_tools/cheki/ui/compact_record.dart';
import 'package:count_tools/cheki/ui/components.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'bi_fixture.dart';
import 'daily_r2_test.dart' show legacy;
import 'support/settle_io.dart';

class _Csv extends BiFileAccess {
  String? csv;
  bool saved = false, fail = false;
  @override
  Future<bool> save(String text) async {
    csv = text;
    if (fail) throw StateError('isolated save failure');
    return saved;
  }
}

void main() {
  final visual = Platform.environment['CHEKI_COMPACT_VISUAL'];
  final boundary = GlobalKey();
  late BiFixture f;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (visual != null) {
      for (final e in {
        'ChekiTest': 'C:/Windows/Fonts/msyh.ttc',
        'Ahem': 'C:/Windows/Fonts/msyh.ttc',
        'Roboto': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons':
            'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(e.key)
              ..addFont(File(e.value).readAsBytes().then(ByteData.sublistView)))
            .load();
      }
    }
  });
  setUp(() async {
    f = BiFixture();
    await f.open();
  });
  tearDown(() => f.close());

  Future<void> host(
    WidgetTester t,
    Widget page, {
    double width = 390,
    double scale = 1,
  }) async {
    await t.pumpWidget(const SizedBox());
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    addTearDown(t.view.reset);
    var theme = chekiTheme();
    ThemeData readable(ThemeData source) => source.copyWith(
      textTheme: source.textTheme.apply(fontFamily: 'ChekiTest'),
      appBarTheme: source.appBarTheme.copyWith(
        titleTextStyle: source.appBarTheme.titleTextStyle?.copyWith(
          fontFamily: 'ChekiTest',
        ),
      ),
    );
    if (visual != null) {
      theme = readable(theme);
    }
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
        home: visual != null && page is CatalogManagementPage
            ? Builder(
                builder: (context) {
                  // Only replace fixture fonts in the actual management tree.
                  // The normal regression above mounts the original widget.
                  // ignore: invalid_use_of_protected_member
                  final built = page.build(context) as Theme;
                  return Theme(data: readable(built.data), child: built.child);
                },
              )
            : page,
      ),
    );
    await settleIo(t);
  }

  Future<void> reach(WidgetTester t, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        finder,
        220,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await t.ensureVisible(finder);
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (visual == null) return;
    await settleIo(t);
    await t.runAsync(() async {
      final im =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      await Directory(visual).create(recursive: true);
      await File('$visual/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  }

  Future<Map<String, Object?>> ledger() async {
    final db = await f.records.database();
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
    );
    return {
      for (final row in tables)
        row['name']! as String: await db.rawQuery(
          'SELECT * FROM "${row['name']}" ORDER BY rowid',
        ),
    };
  }

  testWidgets(
    'statistics keeps core BI and expenses without ticket reports or export',
    (t) async {
      await f.quantities();
      await f.finances();
      await host(
        t,
        Scaffold(
          body: BiPage(store: f.bi, records: f.records),
        ),
      );
      await reach(t, find.byKey(const ValueKey('member-expenses')));
      await t.tap(find.byKey(const ValueKey('member-expenses')));
      await settleIo(t);
      expect(find.text('导出花费明细'), findsNothing);
      await t.pageBack();
      await settleIo(t);
      await reach(t, find.text('每日张数'));
      expect(find.text('每日张数'), findsWidgets);
      await reach(t, find.text('属性'));
      expect(find.text('购券与成本'), findsNothing);
      expect(find.text('期间券流水'), findsNothing);
      expect(find.text('保存统计 CSV'), findsNothing);
      await capture(t, 'statistics-clean');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'management hides legacy entries and opens default folded report destination',
    (t) async {
      final access = _Csv();
      await host(
        t,
        CatalogManagementPage(store: f.catalog, reportAccess: access),
      );
      expect(find.text('旧版项目'), findsNothing);
      expect(find.text('旧档案映射'), findsNothing);
      await reach(t, find.byKey(const ValueKey('management-reports')));
      expect(find.text('购券、库存与CSV'), findsNothing);
      await capture(t, 'management-folded');
      await t.tap(find.text('报表与导出'));
      await settleIo(t);
      await reach(t, find.text('购券、库存与CSV'));
      await capture(t, 'management-expanded');
      await t.tap(find.text('购券、库存与CSV'));
      await settleIo(t);
      expect(find.text('报表与导出'), findsOneWidget);
      expect(find.text('2026-10-01 — 2026-10-31'), findsOneWidget);
      expect(find.text('所有团体'), findsOneWidget);
      expect(find.text('每日张数'), findsNothing);
      await t.pageBack();
      await settleIo(t);
      await host(t, CatalogManagementPage(store: f.catalog));
      await reach(t, find.text('报表与导出'));
      expect(find.text('购券、库存与CSV'), findsNothing);
    },
  );

  testWidgets(
    'legacy navigation can be explicitly restored without ledger changes',
    (t) async {
      final before = await ledger();
      await host(t, CatalogManagementPage(store: f.catalog, showLegacy: true));
      expect(find.text('旧版项目'), findsOneWidget);
      await reach(t, find.text('旧档案映射'));
      expect(find.text('旧档案映射'), findsOneWidget);
      expect(await ledger(), before);
    },
  );

  testWidgets(
    'report period group CSV cancel error and success use same report and do not write',
    (t) async {
      await f.quantities();
      await f.finances();
      final access = _Csv();
      final before = await ledger();
      await host(
        t,
        BiPage(
          store: f.bi,
          records: f.records,
          reportsOnly: true,
          access: access,
        ),
      );
      await t.tap(find.text('所有').first);
      await settleIo(t);
      await t.tap(find.byType(DropdownButtonFormField<String>).first);
      await settleIo(t);
      await t.tap(find.text('夜航').last);
      await settleIo(t);
      await reach(t, find.text('保存统计 CSV'));
      await t.tap(find.text('保存统计 CSV'));
      await settleIo(t);
      expect(find.text('已取消保存'), findsOneWidget);
      final expected = (await f.bi.read())
          .report(BiPeriod(BiScope.all, '2026-10-14'), groupId: f.groupB)
          .csv();
      expect(access.csv, expected);
      access.fail = true;
      await t.tap(find.text('保存统计 CSV'));
      await settleIo(t);
      expect(find.text('保存失败，请重试；账本未改变'), findsOneWidget);
      access.fail = false;
      access.saved = true;
      await t.tap(find.text('保存统计 CSV'));
      await settleIo(t);
      expect(find.text('统计 CSV 已保存到所选位置'), findsOneWidget);
      expect(await ledger(), before);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'management report retains member expense exports and period on return',
    (t) async {
      await f.quantities();
      final access = _Csv();
      await host(
        t,
        BiPage(
          store: f.bi,
          records: f.records,
          reportsOnly: true,
          access: access,
        ),
      );
      await t.tap(find.text('年'));
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('member-expenses')));
      await t.tap(find.byKey(const ValueKey('member-expenses')));
      await settleIo(t);
      await reach(t, find.text('导出花费明细'));
      await t.tap(find.text('导出花费明细'));
      await settleIo(t);
      expect(access.csv, isNotNull);
      expect(find.text('已取消保存'), findsOneWidget);
      await t.pageBack();
      await settleIo(t);
      await reach(t, find.text('2026-01-01 — 2026-12-31'));
      expect(find.text('2026-01-01 — 2026-12-31'), findsOneWidget);
    },
  );

  for (final width in [320.0, 360.0, 390.0, 430.0]) {
    testWidgets('record three-line normal geometry and full semantics $width', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      var taps = 0;
      await host(
        t,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ChekiCard(
              padding: const EdgeInsets.all(12),
              child: CompactRecordContent(
                date: '2026-10-18',
                members: const [(name: 'Astoria-小夏', color: Colors.blue)],
                quantitySize: '2 张 · 三寸',
                attributesReceipt: '带签 · 已领取',
                cost: '花费：¥160',
                onTap: () => taps++,
              ),
            ),
          ),
        ),
        width: width,
      );
      final left = t.getRect(find.byKey(const ValueKey('record-identity')));
      final right = t.getRect(find.byKey(const ValueKey('record-facts')));
      expect(left.right, lessThan(right.left));
      expect(t.getSize(find.byType(ChekiCard)).height, lessThanOrEqualTo(130));
      expect((t.widget<Text>(find.text('Astoria-小夏')).style!.fontSize), 20);
      expect(find.semantics.byLabel(RegExp('Astoria-小夏.*160')), findsOneWidget);
      await t.tap(find.byType(CompactRecordContent));
      expect(taps, 1);
      expect(t.takeException(), isNull);
      await capture(t, 'record-$width');
      semantics.dispose();
    });
  }

  testWidgets(
    'long multi member back signature large amount 200 percent grows without clipping',
    (t) async {
      final semantics = t.ensureSemantics();
      await host(
        t,
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ChekiCard(
              padding: const EdgeInsets.all(12),
              child: CompactRecordContent(
                date: '发生日期未填写',
                members: const [
                  (name: '长团体名称-第一成员完整姓名', color: Colors.pink),
                  (name: '另一个团体-第二成员', color: Colors.blue),
                ],
                quantitySize: '张数未填写 · 尺寸未填写',
                attributesReceipt: '带签 · 背签 · 部分领取',
                cost: '花费：¥1234567890',
                onTap: () {},
              ),
            ),
          ),
        ),
        width: 320,
        scale: 2,
      );
      final left = t.getRect(find.byKey(const ValueKey('record-identity'))),
          right = t.getRect(find.byKey(const ValueKey('record-facts')));
      expect(left.bottom, lessThan(right.top));
      expect(
        find.semantics.byLabel(RegExp('第一成员完整姓名.*第二成员.*背签.*1234567890')),
        findsOneWidget,
      );
      expect(find.text('等2人'), findsOneWidget);
      expect(t.takeException(), isNull);
      await capture(t, 'record-large');
      semantics.dispose();
    },
  );

  testWidgets(
    'home and list share merged summary and original records remain editable',
    (t) async {
      await f.record(1, [f.a]);
      await f.record(2, [f.a]);
      final before = await ledger();
      await host(
        t,
        Scaffold(
          body: RecordHomePage(store: f.records, ticketStore: f.tickets),
        ),
      );
      await reach(t, find.byType(CompactRecordContent));
      final home = t.widget<CompactRecordContent>(
        find.byType(CompactRecordContent).first,
      );
      expect(home.quantitySize, startsWith('3 张'));
      expect(home.cost, isEmpty);
      await capture(t, 'home');
      await host(t, RecordListPage(store: f.records));
      final list = t.widget<CompactRecordContent>(
        find.byType(CompactRecordContent).first,
      );
      expect(list.quantitySize, home.quantitySize);
      expect(list.members, home.members);
      expect(list.date, home.date);
      await t.tap(find.byType(CompactRecordContent).first);
      await settleIo(t);
      expect(find.text('原始记录'), findsOneWidget);
      expect(find.byType(CompactRecordContent), findsNWidgets(2));
      expect(await ledger(), before);
    },
  );

  Future<List<String>> inventory() async {
    final ids = <String>[];
    for (var i = 0; i < 3; i++) {
      final d = await f.tickets.save(
        kind: 'definition',
        information: TicketInformation({
          'scope': i == 1 ? 'group' : 'personal',
          'group_id': f.groupA,
          if (i != 1) 'member_id': f.a,
          'size_id': i == 2 ? f.five : f.three,
          'signature': i == 2 ? 'unsigned' : 'signed',
          'active': i != 2,
        }),
        operationId: 'grid-def-$i',
      );
      ids.add(d.id);
    }
    await f.buy(ids[0], 9, total: '720');
    await f.buy(ids[1], 5, total: '250', expiry: '2026-10-16');
    return ids;
  }

  testWidgets(
    'record unknown cost stays hidden and explicit zero remains visible',
    (t) async {
      await f.records.save(
        RecordInformation.fromMap({
          ...legacy('0'),
          'member_ids': [f.a],
        }),
        operationId: 'compact-zero',
      );
      await f.records.save(
        RecordInformation.fromMap({
          ...legacy(null, id: 2),
          'member_ids': [f.b],
        }),
        operationId: 'compact-unknown',
      );
      await host(
        t,
        RecordListPage(
          store: f.records,
          initialFilter: RecordFilter(memberId: f.b),
        ),
      );
      expect(
        t.widget<CompactRecordContent>(find.byType(CompactRecordContent)).cost,
        isEmpty,
      );
      expect(find.textContaining('花费：'), findsNothing);
      await host(
        t,
        RecordListPage(
          store: f.records,
          initialFilter: RecordFilter(memberId: f.a),
        ),
      );
      expect(find.text('花费：¥0'), findsOneWidget);
      expect(t.takeException(), isNull);
      await capture(t, 'record-zero');
    },
  );
  for (final pair in [(320.0, 2.0), (430.0, 1.0)]) {
    testWidgets('management report portrait and date keyboard ${pair.$1}', (
      t,
    ) async {
      await f.finances();
      await host(
        t,
        CatalogManagementPage(store: f.catalog),
        width: pair.$1,
        scale: pair.$2,
      );
      await reach(t, find.text('报表与导出'));
      await capture(t, 'management-${pair.$1}');
      await t.tap(find.text('报表与导出'));
      await settleIo(t);
      await reach(t, find.text('购券、库存与CSV'));
      await t.tap(find.text('购券、库存与CSV'));
      await settleIo(t);
      await capture(t, 'report-${pair.$1}');
      await t.tap(find.text('2026-10-01 — 2026-10-31'));
      await settleIo(t);
      await t.enterText(find.byType(TextField), '2026-10-13');
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await t.pump();
      await t.ensureVisible(find.text('取消'));
      await settleIo(t);
      await capture(t, 'report-keyboard-${pair.$1}');
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.text('取消'));
      await settleIo(t);
      t.view.resetViewInsets();
      expect(find.text('2026-10-01 — 2026-10-31'), findsOneWidget);
      await reach(t, find.text('购券与成本'));
      await capture(t, 'report-cost-${pair.$1}');
      expect(t.takeException(), isNull);
    });
  }
  for (final width in [320.0, 360.0, 430.0]) {
    testWidgets('two-column ticket sizing at $width', (t) async {
      final ids = await inventory();
      await host(t, TicketLibraryPage(store: f.tickets), width: width);
      final a = find.byKey(ValueKey('ticket-stock-${ids[0]}')),
          b = find.byKey(ValueKey('ticket-stock-${ids[1]}'));
      expect(t.getTopLeft(a).dy, t.getTopLeft(b).dy);
      expect(t.getSize(a).width, (width - 44) / 2);
      expect(t.getRect(a).right, lessThan(t.getRect(b).left));
      expect(t.takeException(), isNull);
      await capture(t, 'tickets-$width');
    });
  }

  testWidgets(
    'ticket grid two columns row alignment stock reorder and correct detail destination',
    (t) async {
      final ids = await inventory();
      await host(t, TicketLibraryPage(store: f.tickets));
      Finder card(int i) => find.byKey(ValueKey('ticket-stock-${ids[i]}'));
      expect(t.getTopLeft(card(0)).dy, t.getTopLeft(card(1)).dy);
      expect(t.getTopLeft(card(0)).dx, lessThan(t.getTopLeft(card(1)).dx));
      expect(t.getSize(card(0)).width, 173);
      expect(t.getSize(card(0)).height, t.getSize(card(1)).height);
      expect(t.getTopLeft(card(2)).dy, greaterThan(t.getTopLeft(card(0)).dy));
      expect(find.textContaining('即将到期'), findsOneWidget);
      expect(find.textContaining('限时0'), findsNothing);
      expect(find.text('长期 9 张'), findsNothing);
      expect(find.text('已停用'), findsOneWidget);
      await capture(t, 'tickets-two-column');
      await t.runAsync(() => f.buy(ids[1], 10, total: '500'));
      await settleIo(t);
      expect(t.getTopLeft(card(1)).dx, lessThan(t.getTopLeft(card(0)).dx));
      await t.tap(card(1));
      await settleIo(t);
      expect(
        t.widget<TicketDetailPage>(find.byType(TicketDetailPage)).id,
        ids[1],
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'ticket grid large text one column preserves expiry and hidden legacy recovery remains valid',
    (t) async {
      final ids = await inventory();
      final before = await ledger();
      await host(t, TicketLibraryPage(store: f.tickets), width: 320, scale: 2);
      final first = find.byKey(ValueKey('ticket-stock-${ids[0]}')),
          second = find.byKey(ValueKey('ticket-stock-${ids[1]}'));
      expect(t.getTopLeft(first).dx, t.getTopLeft(second).dx);
      expect(t.getTopLeft(first).dy, lessThan(t.getTopLeft(second).dy));
      await reach(t, find.textContaining('即将到期'));
      await capture(t, 'tickets-large');
      expect(await ledger(), before);
      expect(t.takeException(), isNull);
    },
  );
}
