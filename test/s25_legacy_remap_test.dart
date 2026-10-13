// Explicit user-confirmed facts for the specified imported snapshot only.
// Device access stays outside this offline recipe; originals are never written.
import 'dart:convert';
import 'dart:io';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/owned_transaction.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

RecordInformation confirmedLegacyRemap(RecordInformation info) {
  final m = info.toMap(), source = info.toMap()['legacy_source'];
  if (source is! Map ||
      source['snapshot'] != '20261011_102725' ||
      source['application_id'] != 'com.example.count_tools') {
    return info;
  }
  final raw = m['legacy_raw'];
  if (raw is! Map || raw['id'] == null) {
    throw StateError('Original archive missing');
  }
  if (raw['type'] == '带签') {
    m['size_id'] = 'size-3inch';
    m['attributes'] = {
      ...?((m['attributes'] as Map?)?.cast<String, Object?>()),
      'kind': 'signed',
    };
  }
  if (info.receiptStatus?.name != 'received') {
    final batches = ((m['receipt_batches'] as List?) ?? [])
        .map((b) => Map<String, Object?>.from(b as Map))
        .toList();
    if (batches.any((b) => b['quantity'] == null)) {
      throw StateError('Unresolved receipt batch; preserve for review');
    }
    final received = batches.fold<int>(0, (s, b) => s + (b['quantity'] as int));
    final remaining = info.quantity == null ? null : info.quantity! - received;
    if (remaining == null || remaining > 0) {
      batches.add({'origin': 'legacyUnknown', 'quantity': ?remaining});
    }
    m['receipt_batches'] = batches;
    m['receipt_status_hint'] = 'received';
  }
  m['legacy_confirmation'] = {
    ...?((m['legacy_confirmation'] as Map?)?.cast<String, Object?>()),
    'decision': 'DEC-053',
    'receipt': 'user confirmed all imported records received',
    if (raw['type'] == '带签')
      'size': 'user confirmed legacy 带签 means three inch signed',
  };
  return RecordInformation.fromMap(m);
}

RecordInformation confirmedBackSignature(
  RecordInformation info,
  String mitoParent,
  String gaoParent,
) {
  final m = info.toMap(), source = m['legacy_source'];
  if (source is! Map ||
      source['snapshot'] != '20261011_102725' ||
      source['application_id'] != 'com.example.count_tools') {
    return info;
  }
  final raw = m['legacy_raw'] as Map;
  final parent = raw['parentId'].toString();
  final back =
      parent == mitoParent ||
      (parent == gaoParent && info.occurredOn?.value == '2026-05-23');
  if (back && info.signature?.name != 'signed') {
    throw StateError(
      'Requested back signature conflicts with signature; review required',
    );
  }
  m['attributes'] = {
    ...?((m['attributes'] as Map?)?.cast<String, Object?>()),
    'back_signed': back,
  };
  m['legacy_back_confirmation'] = {'decision': 'DEC-054', 'back_signed': back};
  return RecordInformation.fromMap(m);
}

RecordInformation fixture(
  String type, {
  Map<String, Object?> extra = const {},
}) => RecordInformation.fromMap({
  'quantity': 1,
  'occurred_on': '2025-07-08',
  'attributes': {'kind': 'signed', 'unknown': null},
  'legacy_source': {
    'snapshot': '20261011_102725',
    'application_id': 'com.example.count_tools',
  },
  'legacy_raw': {'id': 91, 'type': type, 'ext': '', 'price': '0'},
  'note': 'original',
  ...extra,
});

