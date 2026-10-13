import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/record_query.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/ui/record_names.dart';
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
  late CatalogStore catalog;
  late IdentityStore identities;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cheki-names-');
    path = '${scratch.path}/source.sqlite';
    await legacyFixture(path);
    DatabaseHelper.pathResolver = () => Future.value(path);
    store = RecordStore(() => DatabaseHelper().database);
    catalog = CatalogStore(store.database);
    identities = IdentityStore(store.database);
  });
  tearDown(() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await scratch.delete(recursive: true);
  });
  Future<String> member() async {
    final g = await catalog.create(
      CatalogKind.group,
      name: '旧团',
      operationId: 'g',
    );
    return (await identities.createMember(
      name: '旧名',
      groupId: g.id,
      colorRgb: 0x987654,
      operationId: 'm',
    )).id;
  }

  RecordInformation information(String id) => RecordInformation.fromMap({
    'member_ids': [id],
    'quantity': 2,
    'occurred_on': '2026-10-11',
    'legacy_raw': {'id': 91, 'date': '2024-01-02 13:14:15', 'ext': null},
    'receipt_batches': [
      {
        'quantity': 1,
        'received_at': '2026-10-12T02:00:00.654321Z',
        'opaque': null,
      },
    ],
  });
  test(
    'snapshot shape binding duplicate nullable and unknown metadata contracts',
    () {
      final valid = RecordInformation.fromMap({
        'member_ids': ['m'],
        'member_snapshots': [
          {
            'member_id': 'm',
            'member_name': null,
            'opaque': {
              'x': [null, 1],
            },
          },
        ],
      });
      expect(
        valid.patch({'note': '备注'}).memberSnapshot('m'),
        valid.memberSnapshot('m'),
      );
      for (final value in [
        42,
        [
          {'member_id': 'other'},
        ],
        [
          {'member_id': 'm'},
          {'member_id': 'm'},
        ],
        [
          {'member_id': 'm', 'member_name': 3},
        ],
        [
          {'member_id': 'm', 'origin': 'guessed'},
        ],
      ]) {
        expect(
          () => RecordInformation.fromMap({
            'member_ids': ['m'],
            'member_snapshots': value,
          }),
          throwsFormatException,
        );
      }
      expect(RecordInformation.fromMap({'member_snapshots': null}).toMap(), {
        'member_snapshots': null,
      });
    },
  );
  test(
    'quick entry captures nullable original names while historical selection never fills old facts',
    () async {
      final id = await member(), d = await identities.directory();
      final old = information(id);
      final historical = RecordNamesController(old);
      historical.select([id], d, captureNew: false);
      expect(historical.patch([id]), isEmpty);
      final quick = RecordNamesController(old);
      quick.select([id], d, captureNew: true);
      final info = old.patch(quick.patch([id]));
      expect(info.memberSnapshot(id)?['member_name'], '旧名');
      expect(info.memberSnapshot(id)?['origin'], 'entry');
      quick.change(id, 'group_name', '史料团');
      final partial = old.patch(quick.patch([id]));
      expect(
        (await store.readModel()).recordMemberLabel(partial, id),
        '史料团（当时） · 旧名（录入时）',
      );
      expect(partial.memberSnapshot(id)?['member_name_origin'], isNull);
      final unknown = await identities.createMember(
        name: '',
        operationId: 'unknown',
      );
      quick.select(
        [id, unknown.id],
        await identities.directory(),
        captureNew: true,
      );
      expect(quick.entries[unknown.id]?['member_name'], isNull);
      expect(quick.entries[unknown.id]?['group_name'], isNull);
    },
  );
  test(
    'rename transfer stop ordinary correction cold reopen retain snapshot IDs metadata and audit',
    () async {
      final id = await member();
      final d = await identities.directory();
      final n = RecordNamesController(information(id));
      n.select([id], d, captureNew: true);
      n.entries[id]!['opaque'] = {
        'keep': [null, '原文'],
      };
      final r = await store.save(
        information(id).patch(n.patch([id])),
        operationId: 'record',
      );
      final m = d.members.single;
      final p = await identities.createPerson(
        name: '关联',
        operationId: 'person',
      );
      final named = await identities.editMember(
        original: m,
        name: '新名',
        colorRgb: 0x123456,
        personId: p.id,
        active: true,
        operationId: 'rename',
      );
      final g = await catalog.edit(
        CatalogKind.group,
        original: d.groups.single,
        name: '新团',
        active: true,
        operationId: 'group-rename',
      );
      final target = await catalog.create(
        CatalogKind.group,
        name: '目标团',
        operationId: 'target',
      );
      await identities.transferMember(
        original: named,
        groupId: target.id,
        name: '转团名',
        operationId: 'transfer',
      );
      await identities.editMember(
        original: named,
        name: '新名',
        colorRgb: 0x123456,
        personId: p.id,
        active: false,
        operationId: 'stop',
      );
      final changed = await store.save(
        r.information.patch({
          'note': '补备注',
          'quantity': 3,
          'occurred_on': '2026-10-10',
        }),
        original: r,
        operationId: 'edit',
      );
      expect(
        changed.information.memberSnapshot(id),
        r.information.memberSnapshot(id),
      );
      expect(changed.createdAt, r.createdAt);
      expect(g.knownName, '新团');
      await DatabaseHelper().close();
      final model = await store.readModel();
      expect(
        model.recordMemberLabel(model.records.single.information, id),
        '旧团 · 旧名（录入时）',
      );
      expect(model.members[id]?.colorRgb, 0x123456);
      expect(model.members[id]?.active, isFalse);
      expect(model.members.length, 2);
      expect(model.summarize(RecordFilter()).knownQuantity, 3);
      final history = await store.history(changed);
      expect(history.length, 2);
      await RecordSchema.validate(await store.database());
    },
  );
  test(
    'manual name edit clear remove restore preserves other snapshot facts and original absent NULL empty',
    () async {
      final id = await member();
      for (final raw in <Map<String, Object?>>[
        {},
        {'member_snapshots': null},
        {'member_snapshots': []},
      ]) {
        expect(
          RecordNamesController(RecordInformation.fromMap(raw)).patch([]),
          isEmpty,
        );
      }
      final old = information(id).patch({
        'member_snapshots': [
          {
            'member_id': id,
            'member_name': '原名',
            'group_name': null,
            'opaque': [null, 1],
          },
        ],
      });
      final n = RecordNamesController(old);
      n.change(id, 'group_name', '史料团');
      expect(n.patch([id])['member_snapshots'], [
        {
          'member_id': id,
          'member_name': '原名',
          'group_name': '史料团',
          'opaque': [null, 1],
          'origin': 'manual',
          'group_name_origin': 'manual',
        },
      ]);
      expect(n.patch([])['member_snapshots'], isEmpty);
      expect(n.patch([id])['member_snapshots'], isNotEmpty);
      n.change(id, 'member_name', '');
      expect(
        (n.patch([id])['member_snapshots'] as List).single['member_name'],
        isNull,
      );
      final invalid = old.patch({
        'member_snapshots': [
          {'member_id': id, 'group_id': 'missing'},
        ],
      });
      await expectLater(
        store.save(invalid, operationId: 'invalid'),
        throwsA(isA<CatalogException>()),
      );
      expect(await store.list(), isEmpty);
    },
  );
  testWidgets(
    'real old record manual name entry review back cancel save and history narrow large text keyboard',
    (tester) async {
      final id = (await tester.runAsync(member))!;
      final original = (await tester.runAsync(
        () => store.save(information(id), operationId: 'old'),
      ))!;
      for (final width in [320.0, 430.0]) {
        tester.view.physicalSize = Size(width, 960);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 200);
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            builder: (c, ch) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: ch!,
            ),
            home: RecordDetailPage(store: store, record: original),
          ),
        );
        await settleIo(tester);
        expect(find.textContaining('当时名称未填写'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('修改记录'),
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('修改记录'));
        await settleIo(tester);
        await tester.ensureVisible(find.text('记录名称'));
        await tester.tap(find.text('记录名称'));
        await tester.pumpAndSettle();
        final f = find.byKey(ValueKey('snapshot-member-$id'));
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.enterText(f, '史料名');
        await tester.tap(find.text('核对'));
        await settleIo(tester);
        expect(find.textContaining('史料名'), findsWidgets);
        await tester.binding.handlePopRoute();
        await settleIo(tester);
        await tester.ensureVisible(f);
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: f, matching: find.byType(TextField)),
              )
              .controller!
              .text,
          '史料名',
        );
        if (width == 320) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await tester.tap(find.text('放弃'));
          await settleIo(tester);
          expect(
            (await tester.runAsync(
              store.list,
            ))!.single.information.memberSnapshot(id),
            isNull,
          );
        } else {
          await tester.tap(find.text('核对'));
          await settleIo(tester);
          await tester.tap(find.text('保存'));
          await settleIo(tester);
          final saved = (await tester.runAsync(store.list))!.single;
          expect(saved.information.memberSnapshot(id)?['member_name'], '史料名');
          expect(saved.id, original.id);
          expect(saved.createdAt, original.createdAt);
          expect(
            (await tester.runAsync(() => store.history(saved)))!.length,
            2,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      tester.view.reset();
    },
  );
  testWidgets(
    'actual quick-new dropdown creates entry snapshot through the two-page save',
    (tester) async {
      final id = (await tester.runAsync(member))!;
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: RecordEditPage(store: store),
        ),
      );
      await settleIo(tester);
      await tester.ensureVisible(find.text('选择成员'));
      await tester.tap(find.text('选择成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('member-option-$id')));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      // This name-snapshot test intentionally records without coupon inventory.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('use-record-only')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('use-record-only')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对'));
      await settleIo(tester);
      expect(find.textContaining('旧团 · 旧名（录入时）'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await settleIo(tester);
      final r = (await tester.runAsync(store.list))!.single;
      expect(r.information.memberSnapshot(id)?['member_name'], '旧名');
      expect(r.information.memberSnapshot(id)?['group_name'], '旧团');
      expect(r.information.memberSnapshot(id)?['origin'], 'entry');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  final evidence = Platform.environment['COUNT_TOOLS_NAMES_VISUAL'];
  if (evidence != null) {
    testWidgets('optional actual record names form visual', (tester) async {
      final root = Directory(evidence);
      expect(File('${root.path}/.cheki-ui-evidence').existsSync(), isTrue);
      for (final (family, path) in [
        ('NamesPreview', Platform.environment['COUNT_TOOLS_UI_FONT']),
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
      final id = (await tester.runAsync(member))!;
      final n = RecordNamesController(information(id));
      n.change(id, 'member_name', '史料名');
      final r = (await tester.runAsync(
        () => store.save(
          information(id).patch(n.patch([id])),
          operationId: 'visual',
        ),
      ))!;
      tester.view.physicalSize = const Size(320, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme().copyWith(
            textTheme: chekiTheme().textTheme.apply(fontFamily: 'NamesPreview'),
            appBarTheme: chekiTheme().appBarTheme.copyWith(
              titleTextStyle: chekiTheme().appBarTheme.titleTextStyle!.copyWith(
                fontFamily: 'NamesPreview',
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
      await tester.ensureVisible(find.text('记录名称'));
      await tester.tap(find.text('记录名称'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(ValueKey('snapshot-member-$id')));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('记录名称')),
        alignment: 0,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final pic =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final bytes = await pic.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${root.path}/names-form-320.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
        } finally {
          pic.dispose();
        }
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
  final export = Platform.environment['COUNT_TOOLS_NAMES_ACCEPTANCE'];
  if (export != null) {
    test('optional actual Dart name snapshot store export', () async {
      final root = Directory(export).absolute;
      final mark =
          jsonDecode(
                File('${root.path}/.names-acceptance.json').readAsStringSync(),
              )
              as Map;
      expect(mark['purpose'], 'm1-synthetic-names');
      expect(root.path.startsWith(Directory.current.absolute.path), isFalse);
      for (final f in [
        'database.sqlite',
        'preferences.json',
        'synthetic-attachment',
      ]) {
        expect(File('${root.path}/$f').existsSync(), isFalse);
      }
      final id = await member();
      await store.save(RecordInformation.fromMap({}), operationId: 'blank');
      await store.save(information(id), operationId: 'old');
      final quick = RecordNamesController(information(id));
      quick.select([id], await identities.directory(), captureNew: true);
      await store.save(
        information(id).patch(quick.patch([id])),
        operationId: 'quick',
      );
      final n = RecordNamesController(information(id));
      n.change(id, 'member_name', '史料名');
      n.entries[id]!['opaque'] = {
        'keep': [null, '原文'],
      };
      final r = await store.save(
        information(id).patch(n.patch([id])),
        operationId: 'manual',
      );
      final next = RecordNamesController(r.information);
      next.change(id, 'group_name', '史料团');
      await store.save(
        r.information.patch(next.patch([id])),
        original: r,
        operationId: 'complete',
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
    });
  }
}
