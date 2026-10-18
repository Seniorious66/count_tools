import 'dart:convert';
import 'dart:io';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'bi_fixture.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late BiFixture f;
  setUp(() async {
    f = BiFixture();
    await f.open();
  });
  tearDown(() async => f.close());
  test(
    'all five periods move with Monday week, leap and cross-year boundaries',
    () {
      final day = BiPeriod(BiScope.day, '2024-02-29');
      expect(day.move(1).anchor, '2024-03-01');
      final week = BiPeriod(BiScope.week, '2021-01-01');
      expect(week.from, '2020-12-28');
      expect(week.through, '2021-01-03');
      expect(week.move(1).from, '2021-01-04');
      final month = BiPeriod(BiScope.month, '2024-02-29');
      expect(month.through, '2024-02-29');
      expect(month.move(1).from, '2024-03-01');
      expect(
        BiPeriod(BiScope.year, '2024-10-14').move(-1).through,
        '2023-12-31',
      );
      expect(BiPeriod(BiScope.all, '2026-10-14').contains(null), true);
      expect(month.contains(null), false);
    },
  );
  test(
    'physical 7 participation 9; cross-group filter changes denominator without copying joint record',
    () async {
      await f.quantities();
      final s = await f.bi.read(),
          r = s.report(BiPeriod(BiScope.month, '2026-10-14'));
      expect(r.summary.knownQuantity, 7);
      expect(r.memberQuantity, 9);
      expect(r.members[f.a]!.quantity, 5);
      expect(r.members[f.b]!.quantity, 4);
      expect(r.signatures, {'signed': 3, 'unsigned': 2, 'homework': 2});
      expect(r.receipts, {'unreceived': 3, 'received': 2, 'partial': 2});
      expect(r.summary.knownReceivedQuantity, 3);
      expect(r.summary.knownAwaitingQuantity, 4);
      final group = s.report(r.period, groupId: f.groupA);
      expect(group.summary.knownQuantity, 5);
      expect(group.memberQuantity, 5);
      expect(group.members.keys, [f.a]);
      expect(r.sortedMembers().first.colorRgb, 0x123456);
      expect(r.memberRows({f.a}, day: '2026-10-11').length, 2);
      expect(r.csv(), contains('"member","${f.a}","晨星-A","","5","9"'));
    },
  );
  test(
    'only manual same-person links aggregate across identities; unlinked nulls stay separate',
    () async {
      final person = await f.identities.createPerson(
        name: '同一个A',
        operationId: 'person',
      );
      var a = await f.member(f.a);
      a = await f.identities.editMember(
        original: a,
        name: a.name,
        colorRgb: a.colorRgb,
        personId: person.id,
        active: true,
        operationId: 'link',
      );
      final next = await f.identities.transferMember(
        original: a,
        groupId: f.groupB,
        name: '新A',
        operationId: 'transfer',
      );
      await f.record(120, [f.a]);
      await f.record(80, [next.id]);
      await f.record(2, [f.b]);
      final r = (await f.bi.read()).report(BiPeriod(BiScope.all, '2026-10-14'));
      expect(r.people['person:${person.id}']!.quantity, 200);
      expect(r.members.length, 3);
      expect(r.people.length, 2);
      expect(r.personQuantity, 202);
      expect(
        r.memberRows(r.people['person:${person.id}']!.memberIds).length,
        2,
      );
    },
  );
  test(
    'unknown date quantity attributes and receipt stay distinct; all-empty JSON remains unchanged',
    () async {
      final empty = await f.records.save(
        RecordInformation.fromMap({
          'ext': {'missing': null, 'raw': '001'},
        }),
        operationId: 'empty',
      );
      await f.record(
        4,
        [f.a],
        day: null,
        signature: null,
        back: null,
        receipt: null,
      );
      await f.record(null, [f.b], signature: null, back: null, receipt: null);
      final all = (await f.bi.read()).report(
        BiPeriod(BiScope.all, '2026-10-14'),
      );
      expect(all.summary.unknownQuantityRecords, 2);
      expect(all.summary.unknownDateRecords, 2);
      expect(all.summary.knownQuantity, 4);
      expect(all.receipts, {null: 4});
      expect(all.members[f.b]!.quantity, 0);
      expect(all.members[f.b]!.unknownRecords, 1);
      expect(all.csv(), contains('"member","${f.b}","夜航-B","","","4"'));
      final month = (await f.bi.read()).report(
        BiPeriod(BiScope.month, '2026-10-14'),
      );
      expect(month.summary.quantityLabel, '未填写');
      expect(month.rows.length, 1);
      expect(
        (await f.records.list())
            .singleWhere((r) => r.id == empty.id)
            .information
            .encode(),
        empty.information.encode(),
      );
    },
  );
  test(
    'event date changes move quantities, receipt edits do not; colours rename reload from same snapshot',
    () async {
      final row = await f.record(
        2,
        [f.a],
        back: true,
        receipt: [
          {
            'quantity': 1,
            'origin': 'actual',
            'received_at': '2026-10-12T01:00:00.000Z',
          },
        ],
      );
      final updated = await f.records.save(
        row.information.patch({'occurred_on': '2026-09-30'}),
        operationId: 'date-edit',
        original: row,
      );
      var r = (await f.bi.read()).report(BiPeriod(BiScope.month, '2026-10-14'));
      expect(r.rows, isEmpty);
      await f.records.save(
        updated.information.patch({
          'receipt_batches': [
            {
              'quantity': 2,
              'origin': 'actual',
              'received_at': '2026-11-12T01:00:00.000Z',
            },
          ],
        }),
        operationId: 'receipt-edit',
        original: updated,
      );
      final a = await f.member(f.a);
      await f.identities.editMember(
        original: a,
        name: 'A改名',
        colorRgb: 0xabcdef,
        personId: null,
        active: true,
        operationId: 'color',
      );
      r = (await f.bi.read()).report(BiPeriod(BiScope.month, '2026-09-30'));
      expect(r.summary.knownQuantity, 2);
      expect(r.backSigned, 2);
      expect(r.members[f.a]!.colorRgb, 0xabcdef);
      expect(r.members[f.a]!.label, '晨星-A改名');
      expect(r.rows.single.createdAt, row.createdAt);
    },
  );
  test(
    'purchase100 gift30 exchange30 consume30 stock40; period flows and cutoff inventory reconcile',
    () async {
      await f.finances();
      final s = await f.bi.read();
      final before = s.report(BiPeriod(BiScope.day, '2026-10-10'));
      expect(before.purchase.known.exact, '100');
      expect(before.stocks[f.source]!.available, 4);
      expect(before.stocks[f.source]!.cost.known.exact, '100');
      final gift = s.report(BiPeriod(BiScope.day, '2026-10-11'));
      expect(gift.purchase.known.exact, '0');
      expect(gift.flows['赠送']!.cost.label, '30');
      expect(gift.stocks[f.source]!.cost.label, '70');
      final exchange = s.report(BiPeriod(BiScope.day, '2026-10-12'));
      expect(exchange.flows['交换入']!.cost.label, '30');
      expect(exchange.flows['交换出']!.cost.label, '30');
      expect(exchange.stocks[f.target]!.cost.label, '30');
      expect(exchange.purchase.knownQuantity, 0);
      final r = s.report(BiPeriod(BiScope.all, '2026-10-14'));
      expect(r.purchase.known.exact, '100');
      expect(r.purchase.average, '25');
      expect(r.flows['拍切消耗']!.cost.label, '30');
      expect(r.stocks[f.source]!.cost.label, '40');
      expect(r.summary.knownQuantity, 1);
      expect(r.consumedRecordCost.label, '30');
      expect(
        r.csv(),
        contains('"stock","${f.source}","晨星","2026-10-14","2","","40"'),
      );
      await StorageSchema.validate(await f.records.database(), 8);
    },
  );
  test(
    'exact ratios, unknown costs, expired quantity, future flows and all cutoff are not rounded or invented',
    () async {
      await f.finances(unknown: true, future: true);
      await f.buy(f.source, 3, total: '10', day: '2026-10-14');
      final r = (await f.bi.read()).report(BiPeriod(BiScope.all, '2026-10-14'));
      expect(r.purchase.known.exact, '116');
      expect(r.purchase.unknownQuantity, 2);
      expect(r.purchase.average, '15');
      expect(r.purchase.known.divided(r.purchase.knownQuantity).exact, '29/2');
      expect(r.stocks[f.source]!.available, 5);
      expect(r.stocks[f.source]!.expired, 2);
      expect(r.stocks[f.source]!.cost.known.exact, '50');
      expect(r.stocks[f.source]!.cost.unknownQuantity, 2);
      final group = (await f.bi.read()).report(
        BiPeriod(BiScope.all, '2026-10-14'),
        groupId: f.groupB,
      );
      expect(group.purchase.known.exact, '0');
      expect(group.flows['拍切消耗']!.quantity, 1);
    },
  );
  test(
    'CSV RFC4180 quotes raw original text, neutralises formulas and uses same filters as report',
    () async {
      final a = await f.member(f.a);
      await f.identities.editMember(
        original: a,
        name: '=A,"换行\n成员"',
        colorRgb: a.colorRgb,
        personId: null,
        active: true,
        operationId: 'name-formula',
      );
      await f.record(3, [f.a]);
      await f.record(9, [f.b], day: '2026-09-30');
      final r = (await f.bi.read()).report(
            BiPeriod(BiScope.month, '2026-10-14'),
            groupId: f.groupA,
          ),
          csv = r.csv();
      expect(csv, startsWith('\ufeff"section"'));
      expect(csv, contains('"summary","physical","张数","","3"'));
      expect(csv, contains('""换行'));
      expect(csv, contains('ext'));
      expect(csv, contains('\\n'));
      expect(csv, isNot(contains('"9","9"')));
      final label = r.members[f.a]!.label;
      expect(label, contains('=A'));
      expect(jsonDecode(r.rows.single.information.encode())['ext'], {
        '原文': [null, '=保留,\n"原文"'],
      });
    },
  );
  test(
    'R1 synthetic fixture day7 week14 month15 year21 all24 and empty period',
    () async {
      await f.quantities();
      await f.record(7, [f.a], day: '2026-10-06');
      await f.record(1, [f.b], day: '2026-10-12');
      await f.record(4, [f.a], day: '2026-09-30');
      await f.record(2, [f.b], day: '2026-01-01');
      await f.record(3, [f.a], day: '2025-10-11');
      final source = await f.bi.read();
      expect(
        [
          for (final scope in BiScope.values)
            source.report(BiPeriod(scope, '2026-10-11')).summary.knownQuantity,
        ],
        [7, 14, 15, 21, 24],
      );
      expect(
        source
            .report(BiPeriod(BiScope.day, '2026-10-14'))
            .summary
            .quantityLabel,
        '0',
      );
      expect(
        source
            .report(BiPeriod(BiScope.all, '2026-10-14'))
            .summary
            .knownQuantity,
        24,
      );
    },
  );
  test(
    'optional saved S25 copy BI is read-only, retains342 raw rows and legacy effective colours',
    () async {
      final path = Platform.environment['COUNT_TOOLS_BI_READONLY'];
      if (path == null) return;
      final db = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      try {
        final before = jsonEncode(await db.query('cheki_members'));
        final records = jsonEncode(await db.query('cheki_records'));
        final source = await BiStore(
          () async => db,
          clock: () => DateTime.utc(2026, 10, 14),
        ).read();
        final report = source.report(BiPeriod(BiScope.all, '2026-10-14'));
        expect(report.rows.length, 342);
        expect(report.summary.knownQuantity, 342);
        expect(
          source.records.members.values.where((m) => m.colorRgb != null).length,
          25,
        );
        expect(jsonEncode(await db.query('cheki_members')), before);
        expect(jsonEncode(await db.query('cheki_records')), records);
      } finally {
        await db.close();
      }
    },
  );
  test(
    'dimensions share filters and CSV; member denominator excludes non-selected identities',
    () async {
      await f.quantities();
      final source = await f.bi.read(),
          period = BiPeriod(BiScope.month, '2026-10-14');
      final a = source.report(period, filter: BiRecordFilter(memberId: f.a));
      expect(a.summary.knownQuantity, 5);
      expect(a.memberQuantity, 5);
      expect(a.members.keys, [f.a]);
      expect(a.members[f.a]!.bySize, {f.three: 5});
      final unsigned = source.report(
        period,
        filter: BiRecordFilter(
          signature: 'unsigned',
          sizeId: f.five,
          receipt: 'received',
        ),
      );
      expect(unsigned.summary.knownQuantity, 2);
      expect(unsigned.members.keys, [f.b]);
      expect(unsigned.csv(), contains('"physical","张数","","2"'));
      expect(
        source
            .report(period, filter: const BiRecordFilter(backSigned: true))
            .rows,
        isEmpty,
      );
      await f.record(1, [f.a], signature: null, back: null, receipt: null);
      final unknown = (await f.bi.read()).report(
        period,
        filter: const BiRecordFilter(
          signature: '@unknown',
          receipt: '@unknown',
        ),
      );
      expect(unknown.summary.knownQuantity, 1);
      expect(unknown.signatures, {null: 1});
      expect(
        (await f.bi.read())
            .report(period, filter: const BiRecordFilter(unknownBack: true))
            .summary
            .knownQuantity,
        1,
      );
    },
  );
  test(
    'inventory expiry pools reminder and per-definition purchases agree with CSV',
    () async {
      await f.finances();
      await f.buy(f.source, 2, unit: '7', expiry: '2026-10-20');
      final r = (await f.bi.read()).report(BiPeriod(BiScope.all, '2026-10-14'));
      expect(r.purchases[f.source]!.known.exact, '114');
      expect(r.purchases[f.source]!.knownQuantity, 6);
      final stock = r.stocks[f.source]!;
      expect(stock.longAvailable, 2);
      expect(stock.datedAvailable, 2);
      expect(stock.nearExpiry, 2);
      expect(stock.available, 4);
      expect(stock.cost.label, '54');
      expect(r.csv(), contains('near_expiry'));
      expect(r.csv(), contains('"purchase_definition"'));
    },
  );
}
