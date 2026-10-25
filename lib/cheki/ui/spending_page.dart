import 'dart:async';
import 'package:flutter/material.dart';
import '../data/bi_query.dart';
import '../data/record_store.dart';
import '../data/spending_query.dart';
import '../data/ticket_store.dart';
import '../data/transfer_store.dart';
import 'components.dart';
import 'record_pages.dart';
import 'transfer_pages.dart';
import 'theme.dart';

class SpendingPage extends StatefulWidget {
  const SpendingPage({
    required this.store,
    required this.records,
    required this.period,
    this.group,
    this.member,
    this.groups = false,
    this.exportCsv,
    super.key,
  });
  final BiStore store;
  final RecordStore records;
  final BiPeriod period;
  final String? group, member;
  final bool groups;
  final Future<bool> Function(String)? exportCsv;
  @override
  State<SpendingPage> createState() => _SpendingPageState();
}

class _SpendingPageState extends State<SpendingPage> {
  late Future<BiSnapshot> snapshot;
  final subscriptions = <StreamSubscription<void>>[];
  late bool groups = widget.groups;
  bool exporting = false;
  String? message;
  @override
  void initState() {
    super.initState();
    snapshot = widget.store.read();
    subscriptions.add(RecordStore.changes.listen((_) => refresh()));
    subscriptions.add(TicketStore.changes.listen((_) => refresh()));
  }

  void refresh() {
    if (mounted) setState(() => snapshot = widget.store.read());
  }

