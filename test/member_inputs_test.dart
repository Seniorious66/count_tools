import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/ui/components.dart';
import 'package:count_tools/cheki/ui/member_inputs.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

List<MemberOption> members() => [
  MemberOption(id: 'a', group: '晨星', name: '同名', color: Colors.white),
  MemberOption(id: 'b', group: '夜航', name: '同名', color: Colors.orange),
  MemberOption(
    id: 'stopped',
    group: '晨星',
    name: '历史成员',
    color: Colors.purple,
    available: false,
  ),
  for (var i = 0; i < 80; i++)
    MemberOption(
      id: 'm$i',
      group: '晨星',
      name: '成员 $i',
      color: Color(0xff228855 + i),
    ),
];

Widget memberHost({
  List<MemberOption>? options,
  List<String> initial = const [],
  ValueChanged<List<String>>? changed,
  double scale = 1,
  bool enabled = true,
  String? error,
  Key? boundaryKey,
  ThemeData? theme,
}) {
  var selected = List<String>.of(initial);
  return MaterialApp(
    theme: theme ?? chekiTheme(),
    builder: (context, child) => RepaintBoundary(
      key: boundaryKey,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
    home: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: StatefulBuilder(
            builder: (context, setState) => MemberMultiSelectField(
              options: options ?? members(),
              selectedIds: selected,
              enabled: enabled,
              errorText: error,
              onChanged: (ids) {
                changed?.call(ids);
                setState(() => selected = ids);
              },
            ),
          ),
        ),
      ),
    ),
  );
}

