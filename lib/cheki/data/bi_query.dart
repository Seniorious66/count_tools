import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/record_contract.dart';
import '../domain/ticket_information.dart';
import 'catalog_contract.dart';
import 'identity_contract.dart';
import 'legacy_member_colors.dart';
import 'record_query.dart';
import 'record_store.dart';
import 'ticket_store.dart';
import 'entry_store.dart';
import 'transfer_store.dart';
import 'record_cost.dart';
import 'member_statistics.dart';

enum BiScope {
  day('日'),
  week('周'),
  month('月'),
  year('年'),
  all('所有');

  const BiScope(this.label);
  final String label;
}

String biDay(DateTime d) => d.toIso8601String().substring(0, 10);

/// Business dates have no time zone conversion. Only the query's today uses Shanghai.
class BiPeriod {
  BiPeriod(this.scope, String anchor) : anchor = OccurredOn.parse(anchor).value;
  final BiScope scope;
  final String anchor;
  DateTime get date => DateTime.parse('${anchor}T00:00:00Z');
  String? get from => switch (scope) {
    BiScope.day => anchor,
    BiScope.week => biDay(date.subtract(Duration(days: date.weekday - 1))),
    BiScope.month => biDay(DateTime.utc(date.year, date.month)),
    BiScope.year => biDay(DateTime.utc(date.year)),
    BiScope.all => null,
  };
  String? get through => switch (scope) {
    BiScope.day => anchor,
    BiScope.week => biDay(
      DateTime.parse('${from}T00:00:00Z').add(const Duration(days: 6)),
    ),
    BiScope.month => biDay(DateTime.utc(date.year, date.month + 1, 0)),
    BiScope.year => biDay(DateTime.utc(date.year, 12, 31)),
    BiScope.all => null,
  };
  bool contains(String? day) =>
      scope == BiScope.all ||
      day != null && day.compareTo(from!) >= 0 && day.compareTo(through!) <= 0;
  String get label => scope == BiScope.all
      ? '所有时间'
      : from == through
      ? from!
      : '$from — $through';
  BiPeriod move(int direction) {
    final d = date;
    final next = switch (scope) {
      BiScope.day => d.add(Duration(days: direction)),
      BiScope.week => d.add(Duration(days: 7 * direction)),
      BiScope.month => DateTime.utc(d.year, d.month + direction),
      BiScope.year => DateTime.utc(d.year + direction),
      BiScope.all => d,
    };
    return BiPeriod(scope, biDay(next));
  }
}

class BiAmount extends RecordCost {
  String get displayLabel => hasAmount ? known.roundedYuan : '';
  @override
  String get label => displayLabel;
  String get average =>
      hasAmount ? known.divided(knownQuantity).roundedYuan : '';
}

/// Additional Cheki dimensions do not invent an allocation of group coupons to people.
class BiRecordFilter {
  const BiRecordFilter({
    this.memberId,
    this.personId,
    this.sizeId,
    this.signature,
    this.receipt,
    this.backSigned,
    this.unknownBack = false,
    this.exactMember = false,
  });
  final String? memberId, personId, sizeId, signature, receipt;
  final bool? backSigned;
  final bool unknownBack;
  final bool exactMember;
  bool memberMatches(String id, RecordReadModel model) =>
      (memberId == null ||
          memberId == id ||
          !exactMember &&
              model.members[memberId]?.personId != null &&
              model.members[memberId]?.personId ==
                  model.members[id]?.personId) &&
      (personId == null || model.members[id]?.personId == personId);
  bool matches(StoredRecord row, RecordReadModel model) {
    final i = row.information;
    bool dimension(String? selected, String? actual) =>
        selected == null ||
        (selected == '@unknown' ? actual == null : selected == actual);
    return ((memberId == null && personId == null) ||
            (i.memberIds ?? []).any((id) => memberMatches(id, model))) &&
        dimension(sizeId, i.sizeId) &&
        dimension(signature, i.signature?.name) &&
        dimension(receipt, i.receiptStatus?.name) &&
        (unknownBack
            ? i.backSigned == null
            : backSigned == null || i.backSigned == backSigned);
  }

  Map<String, Object?> toMap() => {
    'member_id': memberId,
    'person_id': personId,
    'size_id': sizeId,
    'signature': signature,
    'receipt': receipt,
    'back_signed': backSigned,
    'unknown_back': unknownBack,
    'exact_member': exactMember,
  };
}

class BiMemberCount {
  BiMemberCount(this.id, this.label, this.memberIds, this.colorRgb);
  final String id, label;
  final Set<String> memberIds;
  final int? colorRgb;
  int quantity = 0, unknownRecords = 0;
  final bySize = <String?, int>{};
}

