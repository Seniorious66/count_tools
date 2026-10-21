import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/bi_query.dart';
import '../data/record_query.dart';
import '../data/record_store.dart';
import '../data/ticket_store.dart';
import '../domain/record_contract.dart';
import '../domain/ticket_information.dart';
import 'components.dart';
import 'record_pages.dart';
import 'record_browse.dart' show recordAppBar;
import 'theme.dart';
import 'ticket_pages.dart';
import 'member_pie.dart';
import 'spending_page.dart';
import 'bi_date_picker.dart';

class BiFileAccess {
  static const channel = MethodChannel('com.seniorious66.counttools/backup');
  Future<bool> save(String csv) async =>
      await channel.invokeMethod<bool>('exportCsv', {
        'bytes': Uint8List.fromList(utf8.encode(csv)),
        'name': 'Cheki-statistics.csv',
      }) ??
      false;
}

class BiPage extends StatefulWidget {
  const BiPage({
    required this.store,
    required this.records,
    this.access,
    this.initialPeriod,
    this.reportsOnly = false,
    super.key,
  });
  final BiStore store;
  final RecordStore records;
  final BiFileAccess? access;
  final BiPeriod? initialPeriod;
  final bool reportsOnly;
  @override
  State<BiPage> createState() => _BiPageState();
}

class _BiPageState extends State<BiPage> {
  late Future<BiSnapshot> snapshot;
  late BiPeriod period;
  final subscriptions = <StreamSubscription<void>>[];
  String? group;
  String? member, person, size, signature, receipt, back;
  BiRecordFilter get filter => BiRecordFilter(
    memberId: member,
    personId: person,
    sizeId: size,
    signature: signature,
    receipt: receipt,
    backSigned: back == null || back == 'unknown' ? null : back == 'yes',
    unknownBack: back == 'unknown',
  );
  bool persons = false, exporting = false;
  String? message;
  @override
  void initState() {
    super.initState();
    period =
        widget.initialPeriod ??
        BiPeriod(
          BiScope.month,
          OccurredOn.shanghaiDay(widget.store.clock()).value,
        );
    snapshot = widget.store.read();
    subscriptions.add(RecordStore.changes.listen((_) => refresh()));
    subscriptions.add(TicketStore.changes.listen((_) => refresh()));
  }

  void refresh() {
    if (mounted) {
      setState(() {
        snapshot = widget.store.read();
      });
    }
  }

