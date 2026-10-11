import 'dart:io';
import 'dart:convert';
import 'package:count_tools/app.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:count_tools/data/database/helper/project_helper.dart';
import 'package:count_tools/data/database/helper/sub_project_helper.dart';
import 'package:count_tools/data/database/helper/item_helper.dart';
import 'package:count_tools/page/count_page/count_page_vm.dart';
import 'package:count_tools/page/count_page/count_page.dart';
import 'package:count_tools/page/home_page/home_page_vm.dart';
import 'package:count_tools/page/project_info_page/project_info_page_vm.dart';
import 'package:count_tools/page/project_info_page/project_info_page.dart';
import 'package:count_tools/page/subproject_info_page/subproject_info_page_vm.dart';
import 'package:count_tools/page/subproject_info_page/subproject_info_page.dart';
import 'package:count_tools/page/setting_page/setting_page.dart';
import 'package:count_tools/utils/setting_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> legacyFixture(String path) async {
  final db = await openDatabase(path);
  await db.execute(
    'CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT,username TEXT NOT NULL,user_key TEXT NOT NULL,ext TEXT)',
  );
  await db.execute(
    'CREATE TABLE project_data(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,subTitle TEXT,count TEXT,ext TEXT)',
  );
  await db.execute(
    'CREATE TABLE sub_project_data(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,count TEXT NOT NULL,countPre TEXT NOT NULL,color TEXT NOT NULL,textColor TEXT NOT NULL,parentId TEXT NOT NULL,ext TEXT)',
  );
  await db.execute(
    'CREATE TABLE item_data(id INTEGER PRIMARY KEY AUTOINCREMENT,price TEXT,eventName TEXT,type TEXT,date TEXT NOT NULL,itemName TEXT NOT NULL,parentId TEXT NOT NULL,projectId TEXT NOT NULL,ext TEXT,unknown_value BLOB)',
  );
  await db.execute(
    'CREATE TABLE unknown_table(id INTEGER PRIMARY KEY,payload BLOB)',
  );
  await db.execute("INSERT INTO project_data VALUES(17,'合成项目',NULL,'1',NULL)");
  await db.execute(
    "INSERT INTO sub_project_data VALUES(41,'合成成员','2','100.0','4280391411','4278190080','17',NULL)",
  );
  await db.execute(
    "INSERT INTO item_data VALUES(91,NULL,NULL,NULL,'2024-01-02 13:14:15','记录','41','17',NULL,X'00FF')",
  );
  await db.execute(
    "INSERT INTO item_data VALUES(92,'25.00','活动','类型','2024-01-03','记录2','41','17','原ext',NULL)",
  );
  await db.execute("INSERT INTO unknown_table VALUES(5,X'FF00')");
  await db.execute(
    "UPDATE sqlite_sequence SET seq=1000 WHERE name='item_data'",
  );
  await db.setVersion(1);
  await db.close();
}

