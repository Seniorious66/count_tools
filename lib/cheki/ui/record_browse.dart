import 'dart:async';
import 'package:flutter/material.dart';
import '../data/record_query.dart';
import '../data/record_store.dart';
import '../data/ticket_store.dart';
import '../data/entry_store.dart';
import 'coupon_entry.dart';
import 'ticket_pages.dart';
import '../domain/record_contract.dart';
import 'components.dart';
import 'identity_pages.dart' show identityActionLabel;
import 'record_pages.dart';
import 'theme.dart';

AppBar recordAppBar(
  BuildContext context,
  String title, {
  List<Widget> actions = const [],
}) => AppBar(
  toolbarHeight: MediaQuery.textScalerOf(context).scale(24) > 32
      ? MediaQuery.textScalerOf(context).scale(24) * 1.5 + 16
      : 56,
  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
  actions: actions,
);

mixin _RecordReader<T extends StatefulWidget> on State<T> {
  RecordStore get store;
  late Future<RecordReadModel> model;
  StreamSubscription<void>? _subscription;
  @override
  void initState() {
    super.initState();
    model = store.readModel();
    _subscription = RecordStore.changes.listen((_) {
      if (mounted) reload();
    });
  }

  void reload() => setState(() {
    model = store.readModel();
  });
  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Widget readBody(Widget Function(RecordReadModel) build) =>
      FutureBuilder<RecordReadModel>(
        future: model,
        builder: (context, s) {
          if (s.hasError) {
            return Center(
              child: TextButton(
                onPressed: reload,
                child: const Text('读取失败，点击重试'),
              ),
            );
          }
          if (s.connectionState == ConnectionState.waiting || !s.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return build(s.data!);
        },
      );
  Future<void> edit({StoredRecord? original, bool historical = false}) async {
    await Navigator.push<StoredRecord>(
      context,
      MaterialPageRoute(
        builder: (_) => RecordEditPage(
          store: store,
          original: original,
          historical: historical,
        ),
      ),
    );
  }

  Future<void> detail(StoredRecord record) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RecordDetailPage(store: store, record: record),
      ),
    );
  }

  Future<void> bundleDetail(RecordBundle bundle) async {
    if (bundle.records.length == 1) return detail(bundle.representative);
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _RecordBundlePage(
          store: store,
          ids: bundle.records.map((r) => r.id).toSet(),
        ),
      ),
    );
  }
}

class RecordHomePage extends StatefulWidget {
  const RecordHomePage({required this.store, this.ticketStore, super.key});
  final RecordStore store;
  final TicketStore? ticketStore;
  @override
  State<RecordHomePage> createState() => _RecordHomePageState();
}