  @override
  void dispose() {
    for (final s in subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> date() async {
    final selected = await chooseBiDate(
      context,
      period.anchor,
      today: OccurredOn.shanghaiDay(widget.store.clock()).value,
    );
    if (selected != null && mounted) {
      setState(() => period = BiPeriod(period.scope, selected));
    }
  }

  Future<void> export(BiReport report) async {
    if (exporting) return;
    setState(() {
      exporting = true;
      message = null;
    });
    try {
      final saved = await (widget.access ?? BiFileAccess()).save(report.csv());
      if (mounted) {
        setState(() => message = saved ? '统计 CSV 已保存到所选位置' : '已取消保存');
      }
    } catch (_) {
      if (mounted) setState(() => message = '保存失败，请重试；账本未改变');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.reportsOnly
      ? Scaffold(
          appBar: recordAppBar(context, '报表与导出'),
          body: SafeArea(top: false, child: body()),
        )
      : body();

  List<Widget> expenseLinks() => [
    for (final groups in [false, true])
      TextButton(
        key: ValueKey(groups ? 'group-expenses' : 'member-expenses'),
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SpendingPage(
              store: widget.store,
              records: widget.records,
              period: period,
              group: group,
              member: member,
              groups: groups,
              exportCsv: widget.reportsOnly
                  ? (csv) => (widget.access ?? BiFileAccess()).save(csv)
                  : null,
            ),
          ),
        ),
        child: Text(groups ? '团体花费' : '成员花费'),
      ),
  ];

  Widget body() => FutureBuilder<BiSnapshot>(
    future: snapshot,
    builder: (context, state) {
      if (state.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (state.hasError || !state.hasData) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('统计读取失败'),
              TextButton(onPressed: refresh, child: const Text('重试')),
            ],
          ),
        );
      }
      final source = state.data!,
          report = source.report(period, groupId: group, filter: filter);
      final list = report.sortedMembers(person: persons);
      final denominator = persons
          ? report.personQuantity
          : report.memberQuantity;
      final excluded = source.records.records
          .where(
            (r) =>
                r.information.occurredOn == null &&
                filter.matches(r, source.records) &&
                (group == null ||
                    (r.information.memberIds ?? []).any(
                      (id) => source.records.members[id]?.groupId == group,
                    )),
          )
          .length;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const ValueKey('bi-today'),
                label: const Text('今日'),
                selected:
                    period.scope == BiScope.day &&
                    period.anchor ==
                        OccurredOn.shanghaiDay(widget.store.clock()).value,
                onSelected: (_) => setState(
                  () => period = BiPeriod(
                    BiScope.day,
                    OccurredOn.shanghaiDay(widget.store.clock()).value,
                  ),
                ),
              ),
              for (final scope in BiScope.values)
                ChoiceChip(
                  label: Text(scope.label),
                  selected:
                      scope == period.scope &&
                      (scope != BiScope.day ||
                          period.anchor !=
                              OccurredOn.shanghaiDay(
                                widget.store.clock(),
                              ).value),
                  onSelected: (_) =>
                      setState(() => period = BiPeriod(scope, period.anchor)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: switch (period.scope) {
                  BiScope.month => '上月',
                  BiScope.year => '上一年',
                  BiScope.day => '前一天',
                  BiScope.week => '上一周',
                  BiScope.all => '上一期间',
                },
                onPressed:
                    period.scope == BiScope.all || period.from == '0001-01-01'
                    ? null
                    : () => setState(() => period = period.move(-1)),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: TextButton(
                  onPressed: period.scope == BiScope.all ? null : date,
                  child: Text(period.label, textAlign: TextAlign.center),
                ),
              ),
              IconButton(
                tooltip: switch (period.scope) {
                  BiScope.month => '下月',
                  BiScope.year => '下一年',
                  BiScope.day => '后一天',
                  BiScope.week => '下一周',
                  BiScope.all => '下一期间',
                },
                onPressed:
                    period.scope == BiScope.all ||
                        period.through == '9999-12-31'
                    ? null
                    : () => setState(() => period = period.move(1)),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          // Floating input labels extend above the border, especially at 200%.
          // Keep them clear of the multiline period selector on narrow screens.
          const SizedBox(height: 24),
          DropdownButtonFormField<String>(
            initialValue: group,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '团体筛选'),
            items: [
              const DropdownMenuItem(value: null, child: Text('所有团体')),
              for (final g in source.records.groups.values)
                DropdownMenuItem(
                  value: g.id,
                  child: Text(g.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) => setState(() => group = id),
          ),
          ExpansionTile(
            title: const Text('更多筛选'),
            children: [
              _filterField('成员', member, {
                for (final m in source.records.members.values)
                  m.id: source.records.memberLabel(m.id),
              }, (v) => setState(() => member = v)),
              _filterField('同人关联', person, {
                for (final p in source.persons.values) p.id: p.name,
              }, (v) => setState(() => person = v)),
              _filterField('尺寸', size, {
                for (final z in source.records.sizes.values) z.id: z.name,
                '@unknown': '尺寸未填写',
              }, (v) => setState(() => size = v)),
              _filterField('属性', signature, {
                'unsigned': '无签',
                'signed': '带签',
                'homework': '宿题',
                '@unknown': '属性未填写',
              }, (v) => setState(() => signature = v)),
              _filterField('背签', back, {
                'yes': '有背签',
                'no': '无背签',
                'unknown': '背签情况未填写',
              }, (v) => setState(() => back = v)),
              _filterField('领取', receipt, {
                'received': '已领取',
                'partial': '部分领取',
                'unreceived': '未领取',
                '@unknown': '领取情况未填写',
              }, (v) => setState(() => receipt = v)),
              TextButton(
                onPressed: () => setState(() {
                  member = null;
                  person = null;
                  size = null;
                  signature = null;
                  receipt = null;
                  back = null;
                }),
                child: const Text('清除更多筛选'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!widget.reportsOnly) ...[
            ChekiCard(
              color: ChekiColors.blue,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${report.summary.quantityLabel} 张',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  Text(
                    '成员参与 ${report.memberQuantityLabel} 张 · ${report.rows.length} 条记录',
                  ),
                  if (report.summary.unknownQuantityRecords > 0)
                    Text('${report.summary.unknownQuantityRecords} 条张数未填写'),
                  if (report.summary.unknownMemberRecords > 0)
                    Text('${report.summary.unknownMemberRecords} 条成员未填写'),
                  if (excluded > 0)
                    Text(
                      period.scope == BiScope.all
                          ? '$excluded 条日期未填写，另列展示'
                          : '$excluded 条日期未填写，未归入此期间',
                    ),
                  if (report.rows.isEmpty) const Text('这个范围还没有记录'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                ...expenseLinks(),
                ChoiceChip(
                  label: const Text('成员'),
                  selected: !persons,
                  onSelected: (_) => setState(() => persons = false),
                ),
                ChoiceChip(
                  label: const Text('同人关联'),
                  selected: persons,
                  onSelected: (_) => setState(() => persons = true),
                ),
              ],
            ),
            if (persons) const Text('仅合并手动关联的身份；未关联成员各自保留。'),
            ChekiCard(
              child: Column(
                children: [
                  if (list.isEmpty) const Text('还没有可统计的成员'),
                  for (final m in list)
                    _CountRow(
                      label: m.label,
                      quantity: m.quantity,
                      denominator: denominator,
                      unknown: m.unknownRecords,
                      detail: m.bySize.entries
                          .map(
                            (e) =>
                                '${source.records.sizes[e.key]?.name ?? '尺寸未填写'} ${e.value}',
                          )
                          .join(' · '),
                      color: _memberColor(m.colorRgb),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BiMemberPage(
                            store: widget.store,
                            records: widget.records,
                            period: period,
                            group: group,
                            filter: filter,
                            memberIds: m.memberIds,
                            label: m.label,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _BiRecordsPage(
                    store: widget.records,
                    ids: report.rows.map((r) => r.id).toSet(),
                    label: '所选期间记录',
                    filterByDay: false,
                    filter: filter,
                    group: group,
                  ),
                ),
              ),
              child: const Text('查看所选期间记录'),
            ),
            KeyedSubtree(
              key: const ValueKey('bi-daily-section'),
              child: _section(context, '每日张数', [
                if (report.days.isEmpty) const Text('没有发生日期记录'),
                if (report.days.isNotEmpty)
                  SizedBox(
                    height: 120,
                    child: Semantics(
                      label:
                          '每日张数趋势，${report.days.keys.whereType<String>().length}个日期；下方列表可查看具体数量',
                      child: CustomPaint(painter: _DailyLine(report.days)),
                    ),
                  ),
                for (final entry in _sortedDays(report.days).take(5))
                  ListTile(
                    key: ValueKey('bi-day-preview-${entry.key ?? 'unknown'}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.key ?? '日期未填写'),
                    trailing: Text(
                      '${RecordSummary(entry.value).quantityLabel} 张',
                    ),
                    onTap: () => _dayRecords(
                      context,
                      widget.records,
                      entry.value,
                      entry.key ?? '日期未填写',
                      filter: filter,
                      group: group,
                    ),
                  ),
                if (report.days.length > 5)
                  TextButton(
                    key: const ValueKey('bi-all-days'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _BiAllDays(
                          records: widget.records,
                          days: report.days,
                          filter: filter,
                          group: group,
                        ),
                      ),
                    ),
                    child: Text('查看全部 ${report.days.length} 个日期'),
                  ),
              ]),
            ),
            KeyedSubtree(
              key: const ValueKey('bi-pie-section'),
              child: _section(context, persons ? '同人占比' : '成员占比', [
                MemberPie(
                  slices: [
                    for (final m in list)
                      MemberPieSlice(
                        m.id,
                        m.label,
                        m.quantity,
                        m.unknownRecords,
                        _memberColor(m.colorRgb),
                      ),
                  ],
                  denominator: denominator,
                ),
              ]),
            ),
            _section(context, '尺寸', [
              for (final e in report.sizes.entries)
                _CountRow(
                  label: source.records.sizes[e.key]?.name ?? '未填写尺寸',
                  quantity: e.value,
                  denominator: report.summary.knownQuantity,
                  color: ChekiColors.blueInk,
                ),
            ]),
            _section(context, '属性', [
              for (final e in report.signatures.entries)
                _CountRow(
                  label: _signature(e.key),
                  quantity: e.value,
                  denominator: report.summary.knownQuantity,
                  color: ChekiColors.blueInk,
                ),
              Text('带签中的背签 ${report.backSigned} 张'),
              if (report.backUnknown > 0)
                Text('带签中 ${report.backUnknown} 张背签情况未填写'),
            ]),
          ],
          if (widget.reportsOnly) ...[
            Wrap(spacing: 8, children: expenseLinks()),
            _section(context, '购券与成本', [
              if (member != null ||
                  person != null ||
                  size != null ||
                  signature != null ||
                  receipt != null ||
                  back != null)
                const Text('券金额和库存按期间与团体筛选；用券成本按所选 Cheki 筛选。'),
              if (report.purchase.hasAmount)
                _value('购券金额', report.purchase.displayLabel),
              if (report.purchase.hasAmount)
                _value('购入均价', report.purchase.average),
              for (final p in report.purchases.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(report.definitionLabel(p.key)),
                      Text(
                        '购入 ${p.value.knownQuantity + p.value.unknownQuantity} 张${p.value.hasAmount ? ' · 金额 ${p.value.displayLabel}' : ''}',
                      ),
                      if (p.value.hasAmount) Text('均价 ${p.value.average}'),
                    ],
                  ),
                ),
              if (report.consumedRecordCost.hasAmount)
                _value('所选 Cheki 花费', report.consumedRecordCost.displayLabel),
            ], color: ChekiColors.pink),
            _section(context, '期间券流水', [
              if (report.flows.isEmpty) const Text('本期间没有已入账券流水'),
              for (final f in report.flows.values)
                if (f.cost.hasAmount)
                  _value('${f.kind} ${f.quantity} 张', f.cost.displayLabel)
                else
                  Text('${f.kind} ${f.quantity} 张'),
              if (report.draftCount > 0)
                Text('${report.draftCount} 条草稿未入账，不计库存与金额'),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _FlowPage(
                      report: report,
                      store: TicketStore(widget.store.database),
                    ),
                  ),
                ),
                child: const Text('查看流水明细'),
              ),
            ]),
            _section(context, '库存 · 截至 ${report.cutoff}', [
              if (period.scope == BiScope.all)
                const Text('所有期间流水包含未来已记账日期，库存仅截止今天。'),
              if (report.stocks.isEmpty) const Text('截止此日无剩余库存'),
              for (final s in report.stocks.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.label,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '可用 ${s.available} 张${s.availableCost.hasAmount ? ' · 成本 ${s.availableCost.displayLabel}' : ''}',
                      ),
                      if (s.datedAvailable > 0)
                        Text(
                          '限时 ${s.datedAvailable} 张${s.longAvailable > 0 ? ' · 长期 ${s.longAvailable} 张' : ''}',
                        ),
                      if (s.nearExpiry > 0) Text('临期 ${s.nearExpiry} 张'),
                      if (s.expired > 0)
                        Text(
                          '过期 ${s.expired} 张${s.expiredCost.hasAmount ? ' · 成本 ${s.expiredCost.displayLabel}' : ''}',
                        ),
                      if (s.cost.hasAmount) Text('库存成本 ${s.cost.displayLabel}'),
                    ],
                  ),
                ),
            ], color: ChekiColors.pink),
            FilledButton.icon(
              onPressed: exporting ? null : () => export(report),
              icon: const Icon(Icons.save_alt),
              label: Text(exporting ? '正在保存…' : '保存统计 CSV'),
            ),
            const Text('选择保存位置；统计 CSV 不用于恢复完整账本。'),
            if (message != null)
              Text(message!, key: const ValueKey('bi-export-result')),
          ],
        ],
      );
    },
  );
}

