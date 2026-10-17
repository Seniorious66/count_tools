import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/catalog_store.dart';
import '../data/catalog_contract.dart';
import '../data/ticket_store.dart';
import '../data/transfer_store.dart';
import '../domain/transfer_information.dart';
import '../domain/record_contract.dart';
import '../domain/ticket_information.dart';
import 'components.dart';
import 'theme.dart';

class TransferEditPage extends StatefulWidget {
  const TransferEditPage({
    required this.store,
    this.kind = 'exchange',
    this.sourceDefinition,
    this.original,
    super.key,
  });
  final TransferStore store;
  final String? kind, sourceDefinition;
  final TransferObject? original;
  @override
  State<TransferEditPage> createState() => _TransferEditPageState();
}

class _TransferEditPageState extends State<TransferEditPage> {
  late final initial =
      widget.original?.information ??
      TransferInformation({
        'kind': widget.kind,
        'source_definition_id': widget.sourceDefinition,
        'occurred_on': OccurredOn.shanghaiDay(widget.store.clock()).value,
        'quantity': 1,
        if (widget.kind == 'exchange') 'target_pool': 'long',
      });
  late final day = TextEditingController(
        text: initial.text('occurred_on') ?? '',
      ),
      quantity = TextEditingController(
        text: initial.quantity?.toString() ?? '',
      ),
      sourceExpiry = TextEditingController(
        text: initial.text('source_expires_on') ?? '',
      ),
      targetExpiry = TextEditingController(
        text: initial.text('target_expires_on') ?? '',
      ),
      note = TextEditingController(text: initial.text('note') ?? '');
  late String? kind = initial.text('kind'),
      from = initial.text('source_definition_id'),
      to = initial.text('target_definition_id'),
      sourcePool = initial.text('source_pool'),
      targetPool = initial.text('target_pool');
  late bool expired = initial.expiredConfirmed;
  late Future<TicketModel> model = _load();
  int _request = 0;
  bool _sourcePoolTouched = false;
  Future<TicketModel> _load() async {
    final request = ++_request;
    final updated =
        await TicketStore(
          widget.store.database,
          clock: widget.store.clock,
        ).readModel(
          day: RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day.text)
              ? day.text
              : null,
        );
    if (!mounted || request != _request) return updated;
    if (widget.original == null && !_sourcePoolTouched) {
      final pools = from == null
          ? <TicketPool>[]
          : updated
                .pools(from!)
                .where((p) => p.quantity > 0 && !p.expired(updated.day))
                .toList();
      pools.sort(
        (a, b) =>
            (a.expiry ?? '9999-12-31').compareTo(b.expiry ?? '9999-12-31'),
      );
      final choice = pools.firstOrNull;
      sourcePool = choice == null
          ? null
          : choice.expiry == null
          ? 'long'
          : 'dated';
      sourceExpiry.text = choice?.expiry ?? '';
    }
    return updated;
  }

  bool busy = false, leaving = false;
  String? error;
  final operationId = newOperationId();
  @override
  void dispose() {
    for (final c in [day, quantity, sourceExpiry, targetExpiry, note]) {
      c.dispose();
    }
    super.dispose();
  }

  TransferInformation information() {
    final raw = initial.toMap(), updates = <String, Object?>{};
    for (final e in {
      'kind': kind,
      'source_definition_id': from,
      'target_definition_id': to,
      'source_pool': sourcePool,
      'target_pool': targetPool,
      'allow_expired': expired,
    }.entries) {
      if (e.value !=
          (e.key == 'allow_expired' ? initial.expiredConfirmed : raw[e.key])) {
        updates[e.key] = e.value;
      }
    }
    for (final e in {
      'occurred_on': day.text,
      'source_expires_on': sourceExpiry.text,
      'target_expires_on': targetExpiry.text,
      'note': note.text,
    }.entries) {
      if (e.value != (initial.text(e.key) ?? '')) {
        updates[e.key] = e.value.trim().isEmpty ? null : e.value.trim();
      }
    }
    if (quantity.text != (initial.quantity?.toString() ?? '')) {
      final q = int.tryParse(quantity.text);
      if (quantity.text.isNotEmpty && q == null) {
        throw const FormatException('张数需为正整数，未知可留空');
      }
      updates['quantity'] = q;
    }
    return initial.patch(updates);
  }

  bool get dirty =>
      day.text != (initial.text('occurred_on') ?? '') ||
      quantity.text != (initial.quantity?.toString() ?? '') ||
      sourceExpiry.text != (initial.text('source_expires_on') ?? '') ||
      targetExpiry.text != (initial.text('target_expires_on') ?? '') ||
      note.text != (initial.text('note') ?? '') ||
      kind != initial.text('kind') ||
      from != initial.text('source_definition_id') ||
      to != initial.text('target_definition_id') ||
      sourcePool != initial.text('source_pool') ||
      targetPool != initial.text('target_pool') ||
      expired != initial.expiredConfirmed;
  Future<void> back() async {
    if (busy) return;
    final leave =
        !dirty ||
        await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('放弃修改？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('继续编辑'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('放弃'),
                  ),
                ],
              ),
            ) ==
            true;
    if (leave && mounted) {
      setState(() => leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  Future<void> review(bool posted) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final i = information();
      final costs = await widget.store.preview(
        i,
        original: widget.original,
        posted: posted,
      );
      if (!mounted) return;
      final result = await Navigator.push<TransferObject>(
        context,
        MaterialPageRoute(
          builder: (_) => TransferReviewPage(
            store: widget.store,
            info: i,
            original: widget.original,
            operationId: operationId,
            posted: posted,
            costs: costs,
          ),
        ),
      );
      if (mounted && result != null) {
        setState(() => leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, result);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is CatalogException
              ? e.message
              : e is FormatException
              ? e.message
              : '检查失败，输入保留，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget pick(
    String label,
    String key,
    String? value,
    List<(String, String)> items,
    void Function(String?) changed,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$key-$value'),
      initialValue: value,
      isExpanded: true,
      itemHeight: null,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem<String>(value: null, child: Text('待补录')),
        for (final item in items)
          DropdownMenuItem(
            value: item.$1,
            child: Text(item.$2, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: busy ? null : changed,
    ),
  );
  Widget field(
    String label,
    String key,
    TextEditingController c, {
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      key: ValueKey(key),
      controller: c,
      enabled: !busy,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        hintText: number
            ? null
            : label.contains('日期') || label.contains('截止')
            ? 'YYYY-MM-DD'
            : null,
      ),
      onChanged: key == 'transfer-day'
          ? (_) => setState(() {
              model = _load();
            })
          : (_) => setState(() {
              if (key == 'transfer-source-expiry') _sourcePoolTouched = true;
            }),
    ),
  );
  @override
  Widget build(BuildContext c) => PopScope<TransferObject>(
    canPop: leaving,
    onPopInvokedWithResult: (did, _) {
      if (!did) back();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          widget.original != null
              ? '修改换送'
              : kind == 'gift'
              ? '送券'
              : '换券',
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: FutureBuilder<TicketModel>(
                future: model,
                builder: (c, s) {
                  if (s.hasError) {
                    return Center(
                      child: TextButton(
                        onPressed: () => setState(() {
                          model = _load();
                        }),
                        child: const Text('库存读取失败，重试'),
                      ),
                    );
                  }
                  if (!s.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final m = s.data!,
                      choices = [
                        for (final d in m.definitions)
                          (d.id, '${m.label(d)} · ${m.scopeLabel(d)}'),
                      ];
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      pick('操作类型', 'transfer-kind', kind, [
                        ('exchange', '换券 1:1'),
                        ('gift', '送券'),
                      ], (v) => setState(() => kind = v)),
                      field('发生日期', 'transfer-day', day),
                      field(
                        '张数（可空）',
                        'transfer-quantity',
                        quantity,
                        number: true,
                      ),
                      ChekiCard(
                        color: ChekiColors.pink,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('来源券'),
                            pick(
                              '券种',
                              'transfer-source',
                              from,
                              choices,
                              (v) => setState(() {
                                from = v;
                                if (widget.original == null) {
                                  _sourcePoolTouched = false;
                                }
                                model = _load();
                              }),
                            ),
                            pick(
                              '券池',
                              'transfer-source-pool',
                              sourcePool,
                              [('long', '可用'), ('dated', '指定期限')],
                              (v) => setState(() {
                                _sourcePoolTouched = true;
                                sourcePool = v;
                                if (v == 'long') sourceExpiry.clear();
                              }),
                            ),
                            if (sourcePool == 'dated')
                              field(
                                '来源截止日期',
                                'transfer-source-expiry',
                                sourceExpiry,
                              ),
                            if (from != null)
                              for (final p in m.pools(from!))
                                Text(
                                  '${p.expiry ?? '可用'} · ${p.quantity} 张${p.expired(m.day) ? ' · 已过期' : ''}',
                                ),
                            if (from != null &&
                                int.tryParse(quantity.text) != null)
                              Builder(
                                builder: (_) {
                                  final available = m
                                      .pools(from!)
                                      .where(
                                        (p) =>
                                            p.expiry ==
                                                (sourcePool == 'dated'
                                                    ? sourceExpiry.text
                                                    : null) &&
                                            (!p.expired(m.day) || expired),
                                      )
                                      .fold<int>(0, (q, p) => q + p.quantity);
                                  final need = int.tryParse(quantity.text)!;
                                  return need > available
                                      ? Text(
                                          '需要$need张，可用$available张，还差${need - available}张。请修改张数或来源池。',
                                        )
                                      : const SizedBox.shrink();
                                },
                              ),
                            if (sourcePool == 'dated' &&
                                sourceExpiry.text.isNotEmpty)
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('明确允许使用过期来源券'),
                                value: expired,
                                onChanged: busy
                                    ? null
                                    : (v) =>
                                          setState(() => expired = v ?? false),
                              ),
                          ],
                        ),
                      ),
                      if (kind == 'exchange') ...[
                        const SizedBox(height: 16),
                        ChekiCard(
                          color: ChekiColors.blue,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('目标券'),
                              pick(
                                '券种',
                                'transfer-target',
                                to,
                                choices,
                                (v) => setState(() => to = v),
                              ),
                              pick(
                                '券池',
                                'transfer-target-pool',
                                targetPool,
                                [('long', '不限期限'), ('dated', '指定期限')],
                                (v) => setState(() {
                                  targetPool = v;
                                  if (v == 'long') targetExpiry.clear();
                                }),
                              ),
                              if (targetPool == 'dated')
                                field(
                                  '目标截止日期',
                                  'transfer-target-expiry',
                                  targetExpiry,
                                ),
                            ],
                          ),
                        ),
                      ],
                      field('备注（可空）', 'transfer-note', note),
                      if (widget.original != null)
                        TextButton(
                          onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => TicketDependenciesPage(
                                store: widget.store,
                                sourceIds: widget.original!.children,
                              ),
                            ),
                          ),
                          child: const Text('查看依赖'),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  error!,
                  style: const TextStyle(color: ChekiColors.danger),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: busy ? null : () => review(true),
                    child: const Text('核对并入账'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => review(false),
                    child: Text(
                      widget.original?.posted == true ? '核对撤销入账' : '保存待补录',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class TransferReviewPage extends StatefulWidget {
  const TransferReviewPage({
    required this.store,
    required this.info,
    required this.operationId,
    required this.posted,
    required this.costs,
    this.original,
    super.key,
  });
  final TransferStore store;
  final TransferInformation info;
  final String operationId;
  final bool posted;
  final List<Map<String, Object?>> costs;
  final TransferObject? original;
  @override
  State<TransferReviewPage> createState() => _TransferReviewPageState();
}

class _TransferReviewPageState extends State<TransferReviewPage> {
  bool busy = false, leaving = false;
  String? error;
  Future<void> save() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final r = await widget.store.save(
        widget.info,
        original: widget.original,
        operationId: widget.operationId,
        posted: widget.posted,
      );
      if (mounted) {
        setState(() => leaving = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, r);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is CatalogException
              ? e.message
              : e is FormatException
              ? e.message
              : '保存失败，原账保留，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => PopScope<TransferObject>(
    canPop: !busy || leaving,
    child: Scaffold(
      appBar: AppBar(title: const Text('换送核对')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TransferInformationView(
                    store: widget.store,
                    info: widget.info,
                  ),
                  if (widget.original != null) ...[
                    const Text('修改前'),
                    TransferInformationView(
                      store: widget.store,
                      info: widget.original!.information,
                    ),
                  ],
                  Text(widget.posted ? '确认后实际入账' : '仅保存信息，不产生库存变动'),
                  for (final cost in widget.costs)
                    Text(
                      '${cost['quantity']} 张 · 成本 ${cost['cost'] == null ? '未知' : TicketMoney.fromExact(cost['cost'] as String).roundedYuan}',
                    ),
                  if (widget.info.text('kind') == 'exchange' && widget.posted)
                    const Text('目标逐来源继承成本，不增加购买支出或Cheki。'),
                  if (error != null)
                    Text(
                      error!,
                      style: const TextStyle(color: ChekiColors.danger),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: busy ? null : save,
                child: const Text('确认保存'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class TransferInformationView extends StatelessWidget {
  const TransferInformationView({
    required this.store,
    required this.info,
    super.key,
  });
  final TransferStore store;
  final TransferInformation info;
  @override
  Widget build(BuildContext c) => FutureBuilder<TicketModel>(
    future: TicketStore(store.database).readModel(),
    builder: (c, s) {
      if (s.hasError) return const Text('券信息读取失败，请重试');
      if (!s.hasData) return const LinearProgressIndicator();
      final m = s.data!;
      String label(String side) {
        final d = m.definitions
            .where((d) => d.id == info.text('${side}_definition_id'))
            .firstOrNull;
        return d == null ? '券种待补录' : '${m.label(d)} · ${m.scopeLabel(d)}';
      }

      return ChekiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              info.text('kind') == 'exchange'
                  ? '换券 1:1'
                  : info.text('kind') == 'gift'
                  ? '送券'
                  : '类型待补录',
            ),
            Text('发生日期 ${info.text('occurred_on') ?? '待补录'}'),
            Text('张数 ${info.quantity ?? '待补录'}'),
            Text('来源 ${label('source')}'),
            if (info.text('source_pool') != null)
              Text(info.text('source_expires_on') ?? '不限期限'),
            if (info.text('kind') == 'exchange') ...[
              Text('目标 ${label('target')}'),
              if (info.text('target_pool') != null)
                Text(info.text('target_expires_on') ?? '不限期限'),
            ],
            if (info.expiredConfirmed) const Text('已明确允许使用过期来源券'),
            if (info.text('note') != null) Text(info.text('note')!),
          ],
        ),
      );
    },
  );
}

class TransferDetailPage extends StatefulWidget {
  const TransferDetailPage({required this.store, required this.id, super.key});
  final TransferStore store;
  final String id;
  @override
  State<TransferDetailPage> createState() => _TransferDetailPageState();
}

class _TransferDetailPageState extends State<TransferDetailPage> {
  late Future<TransferObject> record = load();
  StreamSubscription<void>? subscription;
  Future<TransferObject> load() async =>
      (await widget.store.list()).singleWhere((r) => r.id == widget.id);
  @override
  void initState() {
    super.initState();
    subscription = TicketStore.changes.listen((_) {
      if (mounted) {
        setState(() {
          record = load();
        });
      }
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('换送详情')),
    body: SafeArea(
      child: FutureBuilder<TransferObject>(
        future: record,
        builder: (c, s) {
          if (s.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() {
                  record = load();
                }),
                child: const Text('读取失败，重试'),
              ),
            );
          }
          if (!s.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final r = s.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TransferInformationView(store: widget.store, info: r.information),
              Text(r.posted ? '已入账' : '未入账 / 待补录'),
              FutureBuilder<TicketModel>(
                future: TicketStore(widget.store.database).readModel(),
                builder: (c, m) {
                  if (m.hasError) return const Text('成本流水读取失败');
                  if (!m.hasData) return const LinearProgressIndicator();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final child in m.data!.objects.where(
                        (o) => r.children.contains(o.id),
                      )) ...[
                        Text(
                          '${child.information.text('reason')} · ${child.information.quantity} 张',
                        ),
                        if ((child.information.quantity ?? 0) > 0)
                          Text('继承每张成本 ${child.unitCost?.exact ?? '未知'}'),
                        for (final a in child.allocations)
                          Text(
                            '${a['quantity']} 张 · 转出成本 ${a['cost'] ?? '未知'}',
                          ),
                      ],
                    ],
                  );
                },
              ),
              Text('录入 ${r.raw['created_at']}'),
              TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        TransferEditPage(store: widget.store, original: r),
                  ),
                ),
                child: const Text('修改 / 撤销整笔'),
              ),
              TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TicketDependenciesPage(
                      store: widget.store,
                      sourceIds: r.children,
                    ),
                  ),
                ),
                child: const Text('查看依赖'),
              ),
              FutureBuilder<List<Map<String, Object?>>>(
                future: widget.store.history(r.id),
                builder: (c, h) {
                  if (h.hasError) return const Text('修订历史读取失败');
                  if (!h.hasData) return const LinearProgressIndicator();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('修订历史'),
                      for (final o in h.data!) ...[
                        Text(o['created_at'] as String),
                        TransferInformationView(
                          store: widget.store,
                          info: TransferObject.fromRow(
                            decodeSqlRow(
                              (jsonDecode(o['result_json'] as String)
                                      as Map)['object_json']
                                  as String,
                            ),
                          ).information,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}

class TicketDependenciesPage extends StatelessWidget {
  const TicketDependenciesPage({
    required this.store,
    required this.sourceIds,
    super.key,
  });
  final TransferStore store;
  final List<String> sourceIds;
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('关联依赖')),
    body: FutureBuilder<List<TicketObject>>(
      future: store.dependents(sourceIds),
      builder: (c, s) {
        if (s.hasError) return const Center(child: Text('依赖读取失败，请返回重试'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        return FutureBuilder<TicketModel>(
          future: TicketStore(store.database).readModel(),
          builder: (c, m) {
            if (m.hasError) return const Center(child: Text('券信息读取失败'));
            if (!m.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(s.data!.isEmpty ? '没有后续库存依赖' : '已有后续操作，只能查看依赖，不能修改原操作'),
                for (final r in s.data!)
                  ChekiCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.information.text('reason') ?? '关联库存操作'),
                        Text(
                          m.data!.label(
                            m.data!.definitions.singleWhere(
                              (d) =>
                                  d.id == r.information.text('definition_id'),
                            ),
                          ),
                        ),
                        Text(
                          '${r.information.day} · ${r.information.quantity} 张',
                        ),
                        for (final a in r.allocations)
                          Text(
                            '来源分配 ${a['quantity']} 张 · 成本 ${a['cost'] ?? '未知'}',
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      },
    ),
  );
}

class TransferListPart extends StatelessWidget {
  const TransferListPart({
    required this.store,
    required this.definitionId,
    super.key,
  });
  final TransferStore store;
  final String definitionId;
  @override
  Widget build(BuildContext c) => FutureBuilder<List<TransferObject>>(
    future: store.list(),
    builder: (c, s) {
      if (s.hasError) return const Text('换送读取失败，请返回重试');
      if (!s.hasData) return const LinearProgressIndicator();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in s.data!.where(
            (r) => [
              r.information.text('source_definition_id'),
              r.information.text('target_definition_id'),
            ].contains(definitionId),
          ))
            ListTile(
              title: Text(r.information.text('kind') == 'gift' ? '送券' : '换券'),
              subtitle: Text(
                '${r.information.text('occurred_on') ?? '日期待补录'} · ${r.information.quantity ?? '张数待补录'}${r.posted ? '' : ' · 未入账'}',
              ),
              onTap: () => Navigator.push<void>(
                c,
                MaterialPageRoute(
                  builder: (_) => TransferDetailPage(store: store, id: r.id),
                ),
              ),
            ),
        ],
      );
    },
  );
}
