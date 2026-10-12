import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/catalog_store.dart' show newOperationId;
import '../domain/record_contract.dart';
import '../domain/record_information.dart';
import 'components.dart';

/// Keeps original missing keys, extensions and precise instants unless edited.
class ReceiptBatchInput {
  ReceiptBatchInput(Map<String, Object?> raw)
    : original = Map<String, Object?>.from(jsonDecode(jsonEncode(raw)) as Map),
      key = newOperationId() {
    quantity = original['quantity']?.toString() ?? '';
    origin = original['origin'] as String?;
    time = timeLabel(original['received_at'] as String?);
  }
  final Map<String, Object?> original;
  final String key;
  late String quantity, time;
  String? origin;
  static String timeLabel(String? stamp) => stamp == null
      ? ''
      : DateTime.parse(stamp)
            .toUtc()
            .add(const Duration(hours: 8))
            .toIso8601String()
            .substring(0, 19)
            .replaceFirst('T', ' ');
  static int? number(String s) => s.trim().isEmpty
      ? null
      : int.tryParse(s.trim()) ??
            (throw const FormatException('领取张数须为整数，未知请留空'));
  static String? instant(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$').hasMatch(s)) {
      throw const FormatException('领取时间请填写 年-月-日 时:分:秒，或留空后补');
    }
    final day = OccurredOn.parse(s.substring(0, 10));
    if (int.parse(s.substring(11, 13)) > 23 ||
        int.parse(s.substring(14, 16)) > 59 ||
        int.parse(s.substring(17, 19)) > 59) {
      throw const FormatException('领取时间无效');
    }
    return DateTime.parse(
      '${day.value}T${s.substring(11)}.000Z',
    ).subtract(const Duration(hours: 8)).toIso8601String();
  }

  Map<String, Object?> toMap() => {
    ...Map<String, Object?>.from(jsonDecode(jsonEncode(original)) as Map),
    if (quantity != (original['quantity']?.toString() ?? ''))
      'quantity': number(quantity),
    if (origin != original['origin']) 'origin': origin,
    if (time != timeLabel(original['received_at'] as String?))
      'received_at': instant(time),
  };
}

/// Draft changes stay outside SQLite until the existing review/save transaction.
class ReceiptEditController extends ChangeNotifier {
  ReceiptEditController(this.initial, {required this.clock}) {
    final raw = initial.toMap()['receipt_batches'];
    entries = raw is List
        ? [
            for (final b in raw)
              ReceiptBatchInput(Map<String, Object?>.from(b as Map)),
          ]
        : [];
    selected = initial.receiptStatus;
    _shortcut = entries.length == 1 && entries.single.origin == 'initial';
    _userStatus = _shortcut && selected == ReceiptStatus.received;
    if (_shortcut) _initialCopy = entries.single.original;
    _total = initial.quantity;
  }
  final RecordInformation initial;
  final DateTime Function() clock;
  late List<ReceiptBatchInput> entries;
  ReceiptStatus? selected;
  int? _total;
  bool _changed = false, _suppressed = false, _shortcut = false;
  bool _batchEdited = false, _converted = false;
  bool _userStatus = false;
  Map<String, Object?>? _initialCopy;
  bool get changed => _changed;
  bool get shortcut => _shortcut && !_suppressed;
  bool get showEntries => !_suppressed && !shortcut;
  bool get hasInformation =>
      initial.toMap()['receipt_batches'] != null || entries.isNotEmpty;
  void updateTotal(int? total) {
    _total = total;
    if (!shortcut && !_suppressed) _deriveStatus();
    notifyListeners();
  }

  void _deriveStatus() {
    if (entries.isEmpty &&
        initial.toMap()['receipt_batches'] is! List &&
        !_batchEdited) {
      return; // An empty editing cache is not a known zero-receipt fact.
    }
    if (_total == null ||
        entries.any(
          (b) =>
              int.tryParse(b.quantity.trim()) == null ||
              int.parse(b.quantity.trim()) <= 0,
        )) {
      if (!_userStatus) {
        final hint = initial.toMap()['receipt_status_hint'];
        selected = hint == null
            ? null
            : ReceiptStatus.values.singleWhere((s) => s.name == hint);
      }
      return;
    }
    final sum = entries.fold<int>(
      0,
      (s, b) => s + int.parse(b.quantity.trim()),
    );
    if (sum > _total!) return;
    final next = sum == 0
        ? ReceiptStatus.unreceived
        : sum == _total
        ? ReceiptStatus.received
        : ReceiptStatus.partial;
    if (selected != next) {
      selected = next;
      _changed = true;
    }
  }