Color _memberColor(int? rgb) =>
    rgb == null ? ChekiColors.muted : Color(0xff000000 | rgb);
Widget _filterField(
  String label,
  String? value,
  Map<String, String> options,
  ValueChanged<String?> changed,
) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: DropdownButtonFormField<String>(
    key: ValueKey('$label:$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      const DropdownMenuItem(value: null, child: Text('所有')),
      for (final e in options.entries)
        DropdownMenuItem(
          value: e.key,
          child: Text(e.value, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: changed,
  ),
);
String _signature(String? s) => switch (s) {
  'signed' => '带签',
  'unsigned' => '无签',
  'homework' => '宿题',
  _ => '未填写属性',
};
// Original record detail labels keep receipt state after removing its BI panel.
String _receipt(String? s) => switch (s) {
  'received' => '已领取',
  'partial' => '部分领取',
  'unreceived' => '未领取',
  _ => '领取情况未填写',
};
Widget _value(String name, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(name),
      SelectableText(
        value,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ],
  ),
);
Widget _section(
  BuildContext context,
  String label,
  List<Widget> children, {
  Color color = ChekiColors.surface,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 16),
  child: ChekiCard(
    color: color,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  ),
);
List<MapEntry<String?, List<StoredRecord>>> _sortedDays(
  Map<String?, List<StoredRecord>> days,
) => days.entries.toList()
  ..sort(
    (a, b) => a.key == null
        ? (b.key == null ? 0 : 1)
        : b.key == null
        ? -1
        : b.key!.compareTo(a.key!),
  );

class _CountRow extends StatelessWidget {
  const _CountRow({
    required this.label,
    required this.quantity,
    required this.denominator,
    required this.color,
    this.unknown = 0,
    this.detail,
    this.onTap,
  });
  final String label;
  final int quantity, denominator, unknown;
  final String? detail;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          if (detail != null && detail!.isNotEmpty) Text(detail!),
          Text(
            '${unknown > 0 && quantity == 0 ? '张数未填写' : '$quantity 张'} · ${biShareLabel(quantity, denominator, unknown: unknown)}${unknown > 0 ? ' · $unknown 条张数未填写' : ''}',
          ),
          const SizedBox(height: 6),
          Container(
            height: 8,
            decoration: BoxDecoration(
              color: ChekiColors.line,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: ChekiColors.inputBorder),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: denominator == 0 ? 0 : quantity / denominator,
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class BiMemberPage extends StatefulWidget {
  const BiMemberPage({
    required this.store,
    required this.records,
    required this.period,
    required this.memberIds,
    required this.label,
    this.group,
    this.filter = const BiRecordFilter(),
    super.key,
  });
  final BiStore store;
  final RecordStore records;
  final BiPeriod period;
  final Set<String> memberIds;
  final String label;
  final String? group;
  final BiRecordFilter filter;
  @override
  State<BiMemberPage> createState() => _BiMemberPageState();
}

class _BiMemberPageState extends State<BiMemberPage> {
  late Future<BiSnapshot> snapshot;
  final subscriptions = <StreamSubscription<void>>[];
  @override
  void initState() {
    super.initState();
    snapshot = widget.store.read();
    subscriptions.add(RecordStore.changes.listen((_) => reload()));
    subscriptions.add(TicketStore.changes.listen((_) => reload()));
  }

  void reload() {
    if (mounted) {
      setState(() {
        snapshot = widget.store.read();
      });
    }
  }

  @override
  void dispose() {
    for (final s in subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.label)),
    body: FutureBuilder<BiSnapshot>(
      future: snapshot,
      builder: (context, state) {
        if (state.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.hasError || !state.hasData) {
          return Center(
            child: TextButton(onPressed: reload, child: const Text('读取失败，重试')),
          );
        }
        final report = state.data!.report(
              widget.period,
              groupId: widget.group,
              filter: widget.filter,
            ),
            rows = report.memberRows(widget.memberIds),
            days = <String?, List<StoredRecord>>{};
        for (final r in rows) {
          days.putIfAbsent(r.information.occurredOn?.value, () => []).add(r);
        }
        final color = _memberColor(
          state.data!.records.members[widget.memberIds.first]?.colorRgb,
        );
        final summary = RecordSummary(rows);
        Future<void> open(String? day) async {
          await _dayRecords(
            context,
            widget.records,
            rows.where((r) => r.information.occurredOn?.value == day).toList(),
            day ?? '日期未填写',
            filter: widget.filter,
            group: widget.group,
            memberIds: widget.memberIds,
          );
          reload();
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.period.label),
            if (widget.memberIds.length == 1)
              TextButton(
                key: const ValueKey('member-daily-expenses'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SpendingPage(
                      store: widget.store,
                      records: widget.records,
                      period: widget.period,
                      group: widget.group,
                      member: widget.memberIds.length == 1
                          ? widget.memberIds.single
                          : null,
                    ),
                  ),
                ),
                child: const Text('查看成员花费'),
              ),
            Text(
              '${summary.quantityLabel} 张',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            if (summary.unknownQuantityRecords > 0)
              Text('${summary.unknownQuantityRecords} 条张数未填写'),
            if (widget.period.scope == BiScope.month)
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth <= 348 ||
                      MediaQuery.textScalerOf(context).scale(15) > 20) {
                    return OutlinedButton.icon(
                      onPressed: () async {
                        final d = await chooseBiDate(
                          context,
                          widget.period.anchor,
                          from: widget.period.from,
                          through: widget.period.through,
                        );
                        if (d != null && context.mounted) open(d);
                      },
                      icon: const Icon(Icons.calendar_month),
                      label: const Text('选择日期查看'),
                    );
                  }
                  final first = DateTime.parse(widget.period.from!),
                      end = DateTime.parse(widget.period.through!),
                      offset = first.weekday - 1;
                  return Wrap(
                    children: [
                      for (var index = 0; index < offset + end.day; index++)
                        SizedBox(
                          width: constraints.maxWidth / 7,
                          height: 88,
                          child: index < offset
                              ? null
                              : Builder(
                                  builder: (context) {
                                    final day = biDay(
                                          DateTime.utc(
                                            first.year,
                                            first.month,
                                            index - offset + 1,
                                          ),
                                        ),
                                        items = days[day] ?? [],
                                        sum = RecordSummary(items);
                                    return Semantics(
                                      label: '$day ${sum.quantityLabel}张',
                                      child: TextButton(
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 6,
                                          ),
                                        ),
                                        onPressed: () => open(day),
                                        child: Column(
                                          children: [
                                            Text('${index - offset + 1}'),
                                            Text(
                                              sum.quantityLabel,
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                            if (items.isNotEmpty)
                                              Container(
                                                height: 4,
                                                color: color,
                                              ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                    ],
                  );
                },
              ),
            for (final d in _sortedDays(days))
              _CountRow(
                label: d.key ?? '日期未填写',
                quantity: RecordSummary(d.value).knownQuantity,
                unknown: RecordSummary(d.value).unknownQuantityRecords,
                denominator: summary.knownQuantity,
                color: color,
                onTap: () => open(d.key),
              ),
            if (days.isEmpty) const Text('此期间没有记录'),
          ],
        );
      },
    ),
  );
}

Future<void> _dayRecords(
  BuildContext context,
  RecordStore store,
  List<StoredRecord> rows,
  String label, {
  BiRecordFilter filter = const BiRecordFilter(),
  String? group,
  Set<String>? memberIds,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => _BiRecordsPage(
      store: store,
      ids: rows.map((r) => r.id).toSet(),
      label: label,
      filter: filter,
      group: group,
      memberIds: memberIds,
    ),
  ),
);

class _BiRecordsPage extends StatefulWidget {
  const _BiRecordsPage({
    required this.store,
    required this.ids,
    required this.label,
    this.filterByDay = true,
    this.filter = const BiRecordFilter(),
    this.group,
    this.memberIds,
  });
  final RecordStore store;
  final Set<String> ids;
  final String label;
  final bool filterByDay;
  final BiRecordFilter filter;
  final String? group;
  final Set<String>? memberIds;
  @override
  State<_BiRecordsPage> createState() => _BiRecordsPageState();
}

class _BiRecordsPageState extends State<_BiRecordsPage> {
  late Future<RecordReadModel> model = widget.store.readModel();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.label)),
    body: FutureBuilder<RecordReadModel>(
      future: model,
      builder: (context, state) {
        if (state.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state.hasError || !state.hasData) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() {
                model = widget.store.readModel();
              }),
              child: const Text('读取失败，重试'),
            ),
          );
        }
        final m = state.data!,
            rows = m.records
                .where(
                  (r) =>
                      widget.ids.contains(r.id) &&
                      widget.filter.matches(r, m) &&
                      (widget.group == null ||
                          (r.information.memberIds ?? []).any(
                            (id) => m.members[id]?.groupId == widget.group,
                          )) &&
                      (widget.memberIds == null ||
                          (r.information.memberIds ?? []).any(
                            widget.memberIds!.contains,
                          )) &&
                      (!widget.filterByDay ||
                          r.information.occurredOn?.value ==
                              (widget.label == '日期未填写' ? null : widget.label)),
                )
                .toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (rows.isEmpty) const Text('0 张，没有记录'),
            for (final r in rows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${r.information.quantity ?? '未填写'} 张 · ${r.information.occurredOn?.value ?? '日期未填写'}',
                ),
                subtitle: Text(
                  '${(r.information.memberIds ?? []).map((id) => m.recordMemberLabel(r.information, id)).join('、')}\n${m.sizes[r.information.sizeId]?.name ?? '尺寸未填写'} · ${_signature(r.information.signature?.name)} · ${_receipt(r.information.receiptStatus?.name)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          RecordDetailPage(store: widget.store, record: r),
                    ),
                  );
                  if (mounted) {
                    setState(() {
                      model = widget.store.readModel();
                    });
                  }
                },
              ),
          ],
        );
      },
    ),
  );
}