Widget colorHost({
  required ValueChanged<Color> changed,
  double scale = 1,
  bool enabled = true,
  Key? boundaryKey,
  ThemeData? theme,
}) {
  var color = const Color(0xff123456);
  return MaterialApp(
    theme: theme ?? chekiTheme(),
    builder: (context, child) => RepaintBoundary(
      key: boundaryKey,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: StatefulBuilder(
            builder: (context, setState) => MemberColorField(
              value: color,
              enabled: enabled,
              onChanged: (value) {
                changed(value);
                setState(() => color = value);
              },
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> openMembers(WidgetTester tester) async {
  await tester.tap(find.byType(OutlinedButton));
  await tester.pumpAndSettle();
}

Future<void> search(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const ValueKey('member-search')), query);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'search lazily handles many options and same names by stable ID',
    (tester) async {
      List<String>? result;
      await tester.pumpWidget(memberHost(changed: (ids) => result = ids));
      expect(find.text('晨星 · 同名'), findsNothing);
      await openMembers(tester);
      expect(find.byType(CheckboxListTile).evaluate().length, lessThan(83));
      await search(tester, '同名');
      expect(find.text('晨星 · 同名'), findsOneWidget);
      expect(find.text('夜航 · 同名'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('member-option-a')));
      await tester.pump();
      expect(result, isNull);
      await search(tester, '夜航');
      await tester.tap(find.byKey(const ValueKey('member-option-b')));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, ['a', 'b']);
      expect(() => result!.add('illegal'), throwsUnsupportedError);
      final labels = tester.widgetList<MemberLabel>(find.byType(MemberLabel));
      expect(labels.map((l) => l.color), [Colors.white, Colors.orange]);
      expect(find.text('晨星 · 同名'), findsOneWidget);
      expect(find.text('夜航 · 同名'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('remove-member-a')));
      await tester.pump();
      expect(result, ['b']);
    },
  );

  testWidgets('cancel and system return discard local selection and search', (
    tester,
  ) async {
    var callbacks = 0;
    await tester.pumpWidget(
      memberHost(initial: ['a'], changed: (_) => callbacks++),
    );
    for (final systemBack in [false, true]) {
      await openMembers(tester);
      await search(tester, '夜航');
      await tester.tap(find.byKey(const ValueKey('member-option-b')));
      await tester.pump();
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.text('取消'));
      }
      await tester.pumpAndSettle();
      expect(callbacks, 0);
      expect(find.text('夜航 · 同名'), findsNothing);
      expect(find.text('晨星 · 同名'), findsOneWidget);
    }
    await openMembers(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '',
      '',
    );
  });

  testWidgets(
    'inactive and missing initial IDs remain until explicitly removed',
    (tester) async {
      List<String>? result;
      await tester.pumpWidget(
        memberHost(
          initial: ['stopped', 'missing'],
          changed: (ids) => result = ids,
        ),
      );
      expect(find.text('已停用'), findsOneWidget);
      expect(find.text('成员信息不可用'), findsOneWidget);
      await openMembers(tester);
      await search(tester, '历史');
      expect(
        find.byKey(const ValueKey('member-option-stopped')),
        findsOneWidget,
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, ['stopped', 'missing']);
      await openMembers(tester);
      await search(tester, '历史');
      await tester.tap(find.byKey(const ValueKey('member-option-stopped')));
      await tester.pump();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('member-option-stopped')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, ['missing']);
      await tester.tap(find.byKey(const ValueKey('remove-member-missing')));
      await tester.pump();
      expect(result, isEmpty);
      await openMembers(tester);
      await search(tester, '历史');
      expect(find.text('没有匹配的成员'), findsOneWidget);
    },
  );

  testWidgets(
    'reordered renamed options preserve selection and configuration color',
    (tester) async {
      final options = members().reversed.toList();
      options[options.indexWhere((o) => o.id == 'b')] = MemberOption(
        id: 'b',
        group: '夜航',
        name: '改名',
        color: Colors.yellow,
      );
      List<String>? result;
      await tester.pumpWidget(
        memberHost(
          options: options,
          initial: ['b', 'a'],
          changed: (ids) => result = ids,
        ),
      );
      expect(find.text('夜航 · 改名'), findsOneWidget);
      await openMembers(tester);
      await search(tester, '改名');
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, ['b', 'a']);
      expect(
        tester.widgetList<MemberLabel>(find.byType(MemberLabel)).first.color,
        Colors.yellow,
      );
    },
  );

  testWidgets(
    'empty and no-match are distinct; error and disabled inputs remain legible',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(memberHost(options: [], changed: (_) => calls++));
      await openMembers(tester);
      expect(find.text('还没有可选成员'), findsOneWidget);
      await search(tester, 'x');
      expect(find.text('没有匹配的成员'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        memberHost(
          initial: ['a'],
          enabled: false,
          error: '请选择参与成员',
          changed: (_) => calls++,
        ),
      );
      expect(find.text('请选择参与成员'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'display contracts reject duplicate and empty IDs without Person assumptions',
    () {
      expect(
        () => MemberOption(id: '', group: '晨星', name: 'A', color: Colors.blue),
        throwsArgumentError,
      );
      expect(
        () => MemberMultiSelectField(
          options: [members().first, members().first],
          selectedIds: [],
          onChanged: (_) {},
        ),
        throwsArgumentError,
      );
      expect(
        () => MemberMultiSelectField(
          options: members(),
          selectedIds: ['a', 'a'],
          onChanged: (_) {},
        ),
        throwsArgumentError,
      );
      expect(
        () => MemberMultiSelectField(
          options: members(),
          selectedIds: [''],
          onChanged: (_) {},
        ),
        throwsArgumentError,
      );
    },
  );

  testWidgets('arbitrary RGB preview commits only on confirmation', (
    tester,
  ) async {
    Color? result;
    await tester.pumpWidget(colorHost(changed: (value) => result = value));
    for (final systemBack in [false, true]) {
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      final red = find.byKey(const ValueKey('member-color-红'));
      await tester.ensureVisible(red);
      await tester.drag(red, const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(result, isNull);
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.ensureVisible(find.text('取消'));
        await tester.tap(find.text('取消'));
      }
      await tester.pumpAndSettle();
      expect(result, isNull);
    }
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    for (final channel in const [('红', 47.0), ('绿', 201.0), ('蓝', 19.0)]) {
      final slider = tester.widget<Slider>(
        find.byKey(ValueKey('member-color-${channel.$1}')),
      );
      slider.onChanged!(channel.$2);
      await tester.pump();
    }
    await tester.ensureVisible(find.text('确定'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, const Color(0xff2fc913));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '320/430 large text and keyboard keep search and confirmation usable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      for (final width in [320.0, 430.0]) {
        tester.view.physicalSize = Size(width, 900);
        List<String>? result;
        await tester.pumpWidget(
          memberHost(scale: 2, changed: (ids) => result = ids),
        );
        await openMembers(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await search(tester, '成员 79');
        await tester.tap(find.byKey(const ValueKey('member-option-m79')));
        await tester.pump();
        final confirm = find.text('确定');
        expect(tester.getBottomLeft(confirm).dy, lessThan(620));
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(result, ['m79']);
        tester.view.resetViewInsets();
        await tester.pumpWidget(colorHost(scale: 2, changed: (_) {}));
        await tester.tap(find.byType(OutlinedButton));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('确定'));
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'search checkbox and color sliders expose semantic names and selected state',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(memberHost(initial: ['a']));
        await openMembers(tester);
        await search(tester, '同名');
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('member-option-a')))
              .label,
          contains('晨星 · 同名'),
        );
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('member-option-a')))
              .getSemanticsData()
              .flagsCollection
              .isChecked,
          ui.CheckedState.isTrue,
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(colorHost(changed: (_) {}));
        await tester.tap(find.byType(OutlinedButton));
        await tester.pumpAndSettle();
        final red = find.byKey(const ValueKey('member-color-红'));
        await tester.ensureVisible(red);
        await tester.pumpAndSettle();
        final sliderValues = <String>[];
        tester.getSemantics(red).visitChildren((node) {
          final data = node.getSemanticsData();
          if (data.flagsCollection.isSlider) sliderValues.add(data.value);
          return true;
        });
        expect(sliderValues, ['红 18']);
      } finally {
        handle.dispose();
      }
    },
  );

  final evidenceRoot = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  if (evidenceRoot != null) {
    testWidgets('optional synthetic member input visual evidence', (
      tester,
    ) async {
      final root = Directory(evidenceRoot);
      if (!File('${root.path}/.cheki-ui-evidence').existsSync()) {
        throw StateError('Marked external visual evidence directory required');
      }
      final fontPath = Platform.environment['COUNT_TOOLS_UI_FONT'];
      if (fontPath != null) {
        final loader = FontLoader('MemberInputPreview');
        loader.addFont(
          Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
        );
        await tester.runAsync(loader.load);
      }
      final icon = FontLoader('MaterialIcons');
      icon.addFont(
        Future.value(
          File(
            '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytesSync(),
        ).then(ByteData.sublistView),
      );
      await tester.runAsync(icon.load);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = chekiTheme().copyWith(
        textTheme: chekiTheme().textTheme.apply(
          fontFamily: fontPath == null ? null : 'MemberInputPreview',
        ),
      );
      for (final scale in [1.0, 2.0]) {
        for (final type in ['members', 'color']) {
          final key = GlobalKey();
          await tester.pumpWidget(
            type == 'members'
                ? memberHost(
                    initial: ['a', 'b'],
                    scale: scale,
                    boundaryKey: key,
                    theme: theme,
                  )
                : colorHost(
                    changed: (_) {},
                    scale: scale,
                    boundaryKey: key,
                    theme: theme,
                  ),
          );
          await tester.tap(find.byType(OutlinedButton));
          await tester.pumpAndSettle();
          if (type == 'members') await search(tester, '同名');
          await tester.runAsync(() async {
            final shot =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
            File(
              '${root.path}/$type-320-${scale.toInt()}x.png',
            ).writeAsBytesSync(bytes!.buffer.asUint8List());
            shot.dispose();
          });
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      }
    });
  }
}