class _RecordHomePageState extends State<RecordHomePage>
    with _RecordReader<RecordHomePage> {
  @override
  RecordStore get store => widget.store;
  Future<void> _list(RecordFilter filter) async => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => RecordListPage(store: store, initialFilter: filter),
    ),
  );
  @override
  Widget build(BuildContext context) => readBody((m) {
    final day = OccurredOn.shanghaiDay(store.clock());
    final month = m.month(day);
    final monthly = m.summarize(month);
    final all = m.summarize(RecordFilter());
    final pendingFilter = RecordFilter(
      selection: RecordSelection.awaitingReceipt,
    );
    final pending = m.summarize(pendingFilter);
    return RefreshIndicator(
      onRefresh: () async {
        reload();
        await model;
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          TicketOverview(
            store: widget.ticketStore,
            child: InkWell(
              key: const ValueKey('home-month'),
              onTap: () => _list(month),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${day.value.substring(0, 7)} · Cheki'),
                  const SizedBox(height: 8),
                  Text(
                    monthly.quantityLabel,
                    style: const TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Text('已知张数'),
                  if (monthly.unknownQuantityRecords > 0)
                    Text('张数未填写 ${monthly.unknownQuantityRecords} 条'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          ChekiCard(
            color: ChekiColors.surface,
            child: InkWell(
              key: const ValueKey('home-pending'),
              onTap: () => _list(pendingFilter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('未领取 Cheki'),
                  Text(
                    pending.knownReceiptQuantityRecords == 0 &&
                            pending.recordCount > 0
                        ? '待领取张数未填写'
                        : '${pending.knownAwaitingQuantity} 张已知待领',
                  ),
                  if (pending.unknownReceiptQuantityRecords > 0)
                    Text('另 ${pending.unknownReceiptQuantityRecords} 条待补领取张数'),
                  if (all.unknownReceiptRecords > 0)
                    Text('领取状态未填写 ${all.unknownReceiptRecords} 条'),
                ],
              ),
            ),
          ),
          if (all.unknownDateRecords > 0)
            TextButton(
              onPressed: () =>
                  _list(RecordFilter(selection: RecordSelection.undated)),
              child: Text('发生日期未填写 ${all.unknownDateRecords} 条'),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('home-add'),
            onPressed: () => edit(),
            icon: const Icon(Icons.add),
            label: const Text('记一笔'),
          ),
          TextButton(
            onPressed: () => edit(historical: true),
            child: const Text('补录旧信息'),
          ),
          const SizedBox(height: 16),
          Text('最近记录', style: Theme.of(context).textTheme.titleMedium),
          if (m.records.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Text('还没有记录')),
          for (final b in bundleRecords(m.records).take(5))
            _RecordTile(
              record: b.representative,
              bundle: b,
              model: m,
              onTap: () => bundleDetail(b),
            ),
        ],
      ),
    );
  });
}

class RecordListPage extends StatefulWidget {
  const RecordListPage({
    required this.store,
    this.initialFilter,
    this.embedded = false,
    super.key,
  });
  final RecordStore store;
  final RecordFilter? initialFilter;
  final bool embedded;
  @override
  State<RecordListPage> createState() => _RecordListPageState();
}

class _RecordListPageState extends State<RecordListPage>
    with _RecordReader<RecordListPage> {
  @override
  RecordStore get store => widget.store;
  late RecordFilter _filter = widget.initialFilter ?? RecordFilter();
  bool _merged = true;
  List<Widget> get _actions => [
    IconButton(
      tooltip: '补录旧信息',
      onPressed: () => edit(historical: true),
      icon: const Icon(Icons.post_add),
    ),
    IconButton(
      tooltip: '新增记录',
      onPressed: () => edit(),
      icon: const Icon(Icons.add),
    ),
  ];
  Future<void> _filters(RecordReadModel m) async {
    final next = await showModalBottomSheet<RecordFilter>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _RecordFilters(model: m, value: _filter),
    );
    if (mounted && next != null) setState(() => _filter = next);
  }

  @override
  Widget build(BuildContext context) {
    final body = readBody((m) {
      final summary = m.summarize(_filter);
      final days = m.days(_filter);
      return RefreshIndicator(
        onRefresh: () async {
          reload();
          await model;
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (widget.embedded)
              Wrap(alignment: WrapAlignment.end, children: _actions),
            Wrap(
              spacing: 8,
              children: [
                for (final (value, label) in [
                  (RecordSelection.all, '全部'),
                  (RecordSelection.awaitingReceipt, '未领取'),
                  (RecordSelection.incomplete, '待补录'),
                  (RecordSelection.undated, '无日期'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _filter.selection == value,
                    onSelected: (_) => setState(
                      () => _filter = RecordFilter(
                        selection: value,
                        memberId: _filter.memberId,
                        sizeId: _filter.sizeId,
                        from: value == RecordSelection.undated
                            ? null
                            : _filter.from,
                        through: value == RecordSelection.undated
                            ? null
                            : _filter.through,
                      ),
                    ),
                  ),
                ActionChip(
                  label: const Text('筛选'),
                  avatar: const Icon(Icons.filter_list),
                  onPressed: () => _filters(m),
                ),
                FilterChip(
                  label: const Text('合并显示'),
                  selected: _merged,
                  onSelected: (value) => setState(() => _merged = value),
                ),
              ],
            ),
            if (_filter.memberId != null)
              Text('成员：${m.memberLabel(_filter.memberId!)}'),
            if (_filter.sizeId != null)
              Text('尺寸：${m.sizes[_filter.sizeId]?.name ?? '信息不可用'}'),
            if (_filter.from != null || _filter.through != null)
              Text('${_filter.from ?? '不限'} 至 ${_filter.through ?? '不限'}'),
            const SizedBox(height: 12),
            ChekiCard(
              color: ChekiColors.blue,
              child: _SummaryView(summary: summary),
            ),
            if ((_filter.from != null || _filter.through != null) &&
                m.summarize(RecordFilter()).unknownDateRecords > 0)
              TextButton(
                onPressed: () => setState(
                  () => _filter = RecordFilter(
                    selection: RecordSelection.undated,
                  ),
                ),
                child: const Text('查看未填写发生日期的记录'),
              ),
            if (days.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Text('没有符合条件的记录'),
                    TextButton(
                      onPressed: () => setState(() => _filter = RecordFilter()),
                      child: const Text('清除筛选'),
                    ),
                  ],
                ),
              ),
            for (final group in days) ...[
              const SizedBox(height: 20),
              Text(
                group.day ?? '发生日期未填写',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                '已知张数 ${group.summary.quantityLabel} · 成员张数 ${group.summary.memberQuantityLabel}',
              ),
              if (group.summary.bySize.isNotEmpty)
                Text(
                  group.summary.bySize.entries
                      .map(
                        (e) =>
                            '${m.sizes[e.key]?.name ?? '尺寸信息不可用'} ${e.value}张',
                      )
                      .join(' · '),
                ),
              for (final b
                  in _merged
                      ? bundleRecords(group.records)
                      : group.records.map((r) => RecordBundle([r])))
                _RecordTile(
                  record: b.representative,
                  bundle: b,
                  model: m,
                  onTap: () => bundleDetail(b),
                ),
            ],
          ],
        ),
      );
    });
    return widget.embedded
        ? body
        : Scaffold(
            appBar: recordAppBar(context, 'Cheki记录', actions: _actions),
            body: SafeArea(top: false, child: body),
          );
  }
}