class _BiAllDays extends StatelessWidget {
  const _BiAllDays({
    required this.records,
    required this.days,
    this.filter = const BiRecordFilter(),
    this.group,
  });
  final RecordStore records;
  final Map<String?, List<StoredRecord>> days;
  final BiRecordFilter filter;
  final String? group;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('每日张数')),
    body: ListView(
      children: [
        for (final d in _sortedDays(days))
          ListTile(
            title: Text(d.key ?? '日期未填写'),
            trailing: Text('${RecordSummary(d.value).quantityLabel} 张'),
            onTap: () => _dayRecords(
              context,
              records,
              d.value,
              d.key ?? '日期未填写',
              filter: filter,
              group: group,
            ),
          ),
      ],
    ),
  );
}

class _FlowPage extends StatelessWidget {
  const _FlowPage({required this.report, required this.store});
  final BiReport report;
  final TicketStore store;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('期间券流水')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final t in report.flowRows)
          ChekiCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${t.information.day} · ${report.flowKind(t)} ${t.information.quantity!.abs()} 张',
                ),
                Text(
                  report.source.tickets
                      .where((d) => d.id == t.information.text('definition_id'))
                      .map((d) => report.definitionLabel(d.id))
                      .join(),
                ),
                if (t.information.quantity! > 0)
                  if (t.unitCost != null)
                    Text('单张成本 ${t.unitCost!.roundedYuan}'),
                for (final a in t.allocations)
                  Text(
                    '${a['quantity']} 张${a['cost'] == null ? '' : ' · 来源成本 ${TicketMoney.fromExact(a['cost'] as String).roundedYuan}'}',
                  ),
                if (t.information.text('unit_price') != null)
                  Text(
                    '原单价 ¥${TicketMoney.parse(t.information.text('unit_price')!).roundedYuan}',
                  ),
                if (t.information.text('total_price') != null)
                  Text(
                    '原总额 ¥${TicketMoney.parse(t.information.text('total_price')!).roundedYuan}',
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TicketDetailPage(store: store, id: t.id),
                    ),
                  ),
                  child: const Text('查看来源与原记录'),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _DailyLine extends CustomPainter {
  _DailyLine(Map<String?, List<StoredRecord>> days) {
    for (final entry in days.entries) {
      if (entry.key == null) continue;
      final summary = RecordSummary(entry.value);
      if (summary.knownQuantityRecords == 0 &&
          summary.unknownQuantityRecords > 0) {
        continue;
      }
      points.add((
        DateTime.parse('${entry.key}T00:00:00Z'),
        summary.knownQuantity,
      ));
    }
    points.sort((a, b) => a.$1.compareTo(b.$1));
  }
  final points = <(DateTime, int)>[];
  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final maximum = math.max(1, points.map((p) => p.$2).reduce(math.max));
    final span = points.last.$1.difference(points.first.$1).inDays;
    final paint = Paint()
      ..color = ChekiColors.blueInk
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = span == 0
          ? size.width / 2
          : 8 +
                (size.width - 16) *
                    points[i].$1.difference(points.first.$1).inDays /
                    span;
      final y = size.height - 8 - (size.height - 16) * points[i].$2 / maximum;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 3, Paint()..color = ChekiColors.blueInk);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_DailyLine oldDelegate) => true;
}
