import 'dart:async';
import 'package:flutter/material.dart';
import '../data/ticket_store.dart';
import '../data/catalog_store.dart';
import '../data/catalog_contract.dart';
import '../domain/ticket_information.dart';
import '../domain/record_contract.dart';
import 'components.dart';
import 'theme.dart';
import 'record_browse.dart' show recordAppBar;
import '../data/transfer_store.dart';
import 'transfer_pages.dart';

class TicketOverview extends StatelessWidget {
  const TicketOverview({required this.child, this.store, super.key});
  final Widget child;
  final TicketStore? store;
  @override
  Widget build(BuildContext context) {
    if (store == null) {
      return ChekiCard(color: ChekiColors.blue, child: child);
    }
    final blue = ColoredBox(
      color: ChekiColors.blue,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
    final pink = TicketSummaryPanel(store: store!);
    final metrics = ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: MediaQuery.textScalerOf(context).scale(16) > 24
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [blue, pink],
            )
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: blue),
                  Expanded(child: pink),
                ],
              ),
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        metrics,
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => TicketEditPage(store: store!, kind: 'purchase'),
              ),
            ),
            child: const Text('购券'),
          ),
        ),
      ],
    );
  }
}

class OverviewMetric extends StatelessWidget {
  const OverviewMetric({
    required this.title,
    required this.value,
    required this.onTap,
    super.key,
  });
  final String title, value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(
            text: value,
            children: const [
              TextSpan(
                text: ' 张',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.normal),
              ),
            ],
          ),
          style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

mixin TicketReader<T extends StatefulWidget> on State<T> {
  TicketStore get store;
  late Future<TicketModel> model;
  StreamSubscription<void>? subscription;
  Timer? dayTimer;
  late String observedDay;
  late final observer = _TicketLifecycle(() {
    if (mounted) {
      reload();
    }
  });
  @override
  void initState() {
    super.initState();
    model = store.readModel();
    model.ignore();
    observedDay = OccurredOn.shanghaiDay(store.clock()).value;
    WidgetsBinding.instance.addObserver(observer);
    dayTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final day = OccurredOn.shanghaiDay(store.clock()).value;
      if (mounted && day != observedDay) {
        observedDay = day;
        reload();
      }
    });
    subscription = TicketStore.changes.listen((_) {
      if (mounted) reload();
    });
  }

  void reload() => setState(() {
    model = store.readModel();
    model.ignore();
  });
  @override
  void dispose() {
    dayTimer?.cancel();
    WidgetsBinding.instance.removeObserver(observer);
    subscription?.cancel();
    super.dispose();
  }

  Widget read(Widget Function(TicketModel) builder) =>
      FutureBuilder<TicketModel>(
        future: model,
        builder: (c, s) {
          if (s.hasError) {
            return TextButton(
              onPressed: reload,
              child: const Text('券库存读取失败，重试'),
            );
          }
          if (s.connectionState == ConnectionState.waiting || !s.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return builder(s.data!);
        },
      );
  Future<void> edit(
    String kind, {
    TicketObject? original,
    String? definitionId,
  }) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => TicketEditPage(
          store: store,
          kind: kind,
          original: original,
          definitionId: definitionId,
        ),
      ),
    );
  }
}

class _TicketLifecycle extends WidgetsBindingObserver {
  _TicketLifecycle(this.reload);
  final VoidCallback reload;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      reload();
    }
  }
}

class TicketSummaryPanel extends StatefulWidget {
  const TicketSummaryPanel({required this.store, super.key});
  final TicketStore store;
  @override
  State<TicketSummaryPanel> createState() => _TicketSummaryPanelState();
}