  void clear() {
    selected = null;
    _suppressed = true;
    _changed = true;
    _userStatus = true;
    notifyListeners();
  }

  void select(ReceiptStatus? next) {
    if (next == null) {
      clear();
      return;
    }
    if (next == selected && !_suppressed) return;
    _changed = true;
    selected = next;
    _userStatus = true;
    _suppressed = next == ReceiptStatus.unreceived;
    if (next == ReceiptStatus.partial && _shortcut) {
      entries = [
        ReceiptBatchInput({
          ...entries.single.original,
          'quantity': null,
          'origin': 'actual',
          'received_at': null,
        }),
      ];
      _shortcut = false;
      _converted = true;
    } else if (next == ReceiptStatus.received && _converted && !_batchEdited) {
      entries = [ReceiptBatchInput(_initialCopy!)];
      _shortcut = true;
      _converted = false;
    }
    if (!_suppressed && entries.isEmpty) {
      entries.add(
        ReceiptBatchInput({
          'quantity': null,
          'origin': 'actual',
          'received_at': null,
        }),
      );
    }
    notifyListeners();
  }

  void exposeInitial({bool actualTime = false}) {
    if (!shortcut) return;
    final raw = _buildEntries(_total).single;
    entries = [
      ReceiptBatchInput({...raw, if (actualTime) 'origin': 'actual'}),
    ];
    _shortcut = false;
    _batchEdited = true;
    _changed = true;
    notifyListeners();
  }

  void add() {
    if (shortcut) exposeInitial();
    if (entries.any((e) => e.origin == 'initial')) return;
    _suppressed = false;
    _changed = true;
    _batchEdited = true;
    entries.add(
      ReceiptBatchInput({
        'quantity': null,
        'origin': 'actual',
        'received_at': clock().toUtc().toIso8601String(),
      }),
    );
    if (selected == ReceiptStatus.unreceived) selected = null;
    notifyListeners();
  }

  void remove(ReceiptBatchInput entry) {
    entries.remove(entry);
    _changed = true;
    _batchEdited = true;
    _deriveStatus();
    notifyListeners();
  }

  void change(
    ReceiptBatchInput entry, {
    String? quantity,
    String? time,
    String? origin,
    bool changeOrigin = false,
  }) {
    if (quantity != null) entry.quantity = quantity;
    if (time != null) entry.time = time;
    if (changeOrigin) entry.origin = origin;
    _changed = true;
    _batchEdited = true;
    _deriveStatus();
    notifyListeners();
  }

  List<Map<String, Object?>> _buildEntries(int? total) => [
    for (final e in entries)
      {
        ...e.toMap(),
        if (shortcut &&
            total != initial.quantity &&
            e.original['quantity'] != null)
          'quantity': total,
      },
  ];
  Map<String, Object?> patch(int? total) {
    final align =
        shortcut &&
        total != initial.quantity &&
        entries.single.original['quantity'] != null;
    if (!_changed && !align) return {};
    final raw = initial.toMap();
    final data = _suppressed
        ? selected == ReceiptStatus.unreceived
              ? <Object?>[]
              : null
        : _buildEntries(total);
    return {
      if (jsonEncode(data) != jsonEncode(raw['receipt_batches']))
        'receipt_batches': data,
      if (_userStatus ||
          align ||
          (raw['receipt_status_hint'] != null &&
              raw['receipt_status_hint'] != selected?.name))
        'receipt_status_hint': selected?.name,
    };
  }
}