class BiStock {
  BiStock(this.definition, this.label);
  final TicketObject definition;
  final String label;
  int available = 0, expired = 0;
  int longAvailable = 0, datedAvailable = 0, nearExpiry = 0;
  final cost = BiAmount(), availableCost = BiAmount(), expiredCost = BiAmount();
}

class BiFlow {
  BiFlow(this.kind);
  final String kind;
  int quantity = 0;
  final cost = BiAmount();
}

/// One SQLite transaction for records, identity colours and all cost/flow bindings.
/// This is a rebuildable read model, never another persisted accounting source.
class BiStore {
  BiStore(this.database, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final Future<Database> Function() database;
  final DateTime Function() clock;
  Future<BiSnapshot> read() async => (await database()).transaction((tx) async {
    final records = RecordReadModel(
      records: (await tx.query(
        RecordSchema.records,
      )).map(StoredRecord.fromRow).where((r) => !r.information.isVoided),
      groups: (await tx.query(
        CatalogKind.group.table,
      )).map(CatalogEntity.fromRow),
      members: await readMembersWithLegacyColors(tx),
      sizes: (await tx.query(
        CatalogKind.size.table,
      )).map(CatalogEntity.fromRow),
      costs: await recordCostsIn(tx),
    );
    final transfers = {
      for (final r in await tx.query(TransferSchema.objects))
        r['id'] as String: TransferObject.fromRow(r),
    };
    final ticketObjects = await loadTicketObjects(tx);
    validateLedger(ticketObjects);
    return BiSnapshot(
      records,
      {
        for (final r in await tx.query(IdentityKind.person.table))
          r['id'] as String: IdentityEntity.fromRow(IdentityKind.person, r),
      },
      ticketObjects,
      {
        for (final r in await tx.query(EntrySchema.bindings))
          r['ticket_id'] as String: r['record_id'] as String,
      },
      {
        for (final r in await tx.query(TransferSchema.bindings))
          r['ticket_id'] as String: transfers[r['transfer_id']]!.information
              .text('kind')!,
      },
      OccurredOn.shanghaiDay(clock()).value,
    );
  });
}

class BiSnapshot {
  BiSnapshot(
    this.records,
    this.persons,
    this.tickets,
    this.entryBindings,
    this.transferKinds,
    this.today,
  );
  final RecordReadModel records;
  final Map<String, IdentityEntity> persons;
  final List<TicketObject> tickets;
  final Map<String, String> entryBindings, transferKinds;
  final String today;
  BiReport report(
    BiPeriod period, {
    String? groupId,
    BiRecordFilter filter = const BiRecordFilter(),
  }) => BiReport(this, period, groupId, filter);
}

class BiReport {
  BiReport(this.source, this.period, this.groupId, this.filter) {
    final model = source.records;
    final identity = MemberStatistics(model);
    bool memberMatch(String id, StoredRecord r) =>
        filter.memberMatches(id, model) &&
        (groupId == null || identity.groupOf(r, id) == groupId);
    rows = model.records
        .where(
          (r) =>
              period.contains(r.information.occurredOn?.value) &&
              filter.matches(r, model) &&
              (groupId == null ||
                  (r.information.memberIds ?? []).any(
                    (id) => memberMatch(id, r),
                  )),
        )
        .toList();
    summary = RecordSummary(rows);
    for (final r in rows) {
      final i = r.information, q = i.quantity;
      days.putIfAbsent(i.occurredOn?.value, () => []).add(r);
      void dimension(Map<String?, int> bucket, String? key) {
        if (q != null) bucket.update(key, (old) => old + q, ifAbsent: () => q);
      }

      dimension(sizes, i.sizeId);
      dimension(signatures, i.signature?.name);
      dimension(receipts, i.receiptStatus?.name);
      if (i.signature?.name == 'signed') {
        if (i.backSigned == true) backSigned += q ?? 0;
        if (i.backSigned == null) backUnknown += q ?? 0;
      }
      final personSeen = <String>{};
      for (final id in (i.memberIds ?? []).toSet().where(
        (id) => memberMatch(id, r),
      )) {
        final member = model.members[id];
        final m = members.putIfAbsent(
          id,
          () =>
              BiMemberCount(id, model.memberLabel(id), {id}, member?.colorRgb),
        );
        if (q == null) {
          m.unknownRecords++;
        } else {
          m.quantity += q;
          m.bySize.update(i.sizeId, (v) => v + q, ifAbsent: () => q);
          memberQuantity += q;
        }
        final pid = member?.personId;
        final key = pid == null ? 'member:$id' : 'person:$pid';
        final p = people.putIfAbsent(
          key,
          () => BiMemberCount(
            key,
            identity.label(id),
            identity.identities(id),
            identity.color(id),
          ),
        );
        p.memberIds.add(id);
        if (personSeen.add(key)) {
          if (q == null) {
            p.unknownRecords++;
          } else {
            p.quantity += q;
            p.bySize.update(i.sizeId, (v) => v + q, ifAbsent: () => q);
            personQuantity += q;
          }
        }
      }
    }
    cutoff = period.through ?? source.today;
    final tm = TicketModel(
      source.tickets,
      {for (final g in model.groups.values) g.id: g.name},
      {for (final m in model.members.values) m.id: m.name},
      {for (final s in model.sizes.values) s.id: s.name},
      cutoff,
    );
    final definitions = {for (final d in tm.definitions) d.id: d};
    bool ticketMatch(TicketObject t) =>
        groupId == null ||
        definitions[t.information.text('definition_id')]?.information.text(
              'group_id',
            ) ==
            groupId;
    final remaining = tm.remaining;
    for (final t in source.tickets) {
      if (!['purchase', 'adjustment'].contains(t.kind) || !ticketMatch(t)) {
        continue;
      }
      final i = t.information;
      if (!t.posted) {
        if (period.contains(i.day)) draftCount++;
        continue;
      }
      final q = i.quantity!;
      TicketMoney? cost() {
        if (q > 0) return t.unitCost?.times(q);
        TicketMoney amount = TicketMoney(BigInt.zero, BigInt.one);
        for (final a in t.allocations) {
          if (a['cost'] == null) return null;
          final c = TicketMoney.fromExact(a['cost'] as String);
          amount = TicketMoney.fromExact(
            TicketMoney(
              amount.numerator * c.denominator +
                  c.numerator * amount.denominator,
              amount.denominator * c.denominator,
            ).exact,
          );
        }
        return amount;
      }

      if (period.contains(i.day)) {
        flowRows.add(t);
        final kind = flowKind(t);
        final f = flows.putIfAbsent(kind, () => BiFlow(kind));
        f.quantity += q.abs();
        // Preserve known and unknown allocation slices independently.
        if (q > 0) {
          f.cost.add(cost(), q);
        } else {
          for (final a in t.allocations) {
            f.cost.add(
              a['cost'] == null
                  ? null
                  : TicketMoney.fromExact(a['cost'] as String),
              a['quantity'] as int,
            );
          }
        }
        if (kind == '购入') {
          purchase.add(cost(), q);
          purchases
              .putIfAbsent(i.text('definition_id')!, () => BiAmount())
              .add(cost(), q);
        }
      }
      final rest = remaining[t.id] ?? 0;
      if (rest > 0) {
        final def = definitions[i.text('definition_id')]!;
        final s = stocks.putIfAbsent(def.id, () => BiStock(def, tm.label(def)));
        final expired = i.expiry != null && i.expiry!.compareTo(cutoff) < 0;
        if (expired) {
          s.expired += rest;
          s.expiredCost.add(t.unitCost?.times(rest), rest);
        } else {
          s.available += rest;
          s.availableCost.add(t.unitCost?.times(rest), rest);
          if (i.expiry == null) {
            s.longAvailable += rest;
          } else {
            s.datedAvailable += rest;
            if (DateTime.parse(
                  i.expiry!,
                ).difference(DateTime.parse(cutoff)).inDays <=
                tm.reminderDays) {
              s.nearExpiry += rest;
            }
          }
        }
        s.cost.add(t.unitCost?.times(rest), rest);
      }
    }
  }
  final BiSnapshot source;
  final BiPeriod period;
  final String? groupId;
  final BiRecordFilter filter;
  late final List<StoredRecord> rows;
  late final RecordSummary summary;
  late final String cutoff;
  int memberQuantity = 0,
      personQuantity = 0,
      backSigned = 0,
      backUnknown = 0,
      draftCount = 0;
  final members = <String, BiMemberCount>{}, people = <String, BiMemberCount>{};
  final sizes = <String?, int>{},
      signatures = <String?, int>{},
      receipts = <String?, int>{};
  final days = <String?, List<StoredRecord>>{};
  final stocks = <String, BiStock>{}, flows = <String, BiFlow>{};
  final flowRows = <TicketObject>[];
  final purchase = BiAmount();
  final purchases = <String, BiAmount>{};
  String definitionLabel(String id) {
    final d = source.tickets.singleWhere((t) => t.id == id);
    return ticketDefinitionLabel(
      d.information,
      {for (final g in source.records.groups.values) g.id: g.knownName ?? ''},
      {for (final m in source.records.members.values) m.id: m.knownName ?? ''},
    );
  }