class _SummaryView extends StatelessWidget {
  const _SummaryView({required this.summary});
  final RecordSummary summary;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('已知张数 ${summary.quantityLabel}'),
      Text('成员张数 ${summary.memberQuantityLabel}'),
      if (summary.unknownQuantityRecords > 0)
        Text('张数未填写 ${summary.unknownQuantityRecords} 条'),
      if (summary.unknownDateRecords > 0)
        Text('发生日期未填写 ${summary.unknownDateRecords} 条'),
      if (summary.unknownMemberRecords > 0)
        Text('成员未填写 ${summary.unknownMemberRecords} 条'),
      if (summary.unknownSizeRecords > 0)
        Text('尺寸未填写 ${summary.unknownSizeRecords} 条'),
    ],
  );
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.model,
    required this.onTap,
    this.bundle,
  });
  final StoredRecord record;
  final RecordReadModel model;
  final VoidCallback onTap;
  final RecordBundle? bundle;
  @override
  Widget build(BuildContext context) {
    final i = record.information;
    final quantity = bundle?.quantity ?? i.quantity;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ChekiCard(
        child: InkWell(
          key: ValueKey('record-${record.id}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(i.occurredOn?.value ?? '发生日期未填写'),
                if ((i.memberIds ?? []).isEmpty)
                  const Text('成员未填写')
                else
                  for (final id in i.memberIds!)
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: model.members[id]?.colorRgb == null
                                ? ChekiColors.inputBorder
                                : Color(
                                    0xff000000 | model.members[id]!.colorRgb!,
                                  ),
                            border: Border.all(color: ChekiColors.inputBorder),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(model.recordMemberLabel(i, id))),
                      ],
                    ),
                Text(
                  '${quantity == null ? '张数未填写' : '$quantity 张'} · ${i.sizeId == null ? '尺寸未填写' : model.sizes[i.sizeId]?.name ?? '尺寸信息不可用'}',
                ),
                if ((bundle?.records.length ?? 1) > 1)
                  Text(
                    '${bundle!.records.length} 条记录',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Text(
                  '${i.signature?.label ?? '属性未填写'}${i.backSigned == true ? ' · 背签' : ''} · ${i.receiptStatus?.label ?? '领取信息未填写'}',
                ),
                if (i.missingFields.isNotEmpty)
                  Text('待补录：${i.missingFields.join('、')}'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordBundlePage extends StatefulWidget {
  const _RecordBundlePage({required this.store, required this.ids});
  final RecordStore store;
  final Set<String> ids;
  @override
  State<_RecordBundlePage> createState() => _RecordBundlePageState();
}

class _RecordBundlePageState extends State<_RecordBundlePage>
    with _RecordReader<_RecordBundlePage> {
  @override
  RecordStore get store => widget.store;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: recordAppBar(context, '原始记录'),
    body: SafeArea(
      top: false,
      child: readBody((m) {
        final rows = m.records.where((r) => widget.ids.contains(r.id)).toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '共 ${RecordSummary(rows).quantityLabel} 张 · ${rows.length} 条记录',
            ),
            for (final r in rows)
              _RecordTile(record: r, model: m, onTap: () => detail(r)),
          ],
        );
      }),
    ),
  );
}