Future<Map<String, Object>> legacyRows(DatabaseExecutor db) async {
  final result = <String, Object>{};
  for (final table in [
    ...StorageSchema.columns.keys,
    'sqlite_sequence',
    'unknown_table',
  ]) {
    result[table] = await db.query(
      table,
      orderBy: table == 'sqlite_sequence' ? 'name' : 'id',
    );
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late String path;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-migration-');
    path = '${scratch.path}/legacy.db';
    DatabaseHelper.pathResolver = () async => path;
    SharedPreferences.setMockInitialValues({
      'isNotFirstEnter': true,
      'themeColor': 'blue',
      'projectInfoRowNum': 5,
      'isShowTotalPrice': true,
      'unknownPreference': ['preserve'],
    });
    await legacyFixture(path);
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  testWidgets('first startup fills only absent preferences', (tester) async {
    SharedPreferences.setMockInitialValues({
      'projectInfoRowNum': 3,
      'isShowTotalPrice': false,
      'unknownPreference': ['keep'],
    });
    await tester.pumpWidget(const App());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final prefs = await tester.runAsync(() => SharedPreferences.getInstance());
    expect(prefs!.getInt('projectInfoRowNum'), 3);
    expect(prefs.getBool('isShowTotalPrice'), false);
    expect(prefs.getString('showMode'), '数量-百分比');
    expect(prefs.getStringList('unknownPreference'), ['keep']);
    expect(prefs.getBool('isNotFirstEnter'), true);
    expect(tester.takeException(), isNull);
  });
  final privateRoot = Platform.environment['COUNT_TOOLS_LEGACY_ACCEPTANCE'];
  if (privateRoot != null) {
    testWidgets('private isolated legacy consumers and cold bootstrap', (
      tester,
    ) async {
      final root = Directory(privateRoot).absolute;
      final marker = jsonDecode(
        File('${root.path}/.acceptance-copy.json').readAsStringSync(),
      );
      expect(marker, {
        'project': 'count_tools',
        'purpose': 'm0-isolated-legacy',
      });
      final file = File('${root.path}/database.sqlite');
      expect(
        FileSystemEntity.typeSync(file.path, followLinks: false),
        FileSystemEntityType.file,
      );
      await DatabaseHelper().close();
      DatabaseHelper.pathResolver = () async => file.path;
      final settings = Map<String, Object>.from(
        jsonDecode(File('${root.path}/preferences.json').readAsStringSync())
            as Map,
      );
      SharedPreferences.setMockInitialValues(settings);
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final db = await DatabaseHelper().database;
        expect(await db.getVersion(), 2);
        final home = HomePageViewModel();
        await home.loadProjects();
        expect(home.projects.length, 1);
        final project = ProjectInfoViewModel(home.projects.single.id);
        await project.loadSubProjects();
        expect(project.subProjects.length, 25);
        expect(project.items.length, 342);
        final stats = CountPageViewModel(home.projects.single.id);
        await stats.loadDatas();
        await stats.loadDatas();
        expect(stats.countNum, 342);
        int read = 0;
        for (final sub in project.subProjects) {
          final records = SubProjectInfoViewModel();
          await records.loadItems(sub.id);
          read += records.items.length;
          records.dispose();
        }
        expect(read, 342);
        home.dispose();
        project.dispose();
        stats.dispose();
      });
      final projects = (await tester.runAsync(() => ProjectDBHelper().get()))!;
      final subs = (await tester.runAsync(() => SubProjectDbHelper().get()))!;
      Future<void> show(Widget page) async {
        await tester.pumpWidget(MaterialApp(home: page));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await show(const App());
      await show(ProjectInfoPage(parentData: projects.single));
      await show(
        SubProjectInfoPage(
          parentData: subs.first,
          projectId: projects.single.id,
        ),
      );
      await show(
        SubProjectInfoPage(
          parentData: subs.last,
          projectId: projects.single.id,
        ),
      );
      await show(CountPage(id: projects.single.id));
      await show(const SettingPage());
      await show(const SizedBox());
      await tester.runAsync(() => DatabaseHelper().close());
      await show(const App());
      await show(const SizedBox());
      final prefs = await tester.runAsync(
        () => SharedPreferences.getInstance(),
      );
      expect({
        for (final key in prefs!.getKeys()) key: prefs.get(key),
      }, settings);
      await tester.runAsync(() => DatabaseHelper().close());
    });
  }
  test(
    'v1 to v2 preserves all facts, unknown fields, sequences and repeated opens',
    () async {
      final old = await openDatabase(path);
      final before = await legacyRows(old);
      await old.close();
      final migrated = await DatabaseHelper().database;
      expect(await migrated.getVersion(), 2);
      expect(await legacyRows(migrated), before);
      await DatabaseHelper().close();
      final reopened = await DatabaseHelper().database;
      expect(await legacyRows(reopened), before);
      expect((await reopened.query(StorageSchema.migrationTable)).length, 1);
    },
  );
  test(
    'failure after DDL rolls back version and facts inside real open transaction',
    () async {
      final old = await openDatabase(path);
      final before = await legacyRows(old);
      await old.close();
      await expectLater(
        openDatabase(
          path,
          version: 2,
          onUpgrade: (db, a, b) => StorageSchema.migrate(
            db,
            a,
            b,
            afterStep: () async => throw StateError('injected'),
          ),
        ),
        throwsA(isA<StateError>()),
      );
      final unchanged = await openDatabase(path);
      expect(await unchanged.getVersion(), 1);
      expect(await legacyRows(unchanged), before);
      expect(
        await unchanged.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='count_tools_migrations'",
        ),
        isEmpty,
      );
      await unchanged.close();
      expect(await (await DatabaseHelper().database).getVersion(), 2);
    },
  );
  test(
    'future versions and invalid relationships reject without reset',
    () async {
      final old = await openDatabase(path);
      await old.setVersion(3);
      await old.close();
      await expectLater(DatabaseHelper().database, throwsA(isA<StateError>()));
      final same = await openDatabase(path);
      expect(await same.getVersion(), 3);
      await same.setVersion(1);
      await same.execute("UPDATE item_data SET parentId='999' WHERE id=91");
      await same.close();
      await expectLater(DatabaseHelper().database, throwsA(isA<StateError>()));
      final invalid = await openDatabase(path);
      expect(await invalid.getVersion(), 1);
      expect(
        (await invalid.query('item_data', where: 'id=91')).single['parentId'],
        '999',
      );
      await invalid.close();
    },
  );
  test(
    'edits preserve NULL, opaque fields and IDs; collisions do not replace',
    () async {
      final projects = await ProjectDBHelper().get();
      await ProjectDBHelper().update(
        projects.single.copyWith(
          title: '改名',
          subTitle: projects.single.subTitle,
        ),
      );
      final sub = (await SubProjectDbHelper().get()).single;
      await SubProjectDbHelper().update(sub.copyWith(name: '改成员'));
      final items = await ItemDBHelper().get();
      await ItemDBHelper().updateAll(
        items
            .map((i) => i.copyWith(eventName: i.eventName, price: i.price))
            .toList(),
      );
      final db = await DatabaseHelper().database;
      expect((await db.query('project_data')).single['subTitle'], isNull);
      expect((await db.query('sub_project_data')).single['ext'], isNull);
      final raw = (await db.query('item_data', where: 'id=91')).single;
      expect(raw['price'], isNull);
      expect(raw['ext'], isNull);
      expect(raw['unknown_value'], [0, 255]);
      expect(raw['date'], '2024-01-02 13:14:15');
      await expectLater(
        ItemDBHelper().insert(items.first.copyWith(itemName: 'should reject')),
        throwsA(isA<DatabaseException>()),
      );
      expect((await db.query('item_data', where: 'id=91')).single, raw);
    },
  );
  test(
    'all read models and cache reloads retain legacy semantics and settings',
    () async {
      final home = HomePageViewModel();
      await home.loadProjects();
      expect(home.projects.length, 1);
      final project = ProjectInfoViewModel('17');
      await project.loadSubProjects();
      expect(project.items.length, 2);
      expect(project.row, 5);
      final records = SubProjectInfoViewModel();
      await records.loadItems('41');
      expect(records.items.length, 2);
      expect(records.cost, contains('1条金额未知'));
      final stats = CountPageViewModel('17');
      await stats.loadDatas();
      await stats.loadDatas();
      expect(stats.countNum, 2);
      expect(await SettingUtils.getProjectInfoRowNum(), 5);
      expect(
        (await SharedPreferences.getInstance()).getStringList(
          'unknownPreference',
        ),
        ['preserve'],
      );
      await project.deleteSubProject('41');
      await DatabaseHelper().close();
      expect((await ProjectDBHelper().get()).single.count, '0');
      expect(await ItemDBHelper().get(), isEmpty);
      home.dispose();
      project.dispose();
      records.dispose();
      stats.dispose();
    },
  );
  testWidgets(
    'legacy home, project, records, statistics and settings render after migration',
    (tester) async {
      await tester.runAsync(() => DatabaseHelper().database);
      final project = (await tester.runAsync(
        () => ProjectDBHelper().get(),
      ))!.single;
      final sub = (await tester.runAsync(
        () => SubProjectDbHelper().get(),
      ))!.single;
      Future<void> show(Widget page) async {
        await tester.pumpWidget(MaterialApp(home: page));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await show(const App());
      expect(find.text('合成项目'), findsOneWidget);
      await show(ProjectInfoPage(parentData: project));
      expect(find.text('合成成员'), findsOneWidget);
      await show(SubProjectInfoPage(parentData: sub, projectId: '17'));
      expect(find.textContaining('金额未知'), findsOneWidget);
      await show(const CountPage(id: '17'));
      await show(const SettingPage());
      await show(const SizedBox());
      await tester.runAsync(() => DatabaseHelper().close());
      await show(const App());
      expect(find.text('合成项目'), findsOneWidget);
    },
  );
  testWidgets(
    'failed bootstrap shows bounded error and does not initialize settings',
    (tester) async {
      await tester.runAsync(() async {
        final db = await openDatabase(path);
        await db.setVersion(3);
        await db.close();
      });
      SharedPreferences.setMockInitialValues({
        'unknownPreference': ['keep'],
      });
      await tester.pumpWidget(const App());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('数据校验未通过'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final prefs = await tester.runAsync(
        () => SharedPreferences.getInstance(),
      );
      expect(prefs!.getBool('isNotFirstEnter'), isNull);
      expect(prefs.getStringList('unknownPreference'), ['keep']);
    },
  );
}
