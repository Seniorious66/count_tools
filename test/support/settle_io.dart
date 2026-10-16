import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pump frames AND yield to the OS event loop while filesystem/SQLite futures
/// are active. pumpAndSettle alone advances fake time and can starve real IO.
/// Never fall back to fake-clock settling with an indeterminate spinner alive.
Future<void> settleIo(
  WidgetTester tester, {
  bool Function()? until,
  Duration budget = const Duration(seconds: 20),
}) async {
  final watch = Stopwatch()..start();
  var quiet = 0;
  do {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.takeException(), isNull);
    final busy =
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
        find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
    if (!busy && !tester.binding.hasScheduledFrame && (until?.call() ?? true)) {
      if (++quiet >= 5) return;
    } else {
      quiet = 0;
    }
  } while (watch.elapsed < budget);
  fail(
    'Real IO did not settle within $budget '
    '(circular=${find.byType(CircularProgressIndicator).evaluate().length}, '
    'linear=${find.byType(LinearProgressIndicator).evaluate().length}, '
    'frame=${tester.binding.hasScheduledFrame}, '
    'expectedState=${until?.call() ?? true}).',
  );
}
