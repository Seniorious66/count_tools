import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_schema.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late String path;
  late CatalogStore store;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-catalog-');
    path = '${scratch.path}/catalog.sqlite';
    DatabaseHelper.pathResolver = () async => path;
    await legacyFixture(path);
    store = CatalogStore(() => DatabaseHelper().database);
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  test(
    'migration seeds only two sizes; custom four inch is a real definition',
    () async {
      final sizes = await store.list(CatalogKind.size);
      expect(sizes.map((s) => s.name).toSet(), {'三寸', '五寸'});
      expect(await store.list(CatalogKind.group), isEmpty);
      final custom = await store.create(
        CatalogKind.size,
        name: '四寸',
        operationId: 'size-four',
      );
      expect(custom.toRow()['source'], 'user');
      await DatabaseHelper().close();
      expect((await store.list(CatalogKind.size)).map((s) => s.name).toSet(), {
        '三寸',
        '五寸',
        '四寸',
      });
    },
  );
  test(
    'rename and stop preserve IDs, timestamps, history and unknown SQL fields',
    () async {
      final db = await DatabaseHelper().database;
      await db.execute('ALTER TABLE cheki_groups ADD COLUMN unknown_blob BLOB');
      await db.execute(
        "ALTER TABLE cheki_groups ADD COLUMN future_text TEXT DEFAULT '保留'",
      );
      final original = await store.create(
        CatalogKind.group,
        name: '原团体',
        operationId: 'group-create',
      );
      expect(original.toRow()['unknown_blob'], isNull);
      expect(original.toRow()['future_text'], '保留');
      final renamed = await store.edit(
        CatalogKind.group,
        original: original,
        name: '新团体',
        active: true,
        operationId: 'group-rename',
      );
      final stopped = await store.edit(
        CatalogKind.group,
        original: renamed,
        name: renamed.name,
        active: false,
        operationId: 'group-stop',
      );
      expect(stopped.id, original.id);
      expect(stopped.createdAt, original.createdAt);
      expect(stopped.revision, 3);
      expect(stopped.toRow()['future_text'], '保留');
      final history = await store.history(CatalogKind.group, stopped.id);
      expect(history.length, 3);
      expect(decodeSqlRow(history[1]['before_json'] as String)['name'], '原团体');
      expect(decodeSqlRow(history[1]['after_json'] as String)['name'], '新团体');
      expect(
        await store.list(CatalogKind.group, includeInactive: false),
        isEmpty,
      );
      await DatabaseHelper().close();
      final reopened = (await store.list(CatalogKind.group)).single;
      expect(reopened.toRow(), stopped.toRow());
      expect((await store.history(CatalogKind.group, stopped.id)).length, 3);
    },
  );
  test(
    'default-size edit retains opaque BLOB and NULL extension facts',
    () async {
      final db = await DatabaseHelper().database;
      await db.execute(
        "ALTER TABLE cheki_sizes ADD COLUMN unknown_blob BLOB DEFAULT X'00FF'",
      );
      final three = (await store.list(
        CatalogKind.size,
      )).firstWhere((s) => s.id == 'size-3inch');
      final changed = await store.edit(
        CatalogKind.size,
        original: three,
        name: '三寸规格',
        active: true,
        operationId: 'default-rename',
      );
      expect(changed.toRow()['unknown_blob'], Uint8List.fromList([0, 255]));
      expect(changed.toRow()['ext'], isNull);
      await CatalogSchema.validate(db);
      await DatabaseHelper().close();
      expect(
        (await store.list(
          CatalogKind.size,
        )).firstWhere((s) => s.id == three.id).name,
        '三寸规格',
      );
    },
  );
  test(
    'retry returns one recorded result; conflicting retry and stale edit reject',
    () async {
      final first = await store.create(
        CatalogKind.group,
        name: '团体',
        operationId: 'same',
      );
      final retried = await store.create(
        CatalogKind.group,
        name: '团体',
        operationId: 'same',
      );
      expect(retried.toRow(), first.toRow());
      await expectLater(
        store.create(CatalogKind.group, name: '另一个', operationId: 'same'),
        throwsA(isA<CatalogException>()),
      );
      final changed = await store.edit(
        CatalogKind.group,
        original: first,
        name: '改名',
        active: true,
        operationId: 'edit',
      );
      expect(
        (await store.create(
          CatalogKind.group,
          name: '团体',
          operationId: 'same',
        )).name,
        '团体',
      );
      await expectLater(
        store.edit(
          CatalogKind.group,
          original: first,
          name: '过时修改',
          active: true,
          operationId: 'stale',
        ),
        throwsA(isA<CatalogException>()),
      );
      expect(
        (await store.list(CatalogKind.group)).single.toRow(),
        changed.toRow(),
      );
      expect((await store.history(CatalogKind.group, first.id)).length, 2);
    },
  );
  test('failure rolls definition, operation and audit back together', () async {
    final failing = CatalogStore(
      () => DatabaseHelper().database,
      afterWrite: () async => throw StateError('injected'),
    );
    await expectLater(
      failing.create(CatalogKind.group, name: '不应写入', operationId: 'failed'),
      throwsA(isA<StateError>()),
    );
    final db = await DatabaseHelper().database;
    expect(await db.query(CatalogKind.group.table), isEmpty);
    expect(await db.query(CatalogSchema.operations), isEmpty);
    expect(await db.query(CatalogSchema.history), isEmpty);
    expect(
      (await store.create(
        CatalogKind.group,
        name: '可重试',
        operationId: 'failed',
      )).revision,
      1,
    );
  });
  test(
    'real foreign key protection and corrupted audit refuse reopen without reset',
    () async {
      final item = await store.create(
        CatalogKind.group,
        name: '团体',
        operationId: 'create',
      );
      final db = await DatabaseHelper().database;
      expect(
        (await db.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1,
      );
      await expectLater(
        db.delete(CatalogSchema.operations),
        throwsA(isA<DatabaseException>()),
      );
      final request =
          jsonDecode(
                (await db.query(
                      CatalogSchema.operations,
                    )).single['request_json']
                    as String,
              )
              as Map<String, dynamic>;
      request['name'] = '伪造';
      await db.update(CatalogSchema.operations, {
        'request_json': jsonEncode(request),
      });
      await DatabaseHelper().close();
      await expectLater(DatabaseHelper().database, throwsA(isA<StateError>()));
      final inspection = await openDatabase(path);
      expect(await inspection.getVersion(), StorageSchema.version);
      expect(
        (await inspection.query(CatalogKind.group.table)).single['id'],
        item.id,
      );
      expect((await inspection.query(CatalogSchema.history)).length, 1);
      await inspection.close();
    },
  );
  test(
    'schema two migration failure leaves old database and ledger intact',
    () async {
      final v2 = await openDatabase(
        path,
        version: 2,
        onUpgrade: (db, a, b) => StorageSchema.migrate(db, a, b),
      );
      await v2.close();
      await expectLater(
        openDatabase(
          path,
          version: 3,
          onUpgrade: (db, a, b) => StorageSchema.migrate(
            db,
            a,
            b,
            afterStep: () async => throw StateError('injected'),
          ),
        ),
        throwsA(isA<StateError>()),
      );
      final old = await openDatabase(path);
      expect(await old.getVersion(), 2);
      expect((await old.query(StorageSchema.migrationTable)).length, 1);
      expect(
        await old.rawQuery(
          "SELECT name FROM sqlite_master WHERE name LIKE 'cheki_%'",
        ),
        isEmpty,
      );
      expect((await old.query('item_data')).length, 2);
      await old.close();
      expect((await store.list(CatalogKind.size)).length, 2);
    },
  );
  test(
    'invalid JSON SQL values and backwards action clock fail safely',
    () async {
      expect(() => decodeSqlRow('[]'), throwsFormatException);
      expect(() => decodeSqlRow('{"ext":true}'), throwsFormatException);
      expect(
        () => decodeSqlRow('{"ext":{"arbitrary":1}}'),
        throwsFormatException,
      );
      final original = await store.create(
        CatalogKind.group,
        name: '团体',
        operationId: 'create',
      );
      final reversed = CatalogStore(
        () => DatabaseHelper().database,
        clock: () => DateTime.utc(2000),
      );
      await expectLater(
        reversed.edit(
          CatalogKind.group,
          original: original,
          name: '错误时间',
          active: false,
          operationId: 'reversed',
        ),
        throwsA(isA<CatalogException>()),
      );
      expect(
        (await store.list(CatalogKind.group)).single.toRow(),
        original.toRow(),
      );
    },
  );
  final acceptance = Platform.environment['COUNT_TOOLS_CATALOG_ACCEPTANCE'];
  if (acceptance != null) {
    test(
      'export marked synthetic application database for full recovery checks',
      () async {
        final root = Directory(acceptance).absolute;
        expect(root.path.startsWith(Directory.current.absolute.path), isFalse);
        expect(
          jsonDecode(
            File('${root.path}/.catalog-acceptance.json').readAsStringSync(),
          ),
          {'project': 'count_tools', 'purpose': 'm1-synthetic-catalog'},
        );
        final target = File('${root.path}/database.sqlite');
        expect(target.existsSync(), isFalse);
        final db = await DatabaseHelper().database;
        await db.execute(
          "ALTER TABLE cheki_sizes ADD COLUMN unknown_blob BLOB DEFAULT X'00FF'",
        );
        final group = await store.create(
          CatalogKind.group,
          name: '合成团体',
          operationId: 'acceptance-create',
        );
        final renamed = await store.edit(
          CatalogKind.group,
          original: group,
          name: '合成改名',
          active: true,
          operationId: 'acceptance-rename',
        );
        await store.edit(
          CatalogKind.group,
          original: renamed,
          name: renamed.name,
          active: false,
          operationId: 'acceptance-stop',
        );
        final size = (await store.list(
          CatalogKind.size,
        )).firstWhere((s) => s.id == 'size-3inch');
        await store.edit(
          CatalogKind.size,
          original: size,
          name: '三寸规格',
          active: true,
          operationId: 'acceptance-size',
        );
        await store.create(
          CatalogKind.size,
          name: '四寸',
          operationId: 'acceptance-four',
        );
        await StorageSchema.validate(db, StorageSchema.version);
        await DatabaseHelper().close();
        File(path).copySync(target.path);
        File('${root.path}/preferences.json').writeAsStringSync(
          jsonEncode({
            'themeColor': 'blue',
            'enabled': true,
            'count': 7,
            'fraction': 1.25,
            'labels': ['合成', '未知偏好'],
            'opaque': '保留原文',
          }),
        );
        File(
          '${root.path}/synthetic-attachment',
        ).writeAsBytesSync([0, 255, 1, 2]);
      },
    );
  }
}
