import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../../data/database/schema.dart';
import 'backup_store.dart';
import 'catalog_contract.dart';
import 'catalog_store.dart';
import 'catalog_schema.dart';
import 'transport_codec.dart';

enum TransportMode { transactions, snapshot }

class TransportPreview {
  TransportPreview(
    this.backup,
    this.mode,
    this.batchId,
    this.added,
    this.unchanged,
    this.tables,
  );
  final BackupPreview backup;
  final TransportMode mode;
  final String batchId;
  final int added, unchanged;
  final Map<String, int> tables;
}

/// CSV is an editable, lossless table projection, never a second inventory
/// ledger. Every candidate is validated in isolation and committed through the
/// existing crash-safe complete-generation recovery protocol.
class TransportStore {
  TransportStore(this.backups);
  final BackupStore backups;
  static const _format = 'cheki-csv-tables';
  static const _readme = '''Cheki账本结构化数据包 v1
先保留原包，再解压修改 tables/*.csv，按原路径重新打包 ZIP。
每个单元格是 JSON 值：null 为 SQL NULL，"文字"为原文，数字不加引号。
JSON 字段内部的缺键、NULL、未知字段和时间原文必须保留。二进制用 {"\$blob":"base64"}。
列名、稳定 ID、内部动作时间、修订与关联须一致；不按名字自动匹配。
transactions：只追加完整新对象及其操作/修订/关联；相同 ID 相同内容跳过，冲突整批拒绝。
snapshot：完整账本替换恢复，包含历史与成本来源；不是在现库存上累加。
不可将库存汇总余额与历史购买重复导入；不支持无来源的余额自动转成历史交易。
seed.chekibackup 是格式/原始档案/设置附件载体，不要删除或修改。
空模板仅提供表头，不代表可凭空生成内部关联。manifest.json 中列结构来自原库，禁止增加 SQL。
仅支持本项目版本化多表包；普通统计 CSV 和 XLSX 不是本格式。
''';
  static String _q(String name) => '"${name.replaceAll('"', '""')}"';
  static Map<String, Object?> _payload(Uint8List bytes) {
    final outer = decodeBackupJson(utf8.decode(bytes)) as Map;
    return Map<String, Object?>.from(
      decodeBackupJson(outer['payload'] as String) as Map,
    );
  }

  static Uint8List _envelope(Map<String, Object?> payload) {
    final text = jsonEncode(payload);
    return Uint8List.fromList(
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
    );
  }

  static Object? _encodeCell(Object? value) =>
      value is Uint8List ? {'\$blob': base64Encode(value)} : value;
  static Object? _decodeCell(String value) {
    final decoded = decodeBackupJson(value);
    if (decoded is Map && decoded.length == 1 && decoded['\$blob'] is String) {
      return base64Decode(decoded['\$blob'] as String);
    }
    if (decoded == null ||
        decoded is String ||
        decoded is int ||
        decoded is double && decoded.isFinite) {
      return decoded;
    }
    throw const FormatException('CSV单元格需要JSON文字、数字、null或二进制值');
  }

  static String _rowKey(Map<String, Object?> row, List<String> keys) =>
      jsonEncode([for (final key in keys) _encodeCell(row[key])]);
  static String _rowValue(Map<String, Object?> row, List<String> cols) =>
      jsonEncode([for (final key in cols) _encodeCell(row[key])]);
  Future<Directory> _workspace() async {
    // This is an owned child of the already owned recovery root, never user data.
    await backups.recoverPending();
    final dir = Directory(
      p.join(backups.recovery.path, 'transport-${newOperationId()}'),
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<Map<String, Object?>>> _schema(Database db) async {
    final unsafe = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='trigger' OR (type='table' AND upper(sql) LIKE 'CREATE VIRTUAL TABLE%')",
    );
    if (unsafe.isNotEmpty) {
      throw const FormatException('数据库含触发器或虚拟表，请使用完整备份恢复，CSV不执行这些扩展');
    }
    final names = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND (name NOT LIKE 'sqlite_%' OR name='sqlite_sequence') ORDER BY name",
    );
    final result = <Map<String, Object?>>[];
    for (final item in names) {
      final name = item['name'] as String,
          info = await db.rawQuery('PRAGMA table_info(${_q(name)})');
      final pk = info.where((e) => (e['pk'] as int) > 0).toList()
        ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
      result.add({
        'name': name,
        'columns': [for (final e in info) e['name']],
        'keys': name == 'sqlite_sequence'
            ? ['name']
            : [for (final e in pk) e['name']],
        'file': 'tables/${result.length.toString().padLeft(3, '0')}.csv',
      });
    }
    return result;
  }

