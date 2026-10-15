import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/ui/app_shell.dart';
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
  late RecordStore store;
  late CatalogStore catalog;
  late IdentityStore identities;
  late String a, b, three, five;
  var clock = DateTime.utc(2026, 10, 12, 1);
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-query-');
    final path = '${scratch.path}/query.sqlite';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () async => path;
    clock = DateTime.utc(2026, 10, 12, 1);
    store = RecordStore(() => DatabaseHelper().database, clock: () => clock);
    catalog = CatalogStore(store.database, clock: () => clock);
    identities = IdentityStore(store.database, clock: () => clock);
    final group = await catalog.create(
      CatalogKind.group,
      name: '晨星',
      operationId: 'group',
    );
    a = (await identities.createMember(
      name: 'A',
      groupId: group.id,
      colorRgb: 0x90bfff,
      operationId: 'a',
    )).id;
    b = (await identities.createMember(
      name: 'B',
      groupId: group.id,
      colorRgb: 0xef98b6,
      operationId: 'b',
    )).id;
    final sizes = await catalog.list(CatalogKind.size);
    three = sizes.singleWhere((s) => s.name == '三寸').id;
    five = sizes.singleWhere((s) => s.name == '五寸').id;
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  Future<List<StoredRecord>> fixture() async => [
    await store.save(
      RecordInformation.fromMap({
        'occurred_on': '2026-10-11',
        'quantity': 3,
        'member_ids': [a],
        'size_id': three,
        'receipt_batches': [],
        'attributes': {'kind': 'signed', 'back_signed': false},
      }),
      operationId: 'a3',
    ),
    await store.save(
      RecordInformation.fromMap({
        'occurred_on': '2026-10-11',
        'quantity': 2,
        'member_ids': [b],
        'size_id': five,
        'receipt_batches': [
          {'quantity': 2, 'origin': 'initial', 'received_at': null},
        ],
        'attributes': {'kind': 'unsigned'},
      }),
      operationId: 'b2',
    ),
    await store.save(
      RecordInformation.fromMap({
        'occurred_on': '2026-10-11',
        'quantity': 2,
        'member_ids': [a, b],
        'size_id': three,
        'receipt_batches': [
          {
            'quantity': 1,
            'origin': 'actual',
            'received_at': '2026-10-12T01:00:00.123456Z',
          },
        ],
        'attributes': {'kind': 'homework'},
      }),
      operationId: 'ab2',
    ),
  ];
  test(
    'actual persisted A3 B2 AB2 reconciles 7/9, sizes and repeat daily rows after cold reopen',
    () async {
      final original = await fixture();
      await DatabaseHelper().close();
      var m = await store.readModel();
      final total = m.summarize(RecordFilter());
      expect(total.knownQuantity, 7);
      expect(total.memberQuantity, 9);
      expect(total.byMember, {a: 5, b: 4});
      expect(total.bySize, {three: 5, five: 2});
      expect(total.knownReceivedQuantity, 3);
      expect(total.knownAwaitingQuantity, 4);
      expect(m.days(RecordFilter()).single.day, '2026-10-11');
      expect(
        m.days(RecordFilter()).single.records.map((r) => r.id).toSet(),
        original.map((r) => r.id).toSet(),
      );
      final filtered = m.summarize(
        RecordFilter(
          memberId: a,
          sizeId: three,
          from: '2026-10-11',
          through: '2026-10-11',
        ),
      );
      expect(filtered.knownQuantity, 5);
      expect(filtered.memberQuantity, 5);
      await store.save(
        RecordInformation.fromMap({
          'occurred_on': '2026-10-11',
          'quantity': 2,
          'member_ids': [b],
          'size_id': five,
        }),
        operationId: 'b-extra',
      );
      m = await store.readModel();
      expect(
        m.summarize(RecordFilter(memberId: b, sizeId: five)).knownQuantity,
        4,
      );
      expect(
        m.days(RecordFilter(memberId: b, sizeId: five)).single.records.length,
        2,
      );
      expect((await store.list()).length, 4);
      for (final (id, size, quantity) in [
        ('a-three-first', three, 2),
        ('a-three-second', three, 2),
        ('a-five', five, 1),
      ]) {
        await store.save(
          RecordInformation.fromMap({
            'occurred_on': '2026-10-12',
            'quantity': quantity,
            'member_ids': [a],
            'size_id': size,
          }),
          operationId: id,
        );
      }
      m = await store.readModel();
      final aDay = m.summarize(
        RecordFilter(memberId: a, from: '2026-10-12', through: '2026-10-12'),
      );
      expect(aDay.bySize, {three: 4, five: 1});
      expect(aDay.memberQuantity, 5);
      expect(
        m
            .days(
              RecordFilter(
                memberId: a,
                sizeId: three,
                from: '2026-10-12',
                through: '2026-10-12',
              ),
            )
            .single
            .records
            .length,
        2,
      );
    },
  );
  test(
    'editing occurrence moves old/new days and month; actual receipt changes only receipt, not action or event day',
    () async {
      final original = (await fixture()).last;
      clock = clock.add(const Duration(hours: 1));
      final moved = await store.save(
        original.information.patch({'occurred_on': '2026-09-30'}),
        original: original,
        operationId: 'move',
      );
      var m = await store.readModel();
      final month = m.month(OccurredOn.parse('2026-10-12'));
      expect(m.summarize(month).knownQuantity, 5);
      expect(
        m
            .summarize(RecordFilter(from: '2026-09-30', through: '2026-09-30'))
            .knownQuantity,
        2,
      );
      expect(m.days(RecordFilter()).map((d) => d.day), [
        '2026-10-11',
        '2026-09-30',
      ]);
      final received = await store.save(
        moved.information.patch({
          'receipt_batches': [
            ...moved.information.toMap()['receipt_batches'] as List,
            {
              'quantity': 1,
              'origin': 'actual',
              'received_at': '2026-11-01T00:00:00.000Z',
            },
          ],
        }),
        original: moved,
        operationId: 'receive',
      );
      expect(received.createdAt, original.createdAt);
      expect(received.information.occurredOn?.value, '2026-09-30');
      await DatabaseHelper().close();
      m = await store.readModel();
      expect(m.summarize(month).knownQuantity, 5);
      expect(m.summarize(RecordFilter()).knownQuantity, 7);
      expect(m.summarize(RecordFilter()).knownAwaitingQuantity, 3);
      expect(m.summarize(RecordFilter()).memberQuantity, 9);
    },
  );
  test(
    'partial information contributes to each known metric and never to guessed dates receipt or participants',
    () async {
      for (final (id, data) in <(String, Map<String, Object?>)>[
        ('no-date', {'quantity': 4, 'size_id': three}),
        (
          'no-q',
          {
            'occurred_on': '2026-10-11',
            'member_ids': [a],
            'size_id': five,
            'receipt_status_hint': 'received',
          },
        ),
        (
          'no-status',
          {
            'quantity': 2,
            'occurred_on': '2026-10-11',
            'member_ids': [a],
          },
        ),
        (
          'legacy',
          {
            'legacy_raw': {'date': '旧原文', 'id': 91, 'ext': null},
          },
        ),
      ]) {
        await store.save(RecordInformation.fromMap(data), operationId: id);
      }
      final before = (await store.list()).map((r) => r.toRow()).toList();
      var m = await store.readModel();
      final all = m.summarize(RecordFilter());
      expect(all.knownQuantity, 6);
      expect(all.memberQuantity, 2);
      expect(all.bySize, {three: 4});
      expect(all.unknownQuantityRecords, 2);
      expect(all.unknownDateRecords, 2);
      expect(all.unknownReceiptRecords, 3);
      expect(all.unknownReceiptQuantityRecords, 4);
      final month = m.summarize(m.month(OccurredOn.parse('2026-10-12')));
      expect(month.knownQuantity, 2);
      expect(month.unknownQuantityRecords, 1);
      expect(
        m.select(RecordFilter(selection: RecordSelection.awaitingReceipt)),
        isEmpty,
      );
      expect(
        m
            .summarize(RecordFilter(selection: RecordSelection.undated))
            .knownQuantity,
        4,
      );
      expect(m.days(RecordFilter()).last.day, isNull);
      expect((await store.list()).map((r) => r.toRow()).toList(), before);
      final legacy = m.records.singleWhere(
        (r) => r.information.toMap().containsKey('legacy_raw'),
      );
      expect(RecordSummary([legacy]).quantityLabel, '未填写');
      expect(RecordSummary([legacy]).memberQuantityLabel, '未填写');
      await store.save(
        legacy.information.patch({'quantity': 3}),
        original: legacy,
        operationId: 'fill-q',
      );
      m = await store.readModel();
      expect(m.summarize(RecordFilter()).knownQuantity, 9);
      expect(
        m.summarize(m.month(OccurredOn.parse('2026-10-12'))).knownQuantity,
        2,
      );
    },
  );
  test(
    'filters bind identity and size IDs, include inactive historical records, and handle leap/year ranges',
    () async {
      await fixture();
      final other = await identities.createMember(
        name: 'A',
        operationId: 'same-name',
      );
      final extra = await store.save(
        RecordInformation.fromMap({
          'member_ids': [other.id],
          'occurred_on': '2024-02-29',
          'quantity': 4,
        }),
        operationId: 'leap',
      );
      final originalA = (await identities.list(
        IdentityKind.member,
      )).singleWhere((i) => i.id == a);
      await identities.editMember(
        original: originalA,
        name: '新A',
        colorRgb: 0x123456,
        personId: null,
        active: false,
        operationId: 'stop-a',
      );
      final m = await store.readModel();
      expect(m.memberLabel(a), '晨星-新A');
      expect(m.members[a]?.colorRgb, 0x123456);
      expect(m.summarize(RecordFilter(memberId: a)).knownQuantity, 5);
      expect(m.summarize(RecordFilter(memberId: other.id)).knownQuantity, 4);
      expect(
        m
            .select(RecordFilter(from: '2024-02-29', through: '2024-02-29'))
            .single
            .id,
        extra.id,
      );
      expect(m.month(OccurredOn.parse('2024-02-29')).through, '2024-02-29');
      expect(m.month(OccurredOn.parse('2026-12-30')).through, '2026-12-31');
      expect(
        () => RecordFilter(from: '2026-10-12', through: '2026-10-11'),
        throwsArgumentError,
      );
    },
  );
  test(
    'successful writes notify readers only after the atomic result; failed writes do not invalidate as success',
    () async {
      var notifications = 0;
      final subscription = RecordStore.changes.listen((_) => notifications++);
      try {
        final bad = RecordStore(
          store.database,
          afterWrite: () async => throw StateError('fault'),
        );
        await expectLater(
          bad.save(RecordInformation.fromMap({}), operationId: 'fault'),
          throwsStateError,
        );
        await Future<void>.delayed(Duration.zero);
        expect(notifications, 0);
        expect((await store.readModel()).records, isEmpty);
        final saved = await store.save(
          RecordInformation.fromMap({'quantity': 1}),
          operationId: 'okay',
        );
        await Future<void>.delayed(Duration.zero);
        expect(notifications, 1);
        expect((await store.readModel()).records.single.id, saved.id);
      } finally {
        await subscription.cancel();
      }
    },
  );

  testWidgets(
    'actual home month/pending and record filters/detail edit refresh and preserve original creation',
    (tester) async {
      final rows = (await tester.runAsync(fixture))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: Scaffold(body: RecordHomePage(store: store)),
        ),
      );
      await settleIo(tester);
      expect(find.text('7 张'), findsOneWidget);
      expect(find.text('4 张'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-pending')));
      await settleIo(tester);
      expect(find.text('5 张'), findsOneWidget);
      expect(find.byKey(ValueKey('record-${rows[1].id}')), findsNothing);
      await tester.tap(find.text('全部').first);
      await settleIo(tester);
      expect(find.text('7 张'), findsOneWidget);
      expect(find.text('成员张数 9'), findsOneWidget);
      await tester.tap(find.widgetWithText(ActionChip, '筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('晨星-A').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用'));
      await settleIo(tester);
      expect(find.text('5 张'), findsOneWidget);
      expect(find.text('成员张数 5'), findsOneWidget);
      final tile = find.byKey(ValueKey('record-${rows[2].id}'));
      await tester.scrollUntilVisible(
        tile,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(tile);
      await settleIo(tester);
      expect(find.text('记录详情'), findsOneWidget);
      expect(find.textContaining('背签：'), findsNothing);
      expect(find.textContaining('2026-10-12 09:00:00'), findsWidgets);
      await tester.ensureVisible(find.text('修改记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改记录'));
      await settleIo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('record-day')),
        '2026-09-30',
      );
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      expect(find.text('修改前：2026-10-11'), findsOneWidget);
      expect(find.text('修改后：2026-09-30'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.byType(RecordDetailPage), findsNothing);
      final updated = (await tester.runAsync(
        store.list,
      ))!.singleWhere((r) => r.id == rows[2].id);
      expect(updated.createdAt, rows[2].createdAt);
      expect(updated.information.occurredOn!.value, '2026-09-30');
      await tester.binding.handlePopRoute();
      await settleIo(tester);
      expect(find.text('5 张'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'failed read retries without a fabricated empty result; unknown date filter and cancellation retain facts',
    (tester) async {
      final blank = await tester.runAsync(
        () => store.save(RecordInformation.fromMap({}), operationId: 'blank'),
      );
      var unavailable = true;
      final retryStore = RecordStore(() async {
        if (unavailable) throw StateError('synthetic unavailable');
        return store.database();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: RecordListPage(store: retryStore),
        ),
      );
      await settleIo(tester);
      expect(find.text('读取失败，点击重试'), findsOneWidget);
      expect(find.text('0 张'), findsNothing);
      unavailable = false;
      await tester.tap(find.text('读取失败，点击重试'));
      await settleIo(tester);
      expect(find.text('未填写 张'), findsOneWidget);
      expect(find.text('无日期'), findsNothing);
      expect(find.byKey(ValueKey('record-${blank!.id}')), findsOneWidget);
      await tester.tap(find.widgetWithText(ActionChip, '筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
            .selected,
        isTrue,
      );
      expect(
        (await tester.runAsync(store.list))!.single.information.toMap(),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'actual root has home/records plus legacy management and stays usable at 320/430 and 200 percent',
    (tester) async {
      await tester.runAsync(fixture);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final width in [320.0, 430.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const ChekiAppShell(),
          ),
        );
        await settleIo(tester);
        expect(
          find.byKey(const ValueKey('home-month')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text('券库'), findsWidgets);
        expect(find.text('统计'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.notes));
        await settleIo(tester);
        expect(find.text('7 张'), findsOneWidget);
        await tester.tap(find.byTooltip('打开管理'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('旧版项目'));
        await settleIo(tester);
        expect(find.text('合成项目'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  final evidence = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  testWidgets(
    'editing only a note keeps missing keys NULL empty values and unknown nested attributes exactly',
    (tester) async {
      final raw = <String, Object?>{
        'attributes': {
          'kind': null,
          'back_signed': null,
          'opaque': [null, '原文'],
        },
        'member_ids': <String>[],
        'receipt_batches': null,
        'note': '',
        'legacy_raw': {'id': 9, 'ext': null, 'price': '25.00'},
      };
      final original = await tester.runAsync(
        () => store.save(RecordInformation.fromMap(raw), operationId: 'raw'),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: RecordEditPage(store: store, original: original),
        ),
      );
      await settleIo(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('record-note')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byKey(const ValueKey('record-note')), '后补备注');
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      expect(find.text('修改前：'), findsOneWidget);
      expect(find.text('修改后：后补备注'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final saved = (await tester.runAsync(store.list))!.single;
      expect(saved.information.toMap(), {...raw, 'note': '后补备注'});
      expect(saved.createdAt, original!.createdAt);
      expect(saved.id, original.id);
      await tester.pumpWidget(const SizedBox());
    },
  );
  if (evidence != null) {
    testWidgets('optional actual record home list and detail visual evidence', (
      tester,
    ) async {
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        final root = Directory(evidence).absolute;
        expect(root.path.startsWith(Directory.current.absolute.path), isFalse);
        expect(File('${root.path}/.cheki-ui-evidence').existsSync(), isTrue);
        for (final (family, path) in [
          ('RecordBrowsePreview', Platform.environment['COUNT_TOOLS_UI_FONT']),
          ('MaterialIcons', Platform.environment['COUNT_TOOLS_UI_ICON_FONT']),
        ]) {
          if (path != null) {
            final loader = FontLoader(family)
              ..addFont(
                Future.value(
                  ByteData.sublistView(File(path).readAsBytesSync()),
                ),
              );
            await loader.load();
          }
        }
        final rows = (await tester.runAsync(fixture))!;
        await tester.runAsync(
          () => store.save(
            rows.first.information.patch({'quantity': 1}),
            operationId: 'visual-repeat',
          ),
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        for (final (name, width, page) in <(String, double, Widget)>[
          (
            'home',
            320,
            Scaffold(
              appBar: AppBar(title: const Text('首页')),
              body: RecordHomePage(store: store),
            ),
          ),
          ('list', 430, RecordListPage(store: store)),
          ('detail', 320, RecordDetailPage(store: store, record: rows.last)),
        ]) {
          tester.view.physicalSize = Size(width, 900);
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: chekiTheme().copyWith(
                appBarTheme: chekiTheme().appBarTheme.copyWith(
                  titleTextStyle: chekiTheme().appBarTheme.titleTextStyle!
                      .copyWith(fontFamily: 'RecordBrowsePreview'),
                ),
                textTheme: chekiTheme().textTheme.apply(
                  fontFamily: 'RecordBrowsePreview',
                ),
              ),
              home: RepaintBoundary(key: key, child: page),
            ),
          );
          await settleIo(tester);
          await tester.runAsync(() async {
            final pic =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final bytes = await pic.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File(
                '${root.path}/record-browse-$name-${width.toInt()}.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
            } finally {
              pic.dispose();
            }
          });
          await tester.pumpWidget(const SizedBox());
        }
      } finally {
        debugDisableShadows = previousShadows;
      }
    });
  }
}
