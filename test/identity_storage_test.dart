import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/identity_schema.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late String path;
  late IdentityStore store;
  late CatalogStore catalog;
  late CatalogEntity group, otherGroup;
  final stamp = DateTime.utc(2030, 1, 1);
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-identity-');
    path = '${scratch.path}/identity.sqlite';
    DatabaseHelper.pathResolver = () async => path;
    await legacyFixture(path);
    store = IdentityStore(() => DatabaseHelper().database, clock: () => stamp);
    catalog = CatalogStore(() => DatabaseHelper().database, clock: () => stamp);
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
  Future<IdentityEntity> member(
    String op, {
    String? personId,
    String? groupId,
  }) => store.createMember(
    name: '同名',
    groupId: groupId ?? group.id,
    colorRgb: 0x22ff44,
    personId: personId,
    operationId: op,
  );

  test(
    'same names stay distinct until an explicit Person link, also after cold reopen',
    () async {
      final a = await member('a'), b = await member('b');
      expect(a.id, isNot(b.id));
      expect(a.personId, isNull);
      expect(await store.list(IdentityKind.person), isEmpty);
      final p = await store.createPerson(
        name: '自己指定的同人标签',
        operationId: 'person',
      );
      final linked = await store.editMember(
        original: b,
        name: b.name,
        colorRgb: b.colorRgb!,
        personId: p.id,
        active: true,
        operationId: 'link',
      );
      expect(linked.personId, p.id);
      expect(
        (await store.list(
          IdentityKind.member,
        )).firstWhere((m) => m.id == a.id).personId,
        isNull,
      );
      await DatabaseHelper().close();
      expect((await store.list(IdentityKind.member)).length, 2);
      expect((await store.list(IdentityKind.person)).single.id, p.id);
    },
  );

  test(
    'rename color and stop preserve raw SQL values, old names, ID and creation action',
    () async {
      final db = await DatabaseHelper().database;
      await db.execute(
        "ALTER TABLE cheki_members ADD COLUMN future_blob BLOB DEFAULT X'00FF'",
      );
      await db.execute('ALTER TABLE cheki_members ADD COLUMN future_null TEXT');
      final a = await member('a');
      final editor = IdentityStore(
        () => DatabaseHelper().database,
        clock: () => stamp.add(const Duration(days: 1)),
      );
      final changed = await editor.editMember(
        original: a,
        name: '新艺名',
        colorRgb: 0xffffff,
        personId: null,
        active: false,
        operationId: 'edit',
      );
      expect(changed.id, a.id);
      expect(changed.createdAt, a.createdAt);
      expect(changed.updatedAt, isNot(a.updatedAt));
      expect(changed.toRow()['future_blob'], Uint8List.fromList([0, 255]));
      expect(changed.toRow()['future_null'], isNull);
      final history = await store.history(changed);
      expect(history.length, 2);
      expect(decodeSqlRow(history.last['before_json'] as String)['name'], '同名');
      expect(
        decodeSqlRow(history.last['after_json'] as String)['color_rgb'],
        0xffffff,
      );
      expect(
        await store.list(IdentityKind.member, includeInactive: false),
        isEmpty,
      );
      await DatabaseHelper().close();
      expect((await store.list(IdentityKind.member)).single.active, isFalse);
      expect((await store.history(changed)).length, 2);
    },
  );

  test(
    'transfer creates new group identity and retains original identity and Person',
    () async {
      final p = await store.createPerson(name: 'P', operationId: 'p');
      final a = await member('a', personId: p.id);
      final b = await store.transferMember(
        original: a,
        groupId: otherGroup.id,
        name: '新团艺名',
        operationId: 'transfer',
      );
      expect(b.id, isNot(a.id));
      expect(b.groupId, otherGroup.id);
      expect(b.personId, p.id);
      expect(b.colorRgb, a.colorRgb);
      expect(
        (await store.list(
          IdentityKind.member,
        )).firstWhere((m) => m.id == a.id).toRow(),
        a.toRow(),
      );
      expect((await store.history(a)).length, 1);
      expect((await store.history(b)).length, 1);
      await DatabaseHelper().close();
      expect((await store.list(IdentityKind.member)).map((m) => m.id).toSet(), {
        a.id,
        b.id,
      });
    },
  );

  test(
    'selection enforces one identity per linked Person but permits different people across groups',
    () async {
      final p = await store.createPerson(name: 'P', operationId: 'p');
      final a = await member('a', personId: p.id);
      final b = await member('b', groupId: otherGroup.id, personId: p.id);
      final c = await member('c', groupId: otherGroup.id);
      expect(
        () => store.validateSelection([a.id, b.id]),
        throwsA(isA<CatalogException>()),
      );
      expect((await store.validateSelection([a.id, c.id])).map((m) => m.id), [
        a.id,
        c.id,
      ]);
      expect(
        () => store.validateSelection([a.id, a.id]),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => store.validateSelection(['missing']),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => store.validateSelection([]),
        throwsA(isA<CatalogException>()),
      );
      final stopped = await store.editMember(
        original: c,
        name: c.name,
        colorRgb: c.colorRgb!,
        personId: null,
        active: false,
        operationId: 'stop',
      );
      expect(
        () => store.validateSelection([stopped.id]),
        throwsA(isA<CatalogException>()),
      );
      expect(
        (await store.validateSelection(
          [stopped.id],
          retainedIds: {stopped.id},
        )).single.id,
        stopped.id,
      );
    },
  );

  test(
    'same operation retry is idempotent after edits; stale and cross-service reuse rejected',
    () async {
      final a = await member('a');
      final changed = await store.editMember(
        original: a,
        name: '改名',
        colorRgb: a.colorRgb!,
        personId: null,
        active: true,
        operationId: 'edit',
      );
      expect((await member('a')).toRow(), a.toRow());
      expect(
        (await store.list(IdentityKind.member)).single.revision,
        changed.revision,
      );
      expect(
        () => store.createPerson(name: 'P', operationId: 'a'),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => store.editMember(
          original: a,
          name: '旧输入',
          colorRgb: a.colorRgb!,
          personId: null,
          active: true,
          operationId: 'stale',
        ),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => store.createPerson(name: 'P', operationId: 'group-a'),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => catalog.create(CatalogKind.size, name: '四寸', operationId: 'a'),
        throwsA(isA<CatalogException>()),
      );
      expect((await store.history(changed)).length, 2);
    },
  );

  test('fault rolls back definition, operation and audit together', () async {
    final faulty = IdentityStore(
      () => DatabaseHelper().database,
      clock: () => stamp,
      afterWrite: () async => throw StateError('injected failure'),
    );
    expect(
      () => faulty.createPerson(name: 'P', operationId: 'failure'),
      throwsStateError,
    );
    final db = await DatabaseHelper().database;
    for (final table in [
      'cheki_persons',
      'cheki_members',
      IdentitySchema.operations,
      IdentitySchema.history,
    ]) {
      expect(await db.query(table), isEmpty);
    }
    final a = await member('a');
    expect(
      () => faulty.editMember(
        original: a,
        name: '失败改名',
        colorRgb: 0,
        personId: null,
        active: false,
        operationId: 'failed-edit',
      ),
      throwsStateError,
    );
    expect((await store.list(IdentityKind.member)).single.toRow(), a.toRow());
    await IdentitySchema.validate(db);
  });

  test(
    'foreign keys and stop rules protect current references without deleting history',
    () async {
      final p = await store.createPerson(name: 'P', operationId: 'p');
      final a = await member('a', personId: p.id);
      final db = await DatabaseHelper().database;
      expect(
        () => db.delete('cheki_groups', where: 'id=?', whereArgs: [group.id]),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        () => db.delete('cheki_persons', where: 'id=?', whereArgs: [p.id]),
        throwsA(isA<DatabaseException>()),
      );
      await store.editPerson(
        original: p,
        name: p.name,
        active: false,
        operationId: 'person-stop',
      );
      expect(
        () => member('new-link', personId: p.id),
        throwsA(isA<CatalogException>()),
      );
      await store.editMember(
        original: a,
        name: '色变',
        colorRgb: 0xabcdef,
        personId: p.id,
        active: true,
        operationId: 'color',
      );
      await catalog.edit(
        CatalogKind.group,
        original: group,
        name: group.name,
        active: false,
        operationId: 'group-stop',
      );
      expect(() => member('bad-group'), throwsA(isA<CatalogException>()));
      expect(
        () => store.validateSelection([a.id]),
        throwsA(isA<CatalogException>()),
      );
      expect(
        (await store.validateSelection(
          [a.id],
          retainedIds: {a.id},
        )).single.personId,
        p.id,
      );
      await DatabaseHelper().close();
      expect((await store.list(IdentityKind.member)).single.colorRgb, 0xabcdef);
    },
  );

  test(
    'invalid input and backwards action clock reject without writes',
    () async {
      final p = await store.createPerson(name: 'P', operationId: 'p');
      final a = await member('a', personId: p.id);
      for (final color in [-1, 0x1000000]) {
        expect(
          () => store.createMember(
            name: 'A',
            groupId: group.id,
            colorRgb: color,
            operationId: 'bad-$color',
          ),
          throwsA(isA<CatalogException>()),
        );
      }
      expect(
        () => store.createPerson(name: ' ', operationId: 'blank'),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => member('bad-person', personId: 'missing'),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => member('bad-group', groupId: 'missing'),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => store.transferMember(
          original: a,
          groupId: group.id,
          name: a.name,
          operationId: 'same-group',
        ),
        throwsA(isA<CatalogException>()),
      );
      final backwards = IdentityStore(
        () => DatabaseHelper().database,
        clock: () => stamp.subtract(const Duration(seconds: 1)),
      );
      expect(
        () => backwards.editPerson(
          original: p,
          name: '变',
          active: true,
          operationId: 'clock',
        ),
        throwsA(isA<CatalogException>()),
      );
      expect(
        () => backwards.transferMember(
          original: a,
          groupId: otherGroup.id,
          name: a.name,
          operationId: 'transfer-clock',
        ),
        throwsA(isA<CatalogException>()),
      );
      expect((await store.list(IdentityKind.member)).single.toRow(), a.toRow());
    },
  );

  for (final corruption in ['current', 'request', 'missing-history']) {
    test(
      'opening rejects identity $corruption corruption without resetting source',
      () async {
        await member('a');
        final db = await DatabaseHelper().database;
        if (corruption == 'current') {
          await db.rawUpdate("UPDATE cheki_members SET name='损坏'");
        } else if (corruption == 'request') {
          await db.rawUpdate(
            "UPDATE cheki_identity_operations SET request_json='{}'",
          );
        } else {
          await db.delete(IdentitySchema.history);
        }
        await DatabaseHelper().close();
        final bytes = File(path).readAsBytesSync();
        expect(() => DatabaseHelper().database, throwsA(anything));
        expect(File(path).readAsBytesSync(), bytes);
      },
    );
  }

  test(
    'step four DDL failure retains complete schema three and original ledger',
    () async {
      await DatabaseHelper().close();
      final oldPath = '${scratch.path}/three.sqlite';
      await legacyFixture(oldPath);
      final old = await openDatabase(
        oldPath,
        version: 3,
        onUpgrade: StorageSchema.migrate,
      );
      Future<Map<String, Object?>> facts(Database database) async {
        final tables = await database.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
        );
        return {
          'version': await database.getVersion(),
          'objects': await database.rawQuery(
            'SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name',
          ),
          'tables': {
            for (final table in tables)
              table['name'] as String: await database.rawQuery(
                'SELECT * FROM "${(table['name'] as String).replaceAll('"', '""')}"',
              ),
          },
        };
      }

      final before = await facts(old);
      await old.close();
      expect(
        () => openDatabase(
          oldPath,
          version: 4,
          onUpgrade: (db, from, to) => StorageSchema.migrate(
            db,
            from,
            to,
            afterStep: () async => throw StateError('DDL fault'),
          ),
        ),
        throwsA(anything),
      );
      final inspection = await openDatabase(oldPath, readOnly: true);
      expect(await inspection.getVersion(), 3);
      expect(
        await inspection.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='cheki_members'",
        ),
        isEmpty,
      );
      expect((await inspection.query(StorageSchema.migrationTable)).length, 2);
      expect(await facts(inspection), before);
      await inspection.close();
    },
  );

  final exportRoot = Platform.environment['COUNT_TOOLS_IDENTITY_ACCEPTANCE'];
  if (exportRoot != null) {
    test(
      'export actual marked synthetic identity database for complete recovery',
      () async {
        final root = Directory(exportRoot).absolute;
        expect(root.path.startsWith(Directory.current.absolute.path), isFalse);
        expect(
          jsonDecode(
            File('${root.path}/.identity-acceptance.json').readAsStringSync(),
          ),
          {'project': 'count_tools', 'purpose': 'm1-synthetic-identity'},
        );
        final target = File('${root.path}/database.sqlite');
        expect(target.existsSync(), isFalse);
        final db = await DatabaseHelper().database;
        await db.execute(
          "ALTER TABLE cheki_members ADD COLUMN unknown_blob BLOB DEFAULT X'00FF'",
        );
        await db.execute(
          'ALTER TABLE cheki_persons ADD COLUMN future_null TEXT',
        );
        final p = await store.createPerson(name: '同人标签', operationId: 'p');
        final a = await member('a', personId: p.id);
        final renamed = await store.editMember(
          original: a,
          name: '旧团改名',
          colorRgb: 0xff88aa,
          personId: p.id,
          active: true,
          operationId: 'rename',
        );
        final transferred = await store.transferMember(
          original: renamed,
          groupId: otherGroup.id,
          name: '新团艺名',
          operationId: 'transfer',
        );
        await store.editMember(
          original: renamed,
          name: renamed.name,
          colorRgb: renamed.colorRgb!,
          personId: p.id,
          active: false,
          operationId: 'stop',
        );
        await member('unlinked');
        expect(transferred.personId, p.id);
        await StorageSchema.validate(db, 4);
        await DatabaseHelper().close();
        File(path).copySync(target.path);
        File('${root.path}/preferences.json').writeAsStringSync(
          jsonEncode({
            'isNotFirstEnter': true,
            'themeColor': 0xff335577,
            'row': 5,
            'sort': '升序',
            'showMode': '数量',
            'totalPrice': false,
            'unknown_setting': ['原值', '保留'],
          }),
        );
        File(
          '${root.path}/synthetic-attachment',
        ).writeAsBytesSync([1, 2, 0, 255]);
      },
    );
  }
}
