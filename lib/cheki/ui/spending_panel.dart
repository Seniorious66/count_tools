import 'package:flutter/material.dart';
import '../data/bi_query.dart';
import '../data/member_statistics.dart';
import '../data/record_store.dart';
import '../data/spending_query.dart';
import '../data/transfer_store.dart';
import 'components.dart';
import 'record_pages.dart';
import 'transfer_pages.dart';
import 'statistics_style.dart';

/// An inline view of the current statistics snapshot, not a second route/query.
class SpendingPanel extends StatefulWidget {
  const SpendingPanel({
    required this.source,
    required this.period,
    required this.records,
    this.group,
    this.filter = const BiRecordFilter(),
    this.exportCsv,
    this.onChanged,
    this.groupMode,
    this.framed = true,
    super.key,
  });
  final BiSnapshot source;
  final BiPeriod period;
  final RecordStore records;
  final String? group;
  final BiRecordFilter filter;
  final Future<bool> Function(String)? exportCsv;
  final VoidCallback? onChanged;

  /// When supplied, the parent owns the shared count/spending view selector.
  final bool? groupMode;
  final bool framed;
  @override
  State<SpendingPanel> createState() => _SpendingPanelState();
}

class _SpendingPanelState extends State<SpendingPanel> {
  bool localGroups = false, exporting = false;
  bool get groups => widget.groupMode ?? localGroups;
  String? message;
  Future<void> open(SpendingLine line) async {
    if (line.record != null) {
      final current = (await widget.records.list())
          .where((r) => r.id == line.record!.id)
          .firstOrNull;
      if (!mounted || current == null) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              RecordDetailPage(store: widget.records, record: current),
        ),
      );
    } else if (line.ticket != null) {
      final store = TransferStore(widget.records.database);
      final transfer = await store.forTicket(line.ticket!.id);
      if (!mounted || transfer == null) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => TransferDetailPage(store: store, id: transfer.id),
        ),
      );
    }
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final report = SpendingReport(
      widget.source,
      widget.period,
      filter: widget.filter,
    );
    final identity = MemberStatistics(widget.source.records);
    final rows = report.assigned(group: widget.group);
    final buckets = <String, List<SpendingLine>>{};
    final common = <SpendingLine>[];
    for (final row in rows) {
      final id = groups ? row.groupId : row.memberId;
      if (id == null) {
        common.add(row);
        continue;
      }
      final key = groups ? id : identity.representative(id);
      (buckets[key] ??= []).add(row);
    }
    // A cross-group expense remains shared, including when one group is selected.
    for (final row in report.shared(group: widget.group)) {
      if (!common.any((l) => l.id == row.id) &&
          !rows.any((l) => l.id == row.id)) {
        common.add(row);
      }
    }
    final keys = buckets.keys.toList()
      ..sort((a, b) {
        final aa = report.total(buckets[a]!).known,
            bb = report.total(buckets[b]!).known;
        final order = (bb.numerator * aa.denominator).compareTo(
          aa.numerator * bb.denominator,
        );
        return order != 0 ? order : a.compareTo(b);
      });
    final total = report.total({...rows, ...common});
    Widget line(SpendingLine l) => ListTile(
      key: ValueKey('expense-line-${l.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text('${l.day ?? '日期未填写'} · ${l.kind}'),
      subtitle: l.amount.hasAmount ? Text(l.amount.label) : null,
      onTap: () => open(l),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.groupMode == null)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const ValueKey('member-expenses'),
                label: const Text('成员花费'),
                selected: !groups,
                onSelected: (_) => setState(() => localGroups = false),
              ),
              ChoiceChip(
                key: const ValueKey('group-expenses'),
                label: const Text('团体花费'),
                selected: groups,
                onSelected: (_) => setState(() => localGroups = true),
              ),
            ],
          ),
        if (total.hasAmount)
          Text(
            total.label,
            key: const ValueKey('expense-total'),
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
              fontSize: Theme.of(context).textTheme.bodyMedium?.fontSize,
            ),
          ),
        if (keys.isEmpty && common.isEmpty) const Text('没有可统计的花费明细'),
        for (final id in keys)
          ExpansionTile(
            key: ValueKey('expense-${groups ? 'group' : 'member'}-$id'),
            tilePadding: EdgeInsets.zero,
            title: Text(
              groups
                  ? widget.source.records.groups[id]?.name ?? '团体未填写'
                  : identity.label(id),
            ),
            leading: groups
                ? null
                : StatisticsDot(
                    color: Color(0xff000000 | (identity.color(id) ?? 0x7c8ea0)),
                  ),
            subtitle: report.total(buckets[id]!).hasAmount
                ? Text(report.total(buckets[id]!).label)
                : null,
            children: [for (final l in buckets[id]!) line(l)],
          ),
        if (common.isNotEmpty)
          ExpansionTile(
            title: const Text('共同费用（未分摊）'),
            tilePadding: EdgeInsets.zero,
            subtitle: report.total(common).hasAmount
                ? Text(report.total(common).label)
                : null,
            children: [for (final l in common) line(l)],
          ),
        if (widget.exportCsv != null)
          TextButton(
            onPressed: exporting
                ? null
                : () async {
                    setState(() => exporting = true);
                    try {
                      final saved = await widget.exportCsv!(
                        report.csv({...rows, ...common}),
                      );
                      if (mounted) {
                        setState(
                          () => message = saved ? '花费明细已保存到所选位置' : '已取消保存',
                        );
                      }
                    } catch (_) {
                      if (mounted) setState(() => message = '保存失败，请重试；账本未改变');
                    } finally {
                      if (mounted) setState(() => exporting = false);
                    }
                  },
            child: Text(exporting ? '正在保存…' : '导出花费明细'),
          ),
        if (message != null) Text(message!),
      ],
    );
    return widget.framed ? ChekiCard(child: content) : content;
  }
}
