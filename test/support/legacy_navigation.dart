import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:count_tools/cheki/ui/catalog_pages.dart';
import 'settle_io.dart';

/// Old-page regression uses the explicit internal boundary, never a user switch.
Future<void> openLegacyManagement(WidgetTester tester) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
  unawaited(
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => CatalogManagementPage(showLegacy: true),
      ),
    ),
  );
  await settleIo(tester);
}
