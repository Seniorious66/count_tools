import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../../data/database/schema.dart';
import '../domain/record_information.dart';
import 'backup_store.dart';
import 'catalog_contract.dart';
import 'catalog_store.dart';
import 'identity_store.dart';
import 'owned_transaction.dart';
import 'record_store.dart';

Object? _ordered(Object? v) => v is Map
    ? {
        for (final k in v.keys.cast<String>().toList()..sort())
          k: _ordered(v[k]),
      }
    : v is List
    ? v.map(_ordered).toList()
    : v;
String _canonical(Object? v) => jsonEncode(_ordered(v));
Map<String, Object?> _jsonRow(Map<String, Object?> row) =>
    Map<String, Object?>.from(jsonDecode(encodeSqlRow(row)) as Map);

/// Original rows are an archive, not editable business records. Keep SQL types,
/// NULL, unknown columns and binary values in the archive and in provenance.
class LegacyArchiveRow {
  LegacyArchiveRow._(this._raw, this._context, this.existingRecordId);
  final String _raw, _context;
  final String? existingRecordId;
  Map<String, Object?> get raw =>
      Map<String, Object?>.from(jsonDecode(_raw) as Map);
  Map<String, Object?> get context =>
      Map<String, Object?>.from(jsonDecode(_context) as Map);
  int get id => raw['id'] as int;
  String get label => '#$id · ${raw['itemName'] ?? ''}';
}

class LegacyArchive {
  LegacyArchive._(
    this._bytes,
    this._baseline,
    this.rows,
    this.directory,
    this.sizes,
    this.tables,
  );
  final Uint8List _bytes;
  final String _baseline;
  final List<LegacyArchiveRow> rows;
  final IdentityDirectory directory;
  final List<CatalogEntity> sizes;
  final Map<String, int> tables;
  int get existing => rows.where((r) => r.existingRecordId != null).length;
}

class LegacyMappingPreview {
  LegacyMappingPreview._(this.backup, this._report);
  final BackupPreview backup;
  final String _report;
  Map<String, Object?> get report =>
      Map<String, Object?>.from(jsonDecode(_report) as Map);
  String get reportJson => _report;
  int get added => report['added'] as int;
}

/// Maps the preserved legacy tables of a complete, validated ledger. It never
/// opens an arbitrary untrusted bare SQLite file or modifies an original row.
/// Importing a historical full backup uses BackupStore's existing preflight.
class LegacyMappingStore {
  LegacyMappingStore(this.backups);
  final BackupStore backups;
  static const mapping = 'preserved-archive-v1';
  static const _allowed = {
    'quantity',
    'member_ids',
    'occurred_on',
    'size_id',
    'attributes',
    'receipt_status_hint',
    'receipt_batches',
    'note',
  };

  Future<LegacyArchive> read() async {
    final bytes = await backups.snapshot();
    final baseline = BackupStore.snapshotFingerprint(bytes);
    final source = await backups.prepare(bytes, expectedBaseline: baseline);
    try {
      final db = await openDatabase(
        p.join(source.folder.path, backups.databaseName),
        readOnly: true,
        singleInstance: false,
      );
      try {
        final existing = <int, Map<String, Object?>>{};
        final ambiguous = <int>{};
        for (final r in await db.query(RecordSchema.records)) {
          final info = StoredRecord.fromRow(r).information.toMap();
          final origin = info['legacy_source'], raw = info['legacy_raw'];
          if (raw is! Map || raw['id'] is! int) continue;
          // The historical profile is scoped exactly; no name/date fuzzy match.
          final recognized =
              origin is Map &&
              (origin['mapping'] == mapping ||
                  (origin['mapping'] == 'S25-user-confirmed-20261013' &&
                      origin['snapshot'] == '20261011_102725' &&
                      origin['application_id'] == 'com.example.count_tools'));
          if (!recognized) {
            ambiguous.add(raw['id'] as int);
            continue;
          }
          if (existing.containsKey(raw['id'])) {
            throw FormatException('旧行 #${raw['id']} 已有多个来源记录，请先核对');
          }
          existing[raw['id'] as int] = {'id': r['id'], 'raw': raw};
        }
        final projects = {
          for (final r in await db.query('project_data'))
            r['id'].toString(): _jsonRow(r),
        };
        final lists = {
          for (final r in await db.query('sub_project_data'))
            r['id'].toString(): _jsonRow(r),
        };
        final rows = <LegacyArchiveRow>[];
        for (final row in await db.query('item_data', orderBy: 'id')) {
          if (ambiguous.contains(row['id'])) {
            throw FormatException('旧行 #${row['id']} 可能已有未识别来源记录，请核对，未新增');
          }
          final raw = _jsonRow(row), prior = existing[row['id']];
          if (prior != null && _canonical(prior['raw']) != _canonical(raw)) {
            throw FormatException('旧行 #${row['id']} 的原文与已迁移来源冲突，未改账本');
          }
          rows.add(
            LegacyArchiveRow._(
              jsonEncode(raw),
              jsonEncode({
                'project': projects[row['projectId'].toString()],
                'subproject': lists[row['parentId'].toString()],
              }),
              prior?['id'] as String?,
            ),
          );
        }
        return LegacyArchive._(
          Uint8List.fromList(bytes),
          baseline,
          List.unmodifiable(rows),
          await IdentityStore(() async => db).directory(),
          List.unmodifiable(
            (await db.query(CatalogKind.size.table)).map(CatalogEntity.fromRow),
          ),
          Map.unmodifiable(
            (source.before['tables'] as Map).cast<String, int>(),
          ),
        );
      } finally {
        await db.close();
      }
    } finally {
      await backups.discardPreview(source);
    }
  }

