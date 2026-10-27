import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import '../data/catalog_contract.dart';
import '../data/catalog_store.dart';
import '../data/identity_store.dart';
import '../data/identity_contract.dart';
import '../data/record_store.dart';
import '../data/record_query.dart';
import '../data/entry_store.dart';
import '../domain/coupon_plan.dart';
import 'coupon_entry.dart';
import '../domain/record_contract.dart';
import '../domain/record_information.dart';
import 'components.dart';
import 'quantity_stepper.dart';
import 'identity_pages.dart' show identityActionLabel;
import 'member_inputs.dart';
import 'theme.dart';
import 'receipt_edit.dart';
import 'record_names.dart';
import 'record_browse.dart' show recordAppBar;
export 'record_browse.dart'
    show RecordListPage, RecordHomePage, RecordDetailPage;

class RecordEditPage extends StatefulWidget {
  const RecordEditPage({
    required this.store,
    this.original,
    this.historical = false,
    this.addReceipt = false,
    super.key,
  });
  final RecordStore store;
  final StoredRecord? original;
  final bool historical;
  final bool addReceipt;
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
  late final _names = RecordNamesController(_initial);
  late String? _size = _initial.sizeId;
  String? _defaultSize;
  bool _sizeTouched = false;
  MemberRecency _recency = MemberRecency(const []);
  StreamSubscription<void>? _recentSubscription;
  int _recentRequest = 0;
  bool _recentFailed = false;
  Future<void> _loadRecent() async {
    final request = ++_recentRequest;
    try {
      final rows = await widget.store.list();
      if (!mounted || request != _recentRequest) return;
      setState(() {
        _recency = MemberRecency(rows, excluding: widget.original?.id);
        _recentFailed = false;
      });
    } catch (_) {
      if (mounted && request == _recentRequest) {
        setState(() => _recentFailed = true);
      }
    }
  }

  late SignatureKind? _signature = _initial.signature;
  late bool? _back = _initial.backSigned;
  late final _receipts = ReceiptEditController(
    _initial,
    clock: widget.store.clock,
  );
  late final _coupons = CouponEntryController(
    store: EntryStore(widget.store.database, clock: widget.store.clock),
    initialMode: widget.original != null || widget.historical
        ? null
        : 'consume',
    recordId: widget.original?.id,
  );
  bool _saving = false, _leaving = false;
  String? _error;
  final _operationId = newOperationId();
  late Future<(IdentityDirectory, List<CatalogEntity>)> _directory = _load();
  Future<(IdentityDirectory, List<CatalogEntity>)> _load() async {
    final directory = await IdentityStore(widget.store.database).directory();
    final sizes = await CatalogStore(
      widget.store.database,
    ).list(CatalogKind.size);
    if (mounted &&
        widget.original == null &&
        !widget.historical &&
        !_sizeTouched) {
      _defaultSize = sizes.any((s) => s.id == 'size-3inch' && s.active)
          ? 'size-3inch'
          : null;
      _size = _defaultSize;
    }
    return (directory, sizes);
  }

  @override
  void initState() {
    super.initState();
    _quantity.addListener(
      () => _receipts.updateTotal(int.tryParse(_quantity.text.trim())),
    );
    _day.addListener(_inputsChanged);
    _quantity.addListener(_inputsChanged);
    _loadCoupons();
    _loadRecent();
    _recentSubscription = RecordStore.changes.listen((_) => _loadRecent());
    if (widget.addReceipt) _receipts.add();
  }

  Future<void> _loadCoupons() async {
    try {
      final value = await _directory;
      if (!mounted) return;
      await _coupons.load(
        _couponInformation(),
        directoryFuture: Future.value(value.$1),
      );
    } catch (_) {
      // The directory's own retry is displayed before a coupon can be chosen.
    }
  }

  @override
  void dispose() {
    _recentSubscription?.cancel();
    for (final c in [_day, _quantity, _note]) {
      c.dispose();
    }
    _receipts.dispose();
    _coupons.dispose();
    super.dispose();
  }

  void _inputsChanged() {
    if (mounted) setState(() {});
  }

  RecordInformation _couponInformation() {
    String? day;
    try {
      day = OccurredOn.parse(_day.text.trim()).value;
    } catch (_) {}
    final q = int.tryParse(_quantity.text.trim());
    return RecordInformation.fromMap({
      'occurred_on': day,
      'quantity': q != null && q > 0 ? q : null,
      'member_ids': _members,
      'size_id': _size,
      'attributes': {'kind': _signature?.name, 'back_signed': _back},
    });
  }

