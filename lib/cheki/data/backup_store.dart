import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../../data/database/data_base.dart';
import '../../data/database/schema.dart';
import 'catalog_store.dart';
import 'catalog_contract.dart';

const _maxBackup = 128 * 1024 * 1024;
String _digest(List<int> bytes) => sha256.convert(bytes).toString();
Object? decodeBackupJson(String text) {
  final decoded = jsonDecode(text);
  var i = 0;
  void space() {
    while (i < text.length && ' \r\n\t'.contains(text[i])) {
      i++;
    }
  }

  String string() {
    final start = i++;
    while (i < text.length) {
      if (text[i] == '\\') {
        i += 2;
        continue;
      }
      if (text[i++] == '"') {
        return jsonDecode(text.substring(start, i)) as String;
      }
    }
    throw const FormatException('JSON文字无效');
  }

  void value() {
    space();
    final ch = text[i];
    if (ch == '{') {
      i++;
      space();
      final keys = <String>{};
      if (text[i] == '}') {
        i++;
        return;
      }
      while (true) {
        space();
        final key = string();
        if (!keys.add(key)) throw const FormatException('备份存在重复键，拒绝丢弃信息');
        space();
        i++;
        value();
        space();
        if (text[i++] == '}') break;
      }
    } else if (ch == '[') {
      i++;
      space();
      if (text[i] == ']') {
        i++;
        return;
      }
      while (true) {
        value();
        space();
        if (text[i++] == ']') break;
      }
    } else if (ch == '"') {
      string();
    } else {
      while (i < text.length && !',]} \r\n\t'.contains(text[i])) {
        i++;
      }
    }
  }

  value();
  return decoded;
}

final backupEpoch = ValueNotifier<int>(0);

Future<Map<String, Object?>> readAppPreferences() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)};
}

Future<void> writeAppPreferences(Map<String, Object?> values) async {
  final prefs = await SharedPreferences.getInstance();
  for (final k in prefs.getKeys().difference(values.keys.toSet())) {
    if (!await prefs.remove(k)) throw StateError('设置移除失败');
  }
  for (final entry in values.entries) {
    final v = entry.value;
    final result = switch (v) {
      bool v => await prefs.setBool(entry.key, v),
      int v => await prefs.setInt(entry.key, v),
      double v => await prefs.setDouble(entry.key, v),
      String v => await prefs.setString(entry.key, v),
      List v => await prefs.setStringList(entry.key, v.cast<String>()),
      _ => false,
    };
    if (!result) throw StateError('设置写入失败');
  }
  await prefs.reload();
  if (jsonEncode(await readAppPreferencesSorted()) !=
      jsonEncode(_sort(values))) {
    throw StateError('设置读回不一致');
  }
}

Map<String, Object?> _sort(Map<String, Object?> m) => {
  for (final key in m.keys.toList()..sort()) key: m[key],
};
Future<Map<String, Object?>> readAppPreferencesSorted() async =>
    _sort(await readAppPreferences());
void _preferences(Map<String, Object?> values) {
  for (final v in values.values) {
    if (!(v is bool ||
        v is int ||
        v is double && v.isFinite ||
        v is String ||
        v is List && v.every((e) => e is String))) {
      throw const FormatException('备份设置类型无效');
    }
  }
}

void _relative(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('\\') ||
      name.contains(':') ||
      name.split('/').any((x) => x.isEmpty || x == '.' || x == '..') ||
      name.contains('\u0000')) {
    throw const FormatException('备份文件路径无效');
  }
}

class BackupPreview {
  BackupPreview(
    this.folder,
    this.baseline,
    this.staged,
    this.before,
    this.after,
    this.sourceSchema,
  );
  final Directory folder;
  final String baseline, staged;
  final Map<String, Object?> before, after;
  final int sourceSchema;
}

