import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/settle_io.dart';

void main() {
  testWidgets('real IO completion advances while fake animated frames pump', (
    t,
  ) async {
    final result = Completer<String>();
    await t.pumpWidget(
      MaterialApp(
        home: FutureBuilder<String>(
          future: result.future,
          builder: (_, s) =>
              s.hasData ? Text(s.data!) : const LinearProgressIndicator(),
        ),
      ),
    );
    await t.runAsync(() async {
      Timer(const Duration(milliseconds: 250), () => result.complete('真实完成'));
    });
    await settleIo(t, until: () => find.text('真实完成').evaluate().isNotEmpty);
    expect(find.text('真实完成'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
  testWidgets(
    'persistent busy fails promptly instead of fake ten minute fallback',
    (t) async {
      await t.pumpWidget(const MaterialApp(home: CircularProgressIndicator()));
      await expectLater(
        settleIo(t, budget: const Duration(milliseconds: 120)),
        throwsA(
          isA<TestFailure>().having(
            (e) => e.message,
            'diagnostic',
            contains('circular=1'),
          ),
        ),
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'expected state prevents a quiet gap from masquerading as completion',
    (t) async {
      await t.pumpWidget(const MaterialApp(home: Text('尚未完成')));
      var completed = false;
      await t.runAsync(() async {
        Timer(const Duration(milliseconds: 250), () => completed = true);
      });
      await settleIo(t, until: () => completed);
      expect(completed, true);
    },
  );
}
