import 'bi_query.dart';
import 'record_cost.dart';
import 'record_store.dart';
import 'ticket_store.dart';

/// A derived expense slice. No rounded value or ownership guess is persisted.
class SpendingLine {
  SpendingLine({
    required this.id,
    required this.kind,
    required this.day,
    required this.amount,
    required this.participants,
    required this.relatedGroups,
    this.memberId,
    this.groupId,
    this.record,
    this.ticket,
  });
  final String id, kind;
  final String? day, memberId, groupId;
  final Set<String> participants, relatedGroups;
  final RecordCost amount;
  final StoredRecord? record;
  final TicketObject? ticket;
}

class SpendingReport {
  SpendingReport(this.source, this.period) {
    final definitions = {
      for (final t in source.tickets.where((t) => t.kind == 'definition'))
        t.id: t,
    };
    final children = <String, List<TicketObject>>{};
    for (final t in source.tickets) {
      if (!t.posted || (t.information.quantity ?? 0) >= 0) continue;
      final recordId = source.entryBindings[t.id];
      if (recordId != null) (children[recordId] ??= []).add(t);
      if (source.transferKinds[t.id] != 'gift' ||
          !period.contains(t.information.day)) {
        continue;
      }
      final def = definitions[t.information.text('definition_id')];
      final m = def?.information.text('scope') == 'personal'
          ? def?.information.text('member_id')
          : null;
      final g = def?.information.text('group_id');
      lines.add(
        SpendingLine(
          id: 'gift:${t.id}',
          kind: '赠送',
          day: t.information.day,
          amount: RecordCost()..addAllocations(t.allocations),
          memberId: m,
          groupId: g,
          participants: {?m},
          relatedGroups: {?g},
          ticket: t,
        ),
      );
    }
    for (final r in source.records.records) {
      if (!period.contains(r.information.occurredOn?.value)) continue;
      final ids = (r.information.memberIds ?? []).toSet();
      String? groupOf(String id) {
        final saved = r.information.memberSnapshot(id);
        return saved?['group_id'] as String? ??
            source.records.members[id]?.groupId;
      }

      final groups = {
        for (final id in ids)
          if (groupOf(id) != null) groupOf(id)!,
      };
      final legacy = legacyRecordCost(r.information.toMap());
      final bound = children[r.id] ?? <TicketObject>[];
      if (legacy == null && bound.isNotEmpty) {
        for (final t in bound) {
          final m = t.information.text('member_id');
          final g = definitions[t.information.text('definition_id')]
              ?.information
              .text('group_id');
          lines.add(
            SpendingLine(
              id: 'record:${r.id}:${t.id}',
              kind: 'Cheki',
              day: r.information.occurredOn?.value,
              amount: RecordCost()..addAllocations(t.allocations),
              memberId: m,
              groupId: g,
              participants: m == null ? ids : {m},
              relatedGroups: g == null ? groups : {g},
              record: r,
              ticket: t,
            ),
          );
        }
      } else {
        final cost =
            legacy ??
            source.records.costs[r.id] ??
            (RecordCost()..add(null, 1));
        lines.add(
          SpendingLine(
            id: 'record:${r.id}',
            kind: 'Cheki',
            day: r.information.occurredOn?.value,
            amount: cost,
            memberId: ids.length == 1 ? ids.single : null,
            groupId:
                groups.length == 1 && ids.every((id) => groupOf(id) != null)
                ? groups.single
                : null,
            participants: ids,
            relatedGroups: groups,
            record: r,
          ),
        );
      }
    }
    lines.sort((a, b) {
      final byDay = a.day == null
          ? (b.day == null ? 0 : 1)
          : b.day == null
          ? -1
          : b.day!.compareTo(a.day!);
      return byDay != 0 ? byDay : a.id.compareTo(b.id);
    });
  }
  final BiSnapshot source;
  final BiPeriod period;
  final lines = <SpendingLine>[];
  List<SpendingLine> assigned({String? member, String? group}) => lines
      .where(
        (l) =>
            (member == null || l.memberId == member) &&
            (group == null || l.groupId == group),
      )
      .toList();
  List<SpendingLine> shared({
    String? member,
    String? group,
    bool byMember = false,
  }) => lines
      .where(
        (l) =>
            (byMember
                ? l.memberId == null
                : member != null
                ? l.memberId == null && l.participants.contains(member)
                : l.groupId == null) &&
            (group == null || l.relatedGroups.contains(group)),
      )
      .toList();
  RecordCost total(Iterable<SpendingLine> rows) {
    final result = RecordCost();
    final seen = <String>{};
    for (final row in rows) {
      if (seen.add(row.id)) result.combine(row.amount);
    }
    return result;
  }

  Set<String> get members => {for (final l in lines) ...l.participants};
  Set<String> get groups => {for (final l in lines) ...l.relatedGroups};
  String csv(Iterable<SpendingLine> rows) {
    String cell(Object? x) =>
        '"${(x?.toString() ?? '').replaceAll('"', '""')}"';
    final result = [
      [
        'kind',
        'occurred_on',
        'record_id',
        'ticket_id',
        'member_id',
        'group_id',
        'amount_decimal',
        'unknown_parts',
      ],
      for (final l in rows)
        [
          l.kind,
          l.day,
          l.record?.id,
          l.ticket?.id,
          l.memberId,
          l.groupId,
          l.amount.knownQuantity == 0 ? null : l.amount.known.decimal,
          l.amount.unknownQuantity + l.amount.unlinkedRecords,
        ],
    ].map((r) => r.map(cell).join(',')).join('\r\n');
    return '\uFEFF$result\r\n';
  }
}
