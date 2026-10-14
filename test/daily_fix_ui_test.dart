import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/ui/catalog_pages.dart';
import 'package:count_tools/cheki/ui/identity_pages.dart';
import 'package:count_tools/cheki/ui/record_pages.dart';
import 'package:count_tools/cheki/ui/ticket_pages.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'bi_fixture.dart';
import 'catalog_pages_test.dart' show settleIo;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late BiFixture f;
  setUp(() async {
    f = BiFixture();
    await f.open();
  });
  tearDown(() => f.close());
  testWidgets(
    'member settings correction and clear persist across reopen without transfer',
    (t) async {
      final original = await t.runAsync(() => f.member(f.a));
      Future<void> open() async {
        final member = (await t.runAsync(() => f.member(f.a)))!;
        await t.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            home: IdentityEditPage(
              kind: IdentityKind.member,
              store: f.identities,
              original: member,
            ),
          ),
        );
        await settleIo(t);
      }

      await open();
      final group = find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('identity-group-'),
      );
      await t.tap(group);
      await t.pumpAndSettle();
      await t.tap(find.text('夜航').last);
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await settleIo(t);
      expect((await t.runAsync(() => f.member(f.a)))!.groupId, f.groupB);
      await t.pumpWidget(const SizedBox());
      await open();
      await t.tap(group);
      await t.pumpAndSettle();
      await t.tap(find.text('未填写').last);
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await settleIo(t);
      final corrected = (await t.runAsync(() => f.member(f.a)))!;
      expect(corrected.groupId, isNull);
      expect(corrected.createdAt, original!.createdAt);
      expect(corrected.id, original.id);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'home metrics share number baselines and purchase is outside both columns',
    (t) async {
      await t.runAsync(() async {
        await f.quantities();
        await f.finances();
      });
      t.view.physicalSize = const Size(360, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: Scaffold(
            body: RecordHomePage(store: f.records, ticketStore: f.tickets),
          ),
        ),
      );
      await settleIo(t);
      final metrics = find.byType(OverviewMetric);
      expect(metrics, findsNWidgets(2));
      final left = find
          .descendant(of: metrics.at(0), matching: find.byType(RichText))
          .last;
      final right = find
          .descendant(of: metrics.at(1), matching: find.byType(RichText))
          .last;
      expect(
        (t.getTopLeft(left).dy - t.getTopLeft(right).dy).abs(),
        lessThan(1),
      );
      expect(
        t.getTopLeft(find.text('购券')).dy,
        greaterThan(t.getBottomLeft(right).dy),
      );
      expect(find.text('已知张数'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('coupon library separates action and available-stock regions', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        theme: chekiTheme(),
        home: TicketLibraryPage(store: f.tickets),
      ),
    );
    await settleIo(t);
    expect(
      t.getTopLeft(find.text('可用券')).dy - t.getBottomLeft(find.text('购券')).dy,
      greaterThanOrEqualTo(24),
    );
    await t.pumpWidget(const SizedBox());
  });
  final evidence = Platform.environment['COUNT_TOOLS_DAILY_VISUAL'];
  if (evidence != null) {
    testWidgets(
      'readable Flutter portrait management home ticket and keyboard previews',
      (t) async {
        expect(File('$evidence/.daily-acceptance.json').existsSync(), isTrue);
        for (final font in {
          'Roboto': 'C:/Windows/Fonts/msyh.ttc',
          'Ahem': 'C:/Windows/Fonts/msyh.ttc',
          'DailyPreview': 'C:/Windows/Fonts/msyh.ttc',
          'MaterialIcons':
              'C:/Users/Aphoe/.cache/count-tools-runtime/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          final loader = FontLoader(font.key)
            ..addFont(
              Future.value(
                ByteData.sublistView(File(font.value).readAsBytesSync()),
              ),
            );
          await t.runAsync(loader.load);
        }
        await t.runAsync(() async {
          await f.quantities();
          await f.finances();
          for (var i = 0; i < 16; i++) {
            await f.catalog.create(
              CatalogKind.group,
              name: i.isEven ? '星海计划$i' : 'Moonrise $i',
              operationId: 'g$i',
            );
          }
          for (var i = 0; i < 23; i++) {
            await f.identities.createMember(
              name: ['奈奈', 'Mito', '小夏', '长一点艺名', 'Luna'][i % 5],
              groupId: i.isEven ? f.groupA : f.groupB,
              colorRgb: 0x749dc9 + i * 87,
              operationId: 'm$i',
            );
          }
          await f.tickets.save(
            kind: 'definition',
            information: TicketInformation({
              'scope': 'personal',
              'group_id': f.groupA,
              'member_id': f.a,
              'signature': 'signed',
              'size_id': f.three,
              'active': true,
              'name': '旧原文保留',
            }),
            operationId: 'personal',
          );
        });
        final theme = chekiTheme();
        final readable = theme.copyWith(
          appBarTheme: theme.appBarTheme.copyWith(
            titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: 'DailyPreview',
            ),
          ),
          textTheme: theme.textTheme.apply(fontFamily: 'DailyPreview'),
          primaryTextTheme: theme.primaryTextTheme.apply(
            fontFamily: 'DailyPreview',
          ),
        );
        for (final page in <(String, double, double, Widget)>[
          (
            'home-360',
            360,
            1,
            Scaffold(
              body: RecordHomePage(store: f.records, ticketStore: f.tickets),
            ),
          ),
          (
            'members-360',
            360,
            1,
            IdentityListPage(kind: IdentityKind.member, store: f.identities),
          ),
          (
            'groups-360',
            360,
            1,
            CatalogListPage(kind: CatalogKind.group, store: f.catalog),
          ),
          ('tickets-360', 360, 1, TicketLibraryPage(store: f.tickets)),
          (
            'ticket-form-320-big',
            320,
            2,
            TicketEditPage(store: f.tickets, kind: 'definition'),
          ),
          ('record-form-320-big', 320, 2, RecordEditPage(store: f.records)),
        ]) {
          t.view.physicalSize = Size(page.$2, 960);
          t.view.devicePixelRatio = 1;
          t.view.viewInsets = FakeViewPadding(bottom: page.$3 == 2 ? 180 : 0);
          final key = GlobalKey();
          await t.pumpWidget(
            MaterialApp(
              theme: readable,
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(
                  c,
                ).copyWith(textScaler: TextScaler.linear(page.$3)),
                child: child!,
              ),
              home: RepaintBoundary(key: key, child: page.$4),
            ),
          );
          await settleIo(t);
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          await t.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '$evidence/${page.$1}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        }
        t.view.reset();
      },
    );
  }
}