class _TicketSummaryPanelState extends State<TicketSummaryPanel>
    with TicketReader<TicketSummaryPanel> {
  @override
  TicketStore get store => widget.store;
  @override
  Widget build(BuildContext context) => Material(
    color: ChekiColors.pink,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: read(
        (m) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OverviewMetric(
              title: '可用券',
              value: '${m.available}',
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => TicketLibraryPage(store: store),
                ),
              ),
            ),
            if (m.drafts.isNotEmpty ||
                m.allPools.any((p) => p.near(m.day, m.reminderDays)))
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (m.drafts.isNotEmpty) Text('待补录 ${m.drafts.length} 条'),
                  for (final p in m.allPools.where(
                    (p) => p.near(m.day, m.reminderDays),
                  ))
                    Text(
                      '${m.label(m.definitions.singleWhere((d) => d.id == p.definitionId))} · ${p.expiry} 到期 ${p.quantity} 张',
                    ),
                ],
              ),
          ],
        ),
      ),
    ),
  );
}

class TicketLibraryPage extends StatefulWidget {
  const TicketLibraryPage({
    required this.store,
    this.embedded = false,
    this.definitionsOnly = false,
    super.key,
  });
  final TicketStore store;
  final bool embedded, definitionsOnly;
  @override
  State<TicketLibraryPage> createState() => _TicketLibraryPageState();
}

class _TicketLibraryPageState extends State<TicketLibraryPage>
    with TicketReader<TicketLibraryPage> {
  @override
  TicketStore get store => widget.store;
  @override
  Widget build(BuildContext context) {
    final body = read(
      (m) => RefreshIndicator(
        onRefresh: () async {
          reload();
          await model;
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => edit('purchase'),
                  icon: const Icon(Icons.add),
                  label: const Text('购券'),
                ),
                TextButton(
                  onPressed: () => edit('definition'),
                  child: const Text('新增券种'),
                ),
                TextButton(
                  onPressed: () => edit(
                    'setting',
                    original: m.objects
                        .where((e) => e.kind == 'setting')
                        .lastOrNull,
                  ),
                  child: const Text('临期提醒'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (!widget.definitionsOnly)
              ChekiCard(
                color: ChekiColors.pink,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('可用券'),
                    Text(
                      '${m.available} 张',
                      style: const TextStyle(fontSize: 32),
                    ),
                    if (m.allPools.where((p) => p.expired(m.day)).isNotEmpty)
                      Text(
                        '已过期 ${m.allPools.where((p) => p.expired(m.day)).fold(0, (q, p) => q + p.quantity)} 张',
                      ),
                  ],
                ),
              ),
            if (m.definitions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('还没有券种，可先保存空信息再补齐'),
              ),
            for (final d in m.definitions)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ChekiCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(m.label(d)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${m.scopeLabel(d)}${d.information.toMap()['active'] == false
                              ? ' · 已停用'
                              : d.information.toMap()['active'] == null
                              ? ' · 启用状态未填写'
                              : ''}',
                        ),
                        if (!widget.definitionsOnly) ...poolWidgets(m, d),
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => widget.definitionsOnly
                        ? edit('definition', original: d)
                        : Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  TicketDetailPage(store: store, id: d.id),
                            ),
                          ),
                  ),
                ),
              ),
            if (m.drafts.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text('待补录 · 尚未计入库存'),
              ),
              for (final e in m.drafts)
                ListTile(
                  title: Text(entryLabel(m, e)),
                  subtitle: Text(entrySummary(e)),
                  onTap: () => edit(e.kind, original: e),
                ),
            ],
          ],
        ),
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: recordAppBar(context, widget.definitionsOnly ? '券种管理' : '券库'),
      body: SafeArea(child: body),
    );
  }
}

List<Widget> poolWidgets(TicketModel m, TicketObject d) {
  final pools = m.pools(d.id),
      valid = pools.where((p) => !p.expired(m.day)).toList();
  final mixed =
      valid.any((p) => p.expiry == null) && valid.any((p) => p.expiry != null);
  return [
    Text('可用 ${valid.fold(0, (q, p) => q + p.quantity)} 张'),
    for (final p in pools)
      if (p.expiry != null)
        Text(
          '${p.expiry} · ${p.expired(m.day)
              ? '已过期'
              : p.near(m.day, m.reminderDays)
              ? '即将到期'
              : '有效'} ${p.quantity} 张',
          style: TextStyle(
            color: p.expired(m.day) || p.near(m.day, m.reminderDays)
                ? ChekiColors.warning
                : ChekiColors.ink,
          ),
        )
      else if (mixed)
        Text('长期 ${p.quantity} 张'),
  ];
}