class _RecordFilters extends StatefulWidget {
  const _RecordFilters({required this.model, required this.value});
  final RecordReadModel model;
  final RecordFilter value;
  @override
  State<_RecordFilters> createState() => _RecordFiltersState();
}

class _RecordFiltersState extends State<_RecordFilters> {
  late String? _member = widget.value.memberId, _size = widget.value.sizeId;
  late String? _from = widget.value.from, _through = widget.value.through;
  Future<void> _range() async {
    final chosen = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1),
      lastDate: DateTime(9999, 12, 31),
      initialDateRange: _from == null || _through == null
          ? null
          : DateTimeRange(
              start: DateTime.parse(_from!),
              end: DateTime.parse(_through!),
            ),
    );
    if (mounted && chosen != null) {
      setState(() {
        _from = chosen.start.toIso8601String().substring(0, 10);
        _through = chosen.end.toIso8601String().substring(0, 10);
      });
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .8,
    child: Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('筛选记录', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _member,
                decoration: const InputDecoration(labelText: '成员'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('所有成员')),
                  for (final id in widget.model.members.keys)
                    DropdownMenuItem(
                      value: id,
                      child: Text(widget.model.memberLabel(id)),
                    ),
                ],
                onChanged: (v) => setState(() => _member = v == '' ? null : v),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _size,
                decoration: const InputDecoration(labelText: '尺寸'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('所有尺寸')),
                  for (final s in widget.model.sizes.values)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _size = v == '' ? null : v),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _range,
                icon: const Icon(Icons.date_range),
                label: Text(_from == null ? '选择日期范围' : '$_from 至 $_through'),
              ),
              if (_from != null)
                TextButton(
                  onPressed: () => setState(() {
                    _from = null;
                    _through = null;
                  }),
                  child: const Text('清除日期范围'),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      RecordFilter(
                        selection:
                            _from != null &&
                                widget.value.selection ==
                                    RecordSelection.undated
                            ? RecordSelection.all
                            : widget.value.selection,
                        memberId: _member,
                        sizeId: _size,
                        from: _from,
                        through: _through,
                      ),
                    ),
                    child: const Text('应用'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class RecordDetailPage extends StatefulWidget {
  const RecordDetailPage({
    required this.store,
    required this.record,
    super.key,
  });
  final RecordStore store;
  final StoredRecord record;
  @override
  State<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends State<RecordDetailPage>
    with _RecordReader<RecordDetailPage> {
  @override
  RecordStore get store => widget.store;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: recordAppBar(context, '记录详情'),
    body: SafeArea(
      top: false,
      child: readBody((m) {
        final r = m.records.where((r) => r.id == widget.record.id).firstOrNull;
        if (r == null) {
          return Center(
            child: TextButton(
              onPressed: reload,
              child: const Text('记录不可用，点击重试'),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            RecordInformationView(info: r.information, store: store),
            const SizedBox(height: 16),
            RecordCouponView(
              recordId: r.id,
              info: r.information,
              store: EntryStore(store.database, clock: store.clock),
            ),
            const SizedBox(height: 16),
            Text('录入时间：${identityActionLabel(r.createdAt)}'),
            Text('修改时间：${identityActionLabel(r.updatedAt)}'),
            if (r.information.missingFields.isNotEmpty)
              Text('待补录：${r.information.missingFields.join('、')}'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => edit(original: r),
              child: const Text('修改记录'),
            ),
            if (r.information.receiptStatus != ReceiptStatus.received)
              OutlinedButton(
                onPressed: () => Navigator.push<StoredRecord>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RecordEditPage(
                      store: store,
                      original: r,
                      addReceipt: true,
                    ),
                  ),
                ),
                child: Text(
                  r.information.receiptStatus == null ? '补录领取' : '补领',
                ),
              ),
            TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => RecordHistoryPage(store: store, record: r),
                ),
              ),
              child: const Text('记录历史'),
            ),
          ],
        );
      }),
    ),
  );
}
