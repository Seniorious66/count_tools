import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/data/transfer_store.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/domain/transfer_information.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/ui/transfer_pages.dart';
import 'package:count_tools/cheki/ui/backup_page.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:count_tools/app.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'storage_migration_test.dart' show legacyFixture;
import 'support/settle_io.dart';
export 'support/settle_io.dart' show settleIo;

class FakeAccess extends BackupFileAccess {
  Uint8List? selected, saved;
  bool success = false;
  @override
  Future<bool> export(Uint8List b) async {
    saved = b;
    return success;
  }

  @override
  Future<Uint8List?> choose() async => selected;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late Directory root;
  late TicketStore tickets;
  late TransferStore transfers;
  late BackupStore backup;
  late String from, to;
  late Map<String, Object?> settings;
  setUp(() async {
    await DatabaseHelper().close();
    root = await Directory.systemTemp.createTemp('cheki-transfer-ui-');
    await legacyFixture('${root.path}/user_database.db');
    DatabaseHelper.pathResolver = () async => '${root.path}/user_database.db';
    tickets = TicketStore(
      () => DatabaseHelper().database,
      clock: () => DateTime.utc(2026, 10, 13),
    );
    transfers = TransferStore(tickets.database, clock: tickets.clock);
    final group = await CatalogStore(
      tickets.database,
    ).create(CatalogKind.group, name: '晨星', operationId: 'g');
    final ids = <String>[];
    for (final name in ['来源券', '目标券']) {
      ids.add(
        (await tickets.save(
          kind: 'definition',
          information: TicketInformation({
            'name': name,
            'scope': 'group',
            'group_id': group.id,
            'active': true,
          }),
          operationId: name,
        )).id,
      );
    }
    from = ids[0];
    to = ids[1];
    await tickets.save(
      kind: 'purchase',
      information: TicketInformation({
        'definition_id': from,
        'quantity': 5,
        'unit_price': '30',
        'pool': 'long',
        'occurred_on': '2026-10-10',
      }),
      operationId: 'buy',
      posted: true,
    );
    settings = {'isNotFirstEnter': true, 'custom': '原文'};
    backup = BackupStore(
      documents: root,
      readSettings: () async => Map.from(settings),
      writeSettings: (s) async {
        settings = Map.from(s);
      },
      closeMain: DatabaseHelper().close,
      maintenance: (v) => DatabaseHelper.maintenance = v,
    );
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    DatabaseHelper.maintenance = false;
    await root.delete(recursive: true);
    final recovery = Directory('${root.path}.cheki-recovery');
    if (await recovery.exists()) await recovery.delete(recursive: true);
  });
  TransferInformation info() => TransferInformation({
    'kind': 'exchange',
    'source_definition_id': from,
    'source_pool': 'long',
    'target_definition_id': to,
    'target_pool': 'long',
    'quantity': 2,
    'occurred_on': '2026-10-13',
  });
  Future<void> host(
    WidgetTester t,
    Widget child, {
    double width = 430,
    double scale = 1,
  }) async {
    t.view.physicalSize = Size(width, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: chekiTheme(),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: child,
      ),
    );
    await settleIo(t);
  }

  Future<void> reach(WidgetTester t, Finder f) async {
    if (f.evaluate().isEmpty) {
      await t.scrollUntilVisible(
        f,
        120,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await t.ensureVisible(f);
    await t.pumpAndSettle();
  }

  Future<void> pick(WidgetTester t, String key, String label) async {
    final f = find.byKey(ValueKey(key));
    await reach(t, f);
    await t.tap(f);
    await t.pumpAndSettle();
    await t.tap(find.text(label).last);
    await settleIo(t);
  }

  testWidgets(
    'actual ticket detail exchange entry two-page review return cancel and commit once',
    (t) async {
      await host(t, TicketDetailPage(store: tickets, id: from));
      await reach(t, find.text('换券'));
      await t.tap(find.text('换券'));
      await settleIo(t);
      await t.enterText(
        find.byKey(const ValueKey('transfer-day')),
        '2026-10-13',
      );
      await settleIo(t);
      expect(
        find.byKey(const ValueKey('transfer-source-pool-long')),
        findsOneWidget,
      );
      await pick(t, 'transfer-target-null', '晨星 · 团体券');
      expect(
        find.byKey(const ValueKey('transfer-target-pool-long')),
        findsOneWidget,
      );
      await reach(t, find.byKey(const ValueKey('transfer-quantity')));
      await t.enterText(find.byKey(const ValueKey('transfer-quantity')), '2');
      await t.tap(find.text('核对并入账'));
      await settleIo(t);
      expect(find.text('换送核对'), findsOneWidget);
      expect(find.text('2 张 · 成本 60'), findsOneWidget);
      await t.pageBack();
      await settleIo(t);
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('transfer-quantity')))
            .controller!
            .text,
        '2',
      );
      await t.tap(find.text('核对并入账'));
      await settleIo(t);
      await t.tap(find.text('确认保存'));
      await settleIo(t);
      final rows = (await t.runAsync(transfers.list))!;
      expect(rows.length, 1);
      expect((await t.runAsync(tickets.readModel))!.available, 5);
      await t.runAsync(
        () async => StorageSchema.validate(
          await tickets.database(),
          StorageSchema.version,
        ),
      );
    },
  );
  testWidgets(
    'empty historical draft retained missing keys and creation date when filled',
    (t) async {
      final draft = (await t.runAsync(
        () => transfers.save(
          TransferInformation({
            'ext': {'raw': null},
          }),
          operationId: 'draft',
        ),
      ))!;
      await host(t, TransferEditPage(store: transfers, original: draft));
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('transfer-day')))
            .controller!
            .text,
        '',
      );
      await reach(t, find.byKey(const ValueKey('transfer-note')));
      await t.enterText(find.byKey(const ValueKey('transfer-note')), '补录');
      await t.tap(find.text('保存待补录'));
      await settleIo(t);
      await t.tap(find.text('确认保存'));
      await settleIo(t);
      final r = (await t.runAsync(transfers.list))!.single;
      expect(r.id, draft.id);
      expect(r.raw['created_at'], draft.raw['created_at']);
      expect(r.information.toMap(), {
        'ext': {'raw': null},
        'note': '补录',
      });
    },
  );
  testWidgets(
    'with downstream dependency displays and attempted edit keeps input and original stock',
    (t) async {
      final r = (await t.runAsync(
        () => transfers.save(info(), operationId: 'exchange', posted: true),
      ))!;
      await t.runAsync(
        () => transfers.save(
          TransferInformation({
            'kind': 'gift',
            'source_definition_id': to,
            'source_pool': 'long',
            'quantity': 1,
            'occurred_on': '2026-10-13',
          }),
          operationId: 'gift',
          posted: true,
        ),
      );
      await host(t, TransferDetailPage(store: transfers, id: r.id));
      await reach(t, find.text('查看依赖'));
      await t.tap(find.text('查看依赖'));
      await settleIo(t);
      expect(find.textContaining('不能修改原操作'), findsOneWidget);
      expect(find.text('赠送'), findsOneWidget);
      await t.pageBack();
      await settleIo(t);
      await reach(t, find.text('修改 / 撤销整笔'));
      await t.tap(find.text('修改 / 撤销整笔'));
      await settleIo(t);
      await reach(t, find.byKey(const ValueKey('transfer-quantity')));
      await t.enterText(find.byKey(const ValueKey('transfer-quantity')), '3');
      await t.tap(find.text('核对并入账'));
      await settleIo(t);
      expect(find.textContaining('不能修改'), findsOneWidget);
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('transfer-quantity')))
            .controller!
            .text,
        '3',
      );
      expect((await t.runAsync(transfers.list))!.first.raw, r.raw);
    },
  );
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'portrait $width 200 percent keyboard retains invalid input and safe return',
      (t) async {
        await host(
          t,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TransferEditPage(
                      store: transfers,
                      sourceDefinition: from,
                    ),
                  ),
                ),
                child: const Text('打开换送'),
              ),
            ),
          ),
          width: width,
          scale: 2,
        );
        await t.tap(find.text('打开换送'));
        await settleIo(t);
        expect(
          find.byKey(const ValueKey('transfer-source-pool-long')),
          findsOneWidget,
        );
        await reach(t, find.byKey(const ValueKey('transfer-quantity')));
        await t.enterText(
          find.byKey(const ValueKey('transfer-quantity')),
          'wrong',
        );
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
        await t.pumpAndSettle();
        await t.tap(find.text('核对并入账'));
        await settleIo(t);
        await reach(t, find.textContaining('张数需为正整数'));
        expect(t.takeException(), isNull);
        await t.pageBack();
        await t.pumpAndSettle();
        expect(find.text('放弃修改？'), findsOneWidget);
        await t.tap(find.text('继续编辑'));
        await t.pumpAndSettle();
        expect(
          t
              .widget<TextField>(
                find.byKey(const ValueKey('transfer-quantity')),
              )
              .controller!
              .text,
          'wrong',
        );
        t.view.resetViewInsets();
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'backup system-picker mock cancellation corrupt input preview cancel and restore',
    (t) async {
      final access = FakeAccess();
      await host(
        t,
        BackupPage(store: backup, access: access),
        width: 320,
        scale: 2,
      );
      await reach(t, find.text('导出完整备份'));
      await t.tap(find.text('导出完整备份'));
      await settleIo(t);
      expect(access.saved, isNotNull);
      expect(find.textContaining('已取消保存'), findsOneWidget);
      await reach(t, find.text('选择并检查备份'));
      await t.tap(find.text('选择并检查备份'));
      await settleIo(t);
      expect(find.textContaining('已取消选择'), findsOneWidget);
      access.selected = Uint8List.fromList([0]);
      await t.tap(find.text('选择并检查备份'));
      await settleIo(t);
      expect(find.textContaining('当前账本保留'), findsOneWidget);
      settings = {'new': 'current'};
      access.selected = access.saved;
      await t.tap(find.text('选择并检查备份'));
      await settleIo(t);
      expect(find.text('恢复后的账本'), findsOneWidget);
      await reach(t, find.text('恢复此备份'));
      await t.tap(find.text('恢复此备份'));
      await t.pumpAndSettle();
      await t.tap(find.text('取消'));
      await settleIo(t);
      expect(settings, {'new': 'current'});
      await reach(t, find.text('恢复此备份'));
      await t.tap(find.text('恢复此备份'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认恢复'));
      await settleIo(t);
      expect(settings['custom'], '原文');
      expect(find.text('完整恢复完成'), findsOneWidget);
    },
  );
  final visual = Platform.environment['COUNT_TOOLS_TRANSFER_VISUALS'];
  final restored = Platform.environment['COUNT_TOOLS_TRANSFER_RESTORED'];
  if (restored != null) {
    testWidgets(
      'fresh read-only Flutter process opens fully restored exchange costs dependencies and draft',
      (t) async {
        expect(
          File(
            '${Directory(restored).parent.path}/.count-tools-isolated.json',
          ).existsSync(),
          true,
        );
        final db = (await t.runAsync(
          () => databaseFactory.openDatabase(
            '$restored/database.sqlite',
            options: OpenDatabaseOptions(readOnly: true),
          ),
        ))!;
        await t.runAsync(() => StorageSchema.validate(db, 8));
        final s = TransferStore(() => Future.value(db));
        final rows = (await t.runAsync(s.list))!;
        expect(rows.length, 5);
        expect(rows.singleWhere((r) => !r.posted).information.toMap(), isEmpty);
        final first = rows.first;
        await host(t, TransferDetailPage(store: s, id: first.id));
        expect(find.text('继承每张成本 30'), findsOneWidget);
        expect(find.text('继承每张成本 20'), findsOneWidget);
        await reach(t, find.text('查看依赖'));
        await t.tap(find.text('查看依赖'));
        await settleIo(t);
        expect(find.textContaining('不能修改原操作'), findsOneWidget);
        final records = (await t.runAsync(
          () => RecordStore(() => Future.value(db)).list(),
        ))!;
        expect(records.length, 3);
        expect(
          records
              .singleWhere((r) => r.information.toMap().isEmpty)
              .information
              .quantity,
          isNull,
        );
        await t.pumpWidget(const SizedBox());
        await t.runAsync(db.close);
      },
    );
  }
  testWidgets(
    'actual App restore resets routes cached records and all preferences through file channel',
    (t) async {
      SharedPreferences.setMockInitialValues({
        'isNotFirstEnter': true,
        'custom': '原文',
        'opaque': ['原值'],
      });
      final appStore = (await t.runAsync(BackupStore.app))!;
      final bytes = (await t.runAsync(appStore.snapshot))!;
      await t.runAsync(() async {
        await (await SharedPreferences.getInstance()).setString(
          'custom',
          'changed',
        );
        await RecordStore(tickets.database).save(
          RecordInformation.fromMap({'note': '恢复前草稿'}),
          operationId: 'before-restore',
        );
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BackupFileAccess.channel, (call) async {
            if (call.method == 'importBackup') return bytes;
            if (call.method == 'exportBackup') return false;
            throw StateError('Unexpected method');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(BackupFileAccess.channel, null),
      );
      await host(t, const App());
      await t.tap(find.byTooltip('打开管理'));
      await settleIo(t);
      await t.scrollUntilVisible(
        find.text('备份与恢复'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await reach(t, find.text('备份与恢复'));
      await t.tap(find.text('备份与恢复'));
      await settleIo(t);
      await t.tap(find.text('选择并检查备份'));
      await settleIo(t);
      expect(find.text('Cheki 1 条'), findsOneWidget);
      expect(find.text('Cheki 0 条'), findsOneWidget);
      await reach(t, find.text('恢复此备份'));
      await t.tap(find.text('恢复此备份'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认恢复'));
      await settleIo(t);
      expect(find.byKey(const ValueKey('home-month')), findsOneWidget);
      expect(find.text('备份与恢复'), findsNothing);
      await t.runAsync(() async {
        expect(await RecordStore(tickets.database).list(), isEmpty);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('custom'), '原文');
        expect(prefs.getStringList('opaque'), ['原值']);
        expect(prefs.getKeys(), {'isNotFirstEnter', 'custom', 'opaque'});
      });
      await t.pumpWidget(const SizedBox());
      await t.runAsync(DatabaseHelper().close);
      await host(t, const App());
      expect(find.byKey(const ValueKey('home-month')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
  if (visual != null) {
    testWidgets(
      'optional portrait actual exchange review backup visual evidence',
      (t) async {
        expect(File('$visual/.cheki-ui-evidence').existsSync(), true);
        for (final item in [
          ('TransferPreview', r'C:\Windows\Fonts\msyh.ttc'),
          (
            'MaterialIcons',
            r'C:\Users\Aphoe\.cache\count-tools-runtime\flutter-3.47.5\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
          ),
        ]) {
          final l = FontLoader(item.$1);
          l.addFont(
            Future.value(ByteData.sublistView(File(item.$2).readAsBytesSync())),
          );
          await t.runAsync(l.load);
        }
        for (final mode in ['exchange', 'review', 'backup']) {
          final key = GlobalKey();
          t.view.physicalSize = const Size(430, 1000);
          t.view.devicePixelRatio = 1;
          final page = mode == 'exchange'
              ? TransferEditPage(store: transfers, sourceDefinition: from)
              : mode == 'review'
              ? TransferReviewPage(
                  store: transfers,
                  info: info(),
                  operationId: 'visual-only',
                  posted: true,
                  costs: [
                    {'quantity': 2, 'cost': '60'},
                  ],
                )
              : BackupPage(store: backup, access: FakeAccess());
          await t.pumpWidget(
            MaterialApp(
              theme: chekiTheme().copyWith(
                textTheme: chekiTheme().textTheme.apply(
                  fontFamily: 'TransferPreview',
                ),
                appBarTheme: chekiTheme().appBarTheme.copyWith(
                  titleTextStyle: chekiTheme().appBarTheme.titleTextStyle!
                      .copyWith(fontFamily: 'TransferPreview'),
                ),
              ),
              home: RepaintBoundary(key: key, child: page),
            ),
          );
          await settleIo(t);
          await t.runAsync(() async {
            final img =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            await File('$visual/$mode.png').writeAsBytes(
              (await img.toByteData(
                format: ui.ImageByteFormat.png,
              ))!.buffer.asUint8List(),
            );
            img.dispose();
          });
        }
        await t.pumpWidget(const SizedBox());
        t.view.reset();
      },
    );
  }
}
