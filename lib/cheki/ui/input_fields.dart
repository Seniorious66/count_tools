import 'package:flutter/material.dart';
import '../domain/input_contract.dart';
import '../domain/record_contract.dart';

String? occurrenceError(String value) {
  try {
    OccurredOn.parse(value);
    return null;
  } on FormatException catch (error) {
    return error.message;
  }
}

String? quantityError(String value) {
  try {
    parsePositiveQuantity(value);
    return null;
  } on FormatException catch (error) {
    return error.message;
  }
}

class OccurredOnField extends StatelessWidget {
  const OccurredOnField({
    required this.controller,
    required this.onChanged,
    this.error,
    this.enabled = true,
    super.key,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? error;
  final bool enabled;
  Future<void> _pick(BuildContext context) async {
    DateTime initial = DateTime.now().toUtc().add(const Duration(hours: 8));
    try {
      initial = DateTime.parse(OccurredOn.parse(controller.text).value);
    } on FormatException {
      /* Preserve raw input if cancelled. */
    }
    final chosen = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
      cancelText: '取消',
      confirmText: '确定',
    );
    if (chosen == null || !context.mounted) return;
    final text =
        '${chosen.year.toString().padLeft(4, '0')}-${chosen.month.toString().padLeft(2, '0')}-${chosen.day.toString().padLeft(2, '0')}';
    controller.text = text;
    onChanged(text);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    keyboardType: TextInputType.datetime,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: '发生日期',
      hintText: 'YYYY-MM-DD',
      errorText: error,
      errorMaxLines: 3,
      suffixIcon: IconButton(
        tooltip: '选择发生日期',
        onPressed: enabled ? () => _pick(context) : null,
        icon: const Icon(Icons.calendar_today),
      ),
    ),
  );
}

class QuantityField extends StatelessWidget {
  const QuantityField({
    required this.controller,
    required this.onChanged,
    this.error,
    this.enabled = true,
    super.key,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? error;
  final bool enabled;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    keyboardType: TextInputType.number,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: '张数',
      errorText: error,
      errorMaxLines: 3,
    ),
  );
}

class ReceiptInputEditor extends StatefulWidget {
  const ReceiptInputEditor({
    required this.value,
    required this.onChanged,
    this.error,
    this.enabled = true,
    super.key,
  });
  final ReceiptInput value;
  final ValueChanged<ReceiptInput> onChanged;
  final String? error;
  final bool enabled;
  @override
  State<ReceiptInputEditor> createState() => _ReceiptInputEditorState();
}

class _ReceiptInputEditorState extends State<ReceiptInputEditor> {
  final _quantities = <String, TextEditingController>{},
      _times = <String, TextEditingController>{};
  var _next = 0;
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ReceiptInputEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final keys = widget.value.batches.map((b) => b.key).toSet();
    for (final controllers in [_quantities, _times]) {
      for (final key
          in controllers.keys.where((key) => !keys.contains(key)).toList()) {
        controllers.remove(key)!.dispose();
      }
    }
    for (final batch in widget.value.batches) {
      for (final pair in [
        (_quantities, batch.quantity),
        (_times, batch.time),
      ]) {
        final controller = pair.$1.putIfAbsent(
          batch.key,
          () => TextEditingController(),
        );
        if (controller.text != pair.$2) {
          controller.value = TextEditingValue(
            text: pair.$2,
            selection: TextSelection.collapsed(offset: pair.$2.length),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    for (final controller in [..._quantities.values, ..._times.values]) {
      controller.dispose();
    }
    super.dispose();
  }

  ReceiptInputBatch _empty() {
    String key;
    do {
      key = 'input-${_next++}';
    } while (widget.value.batches.any((b) => b.key == key));
    return ReceiptInputBatch(key: key);
  }

  void _select(ReceiptStatus status) {
    var next = widget.value.select(status);
    if (next.needsBatches && next.batches.isEmpty) {
      next = next.replaceBatches([_empty()]);
    }
    widget.onChanged(next);
  }

  void _change(ReceiptInputBatch batch, {String? quantity, String? time}) =>
      widget.onChanged(
        widget.value.replaceBatches([
          for (final b in widget.value.batches)
            b.key == batch.key ? b.copyWith(quantity: quantity, time: time) : b,
        ]),
      );
  Future<void> _pickTime(ReceiptInputBatch batch) async {
    DateTime initial;
    try {
      initial = parseReceiptTime(batch.time).add(const Duration(hours: 8));
    } on FormatException {
      initial = DateTime.now().toUtc().add(const Duration(hours: 8));
    }
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
      cancelText: '取消',
      confirmText: '确定',
    );
    if (!mounted || date == null || !widget.enabled) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
      cancelText: '取消',
      confirmText: '确定',
    );
    if (!mounted || time == null || !widget.enabled) return;
    if (!widget.value.batches.any((b) => b.key == batch.key)) return;
    _change(
      batch,
      time: receiptTimeText(
        DateTime.utc(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ).subtract(const Duration(hours: 8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('领取状态'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final status in ReceiptStatus.values)
            ChoiceChip(
              label: Text(status.label),
              selected: widget.value.status == status,
              onSelected: widget.enabled ? (_) => _select(status) : null,
              materialTapTargetSize: MaterialTapTargetSize.padded,
            ),
        ],
      ),
      if (widget.value.needsBatches) ...[
        for (final (index, batch) in widget.value.batches.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              key: ValueKey(batch.key),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('第 ${index + 1} 次领取')),
                    IconButton(
                      tooltip: '移除第 ${index + 1} 次领取',
                      onPressed: widget.enabled
                          ? () => widget.onChanged(
                              widget.value.replaceBatches(
                                widget.value.batches
                                    .where((b) => b.key != batch.key)
                                    .toList(),
                              ),
                            )
                          : null,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                TextField(
                  key: ValueKey('receipt-quantity-${batch.key}'),
                  controller: _quantities[batch.key],
                  enabled: widget.enabled,
                  keyboardType: TextInputType.number,
                  onChanged: (raw) => _change(batch, quantity: raw),
                  decoration: const InputDecoration(labelText: '本次领取张数'),
                ),
                const SizedBox(height: 12),
                if (batch.origin == ReceiptOrigin.legacyUnknown)
                  const Text('历史领取时间未知')
                else
                  TextField(
                    key: ValueKey('receipt-time-${batch.key}'),
                    controller: _times[batch.key],
                    enabled: widget.enabled,
                    keyboardType: TextInputType.datetime,
                    onChanged: (raw) => _change(batch, time: raw),
                    decoration: InputDecoration(
                      labelText: '实际领取时间',
                      hintText: 'YYYY-MM-DD HH:mm:ss',
                      suffixIcon: IconButton(
                        tooltip: '选择实际领取时间',
                        onPressed: widget.enabled
                            ? () => _pickTime(batch)
                            : null,
                        icon: const Icon(Icons.schedule),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.enabled
                ? () => widget.onChanged(
                    widget.value.replaceBatches([
                      ...widget.value.batches,
                      _empty(),
                    ]),
                  )
                : null,
            icon: const Icon(Icons.add),
            label: const Text('添加领取批次'),
          ),
        ),
      ],
      if (widget.error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            widget.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );
}
