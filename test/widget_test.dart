import 'dart:io';
import 'package:count_tools/app.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/helper/project_helper.dart';
import 'package:count_tools/data/model/project_data.dart';
import 'package:count_tools/page/component/count_item/color_count_pie_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-test-');
    DatabaseHelper.pathResolver = () async =>
        '${scratch.path}/user_database.db';
    SharedPreferences.setMockInitialValues({
      'themeColor': 'blue',
      'isNotFirstEnter': true,
    });
    await DatabaseHelper().database;
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  test(
    'project writes survive close and reopen with original ID/ext',
    () async {
      final project = ProjectData(
        id: '17',
        title: '隔离项目',
        subTitle: '说明',
        count: '0',
        ext: '{"unknown":1}',
      );
      await ProjectDBHelper().insert(project);
      await DatabaseHelper().close();
      final reopened = await ProjectDBHelper().get();
      expect(reopened.single.toJson(), {...project.toJson(), 'id': 17});
      final connections = await Future.wait([
        DatabaseHelper().database,
        DatabaseHelper().database,
      ]);
      expect(identical(connections[0], connections[1]), isTrue);
    },
  );
  testWidgets('real home shows stored project and offline version settings', (
    tester,
  ) async {
    await tester.runAsync(
      () => ProjectDBHelper().insert(
        ProjectData(
          id: '21',
          title: '合成项目',
          subTitle: '合成说明',
          count: '0',
          ext: '',
        ),
      ),
    );
    await tester.pumpWidget(const App());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    expect(find.text('合成项目'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('版本'), findsOneWidget);
    expect(find.text('0.0.0-m0.1 (11000)'), findsOneWidget);
    expect(find.text('检查更新'), findsNothing);
    expect(find.text('更新推送开关'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty database shows the real add-project entry', (
    tester,
  ) async {
    await tester.pumpWidget(const App());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有项目，点击+添加'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add_project_btn')));
    await tester.pumpAndSettle();
    expect(find.text('新增项目'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => ProjectDBHelper().get()), isEmpty);
  });
  testWidgets(
    'native chart handles zero totals and preserves color/count semantics',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ColorPieChartWidget({Colors.blue: 0})),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ColorPieChartWidget({Colors.blue: 3, Colors.pink: 1}),
          ),
        ),
      );
      expect(find.text('(75.00%)'), findsOneWidget);
      expect(find.text('(25.00%)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
