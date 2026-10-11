import 'dart:io';
import 'dart:ui' as ui;
import 'package:count_tools/cheki/domain/input_contract.dart';
import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/ui/input_fields.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget receiptHost({
  required ReceiptInput initial,
  required ValueChanged<ReceiptInput> changed,
  double scale = 1,
}) {
  var value = initial;
  return MaterialApp(
    theme: chekiTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: StatefulBuilder(
            builder: (context, setState) => ReceiptInputEditor(
              value: value,
              onChanged: (next) {
                setState(() {
                  value = next;
                });
                changed(next);
              },
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'default received hides actual time and partial reveals only receipt fields',
    (tester) async {
      ReceiptInput? result;
      await tester.pumpWidget(
        receiptHost(initial: ReceiptInput(), changed: (next) => result = next),
      );
      expect(find.text('已领取'), findsOneWidget);
      expect(find.text('实际领取时间'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('部分领取'));
      await tester.pumpAndSettle();
      expect(find.text('本次领取张数'), findsOneWidget);
      expect(find.text('实际领取时间'), findsOneWidget);
      expect(result!.batches.single.time, '');
      await tester.enterText(
        find.byKey(const ValueKey('receipt-quantity-input-0')),
        '1',
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('receipt-time-input-0')),
        '2026-10-11 18:30:00',
      );
      await tester.pump();
      expect(
        result!
            .validate(quantity: 3, occurredOn: OccurredOn.parse('2026-10-11'))
            .unreceivedQuantity,
        2,
      );
      await tester.tap(find.text('未领取'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('部分领取'));
      await tester.pump();
      expect(find.widgetWithText(TextField, '1'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, '2026-10-11 18:30:00'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'removing first receipt keeps the remaining batch controllers and raw invalid input',
    (tester) async {
      ReceiptInput? result;
      await tester.pumpWidget(
        receiptHost(
          initial: ReceiptInput(
            status: ReceiptStatus.partial,
            allowInitial: false,
            batches: [
              const ReceiptInputBatch(
                key: 'one',
                quantity: '1',
                time: '2026-10-11 18:30',
              ),
              const ReceiptInputBatch(
                key: 'two',
                quantity: 'invalid',
                time: 'unfinished',
              ),
            ],
          ),
          changed: (next) => result = next,
        ),
      );
      await tester.tap(find.byTooltip('移除第 1 次领取'));
      await tester.pump();
      expect(find.widgetWithText(TextField, 'invalid'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'unfinished'), findsOneWidget);
      expect(result!.batches.single.key, 'two');
      expect(
        () => result!.validate(
          quantity: 3,
          occurredOn: OccurredOn.parse('2026-10-11'),
        ),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'editing actual receipts retains their time; historical unknown does not invent one',
    (tester) async {
      final day = OccurredOn.parse('2026-10-11');
      final actual = ReceiptState(
        quantity: 1,
        occurredOn: day,
        batches: [
          ReceiptBatch(
            quantity: 1,
            origin: ReceiptOrigin.actual,
            receivedAt: DateTime.utc(2026, 10, 11, 1),
          ),
        ],
      );
      await tester.pumpWidget(
        receiptHost(initial: ReceiptInput.fromState(actual), changed: (_) {}),
      );
      expect(
        find.widgetWithText(TextField, '2026-10-11 09:00:00'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      final unknown = ReceiptState(
        quantity: 1,
        occurredOn: day,
        batches: [
          ReceiptBatch(quantity: 1, origin: ReceiptOrigin.legacyUnknown),
        ],
      );
      await tester.pumpWidget(
        receiptHost(initial: ReceiptInput.fromState(unknown), changed: (_) {}),
      );
      expect(find.text('历史领取时间未知'), findsOneWidget);
      expect(find.text('实际领取时间'), findsNothing);
    },
  );
  testWidgets(
    'occurrence and quantity show raw errors; cancelled date picker leaves input untouched',
    (tester) async {
      final date = TextEditingController(text: '2026-02-30');
      final quantity = TextEditingController(text: '1.5');
      addTearDown(date.dispose);
      addTearDown(quantity.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: chekiTheme(),
          home: Scaffold(
            body: Column(
              children: [
                OccurredOnField(
                  controller: date,
                  onChanged: (_) {},
                  error: occurrenceError(date.text),
                ),
                QuantityField(
                  controller: quantity,
                  onChanged: (_) {},
                  error: quantityError(quantity.text),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('发生日期无效'), findsOneWidget);
      expect(find.text('请输入正整数张数'), findsOneWidget);
      await tester.tap(find.byTooltip('选择发生日期'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(date.text, '2026-02-30');
      expect(quantity.text, '1.5');
      expect(find.text('发生时间'), findsNothing);
    },
  );
  testWidgets(
    'receipt time date cancellation leaves empty field instead of fabricating now',
    (tester) async {
      await tester.pumpWidget(
        receiptHost(
          initial: ReceiptInput(
            status: ReceiptStatus.partial,
            batches: [const ReceiptInputBatch(key: 'new')],
          ),
          changed: (_) {},
        ),
      );
      await tester.tap(find.byTooltip('选择实际领取时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('receipt-time-new')))
            .controller!
            .text,
        '',
      );
    },
  );
  testWidgets(
    'receipt clock cancellation after confirming its date preserves the original instant',
    (tester) async {
      const original = '2026-10-11 18:30:00.123456';
      var value = ReceiptInput(
        status: ReceiptStatus.partial,
        batches: [
          const ReceiptInputBatch(key: 'clock', quantity: '1', time: original),
        ],
      );
      await tester.pumpWidget(
        receiptHost(initial: value, changed: (next) => value = next),
      );
      await tester.tap(find.byTooltip('选择实际领取时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(value.batches.single.time, original);
      expect(find.widgetWithText(TextField, original), findsOneWidget);
    },
  );
  testWidgets(
    '320 and 430 large text and keyboard keep receipt fields scrollable and save reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      for (final width in [320.0, 430.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpWidget(
          MaterialApp(
            theme: chekiTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: ReceiptInputEditor(
                        value: ReceiptInput(
                          status: ReceiptStatus.partial,
                          allowInitial: false,
                          batches: [
                            const ReceiptInputBatch(
                              key: 'large',
                              quantity: '1',
                            ),
                          ],
                        ),
                        error: '请填写实际领取时间，输入已保留',
                        onChanged: (_) {},
                      ),
                    ),
                  ),
                  FilledButton(onPressed: () {}, child: const Text('核对')),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('核对').hitTestable(), findsOneWidget);
        expect(tester.getRect(find.text('核对')).bottom, lessThanOrEqualTo(620));
        await tester.ensureVisible(find.text('请填写实际领取时间，输入已保留'));
        await tester.pumpAndSettle();
        expect(find.text('请填写实际领取时间，输入已保留').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
  final evidence = Platform.environment['COUNT_TOOLS_UI_EVIDENCE'];
  if (evidence != null) {
    testWidgets('synthetic shared inputs visual evidence', (tester) async {
      final root = Directory(evidence).absolute;
      expect(root.path.startsWith(Directory.current.absolute.path), isFalse);
      expect(File('${root.path}/.cheki-ui-evidence').existsSync(), isTrue);
      final font = Platform.environment['COUNT_TOOLS_UI_FONT'];
      final icons = Platform.environment['COUNT_TOOLS_UI_ICON_FONT'];
      for (final entry in {
        'InputPreview': font,
        'MaterialIcons': icons,
      }.entries) {
        if (entry.value == null) continue;
        final loader = FontLoader(entry.key);
        loader.addFont(
          Future.value(
            ByteData.sublistView(File(entry.value!).readAsBytesSync()),
          ),
        );
        await tester.runAsync(loader.load);
      }
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final scale in [1.0, 2.0]) {
        final key = GlobalKey();
        final date = TextEditingController(text: '2026-10-11');
        final quantity = TextEditingController(text: '3');
        final theme = chekiTheme();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.copyWith(
              appBarTheme: theme.appBarTheme.copyWith(
                titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                  fontFamily: font == null ? null : 'InputPreview',
                ),
              ),
              textTheme: theme.textTheme.apply(
                fontFamily: font == null ? null : 'InputPreview',
              ),
            ),
            builder: (context, child) => RepaintBoundary(
              key: key,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
            ),
            home: Scaffold(
              appBar: AppBar(title: const Text('记录输入预览')),
              body: SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OccurredOnField(
                              controller: date,
                              onChanged: (_) {},
                            ),
                            const SizedBox(height: 16),
                            QuantityField(
                              controller: quantity,
                              onChanged: (_) {},
                            ),
                            const SizedBox(height: 24),
                            ReceiptInputEditor(
                              value: ReceiptInput(
                                status: ReceiptStatus.partial,
                                batches: [
                                  const ReceiptInputBatch(
                                    key: 'visual',
                                    quantity: '1',
                                  ),
                                ],
                              ),
                              onChanged: (_) {},
                              error: '请填写实际领取时间',
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () {},
                          child: const Text('核对'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (scale == 2) {
          await tester.ensureVisible(find.text('请填写实际领取时间'));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final screenshot =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await screenshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          File(
            '${root.path}/inputs-320-${scale.toInt()}x.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          screenshot.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        date.dispose();
        quantity.dispose();
      }
    });
  }
}