void main() {
  test(
    'confirmed signed means three inch and received without invented time',
    () {
      final r = confirmedLegacyRemap(fixture('带签'));
      expect(r.sizeId, 'size-3inch');
      expect(r.signature!.name, 'signed');
      expect(r.receiptStatus!.name, 'received');
      expect(r.receivedQuantity, 1);
      expect((r.toMap()['receipt_batches'] as List).single, {
        'origin': 'legacyUnknown',
        'quantity': 1,
      });
      expect(r.occurredOn!.value, '2025-07-08');
      expect(r.backSigned, isNull);
    },
  );
  test('other types retain unknown sizes raw ext note and cost missing', () {
    final original = fixture(
      '无签',
      extra: {
        'attributes': {'kind': 'unsigned', 'unknown': null},
        'extra': {'null': null},
      },
    );
    final r = confirmedLegacyRemap(original);
    expect(r.sizeId, isNull);
    expect(r.signature!.name, 'unsigned');
    expect(r.note, 'original');
    expect(r.toMap()['legacy_raw'], original.toMap()['legacy_raw']);
    expect(r.toMap()['extra'], original.toMap()['extra']);
    expect(r.toMap().containsKey('cost_reference'), false);
  });
  test('known actual receipt timestamps and unknown total remain intact', () {
    final r = confirmedLegacyRemap(
      fixture(
        '带签',
        extra: {
          'receipt_batches': [
            {
              'quantity': 1,
              'origin': 'actual',
              'received_at': '2025-07-08T01:00:00.000Z',
              'ext': 'keep',
            },
          ],
        },
      ),
    );
    expect((r.toMap()['receipt_batches'] as List).single, {
      'quantity': 1,
      'origin': 'actual',
      'received_at': '2025-07-08T01:00:00.000Z',
      'ext': 'keep',
    });
    final unknown = confirmedLegacyRemap(
      fixture('主题', extra: {'quantity': null, 'attributes': null}),
    );
    expect(unknown.quantity, isNull);
    expect(unknown.receiptStatus!.name, 'received');
    expect((unknown.toMap()['receipt_batches'] as List).single, {
      'origin': 'legacyUnknown',
    });
  });
  test(
    'non snapshot records untouched and applying facts twice is idempotent',
    () {
      final newer = fixture('带签', extra: {'legacy_source': null});
      expect(confirmedLegacyRemap(newer).encode(), newer.encode());
      final once = confirmedLegacyRemap(fixture('带签'));
      expect(confirmedLegacyRemap(once).encode(), once.encode());
    },
  );
  test(
    'back signatures use stable source member plus occurrence date, preserving other facts',
    () {
      RecordInformation sample(String parent, String day) => fixture(
        '带签',
        extra: {
          'occurred_on': day,
          'legacy_raw': {'id': 91, 'parentId': parent, 'type': '带签'},
        },
      );
      expect(
        confirmedBackSignature(
          sample('mito', '2026-01-01'),
          'mito',
          'gao',
        ).backSigned,
        true,
      );
      expect(
        confirmedBackSignature(
          sample('gao', '2026-05-23'),
          'mito',
          'gao',
        ).backSigned,
        true,
      );
      final other = confirmedBackSignature(
        sample('gao', '2026-05-24'),
        'mito',
        'gao',
      );
      expect(other.backSigned, false);
      expect(other.occurredOn!.value, '2026-05-24');
      expect(
        confirmedBackSignature(
          fixture('主题', extra: {'attributes': null}),
          'mito',
          'gao',
        ).signature,
        isNull,
      );
      expect(
        () => confirmedBackSignature(
          sample('mito', '2026-01-01').patch({
            'attributes': {'kind': 'unsigned'},
          }),
          'mito',
          'gao',
        ),
        throwsStateError,
      );
    },
  );
  final backPass = Platform.environment['COUNT_TOOLS_S25_BACKSIGN'] != null;
  final destination =
      Platform.environment['COUNT_TOOLS_S25_REMAP'] ??
      Platform.environment['COUNT_TOOLS_S25_BACKSIGN'];
  if (destination == null) return;
  test(
    'current phone copy receives audited revisions and complete restore rehearsal',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      const root =
          r'E:\OneDrive\Code\artifacts\count-tools-device\s25-remap-20261013';
      final out = Directory(destination).absolute;
      if (!out.path.startsWith('$root\\') || await out.exists()) {
        throw StateError('New isolated preparation required');
      }
      final envelope =
          jsonDecode(
                await File(
                  '$root/${backPass ? 'after' : 'before'}.chekibackup',
                ).readAsString(),
              )
              as Map;
      final payload = jsonDecode(envelope['payload'] as String) as Map;
      // BackupStore.prepare validates envelope before any source is used.
      await out.create(recursive: true);
      final live = Directory('${out.path}/app-documents');
      await live.create();
      for (final e in (payload['files'] as Map).entries) {
        if (e.key is! String ||
            (e.key as String).contains('..') ||
            (e.key as String).startsWith('/')) {
          throw StateError('Unsafe path');
        }
        final f = File('${live.path}/${e.key}');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(base64Decode(e.value as String));
      }
      final settings = Map<String, Object?>.from(payload['settings'] as Map);
      final backup = BackupStore(
        documents: live,
        readSettings: () async => settings,
        writeSettings: (_) async {},
        closeMain: () async {},
      );
      await backup.prepare(
        await File(
          '$root/${backPass ? 'after' : 'before'}.chekibackup',
        ).readAsBytes(),
      );
      final db = await openDatabase(
        '${live.path}/user_database.db',
        singleInstance: false,
      );
      await StorageSchema.validate(db, 8);
      final beforeRows = await db.query(RecordSchema.records);
      if (beforeRows.length != 342) {
        throw StateError('Snapshot changed; review required');
      }
      final sourceRows = {
        for (final r in beforeRows) r['id']: StoredRecord.fromRow(r),
      };
      final beforeHistory = await db.query(RecordSchema.history, orderBy: 'id');
      final legacyMembers = await db.query('sub_project_data');
      final mitoParent = legacyMembers
          .singleWhere(
            (r) => (r['name'] as String).toLowerCase() == 'mito',
          )['id']
          .toString();
      final gaoParent = legacyMembers
          .singleWhere((r) => r['name'] == '糕')['id']
          .toString();
      var backs = 0, mitoBacks = 0, gaoBacks = 0;
      var signed = 0;
      await db.transaction((tx) async {
        final store = RecordStore(
          () => Future.value(OwnedTransactionDatabase(tx)),
          managedEntry: true,
        );
        for (final original in sourceRows.values) {
          final info = original.information;
          if ((info.toMap()['legacy_raw'] as Map)['type'] == '带签') signed++;
          final corrected = backPass
              ? confirmedBackSignature(info, mitoParent, gaoParent)
              : confirmedLegacyRemap(info);
          if (backPass && corrected.backSigned == true) {
            backs++;
            if ((info.toMap()['legacy_raw'] as Map)['parentId'].toString() ==
                mitoParent) {
              mitoBacks++;
            } else {
              gaoBacks++;
            }
          }
          if (identical(corrected, info)) {
            throw StateError('Unexpected nonlegacy record');
          }
          await store.save(
            corrected,
            original: original,
            operationId:
                's25-remap-${backPass ? 'dec054' : 'dec053'}:${original.id}',
          );
        }
        await StorageSchema.validate(tx, 8);
      });
      if (signed != 288) {
        throw StateError('Source type changed; review required');
      }
      if (backPass) {
        expect(backs, 9);
        expect(mitoBacks, 7);
        expect(gaoBacks, 2);
      }
      final afterRows = await db.query(RecordSchema.records);
      for (final row in afterRows) {
        final r = StoredRecord.fromRow(row), original = sourceRows[r.id]!;
        expect(r.createdAt, original.createdAt);
        expect(r.revision, original.revision + 1);
        expect(r.information.receiptStatus!.name, 'received');
        final m = r.information.toMap(), old = original.information.toMap();
        for (final k in old.keys.where(
          (k) => ![
            'size_id',
            'attributes',
            'receipt_batches',
            'receipt_status_hint',
            'legacy_confirmation',
            'legacy_back_confirmation',
          ].contains(k),
        )) {
          expect(m[k], old[k]);
        }
      }
      expect(
        await db.query(RecordSchema.history, orderBy: 'id'),
        startsWithRows(beforeHistory),
      );
      await db.close();
      final bytes = await backup.snapshot();
      await File(
        '${out.path}/corrected.chekibackup',
      ).writeAsBytes(bytes, flush: true);
      final rehearsal = Directory('${out.path}/rehearsal');
      await rehearsal.create();
      await File(
        '${live.path}/user_database.db',
      ).copy('${rehearsal.path}/user_database.db');
      var restoredSettings = <String, Object?>{};
      final restoring = BackupStore(
        documents: rehearsal,
        readSettings: () async => restoredSettings,
        writeSettings: (s) async {
          restoredSettings = Map.from(s);
        },
        closeMain: () async {},
      );
      final preview = await restoring.prepare(bytes);
      await restoring.apply(preview);
      final read = await openDatabase(
        '${rehearsal.path}/user_database.db',
        readOnly: true,
        singleInstance: false,
      );
      await StorageSchema.validate(read, 8);
      expect(await read.query(RecordSchema.records), afterRows);
      await read.close();
      expect(restoredSettings, settings);
      await File('${out.path}/summary.json').writeAsString(
        jsonEncode({
          'records': 342,
          'members': 25,
          'three_inch_signed_corrections': 288,
          'received': 342,
          'receipt_time_invented': false,
          if (backPass) 'back_signed': backs,
          if (backPass) 'mito_back_signed': mitoBacks,
          if (backPass) 'gao_back_signed': gaoBacks,
          'revision_added': 342,
          'sizes_unknown': 50,
          'signature_unknown': 17,
          'isolated_restore': 'passed',
        }),
        flush: true,
      );
    },
  );
}

Matcher startsWithRows(List<Map<String, Object?>> expected) =>
    predicate<List<Map<String, Object?>>>(
      (rows) =>
          rows.length == expected.length + 342 &&
          jsonEncode(rows.take(expected.length).toList()) ==
              jsonEncode(expected),
      'previous history retained before 342 appended revisions',
    );