  Future<void> _materialize(Map<String, Object?> payload, Directory dir) async {
    for (final entry in (payload['files'] as Map).entries) {
      final name = entry.key as String;
      if (name.startsWith('/') ||
          name.contains('\\') ||
          name.contains(':') ||
          name.contains('\u0000') ||
          name.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
        throw const FormatException('文件路径无效');
      }
      final file = File(p.joinAll([dir.path, ...name.split('/')]));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(entry.value as String), flush: true);
    }
  }

  Future<Uint8List> export({
    TransportMode mode = TransportMode.snapshot,
    bool template = false,
  }) async {
    var seed = await backups.snapshot();
    final source = await backups.prepare(seed), dir = source.folder;
    final db = await openDatabase(
      p.join(dir.path, backups.databaseName),
      readOnly: !template,
      singleInstance: false,
    );
    try {
      final schema = await _schema(db);
      if (template) {
        await db.execute('PRAGMA foreign_keys=OFF');
        await db.execute('PRAGMA secure_delete=ON');
        await db.transaction((tx) async {
          for (final table in schema) {
            if (table['name'] != StorageSchema.migrationTable) {
              await tx.delete(_q(table['name'] as String));
            }
          }
          final stamp = actionStamp(DateTime.now());
          for (final entry in CatalogSchema.defaultSizes.entries) {
            await tx.insert('cheki_sizes', {
              'id': entry.key,
              'name': entry.value,
              'active': 1,
              'created_at': stamp,
              'updated_at': stamp,
              'revision': 1,
              'source': 'default',
              'ext': null,
            });
          }
          await StorageSchema.validate(tx, StorageSchema.version);
        });
        await db.execute('VACUUM');
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
        // No user rows, preferences, attachments or deleted SQLite pages in templates.
        seed = _envelope({
          'schema': StorageSchema.version,
          'settings': <String, Object?>{},
          'files': {
            backups.databaseName: base64Encode(
              await File(p.join(dir.path, backups.databaseName)).readAsBytes(),
            ),
          },
        });
      }
      final files = <String, List<int>>{
        'seed.chekibackup': seed,
        'README.txt': utf8.encode(_readme),
      };
      for (final table in schema) {
        final name = table['name'] as String,
            cols = (table['columns'] as List).cast<String>();
        final rows = template
            ? <Map<String, Object?>>[]
            : await db.query(_q(name));
        files[table['file'] as String] = utf8.encode(
          TransportCsv.encode([
            cols,
            for (final row in rows)
              [for (final c in cols) jsonEncode(_encodeCell(row[c]))],
          ]),
        );
      }
      files['manifest.json'] = utf8.encode(
        jsonEncode({
          'format': _format,
          'version': 1,
          'schema': StorageSchema.version,
          'mode': mode.name,
          'batch_id': newOperationId(),
          'captured_at': actionStamp(DateTime.now()),
          'template': template,
          'tables': schema,
        }),
      );
      return TransportZip.encode(files);
    } finally {
      await db.close();
      await backups.discardPreview(source);
    }
  }

  Future<TransportPreview> prepare(
    Uint8List bytes,
    TransportMode selected,
  ) async {
    try {
      return await _prepare(bytes, selected);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('整批检查未通过，账本未变：$e');
    }
  }

  Future<TransportPreview> _prepare(
    Uint8List bytes,
    TransportMode selected,
  ) async {
    final files = TransportZip.decode(bytes);
    if (!files.containsKey('manifest.json') ||
        !files.containsKey('seed.chekibackup')) {
      throw const FormatException('缺少数据包清单或原始档案');
    }
    final manifest =
            decodeBackupJson(utf8.decode(files['manifest.json']!)) as Map,
        batchId = manifest['batch_id'];
    if (manifest['format'] != _format ||
        manifest['version'] != 1 ||
        (manifest['schema'] is! int ||
            (manifest['schema'] as int) < 8 ||
            (manifest['schema'] as int) > StorageSchema.version) ||
        manifest['mode'] != selected.name ||
        batchId is! String ||
        !RegExp(r'^[A-Za-z0-9-]{1,120}$').hasMatch(batchId)) {
      throw const FormatException('数据包版本或模式不符，请选择对应的交易/快照模式');
    }
    if (manifest['template'] != false && selected == TransportMode.snapshot) {
      throw const FormatException('空模板不能作为完整快照恢复');
    }
    final descriptors = List<Map<String, Object?>>.from(
          (manifest['tables'] as List).map(
            (t) => Map<String, Object?>.from(t as Map),
          ),
        ),
        allowed = {
          'manifest.json',
          'seed.chekibackup',
          'README.txt',
          for (final t in descriptors) t['file'],
        };
    if (files.keys.any((s) => !allowed.contains(s)) ||
        descriptors.map((e) => e['file']).toSet().length !=
            descriptors.length) {
      throw const FormatException('数据包存在未知文件或重复表');
    }
    // Validate the seed with the same strict backup parser, schema and references.
    final source = await backups.prepare(files['seed.chekibackup']!);
    Directory? assembly;
    try {
      final sourceDb = await openDatabase(
        p.join(source.folder.path, backups.databaseName),
        readOnly: true,
        singleInstance: false,
      );
      late List<Map<String, Object?>> expected;
      final sourceSequence = <String, int>{};
      try {
        expected = await _schema(sourceDb);
        for (final row in await sourceDb.query('sqlite_sequence')) {
          sourceSequence[row['name'] as String] = row['seq'] as int;
        }
      } finally {
        await sourceDb.close();
      }
      if (jsonEncode(expected) != jsonEncode(descriptors)) {
        throw const FormatException('表/字段/主键清单与原始结构不符');
      }
      final incoming = <String, List<Map<String, Object?>>>{};
      for (final table in descriptors) {
        final name = table['name'] as String,
            cols = (table['columns'] as List).cast<String>(),
            csv = files[table['file']];
        if (csv == null) throw FormatException('$name：CSV缺失');
        final rows = TransportCsv.decode(utf8.decode(csv));
        if (rows.isEmpty || jsonEncode(rows.first) != jsonEncode(cols)) {
          throw FormatException('$name：列名或顺序不符');
        }
        final keys = (table['keys'] as List).cast<String>(),
            seen = <String>{},
            parsed = <Map<String, Object?>>[];
        for (var r = 1; r < rows.length; r++) {
          try {
            if (rows[r].length != cols.length) {
              throw const FormatException('列数量不符');
            }
            final row = {
              for (var c = 0; c < cols.length; c++)
                cols[c]: _decodeCell(rows[r][c]),
            };
            if (keys.isNotEmpty &&
                keys.every((k) => row[k] != null) &&
                !seen.add(_rowKey(row, keys))) {
              throw const FormatException('重复稳定ID');
            }
            parsed.add(row);
          } catch (e) {
            throw FormatException('$name 第${r + 1}行：$e');
          }
        }
        incoming[name] = parsed;
      }
      final base = await backups.snapshot(),
          baseline = BackupStore.snapshotFingerprint(base),
          targetPayload = _payload(
            selected == TransportMode.snapshot
                ? files['seed.chekibackup']!
                : base,
          ),
          currentPayload = _payload(base),
          sourcePayload = _payload(files['seed.chekibackup']!);
      final receiptName = '.cheki-transport/$batchId.json',
          receipt = jsonEncode({
            'batch_id': batchId,
            'mode': selected.name,
            'digest': sha256.convert(bytes).toString(),
          }),
          previousReceipt = (currentPayload['files'] as Map)[receiptName];
      if (previousReceipt != null &&
          previousReceipt != base64Encode(utf8.encode(receipt))) {
        throw const FormatException('这个批次已使用其他内容导入，禁止重用批次ID');
      }
      final dir = await _workspace();
      assembly = dir;
      await _materialize(targetPayload, dir);
      final db = await openDatabase(
        p.join(dir.path, backups.databaseName),
        singleInstance: false,
      );
      var added = 0, unchanged = 0;
      final counts = <String, int>{};
      try {
        final targetSchema = await _schema(db);
        if (jsonEncode(targetSchema) != jsonEncode(expected)) {
          throw const FormatException('当前账本表结构不同，禁止追加或丢弃未知表');
        }
        await db.execute('PRAGMA foreign_keys=OFF');
        await db.transaction((tx) async {
          for (final table in descriptors) {
            final name = table['name'] as String,
                cols = (table['columns'] as List).cast<String>(),
                keys = (table['keys'] as List).cast<String>(),
                rows = incoming[name]!;
            if (selected == TransportMode.snapshot) {
              await tx.delete(_q(name));
            }
            final existing = selected == TransportMode.snapshot
                ? <Map<String, Object?>>[]
                : await tx.query(_q(name));
            final indexed = {
              for (final row in existing) _rowKey(row, keys): row,
            };
            final unkeyed = <String, int>{};
            for (final row in existing) {
              if (keys.isEmpty || keys.any((k) => row[k] == null)) {
                final value = _rowValue(row, cols);
                unkeyed[value] = (unkeyed[value] ?? 0) + 1;
              }
            }
            for (final row in rows) {
              final old = indexed[_rowKey(row, keys)];
              if (selected == TransportMode.transactions &&
                  name == 'sqlite_sequence') {
                if (old != null) {
                  if ((row['seq'] as int) > (old['seq'] as int)) {
                    await tx.update(
                      _q(name),
                      row,
                      where: 'name=?',
                      whereArgs: [row['name']],
                    );
                  }
                  continue;
                }
              } else if (selected == TransportMode.transactions &&
                  (keys.isEmpty || keys.any((k) => row[k] == null))) {
                final value = _rowValue(row, cols),
                    remaining = unkeyed[value] ?? 0;
                if (remaining > 0) {
                  unkeyed[value] = remaining - 1;
                  unchanged++;
                  continue;
                }
                throw FormatException('$name：无稳定主键的表仅允许保持原行，请使用完整快照');
              } else if (old != null) {
                if (_rowValue(old, cols) == _rowValue(row, cols)) {
                  unchanged++;
                  continue;
                }
                throw FormatException(
                  '$name：ID ${_rowKey(row, keys)} 与现有内容冲突，整批未导入',
                );
              }
              await tx.insert(_q(name), row);
              added++;
            }
            counts[name] = rows.length;
          }
          final sequence = await tx.query('sqlite_sequence');
          if (selected == TransportMode.snapshot &&
              !sequence
                  .map((s) => s['name'])
                  .toSet()
                  .containsAll(sourceSequence.keys)) {
            throw const FormatException('快照不能丢弃原序列');
          }
          for (final row in sequence) {
            final name = row['name'],
                value = row['seq'],
                table = descriptors.where((t) => t['name'] == name).toList();
            if (name is! String ||
                value is! int ||
                value < 0 ||
                table.length != 1 ||
                (selected == TransportMode.snapshot &&
                    value < (sourceSequence[name] ?? 0))) {
              throw const FormatException('自增序列无效或小于原档案');
            }
            final keys = (table.single['keys'] as List).cast<String>();
            if (keys.length != 1) throw const FormatException('自增序列主键无效');
            final max = (await tx.rawQuery(
              'SELECT MAX(${_q(keys.single)}) AS n FROM ${_q(name)}',
            )).single['n'];
            if (max is int && max > value) {
              throw const FormatException('自增序列小于已有ID');
            }
          }
          if ((await tx.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
            throw const FormatException('导入存在无效关联，整批未导入');
          }
          if ((manifest['schema'] as int) < 9) {
            await tx.insert(StorageSchema.migrationTable, {
              'version': 9,
              'migration': StorageSchema.migrations[9],
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
            await tx.execute('PRAGMA user_version=9');
          }
          await StorageSchema.validate(tx, StorageSchema.version);
        });
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      } finally {
        await db.close();
      }
      if (selected == TransportMode.transactions) {
        final settings = Map<String, Object?>.from(
          currentPayload['settings'] as Map,
        );
        for (final entry in (sourcePayload['settings'] as Map).entries) {
          if (settings.containsKey(entry.key) &&
              jsonEncode(settings[entry.key]) != jsonEncode(entry.value)) {
            throw FormatException('设置 ${entry.key} 冲突，整批未导入');
          }
          settings[entry.key as String] = entry.value;
        }
        targetPayload['settings'] = settings;
        final targetFiles = Map<String, Object?>.from(
          targetPayload['files'] as Map,
        );
        for (final entry in (sourcePayload['files'] as Map).entries) {
          final name = entry.key as String;
          if ([
            backups.databaseName,
            '${backups.databaseName}-wal',
            '${backups.databaseName}-shm',
            '${backups.databaseName}-journal',
          ].contains(name)) {
            continue;
          }
          if (targetFiles.containsKey(name) &&
              targetFiles[name] != entry.value) {
            throw FormatException('附件 $name 冲突，整批未导入');
          }
          if (!targetFiles.containsKey(name)) {
            await _materialize({
              'files': {name: entry.value},
            }, dir);
          }
        }
      }
      final packed = <String, String>{};
      await _materialize({
        'files': {receiptName: base64Encode(utf8.encode(receipt))},
      }, dir);
      await for (final file in dir.list(recursive: true, followLinks: false)) {
        if (file is! File) continue;
        final name = p
            .relative(file.path, from: dir.path)
            .split(p.separator)
            .join('/');
        packed[name] = base64Encode(await file.readAsBytes());
      }
      targetPayload['files'] = packed;
      targetPayload['schema'] = StorageSchema.version;
      final candidate = await backups.prepare(
        _envelope(targetPayload),
        expectedBaseline: baseline,
      );
      return TransportPreview(
        candidate,
        selected,
        batchId,
        added,
        unchanged,
        counts,
      );
    } finally {
      await backups.discardPreview(source);
      final dir = assembly;
      if (dir != null &&
          p.dirname(p.normalize(dir.absolute.path)) ==
              p.normalize(backups.recovery.absolute.path) &&
          RegExp(r'^transport-[A-Za-z0-9-]+$').hasMatch(p.basename(dir.path)) &&
          await FileSystemEntity.type(dir.path, followLinks: false) ==
              FileSystemEntityType.directory) {
        await dir.delete(recursive: true);
      }
    }
  }

  Future<void> discard(TransportPreview preview) =>
      backups.discardPreview(preview.backup);
  Future<void> apply(TransportPreview preview) async {
    await backups.apply(preview.backup);
    await discard(preview);
  }
}
