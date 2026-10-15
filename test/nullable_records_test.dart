import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
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
  late IdentityStore identities;
  var clock = DateTime.utc(2030, 1, 1);
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-null-records-');
    path = '${scratch.path}/records.sqlite';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () async => path;
    clock = DateTime.utc(2030, 1, 1);
    store = RecordStore(() => DatabaseHelper().database, clock: () => clock);
    identities = IdentityStore(store.database, clock: () => clock);
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  test(
    'blank and legacy-only records save and cold reopen without invented business information',
    () async {
      final blank = await store.save(
        RecordInformation.fromMap({}),
        operationId: 'blank',
      );
      final raw = {
        'legacy_raw': {
          'id': 91,
          'price': null,
          'date': '2024-01-02 13:14:15',
          'ext': null,
          'future': {
            'values': [null, '原文', 1],
          },
        },
        'note': '原有信息',
      };
      final legacy = await store.save(
        RecordInformation.fromMap(raw),
        operationId: 'legacy',
      );
      expect(blank.information.toMap(), isEmpty);
      expect(legacy.information.toMap(), raw);
      await DatabaseHelper().close();
      final reopened = await store.list();
      expect(reopened.map((r) => r.id), containsAll([blank.id, legacy.id]));
      expect(
        reopened.singleWhere((r) => r.id == legacy.id).information.toMap(),
        raw,
      );
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  test(
    'completion preserves ID creation raw legacy facts history NULL and original independent fields',
    () async {
      final initial = await store.save(
        RecordInformation.fromMap({
          'legacy_raw': {'id': 7, 'ext': null, 'date': '旧原文'},
        }),
        operationId: 'initial',
      );
      clock = clock.add(const Duration(days: 1));
      final updated = await store.save(
        initial.information.patch({'occurred_on': '2026-10-11', 'quantity': 3}),
        original: initial,
        operationId: 'complete',
      );
      expect(updated.id, initial.id);
      expect(updated.createdAt, initial.createdAt);
      expect(updated.updatedAt, isNot(initial.updatedAt));
      expect(updated.information.signature, isNull);
      expect(updated.information.receiptStatus, isNull);
      expect(
        updated.information.toMap()['legacy_raw'],
        initial.information.toMap()['legacy_raw'],
      );
      final h = await store.history(updated);
      expect(h.length, 2);
      expect(
        StoredRecord.fromRow(
          decodeSqlRow(h.last['before_json'] as String),
        ).information.quantity,
        isNull,
      );
      final duplicate = await store.save(
        initial.information,
        operationId: 'initial',
      );
      expect(duplicate.id, initial.id);
      expect((await store.list()).length, 1);
      await expectLater(
        store.save(
          initial.information,
          original: initial,
          operationId: 'stale',
        ),
        throwsA(isA<CatalogException>()),
      );
      final cleared = await store.save(
        updated.information.patch({'quantity': null}),
        original: updated,
        operationId: 'clear',
      );
      expect(cleared.information.quantity, isNull);
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  test(
    'failure rolls back record revision operation and history; retry is idempotent across services',
    () async {
      final faulty = RecordStore(
        store.database,
        afterWrite: () async => throw StateError('synthetic fault'),
      );
      await expectLater(
        faulty.save(RecordInformation.fromMap({}), operationId: 'failed'),
        throwsA(anything),
      );
      for (final table in [
        RecordSchema.records,
        RecordSchema.operations,
        RecordSchema.history,
      ]) {
        expect(await (await store.database()).query(table), isEmpty);
      }
      final saved = await store.save(
        RecordInformation.fromMap({}),
        operationId: 'same',
      );
      expect(
        (await store.save(
          RecordInformation.fromMap({}),
          operationId: 'same',
        )).id,
        saved.id,
      );
      await expectLater(
        identities.createPerson(name: '', operationId: 'same'),
        throwsA(isA<CatalogException>()),
      );
      await expectLater(
        CatalogStore(
          store.database,
        ).create(CatalogKind.group, name: '', operationId: 'same'),
        throwsA(isA<CatalogException>()),
      );
      await expectLater(
        store.save(
          RecordInformation.fromMap({'note': 'different'}),
          operationId: 'same',
        ),
        throwsA(isA<CatalogException>()),
      );
    },
  );
  test(
    'known member references and one Person remain valid even while other record fields are empty',
    () async {
      final p = await identities.createPerson(name: 'P', operationId: 'p');
      final a = await identities.createMember(
        name: 'A',
        personId: p.id,
        operationId: 'a',
      );
      final b = await identities.createMember(name: 'B', operationId: 'b');
      final joint = await store.save(
        RecordInformation.fromMap({
          'member_ids': [a.id, b.id],
        }),
        operationId: 'joint',
      );
      await expectLater(
        identities.editMember(
          original: b,
          name: 'B',
          colorRgb: null,
          personId: p.id,
          active: true,
          operationId: 'link',
        ),
        throwsA(isA<CatalogException>()),
      );
      expect(
        (await identities.list(
          IdentityKind.member,
        )).singleWhere((m) => m.id == b.id).personId,
        isNull,
      );
      await expectLater(
        store.save(
          RecordInformation.fromMap({
            'member_ids': ['missing'],
          }),
          operationId: 'dangling',
        ),
        throwsA(isA<CatalogException>()),
      );
      await expectLater(
        store.save(
          RecordInformation.fromMap({'size_id': 'missing'}),
          operationId: 'missing-size',
        ),
        throwsA(isA<CatalogException>()),
      );
      await store.save(
        joint.information.patch({
          'member_ids': [a.id],
        }),
        original: joint,
        operationId: 'remove-b',
      );
      await identities.editMember(
        original: b,
        name: 'B',
        colorRgb: null,
        personId: p.id,
        active: true,
        operationId: 'link-after-edit',
      );
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  test(
    'quantities and receipt state remain known independently of other missing information',
    () async {
      final records = <StoredRecord>[];
      for (final q in [3, 2, 2]) {
        records.add(
          await store.save(
            RecordInformation.fromMap({'quantity': q}),
            operationId: 'q-${records.length}',
          ),
        );
      }
      records.add(
        await store.save(RecordInformation.fromMap({}), operationId: 'unknown'),
      );
      expect(
        records
            .where((r) => r.information.quantity != null)
            .fold<int>(0, (s, r) => s + r.information.quantity!),
        7,
      );
      expect(records.where((r) => r.information.quantity == null).length, 1);
      final partial = await store.save(
        RecordInformation.fromMap({
          'receipt_status_hint': 'partial',
          'receipt_batches': [
            {
              'quantity': null,
              'origin': null,
              'received_at': '2026-10-12T03:00:00.000Z',
            },
          ],
        }),
        operationId: 'partial',
      );
      expect(partial.information.quantity, isNull);
      expect(partial.information.receivedQuantity, isNull);
      expect(partial.information.receiptStatus, ReceiptStatus.partial);
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  testWidgets(
    'actual home entry saves a fully blank historical record then edits and reopens it',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: Scaffold(body: RecordHomePage(store: store)),
        ),
      );
      await settleIo(tester);
      await tester.tap(find.text('切'));
      await settleIo(tester);
      await clearNewShortcuts(tester);
      for (final key in ['record-day', 'record-quantity']) {
        expect(
          tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text,
          isEmpty,
        );
      }
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      var rows = (await tester.runAsync(store.list))!;
      expect(rows.length, 1);
      expect(rows.single.information.quantity, isNull);
      expect(rows.single.information.signature, isNull);
      expect(rows.single.information.receiptStatus, isNull);
      final id = rows.single.id, created = rows.single.createdAt;
      await tester.tap(find.byKey(ValueKey('record-$id')));
      await settleIo(tester);
      await tester.ensureVisible(find.text('修改记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改记录'));
      await settleIo(tester);
      await tester.enterText(
        find.byKey(const ValueKey('record-day')),
        '2026-10-11',
      );
      await tester.enterText(
        find.byKey(const ValueKey('record-quantity')),
        '3',
      );
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect(find.textContaining('3 张 ·'), findsOneWidget);
      expect(find.text('张数未填写 1 条'), findsNothing);
      rows = (await tester.runAsync(store.list))!;
      expect(rows.single.id, id);
      expect(rows.single.createdAt, created);
      expect(rows.single.information.signature, isNull);
      expect(rows.single.information.receiptStatus, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => DatabaseHelper().close());
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: RecordListPage(store: store),
        ),
      );
      await settleIo(tester);
      expect(find.text('3 张'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'invalid supplied values keep input while blank values and narrow large-font keyboard review remain reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 230);
      addTearDown(() => tester.view.reset());
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(body: RecordHomePage(store: store)),
        ),
      );
      await settleIo(tester);
      await tester.tap(find.text('切'));
      await settleIo(tester);
      await clearNewShortcuts(tester);
      await tester.enterText(
        find.byKey(const ValueKey('record-quantity')),
        '-1',
      );
      await tester.tap(find.text('核对'));
      await tester.pump();
      expect(find.text('已知张数必须为正整数，未知请留空'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('record-quantity')))
            .controller!
            .text,
        '-1',
      );
      await tester.enterText(find.byKey(const ValueKey('record-quantity')), '');
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      expect((await tester.runAsync(store.list))!.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  final evidence = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  testWidgets(
    'adding an actual receipt time to initially untracked received record stores the supplied fact',
    (tester) async {
      final r = await tester.runAsync(
        () => store.save(
          RecordInformation.fromMap({
            'quantity': 3,
            'occurred_on': '2026-10-11',
            'receipt_batches': [
              {
                'quantity': 3,
                'origin': 'initial',
                'received_at': null,
                'opaque': null,
              },
            ],
          }),
          operationId: 'initial',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: RecordListPage(store: store),
        ),
      );
      await settleIo(tester);
      await tester.tap(find.byKey(ValueKey('record-${r!.id}')));
      await settleIo(tester);
      await tester.ensureVisible(find.text('修改记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改记录'));
      await settleIo(tester);
      await tester.scrollUntilVisible(
        find.widgetWithText(TextButton, '补填实际领取时间'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.widgetWithText(TextButton, '补填实际领取时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '补填实际领取时间'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('record-receipt-time')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('record-receipt-time')),
        '2026-10-12 11:00:00',
      );
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final stored = (await tester.runAsync(store.list))!.single;
      final batch =
          (stored.information.toMap()['receipt_batches'] as List).single as Map;
      expect(batch['origin'], 'actual');
      expect(batch['received_at'], '2026-10-12T03:00:00.000Z');
      expect(batch['opaque'], isNull);
      expect(stored.createdAt, r.createdAt);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'editing known partial quantity retains unchanged actual receipt subsecond precision and unknown metadata',
    (tester) async {
      final r = await tester.runAsync(
        () => store.save(
          RecordInformation.fromMap({
            'quantity': 5,
            'occurred_on': '2026-10-11',
            'receipt_batches': [
              {
                'quantity': 1,
                'origin': 'actual',
                'received_at': '2026-10-12T03:00:00.123456Z',
                'opaque': '原值',
              },
            ],
          }),
          operationId: 'initial',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: RecordListPage(store: store),
        ),
      );
      await settleIo(tester);
      await tester.tap(find.byKey(ValueKey('record-${r!.id}')));
      await settleIo(tester);
      await tester.ensureVisible(find.text('修改记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改记录'));
      await settleIo(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('record-received-quantity')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('record-received-quantity')),
        '2',
      );
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final stored = (await tester.runAsync(store.list))!.single;
      final batch =
          (stored.information.toMap()['receipt_batches'] as List).single as Map;
      expect(batch['quantity'], 2);
      expect(batch['received_at'], '2026-10-12T03:00:00.123456Z');
      expect(batch['opaque'], '原值');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  if (evidence != null) {
    testWidgets(
      'optional real nullable record list and blank entry visual evidence',
      (tester) async {
        final root = Directory(evidence);
        expect(File('${root.path}/.cheki-ui-evidence').existsSync(), isTrue);
        final font = Platform.environment['COUNT_TOOLS_UI_FONT'];
        if (font != null) {
          final loader = FontLoader('NullablePreview');
          loader.addFont(
            Future.value(ByteData.sublistView(File(font).readAsBytesSync())),
          );
          await tester.runAsync(loader.load);
        }
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          Future.value(
            ByteData.sublistView(
              File(
                '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytesSync(),
            ),
          ),
        );
        await tester.runAsync(icons.load);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(() => tester.view.reset());
        await tester.runAsync(
          () => store.save(RecordInformation.fromMap({}), operationId: 'empty'),
        );
        await tester.runAsync(
          () => store.save(
            RecordInformation.fromMap({
              'quantity': 3,
              'occurred_on': '2026-10-11',
            }),
            operationId: 'known',
          ),
        );
        final base = chekiTheme();
        final theme = base.copyWith(
          textTheme: base.textTheme.apply(
            fontFamily: font == null ? null : 'NullablePreview',
          ),
          appBarTheme: base.appBarTheme.copyWith(
            titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: font == null ? null : 'NullablePreview',
            ),
          ),
        );
        final oldShadow = debugDisableShadows;
        debugDisableShadows = false;
        try {
          for (final page in ['list', 'entry']) {
            final key = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                builder: (context, child) =>
                    RepaintBoundary(key: key, child: child!),
                home: page == 'list'
                    ? RecordListPage(store: store)
                    : RecordEditPage(store: store, historical: true),
              ),
            );
            await settleIo(tester);
            await tester.runAsync(() async {
              final shot =
                  await (key.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await shot.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File(
                '${root.path}/nullable-record-$page-320.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
              shot.dispose();
            });
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          }
        } finally {
          debugDisableShadows = oldShadow;
        }
      },
    );
  }
}

Future<void> clearNewShortcuts(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('record-day')), '');
  await tester.enterText(find.byKey(const ValueKey('record-quantity')), '');
  await tester.scrollUntilVisible(
    find.text('带签'),
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('带签'));
  await tester.pumpAndSettle();
  final status = find.byWidgetPredicate(
    (w) =>
        w is DropdownButtonFormField<String> &&
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('record-receipt-'),
  );
  await tester.scrollUntilVisible(
    status,
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(status);
  await tester.pumpAndSettle();
  await tester.tap(find.text('未填写').last);
  await tester.pumpAndSettle();
  final mode = find.byKey(const ValueKey('use-record-only'));
  await tester.scrollUntilVisible(
    mode,
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(mode);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('record-day')),
    -200,
    scrollable: find.byType(Scrollable).first,
  );
}
