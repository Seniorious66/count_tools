import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/spending_query.dart';
import 'package:count_tools/cheki/data/transfer_store.dart';
import 'package:count_tools/cheki/ui/bi_page.dart';
import 'package:count_tools/cheki/ui/expiry_date_input.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/ui/transfer_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'bi_fixture.dart';
import 'support/settle_io.dart';

Finder key(String id) => find.byKey(ValueKey(id));

Future<void> host(WidgetTester t, Widget page, {double width = 320}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = Size(width, 960);
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: page,
    ),
  );
  await settleIo(t);
}

Future<void> reach(WidgetTester t, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await t.scrollUntilVisible(
      finder,
      140,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await t.ensureVisible(finder);
  await settleIo(t);
}

Future<void> enter(WidgetTester t, String id, String value) async {
  final field = key(id);
  await reach(t, field);
  await t.enterText(field, value);
  await settleIo(t);
}

Future<void> choose(WidgetTester t, String id, String value) async {
  await reach(t, key(id));
  await t.tap(key(id));
  await settleIo(t);
  await t.tap(find.text(value).last);
  await settleIo(t);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  test(
    'short expiry strictly checks calendar and preserves legacy centuries',
    () {
      expect(parseExpiryInput('261231'), '2026-12-31');
      expect(parseExpiryInput('280229'), '2028-02-29');
      expect(parseExpiryInput('000101'), '2000-01-01');
      for (final invalid in [
        '260229',
        '261332',
        '2612310',
        '26123',
        '26-12-31',
        '261231\n',
        ' 261231',
        '2612-1',
      ]) {
        expect(
          () => parseExpiryInput(invalid),
          throwsFormatException,
          reason: invalid,
        );
      }
      expect(expiryInputText('2026-12-31'), '261231');
      expect(expiryInputText('2100-12-31'), '2100-12-31');
      expect(
        parseExpiryInput('2100-12-31', original: '2100-12-31'),
        '2100-12-31',
      );
      expect(() => parseExpiryInput('2100-12-31'), throwsFormatException);
      expect(parseExpiryInput('', original: '2100-12-31'), isNull);
      expect(parseExpiryInput(''), isNull);
    },
  );

  group('isolated ledger', () {
    late BiFixture f;
    setUp(() async {
      f = BiFixture();
      await f.open();
    });
    tearDown(() => f.close());

    for (final kind in ['purchase', 'adjustment']) {
      testWidgets('$kind accepts six digits and stores one ISO expiry', (
        t,
      ) async {
        await t.runAsync(f.finances);
        await host(
          t,
          TicketEditPage(store: f.tickets, kind: kind, definitionId: f.source),
        );
        if (kind == 'adjustment') {
          await enter(t, 'ticket-occurred_on', '2026-10-14');
        }
        await enter(t, 'ticket-quantity', '2');
        await choose(
          t,
          'ticket-pool-${kind == 'purchase' ? 'long' : 'null'}',
          '限时券',
        );
        if (kind == 'adjustment') {
          await enter(t, 'ticket-expires_on', '260229');
          await reach(t, find.text('计入库存'));
          await t.tap(find.text('计入库存'));
          await settleIo(t);
        } else {
          await enter(t, 'ticket-expires_on', '260229');
        }
        await t.tap(find.text('核对'));
        await settleIo(t);
        expect(find.text('截止日不是有效日期，请检查月份和日'), findsOneWidget);
        expect(find.text('确认保存'), findsNothing);
        await enter(t, 'ticket-expires_on', '261231');
        await t.tap(find.text('核对'));
        await settleIo(t);
        expect(find.textContaining('2026-12-31'), findsOneWidget);
        await t.tap(find.text('确认保存'));
        await settleIo(t);
        final m = (await t.runAsync(f.tickets.readModel))!;
        final saved = m.objects.singleWhere(
          (e) => e.kind == kind && e.information.expiry == '2026-12-31',
        );
        expect(saved.posted, isTrue);
        expect(
          m
              .pools(f.source)
              .singleWhere((p) => p.expiry == '2026-12-31')
              .quantity,
          2,
        );
        await t.pumpWidget(const SizedBox());
      });
    }

    testWidgets(
      'editing an ISO expiry reads short and keeps inventory and expiry on unrelated save',
      (t) async {
        final original = (await t.runAsync(() async {
          await f.finances();
          return f.buy(f.source, 2, expiry: '2026-12-31', total: '50');
        }))!;
        await host(
          t,
          TicketEditPage(
            store: f.tickets,
            kind: 'purchase',
            original: original,
          ),
        );
        await reach(t, key('ticket-expires_on'));
        expect(
          t.widget<TextField>(key('ticket-expires_on')).controller!.text,
          '261231',
        );
        await enter(t, 'ticket-note', '只改备注');
        await t.tap(find.text('核对'));
        await settleIo(t);
        await t.tap(find.text('确认保存'));
        await settleIo(t);
        final m = (await t.runAsync(f.tickets.readModel))!;
        final saved = m.objects.singleWhere((e) => e.id == original.id);
        expect(saved.information.toMap(), {
          ...original.information.toMap(),
          'note': '只改备注',
        });
        expect(
          m
              .pools(f.source)
              .singleWhere((p) => p.expiry == '2026-12-31')
              .quantity,
          2,
        );
        await t.pumpWidget(const SizedBox());
      },
    );

    for (final kind in ['gift', 'exchange']) {
      testWidgets(
        '$kind uses ISO for source matching and reviewed destinations',
        (t) async {
          await t.runAsync(() async {
            await f.finances();
            await f.buy(f.source, 2, expiry: '2026-12-31', unit: '25');
          });
          final store = TransferStore(f.records.database, clock: () => f.clock);
          await host(
            t,
            TransferEditPage(
              store: store,
              sourceDefinition: f.source,
              kind: kind,
            ),
            width: 430,
          );
          final source = key('transfer-source-expiry');
          await reach(t, source);
          expect(t.widget<TextField>(source).controller!.text, '261231');
          expect(
            t.widget<TextField>(source).keyboardType,
            TextInputType.number,
          );
          await enter(t, 'transfer-source-expiry', '261332');
          await t.tap(find.text('核对并入账'));
          await settleIo(t);
          expect(find.text('来源截止日不是有效日期，请检查月份和日'), findsOneWidget);
          await enter(t, 'transfer-source-expiry', '261231');
          expect(find.textContaining('还差'), findsNothing);
          if (kind == 'exchange') {
            await reach(t, key('transfer-target-null'));
            await t.tap(key('transfer-target-null'));
            await settleIo(t);
            await t.tap(find.textContaining('夜航').last);
            await settleIo(t);
            await choose(t, 'transfer-target-pool-long', '指定期限');
            await enter(t, 'transfer-target-expiry', '280229');
          }
          await t.tap(find.text('核对并入账'));
          await settleIo(t);
          expect(find.text('换送核对'), findsOneWidget);
          expect(find.text('2026-12-31'), findsOneWidget);
          if (kind == 'exchange') {
            expect(find.text('2028-02-29'), findsOneWidget);
          }
          await t.tap(find.text('确认保存'));
          await settleIo(t);
          final saved = (await t.runAsync(store.list))!.singleWhere(
            (e) => e.information.text('source_expires_on') == '2026-12-31',
          );
          expect(saved.posted, isTrue);
          expect(
            saved.information.text('target_expires_on'),
            kind == 'exchange' ? '2028-02-29' : null,
          );
          final m = (await t.runAsync(f.tickets.readModel))!;
          expect(
            m
                .pools(f.source)
                .singleWhere((p) => p.expiry == '2026-12-31')
                .quantity,
            1,
          );
          if (kind == 'exchange') {
            expect(
              m
                  .pools(f.target)
                  .singleWhere((p) => p.expiry == '2028-02-29')
                  .quantity,
              1,
            );
          }
          await t.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets(
      'natural week drives UI, report, member rows, spending and CSV at both edges',
      (t) async {
        final snapshot = (await t.runAsync(() async {
          for (final (q, day) in [
            (10, '2026-11-01'),
            (2, '2026-11-02'),
            (3, '2026-11-08'),
            (20, '2026-11-09'),
            (30, null),
          ]) {
            await f.record(q, [f.a], day: day);
          }
          return f.bi.read();
        }))!;
        final period = BiPeriod(BiScope.week, '2026-11-07');
        final report = snapshot.report(period);
        final days = ['2026-11-02', '2026-11-08'];
        expect(report.summary.knownQuantity, 5);
        expect(
          report.memberRows({f.a}).map((r) => r.information.occurredOn!.value),
          unorderedEquals(days),
        );
        final spending = SpendingReport(snapshot, period);
        expect(spending.lines.map((l) => l.day), unorderedEquals(days));
        expect(report.csv(), contains('"summary","physical","张数","","5"'));
        expect(report.csv(), isNot(contains('2026-11-09')));
        expect(spending.csv(spending.lines), isNot(contains('2026-11-01')));
        expect(BiPeriod(BiScope.week, '2026-11-08').label, period.label);
        expect(
          BiPeriod(BiScope.week, '2026-11-09').label,
          '2026-11-09 — 2026-11-15',
        );
        await host(
          t,
          Scaffold(
            body: BiPage(
              store: f.bi,
              records: f.records,
              initialPeriod: period,
            ),
          ),
        );
        expect(find.text('2026-11-02 — 2026-11-08'), findsOneWidget);
        await t.tap(find.byTooltip('下一周'));
        await settleIo(t);
        expect(find.text('2026-11-09 — 2026-11-15'), findsOneWidget);
        await t.tap(find.byTooltip('上一周'));
        await settleIo(t);
        expect(find.text(period.label), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      },
    );
  });
}