/// Works on a complete closed application generation. Old generations are retained.
/// The caller must use a private app documents directory or a marked synthetic root.
class BackupStore {
  BackupStore({
    required this.documents,
    required this.readSettings,
    required this.writeSettings,
    required this.closeMain,
    this.maintenance,
    this.fault,
  });
  final Directory documents;
  final Future<Map<String, Object?>> Function() readSettings;
  final Future<void> Function(Map<String, Object?>) writeSettings;
  final Future<void> Function() closeMain;
  final void Function(bool)? maintenance;
  final Future<void> Function(String)? fault;
  bool busy = false;
  static Future<BackupStore> app() async => BackupStore(
    documents: DatabaseHelper.pathResolver == null
        ? await getApplicationDocumentsDirectory()
        : Directory(p.dirname(await DatabaseHelper.pathResolver!())),
    readSettings: readAppPreferences,
    writeSettings: writeAppPreferences,
    closeMain: DatabaseHelper().close,
    maintenance: (value) => DatabaseHelper.maintenance = value,
  );
  Directory get recovery => Directory('${documents.path}.cheki-recovery');
  File get journal => File(p.join(recovery.path, 'transaction.json'));
  String get databaseName => 'user_database.db';
  Future<void> _owned() async {
    if (!p.isAbsolute(documents.path) ||
        p.dirname(documents.path) == documents.path ||
        await FileSystemEntity.type(documents.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw StateError('恢复位置无效');
    }
    final marker = File(p.join(recovery.path, '.cheki-recovery-owner'));
    if (await recovery.exists()) {
      if (!await marker.exists() ||
          await marker.readAsString() != documents.absolute.path) {
        throw StateError('恢复目录没有本项目标记');
      }
    } else {
      await recovery.create();
      await marker.writeAsString(documents.absolute.path, flush: true);
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() task) async {
    if (busy) throw StateError('备份恢复正在进行');
    busy = true;
    maintenance?.call(true);
    try {
      await closeMain();
      return await task();
    } finally {
      maintenance?.call(await journal.exists());
      busy = false;
    }
  }

  Future<Map<String, Uint8List>> _files(Directory dir) async {
    final result = <String, Uint8List>{};
    var total = 0;
    if (!await dir.exists()) throw StateError('账本目录不存在');
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is Link) throw const FormatException('备份不支持指向其他位置的链接');
      if (entity is! File) continue;
      final name = p
          .relative(entity.path, from: dir.path)
          .split(p.separator)
          .join('/');
      _relative(name);
      final bytes = await entity.readAsBytes();
      total += bytes.length;
      if (total > _maxBackup) throw const FormatException('完整备份超过当前大小限制');
      result[name] = bytes;
    }
    if (!result.containsKey(databaseName)) {
      throw const FormatException('完整数据库文件缺失');
    }
    return result;
  }

