import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/app.dart';
import 'package:count_tools/cheki/ui/app_shell.dart';
import 'package:count_tools/cheki/ui/components.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/page/home_page/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'catalog_pages_test.dart' show settleIo;
import 'storage_migration_test.dart' show legacyFixture;

class _OwnedInput extends StatefulWidget {
  const _OwnedInput();
  @override
  State<_OwnedInput> createState() => _OwnedInputState();
}

class _OwnedInputState extends State<_OwnedInput> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: TextField(controller: controller),
  );
}

void main() {
  late Directory scratch;
  late String path;
  const preferences = <String, Object>{
    'isNotFirstEnter': true,
    'themeColor': 'green',
    'projectInfoRowNum': 5,
    'projectInfoSort': '升序',
    'showMode': '数量',
    'isShowTotalPrice': false,
    'unknown_setting': ['原值', '保留'],
  };
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-shell-');
    path = '${scratch.path}/shell.sqlite';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () async => path;
    SharedPreferences.setMockInitialValues(preferences);
    await DatabaseHelper().database;
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });

  Future<void> checkPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), preferences.keys.toSet());
    for (final entry in preferences.entries) {
      expect(prefs.get(entry.key), entry.value);
    }
  }

  testWidgets(
    'actual App uses R1 shell, working management/settings and preserves legacy preferences on cold reopen',
    (tester) async {
      await tester.pumpWidget(const App());
      await settleIo(tester);
      expect(find.text('旧版项目'), findsOneWidget);
      expect(find.text('合成项目'), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('券库'), findsNothing);
      expect(find.text('统计'), findsNothing);
      final context = tester.element(find.byType(ChekiShell));
      expect(Theme.of(context).colorScheme.primaryContainer, ChekiColors.blue);
      expect(
        Theme.of(context).colorScheme.secondaryContainer,
        ChekiColors.pink,
      );
      expect(Localizations.localeOf(context), const Locale('zh', 'CN'));
      await tester.runAsync(checkPreferences);
      await tester.tap(find.byTooltip('打开管理'));
      await tester.pumpAndSettle();
      expect(find.text('团体'), findsOneWidget);
      expect(find.text('尺寸'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('合成项目'), findsOneWidget);
      await tester.tap(find.byTooltip('打开设置'));
      await tester.pumpAndSettle();
      expect(find.text('版本'), findsOneWidget);
      expect(find.text('主题选择'), findsNothing);
      expect(find.text('个人信息'), findsNothing);
      expect(find.text('检查更新'), findsNothing);
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      expect(find.text('Cheki账本'), findsOneWidget);
      expect(find.textContaining('fmqwd/count_tools'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
      final licenses = await tester.runAsync(
        () async => [
          await for (final entry in LicenseRegistry.licenses)
            if (entry.packages.contains('count_tools')) entry,
        ],
      );
      expect(licenses, hasLength(1));
      expect(
        licenses!.single.paragraphs.map((p) => p.text).join('\n'),
        contains('Apache License'),
      );
      expect(
        licenses.single.paragraphs.map((p) => p.text).join('\n'),
        contains('Copyright © 2024 fmqwd'),
      );
      final licensesLabel = MaterialLocalizations.of(
        tester.element(find.byType(AboutDialog)),
      ).viewLicensesButtonLabel;
      await tester.tap(find.text(licensesLabel));
      await settleIo(tester);
      expect(find.text('count_tools'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('合成项目'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => DatabaseHelper().close());
      await tester.pumpWidget(const App());
      await settleIo(tester);
      expect(find.text('合成项目'), findsOneWidget);
      await tester.runAsync(checkPreferences);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'project read failure is retryable and does not masquerade as an empty list',
    (tester) async {
      await tester.runAsync(() => DatabaseHelper().close());
      DatabaseHelper.pathResolver = () async =>
          throw StateError('synthetic unavailable storage');
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: const HomePage(title: '兼容读取', embedded: true),
        ),
      );
      await settleIo(tester);
      expect(find.text('读取项目失败，请重试'), findsOneWidget);
      expect(find.text('没有项目，点击+添加'), findsNothing);
      DatabaseHelper.pathResolver = () async => path;
      await tester.tap(find.text('重试'));
      await settleIo(tester);
      expect(find.text('合成项目'), findsOneWidget);
      expect(find.text('读取项目失败，请重试'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'stable destination IDs retain owned input through rename, reorder, removal and system back',
    (tester) async {
      Widget host(List<ChekiDestination> destinations) => MaterialApp(
        theme: chekiTheme(),
        home: ChekiShell(destinations: destinations),
      );
      const home = ChekiDestination(
        id: 'home',
        label: '首页',
        icon: Icons.home_outlined,
        page: _OwnedInput(),
      );
      const records = ChekiDestination(
        id: 'records',
        label: '记录',
        icon: Icons.notes,
        page: _OwnedInput(),
      );
      await tester.pumpWidget(host([home, records]));
      await tester.enterText(find.byType(TextField), '首页草稿');
      await tester.tap(find.byIcon(Icons.notes));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '记录草稿');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('首页草稿'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.notes));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        host([
          const ChekiDestination(
            id: 'records',
            label: '改名记录',
            icon: Icons.notes,
            page: _OwnedInput(),
          ),
          home,
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('记录草稿'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.home_outlined));
      await tester.pumpAndSettle();
      expect(find.text('首页草稿'), findsOneWidget);
      await tester.pumpWidget(host([records]));
      await tester.pumpAndSettle();
      expect(find.text('记录草稿'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'invalid destination identity is rejected instead of silently mixing state',
    () {
      const valid = ChekiDestination(
        id: 'same',
        label: '页面',
        icon: Icons.notes,
        page: SizedBox(),
      );
      expect(() => ChekiShell(destinations: []), throwsArgumentError);
      expect(
        () => ChekiShell(destinations: [valid, valid]),
        throwsArgumentError,
      );
      expect(
        () => ChekiShell(
          destinations: [
            const ChekiDestination(
              id: ' ',
              label: '页面',
              icon: Icons.notes,
              page: SizedBox(),
            ),
          ],
        ),
        throwsArgumentError,
      );
    },
  );

  testWidgets(
    '320 and 430 at 200 percent keep actual root list, controls and settings usable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final width in [320.0, 430.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const ChekiAppShell(),
          ),
        );
        await settleIo(tester);
        expect(find.byTooltip('打开管理').hitTestable(), findsOneWidget);
        expect(find.byTooltip('打开设置').hitTestable(), findsOneWidget);
        expect(find.byTooltip('修改项目').hitTestable(), findsOneWidget);
        expect(
          find.byKey(const Key('add_project_btn')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('打开设置'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('关于'));
        await tester.pumpAndSettle();
        expect(find.text('关于').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'available two-page navigation remains reachable with large text on narrow widths',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final width in [320.0, 430.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: ChekiShell(
              destinations: const [
                ChekiDestination(
                  id: 'home',
                  label: '首页',
                  icon: Icons.home_outlined,
                  page: _OwnedInput(),
                ),
                ChekiDestination(
                  id: 'records',
                  label: '记录',
                  icon: Icons.notes,
                  page: _OwnedInput(),
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.notes).hitTestable(), findsOneWidget);
        await tester.tap(find.byIcon(Icons.notes));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.home_outlined).hitTestable(), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          0,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  final evidence = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  if (evidence != null) {
    testWidgets('synthetic application shell visual evidence', (tester) async {
      // Flutter test mode replaces elevated shadows with a thick debug stroke.
      // Render normal shadows for visual review, without changing product UI.
      final previousShadowMode = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = previousShadowMode);
      try {
        final root = Directory(evidence).absolute;
        expect(root.path.startsWith(Directory.current.absolute.path), isFalse);
        expect(File('${root.path}/.cheki-ui-evidence').existsSync(), isTrue);
        final font = Platform.environment['COUNT_TOOLS_UI_FONT'];
        final icons = Platform.environment['COUNT_TOOLS_UI_ICON_FONT'];
        for (final entry in {
          'ShellPreview': font,
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
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        for (final scale in [1.0, 2.0]) {
          final key = GlobalKey();
          final theme = chekiTheme();
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.copyWith(
                appBarTheme: theme.appBarTheme.copyWith(
                  titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                    fontFamily: font == null ? null : 'ShellPreview',
                  ),
                ),
                textTheme: theme.textTheme.apply(
                  fontFamily: font == null ? null : 'ShellPreview',
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
              home: const ChekiAppShell(),
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
              '${root.path}/shell-320-${scale.toInt()}x.png',
            ).writeAsBytesSync(bytes!.buffer.asUint8List());
            screenshot.dispose();
          });
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      } finally {
        debugDisableShadows = previousShadowMode;
      }
    });
  }
}
