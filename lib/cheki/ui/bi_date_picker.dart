import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../data/bi_query.dart';

/// Calendar edits are route-local until the standard confirmation action.
/// This also serves member drill-down, whose allowed interval is narrower.
Future<String?> chooseBiDate(
  BuildContext context,
  String initial, {
  String? from,
  String? through,
  String? today,
}) async {
  var selected = DateTime.parse(initial);
  final picked = await showDialog<DateTime>(
    context: context,
    builder: (context) => Localizations.override(
      context: context,
      locale: const Locale('zh', 'CN'),
      delegates: GlobalMaterialLocalizations.delegates,
      child: StatefulBuilder(
        builder: (context, update) => Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 24,
          ),
          constraints: const BoxConstraints(maxWidth: 400),
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('选择日期'),
                    ),
                    // Integer viewport width prevents precision drift over the
                    // full supported 0001..9999 month range on narrow screens.
                    SizedBox(
                      width: (box.maxWidth - 16).floorToDouble(),
                      child: Theme(
                        // The M3 calendar adds eight pixels of padding per day,
                        // wrapping two-digit dates at 200% on narrow portraits.
                        // Keep the app's body font and full text scaling, using
                        // the standard padding-free calendar presentation.
                        data: ThemeData(
                          useMaterial3: false,
                          colorScheme: Theme.of(context).colorScheme,
                          textTheme: Theme.of(context).textTheme,
                          datePickerTheme: DatePickerTheme.of(context).copyWith(
                            dayStyle: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        child: CalendarDatePicker(
                          initialDate: selected,
                          currentDate: today == null
                              ? null
                              : DateTime.parse(today),
                          firstDate: DateTime.parse(from ?? '0001-01-01'),
                          lastDate: DateTime.parse(through ?? '9999-12-31'),
                          onDateChanged: (day) => update(() => selected = day),
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, selected),
                          child: const Text('确定'),
                        ),
                      ],
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
  return picked == null ? null : biDay(picked);
}