  String _fingerprint(
    Map<String, Uint8List> files,
    Map<String, Object?> settings,
  ) => _digest(
    utf8.encode(
      jsonEncode({
        'files': {
          for (final k in files.keys.toList()..sort()) k: _digest(files[k]!),
        },
        'settings': _sort(settings),
      }),
    ),
  );
  Future<Map<String, Object?>> _inspect(
    Directory dir, {
    bool migrate = false,
  }) async {
    final path = p.join(dir.path, databaseName);
    Database db = await openDatabase(
      path,
      readOnly: true,
      singleInstance: false,
    );
    int schema;
    try {
      schema = await db.getVersion();
      await StorageSchema.validate(db, schema);
    } finally {
      await db.close();
    }
    if (migrate && schema < StorageSchema.version) {
      db = await openDatabase(
        path,
        singleInstance: false,
        version: StorageSchema.version,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys=ON'),
        onUpgrade: StorageSchema.migrate,
        onCreate: (_, _) async => throw StateError('不能创建空库代替备份'),
        onDowngrade: (_, _, _) async => throw StateError('不能降级备份'),
        onOpen: (d) async => StorageSchema.validate(d, await d.getVersion()),
      );
      await db.close();
    }
    db = await openDatabase(path, readOnly: true, singleInstance: false);
    try {
      final tables = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
          ),
          counts = <String, int>{};
      for (final r in tables) {
        final name = r['name'] as String;
        counts[name] = Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM "${name.replaceAll('"', '""')}"',
          ),
        )!;
      }
      return {'schema': await db.getVersion(), 'tables': counts};
    } finally {
      await db.close();
    }
  }

  Future<Uint8List> snapshot() async => _exclusive(() async {
    await _owned();
    if (await journal.exists()) throw StateError('请先完成上次恢复');
    final settings = await readSettings();
    _preferences(settings);
    final summary = await _inspect(documents), files = await _files(documents);
    final payload = jsonEncode({
      'schema': summary['schema'],
      'settings': settings,
      'files': {
        for (final k in files.keys.toList()..sort()) k: base64Encode(files[k]!),
      },
    });
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'cheki-full-backup',
          'version': 1,
          'application_id': 'com.seniorious66.counttools',
          'created_at': actionStamp(DateTime.now()),
          'payload': payload,
          'checksum': _digest(utf8.encode(payload)),
        }),
      ),
    );
    if (bytes.length > _maxBackup) throw const FormatException('完整备份超过当前大小限制');
    return bytes;
  });

  /// A transport assembled from a captured generation must not adopt a newer
  /// baseline while it is being prepared, otherwise intervening writes get lost.
  static String snapshotFingerprint(Uint8List bytes) {
    final outer = decodeBackupJson(utf8.decode(bytes)) as Map;
    final payload = decodeBackupJson(outer['payload'] as String) as Map;
    return _digest(
      utf8.encode(
        jsonEncode({
          'files': {
            for (final key in (payload['files'] as Map).keys.toList()..sort())
              key: _digest(base64Decode(payload['files'][key] as String)),
          },
          'settings': _sort(
            Map<String, Object?>.from(payload['settings'] as Map),
          ),
        }),
      ),
    );
  }

  Future<BackupPreview> prepare(
    Uint8List bytes, {
    String? expectedBaseline,
  }) async {
    if (bytes.length > _maxBackup) throw const FormatException('备份过大');
    final envelope = decodeBackupJson(utf8.decode(bytes)) as Map;
    if (envelope['format'] != 'cheki-full-backup' ||
        envelope['version'] != 1 ||
        envelope['application_id'] != 'com.seniorious66.counttools' ||
        envelope['payload'] is! String ||
        envelope['checksum'] !=
            _digest(utf8.encode(envelope['payload'] as String))) {
      throw const FormatException('备份格式或完整性校验失败');
    }
    final payload = Map<String, Object?>.from(
          decodeBackupJson(envelope['payload'] as String) as Map,
        ),
        settings = Map<String, Object?>.from(payload['settings'] as Map);
    _preferences(settings);
    final raw = payload['files'] as Map, files = <String, Uint8List>{};
    var total = 0;
    for (final entry in raw.entries) {
      final name = entry.key as String;
      _relative(name);
      if (Platform.isWindows &&
          files.keys.any((k) => k.toLowerCase() == name.toLowerCase())) {
        throw const FormatException('备份文件名冲突');
      }
      final data = base64Decode(entry.value as String);
      total += data.length;
      if (total > _maxBackup) throw const FormatException('备份文件过大');
      files[name] = data;
    }
    if (!files.containsKey(databaseName)) {
      throw const FormatException('数据库文件缺失');
    }
    await _owned();
    if (await journal.exists()) throw StateError('请先完成上次恢复');
    final stage = Directory(
      p.join(recovery.path, 'incoming-${newOperationId()}'),
    );
    await stage.create();
    for (final entry in files.entries) {
      final f = File(p.joinAll([stage.path, ...entry.key.split('/')]));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(entry.value, flush: true);
    }
    final source = await _inspect(stage);
    if (source['schema'] != payload['schema']) {
      throw const FormatException('备份版本声明与数据库不同');
    }
    final after = await _inspect(stage, migrate: true);
    final preparedSettings = File('${stage.path}.settings.json');
    await preparedSettings.writeAsString(jsonEncode(settings), flush: true);
    final staged = _fingerprint(await _files(stage), settings);
    return _exclusive(() async {
      final currentSettings = await readSettings();
      _preferences(currentSettings);
      final before = await _inspect(documents);
      final currentFiles = await _files(documents);
      final baseline = _fingerprint(currentFiles, currentSettings);
      if (expectedBaseline != null && baseline != expectedBaseline) {
        throw const CatalogException('制作预览期间账本已变化，请重新检查');
      }
      before.addAll({
        'settings': currentSettings.length,
        'files': currentFiles.length,
      });
      after.addAll({'settings': settings.length, 'files': files.length});
      return BackupPreview(
        stage,
        baseline,
        staged,
        before,
        after,
        source['schema'] as int,
      );
    });
  }

  Future<void> _writeJournal(Map<String, Object?> state) async {
    final tmp = File('${journal.path}.tmp');
    await tmp.writeAsString(jsonEncode(state), flush: true);
    await tmp.rename(journal.path);
  }

  void _childName(String value, String prefix) {
    if (p.basename(value) != value ||
        !RegExp('^$prefix[a-zA-Z0-9-]+\$').hasMatch(value)) {
      throw StateError('恢复事务位置无效');
    }
  }

  Future<void> _recover() async {
    if (!await journal.exists()) return;
    final state = Map<String, Object?>.from(
      jsonDecode(await journal.readAsString()) as Map,
    );
    if (state['target'] != documents.absolute.path ||
        !['prepared', 'committed'].contains(state['phase'])) {
      throw StateError('恢复事务标记无效');
    }
    _childName(state['previous'] as String, 'previous-');
    _childName(state['incoming'] as String, 'incoming-');
    final previous = Directory(
      p.join(recovery.path, state['previous'] as String),
    );
    final oldSettings = Map<String, Object?>.from(state['old_settings'] as Map),
        newSettings = Map<String, Object?>.from(state['new_settings'] as Map);
    _preferences(oldSettings);
    _preferences(newSettings);
    if (state['phase'] == 'committed') {
      final current = await _files(documents), settings = await readSettings();
      if (_fingerprint(current, settings) != state['new_fingerprint']) {
        throw StateError('已提交恢复代不一致，保留材料停止');
      }
      await _inspect(documents);
    } else {
      if (await previous.exists()) {
        await _inspect(previous);
        if (await documents.exists()) {
          await documents.rename(
            p.join(recovery.path, 'failed-${newOperationId()}'),
          );
        }
        await previous.rename(documents.path);
      }
      if (!await documents.exists()) throw StateError('原账本代缺失，保留材料停止');
      await writeSettings(oldSettings);
      await _inspect(documents);
      if (_fingerprint(await _files(documents), await readSettings()) !=
          state['old_fingerprint']) {
        throw StateError('原账本恢复读回不一致');
      }
    }
    // Keep the durable completed receipt and all former generations.
    await journal.rename(
      p.join(recovery.path, 'receipt-${newOperationId()}.json'),
    );
  }

  Future<void> recoverPending() async {
    if (!await recovery.exists()) return;
    await _owned();
    await _exclusive(_recover);
  }

  /// Discard only an unused, owned preflight copy, never former live generations.
  Future<void> discardPreview(BackupPreview preview) async {
    if (busy || await journal.exists()) return;
    final path = p.normalize(preview.folder.absolute.path);
    if (p.dirname(path) != p.normalize(recovery.absolute.path) ||
        !RegExp(r'^incoming-[A-Za-z0-9-]+$').hasMatch(p.basename(path))) {
      throw StateError('预览清理位置无效');
    }
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('预览清理不跟随链接');
    }
    if (await preview.folder.exists()) {
      await preview.folder.delete(recursive: true);
    }
    final settings = File('$path.settings.json');
    if (await settings.exists()) await settings.delete();
  }

  Future<void> apply(BackupPreview preview) async => _exclusive(() async {
    await _owned();
    if (await journal.exists()) throw StateError('上次恢复尚未处理');
    if (p.dirname(preview.folder.path) != recovery.path) {
      throw StateError('预检来源位置无效');
    }
    _childName(p.basename(preview.folder.path), 'incoming-');
    final newSettings = Map<String, Object?>.from(
      jsonDecode(
            await File('${preview.folder.path}.settings.json').readAsString(),
          )
          as Map,
    );
    _preferences(newSettings);
    if (_fingerprint(await _files(preview.folder), newSettings) !=
        preview.staged) {
      throw StateError('预检后备份已变化，请重选');
    }
    await _inspect(preview.folder);
    final oldSettings = await readSettings(),
        oldFiles = await _files(documents);
    _preferences(oldSettings);
    if (_fingerprint(oldFiles, oldSettings) != preview.baseline) {
      throw const CatalogException('预览后当前账本已变化，请重新检查备份');
    }
    final previous = Directory(
      p.join(recovery.path, 'previous-${newOperationId()}'),
    );
    final state = <String, Object?>{
      'target': documents.absolute.path,
      'phase': 'prepared',
      'previous': p.basename(previous.path),
      'incoming': p.basename(preview.folder.path),
      'old_settings': oldSettings,
      'new_settings': newSettings,
      'old_fingerprint': preview.baseline,
      'new_fingerprint': preview.staged,
    };
    await _writeJournal(state);
    try {
      await documents.rename(previous.path);
      if (fault != null) await fault!('old-moved');
      await preview.folder.rename(documents.path);
      if (fault != null) await fault!('new-installed');
      await writeSettings(newSettings);
      if (fault != null) await fault!('settings-written');
      await _inspect(documents);
      if (_fingerprint(await _files(documents), await readSettings()) !=
          preview.staged) {
        throw StateError('完整恢复读回不一致');
      }
      state['phase'] = 'committed';
      await _writeJournal(state);
      if (fault != null) await fault!('committed');
      await _recover();
    } catch (_) {
      await _recover();
      rethrow;
    }
    backupEpoch.value++;
  });
}
