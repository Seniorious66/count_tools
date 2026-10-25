import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/member_statistics.dart';
import 'package:count_tools/cheki/data/spending_query.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'backup_test.dart' show contents;
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
  tearDown(() => f.close());
  Future<void> link({bool aActive = true, bool bActive = true}) async {
    final p = await f.identities.createPerson(
      name: '内部同人名',
      operationId: 'person',
    );
    for (final pair in [(f.a, aActive), (f.b, bActive)]) {
      final m = await f.member(pair.$1);
      await f.identities.editMember(
        original: m,
        name: m.name,
        colorRgb: m.colorRgb,
        personId: p.id,
        active: pair.$2,
        operationId: 'link-${m.id}',
      );
    }
  }

  final all = BiPeriod(BiScope.all, '2026-10-14');
  test(
    'linked identities use physical20 denominator while pie remains participation based',
    () async {
      await f.record(3, [f.a]);
      await f.record(2, [f.b]);
      await f.record(15, null);
      await link();
      final before = await contents(f.root);
      final report = (await f.bi.read()).report(all);
      expect(report.summary.knownQuantity, 20);
      expect(report.sortedMembers(person: true).single.quantity, 5);
      expect(report.members[f.a]!.quantity / 20, .15);
      expect(report.members[f.b]!.quantity / 20, .1);
      expect(report.personQuantity, 5);
      expect(report.csv(), contains('person'));
      expect(await contents(f.root), before);
    },
  );
  test(
    'selecting a linked member includes both identities but group intersection stays original',
    () async {
      await f.record(3, [f.a]);
      await f.record(2, [f.b]);
      await link();
      final snap = await f.bi.read();
      final filter = BiRecordFilter(memberId: f.a);
      expect(snap.report(all, filter: filter).summary.knownQuantity, 5);
      expect(snap.report(all, filter: BiRecordFilter(memberId: f.a, exactMember: true)).summary.knownQuantity, 3);
      expect(
        snap
            .report(all, groupId: f.groupA, filter: filter)
            .summary
            .knownQuantity,
        3,
      );
      expect(
        snap
            .report(all, groupId: f.groupB, filter: filter)
            .summary
            .knownQuantity,
        2,
      );
    },
  );
  test(
    'active representative outside selected period wins over recent stopped identity',
    () async {
      await f.record(3, [f.a], day: '2026-10-13');
      await f.record(2, [f.b], day: '2026-09-01');
      await link(aActive: false);
      final snap = await f.bi.read(),
          r = (await f.bi.read()).report(BiPeriod(BiScope.month, '2026-10-01'));
      expect(MemberStatistics(snap.records).representative(f.a), f.b);
      expect(r.sortedMembers(person: true).single.label, '夜航-B');
      expect(r.sortedMembers(person: true).single.memberIds, {f.a, f.b});
    },
  );
  test(
    'stopped group disqualifies representative without changing member flag',
    () async {
      await f.record(1, [f.a], day: '2026-10-13');
      await f.record(1, [f.b]);
      await link();
      final g = (await f.catalog.list(
        CatalogKind.group,
      )).singleWhere((x) => x.id == f.groupA);
      await f.catalog.edit(
        CatalogKind.group,
        original: g,
        name: g.name,
        active: false,
        operationId: 'stop-group',
      );
      final s = await f.bi.read();
      expect(MemberStatistics(s.records).representative(f.a), f.b);
      expect(s.records.members[f.a]!.active, isTrue);
    },
  );
  test(
    'unlinked identical names remain distinct and unlinking reverses aggregation only',
    () async {
      await f.record(3, [f.a]);
      await f.record(2, [f.b]);
      await link();
      final m = await f.member(f.b);
      await f.identities.editMember(
        original: m,
        name: 'A',
        colorRgb: m.colorRgb,
        personId: null,
        active: true,
        operationId: 'unlink',
      );
      final report = (await f.bi.read()).report(all);
      expect(report.sortedMembers(person: true), hasLength(2));
      expect(report.summary.knownQuantity, 5);
    },
  );
  test(
    'multiple active and all stopped fallback is deterministic and read only',
    () async {
      await f.record(3, [f.a], day: '2026-10-13');
      await f.record(2, [f.b], day: '2026-10-01');
      await link();
      expect(
        MemberStatistics((await f.bi.read()).records).representative(f.a),
        f.a,
      );
      for (final id in [f.a, f.b]) {
        final m = await f.member(id);
        await f.identities.editMember(
          original: m,
          name: m.name,
          colorRgb: m.colorRgb,
          personId: m.personId,
          active: false,
          operationId: 'stop-$id',
        );
      }
      final before = await contents(f.root),
          s = MemberStatistics((await f.bi.read()).records);
      expect(s.representative(f.b), f.a);
      expect(s.label(f.a), contains('成员已停用'));
      expect(await contents(f.root), before);
    },
  );
  test(
    'overlapping people each participate100 while actual total stays2',
    () async {
      await f.record(2, [f.a, f.b]);
      final r = (await f.bi.read()).report(all);
      expect(r.summary.knownQuantity, 2);
      expect(r.personQuantity, 4);
      for (final m in r.sortedMembers(person: true)) {
        expect(m.quantity / r.summary.knownQuantity, 1);
      }
    },
  );
  test(
    'linked legacy expenses 240 plus160 retain group ownership and precision',
    () async {
      for (final pair in [(f.a, 3, '240'), (f.b, 2, '160')]) {
        await f.records.save(
          RecordInformation.fromMap({
            'member_ids': [pair.$1],
            'quantity': pair.$2,
            'occurred_on': '2026-10-11',
            'legacy_raw': {'id': 1, 'price': pair.$3},
            'legacy_source': {
              'snapshot': '20261011_102725',
              'application_id': 'com.example.count_tools',
              'mapping': 'S25-user-confirmed-20261013',
            },
          }),
          operationId: 'cost-${pair.$1}',
        );
      }
      await link();
      final s = await f.bi.read(),
          r = SpendingReport(
            await f.bi.read(),
            all,
            filter: BiRecordFilter(memberId: f.a),
          );
      expect(r.total(r.assigned()).known.decimal, '400');
      expect(r.total(r.assigned(group: f.groupA)).known.decimal, '240');
      expect(r.total(r.assigned(member: f.b)).known.decimal, '400');
      final exact = SpendingReport(s, all, filter: BiRecordFilter(memberId: f.a, exactMember: true));
      expect(exact.total(exact.assigned()).known.decimal, '240');
      expect(MemberStatistics(s.records).same(f.a, f.b), isTrue);
    },
  );
  test('shared legacy amount is not copied into each member total', () async {
    await f.records.save(
      RecordInformation.fromMap({
        'member_ids': [f.a, f.b],
        'quantity': 2,
        'occurred_on': '2026-10-11',
        'legacy_raw': {'id': 1, 'price': '375.25'},
        'legacy_source': {
          'snapshot': '20261011_102725',
          'application_id': 'com.example.count_tools',
          'mapping': 'S25-user-confirmed-20261013',
        },
      }),
      operationId: 'shared',
    );
    final r = SpendingReport(await f.bi.read(), all);
    expect(r.assigned(member: f.a), isEmpty);
    expect(r.shared(member: f.a), hasLength(1));
    expect(r.total(r.shared(member: f.a)).known.decimal, '375.25');
    expect(r.total([...r.lines, ...r.lines]).known.decimal, '375.25');
  });
  test(
    'zero and unknown quantities stay readable with no invented denominator',
    () async {
      await f.record(null, [f.a], day: null);
      await f.record(null, [f.b]);
      final r = (await f.bi.read()).report(all);
      expect(r.summary.knownQuantity, 0);
      expect(r.members[f.a]!.unknownRecords, 1);
      expect(r.members[f.b]!.quantity, 0);
      expect(r.members[f.b]!.unknownRecords, 1);
    },
  );
}
