import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/transport_codec.dart';
import 'package:count_tools/cheki/data/transport_store.dart';
import 'package:count_tools/cheki/ui/transport_page.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'bi_fixture.dart';
import 'support/settle_io.dart';
export 'support/settle_io.dart' show settleIo;

class FakeTransportAccess extends TransportFileAccess {
  Uint8List? selected, saved;
  String? name;
  bool success = false;
  @override
  Future<bool> save(Uint8List bytes, String file) async {
    saved = bytes;
    name = file;
    return success;
  }

  @override
  Future<Uint8List?> choose() async => selected;
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (Platform.environment['CHEKI_TRANSPORT_VISUAL'] != null) {
      final font = FontLoader('ChekiTest');
      font.addFont(
        File(
          'C:/Windows/Fonts/msyh.ttc',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        File(
          Platform.environment['CHEKI_TRANSPORT_ICON_FONT']!,
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
      await icons.load();
    }
  });
  late BiFixture f;
  late TransportStore store;
  late FakeTransportAccess access;
  final boundary = GlobalKey();
  setUp(() async {
    f = BiFixture();
    await f.open();
    await f.quantities();
    access = FakeTransportAccess();
    store = TransportStore(
      BackupStore(
        documents: f.root,
        readSettings: () async => {'state': 'synthetic'},
        writeSettings: (_) async {},
        closeMain: DatabaseHelper().close,
      ),
    );
  });
  tearDown(() async {
    final recovery = store.backups.recovery;
    await f.close();
    if (await recovery.exists()) await recovery.delete(recursive: true);
  });
  Future<void> mount(
    WidgetTester t, {
    double width = 360,
    double scale = 1,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    await t.pumpWidget(
      MaterialApp(
        theme: chekiTheme().copyWith(
          appBarTheme: chekiTheme().appBarTheme.copyWith(
            titleTextStyle: chekiTheme().appBarTheme.titleTextStyle?.copyWith(
              fontFamily: Platform.environment['CHEKI_TRANSPORT_VISUAL'] == null
                  ? null
                  : 'ChekiTest',
            ),
          ),
          textTheme: chekiTheme().textTheme.apply(
            fontFamily: Platform.environment['CHEKI_TRANSPORT_VISUAL'] == null
                ? null
                : 'ChekiTest',
          ),
        ),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundary,
          child: TransportPage(store: store, access: access),
        ),
      ),
    );
    await settleIo(t);
  }

  Future<void> tap(WidgetTester t, String label) async {
    final finder = find.text(label).first;
    await t.ensureVisible(finder);
    await settleIo(t);
    await Scrollable.ensureVisible(t.element(finder), alignment: 0.5);
    await t.pumpAndSettle();
    await t.tap(finder);
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    final root = Platform.environment['CHEKI_TRANSPORT_VISUAL'];
    if (root == null) return;
    await t.runAsync(() async {
      final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary,
          image = await render.toImage(pixelRatio: 1),
          data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$root/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'portrait narrow large-font controls stay reachable, no inputs or keyboard trap',
    (t) async {
      addTearDown(t.view.reset);
      for (final width in [320.0, 360.0, 390.0, 430.0]) {
        await mount(t, width: width);
        expect(find.byType(TextField), findsNothing);
        expect(t.takeException(), isNull);
        await capture(t, 'transport-${width.toInt()}');
        await t.pumpWidget(const SizedBox());
        await settleIo(t);
      }
      await mount(t, width: 320, scale: 2);
      await capture(t, 'transport-320-large-top');
      await tap(t, '选择并检查数据包');
      expect(find.text('已取消选择'), findsOneWidget);
      await capture(t, 'transport-320-large-bottom');
      t.view.viewInsets = FakeViewPadding(bottom: 320);
      await t.pump();
      await tap(t, '导出交易模板');
      expect(access.saved, isNotNull);
      expect(t.takeException(), isNull);
      await capture(t, 'transport-320-large-keyboard');
      t.view.resetViewInsets();
    },
  );
  testWidgets(
    'preview cancellation, bad reselection and mode change invalidate confirm',
    (t) async {
      addTearDown(t.view.reset);
      access.selected = await t.runAsync(
        () => store.export(mode: TransportMode.transactions),
      );
      await mount(t);
      await tap(t, '选择并检查数据包');
      expect(find.text('交易追加预览'), findsOneWidget);
      await capture(t, 'transactions-preview');
      await tap(t, '确认这个预览');
      await tap(t, '取消');
      expect(find.text('交易追加预览'), findsOneWidget);
      access.selected = Uint8List.fromList([1, 2, 3]);
      await tap(t, '选择并检查数据包');
      expect(find.text('确认这个预览'), findsNothing);
      access.selected = await t.runAsync(
        () => store.export(mode: TransportMode.transactions),
      );
      await tap(t, '选择并检查数据包');
      await tap(t, '交易追加');
      await tap(t, '完整账本快照');
      expect(find.text('确认这个预览'), findsNothing);
      await capture(t, 'snapshot-mode');
    },
  );
  testWidgets(
    'real isolated transaction confirm and SAF save result, cancel retains ledger',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        final base = await store.backups.snapshot();
        await f.record(5, [f.a]);
        access.selected = await store.export(mode: TransportMode.transactions);
        await store.backups.apply(await store.backups.prepare(base));
      });
      await mount(t);
      await tap(t, '选择并检查数据包');
      await tap(t, '确认这个预览');
      await tap(t, '确认');
      expect(find.text('数据携带完成'), findsOneWidget);
      final rows = await t.runAsync(() => f.records.list());
      expect(rows, hasLength(4));
      access.success = true;
      await tap(t, '导出完整数据包');
      expect(find.text('数据包已保存到选择的位置'), findsOneWidget);
      expect(access.name, endsWith('.chekicsv.zip'));
      expect(
        TransportZip.decode(access.saved!).keys,
        contains('manifest.json'),
      );
      access.success = false;
      await tap(t, '导出交易模板');
      expect(find.text('已取消保存'), findsOneWidget);
    },
  );
  test(
    'Android channel uses ZIP MIME method and preserves cancel results',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(TransportFileAccess.channel, (call) async {
            calls.add(call);
            return call.method == 'exportTables' ? true : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(TransportFileAccess.channel, null),
      );
      final real = TransportFileAccess();
      expect(await real.save(Uint8List.fromList([1]), 'x.chekicsv.zip'), true);
      expect(calls.single.method, 'exportTables');
      expect((calls.single.arguments as Map)['name'], 'x.chekicsv.zip');
      expect(await real.choose(), null);
    },
  );
}
