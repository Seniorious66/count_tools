import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/app_shell.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'bi_fixture.dart';
import 'catalog_pages_test.dart' show settleIo;

class CsvAccess extends BiFileAccess {
  String? saved;
  bool success = false, fail = false;
  @override
  Future<bool> save(String csv) async {
    if (fail) throw StateError('isolated failure');
    saved = csv;
    return success;
  }
}

class RetryBi extends BiStore {
  RetryBi(super.database, {super.clock});
  bool fail = true;
  @override
  Future<BiSnapshot> read() async {
    if (fail) throw StateError('isolated read failure');
    return super.read();
  }
}

void portrait(WidgetTester t) {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(390, 900);
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (Platform.environment['COUNT_TOOLS_BI_VISUAL'] != null) {
      for (final font in {
        'Roboto': 'C:/Windows/Fonts/msyh.ttc',
        'Ahem': 'C:/Windows/Fonts/msyh.ttc',
        'MaterialIcons':
            'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(font.key);
        loader.addFont(
          Future.value(
            ByteData.sublistView(await File(font.value).readAsBytes()),
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
  ThemeData readableTheme() {
    final theme = chekiTheme();
    return Platform.environment['COUNT_TOOLS_BI_VISUAL'] == null
        ? theme
        : theme.copyWith(
            appBarTheme: theme.appBarTheme.copyWith(
              titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                fontFamily: 'Roboto',
              ),
            ),
          );
  }

  Widget page({
    BiStore? store,
    BiFileAccess? access,
    double scale = 1,
    bool reportsOnly = false,
  }) => MaterialApp(
    theme: readableTheme(),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: BiPage(
        store: store ?? f.bi,
        records: f.records,
        access: access,
        reportsOnly: reportsOnly,
        initialPeriod: BiPeriod(BiScope.month, '2026-10-14'),
      ),
    ),
  );
  testWidgets(
    'fourth actual navigation shows stats and keeps chosen period on return',
    (t) async {
      portrait(t);
      await t.pumpWidget(
        MaterialApp(theme: chekiTheme(), home: const ChekiAppShell()),
      );
      await settleIo(t);
      await t.tap(find.text('统计').last);
      await settleIo(t);
      expect(find.text('同人关联'), findsOneWidget);
      await t.tap(find.text('所有').first);
      await settleIo(t);
      expect(find.text('所有时间'), findsOneWidget);
      await t.tap(find.text('首页').last);
      await settleIo(t);
      await t.tap(find.text('统计').last);
      await settleIo(t);
      expect(find.text('所有时间'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'members are flat with group labels and colour; drill daily then original editable record',
    (t) async {
      portrait(t);
      await t.pumpWidget(page());
      await settleIo(t);
      expect(find.text('7 张'), findsWidgets);
      await t.scrollUntilVisible(
        find.text('晨星-A'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.text('晨星-A'));
      await settleIo(t);
      expect(find.byType(BiMemberPage), findsOneWidget);
      expect(find.text('5 张'), findsOneWidget);
      await t.tap(find.text('2026-10-11'));
      await settleIo(t);
      expect(find.textContaining('3 张 · 2026-10-11'), findsOneWidget);
      await t.tap(find.textContaining('3 张 · 2026-10-11'));
      await settleIo(t);
      expect(find.byType(RecordDetailPage), findsOneWidget);
      expect(find.text('修改记录'), findsOneWidget);
      await t.pageBack();
      await settleIo(t);
      await t.pageBack();
      await settleIo(t);
      await t.pageBack();
      await settleIo(t);
      await t.scrollUntilVisible(
        find.text('2026-10-01 — 2026-10-31'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('2026-10-01 — 2026-10-31'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'read failure retry, committed change invalidation and CSV cancel failure success keep database unchanged',
    (t) async {
      portrait(t);
      final store = RetryBi(f.records.database, clock: () => f.clock),
          access = CsvAccess();
      await t.pumpWidget(page(store: store, access: access));
      await settleIo(t);
      expect(find.text('统计读取失败'), findsOneWidget);
      store.fail = false;
      await t.tap(find.text('重试'));
      await settleIo(t);
      expect(find.text('7 张'), findsWidgets);
      await t.runAsync(() => f.record(1, [f.a]));
      RecordStore.invalidateReads();
      await settleIo(t);
      expect(find.text('8 张'), findsWidgets);
      final before = (await t.runAsync(
        () => f.records.list(),
      ))!.map((r) => r.information.encode()).toList();
      await t.pumpWidget(page(store: store, access: access, reportsOnly: true));
      await settleIo(t);
      await t.scrollUntilVisible(
        find.text('保存统计 CSV'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.text('保存统计 CSV'));
      await settleIo(t);
      expect(find.text('已取消保存'), findsOneWidget);
      expect(access.saved, contains('"physical","张数","","8"'));
      access.fail = true;
      await t.tap(find.text('保存统计 CSV'));
      await settleIo(t);
      expect(find.text('保存失败，请重试；账本未改变'), findsOneWidget);
      access.fail = false;
      access.success = true;
      await t.tap(find.text('保存统计 CSV'));
      await settleIo(t);
      expect(find.text('统计 CSV 已保存到所选位置'), findsOneWidget);
      expect(
        (await t.runAsync(
          () => f.records.list(),
        ))!.map((r) => r.information.encode()).toList(),
        before,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    '320 and 430 portrait 200 percent statistics drilldown and date picker keyboard remain operable',
    (t) async {
      portrait(t);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      for (final width in [320.0, 430.0]) {
        t.view.physicalSize = Size(width, 900);
        await t.pumpWidget(page(scale: 2));
        await settleIo(t);
        await t.scrollUntilVisible(
          find.text('晨星-A'),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await t.tap(find.text('晨星-A'));
        await settleIo(t);
        await t.tap(find.text('选择日期查看'));
        await t.pumpAndSettle();
        expect(find.byType(CalendarDatePicker), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
        await t.pump();
        expect(t.takeException(), isNull);
        await t.tap(find.text('取消'));
        await t.pumpAndSettle();
        t.view.resetViewInsets();
        await t.pageBack();
        await settleIo(t);
        await t.pumpWidget(page(scale: 2, reportsOnly: true));
        await settleIo(t);
        await t.scrollUntilVisible(
          find.text('保存统计 CSV'),
          500,
          scrollable: find.byType(Scrollable).first,
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      }
    },
  );
  test(
    'schema8 complete backup restores same BI CSV exact costs colours settings and attachments',
    () async {
      await f.finances(unknown: true);
      var settings = <String, Object?>{
        'locale': 'zh',
        'unknown': ['原文', null].whereType<String>().toList(),
        'flag': false,
      };
      final attachment = File('${f.root.path}/attachments/original.bin');
      await attachment.parent.create();
      await attachment.writeAsBytes([0, 255, 1]);
      final report = (await f.bi.read())
          .report(BiPeriod(BiScope.all, '2026-10-14'))
          .csv();
      final backup = BackupStore(
        documents: f.root,
        readSettings: () async => Map.from(settings),
        writeSettings: (s) async => settings = Map.from(s),
        closeMain: () => DatabaseHelper().close(),
      );
      final bytes = await backup.snapshot();
      await f.record(11, [f.b]);
      settings = {'altered': true};
      await attachment.writeAsBytes([2]);
      final preview = await backup.prepare(bytes);
      expect(
        (await f.bi.read()).report(BiPeriod(BiScope.all, '2026-10-14')).csv(),
        isNot(report),
      );
      await backup.apply(preview);
      expect(
        (await f.bi.read()).report(BiPeriod(BiScope.all, '2026-10-14')).csv(),
        report,
      );
      expect(settings['flag'], false);
      expect(await attachment.readAsBytes(), [0, 255, 1]);
      await DatabaseHelper().close();
      expect(
        (await f.bi.read()).report(BiPeriod(BiScope.all, '2026-10-14')).csv(),
        report,
      );
    },
  );
  testWidgets(
    'native CSV export uses only chosen document and cancellation returns false',
    (t) async {
      portrait(t);
      const channel = MethodChannel('com.seniorious66.counttools/backup');
      MethodCall? call;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) async {
            call = c;
            return false;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(await BiFileAccess().save('中文,"金额"\r\n'), false);
      expect(call!.method, 'exportCsv');
      expect((call!.arguments as Map)['name'], 'Cheki-statistics.csv');
    },
  );
  testWidgets(
    'additional filters and date validation change real report without writing business dates',
    (t) async {
      portrait(t);
      await t.pumpWidget(page());
      await settleIo(t);
      await t.tap(find.text('更多筛选'));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('属性:null')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.byKey(const ValueKey('属性:null')));
      await t.pumpAndSettle();
      await t.tap(find.text('无签').last);
      await settleIo(t);
      await t.scrollUntilVisible(
        find.text('2 张').first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('2 张'), findsWidgets);
      await t.scrollUntilVisible(
        find.text('2026-10-01 — 2026-10-31'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.text('2026-10-01 — 2026-10-31'));
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      t
          .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
          .onDateChanged(DateTime(2026, 9, 30));
      await t.pump();
      await t.tap(find.text('确定'));
      await settleIo(t);
      expect(find.text('2026-09-01 — 2026-09-30'), findsOneWidget);
      expect((await t.runAsync(() => f.records.list()))!.length, 3);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('optional portrait BI visual evidence', (t) async {
    portrait(t);
    final output = Platform.environment['COUNT_TOOLS_BI_VISUAL'];
    if (output == null) return;
    await t.runAsync(() => f.finances(unknown: true, future: true));
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 900);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(key: key, child: page()));
    await settleIo(t);
    Future<void> capture(String name) async {
      await t.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File(
          '$output/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('statistics');
    await t.runAsync(() async {
      await File('$output/statistics.csv').writeAsString(
        (await f.bi.read()).report(BiPeriod(BiScope.month, '2026-10-14')).csv(),
      );
    });
    await t.scrollUntilVisible(
      find.text('晨星-A'),
      140,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('晨星-A'));
    await settleIo(t);
    await capture('member-month');
    await t.pageBack();
    await settleIo(t);
    await t.pumpWidget(page(reportsOnly: true));
    await settleIo(t);
    await t.scrollUntilVisible(
      find.text('购券与成本'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(t.element(find.text('购券与成本')), alignment: 0);
    await t.pumpAndSettle();
    await capture('cost');
    await t.pumpWidget(const SizedBox());
  });
}
