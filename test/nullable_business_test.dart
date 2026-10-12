import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/ui/catalog_pages.dart';
import 'package:count_tools/cheki/ui/identity_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'catalog_pages_test.dart' show settleIo;
import 'storage_migration_test.dart' show legacyFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late String path;
  final instant = DateTime.utc(2030, 1, 1);
  late IdentityStore identities;
  late CatalogStore catalog;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-nullable-');
    path = '${scratch.path}/database.sqlite';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () async => path;
    identities = IdentityStore(
      () => DatabaseHelper().database,
      clock: () => instant,
    );
    catalog = CatalogStore(identities.database, clock: () => instant);
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });

  test(
    'all business information may be blank; later completion retains identity creation and audit',
    () async {
      final group = await catalog.create(
        CatalogKind.group,
        name: '',
        operationId: 'empty-group',
      );
      final size = await catalog.create(
        CatalogKind.size,
        name: ' ',
        operationId: 'empty-size',
      );
      final person = await identities.createPerson(
        name: '',
        operationId: 'empty-person',
      );
      final member = await identities.createMember(
        name: '',
        operationId: 'empty-member',
      );
      expect([
        group.knownName,
        size.knownName,
        person.knownName,
        member.knownName,
        member.groupId,
        member.colorRgb,
      ], everyElement(isNull));
      expect(await identities.validateSelection([]), isEmpty);
      expect(
        (await identities.validateSelection([member.id])).single.id,
        member.id,
      );
      final completed = await identities.editMember(
        original: member,
        name: '旧信息成员',
        fillGroupId: group.id,
        colorRgb: 0xff8899,
        personId: person.id,
        active: true,
        operationId: 'complete-member',
      );
      expect(completed.id, member.id);
      expect(completed.createdAt, member.createdAt);
      expect(completed.groupId, group.id);
      final history = await identities.history(completed);
      expect(
        decodeSqlRow(history.last['before_json'] as String)['group_id'],
        isNull,
      );
      expect(
        decodeSqlRow(history.last['before_json'] as String)['name'],
        isNull,
      );
      await DatabaseHelper().close();
      final reopened = (await identities.list(IdentityKind.member)).single;
      expect(reopened.toRow(), completed.toRow());
      await StorageSchema.validate(
        await identities.database(),
        StorageSchema.version,
      );
      expect(
        () => identities.editMember(
          original: completed,
          name: 'A',
          fillGroupId: group.id,
          colorRgb: null,
          personId: person.id,
          active: true,
          operationId: 'overwrite-known-group',
        ),
        throwsA(isA<CatalogException>()),
      );
    },
  );

  Future<Map<String, Object?>> facts(Database db) async => {
    'version': await db.getVersion(),
    'objects': await db.rawQuery(
      'SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name',
    ),
    'tables': {
      for (final t in await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      ))
        t['name'] as String: await db.query(t['name'] as String),
    },
  };
  Future<Database> four() async => openDatabase(
    path,
    version: 4,
    onConfigure: (db) => db.execute('PRAGMA foreign_keys=ON'),
    onUpgrade: StorageSchema.migrate,
  );
  test(
    'schema four relaxation preserves all prior rows unknown columns indexes triggers and audits',
    () async {
      final old = await four();
      final c = CatalogStore(() async => old, clock: () => instant);
      final i = IdentityStore(() async => old, clock: () => instant);
      await old.execute(
        "ALTER TABLE cheki_members ADD COLUMN opaque_blob BLOB DEFAULT X'00FF'",
      );
      await old.execute('CREATE INDEX opaque_name ON cheki_members(name)');
      await old.execute('CREATE TABLE unknown_touch_log(value TEXT)');
      await old.execute(
        "CREATE TRIGGER opaque_insert AFTER INSERT ON cheki_members BEGIN INSERT INTO unknown_touch_log VALUES(new.id); END",
      );
      final g = await c.create(CatalogKind.group, name: '旧团', operationId: 'g');
      await i.createMember(
        name: '历史成员',
        groupId: g.id,
        colorRgb: 0,
        operationId: 'm',
      );
      final before = await facts(old);
      await old.close();
      final upgraded = await DatabaseHelper().database;
      final after = await facts(upgraded);
      for (final entry in (before['tables'] as Map).entries) {
        if (entry.key != StorageSchema.migrationTable) {
          expect((after['tables'] as Map)[entry.key], entry.value);
        }
      }
      expect(
        await upgraded.query('unknown_touch_log'),
        (before['tables'] as Map)['unknown_touch_log'],
      );
      expect(
        (await upgraded.query('cheki_members')).single['opaque_blob'],
        Uint8List.fromList([0, 255]),
      );
      final untouched = (before['objects'] as List)
          .where(
            (r) => ![
              'cheki_groups',
              'cheki_sizes',
              'cheki_persons',
              'cheki_members',
            ].contains((r as Map)['name']),
          )
          .toList();
      final afterUntouched = (after['objects'] as List)
          .where(
            (r) => ![
              'cheki_groups',
              'cheki_sizes',
              'cheki_persons',
              'cheki_members',
            ].contains((r as Map)['name']),
          )
          .toList();
      expect(
        afterUntouched
            .where(
              (r) => !(r as Map)['name'].toString().contains('cheki_record'),
            )
            .toList(),
        untouched,
      );
      await identities.createMember(
        name: '',
        operationId: 'blank-after-migration',
      );
      expect((await upgraded.query('unknown_touch_log')).length, 2);
    },
  );
  test(
    'failed nullable DDL restores every original object row and version',
    () async {
      final old = await four();
      final before = await facts(old);
      await old.close();
      await expectLater(
        openDatabase(
          path,
          version: StorageSchema.version,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys=ON'),
          onUpgrade: (db, from, to) => StorageSchema.migrate(
            db,
            from,
            to,
            afterStep: () async => throw StateError('fault after nullable DDL'),
          ),
        ),
        throwsA(anything),
      );
      final check = await openDatabase(path, readOnly: true);
      expect(await facts(check), before);
      await check.close();
    },
  );
  test(
    'unknown external foreign keys refuse migration without cascading any original fact',
    () async {
      final old = await four();
      await old.execute(
        'CREATE TABLE unknown_reference(id TEXT REFERENCES cheki_groups(id) ON DELETE CASCADE)',
      );
      final c = CatalogStore(() async => old, clock: () => instant);
      final group = await c.create(
        CatalogKind.group,
        name: '原值',
        operationId: 'g',
      );
      await old.insert('unknown_reference', {'id': group.id});
      final before = await facts(old);
      await old.close();
      await expectLater(DatabaseHelper().database, throwsA(anything));
      final check = await openDatabase(path, readOnly: true);
      expect(await facts(check), before);
      await check.close();
    },
  );

  test(
    'all empty record fields preserve NULL and missing keys without quick-entry defaults',
    () {
      final blank = RecordInformation.fromMap({});
      expect(blank.toMap(), isEmpty);
      expect([
        blank.quantity,
        blank.occurredOn,
        blank.sizeId,
        blank.memberIds,
        blank.signature,
        blank.backSigned,
        blank.receivedQuantity,
        blank.receiptStatus,
      ], everyElement(isNull));
      final nulls = RecordInformation.fromMap({
        for (final k in [
          'quantity',
          'occurred_on',
          'size_id',
          'member_ids',
          'attributes',
          'receipt_batches',
          'note',
          'cost_reference',
        ])
          k: null,
      });
      expect(RecordInformation.decode(nulls.encode()).toMap(), nulls.toMap());
      expect(blank.missingFields, isNotEmpty);
    },
  );
  test(
    'legacy-only information and unknowns survive selective completion and clearing',
    () {
      final old = <String, Object?>{
        'legacy_raw': {
          'id': 7,
          'price': '30.00',
          'date': '原始日期时刻',
          'ext': null,
          'unknown': {
            'v': [null, 1, '原文'],
          },
        },
      };
      final r = RecordInformation.fromMap(old);
      (old['legacy_raw'] as Map)['price'] = '外部改变';
      final filled = r.patch({
        'occurred_on': '2026-10-11',
        'quantity': 3,
        'member_ids': ['a'],
        'attributes': {'kind': 'unsigned', 'back_signed': false},
      });
      expect(filled.quantity, 3);
      expect(filled.receiptStatus, isNull);
      expect((filled.toMap()['legacy_raw'] as Map)['price'], '30.00');
      expect(filled.patch({'quantity': null}).quantity, isNull);
      expect(RecordInformation.decode(filled.encode()).toMap(), filled.toMap());
    },
  );
  test(
    'known valid fields contribute independently and absent actual receipt time remains unknown',
    () {
      final r = RecordInformation.fromMap({
        'quantity': 3,
        'receipt_batches': [
          {
            'quantity': 1,
            'origin': 'actual',
            'received_at': null,
            'opaque': null,
          },
        ],
      });
      expect(r.receiptStatus, ReceiptStatus.partial);
      expect(r.missingFields, contains('实际领取时间'));
      final completed = r.patch({
        'occurred_on': '2026-10-11',
        'receipt_batches': [
          {
            'quantity': 1,
            'origin': 'actual',
            'received_at': '2026-10-12T03:00:00.123456Z',
            'opaque': null,
          },
        ],
      });
      expect(completed.receiptStatus, ReceiptStatus.partial);
      expect(completed.toMap()['receipt_batches'], [
        {
          'quantity': 1,
          'origin': 'actual',
          'received_at': '2026-10-12T03:00:00.123456Z',
          'opaque': null,
        },
      ]);
      final unreceived = RecordInformation.fromMap({
        'quantity': 3,
        'receipt_batches': [],
      });
      expect(unreceived.receiptStatus, ReceiptStatus.unreceived);
    },
  );
  test(
    'empty does not bypass checks for malformed supplied data contradictory attributes or over-receipt',
    () {
      for (final invalid in <Map<String, Object?>>[
        {'quantity': 0},
        {'quantity': -1},
        {'quantity': 1.5},
        {'quantity': '1'},
        {'occurred_on': '2026-02-30'},
        {'occurred_on': ''},
        {
          'member_ids': ['a', 'a'],
        },
        {
          'attributes': {'kind': 'unsigned', 'back_signed': true},
        },
        {
          'quantity': 1,
          'receipt_batches': [
            {'quantity': 2, 'origin': 'actual', 'received_at': null},
          ],
        },
        {
          'receipt_batches': [
            {'quantity': 1, 'origin': 'actual', 'received_at': 'invalid'},
          ],
        },
        {'unknown': double.nan},
      ]) {
        expect(
          () => RecordInformation.fromMap(invalid),
          throwsA(isA<FormatException>()),
        );
      }
    },
  );
  testWidgets(
    'actual forms save blank group and member then complete missing group without writing placeholders',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: CatalogListPage(kind: CatalogKind.group, store: catalog),
        ),
      );
      await settleIo(tester);
      await tester.tap(find.byTooltip('新增团体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final groups = (await tester.runAsync(
        () => catalog.list(CatalogKind.group),
      ))!;
      expect(groups.single.knownName, isNull);
      expect(find.text('未填写名称'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          theme: chekiTheme(),
          home: IdentityListPage(kind: IdentityKind.member, store: identities),
        ),
      );
      await settleIo(tester);
      await tester.tap(find.byTooltip('新增成员'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      var members = (await tester.runAsync(
        () => identities.list(IdentityKind.member),
      ))!;
      expect(members.single.groupId, isNull);
      expect(members.single.colorRgb, isNull);
      expect(members.single.knownName, isNull);
      await tester.tap(find.byKey(ValueKey('identity-${members.single.id}')));
      await settleIo(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('identity-name')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const ValueKey('identity-name')),
        '补录成员',
      );
      final dropdown = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('identity-group-'),
      );
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('未填写名称').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      members = (await tester.runAsync(
        () => identities.list(IdentityKind.member),
      ))!;
      expect(members.single.groupId, groups.single.id);
      expect(members.single.knownName, '补录成员');
      expect(members.single.colorRgb, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  final exportRoot = Platform.environment['COUNT_TOOLS_NULLABLE_ACCEPTANCE'];
  if (exportRoot != null) {
    test(
      'export actual blank and completed synthetic entities for full recovery',
      () async {
        final root = Directory(exportRoot).absolute;
        expect(
          File('${root.path}/.nullable-acceptance.json').existsSync(),
          isTrue,
        );
        expect(File('${root.path}/database.sqlite').existsSync(), isFalse);
        final g = await catalog.create(
          CatalogKind.group,
          name: '',
          operationId: 'blank-g',
        );
        await catalog.create(
          CatalogKind.size,
          name: '',
          operationId: 'blank-s',
        );
        await identities.createPerson(name: '', operationId: 'blank-p');
        final m = await identities.createMember(
          name: '',
          operationId: 'blank-m',
        );
        await identities.editMember(
          original: m,
          name: '补录后',
          fillGroupId: g.id,
          colorRgb: null,
          personId: null,
          active: true,
          operationId: 'fill-m',
        );
        await identities.createMember(name: '', operationId: 'remaining-blank');
        final records = RecordStore(identities.database, clock: () => instant);
        await records.save(
          RecordInformation.fromMap({}),
          operationId: 'blank-record',
        );
        final old = await records.save(
          RecordInformation.fromMap({
            'legacy_raw': {
              'id': 91,
              'date': '2024-01-02 13:14:15',
              'ext': null,
              'price': '25.00',
              'opaque': {
                'values': [null, '原值'],
              },
            },
            'member_ids': [m.id],
          }),
          operationId: 'legacy-record',
        );
        await records.save(
          old.information.patch({'quantity': 3, 'occurred_on': '2024-01-02'}),
          original: old,
          operationId: 'fill-record',
        );
        await StorageSchema.validate(
          await identities.database(),
          StorageSchema.version,
        );
        await DatabaseHelper().close();
        File(path).copySync('${root.path}/database.sqlite');
        File('${root.path}/preferences.json').writeAsStringSync(
          jsonEncode({
            'known': true,
            'opaque': ['原文', '保留'],
          }),
        );
        File('${root.path}/synthetic-attachment').writeAsBytesSync([0, 255, 1]);
      },
    );
  }
}
