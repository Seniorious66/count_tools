import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/ui/legacy_mapping_page.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'legacy_mapping_test.dart' show LegacyFixture;
import 'transport_ui_test.dart' show settleIo;

void main() {
  final visual = Platform.environment['CHEKI_LEGACY_VISUAL'];
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
            Platform.environment['CHEKI_TRANSPORT_ICON_FONT']!,
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });
  late LegacyFixture f;
  setUp(() async {
    f = LegacyFixture();
    await f.open();
    final d = await f.db();
    await IdentityStore(
      () async => d,
    ).createMember(name: '合成成员', operationId: 'ui-member');
    await d.close();
  });
  tearDown(() => f.close());
  Future<void> mount(
    WidgetTester t, {
    double width = 360,
    double scale = 1,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
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
        builder: (c, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: LegacyMappingPage(store: f.store),
      ),
    );
    await settleIo(t);
  }

  Future<void> tap(WidgetTester t, String text) async {
    final matches = find.text(text);
    if (matches.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        matches,
        180,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
    }
    final target = matches.first;
    await t.ensureVisible(target);
    await settleIo(t);
    await Scrollable.ensureVisible(t.element(target), alignment: 0.5);
    await t.pumpAndSettle();
    await t.tap(target);
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (visual == null) return;
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
    'explicit preview, confirm cancel, back edit, and actual isolated apply',
    (t) async {
      addTearDown(t.view.reset);
      await mount(t);
      await tap(t, '读取旧档案');
      expect(find.text('旧行 2 · 已迁移 0 · 本次选择 2'), findsOneWidget);
      expect(find.textContaining('数量未填'), findsNWidgets(2));
      await tap(t, '生成隔离迁移预览');
      await capture(t, 'legacy-preview-360');
      expect(await t.runAsync(f.records), isEmpty);
      await tap(t, '核对并迁移');
      await tap(t, '取消');
      expect(find.text('迁移预览：新增 2 条'), findsOneWidget);
      await tap(t, '返回调整');
      await tap(t, '本次跳过');
      await tap(t, '生成隔离迁移预览');
      expect(find.text('迁移预览：新增 1 条'), findsOneWidget);
      await tap(t, '核对并迁移');
      await tap(t, '确认迁移');
      expect((await t.runAsync(f.records))!.length, 1);
      await tap(t, '读取旧档案');
      expect(find.text('旧行 2 · 已迁移 1 · 本次选择 1'), findsOneWidget);
    },
  );
  testWidgets(
    'batch rules require explicit confirmation; date projection and count are never defaults',
    (t) async {
      addTearDown(t.view.reset);
      await mount(t);
      await tap(t, '读取旧档案');
      await tap(t, '批量填写已确认的信息');
      await tap(t, '所选每条旧行均为一张 Cheki');
      await tap(t, '采用原日期中的年月日');
      await tap(t, '所选记录全部已领取（实际时间未知）');
      await tap(t, '应用所选规则到草稿');
      await tap(t, '生成隔离迁移预览');
      expect(find.textContaining('2024-01-02 · 1 张'), findsOneWidget);
      await capture(t, 'legacy-explicit-rules');
      await tap(t, '核对并迁移');
      await tap(t, '确认迁移');
      final records = (await t.runAsync(f.records))!;
      expect(records.every((r) => r.information.quantity == 1), true);
      expect(
        records.every((r) => r.information.receiptStatus?.name == 'received'),
        true,
      );
      expect(records.every((r) => r.information.signature == null), true);
    },
  );
  testWidgets(
    'portrait 320–430 and 200% editor keyboard remain reachable without horizontal overflow',
    (t) async {
      addTearDown(t.view.reset);
      for (final width in [320.0, 360.0, 390.0, 430.0]) {
        await mount(t, width: width);
        await tap(t, '读取旧档案');
        await capture(t, 'legacy-${width.toInt()}');
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await settleIo(t);
      }
      await mount(t, width: 320, scale: 2);
      await tap(t, '读取旧档案');
      await tap(t, '调整映射');
      t.view.viewInsets = FakeViewPadding(bottom: 320);
      await t.pump();
      final date = find.byType(TextField).first;
      await t.ensureVisible(date);
      await t.enterText(date, '2024-01-02');
      final quantity = find.byType(TextField).at(1);
      await t.ensureVisible(quantity);
      await t.enterText(quantity, '2');
      await capture(t, 'legacy-editor-320-large-keyboard');
      await tap(t, '保留到映射草稿');
      expect(find.textContaining('2024-01-02 · 2 张'), findsOneWidget);
      expect(t.takeException(), isNull);
      t.view.resetViewInsets();
      await capture(t, 'legacy-320-large');
    },
  );
  testWidgets(
    'stale confirmation refuses and does not show success; reread resets draft and preview',
    (t) async {
      addTearDown(t.view.reset);
      await mount(t);
      await tap(t, '读取旧档案');
      await tap(t, '生成隔离迁移预览');
      f.settings['newer'] = true;
      await tap(t, '核对并迁移');
      await tap(t, '确认迁移');
      expect(find.textContaining('账本已变化'), findsOneWidget);
      expect(await t.runAsync(f.records), isEmpty);
      await tap(t, '读取旧档案');
      expect(find.text('核对并迁移'), findsNothing);
      expect(find.textContaining('数量未填'), findsNWidgets(2));
    },
  );
}
