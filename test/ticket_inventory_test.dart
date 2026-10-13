import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
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
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late Directory temp;
  late TicketStore store;
  late TicketObject definition;
  var code = 0;
  Future<TicketObject> purchase(
    int? q, {
    String? unit,
    String? total,
    String? expiry,
    String day = '2026-10-10',
    bool posted = true,
  }) => store.save(
    kind: 'purchase',
    information: TicketInformation({
      'definition_id': definition.id,
      'occurred_on': day,
      'quantity': q,
      'pool': expiry == null ? 'long' : 'dated',
      'expires_on': ?expiry,
      'unit_price': ?unit,
      'total_price': ?total,
    }),
    operationId: 'buy-${code++}',
    posted: posted,
  );
  Future<TicketObject> adjust(
    int q, {
    String? expiry,
    String day = '2026-10-13',
    bool allowExpired = false,
  }) => store.save(
    kind: 'adjustment',
    information: TicketInformation({
      'definition_id': definition.id,
      'occurred_on': day,
      'quantity': q,
      'pool': expiry == null ? 'long' : 'dated',
      'expires_on': ?expiry,
      'reason': '合成库存修正',
    }),
    operationId: 'adjust-${code++}',
    posted: true,
    allowExpired: allowExpired,
  );
  setUp(() async {
    code = 0;
    await DatabaseHelper().close();
    temp = await Directory.systemTemp.createTemp('cheki-ticket-');
    final path = '${temp.path}/db';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () => Future.value(path);
    store = TicketStore(
      () => DatabaseHelper().database,
      clock: () => DateTime.utc(2026, 10, 13, 3),
    );
    final group = await CatalogStore(
      store.database,
      clock: store.clock,
    ).create(CatalogKind.group, name: '晨星', operationId: 'group');
    definition = await store.save(
      kind: 'definition',
      information: TicketInformation({
        'name': '通用券',
        'group_id': group.id,
        'scope': 'group',
        'active': true,
      }),
      operationId: 'definition',
    );
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await temp.delete(recursive: true);
  });
  test(
    'nullable draft preserves missing NULL ext and original action; later posting keeps ID',
    () async {
      final draft = await store.save(
        kind: 'purchase',
        information: TicketInformation({
          'quantity': null,
          'ext': {
            '原文': [null, '未知'],
          },
        }),
        operationId: 'blank',
      );
      expect((await store.readModel()).available, 0);
      expect((await store.readModel()).drafts.length, 1);
      final posted = await store.save(
        kind: 'purchase',
        information: TicketInformation({
          ...draft.information.toMap(),
          'definition_id': definition.id,
          'quantity': 2,
          'occurred_on': '2026-10-11',
          'pool': 'long',
        }),
        original: draft,
        posted: true,
        operationId: 'fill',
      );
      expect(posted.id, draft.id);
      expect(posted.raw['created_at'], draft.raw['created_at']);
      expect(posted.information.toMap().containsKey('unit_price'), false);
      expect(
        posted.information.toMap()['ext'],
        draft.information.toMap()['ext'],
      );
      expect((await store.history(draft.id)).length, 2);
      await DatabaseHelper().close();
      expect((await store.readModel()).available, 2);
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  test('long stock merges sources but outgoing costs FIFO 30 then20', () async {
    await purchase(2, unit: '30');
    await purchase(2, unit: '20');
    final m = await store.readModel();
    expect(m.pools(definition.id).single.quantity, 4);
    final out = await adjust(-3);
    expect(out.allocations.map((a) => a['cost']), ['60', '20']);
    expect((await store.readModel()).available, 1);
    await StorageSchema.validate(await store.database(), StorageSchema.version);
  });
  test(
    'FEFO excludes expired and future, expiry includes boundary day',
    () async {
      await purchase(3, unit: '30');
      await purchase(2, expiry: '2026-10-15');
      await purchase(1, expiry: '2026-10-13');
      await purchase(9, expiry: '2026-10-12');
      await purchase(8, day: '2026-10-14');
      expect((await store.readModel()).available, 6);
      final suggestion = await store.suggest(definition.id, 4, '2026-10-13');
      expect(suggestion.map((p) => p.expiry), [
        '2026-10-13',
        '2026-10-15',
        null,
      ]);
      expect(suggestion.map((p) => p.quantity), [1, 2, 1]);
      expect((await store.readModel(day: '2026-10-14')).available, 13);
    },
  );
  test('manual expired use explicit and unknown cost remains NULL', () async {
    await purchase(2, expiry: '2026-10-12');
    await expectLater(adjust(-1, expiry: '2026-10-12'), throwsFormatException);
    final used = await adjust(-1, expiry: '2026-10-12', allowExpired: true);
    expect(used.allocations.single['cost'], null);
    expect((await store.readModel()).allPools.single.quantity, 1);
  });
  test(
    'future inventory cannot support historical outgoing; overdraw rolls back',
    () async {
      await purchase(2, day: '2026-10-14');
      final before = (await store.readModel()).objects.length;
      await expectLater(adjust(-1), throwsFormatException);
      expect((await store.readModel()).objects.length, before);
      await expectLater(adjust(-3, day: '2026-10-14'), throwsFormatException);
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  test(
    'exact rational no rounding, cost conflict retained as draft and blocked posting',
    () async {
      final source = await purchase(3, total: '10.00');
      expect(source.information.unitCost!.exact, '10/3');
      final out = await adjust(-2);
      expect(out.allocations.single['cost'], '20/3');
      final conflict = await purchase(
        2,
        unit: '30',
        total: '50',
        posted: false,
      );
      expect(conflict.information.costConflict, true);
      await expectLater(
        store.save(
          kind: 'purchase',
          information: conflict.information,
          original: conflict,
          operationId: 'post-conflict',
          posted: true,
        ),
        throwsFormatException,
      );
      expect((await store.readModel()).available, 1);
    },
  );
  test(
    'downstream blocks source changes, no downstream correction preserves original history',
    () async {
      final first = await purchase(2, unit: '30');
      await adjust(-1);
      await expectLater(
        store.save(
          kind: 'purchase',
          original: first,
          information: TicketInformation({
            ...first.information.toMap(),
            'quantity': 1,
          }),
          operationId: 'bad-correct',
          posted: true,
        ),
        throwsFormatException,
      );
      final second = await purchase(2, unit: '20');
      final correction = await store.save(
        kind: 'purchase',
        original: second,
        information: TicketInformation({
          ...second.information.toMap(),
          'quantity': 3,
        }),
        operationId: 'correct',
        posted: true,
      );
      expect(correction.id, second.id);
      expect((await store.history(second.id)).length, 2);
      expect((await store.readModel()).available, 4);
      await store.save(
        kind: 'purchase',
        original: correction,
        information: correction.information,
        operationId: 'unpost',
        posted: false,
      );
      expect((await store.readModel()).available, 1);
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  test(
    'idempotence collision stale revision fault and notifications only success',
    () async {
      var notifications = 0;
      final sub = TicketStore.changes.listen((_) => notifications++);
      final info = TicketInformation({});
      final draft = await store.save(
        kind: 'purchase',
        information: info,
        operationId: 'repeat',
      );
      final retry = await store.save(
        kind: 'purchase',
        information: info,
        operationId: 'repeat',
      );
      expect(retry.id, draft.id);
      expect(notifications, 1);
      await expectLater(
        store.save(
          kind: 'purchase',
          information: TicketInformation({'note': '不同请求'}),
          operationId: 'repeat',
        ),
        throwsFormatException,
      );
      final fault = TicketStore(
        store.database,
        clock: store.clock,
        afterWrite: () async => throw StateError('injected'),
      );
      await expectLater(
        fault.save(kind: 'purchase', information: info, operationId: 'fail'),
        throwsStateError,
      );
      expect(notifications, 1);
      await store.save(
        kind: 'purchase',
        information: TicketInformation({'note': '新版'}),
        original: draft,
        operationId: 'new-revision',
      );
      await expectLater(
        store.save(
          kind: 'purchase',
          information: info,
          original: draft,
          operationId: 'stale',
        ),
        throwsFormatException,
      );
      await expectLater(
        store.save(kind: 'purchase', information: info, operationId: 'group'),
        throwsFormatException,
      );
      await sub.cancel();
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  test(
    'same name groups independent; inactive keeps balances/history rejects new posting',
    () async {
      await purchase(2);
      final other = await store.save(
        kind: 'definition',
        information: TicketInformation({'name': '通用券'}),
        operationId: 'incomplete-def',
      );
      await expectLater(
        store.save(
          kind: 'purchase',
          information: TicketInformation({
            'definition_id': other.id,
            'quantity': 1,
            'occurred_on': '2026-10-13',
            'pool': 'long',
          }),
          operationId: 'unknown-owner',
          posted: true,
        ),
        throwsFormatException,
      );
      await store.save(
        kind: 'definition',
        information: TicketInformation({
          ...definition.information.toMap(),
          'active': false,
          'name': '新券名',
        }),
        original: definition,
        operationId: 'stop',
      );
      expect((await store.readModel()).available, 2);
      await expectLater(purchase(1), throwsFormatException);
    },
  );
  testWidgets(
    'real long-only, mixed, expired and exhausted pools use R1 labels',
    (t) async {
      addTearDown(() => t.pumpWidget(const SizedBox()));
      await purchase(2, unit: '30');
      await purchase(2, unit: '20');
      await purchase(1, expiry: '2026-10-12');
      await t.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: TicketLibraryPage(store: store),
        ),
      );
      await settleIo(t);
      expect(find.text('长期 4 张'), findsNothing);
      expect(find.textContaining('限时 0'), findsNothing);
      expect(find.text('晨星 · 通用券'), findsOneWidget);
      expect(find.textContaining('已过期'), findsWidgets);
      await t.runAsync(() => purchase(1, expiry: '2026-10-15'));
      await settleIo(t);
      expect(find.text('长期 4 张'), findsOneWidget);
      expect(find.textContaining('2026-10-15'), findsOneWidget);
      await t.runAsync(() => adjust(-1, expiry: '2026-10-15'));
      await settleIo(t);
      expect(find.text('长期 4 张'), findsNothing);
      expect(find.textContaining('2026-10-15'), findsNothing);
    },
  );
  testWidgets('320 and430 portrait at200% keyboard nullable form review save', (
    t,
  ) async {
    for (final width in [320.0, 430.0]) {
      t.view.physicalSize = Size(width, 900);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          builder: (c, w) => MediaQuery(
            data: MediaQuery.of(c).copyWith(
              textScaler: const TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 260),
            ),
            child: w!,
          ),
          home: TicketEditPage(
            key: ValueKey(width),
            store: store,
            kind: 'purchase',
          ),
        ),
      );
      await settleIo(t);
      await t.tap(find.text('核对'));
      await settleIo(t);
      expect(find.text('仅保存信息，不生成库存'), findsOneWidget);
      expect(t.takeException(), null);
      await t.tap(find.text('返回修改'));
      await settleIo(t);
      expect(t.takeException(), null);
    }
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  testWidgets(
    'home loading/error never shows fake zero and reminder settings survive',
    (t) async {
      addTearDown(() => t.pumpWidget(const SizedBox()));
      final gate = Completer<Database>();
      final delayed = TicketStore(() => gate.future);
      await t.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: TicketSummaryPanel(store: delayed),
        ),
      );
      await t.pump();
      expect(find.text('0'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      gate.completeError(StateError('synthetic read failure'));
      await t.pumpAndSettle();
      expect(find.textContaining('读取失败'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      await t.runAsync(
        () => store.save(
          kind: 'setting',
          information: TicketInformation({'reminder_days': 0, 'ext': null}),
          operationId: 'reminder',
        ),
      );
      await t.runAsync(() => purchase(1, expiry: '2026-10-15'));
      await t.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: TicketSummaryPanel(key: const ValueKey("actual"), store: store),
        ),
      );
      await settleIo(t);
      expect(find.textContaining('到期 1 张'), findsNothing);
      await t.runAsync(() async {
        await DatabaseHelper().close();
        expect((await store.readModel()).reminderDays, 0);
      });
    },
  );

  test(
    'schema5 migration adds only ticket tables and failure leaves originals intact',
    () async {
      final path = '${temp.path}/schema5';
      await legacyFixture(path);
      final db = await openDatabase(path);
      await db.transaction((tx) => StorageSchema.migrate(tx, 1, 5));
      await db.setVersion(5);
      final before = await db.query('item_data');
      await expectLater(
        db.transaction(
          (tx) => StorageSchema.migrate(
            tx,
            5,
            6,
            afterStep: () async => throw StateError('migration fault'),
          ),
        ),
        throwsStateError,
      );
      expect(await db.getVersion(), 5);
      expect(await db.query('item_data'), before);
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name='cheki_ticket_objects'",
        ),
        isEmpty,
      );
      await db.transaction((tx) => StorageSchema.migrate(tx, 5, 6));
      await db.setVersion(6);
      await StorageSchema.validate(db, 6);
      expect(await db.query('item_data'), before);
      await db.close();
    },
  );
  testWidgets(
    'actual purchase review, saving and correction from portrait UI',
    (t) async {
      addTearDown(() => t.pumpWidget(const SizedBox()));
      t.view.physicalSize = const Size(320, 900);
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: Builder(
            builder: (c) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  c,
                  MaterialPageRoute(
                    builder: (_) => TicketEditPage(
                      store: store,
                      kind: 'purchase',
                      definitionId: definition.id,
                    ),
                  ),
                ),
                child: const Text('打开购券'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开购券'));
      await settleIo(t);
      for (final kv in {
        'occurred_on': '2026-10-13',
        'quantity': '2',
        'unit_price': '30.00',
      }.entries) {
        final f = find.byKey(ValueKey('ticket-${kv.key}'));
        await t.ensureVisible(f);
        await t.enterText(f, kv.value);
      }
      final pool = find.byKey(const ValueKey('ticket-pool'));
      await t.ensureVisible(pool);
      await t.tap(pool);
      await t.pumpAndSettle();
      await t.tap(find.text('长期有效').last);
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('计入库存'));
      await t.tap(find.text('计入库存'));
      await t.pump();
      await t.tap(find.text('核对'));
      await t.pumpAndSettle();
      expect(find.text('确认后计入库存'), findsOneWidget);
      await t.tap(find.text('确认保存'));
      await settleIo(t);
      expect(find.text('打开购券'), findsOneWidget);
      await t.runAsync(() async {
        expect((await store.readModel()).available, 2);
        await StorageSchema.validate(
          await store.database(),
          StorageSchema.version,
        );
      });
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    },
  );
  final visual = Platform.environment['COUNT_TOOLS_TICKET_VISUALS'];
  if (visual != null) {
    testWidgets('optional actual coupon screens portrait visual evidence', (
      t,
    ) async {
      await t.runAsync(() async {
        await purchase(4, unit: '30');
        await purchase(2, expiry: '2026-10-15');
        await purchase(1, expiry: '2026-10-12');
      });
      final key = GlobalKey();
      final loader = FontLoader('TicketPreview');
      loader.addFont(
        Future.value(
          ByteData.sublistView(
            File(r'C:\Windows\Fonts\msyh.ttc').readAsBytesSync(),
          ),
        ),
      );
      await t.runAsync(loader.load);
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        Future.value(
          ByteData.sublistView(
            File(
              r'C:\Users\Aphoe\.cache\count-tools-runtime\flutter-3.47.5\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
      await t.runAsync(icons.load);
      for (final entry in <(String, double, double, Widget)>[
        (
          'home-320',
          320,
          1,
          Scaffold(
            body: ListView(
              children: [
                TicketOverview(
                  store: store,
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('2026-10 · Cheki'),
                      Text('7', style: TextStyle(fontSize: 40)),
                      Text('已知张数'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        ('library-430', 430, 1, TicketLibraryPage(store: store)),
        (
          'detail-320-big',
          320,
          2,
          TicketDetailPage(store: store, id: definition.id),
        ),
        (
          'purchase-320-big',
          320,
          2,
          TicketEditPage(
            store: store,
            kind: 'purchase',
            definitionId: definition.id,
          ),
        ),
      ]) {
        t.view.physicalSize = Size(entry.$2, 1000);
        t.view.devicePixelRatio = 1;
        await t.pumpWidget(
          MaterialApp(
            theme: chekiTheme().copyWith(
              textTheme: chekiTheme().textTheme.apply(
                fontFamily: 'TicketPreview',
              ),
              appBarTheme: chekiTheme().appBarTheme.copyWith(
                titleTextStyle: chekiTheme().appBarTheme.titleTextStyle!
                    .copyWith(fontFamily: 'TicketPreview'),
              ),
            ),
            builder: (c, w) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: TextScaler.linear(entry.$3)),
              child: w!,
            ),
            home: RepaintBoundary(key: key, child: entry.$4),
          ),
        );
        await settleIo(t);
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await t.runAsync(() async {
          final img = await boundary.toImage();
          final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$visual/${entry.$1}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          img.dispose();
        });
        expect(t.takeException(), null);
      }
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
  }
  final restored = Platform.environment['COUNT_TOOLS_TICKET_RESTORED'];
  if (restored != null) {
    testWidgets(
      'fresh Flutter readonly restored ledger and actual coupon library',
      (t) async {
        addTearDown(() => t.pumpWidget(const SizedBox()));
        final db = (await t.runAsync(
          () => databaseFactory.openDatabase(
            '$restored/database.sqlite',
            options: OpenDatabaseOptions(readOnly: true),
          ),
        ))!;
        final restoredStore = TicketStore(
          () => Future.value(db),
          clock: () => DateTime.utc(2026, 10, 13),
        );
        await t.runAsync(() async {
          await StorageSchema.validate(db, 6);
          final m = await restoredStore.readModel();
          expect(m.available, 5);
          expect(m.drafts.length, 2);
          expect(m.allPools.where((p) => p.expired(m.day)).single.quantity, 1);
        });
        await t.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            home: TicketLibraryPage(store: restoredStore),
          ),
        );
        await settleIo(t);
        expect(find.text('晨星 · 通用券'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
        await t.runAsync(db.close);
      },
    );
  }
  test(
    'fault after an allocated decrease keeps source balances costs and history unchanged',
    () async {
      await purchase(2, unit: '30');
      await purchase(2, unit: '20');
      final before = (await store.readModel()).objects
          .map((e) => e.raw)
          .toList();
      final fault = TicketStore(
        store.database,
        clock: store.clock,
        afterWrite: () async => throw StateError('allocated fault'),
      );
      await expectLater(
        fault.save(
          kind: 'adjustment',
          information: TicketInformation({
            'definition_id': definition.id,
            'occurred_on': '2026-10-13',
            'quantity': -3,
            'pool': 'long',
          }),
          operationId: 'allocated-failure',
          posted: true,
        ),
        throwsStateError,
      );
      final after = await store.readModel();
      expect(after.available, 4);
      expect(after.objects.map((e) => e.raw).toList(), before);
      expect(
        await (await store.database()).query(
          TicketSchema.operations,
          where: 'id=?',
          whereArgs: ['allocated-failure'],
        ),
        isEmpty,
      );
      await expectLater(
        CatalogStore(
          store.database,
          clock: store.clock,
        ).create(CatalogKind.group, name: '不能重复', operationId: 'definition'),
        throwsA(isA<CatalogException>()),
      );
      await StorageSchema.validate(
        await store.database(),
        StorageSchema.version,
      );
    },
  );
  test('current schema6 full synthetic export for complete recovery', () async {
    await purchase(2, unit: '30');
    await purchase(2, unit: '20');
    await adjust(-1);
    await purchase(2, total: '10', expiry: '2026-10-15');
    await purchase(1, expiry: '2026-10-12');
    await store.save(
      kind: 'purchase',
      information: TicketInformation({
        'quantity': null,
        'ext': {
          '缺键': [null, '原文'],
        },
      }),
      operationId: 'draft-ext',
    );
    await store.save(
      kind: 'purchase',
      information: TicketInformation({}),
      operationId: 'blank-entry',
    );
    await store.save(
      kind: 'definition',
      information: TicketInformation({}),
      operationId: 'blank-definition',
    );
    await store.save(
      kind: 'setting',
      information: TicketInformation({'reminder_days': 3}),
      operationId: 'settings',
    );
    await RecordStore(
      store.database,
      clock: store.clock,
    ).save(RecordInformation.fromMap({}), operationId: 'blank-record');
    final db = await store.database();
    await StorageSchema.validate(db, StorageSchema.version);
    final export = Platform.environment['COUNT_TOOLS_TICKET_ACCEPTANCE'];
    if (export != null) {
      final root = Directory(export);
      expect(root.path.contains('artifacts'), true);
      await root.create(recursive: true);
      expect(File('${root.path}/database.sqlite').existsSync(), false);
      await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      await DatabaseHelper().close();
      await File('${temp.path}/db').copy('${root.path}/database.sqlite');
      await File('${root.path}/.ticket-acceptance.json').writeAsString(
        jsonEncode({'project': 'count_tools', 'purpose': 'ticket-synthetic'}),
      );
      await File('${root.path}/preferences.json').writeAsString(
        jsonEncode({
          '原设置': '保留',
          'unknown': ['原文'],
          'theme': 0,
          'isDarkMode': false,
        }),
      );
      await File(
        '${root.path}/synthetic-attachment',
      ).writeAsBytes([0, 255, 1, 2, 3]);
    }
  });
}