  /// Distinct known people present in this report's filtered member rows.
  /// Quantity may be unknown; an unresolved historical member ID is not a person.
  int get personCount => {
    for (final id in members.keys)
      if (source.records.members[id] case final member?)
        member.personId == null ? 'member:$id' : 'person:${member.personId}',
  }.length;

  String get memberQuantityLabel =>
      memberQuantity == 0 &&
          rows.isNotEmpty &&
          (summary.unknownQuantityRecords > 0 ||
              summary.unknownMemberRecords > 0)
      ? '未填写'
      : '$memberQuantity';
  String flowKind(TicketObject t) => t.kind == 'purchase'
      ? '购入'
      : source.entryBindings.containsKey(t.id)
      ? '拍切消耗'
      : source.transferKinds[t.id] == 'gift'
      ? '赠送'
      : source.transferKinds[t.id] == 'exchange'
      ? (t.information.quantity! > 0 ? '交换入' : '交换出')
      : t.information.quantity! > 0
      ? '调整入'
      : '调整出';
  List<BiMemberCount> sortedMembers({bool person = false}) =>
      (person ? people.values : members.values).toList()..sort((a, b) {
        final c = b.quantity.compareTo(a.quantity);
        return c == 0 ? a.id.compareTo(b.id) : c;
      });
  List<StoredRecord> memberRows(Set<String> ids, {String? day}) => rows
      .where(
        (r) =>
            (day == null || r.information.occurredOn?.value == day) &&
            (r.information.memberIds ?? []).any(ids.contains),
      )
      .toList();
  BiAmount get consumedRecordCost {
    return BiAmount()..combine(source.records.costFor(rows.map((r) => r.id)));
  }

