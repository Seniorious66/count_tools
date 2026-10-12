import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/app.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/ui/identity_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'catalog_pages_test.dart' show settleIo;
import 'storage_migration_test.dart' show legacyFixture;

Finder dropdown(String field) => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      ((widget.key as ValueKey<String>).value).startsWith('identity-$field-'),
);
Future<void> select(WidgetTester tester, String field, String label) async {
  await tester.ensureVisible(dropdown(field));
  await tester.tap(dropdown(field));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Widget host(Widget page, {double scale = 1, ThemeData? theme, Key? boundary}) =>
    MaterialApp(
      theme: theme ?? chekiTheme(),
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
    );

void main() {
  late Directory scratch;
  late IdentityStore store;
  late CatalogEntity group, otherGroup;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-identity-pages-');
    final path = '${scratch.path}/identity.sqlite';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () async => path;
    SharedPreferences.setMockInitialValues({
      'isNotFirstEnter': true,
      'unknown_setting': ['保留', '原值'],
    });
    store = IdentityStore(() => DatabaseHelper().database);
    final catalog = CatalogStore(store.database);
    group = await catalog.create(
      CatalogKind.group,
      name: '晨星',
      operationId: 'group-a',
    );
    otherGroup = await catalog.create(
      CatalogKind.group,
      name: '夜航',
      operationId: 'group-b',
    );
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  Future<IdentityEntity> original() => store.createMember(
    name: 'A',
    groupId: group.id,
    colorRgb: 0x2288aa,
    operationId: 'a',
  );

  testWidgets(
    'actual App manages Person, member color rename transfer stop history and cold reopen',
    (tester) async {
      await tester.pumpWidget(const App());
      await settleIo(tester);
      await tester.tap(find.byTooltip('打开管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同人关联'));
      await settleIo(tester);
      await tester.tap(find.byTooltip('新增同人标签'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        '同人标签',
      );
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final person = (await store.list(IdentityKind.person)).single;
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('成员'));
      await settleIo(tester);
      await tester.tap(find.byTooltip('新增成员'));
      await settleIo(tester);
      await tester.enterText(find.byKey(const ValueKey('identity-name')), 'A');
      await select(tester, 'group', '晨星');
      await select(tester, 'person', '同人标签');
      await tester.ensureVisible(find.text('成员颜色'));
      await tester.tap(find.text('成员颜色'));
      await tester.pumpAndSettle();
      for (final channel in const [('红', 171.0), ('绿', 205.0), ('蓝', 239.0)]) {
        tester
            .widget<Slider>(find.byKey(ValueKey('member-color-${channel.$1}')))
            .onChanged!(channel.$2);
        await tester.pump();
      }
      await tester.ensureVisible(find.text('确定'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final a = (await store.list(IdentityKind.member)).single;
      expect(a.personId, person.id);
      expect(a.colorRgb, 0xabcdef);
      expect(find.text('晨星 · A'), findsOneWidget);
      await tester.tap(find.text('晨星 · A'));
      await settleIo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        'A改名',
      );
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      await tester.tap(find.text('晨星 · A改名'));
      await settleIo(tester);
      await tester.tap(find.byTooltip('修改历史'));
      await settleIo(tester);
      expect(find.text('原名：A'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('转团新增身份'));
      await settleIo(tester);
      await select(tester, 'group', '夜航');
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        '新团艺名',
      );
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.text('晨星 · A改名'), findsOneWidget);
      expect(find.text('夜航 · 新团艺名'), findsOneWidget);
      await tester.tap(find.text('晨星 · A改名'));
      await settleIo(tester);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final members = await store.list(IdentityKind.member);
      final old = members.firstWhere((m) => m.id == a.id);
      expect(old.createdAt, a.createdAt);
      expect(old.active, isFalse);
      expect(members.firstWhere((m) => m.id != a.id).personId, person.id);
      expect(members.map((m) => m.colorRgb).toSet(), {0xabcdef});
      await tester.pumpWidget(const SizedBox());
      await DatabaseHelper().close();
      await tester.pumpWidget(const App());
      await settleIo(tester);
      await tester.tap(find.byTooltip('打开管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('成员'));
      await settleIo(tester);
      expect(find.text('晨星 · A改名'), findsOneWidget);
      expect(find.text('夜航 · 新团艺名'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getStringList(
          'unknown_setting',
        ),
        ['保留', '原值'],
      );
    },
  );

  testWidgets(
    'fast system back inspects dirty input; cancel retains it and discard never writes',
    (tester) async {
      final a = await original();
      await tester.pumpWidget(
        host(IdentityListPage(kind: IdentityKind.member, store: store)),
      );
      await settleIo(tester);
      await tester.tap(find.text('晨星 · A'));
      await settleIo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        '未保存',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('放弃修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('identity-name')))
            .controller!
            .text,
        '未保存',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect((await store.list(IdentityKind.member)).single.toRow(), a.toRow());
    },
  );

  testWidgets(
    'failed save preserves all input and stale edit cannot overwrite newer member',
    (tester) async {
      final a = await original();
      final failing = IdentityStore(
        store.database,
        afterWrite: () async => throw StateError('synthetic fault'),
      );
      await tester.pumpWidget(
        host(IdentityListPage(kind: IdentityKind.member, store: failing)),
      );
      await settleIo(tester);
      await tester.tap(find.text('晨星 · A'));
      await settleIo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        '我的输入',
      );
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.text('保存失败，输入已保留，请重试'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('identity-name')))
            .controller!
            .text,
        '我的输入',
      );
      expect((await store.list(IdentityKind.member)).single.toRow(), a.toRow());
      await store.editMember(
        original: a,
        name: '另一修改',
        colorRgb: a.colorRgb!,
        personId: null,
        active: true,
        operationId: 'external',
      );
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.text('内容已被修改，请返回列表重新打开'), findsOneWidget);
      expect((await store.list(IdentityKind.member)).single.name, '另一修改');
    },
  );

  testWidgets(
    'read failure retries without claiming empty; related management preserves input',
    (tester) async {
      await original();
      var failed = true;
      final reader = IdentityStore(() async {
        if (failed) throw StateError('synthetic read failure');
        return store.database();
      });
      await tester.pumpWidget(
        host(IdentityListPage(kind: IdentityKind.member, store: reader)),
      );
      await settleIo(tester);
      expect(find.text('读取失败，请重试'), findsOneWidget);
      expect(find.text('还没有成员'), findsNothing);
      failed = false;
      await tester.tap(find.text('重试'));
      await settleIo(tester);
      await tester.tap(find.byTooltip('新增成员'));
      await settleIo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        '保留输入',
      );
      await tester.ensureVisible(find.text('管理同人关联'));
      await tester.tap(find.text('管理同人关联'));
      await settleIo(tester);
      await tester.pageBack();
      await settleIo(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('identity-name')))
            .controller!
            .text,
        '保留输入',
      );
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final saved = (await tester.runAsync(
        () => store.list(IdentityKind.member),
      ))!;
      expect(saved.length, 2);
      expect(saved.singleWhere((m) => m.name == '保留输入').groupId, isNull);
    },
  );

  testWidgets(
    'busy identity save blocks repeats and back until one transaction finishes',
    (tester) async {
      await original();
      final gate = Completer<void>();
      final busy = IdentityStore(store.database, afterWrite: () => gate.future);
      try {
        await tester.pumpWidget(
          host(IdentityListPage(kind: IdentityKind.member, store: busy)),
        );
        await settleIo(tester);
        await tester.tap(find.text('晨星 · A'));
        await settleIo(tester);
        await tester.enterText(
          find.byKey(const ValueKey('identity-name')),
          '保存后名字',
        );
        await tester.tap(find.text('保存'));
        await tester.pump();
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.text('放弃修改？'), findsNothing);
        gate.complete();
        await settleIo(tester);
        expect((await store.list(IdentityKind.member)).single.name, '保存后名字');
        expect(
          (await store.history(
            (await store.list(IdentityKind.member)).single,
          )).length,
          2,
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  testWidgets(
    '320/430 at 200 percent and keyboard keep member and person save reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      for (final width in [320.0, 430.0]) {
        for (final kind in IdentityKind.values) {
          tester.view.physicalSize = Size(width, 900);
          await tester.pumpWidget(
            host(IdentityListPage(kind: kind, store: store), scale: 2),
          );
          await settleIo(tester);
          await tester.tap(
            find.byTooltip(kind == IdentityKind.member ? '新增成员' : '新增同人标签'),
          );
          await settleIo(tester);
          if (kind == IdentityKind.member) await select(tester, 'group', '晨星');
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.enterText(
            find.byKey(const ValueKey('identity-name')),
            '大字输入 ${width.toInt()} ${kind.name}',
          );
          await tester.pumpAndSettle();
          final save = find.text('保存');
          expect(tester.getBottomLeft(save).dy, lessThan(620));
          await tester.tap(save);
          await settleIo(tester);
          expect(
            (await store.list(
              kind,
            )).where((e) => e.name == '大字输入 ${width.toInt()} ${kind.name}'),
            hasLength(1),
          );
          expect(tester.takeException(), isNull);
          tester.view.resetViewInsets();
          await tester.pumpWidget(const SizedBox());
        }
      }
    },
  );

  final evidence = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  if (evidence != null) {
    testWidgets(
      'optional actual synthetic identity list and editor visual evidence',
      (tester) async {
        final root = Directory(evidence);
        if (!File('${root.path}/.cheki-ui-evidence').existsSync()) {
          throw StateError('External marked evidence required');
        }
        final person = await store.createPerson(
          name: '同人标签',
          operationId: 'person',
        );
        await store.createMember(
          name: '旧团艺名',
          groupId: group.id,
          personId: person.id,
          colorRgb: 0x90c8ea,
          operationId: 'old',
        );
        final member = await store.createMember(
          name: '新团艺名',
          groupId: otherGroup.id,
          personId: person.id,
          colorRgb: 0xf1a8c6,
          operationId: 'new',
        );
        final font = Platform.environment['COUNT_TOOLS_UI_FONT'];
        if (font != null) {
          final loader = FontLoader('IdentityPreview');
          loader.addFont(
            Future.value(ByteData.sublistView(File(font).readAsBytesSync())),
          );
          await tester.runAsync(loader.load);
        }
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          Future.value(
            ByteData.sublistView(
              File(
                '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytesSync(),
            ),
          ),
        );
        await tester.runAsync(icons.load);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final base = chekiTheme();
        final theme = base.copyWith(
          textTheme: base.textTheme.apply(
            fontFamily: font == null ? null : 'IdentityPreview',
          ),
          appBarTheme: base.appBarTheme.copyWith(
            titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: font == null ? null : 'IdentityPreview',
            ),
          ),
        );
        for (final scale in [1.0, 2.0]) {
          for (final type in ['list', 'edit']) {
            final key = GlobalKey();
            await tester.pumpWidget(
              host(
                type == 'list'
                    ? IdentityListPage(kind: IdentityKind.member, store: store)
                    : IdentityEditPage(
                        kind: IdentityKind.member,
                        store: store,
                        original: member,
                      ),
                scale: scale,
                theme: theme,
                boundary: key,
              ),
            );
            await settleIo(tester);
            await tester.runAsync(() async {
              final shot =
                  await (key.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await shot.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File(
                '${root.path}/identity-$type-320-${scale.toInt()}x.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
              shot.dispose();
            });
            await tester.pumpWidget(const SizedBox());
          }
        }
      },
    );
  }
}
