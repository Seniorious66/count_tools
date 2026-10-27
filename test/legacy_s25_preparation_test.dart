// A scoped, offline preparation recipe for the user-confirmed S25 snapshot.
// It never connects to a phone and never writes the original source database.
import 'dart:convert';
import 'dart:io';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/owned_transaction.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/member_color.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

RecordInformation mappedLegacy(Map<String, Object?> row, String member) {
  final type = row['type'] as String?;
  final kind = switch (type) {
    '无签' => 'unsigned',
    '带签' || '有签' => 'signed',
    '宿题' || '生日宿题3寸' || '生日宿题5寸' => 'homework',
    _ => null,
  };
  final size = switch (type) {
    '5寸' || '生日宿题5寸' => 'size-5inch',
    '生日宿题3寸' => 'size-3inch',
    _ => null,
  };
  return RecordInformation.fromMap({
    'quantity': 1,
    if (row['date'] != null) 'occurred_on': row['date'],
    'member_ids': [member],
    'member_snapshots': [
      {
        'member_id': member,
        if (row['itemName'] != null) 'member_name': row['itemName'],
        'member_name_origin': 'entry',
      },
    ],
    if (kind != null) 'attributes': {'kind': kind},
    'size_id': ?size,
    if (type != null && type.isNotEmpty) 'note': '旧类型：$type',
    'legacy_raw': row,
    'legacy_source': {
      'snapshot': '20261011_102725',
      'application_id': 'com.example.count_tools',
      'mapping': 'S25-user-confirmed-20261013',
      'quantity_basis': 'legacy app counts individual rows',
      'other_participants_unknown': type == '团切',
    },
  });
}

