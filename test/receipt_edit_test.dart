import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/ui/receipt_edit.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;
import 'catalog_pages_test.dart' show settleIo;

void main() {
  late Directory scratch;
  late String path;
  late RecordStore store;
  var clock = DateTime.utc(2026, 10, 12, 1);
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-receipts-');
    path = '${scratch.path}/receipt.sqlite';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () async => path;
    clock = DateTime.utc(2026, 10, 12, 1);
    store = RecordStore(() => DatabaseHelper().database, clock: () => clock);
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  RecordInformation multi() => RecordInformation.fromMap({
    'occurred_on': '2026-10-11',
    'quantity': 4,
    'receipt_batches': [
      {
        'quantity': 1,
        'origin': 'actual',
        'received_at': '2026-10-12T01:00:00.123456Z',
        'opaque': {
          'values': [null, '原文'],
        },
      },
      {
        'quantity': 2,
        'received_at': '2026-10-12T02:00:00.654321Z',
        'ext': null,
      },
    ],
    'legacy_raw': {
      'id': 91,
      'date': '2024-01-02 13:14:15',
      'price': '25.00',
      'ext': null,
    },
  });
  test(
    'individual batch correction retains every other fact timestamp precision and missing origin',
    () {
      final original = multi();
      final editor = ReceiptEditController(original, clock: () => clock);
      addTearDown(editor.dispose);
      editor.change(editor.entries.first, quantity: '2');
      final completed = original.patch(editor.patch(4));
      expect(completed.receiptStatus, ReceiptStatus.received);
      expect(completed.receivedQuantity, 4);
      final before = original.toMap()['receipt_batches'] as List;
      final after = completed.toMap()['receipt_batches'] as List;
      expect(after[1], before[1]);
      expect((after[0] as Map)['received_at'], '2026-10-12T01:00:00.123456Z');
      expect((after[0] as Map)['opaque'], (before[0] as Map)['opaque']);
      expect(completed.toMap()['legacy_raw'], original.toMap()['legacy_raw']);
      editor.remove(editor.entries.first);
      final remaining = original.patch(editor.patch(4));
      expect(remaining.receivedQuantity, 2);
      expect(remaining.receiptStatus, ReceiptStatus.partial);
      expect(remaining.toMap()['receipt_batches'], [before[1]]);
    },
  );
  test(
    'status clear and return keeps batch input; all unknown fields remain unknown and can be completed',
    () {
      final original = multi();
      final editor = ReceiptEditController(original, clock: () => clock);
      addTearDown(editor.dispose);
      editor.select(ReceiptStatus.unreceived);
      expect(original.patch(editor.patch(4)).receivedQuantity, 0);
      editor.select(ReceiptStatus.partial);
      expect(
        original.patch(editor.patch(4)).toMap()['receipt_batches'],
        original.toMap()['receipt_batches'],
      );
      editor.clear();
      expect(original.patch(editor.patch(4)).receivedQuantity, isNull);
      final unknown = ReceiptEditController(
        RecordInformation.fromMap({}),
        clock: () => clock,
      );
      addTearDown(unknown.dispose);
      unknown.updateTotal(5);
      expect(unknown.patch(5), isEmpty);
      expect(unknown.selected, isNull);
      expect(unknown.patch(null), isEmpty);
      unknown.add();
      unknown.change(
        unknown.entries.single,
        time: '',
        origin: null,
        changeOrigin: true,
      );
      final info = RecordInformation.fromMap({}).patch(unknown.patch(null));
      expect(info.quantity, isNull);
      expect(info.receivedQuantity, isNull);
      expect(info.receiptStatus, isNull);
      expect((info.toMap()['receipt_batches'] as List).single, {
        'quantity': null,
        'origin': null,
        'received_at': null,
      });
    },
  );
  test(
    'initial whole shortcut does not fabricate time or fill an originally unknown receipt count',
    () {
      final original = RecordInformation.fromMap({
        'quantity': 1,
        'receipt_batches': [
          {'quantity': 1, 'origin': 'initial', 'opaque': null},
        ],
      });
      final editor = ReceiptEditController(original, clock: () => clock);
      addTearDown(editor.dispose);
      editor.updateTotal(3);
      final changed = original.patch({'quantity': 3, ...editor.patch(3)});
      expect(changed.receivedQuantity, 3);
      expect((changed.toMap()['receipt_batches'] as List).single, {
        'quantity': 3,
        'origin': 'initial',
        'opaque': null,
      });
      editor.updateTotal(null);
      expect(
        original.patch({'quantity': null, ...editor.patch(null)}).receiptStatus,
        ReceiptStatus.received,
      );
      final unknown = RecordInformation.fromMap({
        'receipt_batches': [
          {'origin': 'initial', 'quantity': null},
        ],
      });
      final u = ReceiptEditController(unknown, clock: () => clock);
      addTearDown(u.dispose);
      u.updateTotal(3);
      expect(
        unknown.patch({'quantity': 3, ...u.patch(3)}).receivedQuantity,
        isNull,
      );
      expect(
        unknown.patch({'quantity': 3, ...u.patch(3)}).receiptStatus,
        ReceiptStatus.received,
      );
      editor.select(ReceiptStatus.partial);
      editor.select(ReceiptStatus.received);
      expect(editor.shortcut, isTrue);
      editor.updateTotal(1);
      editor.exposeInitial(actualTime: true);
      editor.change(editor.entries.single, time: '2026-10-12 11:00:00');
      expect(
        (original.patch(editor.patch(1)).toMap()['receipt_batches'] as List)
            .single,
        {
          'quantity': 1,
          'origin': 'actual',
          'received_at': '2026-10-12T03:00:00.000Z',
          'opaque': null,
        },
      );
    },
  );
  test(
    'filled invalid quantities dates and incompatible initial source reject, including partial known sums',
    () {
      final original = multi();
      final e = ReceiptEditController(original, clock: () => clock);
      addTearDown(e.dispose);
      e.change(e.entries.first, quantity: '3');
      expect(() => original.patch(e.patch(4)), throwsFormatException);
      e.change(e.entries.first, quantity: '1', time: '2026-10-10 10:00:00');
      expect(() => original.patch(e.patch(4)), throwsFormatException);
      e.change(e.entries.first, time: '2026-10-12 24:00:00');
      expect(() => e.patch(4), throwsFormatException);
      expect(
        () => RecordInformation.fromMap({
          'quantity': null,
          'receipt_status_hint': 'partial',
          'receipt_batches': [
            {'origin': 'initial', 'quantity': null},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => RecordInformation.fromMap({
          'quantity': 2,
          'receipt_batches': [
            {'quantity': 3},
            {'quantity': null},
          ],
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'actual added receipt defaults its own time, removes cleanly and never moves occurrence or creation',
    () async {
      final original = await store.save(
        RecordInformation.fromMap({
          'occurred_on': '2026-10-11',
          'quantity': 3,
          'receipt_batches': [],
        }),
        operationId: 'new',
      );
      final e = ReceiptEditController(original.information, clock: () => clock);
      addTearDown(e.dispose);
      e.add();
      e.change(e.entries.single, quantity: '1');
      var changed = await store.save(
        original.information.patch(e.patch(3)),
        original: original,
        operationId: 'first',
      );
      expect(changed.information.receiptStatus, ReceiptStatus.partial);
      clock = DateTime.utc(2026, 10, 13, 2);
      final second = ReceiptEditController(
        changed.information,
        clock: () => clock,
      );
      addTearDown(second.dispose);
      second.add();
      second.change(second.entries.last, quantity: '2');
      changed = await store.save(
        changed.information.patch(second.patch(3)),
        original: changed,
        operationId: 'second',
      );
      expect(changed.createdAt, original.createdAt);
      expect(changed.information.receiptStatus, ReceiptStatus.received);
      expect((changed.information.toMap()['receipt_batches'] as List).last, {
        'quantity': 2,
        'origin': 'actual',
        'received_at': '2026-10-13T02:00:00.000Z',
      });
      await DatabaseHelper().close();
      final m = await store.readModel();
      expect(m.summarize(RecordFilter()).knownQuantity, 3);
      expect(m.days(RecordFilter()).single.day, '2026-10-11');
      expect(m.summarize(RecordFilter()).knownAwaitingQuantity, 0);
    },
  );
  Future<void> openEdit(WidgetTester tester, StoredRecord r) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: chekiTheme(),
        home: RecordListPage(store: store),
      ),
    );
    await settleIo(tester);
    await tester.tap(find.byKey(ValueKey('record-${r.id}')));
    await settleIo(tester);
    await tester.ensureVisible(find.text('修改记录'));
    await tester.tap(find.text('修改记录'));
    await settleIo(tester);
  }

  test(
    'joint A/B two-card receipts share one quantity and do not duplicate member or daily totals',
    () async {
      final group = await CatalogStore(
        store.database,
      ).create(CatalogKind.group, name: '合成团体', operationId: 'joint-group');
      final identities = IdentityStore(store.database);
      final a = await identities.createMember(
        name: 'A',
        groupId: group.id,
        operationId: 'joint-a',
      );
      final b = await identities.createMember(
        name: 'B',
        groupId: group.id,
        operationId: 'joint-b',
      );
      var r = await store.save(
        RecordInformation.fromMap({
          'occurred_on': '2026-10-11',
          'quantity': 2,
          'member_ids': [a.id, b.id],
          'receipt_batches': [],
        }),
        operationId: 'joint',
      );
      final first = ReceiptEditController(r.information, clock: () => clock);
      first.add();
      first.change(first.entries.single, quantity: '1');
      r = await store.save(
        r.information.patch(first.patch(2)),
        original: r,
        operationId: 'joint-first',
      );
      first.dispose();
      var m = await store.readModel();
      expect(m.summarize(RecordFilter()).knownReceivedQuantity, 1);
      expect(m.summarize(RecordFilter()).knownAwaitingQuantity, 1);
      final second = ReceiptEditController(r.information, clock: () => clock);
      second.add();
      second.change(second.entries.last, quantity: '1');
      r = await store.save(
        r.information.patch(second.patch(2)),
        original: r,
        operationId: 'joint-second',
      );
      second.dispose();
      m = await store.readModel();
      final total = m.summarize(RecordFilter());
      expect(total.knownQuantity, 2);
      expect(total.memberQuantity, 4);
      expect(total.byMember, {a.id: 2, b.id: 2});
      expect(total.knownReceivedQuantity, 2);
      expect(total.knownAwaitingQuantity, 0);
      expect(m.days(RecordFilter()).single.records.length, 1);
      expect(r.information.receiptStatus, ReceiptStatus.received);
    },
  );

  Future<void> reach(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Finder lastQuantity() => find.byWidgetPredicate(
    (w) =>
        w is TextField &&
        (w.key is ValueKey<String>) &&
        (w.key as ValueKey<String>).value.startsWith('receipt-quantity-'),
  );
  testWidgets(
    'real multi-batch edit review/back/save and deletion preserve other batches raw original IDs and audit',
    (tester) async {
      final original = (await tester.runAsync(
        () => store.save(multi(), operationId: 'original'),
      ))!;
      await openEdit(tester, original);
      await reach(
        tester,
        find.byKey(const ValueKey('record-received-quantity')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('record-received-quantity')),
        '2',
      );
      await reach(tester, lastQuantity());
      await tester.enterText(lastQuantity(), '1');
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      expect(find.text('修改对照'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settleIo(tester);
      await reach(tester, lastQuantity());
      expect(tester.widget<TextField>(lastQuantity()).controller!.text, '1');
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      var saved = (await tester.runAsync(store.list))!.single;
      var batches = saved.information.toMap()['receipt_batches'] as List;
      expect((batches[0] as Map)['received_at'], '2026-10-12T01:00:00.123456Z');
      expect((batches[1] as Map)['received_at'], '2026-10-12T02:00:00.654321Z');
      expect((batches[1] as Map).containsKey('origin'), isFalse);
      expect(saved.id, original.id);
      expect(saved.createdAt, original.createdAt);
      await tester.ensureVisible(find.text('修改记录'));
      await tester.tap(find.text('修改记录'));
      await settleIo(tester);
      final delete = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == '删除第1次领取',
      );
      await reach(tester, delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      saved = (await tester.runAsync(store.list))!.single;
      batches = saved.information.toMap()['receipt_batches'] as List;
      expect(batches.length, 1);
      expect((batches.single as Map)['quantity'], 1);
      expect((await tester.runAsync(() => store.history(saved)))!.length, 3);
      expect(saved.information.quantity, 4);
      expect(saved.information.occurredOn?.value, '2026-10-11');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'detail receipt entry records two actual receipts to completion and preserves aggregate/date on cold reopen',
    (tester) async {
      final original = (await tester.runAsync(
        () => store.save(
          RecordInformation.fromMap({
            'occurred_on': '2026-10-11',
            'quantity': 3,
            'receipt_batches': [],
          }),
          operationId: 'unreceived',
        ),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: RecordDetailPage(store: store, record: original),
        ),
      );
      await settleIo(tester);
      await tester.tap(find.text('补领'));
      await settleIo(tester);
      await reach(
        tester,
        find.byKey(const ValueKey('record-received-quantity')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('record-received-quantity')),
        '1',
      );
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      clock = DateTime.utc(2026, 10, 13, 2);
      await tester.ensureVisible(find.text('补领'));
      await tester.tap(find.text('补领'));
      await settleIo(tester);
      await reach(tester, lastQuantity());
      await tester.enterText(lastQuantity(), '2');
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.text('领取：已领取'), findsOneWidget);
      final saved = (await tester.runAsync(store.list))!.single;
      expect(saved.information.receivedQuantity, 3);
      expect(saved.createdAt, original.createdAt);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => DatabaseHelper().close());
      final m = (await tester.runAsync(store.readModel))!;
      expect(m.days(RecordFilter()).single.day, '2026-10-11');
      expect(m.summarize(RecordFilter()).knownQuantity, 3);
      expect(m.summarize(RecordFilter()).knownAwaitingQuantity, 0);
    },
  );
  testWidgets(
    '320/430 at 200 percent and keyboard keep batch validation review and dirty cancellation reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.reset);
      for (final width in [320.0, 430.0]) {
        tester.view.physicalSize = Size(width, 960);
        final original = await tester.runAsync(
          () => store.save(multi(), operationId: 'large-${width.toInt()}'),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Builder(
              builder: (context) {
                return Scaffold(
                  body: TextButton(
                    onPressed: () {
                      Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              RecordEditPage(store: store, original: original),
                        ),
                      );
                    },
                    child: const Text('打开编辑'),
                  ),
                );
              },
            ),
          ),
        );
        await tester.tap(find.text('打开编辑'));
        await settleIo(tester);
        await reach(
          tester,
          find.byKey(const ValueKey('record-received-quantity')),
        );
        await tester.enterText(
          find.byKey(const ValueKey('record-received-quantity')),
          '5',
        );
        await tester.tap(find.text('核对'));
        await tester.pumpAndSettle();
        expect(find.text('领取张数超过总张数').hitTestable(), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.tap(find.text('放弃'));
        await tester.pumpAndSettle();
        expect(find.text('打开编辑'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  final export = Platform.environment['COUNT_TOOLS_RECEIPT_ACCEPTANCE'];
  if (export != null) {
    test(
      'optional actual receipt records complete-store export for independent recovery',
      () async {
        final root = Directory(export).absolute;
        expect(root.path.startsWith(Directory.current.absolute.path), isFalse);
        final marker =
            jsonDecode(
                  File(
                    '${root.path}/.receipt-acceptance.json',
                  ).readAsStringSync(),
                )
                as Map;
        expect(marker['purpose'], 'm1-synthetic-receipts');
        expect(marker['project'], 'count_tools');
        for (final file in [
          'database.sqlite',
          'preferences.json',
          'synthetic-attachment',
        ]) {
          expect(File('${root.path}/$file').existsSync(), isFalse);
        }
        await CatalogStore(
          store.database,
        ).create(CatalogKind.group, name: '合成', operationId: 'group');
        await store.save(RecordInformation.fromMap({}), operationId: 'blank');
        final r = await store.save(multi(), operationId: 'multi');
        final e = ReceiptEditController(r.information, clock: () => clock);
        e.change(e.entries.first, quantity: '2');
        await store.save(
          r.information.patch(e.patch(4)),
          original: r,
          operationId: 'complete',
        );
        e.dispose();
        await store.save(
          RecordInformation.fromMap({
            'receipt_batches': [
              {
                'quantity': null,
                'received_at': '2026-10-12T03:00:00.123456Z',
                'opaque': null,
              },
            ],
          }),
          operationId: 'unknown',
        );
        await DatabaseHelper().close();
        File(path).copySync('${root.path}/database.sqlite');
        File('${root.path}/preferences.json').writeAsStringSync(
          jsonEncode({
            'themeColor': '原值',
            'unknownSetting': ['原文', '保留'],
            'isNotFirstEnter': true,
          }),
        );
        File('${root.path}/synthetic-attachment').writeAsBytesSync([0, 1, 255]);
      },
    );
  }
  final evidence = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  if (evidence != null) {
    testWidgets('optional actual multi-receipt form visual evidence', (
      tester,
    ) async {
      final root = Directory(evidence);
      expect(File('${root.path}/.cheki-ui-evidence').existsSync(), isTrue);
      for (final (family, path) in [
        ('ReceiptPreview', Platform.environment['COUNT_TOOLS_UI_FONT']),
        ('MaterialIcons', Platform.environment['COUNT_TOOLS_UI_ICON_FONT']),
      ]) {
        if (path != null) {
          final loader = FontLoader(family)
            ..addFont(
              Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
            );
          await loader.load();
        }
      }
      final r = await tester.runAsync(
        () => store.save(multi(), operationId: 'visual'),
      );
      tester.view.physicalSize = const Size(320, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme().copyWith(
            textTheme: chekiTheme().textTheme.apply(
              fontFamily: 'ReceiptPreview',
            ),
            appBarTheme: chekiTheme().appBarTheme.copyWith(
              titleTextStyle: chekiTheme().appBarTheme.titleTextStyle!.copyWith(
                fontFamily: 'ReceiptPreview',
              ),
            ),
          ),
          home: RepaintBoundary(
            key: key,
            child: RecordEditPage(store: store, original: r),
          ),
        ),
      );
      await settleIo(tester);
      await reach(
        tester,
        find.byKey(const ValueKey('record-received-quantity')),
      );
      await tester.runAsync(() async {
        final pic =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final bytes = await pic.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${root.path}/receipt-multi-320.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
        } finally {
          pic.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
}