  /// A long-form statistics report. Raw JSON is retained alongside sheet-safe labels.
  /// It is not a restore format, and does not contain a second copy of the ledger.
  String csv() {
    final out = <List<Object?>>[
      [
        'section',
        'id',
        'label',
        'date',
        'quantity',
        'denominator',
        'amount_decimal',
        'unknown_cost_quantity',
        'source_json',
      ],
    ];
    void row(
      String section,
      Object? id,
      Object? label,
      Object? date,
      Object? q, {
      Object? denominator,
      Object? amount,
      Object? unknown,
      Object? raw,
    }) => out.add([
      section,
      id,
      label,
      date,
      q,
      denominator,
      amount is String && RegExp(r'^\d+(?:/[1-9]\d*)?$').hasMatch(amount)
          ? TicketMoney.fromExact(amount).decimal
          : amount,
      unknown,
      raw,
    ]);
    row(
      'filter',
      groupId,
      period.label,
      cutoff,
      null,
      raw: jsonEncode({
        'scope': period.scope.name,
        'anchor': period.anchor,
        'from': period.from,
        'through': period.through,
        'group_id': groupId,
        'record_filter': filter.toMap(),
        'stock_cutoff': cutoff,
        'today': source.today,
      }),
    );
    row(
      'summary',
      'physical',
      '张数',
      null,
      summary.knownQuantityRecords == 0 && summary.unknownQuantityRecords > 0
          ? null
          : summary.knownQuantity,
    );
    row(
      'summary',
      'member',
      '成员参与张数',
      null,
      memberQuantityLabel == '未填写' ? null : memberQuantity,
    );
    row(
      'summary',
      'unknown_quantity',
      '张数未填写记录',
      null,
      summary.unknownQuantityRecords,
    );
    row('summary', 'unknown_date', '日期未填写记录', null, summary.unknownDateRecords);
    row(
      'summary',
      'undated_excluded',
      '未归入期间的无日期记录',
      null,
      period.scope == BiScope.all
          ? 0
          : source.records.records
                .where(
                  (r) =>
                      r.information.occurredOn == null &&
                      filter.matches(r, source.records) &&
                      (groupId == null ||
                          (r.information.memberIds ?? []).any(
                            (id) =>
                                source.records.members[id]?.groupId == groupId,
                          )),
                )
                .length,
    );
    for (final m in sortedMembers()) {
      row(
        'member',
        m.id,
        m.label,
        null,
        m.quantity == 0 && m.unknownRecords > 0 ? null : m.quantity,
        denominator: summary.knownQuantity,
        raw: jsonEncode({
          'unknown_records': m.unknownRecords,
          'color_rgb': m.colorRgb,
          'size_quantities': {
            for (final e in m.bySize.entries) e.key ?? '@unknown': e.value,
          },
        }),
      );
    }
    for (final p in sortedMembers(person: true)) {
      row(
        'person',
        p.id,
        p.label,
        null,
        p.quantity == 0 && p.unknownRecords > 0 ? null : p.quantity,
        denominator: summary.knownQuantity,
        raw: jsonEncode({
          'member_ids': p.memberIds.toList(),
          'unknown_records': p.unknownRecords,
          'size_quantities': {
            for (final e in p.bySize.entries) e.key ?? '@unknown': e.value,
          },
        }),
      );
    }
    for (final map in {
      'size': sizes,
      'signature': signatures,
      'receipt': receipts,
    }.entries) {
      for (final entry in map.value.entries) {
        row(
          map.key,
          entry.key,
          entry.key == null
              ? '未填写'
              : map.key == 'size'
              ? source.records.sizes[entry.key]?.name
              : entry.key,
          null,
          entry.value,
          denominator: summary.knownQuantity,
        );
      }
    }
    row(
      'back_signed',
      'signed_subset',
      '带签中的背签',
      null,
      backSigned,
      denominator: signatures['signed'] ?? 0,
      unknown: backUnknown,
    );
    for (final d in days.entries) {
      row(
        'day',
        d.key,
        d.key ?? '日期未填写',
        d.key,
        RecordSummary(d.value).quantityLabel,
      );
    }
    for (final r in rows) {
      row(
        'record',
        r.id,
        (r.information.memberIds ?? [])
            .map((id) => source.records.recordMemberLabel(r.information, id))
            .join('、'),
        r.information.occurredOn?.value,
        r.information.quantity,
        amount:
            source.records.costs[r.id]?.knownQuantity == 0 ||
                source.records.costs[r.id] == null
            ? null
            : source.records.costs[r.id]!.known.exact,
        unknown: source.records.costs[r.id]?.unknownQuantity ?? 1,
        raw: jsonEncode(r.toRow()),
      );
    }
    final expense = consumedRecordCost;
    row(
      'record_expense',
      'total',
      'Cheki花费',
      null,
      rows.length,
      amount: expense.hasAmount ? expense.known.exact : null,
      unknown: expense.unknownQuantity + expense.unlinkedRecords,
    );
    row(
      'purchase',
      'total',
      '购券金额',
      null,
      purchase.knownQuantity,
      amount: purchase.hasAmount ? purchase.known.exact : null,
      unknown: purchase.unknownQuantity,
    );
    row(
      'purchase',
      'mean',
      '购入均价',
      null,
      purchase.knownQuantity,
      amount: purchase.hasAmount
          ? purchase.known.divided(purchase.knownQuantity).decimal
          : null,
    );
    for (final p in purchases.entries) {
      row(
        'purchase_definition',
        p.key,
        definitionLabel(p.key),
        null,
        p.value.knownQuantity + p.value.unknownQuantity,
        amount: p.value.hasAmount ? p.value.known.exact : null,
        unknown: p.value.unknownQuantity,
        raw: jsonEncode({
          'known_quantity': p.value.knownQuantity,
          'known_average': p.value.hasAmount
              ? p.value.known.divided(p.value.knownQuantity).decimal
              : null,
        }),
      );
    }
    for (final s in stocks.values) {
      row(
        'stock',
        s.definition.id,
        s.label,
        cutoff,
        s.available + s.expired,
        amount: s.cost.hasAmount ? s.cost.known.exact : null,
        unknown: s.cost.unknownQuantity,
        raw: jsonEncode({
          'available': s.available,
          'expired': s.expired,
          'long_available': s.longAvailable,
          'dated_available': s.datedAvailable,
          'near_expiry': s.nearExpiry,
          'available_cost': s.availableCost.label,
          'expired_cost': s.expiredCost.label,
        }),
      );
    }
    for (final f in flows.values) {
      row(
        'flow_summary',
        f.kind,
        f.kind,
        null,
        f.quantity,
        amount: f.cost.hasAmount ? f.cost.known.exact : null,
        unknown: f.cost.unknownQuantity,
      );
    }
    for (final t in flowRows) {
      row(
        'flow',
        t.id,
        flowKind(t),
        t.information.day,
        t.information.quantity,
        raw: jsonEncode(t.raw),
      );
    }
    row('draft', 'excluded', '未入账草稿', null, draftCount);
    String cell(Object? value) {
      var s = value?.toString() ?? '';
      if (RegExp(r'^\s*[=+@\-\t\r]').hasMatch(s) && value is! num) s = "'$s";
      return '"${s.replaceAll('"', '""')}"';
    }

    return '\ufeff${out.map((r) => r.map(cell).join(',')).join('\r\n')}\r\n';
  }
}
