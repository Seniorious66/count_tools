import 'package:flutter/material.dart';

/// Explicit edits only: a blank stays unknown until the user presses +.
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    required this.controller,
    required this.fieldKey,
    this.label = '张数',
    this.enabled = true,
    super.key,
  });
  final TextEditingController controller;
  final Key fieldKey;
  final String label;
  final bool enabled;
  static const maximum = 1000000000;
  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final text = value.text.trim(), n = int.tryParse(text);
          final valid = n != null && n > 0 && n <= maximum;
          void write(int q) {
            final next = '$q';
            controller.value = TextEditingValue(
              text: next,
              selection: TextSelection.collapsed(offset: next.length),
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                tooltip: '减少一张',
                onPressed: enabled && valid && n > 1
                    ? () => write(n - 1)
                    : null,
                icon: const Icon(Icons.remove),
              ),
              Expanded(
                child: TextField(
                  key: fieldKey,
                  controller: controller,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: label,
                    suffixText: '张',
                    errorText: text.isNotEmpty && !valid ? '张数须为正整数' : null,
                    suffixIcon: IconButton(
                      tooltip: '清空张数',
                      onPressed: enabled ? controller.clear : null,
                      icon: const Icon(Icons.clear),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '增加一张',
                onPressed: enabled && (text.isEmpty || valid && n < maximum)
                    ? () => write(text.isEmpty ? 1 : n! + 1)
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          );
        },
      );
}