void main() {
  test(
    'known legacy date name and nature mapped without receipt coupon size or cost defaults',
    () {
      final row = <String, Object?>{
        'id': 91,
        'date': '2025-07-08',
        'itemName': '糕',
        'type': '无签',
        'price': '0',
        'ext': '',
      };
      final r = mappedLegacy(row, 'm');
      expect(r.quantity, 1);
      expect(r.occurredOn!.value, '2025-07-08');
      expect(r.signature!.name, 'unsigned');
      expect(r.sizeId, isNull);
      expect(r.receiptStatus, isNull);
      expect(r.backSigned, isNull);
      expect(r.toMap()['legacy_raw'], row);
      expect(r.toMap().containsKey('cost_reference'), false);
    },
  );
  test(
    'same-day distinct source IDs are retained and unknown combinations remain unclassified',
    () {
      final a = mappedLegacy({
            'id': 1,
            'date': '2025-07-27',
            'type': '团切',
          }, 'm'),
          b = mappedLegacy({'id': 2, 'date': '2025-07-27', 'type': '大切'}, 'm');
      expect((a.toMap()['legacy_raw'] as Map)['id'], 1);
      expect((b.toMap()['legacy_raw'] as Map)['id'], 2);
      expect(a.signature, isNull);
      expect(b.sizeId, isNull);
      expect(a.receiptStatus, isNull);
    },
  );
  test(
    'only explicit size and homework labels mapped, raw birthday label retained',
    () {
      final r = mappedLegacy({
        'id': 1,
        'date': '2025-07-08',
        'type': '生日宿题5寸',
      }, 'm');
      expect(r.sizeId, 'size-5inch');
      expect(r.signature!.name, 'homework');
      expect(r.note, '旧类型：生日宿题5寸');
      expect(r.backSigned, isNull);
    },
  );
  final destination = Platform.environment['COUNT_TOOLS_S25_PREPARATION'];
  if (destination == null) return;
  test(
    'explicit isolated S25 preparation and complete restore rehearsal of actual unchanged snapshot',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      const source =
          r'E:\OneDrive\Code\artifacts\count-tools-export\20261011_102725';
      final parent = Directory(destination).absolute;
      if (!parent.path.startsWith(
            r'E:\OneDrive\Code\artifacts\count-tools-device\s25-20261013\',
          ) ||
          await parent.exists()) {
        throw StateError('New approved preparation directory required');
      }
      await parent.create(recursive: true);
      await File('${parent.path}/.s25-preparation').writeAsString(
        'count_tools private user-authorized isolated copy',
        flush: true,
      );
      final live = Directory('${parent.path}/app-documents');
      await live.create();
      final dbPath = '${live.path}/user_database.db';
      final original = await openDatabase(
        '$source/user_database.db',
        readOnly: true,
        singleInstance: false,
      );
      final legacy = {
            for (final t in StorageSchema.columns.keys)
              t: await original.query(t),
          },
          sequence = await original.query('sqlite_sequence');
      await StorageSchema.validate(original, 1);
      await original.close();
      await File('$source/user_database.db').copy(dbPath);
      final archive = Directory('${live.path}/legacy-source');
      await archive.create();
      await File(
        '$source/user_database.db',
      ).copy('${archive.path}/original-database.sqlite');
      await File(
        '$source/user_database.db-journal',
      ).copy('${archive.path}/original-database-journal');
      await File(
        '$source/extracted/sp/FlutterSharedPreferences.xml',
      ).copy('${archive.path}/original-settings.xml');
      final db = await openDatabase(
        dbPath,
        singleInstance: false,
        version: StorageSchema.version,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys=ON'),
        onUpgrade: StorageSchema.migrate,
        onOpen: (d) async => StorageSchema.validate(d, await d.getVersion()),
      );
      final members = <String, String>{}, records = <String, String>{};
      await db.transaction((tx) async {
        Future<Database> owned() =>
            Future<Database>.value(OwnedTransactionDatabase(tx));
        final clock = DateTime.now;
        final identity = IdentityStore(owned, clock: clock),
            store = RecordStore(owned, clock: clock, managedEntry: true);
        for (final row in legacy['sub_project_data']!) {
          final rawColor = parseLegacyMemberColor(row['color'] as String?);
          final m = await identity.createMember(
            name: row['name'] as String,
            colorRgb: rawColor,
            operationId: 's25-legacy-member:${row['id']}',
          );
          members[row['id'].toString()] = m.id;
        }
        for (final row in legacy['item_data']!) {
          final m = members[row['parentId'].toString()];
          if (m == null) throw StateError('Legacy member relation missing');
          final r = await store.save(
            mappedLegacy(copySqlRow(row), m),
            operationId: 's25-legacy-item:${row['id']}',
          );
          records[row['id'].toString()] = r.id;
        }
        await StorageSchema.validate(tx, StorageSchema.version);
      });
      for (final entry in legacy.entries) {
        if (jsonEncode(await db.query(entry.key)) != jsonEncode(entry.value)) {
          throw StateError('Original legacy fields changed');
        }
      }
      final afterSequence = {
        for (final r in await db.query('sqlite_sequence')) r['name']: r['seq'],
      };
      for (final s in sequence) {
        if (afterSequence[s['name']] != s['seq']) {
          throw StateError('Original sequence changed');
        }
      }
      final actual = await RecordStore(() => Future.value(db)).list();
      if (actual.length != 342 ||
          members.length != 25 ||
          actual.any(
            (r) =>
                r.information.receiptStatus != null ||
                r.information.toMap().containsKey('cost_reference'),
          )) {
        throw StateError('Unexpected migration result');
      }
      final rawById = {
        for (final r in legacy['item_data']!) r['id'].toString(): r,
      };
      for (final r in actual) {
        final raw = r.information.toMap()['legacy_raw'] as Map;
        if (jsonEncode(raw) != jsonEncode(rawById[raw['id'].toString()])) {
          throw StateError('Original row archive changed');
        }
      }
      await File('${archive.path}/mapping.json').writeAsString(
        jsonEncode({
          'source_snapshot': '20261011_102725',
          'member_ids': members,
          'record_ids': records,
          'source_tables_preserved': true,
          'quantity_basis': 'one record per old count unit',
          'unresolved': [
            'group',
            'person',
            'receipt',
            'coupon',
            'ambiguous signature and size',
            'other participants in group Cheki',
          ],
        }),
        flush: true,
      );
      await db.close();
      final settings = Map<String, Object?>.from(
        jsonDecode(
              await File(
                '${parent.parent.path}/source-preferences.json',
              ).readAsString(),
            )
            as Map,
      );
      final backup = BackupStore(
        documents: live,
        readSettings: () async => settings,
        writeSettings: (_) async {},
        closeMain: () async {},
      );
      final bytes = await backup.snapshot();
      await File(
        '${parent.path}/Cheki-S25-legacy-20261013.chekibackup',
      ).writeAsBytes(bytes, flush: true);
      final restored = Directory('${parent.path}/restore-rehearsal');
      await restored.create();
      await File(dbPath).copy('${restored.path}/user_database.db');
      var newSettings = <String, Object?>{'before': true};
      final restoring = BackupStore(
        documents: restored,
        readSettings: () async => newSettings,
        writeSettings: (v) async {
          newSettings = Map.from(v);
        },
        closeMain: () async {},
      );
      final preview = await restoring.prepare(bytes);
      await restoring.apply(preview);
      final read = await openDatabase(
        '${restored.path}/user_database.db',
        readOnly: true,
        singleInstance: false,
      );
      await StorageSchema.validate(read, StorageSchema.version);
      for (final row in await read.query('cheki_records')) {
        final originalRow = actual.singleWhere((r) => r.id == row['id']);
        if (jsonEncode(row) != jsonEncode(originalRow.toRow())) {
          throw StateError('Restored record differs');
        }
      }
      await read.close();
      if (jsonEncode(newSettings) != jsonEncode(settings)) {
        throw StateError('Settings differ');
      }
      await File('${parent.path}/summary.json').writeAsString(
        jsonEncode({
          'schema': StorageSchema.version,
          'legacy_projects': 1,
          'legacy_members': 25,
          'legacy_records': 342,
          'new_members': members.length,
          'new_records': actual.length,
          'known_quantity': actual.fold<int>(
            0,
            (s, r) => s + r.information.quantity!,
          ),
          'signature_unknown': actual
              .where((r) => r.information.signature == null)
              .length,
          'size_unknown': actual
              .where((r) => r.information.sizeId == null)
              .length,
          'receipt_unknown': 342,
          'group_unknown': 25,
          'original_fields_sequences_preserved': true,
          'full_restore_rehearsal': 'passed',
        }),
        flush: true,
      );
    },
  );
}
