import 'dart:convert';
import 'dart:io';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/ui/record_names.dart';
import 'package:count_tools/cheki/ui/receipt_edit.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;
import 'catalog_pages_test.dart' show settleIo;

void checkModel(RecordReadModel m) {
  final a = m.members.values.singleWhere((x) => x.name == 'A新名').id;
  final b = m.members.values.singleWhere((x) => x.name == 'B').id;
  final total = m.summarize(RecordFilter());
  expect(m.records.length, 5);
  expect(total.knownQuantity, 7);
  expect(total.memberQuantity, 9);
  expect(total.byMember, {a: 5, b: 4});
  expect(total.unknownQuantityRecords, 2);
  expect(total.unknownDateRecords, 2);
  expect(total.unknownReceiptRecords, 2);
  expect(total.knownReceivedQuantity, 5);
  expect(total.knownAwaitingQuantity, 2);
  expect(total.bySize.map((k, v) => MapEntry(m.sizes[k]!.name, v)), {
    '三寸': 5,
    '五寸': 2,
  });
  expect(m.summarize(m.month(OccurredOn.parse('2026-10-13'))).knownQuantity, 7);
  expect(
    m
        .select(RecordFilter(selection: RecordSelection.awaitingReceipt))
        .single
        .information
        .quantity,
    2,
  );
  final joint = m.records.singleWhere(
    (r) => (r.information.memberIds ?? []).length == 2,
  );
  expect(joint.information.receivedQuantity, 2);
  expect(joint.information.occurredOn?.value, '2026-10-11');
  expect(m.historicalMemberLabel(joint.information, a), '晨星 · A（录入时）');
  final batches = joint.information.toMap()['receipt_batches'] as List;
  expect(batches.length, 2);
  expect((batches.first as Map)['received_at'], '2026-10-12T01:00:00.123456Z');
  final old = m.records
      .singleWhere((r) => r.information.toMap().containsKey('legacy_raw'))
      .information
      .toMap();
  expect(old['legacy_raw'], {
    'id': 91,
    'date': '2024-01-02 13:14:15',
    'price': '25.00',
    'ext': null,
    'unknown': [null, '原文'],
  });
  expect(old['quantity'], isNull);
  expect(old.containsKey('occurred_on'), isFalse);
  expect(old['member_snapshots'], isNull);
  expect(
    m.records
        .singleWhere((r) => r.information.toMap().isEmpty)
        .information
        .receiptStatus,
    isNull,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  final restored = Platform.environment['COUNT_TOOLS_M1_RESTORED'];
  if (restored != null) {
    testWidgets(
      'optional restored M1 full model and actual pages in a new Flutter process',
      (tester) async {
        final root = Directory(restored).absolute;
        expect(
          File('${root.parent.path}/.count-tools-isolated.json').existsSync(),
          isTrue,
        );
        final db = await tester.runAsync(
          () => databaseFactory.openDatabase(
            '${root.path}/database.sqlite',
            options: OpenDatabaseOptions(readOnly: true),
          ),
        );
        final store = RecordStore(
          () => Future.value(db!),
          clock: () => DateTime.utc(2026, 10, 13, 1),
        );
        checkModel((await tester.runAsync(store.readModel))!);
        await tester.runAsync(() => RecordSchema.validate(db!));
        await tester.runAsync(() => StorageSchema.validate(db!, 5));
        final prefs =
            jsonDecode(
                  File(
                    '${root.path}/settings/preferences.json',
                  ).readAsStringSync(),
                )
                as Map;
        expect(prefs['unknownSetting'], ['原文', '保留']);
        expect(
          File(
            '${root.path}/attachments/synthetic-attachment',
          ).readAsBytesSync(),
          [0, 1, 255],
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            home: Scaffold(body: RecordHomePage(store: store)),
          ),
        );
        await settleIo(tester);
        expect(find.text('7 张'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('home-month')));
        await settleIo(tester);
        expect(find.text('7 张'), findsOneWidget);
        expect(find.text('成员张数 9'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => db!.close());
        expect(tester.takeException(), isNull);
      },
    );
    return;
  }
  test(
    'M1 combined identity record date receipt names unknowns and cold reopen reconcile',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'cheki-m1-combined-',
      );
      final path = '${scratch.path}/database.sqlite';
      await legacyFixture(path);
      DatabaseHelper.pathResolver = () => Future.value(path);
      var clock = DateTime.utc(2026, 10, 12, 1);
      final store = RecordStore(
        () => DatabaseHelper().database,
        clock: () => clock,
      );
      final catalog = CatalogStore(store.database, clock: () => clock);
      final identities = IdentityStore(store.database, clock: () => clock);
      try {
        final g = await catalog.create(
          CatalogKind.group,
          name: '晨星',
          operationId: 'group',
        );
        final a = await identities.createMember(
          name: 'A',
          groupId: g.id,
          colorRgb: 0x90bfff,
          operationId: 'a',
        );
        final b = await identities.createMember(
          name: 'B',
          groupId: g.id,
          colorRgb: 0xef98b6,
          operationId: 'b',
        );
        final sizes = await catalog.list(CatalogKind.size);
        final three = sizes.singleWhere((s) => s.name == '三寸').id,
            five = sizes.singleWhere((s) => s.name == '五寸').id;
        final directory = await identities.directory();
        RecordInformation info(
          List<String> ids,
          int q,
          String size,
          String kind,
          List<Map<String, Object?>> receipts,
        ) {
          final raw = RecordInformation.fromMap({
            'member_ids': ids,
            'quantity': q,
            'size_id': size,
            'occurred_on': '2026-10-11',
            'attributes': {'kind': kind, 'back_signed': false},
            'receipt_batches': receipts,
          });
          final names = RecordNamesController(raw);
          names.select(ids, directory, captureNew: true);
          return raw.patch(names.patch(ids));
        }

        final rA = await store.save(
          info(
            [a.id],
            3,
            three,
            'signed',
            [
              {'quantity': 3, 'origin': 'initial', 'received_at': null},
            ],
          ),
          operationId: 'a3',
        );
        final rB = await store.save(
          info([b.id], 2, five, 'unsigned', []),
          operationId: 'b2',
        );
        var joint = await store.save(
          info([a.id, b.id], 2, three, 'homework', []),
          operationId: 'ab2',
        );
        for (var n = 1; n <= 2; n++) {
          final editor = ReceiptEditController(
            joint.information,
            clock: () => clock,
          );
          editor.add();
          editor.change(
            editor.entries.last,
            quantity: '1',
            time: n == 1 ? '2026-10-12 09:00:00' : '2026-10-13 10:00:00',
          );
          var patch = editor.patch(2);
          if (n == 1) {
            final batches = patch['receipt_batches'] as List;
            (batches.first as Map)['received_at'] =
                '2026-10-12T01:00:00.123456Z';
          }
          joint = await store.save(
            joint.information.patch(patch),
            original: joint,
            operationId: 'receipt$n',
          );
          editor.dispose();
          expect(joint.information.receivedQuantity, n);
          expect(joint.information.quantity, 2);
        }
        final blank = await store.save(
          RecordInformation.fromMap({}),
          operationId: 'blank',
        );
        final old = await store.save(
          RecordInformation.fromMap({
            'quantity': null,
            'member_snapshots': null,
            'legacy_raw': {
              'id': 91,
              'date': '2024-01-02 13:14:15',
              'price': '25.00',
              'ext': null,
              'unknown': [null, '原文'],
            },
            'receipt_batches': [
              {
                'quantity': null,
                'received_at': '2026-10-12T02:00:00.654321Z',
                'opaque': null,
              },
            ],
          }),
          operationId: 'old',
        );
        final edited = await store.save(
          old.information.patch({'note': '补备注'}),
          original: old,
          operationId: 'old-note',
        );
        expect(edited.createdAt, old.createdAt);
        expect(blank.information.toMap(), isEmpty);
        final moved = await store.save(
          rB.information.patch({'occurred_on': '2026-09-30'}),
          original: rB,
          operationId: 'move',
        );
        expect(
          (await store.readModel())
              .summarize(
                RecordFilter(from: '2026-10-01', through: '2026-10-31'),
              )
              .knownQuantity,
          5,
        );
        await store.save(
          moved.information.patch({'occurred_on': '2026-10-11'}),
          original: moved,
          operationId: 'move-back',
        );
        clock = clock.add(const Duration(hours: 2));
        await identities.editMember(
          original: a,
          name: 'A新名',
          colorRgb: 0x123456,
          personId: null,
          active: false,
          operationId: 'rename-stop',
        );
        expect(rA.information.memberSnapshot(a.id)?['member_name'], 'A');
        await DatabaseHelper().close();
        checkModel(await store.readModel());
        await RecordSchema.validate(await store.database());
        final export = Platform.environment['COUNT_TOOLS_M1_ACCEPTANCE'];
        if (export != null) {
          final root = Directory(export).absolute;
          expect(
            root.path.startsWith(Directory.current.absolute.path),
            isFalse,
          );
          final marker =
              jsonDecode(
                    File('${root.path}/.m1-acceptance.json').readAsStringSync(),
                  )
                  as Map;
          expect(marker['purpose'], 'm1-synthetic-combined');
          expect(marker['project'], 'count_tools');
          for (final name in [
            'database.sqlite',
            'preferences.json',
            'synthetic-attachment',
          ]) {
            expect(File('${root.path}/$name').existsSync(), isFalse);
          }
          await DatabaseHelper().close();
          File(path).copySync('${root.path}/database.sqlite');
          File('${root.path}/preferences.json').writeAsStringSync(
            jsonEncode({
              'themeColor': '原值',
              'unknownSetting': ['原文', '保留'],
              'isNotFirstEnter': true,
              'showEnterProjectTip': false,
              'lastBackupTime': '原时间',
            }),
          );
          File(
            '${root.path}/synthetic-attachment',
          ).writeAsBytesSync([0, 1, 255]);
        }
      } finally {
        await DatabaseHelper().close();
        DatabaseHelper.pathResolver = null;
        await scratch.delete(recursive: true);
      }
    },
  );
}