  Future<LegacyMappingPreview> prepare(
    LegacyArchive archive,
    Map<int, RecordInformation> selections,
  ) async {
    final selected = Map<int, RecordInformation>.from(selections);
    final rows = {for (final r in archive.rows) r.id: r};
    if (selected.isEmpty) throw const FormatException('请至少选择一条未迁移旧记录');
    for (final entry in selected.entries) {
      if (!rows.containsKey(entry.key) ||
          rows[entry.key]!.existingRecordId != null) {
        throw FormatException('旧行 #${entry.key} 不可新增；已有记录请在记录页修改');
      }
      if (!entry.value.toMap().keys.every(_allowed.contains)) {
        throw FormatException('旧行 #${entry.key} 的映射包含非业务字段');
      }
    }
    final work = await backups.prepare(
      archive._bytes,
      expectedBaseline: archive._baseline,
    );
    try {
      final path = p.join(work.folder.path, backups.databaseName);
      final db = await openDatabase(
        path,
        singleInstance: false,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys=ON'),
      );
      final differences = <Map<String, Object?>>[];
      try {
        if ((await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='trigger' OR (type='table' AND upper(sql) LIKE 'CREATE VIRTUAL TABLE%')",
        )).isNotEmpty) {
          throw const FormatException('旧档案含触发器或虚拟表，保留完整备份，需单独检查后迁移');
        }
        await db.transaction((tx) async {
          final records = RecordStore(
            () async => OwnedTransactionDatabase(tx),
            managedEntry: true,
          );
          final batch = newOperationId();
          for (final entry in selected.entries) {
            final source = rows[entry.key]!;
            final info = RecordInformation.fromMap({
              ...entry.value.toMap(),
              'legacy_raw': source.raw,
              'legacy_archive_context': source.context,
              'legacy_source': {
                'mapping': mapping,
                'table': 'item_data',
                'source_id': source.id,
                'batch_id': batch,
                'semantics': 'explicit-user-mapping',
                'amount': 'raw-archive-only',
              },
            });
            final saved = await records.save(
              info,
              operationId: 'legacy-map:$batch:${source.id}',
            );
            differences.add({
              'source_id': source.id,
              'record_id': saved.id,
              'before': null,
              'mapped': entry.value.toMap(),
              'original': source.raw,
              'context': source.context,
            });
          }
          await StorageSchema.validate(tx, StorageSchema.version);
          if ((await tx.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
            throw const FormatException('隔离迁移关联不完整，未改账本');
          }
        });
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      } finally {
        await db.close();
      }
      final outer = decodeBackupJson(utf8.decode(archive._bytes)) as Map;
      final payload = Map<String, Object?>.from(
        decodeBackupJson(outer['payload'] as String) as Map,
      );
      final files = <String, String>{};
      await for (final f in work.folder.list(
        recursive: true,
        followLinks: false,
      )) {
        if (f is! File) continue;
        files[p
            .relative(f.path, from: work.folder.path)
            .split(p.separator)
            .join('/')] = base64Encode(
          await f.readAsBytes(),
        );
      }
      payload['schema'] = StorageSchema.version;
      payload['files'] = files;
      final text = jsonEncode(payload);
      final candidate = await backups.prepare(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'format': 'cheki-full-backup',
              'version': 1,
              'application_id': 'com.seniorious66.counttools',
              'created_at': actionStamp(DateTime.now()),
              'payload': text,
              'checksum': sha256.convert(utf8.encode(text)).toString(),
            }),
          ),
        ),
        expectedBaseline: archive._baseline,
      );
      return LegacyMappingPreview._(
        candidate,
        jsonEncode({
          'format': 'cheki-legacy-mapping-report',
          'version': 1,
          'added': selected.length,
          'already_mapped': archive.existing,
          'left_in_archive':
              archive.rows.length - archive.existing - selected.length,
          'original_tables': archive.tables,
          'result_tables': candidate.after['tables'],
          'settings_before': candidate.before['settings'],
          'settings_after': candidate.after['settings'],
          'files_before': candidate.before['files'],
          'files_after': candidate.after['files'],
          'changes': differences,
          'inventory_and_purchase_changes': 0,
          'originals_preserved': true,
          'amount_policy': '原金额原文独立归档；不推导购买、库存或新成本',
        }),
      );
    } finally {
      await backups.discardPreview(work);
    }
  }

  Future<void> apply(LegacyMappingPreview preview) =>
      backups.apply(preview.backup);
  Future<void> discard(LegacyMappingPreview preview) =>
      backups.discardPreview(preview.backup);
}