class ReceiptEditor extends StatelessWidget {
  const ReceiptEditor({
    required this.controller,
    required this.existing,
    super.key,
  });
  final ReceiptEditController controller;
  final bool existing;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('record-receipt-${controller.selected?.name}'),
          initialValue: controller.selected?.name ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: '领取状态'),
          items: [
            const DropdownMenuItem(value: '', child: Text('未填写')),
            for (final s in ReceiptStatus.values)
              DropdownMenuItem(value: s.name, child: Text(s.label)),
          ],
          onChanged: (v) => controller.select(
            v == ''
                ? null
                : ReceiptStatus.values.singleWhere((s) => s.name == v),
          ),
        ),
        if (controller.shortcut) ...[
          const SizedBox(height: 12),
          const Text('初始已领取，不设实际领取时间'),
          TextButton(
            onPressed: () => controller.exposeInitial(),
            child: const Text('编辑初始领取信息'),
          ),
          if (existing)
            TextButton(
              onPressed: () => controller.exposeInitial(actualTime: true),
              child: const Text('补填实际领取时间'),
            ),
        ],
        if (controller.showEntries)
          for (final e in controller.entries) ...[
            const SizedBox(height: 12),
            _ReceiptBatchFields(
              key: ValueKey(e.key),
              entry: e,
              controller: controller,
              position: controller.entries.indexOf(e),
            ),
          ],
        if (!controller.shortcut)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              onPressed: controller.entries.any((e) => e.origin == 'initial')
                  ? null
                  : controller.add,
              icon: const Icon(Icons.add),
              label: const Text('添加领取批次'),
            ),
          ),
        if (controller.hasInformation)
          TextButton(onPressed: controller.clear, child: const Text('领取信息留空')),
      ],
    ),
  );
}

class _ReceiptBatchFields extends StatefulWidget {
  const _ReceiptBatchFields({
    required this.entry,
    required this.controller,
    required this.position,
    super.key,
  });
  final ReceiptBatchInput entry;
  final ReceiptEditController controller;
  final int position;
  @override
  State<_ReceiptBatchFields> createState() => _ReceiptBatchFieldsState();
}

class _ReceiptBatchFieldsState extends State<_ReceiptBatchFields> {
  late final _quantity = TextEditingController(text: widget.entry.quantity);
  late final _time = TextEditingController(text: widget.entry.time);
  @override
  void dispose() {
    _quantity.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChekiCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text('第${widget.position + 1}次领取')),
            IconButton(
              tooltip: '删除第${widget.position + 1}次领取',
              onPressed: () => widget.controller.remove(widget.entry),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        TextField(
          key: ValueKey(
            widget.position == 0
                ? 'record-received-quantity'
                : 'receipt-quantity-${widget.entry.key}',
          ),
          controller: _quantity,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: '本次领取张数',
            suffixIcon: IconButton(
              tooltip: '清空本次领取张数',
              onPressed: () {
                _quantity.clear();
                widget.controller.change(widget.entry, quantity: '');
              },
              icon: const Icon(Icons.clear),
            ),
          ),
          onChanged: (v) => widget.controller.change(widget.entry, quantity: v),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: widget.entry.origin ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: '领取来源'),
          items: const [
            DropdownMenuItem(value: '', child: Text('未填写')),
            DropdownMenuItem(value: 'actual', child: Text('实际领取')),
            DropdownMenuItem(value: 'initial', child: Text('初始整笔已领')),
            DropdownMenuItem(value: 'legacyUnknown', child: Text('历史未知')),
          ],
          onChanged: (v) => widget.controller.change(
            widget.entry,
            origin: v == '' ? null : v,
            changeOrigin: true,
          ),
        ),
        if (widget.entry.origin != 'initial' ||
            widget.entry.time.isNotEmpty) ...[
          const SizedBox(height: 16),
          TextField(
            key: ValueKey(
              widget.position == 0
                  ? 'record-receipt-time'
                  : 'receipt-time-${widget.entry.key}',
            ),
            controller: _time,
            decoration: InputDecoration(
              labelText: '实际领取时间（可后补）',
              hintText: '年-月-日 时:分:秒',
              suffixIcon: IconButton(
                tooltip: '清空本次领取时间',
                onPressed: () {
                  _time.clear();
                  widget.controller.change(widget.entry, time: '');
                },
                icon: const Icon(Icons.clear),
              ),
            ),
            onChanged: (v) => widget.controller.change(widget.entry, time: v),
          ),
        ],
      ],
    ),
  );
}
