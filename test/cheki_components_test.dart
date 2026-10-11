import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/ui/components.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/cheki/ui/ticket_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {double scale = 1}) => MaterialApp(
  theme: chekiTheme(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    ),
  ),
);

TicketAvailabilityView stock({
  int long = 8,
  int limited = 0,
  String name = '晨星 · 通用券',
}) => TicketAvailabilityView(
  ticketId: 'fixture-ticket',
  ticketName: name,
  pools: [
    TicketPoolView(id: 'long', kind: TicketPoolKind.longTerm, available: long),
    TicketPoolView(
      id: 'limited',
      kind: TicketPoolKind.limited,
      available: limited,
      expiresOn: OccurredOn.parse('2026-10-15'),
    ),
  ],
);

void main() {
  test('text and actionable outline contrasts meet the design targets', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05));
    }

    for (final pair in [
      [ChekiColors.ink, ChekiColors.surface],
      [ChekiColors.muted, ChekiColors.surface],
      [ChekiColors.blueInk, ChekiColors.blue],
      [ChekiColors.pinkInk, ChekiColors.pink],
      [ChekiColors.danger, ChekiColors.dangerSurface],
    ]) {
      expect(contrast(pair[0], pair[1]), greaterThanOrEqualTo(4.5));
    }
    expect(
      contrast(ChekiColors.inputBorder, ChekiColors.surface),
      greaterThanOrEqualTo(3),
    );
  });
  testWidgets(
    'exclusive checked controls, disabled back signature and no hidden restoration',
    (tester) async {
      var value = ChekiAttributes();
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => AttributeSelector(
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      );
      await tester.tap(find.text('有签'));
      await tester.tap(find.text('背签'));
      await tester.pump();
      expect(value.backSigned, isTrue);
      for (final label in ['宿题', '无签']) {
        await tester.tap(find.text(label));
        await tester.pump();
        expect(value.backSigned, isFalse);
        final semantics = tester.getSemantics(
          find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == '背签',
          ),
        );
        expect(semantics.flagsCollection.isEnabled, ui.Tristate.isFalse);
        await tester.tap(find.text('背签'));
        await tester.pump();
        expect(value.backSigned, isFalse);
        await tester.tap(find.text('有签'));
        await tester.pump();
        expect(value.backSigned, isFalse);
      }
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 390.0, 430.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('attributes and member text fit width $width scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          host(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AttributeSelector(value: ChekiAttributes(), onChanged: (_) {}),
                const SizedBox(height: 24),
                const MemberLabel(
                  group: '很长的团体名称',
                  name: '很长的成员名称和当时的艺名',
                  color: Colors.white,
                ),
              ],
            ),
            scale: scale,
          ),
        );
        if (scale == 1) {
          final y = tester.getTopLeft(find.text('无签')).dy;
          for (final label in ['有签', '宿题', '背签']) {
            expect(tester.getTopLeft(find.text(label)).dy, y);
          }
        }
        for (final label in ['无签', '有签', '宿题', '背签']) {
          final ink = find.ancestor(
            of: find.text(label),
            matching: find.byType(InkWell),
          );
          expect(tester.getSize(ink).height, greaterThanOrEqualTo(44));
          expect(tester.getSize(ink).width, greaterThanOrEqualTo(44));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'shell only exposes provided features and preserves page state on switching',
    (tester) async {
      final input = TextEditingController();
      addTearDown(input.dispose);
      var managed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: ChekiShell(
            onManage: () => managed++,
            destinations: [
              ChekiDestination(
                label: '首页',
                icon: Icons.home_outlined,
                page: TextField(controller: input),
              ),
              const ChekiDestination(
                label: '记录',
                icon: Icons.notes,
                page: Text('记录服务入口'),
              ),
            ],
          ),
        ),
      );
      expect(find.text('券库'), findsNothing);
      expect(find.text('统计'), findsNothing);
      await tester.enterText(find.byType(TextField), '保留的输入');
      await tester.tap(find.text('记录'));
      await tester.pumpAndSettle();
      expect(find.text('记录服务入口'), findsOneWidget);
      await tester.tap(find.text('首页'));
      await tester.pumpAndSettle();
      expect(find.text('保留的输入'), findsOneWidget);
      await tester.tap(find.byTooltip('打开管理'));
      expect(managed, 1);
    },
  );
  testWidgets(
    'long-only and zero snapshots suppress unrelated pool labels; loading is not zero',
    (tester) async {
      await tester.pumpWidget(host(TicketAvailabilityCard(value: null)));
      expect(find.text('0 张'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      for (final count in [8, 0]) {
        await tester.pumpWidget(
          host(TicketAvailabilityCard(value: stock(long: count))),
        );
        expect(find.text('$count 张'), findsOneWidget);
        expect(find.textContaining('限时'), findsNothing);
        expect(find.textContaining('长期'), findsNothing);
      }
      await tester.pumpWidget(
        host(TicketAvailabilityCard(value: stock(long: 0, limited: 2))),
      );
      expect(find.textContaining('2026-10-15'), findsOneWidget);
      expect(find.textContaining('长期'), findsNothing);
    },
  );
  testWidgets(
    'mixed pool editor remains open, amounts are independent, single-pool ticket unaffected',
    (tester) async {
      var quantities = {'long': '1', 'limited': '4'};
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TicketAllocationEditor(
                  value: stock(limited: 4, name: '晨星 · A基础券'),
                  quantities: quantities,
                  needed: 5,
                  onChanged: (id, text) =>
                      setState(() => quantities = {...quantities, id: text}),
                ),
                TicketAllocationEditor(
                  value: stock(long: 2),
                  quantities: const {'long': '2'},
                  needed: 2,
                  onChanged: (_, _) {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byType(TextField), findsNWidgets(3));
      await tester.enterText(find.byType(TextField).at(1), '2');
      await tester.pump();
      expect(quantities['long'], '1');
      expect(find.text('! 还差 2 张'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '3');
      await tester.pump();
      expect(quantities['limited'], '2');
      expect(find.textContaining('还差'), findsNothing);
      expect(find.text('可用 2'), findsOneWidget);
      expect(find.text('长期 2'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'confirmation excludes zero usages but historical positive limited usage stays visible',
    (tester) async {
      await tester.pumpWidget(
        host(
          TicketUsageList(
            usages: [
              TicketUsageView(
                ticketId: 'morning-general',
                ticketName: '晨星 · 通用券',
                poolKind: TicketPoolKind.longTerm,
                quantity: 2,
              ),
              TicketUsageView(
                ticketId: 'morning-general',
                ticketName: '晨星 · 通用券',
                poolKind: TicketPoolKind.limited,
                quantity: 0,
                expiresOn: OccurredOn.parse('2026-10-15'),
              ),
              TicketUsageView(
                ticketId: 'night-basic',
                ticketName: '夜航 · 基础券',
                poolKind: TicketPoolKind.limited,
                quantity: 1,
                expiresOn: OccurredOn.parse('2025-01-01'),
              ),
            ],
          ),
        ),
      );
      expect(find.text('晨星 · 通用券 · 2 张'), findsOneWidget);
      expect(find.textContaining('2025-01-01'), findsOneWidget);
      expect(find.textContaining('2026-10-15'), findsNothing);
      expect(find.textContaining('长期'), findsNothing);
    },
  );
  testWidgets(
    'allocation remains reachable at narrow width with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        host(
          Column(
            children: [
              const SizedBox(height: 260),
              TicketAllocationEditor(
                value: stock(limited: 2),
                quantities: const {'long': '1', 'limited': '1'},
                needed: 2,
                onChanged: (_, _) {},
              ),
              FilledButton(onPressed: () {}, child: const Text('核对')),
            ],
          ),
          scale: 2,
        ),
      );
      await tester.ensureVisible(find.text('核对'));
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.text('核对')).dy, lessThan(620));
      await tester.tap(find.text('核对'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'confirmation pool labels use the selected ticket ID and its available pools',
    (tester) async {
      final snapshot = stock(limited: 1);
      await tester.pumpWidget(
        host(
          TicketUsageList(
            availabilityByTicket: {snapshot.ticketId: snapshot},
            usages: [
              TicketUsageView(
                ticketId: snapshot.ticketId,
                ticketName: snapshot.ticketName,
                poolKind: TicketPoolKind.longTerm,
                quantity: 1,
              ),
              TicketUsageView(
                ticketId: 'other-same-name',
                ticketName: snapshot.ticketName,
                poolKind: TicketPoolKind.longTerm,
                quantity: 2,
              ),
            ],
          ),
        ),
      );
      expect(find.text('晨星 · 通用券 · 长期 · 1 张'), findsOneWidget);
      expect(find.text('晨星 · 通用券 · 2 张'), findsOneWidget);
      expect(find.textContaining('限时'), findsNothing);
    },
  );
  final evidenceRoot = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  if (evidenceRoot != null) {
    testWidgets('temporary component visual evidence, synthetic only', (
      tester,
    ) async {
      final dir = Directory(evidenceRoot);
      if (!dir.existsSync() ||
          !File('${dir.path}/.cheki-ui-evidence').existsSync()) {
        throw StateError(
          'Evidence output must be an explicitly marked external directory',
        );
      }
      final font = Platform.environment['COUNT_TOOLS_UI_FONT'];
      final icons = Platform.environment['COUNT_TOOLS_UI_ICON_FONT'];
      if (icons != null) {
        final loader = FontLoader('MaterialIcons');
        loader.addFont(
          Future.value(ByteData.sublistView(File(icons).readAsBytesSync())),
        );
        await tester.runAsync(loader.load);
      }
      if (font != null) {
        final loader = FontLoader('ChekiPreview');
        loader.addFont(
          Future.value(ByteData.sublistView(File(font).readAsBytesSync())),
        );
        await tester.runAsync(loader.load);
      }
      for (final scale in [1.0, 2.0]) {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme().copyWith(
              textTheme: chekiTheme().textTheme.apply(
                fontFamily: font == null ? null : 'ChekiPreview',
              ),
            ),
            home: RepaintBoundary(
              key: key,
              child: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('组件预览 · 合成数据'),
                          const SizedBox(height: 16),
                          AttributeSelector(
                            value: ChekiAttributes(backSigned: true),
                            onChanged: (_) {},
                          ),
                          const SizedBox(height: 16),
                          TicketAvailabilityCard(value: stock()),
                          const SizedBox(height: 16),
                          TicketAllocationEditor(
                            value: stock(limited: 4),
                            quantities: const {'long': '1', 'limited': '4'},
                            needed: 5,
                            onChanged: (_, _) {},
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${dir.path}/components-320-${scale.toInt()}x.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }
}
