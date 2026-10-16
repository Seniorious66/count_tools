import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'bi_fixture.dart';
import 'transport_test.dart' show state;

// Counts actual read SQL sent through the same Database/Transaction interface.
class ReadCounter implements Database {
  ReadCounter(this.inner);
  final Database inner;
  int reads = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) => inner.transaction(
    (tx) => action(_CountedTransaction(tx, () => reads++)),
    exclusive: exclusive,
  );
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    reads++;
    return inner.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) {
    reads++;
    return inner.rawQuery(sql, args);
  }
}

class _CountedTransaction implements Transaction {
  _CountedTransaction(this.inner, this.read);
  final Transaction inner;
  final void Function() read;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    read();
    return inner.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? args,
  ]) {
    read();
    return inner.rawQuery(sql, args);
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => inner.insert(
    table,
    values,
    nullColumnHack: nullColumnHack,
    conflictAlgorithm: conflictAlgorithm,
  );
  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => inner.update(
    table,
    values,
    where: where,
    whereArgs: whereArgs,
    conflictAlgorithm: conflictAlgorithm,
  );
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      inner.delete(table, where: where, whereArgs: whereArgs);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  test(
    'profile isolated edit label, coupon loading, save and list refresh',
    () async {
      final output = Platform.environment['COUNT_TOOLS_R2_PERF'];
      if (output == null) return;
      final reports = <Object?>[];
      for (final count in [343, 5000]) {
        final f = BiFixture();
        await f.open();
        try {
          StoredRecord? last;
          for (var n = 0; n < count; n++) {
            last = await f.records.save(
              RecordInformation.fromMap({
                'quantity': 1,
                'member_ids': [f.a],
                'occurred_on': '2026-10-11',
                'ext': {'原文': 'fixture-$n', 'unknown': null},
              }),
              operationId: 'seed-$n',
            );
          }
          // A realistic accumulated history, not an empty ledger benchmark.
          for (var n = 0; n < (count == 343 ? 707 : 1000); n++) {
            last = await f.records.save(
              last!.information,
              original: last,
              operationId: 'revision-$n',
            );
          }
          final db = ReadCounter(await f.records.database());
          final store = RecordStore(() async => db, clock: () => f.clock);
          final entry = EntryStore(store.database, clock: () => f.clock);
          final bi = BiStore(store.database, clock: () => f.clock);
          final durations = <String, List<int>>{},
              queries = <String, List<int>>{};
          Future<void> measure(
            String key,
            Future<void> Function() action,
          ) async {
            final before = db.reads, watch = Stopwatch()..start();
            await action();
            watch.stop();
            durations.putIfAbsent(key, () => []).add(watch.elapsedMicroseconds);
            queries.putIfAbsent(key, () => []).add(db.reads - before);
          }

          for (var n = 0; n < 11; n++) {
            await measure('edit_labels', () async {
              try {
                await (store as dynamic).readLabels();
              } on NoSuchMethodError {
                await store.readModel();
              }
            });
            await measure('coupon_availability', () async {
              await entry.availability(recordId: last!.id);
            });
            await measure('review_labels', () async {
              try {
                await (store as dynamic).readLabels();
              } on NoSuchMethodError {
                await store.readModel();
              }
            });
            await measure('atomic_save', () async {
              last = await entry.save(
                last!.information,
                plan: CouponPlan({'mode': 'record_only'}),
                original: last,
                operationId: 'edit-$n',
              );
            });
            await measure('list_refresh', () async {
              await store.readModel();
            });
            await measure('bi_snapshot_and_report', () async {
              final snapshot = await bi.read();
              final report = snapshot.report(
                BiPeriod(BiScope.all, '2026-10-14'),
              );
              expect(report.summary.knownQuantity, count);
              expect(report.memberQuantity, count);
            });
            await measure('recency_and_200_sorts', () async {
              final rows = await store.list();
              final recent = MemberRecency(rows, excluding: last!.id);
              for (var i = 0; i < 200; i++) {
                expect(recent.order([f.b, f.a], '2026-10-14').first, f.a);
              }
            });
          }
          final before = await state(f.root);
          var settings = <String, Object?>{
            'raw': '001',
            'empty': <String>[],
            'zero': 0,
          };
          final backups = BackupStore(
            documents: f.root,
            readSettings: () async => Map.of(settings),
            writeSettings: (s) async => settings = Map.of(s),
            closeMain: DatabaseHelper().close,
          );
          final watch = Stopwatch()..start();
          final bytes = await backups.snapshot();
          final snapshotMs = watch.elapsedMicroseconds / 1000;
          watch.reset();
          final preview = await backups.prepare(bytes);
          final prepareMs = watch.elapsedMicroseconds / 1000;
          expect(await state(f.root), before);
          watch.reset();
          await backups.apply(preview);
          final applyMs = watch.elapsedMicroseconds / 1000;
          watch.stop();
          expect(await state(f.root), before);
          expect(settings, {'raw': '001', 'empty': <String>[], 'zero': 0});
          if (await backups.recovery.exists()) {
            await backups.recovery.delete(recursive: true);
          }
          reports.add({
            'records': count,
            'revision_seed': count == 343 ? 1050 : 6000,
            'complete_recovery': {
              'bytes': bytes.length,
              'snapshot_ms': snapshotMs,
              'prepare_ms': prepareMs,
              'apply_ms': applyMs,
              'all_tables_settings_equal': true,
            },
            'segments': {
              for (final e in durations.entries)
                e.key: {
                  'cold_ms': e.value.first / 1000,
                  'p50_ms': ([...e.value.skip(1)]..sort())[4] / 1000,
                  'p95_ms': ([...e.value.skip(1)]..sort())[9] / 1000,
                  'read_sql_first': queries[e.key]!.first,
                  'read_sql_last': queries[e.key]!.last,
                },
            },
          });
        } finally {
          await f.close();
        }
      }
      await File(
        output,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
      // Printed values are measurements on synthetic host data, not S25 evidence.
      // ignore: avoid_print
      print(jsonEncode(reports));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