String entryLabel(TicketModel m, TicketObject e) {
  final d = m.definitions
      .where((d) => d.id == e.information.text('definition_id'))
      .firstOrNull;
  return '${e.kind == 'purchase' ? '购入' : '库存调整'} · ${d == null ? '券种未填写' : m.label(d)}';
}

String entrySummary(TicketObject e) {
  final i = e.information;
  return '${i.day ?? '日期未填写'} · ${i.quantity == null ? '张数未填写' : '${i.quantity} 张'}'
      '${i.expiry == null ? '' : ' · ${i.expiry} 截止'} · ${i.costConflict
          ? '金额待核对'
          : e.unitCost == null
          ? '成本未知'
          : '每张成本 ¥${e.unitCost!.exact}'}'
      '${e.posted ? '' : ' · 未入账'}';
}

class TicketDetailPage extends StatefulWidget {
  const TicketDetailPage({required this.store, required this.id, super.key});
  final TicketStore store;
  final String id;
  @override
  State<TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<TicketDetailPage>
    with TicketReader<TicketDetailPage> {
  @override
  TicketStore get store => widget.store;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: recordAppBar(context, '券详情'),
    body: SafeArea(
      child: read((m) {
        final d = m.definitions.singleWhere((d) => d.id == widget.id);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ChekiCard(
              color: ChekiColors.pink,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.label(d),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(m.scopeLabel(d)),
                  ...poolWidgets(m, d),
                ],
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => edit('definition', original: d),
                  child: const Text('修改券种'),
                ),
                TextButton(
                  onPressed: () => edit('purchase', definitionId: d.id),
                  child: const Text('购券'),
                ),
                TextButton(
                  onPressed: () => edit('adjustment', definitionId: d.id),
                  child: const Text('调整库存'),
                ),
                for (final kind in ['exchange', 'gift'])
                  TextButton(
                    onPressed: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TransferEditPage(
                          store: TransferStore(
                            store.database,
                            clock: store.clock,
                          ),
                          kind: kind,
                          sourceDefinition: d.id,
                        ),
                      ),
                    ),
                    child: Text(kind == 'exchange' ? '换券' : '送券'),
                  ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('购入与库存流水'),
            ),
            TransferListPart(
              store: TransferStore(store.database, clock: store.clock),
              definitionId: d.id,
            ),
            for (final e
                in m.objects
                    .where((e) => e.information.text('definition_id') == d.id)
                    .toList()
                    .reversed)
              ChekiCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entryLabel(m, e)),
                    Text(entrySummary(e)),
                    if (e.information.text('unit_price') != null)
                      Text('原单价 ¥${e.information.text('unit_price')}'),
                    if (e.information.text('total_price') != null)
                      Text('原总额 ¥${e.information.text('total_price')}'),
                    if (e.information.text('reason') != null)
                      Text('原因：${e.information.text('reason')}'),
                    if (e.information.text('note') != null)
                      Text(e.information.text('note')!),
                    for (final a in e.allocations)
                      Text(
                        '购入 ${m.objects.singleWhere((x) => x.id == a['source_id']).information.day ?? '日期未知'} · ${a['quantity']} 张 · 成本 ${a['cost'] ?? '未知'}',
                      ),
                    Text('录入 ${e.raw['created_at']}'),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () async {
                            final transfers = TransferStore(
                              store.database,
                              clock: store.clock,
                            );
                            final transfer = await transfers.forTicket(e.id);
                            if (!context.mounted) return;
                            if (transfer != null) {
                              await Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TransferDetailPage(
                                    store: transfers,
                                    id: transfer.id,
                                  ),
                                ),
                              );
                            } else {
                              await edit(e.kind, original: e);
                            }
                          },
                          child: const Text('修改 / 撤销入账'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => TicketDependenciesPage(
                                store: TransferStore(
                                  store.database,
                                  clock: store.clock,
                                ),
                                sourceIds: [e.id],
                              ),
                            ),
                          ),
                          child: const Text('关联依赖'),
                        ),
                        TextButton(
                          onPressed: () => showTicketHistory(context, store, e),
                          child: const Text('修订历史'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            TextButton(
              onPressed: () => showTicketHistory(context, store, d),
              child: const Text('券种历史'),
            ),
          ],
        );
      }),
    ),
  );
}

