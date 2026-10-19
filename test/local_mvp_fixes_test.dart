import 'dart:io';
import 'dart:convert';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/ui/identity_pages.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/compact_record.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'catalog_pages_test.dart' show settleIo;
import 'identity_pages_test.dart' show select;
import 'storage_migration_test.dart' show legacyFixture;

void main() {
  late Directory scratch;
  late RecordStore records;
  late IdentityStore identities;
  late CatalogStore catalog;
  late String member;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-local-fixes-');
    await legacyFixture('${scratch.path}/user_database.db');
    DatabaseHelper.pathResolver = () async =>
        '${scratch.path}/user_database.db';
    records = RecordStore(() => DatabaseHelper().database);
    identities = IdentityStore(records.database);
    catalog = CatalogStore(records.database);
    final db = await records.database();
    await db.update(
      'sub_project_data',
      {'color': '#12abEF'},
      where: 'id=?',
      whereArgs: [41],
    );
    member = (await identities.createMember(
      name: 'A',
      operationId: 's25-legacy-member:41',
    )).id;
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  RecordInformation info({
    String? day = '2026-05-23',
    int quantity = 1,
    Map<String, Object?> extra = const {},
  }) => RecordInformation.fromMap({
    'occurred_on': day,
    'quantity': quantity,
    'member_ids': [member],
    'size_id': 'size-3inch',
    'attributes': {'kind': 'signed', 'back_signed': false},
    'receipt_batches': [
      {'quantity': quantity, 'origin': 'legacyUnknown'},
    ],
    ...extra,
  });
  test(
    'inherited legacy HEX uses stable migration ID and never rewrites rows',
    () async {
      final db = await records.database();
      final before = await db.query('cheki_members');
      final audit = await db.query('cheki_identity_history');
      await identities.createMember(
        name: 'A',
        operationId: 'ordinary-same-name',
      );
      var directory = await identities.directory();
      expect(
        directory.members.singleWhere((m) => m.id == member).colorRgb,
        0x12abef,
      );
      expect(
        directory.members.singleWhere((m) => m.id != member).colorRgb,
        isNull,
      );
      expect(
        (await db.query('cheki_members', where: 'id=?', whereArgs: [member])),
        before,
      );
      expect(
        (await db.query(
          'cheki_identity_history',
          where: 'entity_id=?',
          whereArgs: [member],
        )),
        audit,
      );
      await DatabaseHelper().close();
      directory = await identities.directory();
      expect(
        directory.members.singleWhere((m) => m.id == member).colorRgb,
        0x12abef,
      );
      expect((await records.readModel()).members[member]!.colorRgb, 0x12abef);
    },
  );
  test(
    'manual color wins, explicit clear survives reopening, transfer inherits',
    () async {
      var m = (await identities.directory()).members.single;
      final person = await identities.createPerson(
        name: '同人',
        operationId: 'person',
      );
      m = await identities.editMember(
        original: m,
        name: 'A',
        colorRgb: 0,
        personId: person.id,
        active: true,
        operationId: 'black',
      );
      expect((await identities.directory()).members.single.colorRgb, 0);
      final group = await catalog.create(
        CatalogKind.group,
        name: '目标',
        operationId: 'group',
      );
      final moved = await identities.transferMember(
        original: m,
        groupId: group.id,
        name: '新A',
        operationId: 'transfer',
      );
      expect(moved.colorRgb, 0);
      await identities.editMember(
        original: m,
        name: 'A',
        colorRgb: null,
        personId: person.id,
        active: true,
        operationId: 'clear',
      );
      await DatabaseHelper().close();
      expect(
        (await identities.directory()).members
            .singleWhere((v) => v.id == member)
            .colorRgb,
        isNull,
      );
      await StorageSchema.validate(await records.database(), 8);
    },
  );
  test(
    'explicitly clearing inherited NULL records intent without filling stored color',
    () async {
      final m = (await identities.directory()).members.single;
      expect(m.toRow()['color_rgb'], isNull);
      expect(m.colorRgb, 0x12abef);
      await identities.editMember(
        original: m,
        name: m.name,
        colorRgb: null,
        personId: null,
        active: true,
        operationId: 'clear-inherited',
        clearColorFallback: true,
      );
      await DatabaseHelper().close();
      expect((await identities.directory()).members.single.colorRgb, isNull);
      await StorageSchema.validate(await records.database(), 8);
    },
  );
  test(
    'transferring inherited legacy color preserves raw source and a durable target snapshot',
    () async {
      final person = await identities.createPerson(
        name: '同人',
        operationId: 'transfer-person',
      );
      var m = (await identities.directory()).members.single;
      await identities.editMember(
        original: m,
        name: m.name,
        colorRgb: null,
        personId: person.id,
        active: true,
        operationId: 'link-only',
      );
      m = (await identities.directory()).members.single;
      final g = await catalog.create(
        CatalogKind.group,
        name: '目标',
        operationId: 'target-group',
      );
      final target = await identities.transferMember(
        original: m,
        groupId: g.id,
        name: '新A',
        operationId: 'inherited-transfer',
      );
      expect(target.colorRgb, 0x12abef);
      expect(target.toRow()['color_rgb'], isNull);
      await identities.editMember(
        original: m,
        name: m.name,
        colorRgb: null,
        personId: person.id,
        active: true,
        operationId: 'source-clear-after-transfer',
        clearColorFallback: true,
      );
      await DatabaseHelper().close();
      final members = (await identities.directory()).members;
      expect(members.singleWhere((r) => r.id == member).colorRgb, isNull);
      expect(members.singleWhere((r) => r.id == target.id).colorRgb, 0x12abef);
      final db = await records.database();
      await StorageSchema.validate(db, 8);
      final op = (await db.query(
        'cheki_identity_operations',
        where: 'id=?',
        whereArgs: ['inherited-transfer'],
      )).single;
      final request =
          jsonDecode(op['request_json'] as String) as Map<String, dynamic>;
      request['inherited_color_rgb'] = 'invalid';
      await db.update(
        'cheki_identity_operations',
        {'request_json': jsonEncode(request)},
        where: 'id=?',
        whereArgs: ['inherited-transfer'],
      );
      await expectLater(StorageSchema.validate(db, 8), throwsStateError);
    },
  );
  test(
    'date DESC beats import/action order; unknown stays last and edit regroups',
    () async {
      final newest = await records.save(
        info(day: '2026-10-13'),
        operationId: 'newest',
      );
      await records.save(info(), operationId: 'older-later-import');
      final unknown = await records.save(
        info(day: null),
        operationId: 'undated',
      );
      var m = await records.readModel();
      expect(m.records.first.id, newest.id);
      expect(m.records.last.id, unknown.id);
      await records.save(
        newest.information.patch({'occurred_on': '2024-01-01'}),
        original: newest,
        operationId: 'correct-day',
      );
      m = await records.readModel();
      expect(m.records.first.information.occurredOn!.value, '2026-05-23');
      expect(m.records.last.id, unknown.id);
    },
  );
  test(
    'merged presentation preserves raw rows audits unknowns and all quantities',
    () async {
      for (var n = 0; n < 2; n++) {
        await records.save(
          info(
            extra: {
              'legacy_raw': {'id': n, 'ext': null},
            },
          ),
          operationId: 'row$n',
        );
      }
      await records.save(
        info(
          extra: {
            'attributes': {'kind': 'signed', 'back_signed': true},
          },
        ),
        operationId: 'back',
      );
      await records.save(
        info(extra: {'size_id': null}),
        operationId: 'unknown-size',
      );
      final db = await records.database();
      final before = await db.query('cheki_records');
      final history = await db.query('cheki_record_history');
      final m = await records.readModel();
      final bundles = bundleRecords(m.records);
      expect(bundles.length, 3);
      expect(bundles.singleWhere((b) => b.records.length == 2).quantity, 2);
      expect(bundles.fold<int>(0, (v, b) => v + b.quantity!), 4);
      expect(
        bundles.expand((b) => b.records).map((r) => r.id).toSet(),
        m.records.map((r) => r.id).toSet(),
      );
      expect(await db.query('cheki_records'), before);
      expect(await db.query('cheki_record_history'), history);
      final r = bundles.singleWhere((b) => b.records.length == 2).records.first;
      await records.save(
        r.information.patch({
          'quantity': 3,
          'receipt_batches': [
            {'quantity': 3, 'origin': 'legacyUnknown'},
          ],
        }),
        original: r,
        operationId: 'fill-one',
      );
      expect(
        bundleRecords(
          (await records.readModel()).records,
        ).singleWhere((b) => b.records.length == 2).quantity,
        4,
      );
      expect(
        (await records.readModel()).summarize(RecordFilter()).knownQuantity,
        6,
      );
    },
  );
  test(
    'partial receipt, timestamps and differing extension facts do not silently combine',
    () async {
      for (var n = 0; n < 2; n++) {
        await records.save(
          info(
            quantity: 2,
            extra: {
              'receipt_batches': [
                {
                  'quantity': 1,
                  'origin': 'actual',
                  'received_at': '2026-05-24T00:00:00.000Z',
                },
              ],
            },
          ),
          operationId: 'partial$n',
        );
        await records.save(
          info(extra: {'extra_fact': n}),
          operationId: 'ext$n',
        );
      }
      expect(bundleRecords((await records.readModel()).records).length, 4);
    },
  );
  test(
    'full backup roundtrip retains raw NULL, inherited colors, group link and merged view',
    () async {
      final group = await catalog.create(
        CatalogKind.group,
        name: '团体',
        operationId: 'g',
      );
      final m = (await identities.directory()).members.single;
      await identities.editMember(
        original: m,
        name: m.name,
        colorRgb: null,
        fillGroupId: group.id,
        personId: null,
        active: true,
        operationId: 'fill-group',
      );
      for (var n = 0; n < 2; n++) {
        await records.save(info(), operationId: 'backup$n');
      }
      final before = await (await records.database()).query('cheki_records');
      await DatabaseHelper().close();
      final settings = <String, Object?>{'unknown': '保留'};
      final backup = BackupStore(
        documents: scratch,
        readSettings: () async => settings,
        writeSettings: (_) async {},
        closeMain: () async {},
      );
      final bytes = await backup.snapshot();
      final target = Directory('${scratch.path}/isolated-restore')
        ..createSync();
      await File(
        '${scratch.path}/user_database.db',
      ).copy('${target.path}/user_database.db');
      var prefs = <String, Object?>{};
      final restore = BackupStore(
        documents: target,
        readSettings: () async => prefs,
        writeSettings: (v) async {
          prefs = Map.from(v);
        },
        closeMain: () async {},
      );
      await restore.apply(await restore.prepare(bytes));
      final db = await openDatabase(
        '${target.path}/user_database.db',
        singleInstance: false,
      );
      try {
        await StorageSchema.validate(db, 8);
        final read = IdentityStore(() async => db);
        final memberAfter = (await read.directory()).members.single;
        expect(memberAfter.toRow()['color_rgb'], isNull);
        expect(memberAfter.colorRgb, 0x12abef);
        expect(memberAfter.groupId, group.id);
        final snapshot = info(
          extra: {
            'member_snapshots': [
              {
                'member_id': member,
                'member_name': '旧A',
                'member_name_origin': 'entry',
              },
            ],
          },
        );
        final labels = await RecordStore(() async => db).readModel();
        expect(
          labels.historicalMemberLabel(snapshot, member),
          '团体（当前团体） · 旧A（录入时）',
        );
        expect(
          snapshot.memberSnapshot(member)!.containsKey('group_name'),
          isFalse,
        );
        expect(await db.query('cheki_records'), before);
        expect(
          bundleRecords(
            (await RecordStore(() async => db).readModel()).records,
          ).single.quantity,
          2,
        );
        expect(prefs, settings);
      } finally {
        await db.close();
      }
    },
  );
  testWidgets(
    'group association actually saves, retains identity and cold reopens',
    (tester) async {
      final g = (await tester.runAsync(
        () => catalog.create(
          CatalogKind.group,
          name: '合成团体',
          operationId: 'ui-group',
        ),
      ))!;
      final m = (await tester.runAsync(identities.directory))!.members.single;
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: IdentityEditPage(
            kind: IdentityKind.member,
            store: identities,
            original: m,
          ),
        ),
      );
      await settleIo(tester);
      await select(tester, 'group', '合成团体');
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => DatabaseHelper().close());
      final after = (await tester.runAsync(
        identities.directory,
      ))!.members.single;
      expect(after.id, m.id);
      expect(after.groupId, g.id);
      expect(after.createdAt, m.createdAt);
      expect(after.colorRgb, 0x12abef);
    },
  );
  testWidgets(
    'portrait large text merged rows expand to editable originals and toggle back',
    (tester) async {
      for (final width in [320.0, 430.0]) {
        tester.view.physicalSize = Size(width, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (width == 320) {
          await tester.runAsync(() async {
            for (var n = 0; n < 2; n++) {
              await records.save(info(), operationId: 'ui$n');
            }
          });
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: RecordListPage(store: records),
          ),
        );
        await settleIo(tester);
        await tester.scrollUntilVisible(find.byType(CompactRecordContent), 200);
        await tester.ensureVisible(find.byType(CompactRecordContent));
        await tester.tap(find.byType(CompactRecordContent));
        await settleIo(tester);
        expect(find.text('原始记录'), findsOneWidget);
        expect(find.text('共 2 张 · 2 条记录'), findsOneWidget);
        await tester.pageBack();
        await settleIo(tester);
        expect(find.text('合并显示'), findsNothing);
        expect(find.byType(CompactRecordContent), findsOneWidget);
        expect(
          tester
              .widget<CompactRecordContent>(find.byType(CompactRecordContent))
              .quantitySize,
          startsWith('2 张'),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  final realCopy = Platform.environment['COUNT_TOOLS_FIX_READONLY_COPY'];
  if (realCopy != null) {
    test(
      'saved S25 copy read-only resolves all legacy colors and keeps every raw record',
      () async {
        final db = await openDatabase(
          realCopy,
          readOnly: true,
          singleInstance: false,
        );
        try {
          await StorageSchema.validate(db, 8);
          final memberRows = await db.query('cheki_members');
          final recordRows = await db.query('cheki_records');
          final groups = await db.query('cheki_groups');
          final directory = await IdentityStore(() async => db).directory();
          expect(directory.members.length, 25);
          expect(directory.members.where((m) => m.colorRgb != null).length, 25);
          final model = await RecordStore(() async => db).readModel();
          expect(model.records.length, 342);
          expect(model.summarize(RecordFilter()).knownQuantity, 342);
          expect(
            bundleRecords(model.records).expand((b) => b.records).length,
            342,
          );
          expect(await db.query('cheki_members'), memberRows);
          expect(await db.query('cheki_records'), recordRows);
          expect(await db.query('cheki_groups'), groups);
          debugPrint(
            'Read-only saved copy: 25 effective colors / 342 rows retained; grouped rows ${bundleRecords(model.records).length}.',
          );
        } finally {
          await db.close();
        }
      },
    );
  }
}