  int? _number(String s) => s.trim().isEmpty
      ? null
      : int.tryParse(s.trim()) ?? (throw const FormatException('张数须为整数，未知请留空'));
  RecordInformation _information() {
    final quantity = _number(_quantity.text);
    final raw = _initial.toMap();
    final receiptChanges = _receipts.patch(quantity);
    final oldAttributes = (raw['attributes'] as Map?) ?? {};
    // Only replace changed fields. An untouched missing key, NULL, empty list
    // or unknown nested attribute must remain exactly as it was recorded.
    return _initial.patch({
      if (_day.text != (_initial.occurredOn?.value ?? ''))
        'occurred_on': _day.text.trim().isEmpty ? null : _day.text.trim(),
      if (_quantity.text != (_initial.quantity?.toString() ?? ''))
        'quantity': quantity,
      if (_size != _initial.sizeId) 'size_id': _size,
      if (jsonEncode(_members) != jsonEncode(_initial.memberIds ?? []))
        'member_ids': _members.isEmpty ? null : _members,
      if (_signature != _initial.signature || _back != _initial.backSigned)
        'attributes': {
          ...oldAttributes,
          'kind': _signature?.name,
          'back_signed': _back,
        },
      ...receiptChanges,
      ..._names.patch(_members),
      if (_note.text != (_initial.note ?? ''))
        'note': _note.text.isEmpty ? null : _note.text,
    });
  }