  @override
  void dispose() {
    for (final sub in subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }

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
      final store = TransferStore(
        widget.store.database,
        clock: widget.store.clock,
      );
      final transfer = await store.forTicket(line.ticket!.id);
      if (!mounted || transfer == null) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => TransferDetailPage(store: store, id: transfer.id),
        ),
      );
    }
    refresh();
  }

  Future<void> export(SpendingReport report, List<SpendingLine> rows) async {
    if (exporting) return;
    setState(() => exporting = true);
    try {
      final saved = await widget.exportCsv!(report.csv(rows));
      if (mounted) {
        setState(() => message = saved ? '花费 CSV 已保存到所选位置' : '已取消保存');
      }
    } catch (_) {
      if (mounted) setState(() => message = '保存失败，请重试；账本未改变');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        IconButton(
          tooltip: '花费说明',
          icon: const Icon(Icons.info_outline),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('花费说明'),
              content: const Text(
                '消费花费包含 Cheki 与赠送。购券付款和交换不重复计入。\n\n保留原金额精度，显示时四舍五入。共同费用没有明确归属时不自动平摊。\n\n本页按所选时间及成员/团体统计，不使用 Cheki 属性或领取筛选。旧记录缺少团体快照时，按当前成员资料显示。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('知道了'),
                ),
              ],
            ),
          ),
        ),
      ],
      title: Text(
        widget.member != null
            ? '成员花费'
            : widget.group != null && widget.groups
            ? '团体花费'
            : '消费花费',
      ),
    ),
    body: FutureBuilder<BiSnapshot>(
      future: snapshot,
      builder: (context, state) {
        if (!state.hasData) {
          return Center(
            child: state.hasError
                ? TextButton(onPressed: refresh, child: const Text('读取失败，重试'))
                : const CircularProgressIndicator(),
          );
        }
        final report = SpendingReport(state.data!, widget.period),
            model = state.data!.records;
        final rows = report.assigned(
          member: widget.member,
          group: widget.group,
        );
        final common = report.shared(
          member: widget.member,
          group: widget.group,
          byMember: !groups && widget.member == null,
        );
        final drill =
            widget.member != null || widget.groups && widget.group != null;
        String memberLabel(String id) => model.memberLabel(id);
        String groupLabel(String id) => model.groups[id]?.name ?? '团体未填写';
        Widget lineTile(SpendingLine l) => ListTile(
          key: ValueKey('expense-line-${l.id}'),
          contentPadding: EdgeInsets.zero,
          title: Text('${l.day ?? '日期未填写'} · ${l.kind}'),
          subtitle: Text(
            '${l.memberId != null
                ? memberLabel(l.memberId!)
                : l.groupId != null
                ? groupLabel(l.groupId!)
                : '共同费用'}\n${l.amount.label}',
          ),
          isThreeLine: true,
          onTap: () => open(l),
        );
        final keys = (groups ? report.groups : report.members)
            .where(
              (id) =>
                  groups ||
                  widget.group == null ||
                  report.assigned(member: id, group: widget.group).isNotEmpty ||
                  report.shared(member: id, group: widget.group).isNotEmpty,
            )
            .toList();
        keys.sort((a, b) {
          final aa = report
              .total(
                report.assigned(
                  member: groups ? null : a,
                  group: groups ? a : widget.group,
                ),
              )
              .known;
          final bb = report
              .total(
                report.assigned(
                  member: groups ? null : b,
                  group: groups ? b : widget.group,
                ),
              )
              .known;
          final order = (bb.numerator * aa.denominator).compareTo(
            aa.numerator * bb.denominator,
          );
          return order != 0 ? order : a.compareTo(b);
        });
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(widget.period.label),
            const SizedBox(height: 12),
            if (report.total(rows).hasAmount)
              ChekiCard(
                color: ChekiColors.blue,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      report.total(rows).label,
                      key: const ValueKey('expense-total'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (report
                        .total(rows.where((l) => l.kind == 'Cheki'))
                        .hasAmount)
                      Text(
                        'Cheki ${report.total(rows.where((l) => l.kind == 'Cheki')).label}',
                      ),
                    if (report
                        .total(rows.where((l) => l.kind == '赠送'))
                        .hasAmount)
                      Text(
                        '赠送 ${report.total(rows.where((l) => l.kind == '赠送')).label}',
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (!drill) ...[
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('成员花费'),
                    selected: !groups,
                    onSelected: (_) => setState(() => groups = false),
                  ),
                  ChoiceChip(
                    label: const Text('团体花费'),
                    selected: groups,
                    onSelected: (_) => setState(() => groups = true),
                  ),
                ],
              ),
              if (keys.isEmpty) const Text('没有可统计的花费明细'),
              for (final id in keys)
                ListTile(
                  key: ValueKey('expense-${groups ? 'group' : 'member'}-$id'),
                  contentPadding: EdgeInsets.zero,
                  leading: groups
                      ? null
                      : Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Color(
                              0xff000000 |
                                  (model.members[id]?.colorRgb ?? 0x7c8ea0),
                            ),
                            border: Border.all(color: Colors.black, width: .5),
                          ),
                        ),
                  title: Text(groups ? groupLabel(id) : memberLabel(id)),
                  subtitle:
                      report
                          .total(
                            report.assigned(
                              member: groups ? null : id,
                              group: groups ? id : widget.group,
                            ),
                          )
                          .hasAmount
                      ? Text(
                          report
                              .total(
                                report.assigned(
                                  member: groups ? null : id,
                                  group: groups ? id : widget.group,
                                ),
                              )
                              .label,
                        )
                      : null,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SpendingPage(
                        store: widget.store,
                        records: widget.records,
                        period: widget.period,
                        member: groups ? null : id,
                        group: groups ? id : widget.group,
                        groups: groups,
                        exportCsv: widget.exportCsv,
                      ),
                    ),
                  ),
                ),
            ] else ...[
              Text(
                widget.member != null
                    ? memberLabel(widget.member!)
                    : groupLabel(widget.group!),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (rows.isEmpty) const Text('没有已归属的消费花费'),
              for (final l in rows) lineTile(l),
            ],
            if (common.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(!groups && widget.member == null ? '未分配到成员' : '共同费用（未分摊）'),
              if (report.total(common).hasAmount)
                Text(report.total(common).label),
              Text(
                !groups && widget.member == null
                    ? '团体通用券赠送及共同费用保留原金额，不自动分配到成员。'
                    : '缺少明确归属，保留原金额，不平摊或复制到每个成员。',
              ),
              for (final l in common) lineTile(l),
            ],
            const SizedBox(height: 12),
            if (widget.exportCsv != null)
              TextButton(
                onPressed: exporting
                    ? null
                    : () => export(report, {...rows, ...common}.toList()),
                child: Text(exporting ? '正在保存…' : '导出花费明细'),
              ),
            if (message != null) Text(message!),
          ],
        );
      },
    ),
  );
}
