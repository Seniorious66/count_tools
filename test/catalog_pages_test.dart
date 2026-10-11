import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/app.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/ui/catalog_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;

Future<void> settleIo(WidgetTester tester) async {
  // OS file work and fake-frame callbacks must both advance during cold open.
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  late Directory scratch;
  late CatalogStore store;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-catalog-pages-');
    final path = '${scratch.path}/catalog.sqlite';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () async => path;
    SharedPreferences.setMockInitialValues({'isNotFirstEnter': true});
    store = CatalogStore(() => DatabaseHelper().database);
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  testWidgets(
    'application management entry creates, renames, stops and reads history',
    (tester) async {
      await tester.pumpWidget(const App());
      await settleIo(tester);
      await tester.tap(find.byTooltip('Cheki 管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('团体'));
      await settleIo(tester);
      expect(find.text('还没有团体'), findsOneWidget);
      expect(find.text('券库'), findsNothing);
      await tester.tap(find.byTooltip('新增团体'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '合成团体');
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.text('合成团体'), findsOneWidget);
      await tester.tap(find.text('合成团体'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '改名团体');
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.text('已停用'), findsOneWidget);
      await tester.tap(find.text('改名团体'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('修改历史'));
      await settleIo(tester);
      expect(find.text('合成团体 → 改名团体'), findsOneWidget);
      expect(find.text('新增 合成团体'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => DatabaseHelper().close());
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: CatalogManagementPage(store: store),
        ),
      );
      await tester.tap(find.text('团体'));
      await settleIo(tester);
      expect(find.text('改名团体'), findsOneWidget);
      expect(find.text('已停用'), findsOneWidget);
      expect(
        (await tester.runAsync(
          () => store.list(CatalogKind.group),
        ))!.single.revision,
        2,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'blank save and cancelled back preserve input; discard never writes',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: CatalogManagementPage(store: store),
        ),
      );
      await tester.tap(find.text('团体'));
      await settleIo(tester);
      await tester.tap(find.byTooltip('新增团体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入团体名称'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '未保存内容');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('放弃修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '未保存内容'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(find.text('还没有团体'), findsOneWidget);
      expect(
        await tester.runAsync(() => store.list(CatalogKind.group)),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'stale edit retains form and refuses to overwrite newer content',
    (tester) async {
      final original = (await tester.runAsync(
        () => store.create(CatalogKind.group, name: '团体', operationId: 'old'),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: CatalogEditPage(
            kind: CatalogKind.group,
            store: store,
            original: original,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '当前输入');
      await tester.runAsync(
        () => store.edit(
          CatalogKind.group,
          original: original,
          name: '外部修改',
          active: true,
          operationId: 'external',
        ),
      );
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.widgetWithText(TextField, '当前输入'), findsOneWidget);
      expect(find.text('内容已被修改，请返回列表重新打开'), findsOneWidget);
      expect(
        (await tester.runAsync(
          () => store.list(CatalogKind.group),
        ))!.single.name,
        '外部修改',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'read failure offers retry without presenting a false empty list',
    (tester) async {
      var fails = true;
      final retry = CatalogStore(() async {
        if (fails) throw StateError('injected read failure');
        return DatabaseHelper().database;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: CatalogListPage(kind: CatalogKind.size, store: retry),
        ),
      );
      await settleIo(tester);
      expect(find.text('读取失败，请重试'), findsOneWidget);
      expect(find.text('还没有尺寸'), findsNothing);
      fails = false;
      await tester.tap(find.text('重试'));
      await settleIo(tester);
      expect(find.text('三寸'), findsOneWidget);
      expect(find.text('五寸'), findsOneWidget);
      expect(find.text('四寸'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('320 and 430 widths at large text keep keyboard save reachable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    for (final width in [320.0, 430.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CatalogEditPage(
            key: ValueKey(width),
            kind: CatalogKind.group,
            store: store,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '多字团体名称');
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('保存')).bottom, lessThanOrEqualTo(520));
      expect(find.text('保存').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('busy save disables repeats and system back until one commit', (
    tester,
  ) async {
    final gate = Completer<void>();
    final slow = CatalogStore(
      () => DatabaseHelper().database,
      afterWrite: () => gate.future,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: chekiTheme(),
        home: CatalogManagementPage(store: slow),
      ),
    );
    await tester.tap(find.text('团体'));
    await settleIo(tester);
    await tester.tap(find.byTooltip('新增团体'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '只写一次');
    await tester.tap(find.text('保存'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.pageBack();
    await tester.pump();
    expect(find.text('正在保存…'), findsOneWidget);
    expect(find.text('放弃修改？'), findsNothing);
    gate.complete();
    await settleIo(tester);
    expect(find.text('只写一次'), findsOneWidget);
    expect(
      (await tester.runAsync(() => store.list(CatalogKind.group)))!.length,
      1,
    );
    await tester.pumpWidget(const SizedBox());
  });
  final evidence = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  if (evidence != null) {
    testWidgets('synthetic catalog page visual evidence', (tester) async {
      final root = Directory(evidence).absolute;
      expect(root.path.startsWith(Directory.current.absolute.path), isFalse);
      expect(File('${root.path}/.cheki-ui-evidence').existsSync(), isTrue);
      final font = Platform.environment['COUNT_TOOLS_UI_FONT'];
      final icons = Platform.environment['COUNT_TOOLS_UI_ICON_FONT'];
      for (final entry in {
        'CatalogPreview': font,
        'MaterialIcons': icons,
      }.entries) {
        if (entry.value == null) continue;
        final loader = FontLoader(entry.key);
        loader.addFont(
          Future.value(
            ByteData.sublistView(File(entry.value!).readAsBytesSync()),
          ),
        );
        await tester.runAsync(loader.load);
      }
      final original = (await tester.runAsync(
        () => store.create(
          CatalogKind.group,
          name: '晨星与夜空的长名字合成团体',
          operationId: 'visual',
        ),
      ))!;
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final scale in [1.0, 2.0]) {
        final key = GlobalKey();
        final theme = chekiTheme();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.copyWith(
              appBarTheme: theme.appBarTheme.copyWith(
                titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                  fontFamily: font == null ? null : 'CatalogPreview',
                ),
              ),
              textTheme: theme.textTheme.apply(
                fontFamily: font == null ? null : 'CatalogPreview',
              ),
            ),
            builder: (context, child) => RepaintBoundary(
              key: key,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
            home: scale == 1
                ? CatalogListPage(kind: CatalogKind.group, store: store)
                : CatalogEditPage(
                    kind: CatalogKind.group,
                    store: store,
                    original: original,
                  ),
          ),
        );
        await settleIo(tester);
        await tester.runAsync(() async {
          final screenshot =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await screenshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          File(
            '${root.path}/catalog-320-${scale.toInt()}x.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          screenshot.dispose();
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    });
  }
}
