import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/ui/coupon_entry.dart';
import 'package:count_tools/cheki/ui/member_pie.dart';
import 'bi_fixture.dart';

class DelayedAvailability extends EntryStore {
  DelayedAvailability(super.database);
  final pending = <String, Completer<TicketModel>>{};
  @override
  Future<TicketModel> availability({String? recordId, String? day}) =>
      pending[day]?.future ?? super.availability(recordId: recordId, day: day);
}

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
  RecordInformation info({
    String? day = '2026-10-14',
    String? size = 'size-3inch',
    String? kind = 'signed',
    List<String>? members,
    int q = 1,
  }) => RecordInformation.fromMap({
    'occurred_on': day,
    'size_id': size,
    'quantity': q,
    'member_ids': members ?? [f.a],
    'attributes': {'kind': kind},
  });
  Future<String> definition({
    String? size = 'size-3inch',
    String? kind = 'signed',
    String scope = 'personal',
    String? member,
    int stock = 10,
    String day = '2026-10-10',
    String? expiry,
  }) async {
    final d = await f.tickets.save(
      kind: 'definition',
      information: TicketInformation({
        'active': true,
        'scope': scope,
        'group_id': f.groupA,
        if (scope == 'personal') 'member_id': member ?? f.a,
        'size_id': size,
        'signature': kind,
      }),
      operationId: 'def-${f.n++}',
    );
    if (stock > 0) await f.buy(d.id, stock, day: day, expiry: expiry);
    return d.id;
  }

  CouponEntryController controller({EntryStore? store, String? recordId}) =>
      CouponEntryController(
        store: store ?? EntryStore(f.records.database),
        initialMode: 'consume',
        recordId: recordId,
      );

  test(
    'raw share threshold and readable geometry keep small sectors without promoting rounded percentages',
    () {
      for (final quantity in [49, 50, 51]) {
        final slices = [
          MemberPieSlice('small', 'A', quantity, 0, Colors.white),
          MemberPieSlice('rest', 'B', 1000 - quantity, 0, Colors.black),
        ];
        // An unusually large surface removes the separate space limitation,
        // exposing the raw 5% eligibility boundary rather than rounded text.
        final labels = layoutPieLabels(
          slices,
          1000,
          4000,
          TextScaler.noScaling,
          TextDirection.ltr,
          Colors.white,
        );
        expect(labels.any((l) => l.slice.id == 'small'), quantity >= 50);
        for (final l in labels) {
          l.painter.dispose();
        }
      }
      expect(biShareLabel(49, 1000), '4.9%');
    },
  );

  test(
    'two members share one small group pool without duplicate promises and clearing a manual date does not erase pools',
    () async {
      final other = await f.identities.createMember(
        name: 'C',
        groupId: f.groupA,
        operationId: 'c',
      );
      final group = await definition(scope: 'group', stock: 1);
      final c = controller();
      await c.load(info(members: [f.a, other.id]));
      expect(c.lines[0]['definition_id'], group);
      expect(c.lines[1]['definition_id'], isNull);
      expect(
        c.lines
            .expand(CouponPlan.pools)
            .fold(0, (q, p) => q + (p['quantity'] as int)),
        1,
      );
      c.selectDefinition(0, group);
      c.editPool(0, 0, '1');
      final pinned = jsonEncode(c.lines[0]);
      await c.sync(info(day: null, members: [f.a, other.id]));
      expect(jsonEncode(c.lines[0]), pinned);
      c.dispose();
    },
  );

  test(
    'initial slow load uses latest form day and historical plan retains missing NULL and extension facts',
    () async {
      await definition();
      final slow = DelayedAvailability(f.records.database),
          c = controller(store: slow);
      slow.pending['2026-10-11'] = Completer<TicketModel>();
      final loading = c.load(info(day: '2026-10-11'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await c.sync(info(day: '2026-10-12', q: 3));
      slow.pending['2026-10-11']!.complete(
        await f.tickets.readModel(day: '2026-10-11'),
      );
      await loading;
      expect(c.model!.day, '2026-10-12');
      expect(c.lines.single['quantity'], 3);
      c.dispose();
      final store = EntryStore(f.records.database);
      final plan = CouponPlan({
        'mode': null,
        'lines': null,
        'ext': {
          'unknown': [null, '原文'],
        },
      });
      final r = await store.save(
        RecordInformation.fromMap({
          'ext': {'old': null},
        }),
        plan: plan,
        operationId: 'historical',
      );
      final edit = controller(recordId: r.id);
      await edit.load(r.information);
      await edit.sync(info(size: f.five));
      expect(edit.plan.toMap(), plan.toMap());
      edit.dispose();
      expect((await f.records.list()).single.toRow(), r.toRow());
    },
  );

  test(
    '5000-row recency index is built once; 200 reference-date sorts never reread storage',
    () async {
      final db = await f.records.database();
      await db.transaction((tx) async {
        final batch = tx.batch();
        for (var i = 0; i < 5000; i++) {
          batch.insert(RecordSchema.records, {
            'id': 'scale-$i',
            'revision': 1,
            'created_at': '2026-10-14T01:00:00.000Z',
            'updated_at': '2026-10-14T01:00:00.000Z',
            'information_json': jsonEncode({
              'member_ids': [i % 2 == 0 ? f.a : f.b],
              'occurred_on':
                  '2026-10-${(i % 28 + 1).toString().padLeft(2, '0')}',
            }),
          });
        }
        await batch.commit(noResult: true);
      });
      final read = Stopwatch()..start();
      final rows = await f.records.list();
      read.stop();
      final build = Stopwatch()..start();
      final index = MemberRecency(rows);
      build.stop();
      final order = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        expect(index.order([f.a, f.b], '2026-10-14'), hasLength(2));
      }
      order.stop();
      // Broad guard catches accidental IO/full-history reconstruction in typing.
      expect(order.elapsedMilliseconds, lessThan(2000));
      // Evidence is timing only, without personal records or content digests.
      debugPrint(
        'PFE synthetic5000 read=${read.elapsedMicroseconds / 1000}ms index=${build.elapsedMicroseconds / 1000}ms sort200=${order.elapsedMicroseconds / 1000}ms',
      );
    },
  );

  test(
    'circular color placement reaches theoretical minimum for all four-color populations through five each',
    () {
      for (var a = 0; a <= 5; a++) {
        for (var b = 0; b <= 5; b++) {
          for (var c = 0; c <= 5; c++) {
            for (var d = 0; d <= 5; d++) {
              final counts = [a, b, c, d], original = <MemberPieSlice>[];
              for (var color = 0; color < counts.length; color++) {
                for (var i = 0; i < counts[color]; i++) {
                  original.add(
                    MemberPieSlice(
                      '$color-$i',
                      '团体-成员$i',
                      i + 1,
                      0,
                      Color(0xff000000 | color),
                    ),
                  );
                }
              }
              final ordered = arrangePieSlices(original.reversed.toList());
              expect(
                ordered.map((s) => s.id).toSet(),
                original.map((s) => s.id).toSet(),
              );
              expect(
                ordered.map((s) => s.id),
                arrangePieSlices(original).map((s) => s.id),
              );
              if (ordered.length < 2) continue;
              final adjacent = List.generate(
                ordered.length,
                (i) =>
                    ordered[i].color == ordered[(i + 1) % ordered.length].color,
              ).where((same) => same).length;
              expect(
                adjacent,
                math.max(0, 2 * counts.reduce(math.max) - ordered.length),
                reason: '$counts',
              );
            }
          }
        }
      }
      expect(
        arrangePieSlices([const MemberPieSlice('u', '未知', 0, 1, Colors.red)]),
        isEmpty,
      );
    },
  );

  test(
    'reference-day recency excludes future undated and editing-self without merging identities',
    () async {
      await f.record(1, [f.a], day: '2026-10-05');
      await f.record(1, [f.a], day: '2026-10-20');
      final self = await f.record(1, [f.a], day: '2026-10-10');
      await f.record(1, [f.b], day: '2026-10-09');
      await f.record(1, [f.a], day: null);
      final index = MemberRecency(await f.records.list(), excluding: self.id);
      expect(index.order([f.a, f.b, 'missing'], '2026-10-10'), [
        f.b,
        f.a,
        'missing',
      ]);
      expect(index.order([f.a, f.b], '2026-10-06'), [f.a, f.b]);
      expect(index.order([f.a, f.b], null), [f.a, f.b]);
      expect(index.latest(f.a, '2026-10-01'), isNull);
    },
  );

  test(
    'already selected size and signature precede personal priority, multiple defaults are stable',
    () async {
      final personal3 = await definition();
      final group5 = await definition(size: f.five, scope: 'group');
      await definition(size: f.five, kind: 'unsigned');
      final c = controller();
      await c.load(info(size: f.five));
      expect(c.lines.single['definition_id'], group5);
      await c.sync(info());
      expect(c.lines.single['definition_id'], personal3);
      final another = await definition();
      await c.load(info());
      expect(
        c.lines.single['definition_id'],
        ([personal3, another]..sort()).first,
      );
      c.dispose();
    },
  );

  test(
    'unset size prefers personal scope then three over five without filling the record',
    () async {
      await definition(size: f.five, scope: 'group');
      final five = await definition(size: f.five);
      final c = controller();
      await c.load(info(size: null));
      expect(c.lines.single['definition_id'], five);
      final three = await definition();
      await c.load(info(size: null));
      expect(c.lines.single['definition_id'], three);
      expect(c.info.sizeId, isNull);
      c.dispose();
    },
  );

  test(
    'zero expired future and unknown-group definitions cannot become inventory defaults',
    () async {
      await definition(stock: 0);
      await definition(expiry: '2026-10-13');
      await definition(day: '2026-10-15');
      final c = controller();
      await c.load(info());
      expect(c.lines.single['definition_id'], isNull);
      final known = await definition(stock: 1);
      await c.load(info(q: 2));
      expect(c.lines.single['definition_id'], known);
      expect(CouponPlan.pools(c.lines.single).single['quantity'], 1);
      await expectLater(c.checked(info(q: 2)), throwsA(isA<Exception>()));
      await c.sync(info(day: null));
      expect(c.lines.single['definition_id'], isNull);
      c.dispose();
    },
  );

  test(
    'manual clear and pool/quantity overrides survive while untouched members get fresh suggestions',
    () async {
      final other = await f.identities.createMember(
        name: 'C',
        groupId: f.groupA,
        operationId: 'c',
      );
      final group = await definition(scope: 'group');
      final five = await definition(size: f.five, scope: 'group');
      final c = controller();
      await c.load(info(members: [f.a, other.id]));
      expect(c.lines.every((l) => l['definition_id'] == group), isTrue);
      c.selectDefinition(0, null);
      await c.sync(info(size: f.five, members: [f.a, other.id]));
      expect(c.lines[0]['definition_id'], isNull);
      expect(c.lines[1]['definition_id'], five);
      c.editQuantity(1, '7');
      c.editPool(1, 0, '2');
      final manual = jsonEncode(c.lines[1]);
      await c.sync(info(day: '2026-10-13', members: [f.a, other.id]));
      expect(jsonEncode(c.lines[1]), manual);
      c.restoreAutomatic();
      expect(c.lines[0]['definition_id'], group);
      c.dispose();
    },
  );

  test(
    'personal positive shortage keeps priority; shared stock is never promised twice or consumed by a suggestion',
    () async {
      final other = await f.identities.createMember(
        name: 'C',
        groupId: f.groupA,
        operationId: 'c',
      );
      final personal = await definition(stock: 1);
      final group = await definition(scope: 'group', stock: 1);
      final before = await (await f.records.database()).query(
        TicketSchema.objects,
      );
      final c = controller();
      await c.load(info(q: 2, members: [f.a, other.id]));
      expect(c.lines[0]['definition_id'], personal);
      expect(c.lines[1]['definition_id'], group);
      expect(
        c.lines
            .expand(CouponPlan.pools)
            .fold(0, (q, p) => q + (p['quantity'] as int)),
        2,
      );
      await c.sync(info(q: 1, members: [other.id, f.a]));
      expect(c.lines[0]['definition_id'], group);
      expect(c.lines[1]['definition_id'], personal);
      expect(
        await (await f.records.database()).query(TicketSchema.objects),
        before,
      );
      c.dispose();
    },
  );

  test(
    'out-of-order date reads cannot overwrite newer inputs and loading does not accept stale inventory',
    () async {
      await definition();
      final slow = DelayedAvailability(f.records.database),
          c = controller(store: slow);
      await c.load(info());
      slow.pending['2026-10-11'] = Completer<TicketModel>();
      slow.pending['2026-10-12'] = Completer<TicketModel>();
      final first = c.sync(info(day: '2026-10-11'));
      final last = c.sync(info(day: '2026-10-12', q: 2));
      slow.pending['2026-10-12']!.complete(
        await f.tickets.readModel(day: '2026-10-12'),
      );
      await last;
      slow.pending['2026-10-11']!.complete(
        await f.tickets.readModel(day: '2026-10-11'),
      );
      await first;
      expect(c.model!.day, '2026-10-12');
      expect(c.lines.single['quantity'], 2);
      c.dispose();
    },
  );

  test(
    'library sorts available not expired future or draft; immutable snapshot and management order survive',
    () async {
      final low = await definition(stock: 3),
          high = await definition(stock: 20);
      final expired = await definition(stock: 50, expiry: '2026-10-13');
      final future = await definition(stock: 80, day: '2026-10-15');
      await f.tickets.save(
        kind: 'purchase',
        information: TicketInformation({
          'definition_id': expired,
          'quantity': 200,
        }),
        operationId: 'draft',
      );
      final m = await f.tickets.readModel(day: '2026-10-14');
      final original = m.definitions.map((d) => d.id).toList();
      expect(m.stockOrderedDefinitions.map((d) => d.id), [
        high,
        low,
        ...([expired, future]..sort()),
      ]);
      expect(m.definitions.map((d) => d.id), original);
      expect(
        (await f.tickets.readModel(
          day: '2026-10-15',
        )).stockOrderedDefinitions.first.id,
        future,
      );
    },
  );
}
