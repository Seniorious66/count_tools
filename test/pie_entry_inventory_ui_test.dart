import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/member_inputs.dart';
import 'package:count_tools/cheki/ui/member_pie.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'bi_fixture.dart';
import 'transport_ui_test.dart' show settleIo;

void main() {
  final visual = Platform.environment['CHEKI_PFE_VISUAL'];
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    if (visual != null) {
      final font = FontLoader('ChekiTest')
        ..addFont(
          File(
            'C:/Windows/Fonts/msyh.ttc',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });
  late BiFixture f;
  setUp(() async {
    f = BiFixture();
    await f.open();
  });
  tearDown(() => f.close());
  final boundary = GlobalKey();
  Future<void> host(
    WidgetTester t,
    Widget child, {
    double width = 390,
    double scale = 1,
  }) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(width, 1000);
    final theme = chekiTheme();
    await t.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(
            fontFamily: visual == null ? null : 'ChekiTest',
          ),
        ),
        builder: (c, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              c,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: child,
      ),
    );
    await settleIo(t);
  }

  Future<void> capture(WidgetTester t, String name) async {
    if (visual == null) return;
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final im =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('$visual/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  }

  testWidgets(
    'library cards reorder after stock change with stable destinations; management keeps its original order',
    (t) async {
      addTearDown(t.view.reset);
      final ids = <String>[];
      await t.runAsync(() async {
        for (final q in [3, 20]) {
          final d = await f.tickets.save(
            kind: 'definition',
            information: TicketInformation({
              'active': true,
              'scope': 'group',
              'group_id': f.groupA,
              'size_id': f.three,
              'signature': 'signed',
            }),
            operationId: 'library-$q',
          );
          ids.add(d.id);
          await f.buy(d.id, q);
        }
      });
      await host(t, TicketLibraryPage(store: f.tickets));
      final first = find.byKey(ValueKey('ticket-stock-${ids[0]}'));
      final second = find.byKey(ValueKey('ticket-stock-${ids[1]}'));
      expect(t.getTopLeft(second).dy, t.getTopLeft(first).dy);
      expect(t.getTopLeft(second).dx, lessThan(t.getTopLeft(first).dx));
      await t.runAsync(() => f.buy(ids[0], 30));
      await settleIo(t);
      expect(t.getTopLeft(first).dy, t.getTopLeft(second).dy);
      expect(t.getTopLeft(first).dx, lessThan(t.getTopLeft(second).dx));
      await t.tap(first);
      await settleIo(t);
      final detail = t.widget<TicketDetailPage>(find.byType(TicketDetailPage));
      expect(detail.id, ids[0]);
      await t.pumpWidget(const SizedBox());
      await settleIo(t);
      await host(t, TicketLibraryPage(store: f.tickets, definitionsOnly: true));
      final model = (await t.runAsync(() => f.tickets.readModel()))!;
      final ordered = model.definitions.map((d) => d.id).toList();
      expect(
        t.getTopLeft(find.byKey(ValueKey('ticket-stock-${ordered[0]}'))).dy,
        lessThan(
          t.getTopLeft(find.byKey(ValueKey('ticket-stock-${ordered[1]}'))).dy,
        ),
      );
      await capture(t, 'library-management');
    },
  );

  testWidgets(
    'new size default can be cleared and untouched default does not prompt on exit',
    (t) async {
      addTearDown(t.view.reset);
      await host(
        t,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => RecordEditPage(store: f.records),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await settleIo(t);
      expect(find.byKey(ValueKey('record-size-${f.three}')), findsOneWidget);
      await t.tap(find.byType(BackButton));
      await settleIo(t);
      expect(find.text('放弃修改？'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      await t.tap(find.text('打开'));
      await settleIo(t);
      await t.tap(find.byKey(ValueKey('record-size-${f.three}')));
      await t.pumpAndSettle();
      await t.tap(find.text('未填写').last);
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('record-day')), '2026-10-12');
      await settleIo(t);
      expect(find.byKey(const ValueKey('record-size-null')), findsOneWidget);
      await capture(t, 'new-clear-default');
    },
  );
  testWidgets(
    'historical/edit missing size stays missing and disabled three is never defaulted',
    (t) async {
      addTearDown(t.view.reset);
      final old = await t.runAsync(
        () => f.records.save(
          RecordInformation.fromMap({
            'ext': {'原文': null},
          }),
          operationId: 'old-empty',
        ),
      );
      for (final page in [
        RecordEditPage(store: f.records, original: old),
        RecordEditPage(store: f.records, historical: true),
      ]) {
        await host(t, page);
        expect(find.byKey(const ValueKey('record-size-null')), findsOneWidget);
        await t.pumpWidget(const SizedBox());
        await settleIo(t);
      }
      final size = (await t.runAsync(
        () => f.catalog.list(CatalogKind.size),
      ))!.singleWhere((s) => s.id == f.three);
      await t.runAsync(
        () =>
            CatalogStore(
              f.records.database,
              clock: () => DateTime.now().toUtc().add(const Duration(days: 1)),
            ).edit(
              CatalogKind.size,
              original: size,
              name: size.name,
              active: false,
              operationId: 'disable-three',
            ),
      );
      await host(t, RecordEditPage(store: f.records));
      expect(find.byKey(const ValueKey('record-size-null')), findsOneWidget);
      expect(
        (await t.runAsync(() => f.records.list()))!.single.toRow(),
        old!.toRow(),
      );
    },
  );
  testWidgets(
    'member options follow form-day history while search selection and keyboard retain IDs',
    (t) async {
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        await f.record(1, [f.a], day: '2026-10-05');
        await f.record(1, [f.a], day: '2026-10-20');
        await f.record(1, [f.b], day: '2026-10-09');
      });
      await host(t, RecordEditPage(store: f.records), width: 320, scale: 2);
      await t.enterText(find.byKey(const ValueKey('record-day')), '2026-10-10');
      await settleIo(t);
      final input = find.byType(MemberMultiSelectField);
      expect(t.widget<MemberMultiSelectField>(input).options.map((m) => m.id), [
        f.b,
        f.a,
      ]);
      await t.ensureVisible(find.text('选择成员'));
      await t.tap(find.text('选择成员'));
      await t.pumpAndSettle();
      final search = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      );
      await t.enterText(search, 'A');
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      await t.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsOneWidget);
      await t.tap(find.byType(CheckboxListTile));
      await t.pumpAndSettle();
      await capture(t, 'member-keyboard-320-large');
      t.view.resetViewInsets();
      await t.pumpAndSettle();
      await t.tap(find.text('确定'));
      await settleIo(t);
      expect(t.widget<MemberMultiSelectField>(input).selectedIds, [f.a]);
      await t.enterText(find.byKey(const ValueKey('record-day')), '2026-10-06');
      await settleIo(t);
      expect(t.widget<MemberMultiSelectField>(input).options.first.id, f.a);
      expect(t.widget<MemberMultiSelectField>(input).selectedIds, [f.a]);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'responsive inner labels fit every portrait width and large font; small slice tap reveals full identity',
    (t) async {
      addTearDown(t.view.reset);
      final slices = [
        const MemberPieSlice('a', '晨星-A', 55, 0, Color(0xff123456)),
        const MemberPieSlice('b', '夜航-很长成员B', 40, 0, Colors.white),
        const MemberPieSlice('c', '晨星-极小成员C', 5, 0, Color(0xff123456)),
      ];
      final handle = t.ensureSemantics();
      for (final width in [320.0, 360.0, 390.0, 430.0]) {
        for (final scale in [1.0, 2.0]) {
          await host(
            t,
            Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: MemberPie(slices: slices, denominator: 100),
                ),
              ),
            ),
            width: width,
            scale: scale,
          );
          final paint = t.widget<CustomPaint>(
            find.byKey(const ValueKey('bi-pie-paint')),
          );
          expect(
            t.getSize(find.byKey(const ValueKey('bi-pie-paint'))).width,
            width - 64,
          );
          final painter = paint.painter! as MemberPiePainter;
          final labels = layoutPieLabels(
            painter.slices,
            100,
            width - 64,
            TextScaler.linear(scale),
            TextDirection.ltr,
            Colors.white,
          );
          for (var i = 0; i < labels.length; i++) {
            for (var j = i + 1; j < labels.length; j++) {
              expect(labels[i].bounds.overlaps(labels[j].bounds), isFalse);
            }
            labels[i].painter.dispose();
          }
          expect(
            find.semantics.byLabel(slices[2].description(100)),
            findsOneWidget,
          );
          await capture(t, 'pie-${width.toInt()}-${scale.toInt()}');
          expect(t.takeException(), isNull);
        }
      }
      // Select the tiny sector by angle, with no dependency on color identity.
      final painter =
          t
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('bi-pie-paint')),
                  )
                  .painter!
              as MemberPiePainter;
      final index = painter.slices.indexWhere((s) => s.id == 'c');
      final share =
          painter.slices.take(index).fold(0, (q, s) => q + s.quantity) + 2.5;
      final angle = 2 * 3.141592653589793 * share / 100 - 3.141592653589793 / 2;
      final rect = t.getRect(find.byKey(const ValueKey('bi-pie-touch')));
      // Exact sector test uses a point well away from radial boundaries.
      final offset = Offset.fromDirection(angle, rect.width * .3);
      await t.tapAt(rect.center + offset);
      await t.pumpAndSettle();
      expect(find.text(slices[2].description(100)), findsOneWidget);
      handle.dispose();
    },
  );
}