  Future<void> _review() async {
    if (_saving) return;
    try {
      final info = _information();
      setState(() => _saving = true);
      await _coupons.sync(_couponInformation());
      final plan = await _coupons.checked(info);
      if (!mounted) return;
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
            couponPlan: plan,
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
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } on CatalogException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '读取或核对失败，请重试；输入已保留';
        });
      }
    }
  }

  Future<void> _backRequest() async {
    if (_saving) return;
    final changed =
        _day.text != (_initial.occurredOn?.value ?? '') ||
        _quantity.text != (_initial.quantity?.toString() ?? '') ||
        _note.text != (_initial.note ?? '') ||
        _size != (_defaultSize ?? _initial.sizeId) ||
        _members.join('\u0000') != (_initial.memberIds ?? []).join('\u0000') ||
        _signature != _initial.signature ||
        _back != _initial.backSigned ||
        _receipts.changed ||
        _coupons.changed;
    final namesChanged = _names.patch(_members).isNotEmpty;
    final leave =
        !(changed || namesChanged) ||
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
      appBar: recordAppBar(
        context,
        widget.original != null ? '修改记录' : '记录',
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
                  QuantityStepper(
                    fieldKey: const ValueKey('record-quantity'),
                    controller: _quantity,
                  ),
                  const SizedBox(height: 16),
                  FutureBuilder<(IdentityDirectory, List<CatalogEntity>)>(
                    future: _directory,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return TextButton(
                          onPressed: () {
                            setState(() => _directory = _load());
                            _loadCoupons();
                          },
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
                      final membersById = {
                        for (final m in directory.members) m.id: m,
                      };
                      return Column(
                        children: [
                          MemberMultiSelectField(
                            options: _recency
                                .order(
                                  directory.members.map((m) => m.id),
                                  _couponInformation().occurredOn?.value,
                                )
                                .map((id) {
                                  final m = membersById[id]!;
                                  final availability =
                                      MemberAvailability.fromMember(
                                        m,
                                        groups[m.groupId],
                                      );
                                  return MemberOption(
                                    id: m.id,
                                    group: groups[m.groupId]?.name ?? '未填写团体',
                                    name: m.name,
                                    color: m.colorRgb == null
                                        ? ChekiColors.inputBorder
                                        : Color(0xff000000 | m.colorRgb!),
                                    available: availability.available,
                                    unavailableReason: availability.description,
                                  );
                                })
                                .toList(),
                            selectedIds: _members,
                            onChanged: (ids) => setState(() {
                              _members = ids;
                              _names.select(
                                ids,
                                directory,
                                captureNew:
                                    widget.original == null &&
                                    !widget.historical,
                              );
                            }),
                          ),
                          if (_recentFailed)
                            TextButton(
                              onPressed: _loadRecent,
                              child: const Text('最近成员读取失败，重试'),
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
                            onChanged: (value) => setState(() {
                              _sizeTouched = true;
                              _size = value == '' ? null : value;
                            }),
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
                              if (v && k == SignatureKind.homework) {
                                _coupons.selectMode('record_only');
                              }
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
                  ReceiptEditor(
                    controller: _receipts,
                    existing: widget.original != null,
                  ),
                  const SizedBox(height: 16),
                  CouponEntryEditor(
                    controller: _coupons,
                    info: _couponInformation(),
                    autoLoad: false,
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
        child: InkWell(
          onTap: changed == null ? null : () => changed(!value),
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
        ),
      );
}

class RecordReviewPage extends StatefulWidget {
  const RecordReviewPage({
    required this.store,
    required this.information,
    required this.operationId,
    this.original,
    this.couponPlan,
    super.key,
  });
  final RecordStore store;
  final RecordInformation information;
  final String operationId;
  final StoredRecord? original;
  final CouponPlan? couponPlan;
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
      final r = widget.couponPlan == null
          ? await widget.store.save(
              widget.information,
              original: widget.original,
              operationId: widget.operationId,
            )
          : await EntryStore(
              widget.store.database,
              clock: widget.store.clock,
              afterRecord: widget.store.afterWrite,
            ).save(
              widget.information,
              plan: widget.couponPlan!,
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
      appBar: recordAppBar(context, '核对'),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (widget.original != null) ...[
                    RecordChangeView(
                      before: widget.original!.information,
                      after: widget.information,
                      store: widget.store,
                    ),
                    const SizedBox(height: 16),
                  ],
                  RecordInformationView(
                    info: widget.information,
                    store: widget.store,
                  ),
                  if (widget.couponPlan != null) ...[
                    const SizedBox(height: 16),
                    CouponPlanView(
                      plan: widget.couponPlan!,
                      store: EntryStore(
                        widget.store.database,
                        clock: widget.store.clock,
                      ),
                      originalId: widget.original?.id,
                    ),
                  ],
                  if (widget.couponPlan != null)
                    CouponCostPreview(
                      info: widget.information,
                      plan: widget.couponPlan!,
                      store: EntryStore(
                        widget.store.database,
                        clock: widget.store.clock,
                      ),
                      recordId: widget.original?.id,
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

class RecordInformationView extends StatefulWidget {
  const RecordInformationView({
    required this.info,
    required this.store,
    this.historical = false,
    super.key,
  });
  final bool historical;
  final RecordInformation info;
  final RecordStore store;
  @override
  State<RecordInformationView> createState() => _RecordInformationViewState();
}

class _RecordInformationViewState extends State<RecordInformationView> {
  RecordInformation get info => widget.info;
  late Future<RecordReadModel> _labels = widget.store.readLabels();
  StreamSubscription<void>? _subscription;
  @override
  void initState() {
    super.initState();
    _subscription = RecordStore.changes.listen((_) {
      if (mounted) {
        setState(() {
          _labels = widget.store.readLabels();
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChekiCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('发生日期：${info.occurredOn?.value ?? '未填写'}'),
        Text('张数：${info.quantity ?? '未填写'}'),
        FutureBuilder<RecordReadModel>(
          future: _labels,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return TextButton(
                onPressed: () =>
                    setState(() => _labels = widget.store.readLabels()),
                child: const Text('成员与尺寸读取失败，点击重试'),
              );
            }
            if (!snapshot.hasData) return const Text('正在读取成员与尺寸…');
            final labels = snapshot.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '尺寸：${info.sizeId == null ? '未填写' : labels.sizes[info.sizeId]?.name ?? '尺寸信息不可用'}',
                ),
                Text(
                  '参与成员：${info.memberIds == null || info.memberIds!.isEmpty ? '未填写' : info.memberIds!.map((id) => widget.historical ? labels.historicalMemberLabel(info, id) : labels.recordMemberLabel(info, id)).join('、')}',
                ),
              ],
            );
          },
        ),
        Text('属性：${info.signature?.label ?? '未填写'}'),
        if (info.signature == SignatureKind.signed)
          Text(
            '背签：${info.backSigned == null
                ? '未填写'
                : info.backSigned!
                ? '是'
                : '否'}',
          ),
        Text('领取：${info.receiptStatus?.label ?? '未填写'}'),
        Text('已领取张数：${info.receivedQuantity ?? '未填写'}'),
        for (final line in recordReceiptLines(info)) Text(line),
        if (info.note != null) Text('备注：${info.note}'),
      ],
    ),
  );
}

List<String> recordReceiptLines(RecordInformation info) {
  final batches = info.toMap()['receipt_batches'];
  if (batches == null) return ['领取批次：未填写'];
  if ((batches as List).isEmpty) return ['领取批次：无'];
  return [
    for (var index = 0; index < batches.length; index++)
      '第${index + 1}次：${(batches[index] as Map)['quantity'] ?? '未填写'} 张 · ${switch ((batches[index] as Map)['origin']) {
        'initial' => '初始已领取',
        'actual' => '实际领取',
        'legacyUnknown' => '历史时间未知',
        _ => '来源未填写',
      }}\n${(batches[index] as Map)['received_at'] == null
          ? (batches[index] as Map)['origin'] == 'initial'
                ? '不设实际领取时间'
                : '实际领取时间未填写'
          : identityActionLabel((batches[index] as Map)['received_at'] as String)}',
  ];
}

class RecordChangeView extends StatefulWidget {
  const RecordChangeView({
    required this.before,
    required this.after,
    required this.store,
    super.key,
  });
  final RecordInformation before, after;
  final RecordStore store;
  @override
  State<RecordChangeView> createState() => _RecordChangeViewState();
}

class _RecordChangeViewState extends State<RecordChangeView> {
  late Future<RecordReadModel> _labels = widget.store.readLabels();
  String _value(String key, RecordInformation info, RecordReadModel m) =>
      switch (key) {
        'occurred_on' => info.occurredOn?.value ?? '未填写',
        'quantity' => info.quantity?.toString() ?? '未填写',
        'size_id' =>
          info.sizeId == null ? '未填写' : m.sizes[info.sizeId]?.name ?? '尺寸信息不可用',
        'member_ids' =>
          (info.memberIds ?? []).isEmpty
              ? '未填写'
              : info.memberIds!
                    .map((id) => m.recordMemberLabel(info, id))
                    .join('、'),
        'member_snapshots' =>
          (info.memberIds ?? []).isEmpty
              ? '未填写'
              : info.memberIds!
                    .map((id) => m.historicalMemberLabel(info, id))
                    .join('、'),
        'attributes' =>
          info.signature == SignatureKind.signed
              ? '带签 · 背签${info.backSigned == null
                    ? '未填写'
                    : info.backSigned!
                    ? '是'
                    : '否'}'
              : info.signature?.label ?? '未填写',
        'receipt_batches' => recordReceiptLines(info).join('\n'),
        'receipt_status_hint' => info.receiptStatus?.label ?? '未填写',
        'note' => info.note ?? '未填写',
        _ => '其他信息',
      };
  @override
  Widget build(BuildContext context) => FutureBuilder<RecordReadModel>(
    future: _labels,
    builder: (context, s) {
      if (s.hasError) {
        return TextButton(
          onPressed: () => setState(() {
            _labels = widget.store.readLabels();
          }),
          child: const Text('修改对照读取失败，点击重试'),
        );
      }
      if (!s.hasData) return const Text('正在读取修改对照…');
      final before = widget.before.toMap(), after = widget.after.toMap();
      const fields = {
        'occurred_on': '发生日期',
        'quantity': '张数',
        'size_id': '尺寸',
        'member_ids': '参与成员',
        'member_snapshots': '记录名称',
        'attributes': '属性',
        'receipt_batches': '领取批次',
        'receipt_status_hint': '领取状态',
        'note': '备注',
      };
      final changed = fields.keys
          .where((k) => jsonEncode(before[k]) != jsonEncode(after[k]))
          .toList();
      return ChekiCard(
        color: ChekiColors.pink,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('修改对照'),
            if (changed.isEmpty) const Text('业务信息没有变化'),
            for (final k in changed)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fields[k]!,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text('修改前：${_value(k, widget.before, s.data!)}'),
                    Text('修改后：${_value(k, widget.after, s.data!)}'),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}

class RecordHistoryPage extends StatefulWidget {
  const RecordHistoryPage({
    required this.store,
    required this.record,
    super.key,
  });
  final RecordStore store;
  final StoredRecord record;
  @override
  State<RecordHistoryPage> createState() => _RecordHistoryPageState();
}

class _RecordHistoryPageState extends State<RecordHistoryPage> {
  late Future<List<Map<String, Object?>>> _history = widget.store.history(
    widget.record,
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: recordAppBar(context, '记录历史'),
    body: FutureBuilder<List<Map<String, Object?>>>(
      future: _history,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(
                () => _history = widget.store.history(widget.record),
              ),
              child: const Text('历史读取失败，点击重试'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final h in snapshot.data!.reversed)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(identityActionLabel(h['created_at'] as String)),
                    if (h['before_json'] != null)
                      RecordChangeView(
                        store: widget.store,
                        before: StoredRecord.fromRow(
                          decodeSqlRow(h['before_json'] as String),
                        ).information,
                        after: StoredRecord.fromRow(
                          decodeSqlRow(h['after_json'] as String),
                        ).information,
                      ),
                    RecordInformationView(
                      historical: true,
                      store: widget.store,
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
