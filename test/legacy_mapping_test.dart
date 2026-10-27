import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/legacy_mapping_store.dart';
import 'package:count_tools/cheki/data/record_cost.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'backup_test.dart' show fixture, contents;

class LegacyFixture {
  late Directory root;
  late BackupStore backup;
  late LegacyMappingStore store;
  Map<String, Object?> settings = {
    'text': '001',
    'enabled': false,
    'array': <String>['原文', ''],
    'zero': 0,
  };
  Future<void> open({
    int schema = StorageSchema.version,
    Future<void> Function(String)? fault,
  }) async {
    root = await Directory.systemTemp.createTemp('cheki-legacy-mapping-');
    await fixture(root, schema: schema);
    backup = BackupStore(
      documents: root,
      readSettings: () async => settings,
      writeSettings: (s) async => settings = Map.from(s),
      closeMain: () async {},
      fault: fault,
    );
    store = LegacyMappingStore(backup);
  }

  Future<Database> db({bool readOnly = false}) => openDatabase(
    '${root.path}/user_database.db',
    readOnly: readOnly,
    singleInstance: false,
  );
  Future<void> close() async {
    await root.delete(recursive: true);
    if (await backup.recovery.exists()) {
      await backup.recovery.delete(recursive: true);
    }
  }

  Future<List<StoredRecord>> records() async {
    final d = await db(readOnly: true);
    try {
      return await RecordStore(() async => d).list();
    } finally {
      await d.close();
    }
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late LegacyFixture f;
  setUp(() async {
    f = LegacyFixture();
    await f.open();
  });
  tearDown(() => f.close());

  test(
    'archive is read-only, SQL raw/BLOB/null independent and mappings start unknown',
    () async {
      final before = await f.backup.snapshot();
      final a = await f.store.read();
      expect(a.rows.length, 2);
      expect(a.existing, 0);
      expect(a.rows.first.raw['unknown_value'], {'sqlite_blob_base64': 'AP8='});
      expect(a.rows.first.raw['price'], isNull);
      expect(a.rows.last.raw['price'], '25.00');
      expect(a.rows.first.context['project'], containsPair('id', 17));
      final changed = a.rows.first.raw..['id'] = 999;
      expect(changed['id'], 999);
      expect(a.rows.first.id, 91);
      expect(
        BackupStore.snapshotFingerprint(await f.backup.snapshot()),
        BackupStore.snapshotFingerprint(before),
      );
      expect(await f.records(), isEmpty);
    },
  );

  test(
    'fully blank business information migrates and original archive remains exact',
    () async {
      final original = await contents(f.root);
      final a = await f.store.read();
      final p = await f.store.prepare(a, {
        for (final r in a.rows) r.id: RecordInformation.fromMap({}),
      });
      expect(await contents(f.root), original);
      expect(p.report['inventory_and_purchase_changes'], 0);
      expect(p.added, 2);
      expect(p.report['left_in_archive'], 0);
      await f.store.apply(p);
      final after = await contents(f.root);
      for (final t in [
        'users',
        'project_data',
        'sub_project_data',
        'item_data',
        'unknown_table',
        'future_values',
      ]) {
        expect(after[t], original[t]);
      }
      final seq = (after['sqlite_sequence'] as List).singleWhere(
        (r) => r['name'] == 'item_data',
      );
      expect(seq['seq'], 1000);
      for (final r in await f.records()) {
        expect(r.information.quantity, isNull);
        expect(r.information.occurredOn, isNull);
        expect(r.information.receiptStatus, isNull);
        expect(r.information.signature, isNull);
        expect(r.information.backSigned, isNull);
        expect(r.information.memberIds, isNull);
        expect(legacyRecordCost(r.information.toMap()), isNull);
        expect(r.information.toMap().containsKey('cost_reference'), false);
        expect(r.revision, 1);
        expect(isActionStamp(r.createdAt), true);
      }
      expect((after['cheki_ticket_objects'] as List), isEmpty);
    },
  );

  test(
    'explicit member/date/size/signature/receipt maps with no invented actual time',
    () async {
      final d = await f.db();
      final m = await IdentityStore(
        () async => d,
      ).createMember(name: '已确认成员', operationId: 'member-create');
      await d.close();
      final a = await f.store.read();
      final p = await f.store.prepare(a, {
        92: RecordInformation.fromMap({
          'quantity': 2,
          'member_ids': [m.id],
          'occurred_on': '2024-01-03',
          'size_id': 'size-3inch',
          'attributes': {'kind': 'signed', 'back_signed': false},
          'receipt_status_hint': 'received',
          'receipt_batches': [
            {'origin': 'legacyUnknown', 'quantity': 2},
          ],
          'note': '用户确认',
        }),
      });
      expect(p.report['left_in_archive'], 1);
      await f.store.apply(p);
      final r = (await f.records()).single;
      expect(r.information.quantity, 2);
      expect(r.information.receivedQuantity, 2);
      expect(r.information.receiptStatus!.name, 'received');
      expect((r.information.toMap()['receipt_batches'] as List).single, {
        'origin': 'legacyUnknown',
        'quantity': 2,
      });
      expect((r.information.toMap()['legacy_raw'] as Map)['price'], '25.00');
      expect(r.information.occurredOn!.value, '2024-01-03');
      expect(r.createdAt.startsWith('2024-01-03'), false);
      expect((await f.store.read()).existing, 1);
    },
  );

  test(
    'repeated migration skips sources and preserves later user edits',
    () async {
      var a = await f.store.read();
      final p = await f.store.prepare(a, {91: RecordInformation.fromMap({})});
      await f.store.apply(p);
      final d = await f.db();
      final records = RecordStore(() async => d);
      final r = (await records.list()).single;
      await records.save(
        r.information.patch({'note': '后续编辑', 'quantity': 7}),
        original: r,
        operationId: 'later-edit',
      );
      await d.close();
      a = await f.store.read();
      expect(a.existing, 1);
      expect(a.rows.first.existingRecordId, r.id);
      await expectLater(
        f.store.prepare(a, {91: RecordInformation.fromMap({})}),
        throwsFormatException,
      );
      final p2 = await f.store.prepare(a, {92: RecordInformation.fromMap({})});
      await f.store.apply(p2);
      expect(
        (await f.records()).singleWhere((e) => e.id == r.id).information.note,
        '后续编辑',
      );
      expect((await f.store.read()).existing, 2);
    },
  );

  test(
    'known scoped historical profile is detected, not guessed by name',
    () async {
      final a = await f.store.read(), d = await f.db();
      await RecordStore(() async => d).save(
        RecordInformation.fromMap({
          'legacy_raw': a.rows.last.raw,
          'legacy_source': {
            'mapping': 'S25-user-confirmed-20261013',
            'snapshot': '20261011_102725',
            'application_id': 'com.example.count_tools',
          },
          'quantity': 1,
        }),
        operationId: 'previous-scoped',
      );
      await d.close();
      final loaded = await f.store.read();
      expect(loaded.existing, 1);
      expect(loaded.rows.first.existingRecordId, isNull);
      final p = await f.store.prepare(loaded, {
        91: RecordInformation.fromMap({}),
      });
      await f.store.apply(p);
      expect((await f.records()).length, 2);
    },
  );

  test(
    'source raw conflict or multiple mapped origins reject read without editing history',
    () async {
      final a = await f.store.read();
      await f.store.apply(
        await f.store.prepare(a, {92: RecordInformation.fromMap({})}),
      );
      final d = await f.db();
      await d.update('item_data', {'price': '99.00'}, where: 'id=92');
      await d.close();
      final before = await contents(f.root);
      await expectLater(f.store.read(), throwsFormatException);
      expect(await contents(f.root), before);
    },
  );

  test(
    'invalid references or reserved provenance reject entire candidate, including earlier valid row',
    () async {
      final a = await f.store.read(), before = await contents(f.root);
      await expectLater(
        f.store.prepare(a, {
          91: RecordInformation.fromMap({'quantity': 1}),
          92: RecordInformation.fromMap({
            'member_ids': ['missing'],
          }),
        }),
        throwsA(isA<Exception>()),
      );
      expect(await contents(f.root), before);
      await expectLater(
        f.store.prepare(a, {
          91: RecordInformation.fromMap({'legacy_raw': {}}),
        }),
        throwsFormatException,
      );
      await expectLater(
        f.store.prepare(a, {999: RecordInformation.fromMap({})}),
        throwsFormatException,
      );
      await expectLater(f.store.prepare(a, {}), throwsFormatException);
    },
  );

  test(
    'unrecognized provenance and duplicate recognized origins cannot create another copy',
    () async {
      final a = await f.store.read(), d = await f.db();
      final info = RecordInformation.fromMap({
        'legacy_raw': a.rows.first.raw,
        'legacy_source': {'mapping': 'unknown-older-mapping'},
      });
      await RecordStore(
        () async => d,
      ).save(info, operationId: 'ambiguous-older');
      await d.close();
      await expectLater(f.store.read(), throwsFormatException);
      final extra = LegacyFixture();
      await extra.open();
      try {
        final source = await extra.store.read(), db = await extra.db();
        final known = RecordInformation.fromMap({
          'legacy_raw': source.rows.first.raw,
          'legacy_source': {'mapping': LegacyMappingStore.mapping},
        });
        await RecordStore(
          () async => db,
        ).save(known, operationId: 'duplicate-1');
        await RecordStore(
          () async => db,
        ).save(known, operationId: 'duplicate-2');
        await db.close();
        await expectLater(extra.store.read(), throwsFormatException);
        expect((await extra.records()).length, 2);
      } finally {
        await extra.close();
      }
    },
  );

  test(
    'unknown triggers cannot rewrite the source archive during mapping',
    () async {
      final d = await f.db();
      await d.execute(
        "CREATE TRIGGER unknown_rewrite AFTER INSERT ON cheki_records BEGIN UPDATE item_data SET price='0'; END",
      );
      await d.close();
      final a = await f.store.read(), before = await contents(f.root);
      await expectLater(
        f.store.prepare(a, {91: RecordInformation.fromMap({})}),
        throwsFormatException,
      );
      expect(await contents(f.root), before);
    },
  );

  test(
    'stale archive, stale preview, and altered staged payload never overwrite current changes',
    () async {
      var a = await f.store.read();
      f.settings['later'] = true;
      await expectLater(
        f.store.prepare(a, {91: RecordInformation.fromMap({})}),
        throwsA(isA<Exception>()),
      );
      expect(
        await f.backup.recovery
            .list()
            .where(
              (e) =>
                  e is Directory &&
                  e.path
                      .split(Platform.pathSeparator)
                      .last
                      .startsWith('incoming-'),
            )
            .length,
        0,
      );
      a = await f.store.read();
      final p = await f.store.prepare(a, {91: RecordInformation.fromMap({})});
      f.settings['later'] = false;
      await expectLater(f.store.apply(p), throwsA(isA<Exception>()));
      expect(await f.records(), isEmpty);
      await f.store.discard(p);
      a = await f.store.read();
      final q = await f.store.prepare(a, {91: RecordInformation.fromMap({})});
      await File(
        '${q.backup.folder.path}/attachments/原文.bin',
      ).writeAsBytes([9]);
      await expectLater(f.store.apply(q), throwsStateError);
      expect(await f.records(), isEmpty);
      await f.store.discard(q);
    },
  );

  test(
    'legacy schema1 source upgrades only isolated generation and retains source metadata',
    () async {
      final extra = LegacyFixture();
      await extra.open(schema: 1);
      try {
        final a = await extra.store.read();
        expect(a.tables.containsKey('cheki_records'), false);
        final source = await extra.db(readOnly: true);
        expect(await source.getVersion(), 1);
        await source.close();
        final p = await extra.store.prepare(a, {
          91: RecordInformation.fromMap({}),
        });
        await extra.store.apply(p);
        final d = await extra.db(readOnly: true);
        await StorageSchema.validate(d, StorageSchema.version);
        expect((await d.query('item_data')).length, 2);
        await d.close();
      } finally {
        await extra.close();
      }
    },
  );

  for (final phase in [
    'old-moved',
    'new-installed',
    'settings-written',
    'committed',
  ]) {
    test(
      'mapping durable generation fault $phase preserves complete expected generation',
      () async {
        final extra = LegacyFixture();
        await extra.open(
          fault: (s) async {
            if (s == phase) throw StateError('injected');
          },
        );
        try {
          final a = await extra.store.read();
          final p = await extra.store.prepare(a, {
            91: RecordInformation.fromMap({}),
          });
          await expectLater(extra.store.apply(p), throwsStateError);
          await extra.backup.recoverPending();
          expect((await extra.records()).length, phase == 'committed' ? 1 : 0);
          expect(
            await File('${extra.root.path}/attachments/原文.bin').readAsBytes(),
            [0, 255, 254],
          );
          expect(extra.settings['text'], '001');
        } finally {
          await extra.close();
        }
      },
    );
  }

  test(
    '342 distinct synthetic legacy rows retain IDs/raw values and explicit nullable mappings; full restoration',
    () async {
      final d = await f.db();
      await CatalogStore(
        () async => d,
      ).create(CatalogKind.group, name: '合成团体', operationId: 'synthetic-group');
      await d.delete('item_data');
      await d.update('sub_project_data', {'count': '342'}, where: 'id=41');
      for (var i = 1; i <= 342; i++) {
        await d.insert('item_data', {
          'id': i,
          'price': i == 1 ? null : '080.00',
          'eventName': null,
          'type': i.isEven ? '带签' : null,
          'date': '2025-07-08',
          'itemName': '合成成员',
          'parentId': '41',
          'projectId': '17',
          'ext': i == 1 ? '原文' : null,
          'unknown_value': i == 1 ? Uint8List.fromList([0, 255]) : null,
        });
      }
      await d.close();
      final original = await contents(f.root), a = await f.store.read();
      final p = await f.store.prepare(a, {
        for (final row in a.rows)
          row.id: RecordInformation.fromMap(
            row.id == 1 ? {} : {'quantity': 1, 'occurred_on': '2025-07-08'},
          ),
      });
      expect(await contents(f.root), original);
      expect((p.report['changes'] as List).length, 342);
      await f.store.apply(p);
      final rows = await f.records();
      expect(rows.length, 342);
      expect(
        rows.fold<int>(0, (s, r) => s + (r.information.quantity ?? 0)),
        341,
      );
      expect(
        rows
            .map((r) => (r.information.toMap()['legacy_raw'] as Map)['id'])
            .toSet()
            .length,
        342,
      );
      expect((await f.store.read()).existing, 342);
      final bytes = await f.backup.snapshot();
      final restored = LegacyFixture();
      await restored.open();
      try {
        await restored.backup.apply(await restored.backup.prepare(bytes));
        expect(await contents(restored.root), await contents(f.root));
        expect(restored.settings, f.settings);
        expect(
          await File('${restored.root.path}/attachments/原文.bin').readAsBytes(),
          [0, 255, 254],
        );
      } finally {
        await restored.close();
      }
      final proof = Platform.environment['CHEKI_LEGACY_EVIDENCE'];
      if (proof != null) {
        final out = Directory(proof).absolute;
        if (!out.path.startsWith(
              r'E:\OneDrive\Code\artifacts\count-tools-workflow\v150-20261015\',
            ) ||
            await out.exists()) {
          throw StateError('New owned synthetic evidence directory required');
        }
        await out.create(recursive: true);
        await File(
          '${out.path}/.legacy-synthetic',
        ).writeAsString('count_tools');
        await File(
          '${f.root.path}/user_database.db',
        ).copy('${out.path}/database.sqlite');
        await File(
          '${out.path}/preferences.json',
        ).writeAsString(jsonEncode(f.settings));
        await File(
          '${out.path}/synthetic-attachment',
        ).writeAsBytes([0, 255, 254]);
        await File('${out.path}/app.chekibackup').writeAsBytes(bytes);
        await File(
          '${out.path}/mapping-report.json',
        ).writeAsString(p.reportJson);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  if (Platform.environment['CHEKI_LEGACY_READBACK'] case final source?) {
    test('independent migration readback', () async {
      if (await File('$source/.legacy-synthetic').readAsString() !=
          'count_tools') {
        throw StateError('Marked synthetic source required');
      }
      final db = await openDatabase(
        '$source/database.sqlite',
        readOnly: true,
        singleInstance: false,
      );
      try {
        await StorageSchema.validate(db, StorageSchema.version);
        final rows = await RecordStore(() async => db).list();
        expect(rows.length, 342);
        expect(
          rows.fold<int>(0, (s, r) => s + (r.information.quantity ?? 0)),
          341,
        );
        expect(
          rows
              .map((r) => (r.information.toMap()['legacy_raw'] as Map)['id'])
              .toSet()
              .length,
          342,
        );
        expect((await db.query('item_data')).length, 342);
      } finally {
        await db.close();
      }
    });
  }
}
