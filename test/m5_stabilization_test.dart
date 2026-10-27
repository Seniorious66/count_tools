import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/ui/app_shell.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/transport_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/ui/entity_grid.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'package:count_tools/data/database/schema.dart';
import 'bi_fixture.dart';
import 'transport_test.dart' show state;
import 'support/settle_io.dart';

void main() {
  final visual = Platform.environment['CHEKI_M5_VISUAL'];
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (visual != null) {
      for (final item in [
        ('M5Chinese', 'C:/Windows/Fonts/msyh.ttc'),
        (
          'MaterialIcons',
          'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
      ]) {
        final loader = FontLoader(item.$1)
          ..addFont(File(item.$2).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
    }
  });
  late BiFixture f;
  setUp(() async {
    f = BiFixture();
    await f.open();
    SharedPreferences.setMockInitialValues({
      'isNotFirstEnter': true,
      'opaque': '001',
    });
  });
  tearDown(() => f.close());

  test(
    'combined costs joint counts nullable history CSV and full transport survive a generation switch',
    () async {
      await f.quantities();
      await f.finances(unknown: true, future: true);
      await f.records.save(
        RecordInformation.fromMap({
          'ext': {'missing': {}, 'null': null},
        }),
        operationId: 'm5-empty',
      );
      final before = await state(f.root);
      final snapshot = await f.bi.read();
      final period = BiPeriod(BiScope.all, '2026-10-14');
      final report = snapshot.report(period);
      expect(report.summary.knownQuantity, 8);
      expect(report.memberQuantity, 10);
      expect(report.purchase.known.exact, '106');
      expect(report.flows['拍切消耗']!.quantity, 1);
      expect(report.stocks[f.source]!.available, 2);
      var settings = <String, Object?>{
        'opaque': '001',
        'zero': 0,
        'empty': <String>[],
      };
      final backups = BackupStore(
        documents: f.root,
        readSettings: () async => Map.of(settings),
        writeSettings: (s) async => settings = Map.of(s),
        closeMain: DatabaseHelper().close,
      );
      final transport = TransportStore(backups);
      final bytes = await transport.export();
      final preview = await transport.prepare(bytes, TransportMode.snapshot);
      expect(
        await state(f.root),
        before,
      ); // Preview never changes the active generation.
      await transport.apply(preview);
      expect(await state(f.root), before);
      expect(settings, {'opaque': '001', 'zero': 0, 'empty': <String>[]});
      await StorageSchema.validate(
        await f.records.database(),
        StorageSchema.version,
      );
      final after = await f.bi.read();
      expect(after.report(period).csv(), report.csv());
      for (final id in [f.a, f.b]) {
        final filter = BiRecordFilter(memberId: id);
        expect(
          after.report(period, filter: filter).csv(),
          snapshot.report(period, filter: filter).csv(),
        );
      }
      // A historical empty entry stays empty; none of the new quick defaults leak in.
      final empty = (await f.records.list()).singleWhere(
        (r) => r.information.quantity == null,
      );
      expect(empty.information.toMap(), {
        'ext': {'missing': {}, 'null': null},
      });
      if (await backups.recovery.exists()) {
        await backups.recovery.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'management grid exposes full long name affiliation inactive status and a semantic action',
    (t) async {
      final handle = t.ensureSemantics();
      var taps = 0;
      const name = '这是一个需要完整读出的很长成员名字';
      await t.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: CompactEntityGrid(
                items: [
                  EntityGridItem(
                    id: 'm5',
                    name: name,
                    subtitle: '晨星',
                    inactive: true,
                    onTap: () => taps++,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final node = t.getSemantics(find.bySemanticsLabel('$name · 晨星 · 已停用'));
      expect(
        node,
        matchesSemantics(
          label: '$name · 晨星 · 已停用',
          isButton: true,
          hasTapAction: true,
        ),
      );
      node.owner!.performAction(node.id, ui.SemanticsAction.tap);
      await t.pump();
      expect(taps, 1);
      handle.dispose();
    },
  );

  for (final size in [(320.0, 2.0), (430.0, 1.0)]) {
    testWidgets(
      'four real shell destinations and management return remain portrait ${size.$1} scale ${size.$2}',
      (t) async {
        addTearDown(t.view.reset);
        final handle = t.ensureSemantics();
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(size.$1, 1000);
        await t.runAsync(() async {
          await f.quantities();
          await f.finances();
        });
        final key = GlobalKey();
        await t.pumpWidget(
          MaterialApp(
            theme: chekiTheme().copyWith(
              textTheme: chekiTheme().textTheme.apply(
                fontFamily: visual == null ? null : 'M5Chinese',
              ),
              appBarTheme: chekiTheme().appBarTheme.copyWith(
                titleTextStyle: chekiTheme().appBarTheme.titleTextStyle
                    ?.copyWith(fontFamily: visual == null ? null : 'M5Chinese'),
              ),
            ),
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [Locale('zh', 'CN')],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(size.$2)),
              child: RepaintBoundary(key: key, child: child!),
            ),
            home: const ChekiAppShell(),
          ),
        );
        await settleIo(t);
        for (final label in ['首页', '记录', '券库', '统计']) {
          await t.tap(
            find.descendant(
              of: find.byType(NavigationBar),
              matching: find.text(label),
            ),
          );
          await settleIo(t);
          expect(t.takeException(), isNull);
          expect(t.view.physicalSize.width < t.view.physicalSize.height, true);
          await expectLater(t, meetsGuideline(labeledTapTargetGuideline));
          if (label == '统计') {
            final period = t.getRect(find.textContaining(' — '));
            final groupLabel = t.getRect(find.text('团体筛选'));
            expect(groupLabel.top - period.bottom, greaterThanOrEqualTo(8));
          }
          if (visual != null) {
            await t.runAsync(() async {
              final render =
                  key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final image = await render.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$visual/app-${size.$1.toInt()}-$label.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
        await t.tap(find.byTooltip('打开管理'));
        await settleIo(t);
        await expectLater(t, meetsGuideline(labeledTapTargetGuideline));
        await t.binding.handlePopRoute();
        await settleIo(t);
        expect(find.byType(NavigationBar), findsOneWidget);
        await t.pumpWidget(const SizedBox());
        handle.dispose();
      },
    );
  }
}
