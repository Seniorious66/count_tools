import 'dart:async';
import 'schema.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();

  factory DatabaseHelper() => _instance;

  static Database? _database;
  static Future<Database>? _opening;
  static Future<String> Function()? pathResolver;
  static bool maintenance = false;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (maintenance) throw StateError('账本正在备份或恢复，请稍后重试');
    if (_database != null) return _database!;
    return _opening ??= _initDB()
        .then((db) => _database = db)
        .whenComplete(() => _opening = null);
  }

  Future<Database> _initDB() async {
    final path = pathResolver != null
        ? await pathResolver!()
        : join(
            (await getApplicationDocumentsDirectory()).path,
            'user_database.db',
          );
    return await openDatabase(
      path,
      version: StorageSchema.version,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys=ON'),
      onCreate: (db, version) async {
        await _createDB(db, 1);
        await StorageSchema.migrate(db, 1, version);
      },
      onUpgrade: StorageSchema.migrate,
      onDowngrade: (db, oldVersion, newVersion) async {
        throw StateError('Newer storage cannot be downgraded');
      },
      onOpen: (db) async => StorageSchema.validate(db, await db.getVersion()),
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute("""
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL,
        user_key TEXT NOT NULL,
        ext TEXT
      )
    """);
    await db.execute("""
      CREATE TABLE project_data (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        subTitle TEXT,
        count TEXT,
        ext TEXT
      )
    """);
    await db.execute("""
      CREATE TABLE sub_project_data (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        count TEXT NOT NULL,
        countPre TEXT NOT NULL,
        color TEXT NOT NULL,
        textColor TEXT NOT NULL,
        parentId TEXT NOT NULL,
        ext TEXT
      )
    """);
    await db.execute("""
      CREATE TABLE item_data (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        price TEXT,
        eventName TEXT,
        type TEXT,
        date TEXT NOT NULL,
        itemName TEXT NOT NULL,
        parentId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        ext TEXT
      )
    """);
  }

  Future<void> close() async {
    if (_opening != null) await _opening;
    final db = _database;
    _database = null;
    await db?.close();
  }
}