Future<void> showTicketHistory(
  BuildContext context,
  TicketStore store,
  TicketObject e,
) async {
  await Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: recordAppBar(context, '修订历史'),
        body: FutureBuilder<List<Map<String, Object?>>>(
          future: store.history(e.id),
          builder: (c, s) {
            if (s.hasError) return const Center(child: Text('历史读取失败，请返回重试'));
            if (!s.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final h in s.data!)
                  ChekiCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${h['created_at']}'),
                        if (h['before_json'] == null)
                          const Text('新建')
                        else
                          Text(
                            '修改前：${TicketInformation.decode(decodeSqlRow(h['before_json'] as String)['information_json'] as String).toMap().entries.where((x) => ticketLabels.containsKey(x.key)).map((x) => '${ticketLabels[x.key]}：${ticketSimpleValue(x.value)}').join('；')}',
                          ),
                        Text(
                          '修改后：${TicketInformation.decode(decodeSqlRow(h['after_json'] as String)['information_json'] as String).toMap().entries.where((x) => ticketLabels.containsKey(x.key)).map((x) => '${ticketLabels[x.key]}：${ticketSimpleValue(x.value)}').join('；')}',
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class TicketEditPage extends StatefulWidget {
  const TicketEditPage({
    required this.store,
    required this.kind,
    this.original,
    this.definitionId,
    super.key,
  });
  final TicketStore store;
  final String kind;
  final TicketObject? original;
  final String? definitionId;
  @override
  State<TicketEditPage> createState() => _TicketEditPageState();
}

class _TicketEditPageState extends State<TicketEditPage> {
  late final Future<TicketModel> model = widget.store.readModel();
  late final Map<String, Object?> baseline =
      widget.original?.information.toMap() ?? {};
  final inputs = <String, TextEditingController>{};
  late final Map<String, Object?> selections = {
    ...baseline,
    if (baseline['active'] is bool)
      'active': baseline['active'] == true ? 'yes' : 'no',
    if (widget.definitionId != null) 'definition_id': widget.definitionId,
  };
  late bool posted = widget.original?.posted ?? false;
  bool expired = false, review = false, busy = false;
  bool _sizeDefaultPending = false;
  TicketModel? _directory;
  String? error;
  final operation = newOperationId();
  bool get definition => widget.kind == 'definition';
  bool get setting => widget.kind == 'setting';
  @override
  void initState() {
    super.initState();
    if (definition && widget.original == null) {
      selections.addAll({
        'scope': 'personal',
        'signature': 'signed',
        'active': 'yes',
      });
      _sizeDefaultPending = true;
    }
    for (final key in [
      'name',
      'quantity',
      'occurred_on',
      'expires_on',
      'unit_price',
      'total_price',
      'note',
      'reason',
      'reminder_days',
    ]) {
      inputs[key] = TextEditingController(
        text: baseline[key]?.toString() ?? '',
      );
    }
  }

  @override
  void dispose() {
    for (final c in inputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  TicketInformation information() {
    final data = {...baseline};
    final fields = setting
        ? ['reminder_days']
        : definition
        ? ['note']
        : [
            'quantity',
            'occurred_on',
            'expires_on',
            'unit_price',
            'total_price',
            'note',
            'reason',
          ];
    for (final key in fields) {
      final text = inputs[key]!.text.trim();
      if (text == (baseline[key]?.toString() ?? '') &&
          baseline.containsKey(key)) {
        continue;
      }
      if (text.isEmpty && !baseline.containsKey(key)) continue;
      data[key] = text.isEmpty
          ? null
          : (['quantity', 'reminder_days'].contains(key)
                ? int.parse(text)
                : text);
    }
    for (final key
        in definition
            ? [
                'group_id',
                'scope',
                'member_id',
                'size_id',
                'signature',
                'active',
              ]
            : setting
            ? <String>[]
            : ['definition_id', 'pool']) {
      if (selections.containsKey(key)) {
        data[key] = key == 'active'
            ? (selections[key] == null ? null : selections[key] == 'yes')
            : selections[key];
      }
    }
    return TicketInformation(data);
  }

  Widget field(String key, String label, {bool numeric = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: ValueKey('ticket-$key'),
      controller: inputs[key],
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
    ),
  );
  Widget select(
    String key,
    String label,
    Map<String, String> options,
  ) => Padding(
    key: ValueKey('ticket-$key'),
    padding: const EdgeInsets.only(bottom: 16),
    child: DropdownButtonFormField<String>(
      key: ValueKey('ticket-$key-${selections[key]}'),
      initialValue: selections[key] as String?,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem<String>(value: null, child: Text('未填写')),
        if (selections[key] != null && !options.containsKey(selections[key]))
          DropdownMenuItem<String>(
            value: selections[key] as String,
            enabled: false,
            child: Text(key == 'member_id' ? '原成员不属于所选团体，请重新选择' : '原选择已不可用'),
          ),
        for (final e in options.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: busy
          ? null
          : (v) => setState(() {
              selections[key] = v;
              if (key == 'group_id' &&
                  selections['member_id'] != null &&
                  _directory?.memberGroups[selections['member_id']] != v) {
                selections['member_id'] = null;
                error = '已清空不属于该团体的成员，请重新选择';
              }
              if (key == 'member_id' &&
                  v != null &&
                  selections['group_id'] == null) {
                selections['group_id'] = _directory?.memberGroups[v];
              }
              if (key == 'scope' && v == 'group') {
                selections['member_id'] = null;
              }
              if (key == 'pool' && v == 'long') inputs['expires_on']!.clear();
            }),
    ),
  );
  void check() {
    try {
      information();
      setState(() {
        error = null;
        review = true;
      });
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.store.save(
        kind: widget.kind,
        information: information(),
        original: widget.original,
        operationId: operation,
        posted: posted,
        allowExpired: expired,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: recordAppBar(
        context,
        review
            ? '核对'
            : setting
            ? '临期提醒'
            : definition
            ? '券种信息'
            : widget.kind == 'purchase'
            ? '购券'
            : '调整库存',
      ),
      body: SafeArea(
        child: FutureBuilder<TicketModel>(
          future: model,
          builder: (c, s) {
            if (s.hasError) {
              return Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('读取失败，返回重新打开'),
                ),
              );
            }
            if (!s.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final m = s.data!;
            _directory = m;
            if (_sizeDefaultPending) {
              _sizeDefaultPending = false;
              if (m.sizes.containsKey('size-3inch')) {
                selections['size_id'] = 'size-3inch';
              }
            }
            return Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (review) ...[
                        if (widget.original != null)
                          ChekiCard(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('原信息'),
                                ...ticketInformationWidgets(
                                  m,
                                  widget.original!.information,
                                ),
                              ],
                            ),
                          ),
                        ChekiCard(
                          color: definition
                              ? ChekiColors.blue
                              : ChekiColors.pink,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ...ticketInformationWidgets(m, information()),
                              if (!definition && !setting)
                                Text(posted ? '确认后计入库存' : '仅保存信息，不生成库存'),
                              if (information().costConflict)
                                const Text('单价与总额不一致，请返回核对；草稿可保留'),
                              if (expired) const Text('已明确允许使用过期库存'),
                            ],
                          ),
                        ),
                      ] else if (setting) ...[
                        const Text('正库存进入提醒天数时显示临期提示；留空使用7天。'),
                        field('reminder_days', '提醒天数（0–365，可空）', numeric: true),
                      ] else if (definition) ...[
                        select('group_id', '团体', m.groups),
                        select('scope', '适用范围', {
                          'personal': '个人券',
                          'group': '团体通用券',
                        }),
                        if (selections['scope'] != 'group')
                          select('member_id', '指定成员', {
                            for (final e in m.members.entries)
                              if (selections['group_id'] == null ||
                                  m.memberGroups[e.key] ==
                                      selections['group_id'])
                                e.key: e.value,
                          }),
                        select('size_id', '默认关联尺寸', m.sizes),
                        select('signature', '默认关联属性', {
                          'unsigned': '无签',
                          'signed': '带签',
                          'homework': '宿题',
                        }),
                        select('active', '启用状态', {'yes': '启用', 'no': '停用'}),
                        field('note', '备注（可空）'),
                      ] else ...[
                        select('definition_id', '券种', {
                          for (final d in m.definitions) d.id: m.label(d),
                        }),
                        field('occurred_on', '发生日期 YYYY-MM-DD（可空）'),
                        field(
                          'quantity',
                          widget.kind == 'purchase'
                              ? '购入张数（可空）'
                              : '调整张数，增加填正数，减少填负数',
                          numeric: true,
                        ),
                        select('pool', '期限', {'long': '长期有效', 'dated': '限时券'}),
                        if (selections['pool'] != 'long')
                          field('expires_on', '截止日 YYYY-MM-DD（可空）'),
                        field('unit_price', '原单价 ¥（未知留空）', numeric: true),
                        field('total_price', '原总金额 ¥（未知留空）', numeric: true),
                        field('reason', '调整原因（可空）'),
                        field('note', '备注（可空）'),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: posted,
                          onChanged: (v) => setState(() => posted = v ?? false),
                          title: const Text('计入库存'),
                          subtitle: const Text('信息可先保存；计入库存需已知归属、张数、日期及期限'),
                        ),
                        if (widget.kind == 'adjustment')
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: expired,
                            onChanged: (v) =>
                                setState(() => expired = v ?? false),
                            title: const Text('允许使用已过期库存'),
                          ),
                      ],
                    ],
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: ChekiColors.danger),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 12,
                    children: [
                      if (review)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() => review = false),
                          child: const Text('返回修改'),
                        ),
                      FilledButton(
                        onPressed: busy
                            ? null
                            : review
                            ? save
                            : check,
                        child: Text(
                          busy
                              ? '保存中'
                              : review
                              ? '确认保存'
                              : '核对',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

const ticketLabels = {
  'name': '券名',
  'group_id': '团体',
  'scope': '范围',
  'member_id': '成员',
  'definition_id': '券种',
  'pool': '期限',
  'occurred_on': '日期',
  'expires_on': '截止日',
  'quantity': '张数',
  'unit_price': '单价',
  'total_price': '总额',
  'note': '备注',
  'reason': '原因',
  'reminder_days': '提醒天数',
  'active': '启用',
  'size_id': '默认尺寸',
  'signature': '默认属性',
};
String ticketSimpleValue(Object? v) => v == null
    ? '未填写'
    : v == true
    ? '是'
    : v == false
    ? '否'
    : {
            'personal': '个人券',
            'group': '团体通用券',
            'long': '长期有效',
            'dated': '限时券',
            'unsigned': '无签',
            'signed': '带签',
            'homework': '宿题',
          }[v] ??
          '$v';
List<Widget> ticketInformationWidgets(TicketModel m, TicketInformation i) => [
  for (final e in i.toMap().entries.where(
    (e) => ticketLabels.containsKey(e.key) && e.key != 'name',
  ))
    Text(
      '${ticketLabels[e.key]}：${e.key == 'definition_id'
          ? m.definitions.where((d) => d.id == e.value).map(m.label).firstOrNull ?? '未填写'
          : e.key == 'group_id'
          ? m.groups[e.value] ?? '未填写'
          : e.key == 'member_id'
          ? m.members[e.value] ?? '未填写'
          : e.key == 'size_id'
          ? m.sizes[e.value] ?? '未填写'
          : ticketSimpleValue(e.value)}',
    ),
];
