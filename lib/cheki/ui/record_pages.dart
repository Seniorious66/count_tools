import 'package:flutter/material.dart';
import '../data/catalog_contract.dart';
import '../data/catalog_store.dart';
import '../data/identity_store.dart';
import '../data/record_store.dart';
import '../domain/record_contract.dart';
import '../domain/record_information.dart';
import 'components.dart';
import 'identity_pages.dart' show identityActionLabel;
import 'member_inputs.dart';
import 'theme.dart';

class RecordListPage extends StatefulWidget {
  const RecordListPage({required this.store, super.key});
  final RecordStore store;
  @override
  State<RecordListPage> createState() => _RecordListPageState();
}

class _RecordListPageState extends State<RecordListPage> {
  late Future<List<StoredRecord>> _records = widget.store.list();
  void _reload() => setState(() {
    _records = widget.store.list();
  });
  Future<void> _edit({StoredRecord? original, bool historical = false}) async {
    final saved = await Navigator.push<StoredRecord>(
      context,
      MaterialPageRoute(
        builder: (_) => RecordEditPage(
          store: widget.store,
          original: original,
          historical: historical,
        ),
      ),
    );
    if (mounted && saved != null) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Cheki记录'),
      actions: [
        IconButton(
          tooltip: '补录旧信息',
          onPressed: () => _edit(historical: true),
          icon: const Icon(Icons.post_add),
        ),
        IconButton(
          tooltip: '新增记录',
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: FutureBuilder<List<StoredRecord>>(
        future: _records,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: _reload,
                child: const Text('读取失败，点击重试'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final records = snapshot.data!;
          var knownTotal = 0, unknownQuantity = 0, unknownDate = 0;
          for (final r in records) {
            final info = r.information;
            if (info.quantity == null) {
              unknownQuantity++;
            } else {
              knownTotal += info.quantity!;
            }
            if (info.occurredOn == null) unknownDate++;
          }
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _records;
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                ChekiCard(
                  color: ChekiColors.blue,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('已知张数 $knownTotal'),
                      if (unknownQuantity > 0) Text('张数未填写 $unknownQuantity 条'),
                      if (unknownDate > 0) Text('发生日期未填写 $unknownDate 条'),
                    ],
                  ),
                ),
                if (records.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有记录'),
                  ),
                for (final r in records)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: ChekiCard(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        key: ValueKey('record-${r.id}'),
                        title: Text(
                          r.information.occurredOn?.value ?? '发生日期未填写',
                        ),
                        subtitle: Text(
                          '${r.information.quantity == null ? '张数未填写' : '${r.information.quantity} 张'} · ${r.information.receiptStatus?.label ?? '领取信息未填写'}${r.information.missingFields.isNotEmpty ? '\n待补录：${r.information.missingFields.join('、')}' : ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _edit(original: r),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class RecordEditPage extends StatefulWidget {
  const RecordEditPage({
    required this.store,
    this.original,
    this.historical = false,
    super.key,
  });
  final RecordStore store;
  final StoredRecord? original;
  final bool historical;
  @override
  State<RecordEditPage> createState() => _RecordEditPageState();
}

class _RecordEditPageState extends State<RecordEditPage> {
  late final RecordInformation _initial =
      widget.original?.information ??
      RecordInformation.fromMap(
        widget.historical
            ? {}
            : {
                'occurred_on': OccurredOn.shanghaiDay(
                  widget.store.clock(),
                ).value,
                'quantity': 1,
                'attributes': {'kind': 'signed', 'back_signed': false},
                'receipt_batches': [
                  {'quantity': 1, 'origin': 'initial', 'received_at': null},
                ],
              },
      );
  late final _day = TextEditingController(
    text: _initial.occurredOn?.value ?? '',
  );
  late final _quantity = TextEditingController(
    text: _initial.quantity?.toString() ?? '',
  );
  late final _note = TextEditingController(text: _initial.note ?? '');
  late List<String> _members = _initial.memberIds?.toList() ?? [];
  late String? _size = _initial.sizeId;
  late SignatureKind? _signature = _initial.signature;
  late bool? _back = _initial.backSigned;
  late ReceiptStatus? _receipt = _initial.receiptStatus;
  late final _received = TextEditingController(
    text: _initial.receivedQuantity?.toString() ?? '',
  );
  String? get _originalReceiptTime {
    final batches = _initial.toMap()['receipt_batches'];
    return batches is List && batches.length == 1
        ? (batches.single as Map)['received_at'] as String?
        : null;
  }

  String get _originalReceiptInput => _originalReceiptTime == null
      ? ''
      : DateTime.parse(_originalReceiptTime!)
            .toUtc()
            .add(const Duration(hours: 8))
            .toIso8601String()
            .substring(0, 19)
            .replaceFirst('T', ' ');
  late final _receiptTime = TextEditingController(text: _originalReceiptInput);
  bool _receiptTouched = false, _saving = false, _leaving = false;
  String? _error;
  final _operationId = newOperationId();
  late Future<(IdentityDirectory, List<CatalogEntity>)> _directory = _load();
  Future<(IdentityDirectory, List<CatalogEntity>)> _load() async => (
    await IdentityStore(widget.store.database).directory(),
    await CatalogStore(widget.store.database).list(CatalogKind.size),
  );
  @override
  void dispose() {
    for (final c in [_day, _quantity, _note, _received, _receiptTime]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _number(String s) => s.trim().isEmpty
      ? null
      : int.tryParse(s.trim()) ?? (throw const FormatException('张数须为整数，未知请留空'));
  RecordInformation _information() {
    final quantity = _number(_quantity.text);
    final raw = _initial.toMap();
    Object? batches = raw['receipt_batches'];
    var hint = raw['receipt_status_hint'];
    final initialBatches =
        batches is List &&
        batches.length == 1 &&
        (batches.single as Map)['origin'] == 'initial';
    final previousBatch = batches is List && batches.length == 1
        ? batches.single as Map
        : <String, Object?>{};
    if (_receiptTouched || (initialBatches && quantity != _initial.quantity)) {
      hint = _receipt?.name;
      if (_receipt == null) {
        batches = null;
      } else if (_receipt == ReceiptStatus.unreceived) {
        batches = [];
      } else if (_receipt == ReceiptStatus.received) {
        final actual =
            widget.original != null &&
            (_initial.receiptStatus != ReceiptStatus.received ||
                !initialBatches ||
                _receiptTime.text.trim().isNotEmpty);
        batches = [
          {
            ...previousBatch,
            'quantity': quantity,
            'origin': actual ? 'actual' : 'initial',
            'received_at': actual ? _actualTime() : null,
          },
        ];
      } else {
        final received = _number(_received.text);
        if (received != null &&
            quantity != null &&
            (received <= 0 || received >= quantity)) {
          throw const FormatException('部分领取张数需小于总张数');
        }
        batches = [
          {
            ...previousBatch,
            'quantity': received,
            'origin': 'actual',
            'received_at': _actualTime(),
          },
        ];
      }
    }
    final oldAttributes = (raw['attributes'] as Map?) ?? {};
    return _initial.patch({
      'occurred_on': _day.text.trim().isEmpty ? null : _day.text.trim(),
      'quantity': quantity,
      'size_id': _size,
      'member_ids': _members.isEmpty ? null : _members,
      'attributes': _signature == null && _back == null
          ? null
          : {...oldAttributes, 'kind': _signature?.name, 'back_signed': _back},
      'receipt_batches': batches,
      'receipt_status_hint': hint,
      'note': _note.text.isEmpty ? null : _note.text,
    });
  }

  Future<void> _review() async {
    if (_saving) return;
    try {
      final info = _information();
      setState(() {
        _error = null;
        _saving = true;
      });
      final saved = await Navigator.push<StoredRecord>(
        context,
        MaterialPageRoute(
          builder: (_) => RecordReviewPage(
            store: widget.store,
            information: info,
            original: widget.original,
            operationId: _operationId,
          ),
        ),
      );
      if (mounted) setState(() => _saving = false);
      if (mounted && saved != null) {
        setState(() => _leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, saved);
        });
      }
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  String? _actualTime() {
    final value = _receiptTime.text.trim();
    if (value.isEmpty) return null;
    if (value == _originalReceiptInput) return _originalReceiptTime;
    if (!RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$').hasMatch(value)) {
      throw const FormatException('领取时间请填写 年-月-日 时:分:秒，或留空后补');
    }
    final day = OccurredOn.parse(value.substring(0, 10));
    final hour = int.parse(value.substring(11, 13)),
        minute = int.parse(value.substring(14, 16)),
        second = int.parse(value.substring(17, 19));
    if (hour > 23 || minute > 59 || second > 59) {
      throw const FormatException('领取时间无效');
    }
    return DateTime.parse(
      '${day.value}T${value.substring(11)}.000Z',
    ).subtract(const Duration(hours: 8)).toIso8601String();
  }

  Future<void> _backRequest() async {
    if (_saving) return;
    final changed =
        _day.text != (_initial.occurredOn?.value ?? '') ||
        _quantity.text != (_initial.quantity?.toString() ?? '') ||
        _note.text != (_initial.note ?? '') ||
        _size != _initial.sizeId ||
        _members.join('\u0000') != (_initial.memberIds ?? []).join('\u0000') ||
        _signature != _initial.signature ||
        _back != _initial.backSigned ||
        _receiptTouched;
    final leave =
        !changed ||
        await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('放弃修改？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('继续编辑'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('放弃'),
                  ),
                ],
              ),
            ) ==
            true;
    if (mounted && leave) {
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<StoredRecord>(
    canPop: _leaving,
    onPopInvokedWithResult: (popped, result) {
      if (!popped) _backRequest();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.original != null
              ? '修改记录'
              : widget.historical
              ? '补录旧信息'
              : '记录',
        ),
        actions: [
          if (widget.original != null)
            IconButton(
              tooltip: '记录历史',
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => RecordHistoryPage(
                    store: widget.store,
                    record: widget.original!,
                  ),
                ),
              ),
              icon: const Icon(Icons.history),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (widget.historical)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text('只填写已知信息，其他内容可以以后补齐。'),
                    ),
                  TextField(
                    key: const ValueKey('record-day'),
                    controller: _day,
                    decoration: InputDecoration(
                      labelText: '发生日期',
                      hintText: 'YYYY-MM-DD',
                      suffixIcon: IconButton(
                        tooltip: '清空发生日期',
                        onPressed: () => setState(() => _day.clear()),
                        icon: const Icon(Icons.clear),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('record-quantity'),
                    controller: _quantity,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '张数',
                      suffixIcon: IconButton(
                        tooltip: '清空张数',
                        onPressed: () => setState(() => _quantity.clear()),
                        icon: const Icon(Icons.clear),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<(IdentityDirectory, List<CatalogEntity>)>(
                    future: _directory,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return TextButton(
                          onPressed: () => setState(() => _directory = _load()),
                          child: const Text('成员与尺寸读取失败，点击重试'),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const LinearProgressIndicator();
                      }
                      final (directory, sizes) = snapshot.data!;
                      final groups = {
                        for (final g in directory.groups) g.id: g,
                      };
                      return Column(
                        children: [
                          MemberMultiSelectField(
                            options: directory.members
                                .map(
                                  (m) => MemberOption(
                                    id: m.id,
                                    group: groups[m.groupId]?.name ?? '未填写团体',
                                    name: m.name,
                                    color: m.colorRgb == null
                                        ? ChekiColors.inputBorder
                                        : Color(0xff000000 | m.colorRgb!),
                                    available:
                                        m.active &&
                                        (groups[m.groupId]?.active ?? true),
                                  ),
                                )
                                .toList(),
                            selectedIds: _members,
                            onChanged: (ids) => setState(() => _members = ids),
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            key: ValueKey('record-size-$_size'),
                            initialValue: _size,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: '尺寸'),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('未填写'),
                              ),
                              for (final s in sizes.where(
                                (s) => s.active || s.id == _size,
                              ))
                                DropdownMenuItem(
                                  value: s.id,
                                  child: Text(s.name),
                                ),
                            ],
                            onChanged: (value) => setState(
                              () => _size = value == '' ? null : value,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, c) => Wrap(
                      children: [
                        for (final k in SignatureKind.values)
                          _check(
                            k.label,
                            _signature == k,
                            (v) => setState(() {
                              _signature = v ? k : null;
                              if (_signature != SignatureKind.signed) {
                                _back = null;
                              } else {
                                _back ??= false;
                              }
                            }),
                          ),
                        _check(
                          '背签',
                          _back == true,
                          _signature == SignatureKind.signed
                              ? (v) => setState(() => _back = v)
                              : null,
                        ),
                      ],
                    ),
                  ),
                  if (_signature == SignatureKind.signed)
                    TextButton(
                      onPressed: () => setState(() => _back = null),
                      child: const Text('背签信息留空'),
                    ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('record-receipt-${_receipt?.name}'),
                    initialValue: _receipt?.name,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '领取状态'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('未填写')),
                      for (final s in ReceiptStatus.values)
                        DropdownMenuItem(value: s.name, child: Text(s.label)),
                    ],
                    onChanged: (v) => setState(() {
                      _receiptTouched = true;
                      _receipt = v == ''
                          ? null
                          : ReceiptStatus.values.singleWhere(
                              (s) => s.name == v,
                            );
                    }),
                  ),
                  if (_receipt == ReceiptStatus.partial ||
                      (_receipt == ReceiptStatus.received &&
                          widget.original != null)) ...[
                    const SizedBox(height: 16),
                    if (_receipt == ReceiptStatus.partial)
                      TextField(
                        key: const ValueKey('record-received-quantity'),
                        controller: _received,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '已领取张数'),
                        onChanged: (_) => _receiptTouched = true,
                      ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('record-receipt-time'),
                      controller: _receiptTime,
                      decoration: const InputDecoration(
                        labelText: '实际领取时间（可后补）',
                        hintText: '2026-10-12 11:00:00',
                      ),
                      onChanged: (_) => _receiptTouched = true,
                    ),
                  ],
                  if (!_receiptTouched &&
                      widget.original != null &&
                      _initial.toMap()['receipt_batches'] is List &&
                      (_initial.toMap()['receipt_batches'] as List).isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('原领取批次与时间保留；改变领取信息时在核对页确认。'),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('record-note'),
                    controller: _note,
                    decoration: const InputDecoration(labelText: '备注'),
                    minLines: 1,
                    maxLines: 4,
                  ),
                  if (widget.original != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        '录入时间：${identityActionLabel(widget.original!.createdAt)}',
                      ),
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: const TextStyle(color: ChekiColors.danger),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _review,
                  child: const Text('核对'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _check(String label, bool value, ValueChanged<bool>? changed) =>
      SizedBox(
        width: MediaQuery.textScalerOf(context).scale(14) > 20 ? 130 : 72,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: value,
              onChanged: changed == null ? null : (v) => changed(v!),
              semanticLabel: label,
            ),
            Text(label),
          ],
        ),
      );
}

class RecordReviewPage extends StatefulWidget {
  const RecordReviewPage({
    required this.store,
    required this.information,
    required this.operationId,
    this.original,
    super.key,
  });
  final RecordStore store;
  final RecordInformation information;
  final String operationId;
  final StoredRecord? original;
  @override
  State<RecordReviewPage> createState() => _RecordReviewPageState();
}

class _RecordReviewPageState extends State<RecordReviewPage> {
  bool _saving = false, _leaving = false;
  String? _error;
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final r = await widget.store.save(
        widget.information,
        original: widget.original,
        operationId: widget.operationId,
      );
      if (mounted) {
        setState(() => _leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, r);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is CatalogException ? e.message : '保存失败，输入已保留，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<StoredRecord>(
    canPop: !_saving || _leaving,
    child: Scaffold(
      appBar: AppBar(title: const Text('核对')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  RecordInformationView(
                    info: widget.information,
                    store: widget.store,
                  ),
                  if (widget.information.missingFields.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        '保存后可补录：${widget.information.missingFields.join('、')}',
                      ),
                    ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: const TextStyle(color: ChekiColors.danger),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '正在保存…' : '保存'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class RecordInformationView extends StatelessWidget {
  const RecordInformationView({
    required this.info,
    required this.store,
    super.key,
  });
  final RecordInformation info;
  final RecordStore store;
  Future<(IdentityDirectory, List<CatalogEntity>)> _labels() async => (
    await IdentityStore(store.database).directory(),
    await CatalogStore(store.database).list(CatalogKind.size),
  );
  @override
  Widget build(BuildContext context) => ChekiCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('发生日期：${info.occurredOn?.value ?? '未填写'}'),
        Text('张数：${info.quantity ?? '未填写'}'),
        FutureBuilder<(IdentityDirectory, List<CatalogEntity>)>(
          future: _labels(),
          builder: (context, snapshot) {
            if (snapshot.hasError) return const Text('成员与尺寸读取失败');
            if (!snapshot.hasData) return const Text('正在读取成员与尺寸…');
            final (directory, sizes) = snapshot.data!;
            final groups = {for (final g in directory.groups) g.id: g};
            final members = {for (final m in directory.members) m.id: m};
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '尺寸：${info.sizeId == null ? '未填写' : sizes.where((s) => s.id == info.sizeId).firstOrNull?.name ?? '尺寸信息不可用'}',
                ),
                Text(
                  '参与成员：${info.memberIds == null || info.memberIds!.isEmpty ? '未填写' : info.memberIds!.map((id) {
                          final m = members[id];
                          return m == null ? '成员信息不可用' : '${groups[m.groupId]?.name ?? '未填写团体'} · ${m.name}';
                        }).join('、')}',
                ),
              ],
            );
          },
        ),
        Text('属性：${info.signature?.label ?? '未填写'}'),
        Text(
          '背签：${info.backSigned == null
              ? '未填写'
              : info.backSigned!
              ? '是'
              : '否'}',
        ),
        Text('领取：${info.receiptStatus?.label ?? '未填写'}'),
        if (info.note != null) Text('备注：${info.note}'),
      ],
    ),
  );
}

class RecordHistoryPage extends StatelessWidget {
  const RecordHistoryPage({
    required this.store,
    required this.record,
    super.key,
  });
  final RecordStore store;
  final StoredRecord record;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('记录历史')),
    body: FutureBuilder<List<Map<String, Object?>>>(
      future: store.history(record),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('历史读取失败'));
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final h in snapshot.data!)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(identityActionLabel(h['created_at'] as String)),
                    RecordInformationView(
                      store: store,
                      info: StoredRecord.fromRow(
                        decodeSqlRow(h['after_json'] as String),
                      ).information,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
