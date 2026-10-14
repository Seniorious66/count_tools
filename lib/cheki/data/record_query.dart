import 'dart:convert';
import '../domain/record_contract.dart';
import '../domain/record_information.dart';
import 'catalog_contract.dart';
import 'identity_contract.dart';
import 'record_store.dart';
import 'record_cost.dart';

enum RecordSelection { all, awaitingReceipt, incomplete, undated }

/// Filters business dates only. Missing dates never fall back to action time.
final class RecordFilter {
  RecordFilter({
    this.selection = RecordSelection.all,
    this.memberId,
    this.sizeId,
    this.from,
    this.through,
  }) {
    if (from != null) OccurredOn.parse(from!);
    if (through != null) OccurredOn.parse(through!);
    if (from != null && through != null && from!.compareTo(through!) > 0) {
      throw ArgumentError('日期范围顺序无效');
    }
  }
  final RecordSelection selection;
  final String? memberId, sizeId, from, through;
  bool matches(RecordInformation info) {
    if (memberId != null && !(info.memberIds ?? []).contains(memberId)) {
      return false;
    }
    if (sizeId != null && info.sizeId != sizeId) return false;
    final day = info.occurredOn?.value;
    if ((from != null || through != null) && day == null) return false;
    if (from != null && day!.compareTo(from!) < 0) return false;
    if (through != null && day!.compareTo(through!) > 0) return false;
    return switch (selection) {
      RecordSelection.all => true,
      RecordSelection.awaitingReceipt =>
        info.receiptStatus == ReceiptStatus.partial ||
            info.receiptStatus == ReceiptStatus.unreceived,
      RecordSelection.incomplete => info.missingFields.isNotEmpty,
      RecordSelection.undated => day == null,
    };
  }
}

/// Each indicator uses only its own known inputs. No persisted aggregate exists.
final class RecordSummary {
  RecordSummary(Iterable<StoredRecord> records, {String? memberId}) {
    for (final record in records) {
      final i = record.information;
      recordCount++;
      if (i.occurredOn == null) unknownDateRecords++;
      if (i.sizeId == null) unknownSizeRecords++;
      if ((i.memberIds ?? []).isEmpty) unknownMemberRecords++;
      if (i.receiptStatus == null) unknownReceiptRecords++;
      final q = i.quantity;
      if (q == null) {
        unknownQuantityRecords++;
      } else {
        knownQuantityRecords++;
        knownQuantity += q;
        if (i.sizeId != null) {
          bySize.update(i.sizeId!, (v) => v + q, ifAbsent: () => q);
        }
        for (final id in i.memberIds ?? <String>[]) {
          if (memberId != null && id != memberId) continue;
          memberQuantity += q;
          byMember.update(id, (v) => v + q, ifAbsent: () => q);
        }
        if (memberId == null
            ? (i.memberIds ?? []).isNotEmpty
            : (i.memberIds ?? []).contains(memberId)) {
          knownMemberQuantityRecords++;
        }
      }
      final received = i.receivedQuantity;
      if (q != null && received != null) {
        knownReceiptQuantityRecords++;
        knownReceivedQuantity += received;
        knownAwaitingQuantity += q - received;
      } else {
        unknownReceiptQuantityRecords++;
      }
    }
  }
  int recordCount = 0, knownQuantity = 0, knownQuantityRecords = 0;
  int memberQuantity = 0, knownReceivedQuantity = 0, knownAwaitingQuantity = 0;
  int knownMemberQuantityRecords = 0;
  int knownReceiptQuantityRecords = 0;
  int unknownQuantityRecords = 0, unknownDateRecords = 0;
  int unknownMemberRecords = 0, unknownSizeRecords = 0;
  int unknownReceiptRecords = 0, unknownReceiptQuantityRecords = 0;
  final byMember = <String, int>{}, bySize = <String, int>{};
  String get quantityLabel =>
      knownQuantityRecords == 0 && unknownQuantityRecords > 0
      ? '未填写'
      : knownQuantity.toString();
  String get memberQuantityLabel =>
      knownMemberQuantityRecords == 0 &&
          (unknownMemberRecords > 0 || unknownQuantityRecords > 0)
      ? '未填写'
      : memberQuantity.toString();
}

final class RecordDay {
  RecordDay(this.day, Iterable<StoredRecord> records, {String? memberId})
    : records = List.unmodifiable(records),
      summary = RecordSummary(records, memberId: memberId);
  final String? day;
  final List<StoredRecord> records;
  final RecordSummary summary;
}

int compareRecordOccurrence(StoredRecord a, StoredRecord b) {
  final ad = a.information.occurredOn?.value;
  final bd = b.information.occurredOn?.value;
  final date = ad == null
      ? (bd == null ? 0 : 1)
      : bd == null
      ? -1
      : bd.compareTo(ad);
  if (date != 0) return date;
  final action = b.createdAt.compareTo(a.createdAt);
  return action != 0 ? action : a.id.compareTo(b.id);
}

/// A reversible display group, never a replacement database record.
final class RecordBundle {
  RecordBundle(Iterable<StoredRecord> rows) : records = List.unmodifiable(rows);
  final List<StoredRecord> records;
  StoredRecord get representative => records.first;
  int? get quantity => records.any((r) => r.information.quantity == null)
      ? null
      : records.fold<int>(0, (n, r) => n + r.information.quantity!);
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

List<RecordBundle> bundleRecords(Iterable<StoredRecord> records) {
  final buckets = <String, List<StoredRecord>>{};
  for (final r in records) {
    final i = r.information;
    final members = i.memberIds;
    if (i.occurredOn == null ||
        i.quantity == null ||
        i.sizeId == null ||
        members == null ||
        members.isEmpty ||
        i.signature == null ||
        (i.signature == SignatureKind.signed && i.backSigned == null) ||
        i.receiptStatus == null ||
        i.receiptStatus == ReceiptStatus.partial) {
      buckets['single:${r.id}'] = [r];
      continue;
    }
    final raw = i.toMap();
    final ids = [...members]..sort();
    final snapshots = (raw['member_snapshots'] as List?)?.toList()
      ?..sort(
        (a, b) => (a as Map)['member_id'].toString().compareTo(
          (b as Map)['member_id'].toString(),
        ),
      );
    final key = jsonEncode(
      _canonical({
        for (final e in raw.entries)
          if (![
            'quantity',
            'member_ids',
            'member_snapshots',
            'receipt_batches',
            'legacy_raw',
            'legacy_source',
          ].contains(e.key))
            e.key: e.value,
        'member_ids': ids,
        if (raw.containsKey('member_snapshots')) 'member_snapshots': snapshots,
        'receipt_status': i.receiptStatus!.name,
        'receipt_batches': [
          for (final b in raw['receipt_batches'] as List? ?? [])
            {
              for (final e in (b as Map).entries)
                if (e.key != 'quantity') e.key as String: e.value,
            },
        ],
      }),
    );
    buckets.putIfAbsent('bundle:$key', () => []).add(r);
  }
  final result = [
    for (final rows in buckets.values)
      RecordBundle(rows..sort(compareRecordOccurrence)),
  ];
  result.sort(
    (a, b) => compareRecordOccurrence(a.representative, b.representative),
  );
  return List.unmodifiable(result);
}

/// Record rows and names are read in one database transaction by RecordStore.
final class RecordReadModel {
  RecordReadModel({
    required Iterable<StoredRecord> records,
    required Iterable<CatalogEntity> groups,
    required Iterable<IdentityEntity> members,
    required Iterable<CatalogEntity> sizes,
    Map<String, RecordCost> costs = const {},
  }) : records = List.unmodifiable(
         records.toList()..sort(compareRecordOccurrence),
       ),
       groups = Map.unmodifiable({for (final g in groups) g.id: g}),
       members = Map.unmodifiable({for (final m in members) m.id: m}),
       sizes = Map.unmodifiable({for (final s in sizes) s.id: s}),
       costs = Map.unmodifiable(costs);
  final List<StoredRecord> records;
  final Map<String, CatalogEntity> groups, sizes;
  final Map<String, IdentityEntity> members;
  final Map<String, RecordCost> costs;
  RecordCost costFor(Iterable<String> recordIds) {
    final total = RecordCost();
    for (final id in recordIds.toSet()) {
      final cost = costs[id];
      if (cost == null) {
        total.unlinkedRecords++;
      } else {
        total.combine(cost);
      }
    }
    return total;
  }

  String memberLabel(String id) {
    final m = members[id];
    final parts = [
      groups[m?.groupId]?.knownName,
      m?.knownName,
    ].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
    return parts.isEmpty ? '成员信息未填写' : parts.join('-');
  }

  String recordMemberLabel(RecordInformation info, String id) =>
      memberLabel(id);

  String historicalMemberLabel(RecordInformation info, String id) {
    final s = info.memberSnapshot(id);
    if (s == null) return '${memberLabel(id)}（当前名称，当时名称未填写）';
    final group = s['group_name'] as String?;
    final member = s['member_name'] as String?;
    String source(Object? origin) => origin == 'entry'
        ? '录入时'
        : origin == 'manual'
        ? '当时'
        : '记录中';
    final gs = source(s['group_name_origin'] ?? s['origin']),
        ms = source(s['member_name_origin'] ?? s['origin']);
    final currentGroup = groups[members[id]?.groupId]?.knownName;
    if ((group == null || group.trim().isEmpty) && currentGroup != null) {
      // Current affiliation is a label, never backfilled into the old snapshot.
      return '$currentGroup（当前团体） · ${member == null || member.trim().isEmpty ? '成员名称未填写' : member}（$ms）';
    }
    final g = group == null || group.trim().isEmpty ? '团体名称未填写' : group;
    final m = member == null || member.trim().isEmpty ? '成员名称未填写' : member;
    return gs == ms ? '$g · $m（$gs）' : '$g（$gs） · $m（$ms）';
  }

  List<StoredRecord> select(RecordFilter filter) => records
      .where((r) => filter.matches(r.information))
      .toList(growable: false);
  RecordSummary summarize(RecordFilter filter) =>
      RecordSummary(select(filter), memberId: filter.memberId);
  List<RecordDay> days(RecordFilter filter) {
    final buckets = <String?, List<StoredRecord>>{};
    for (final r in select(filter)) {
      buckets.putIfAbsent(r.information.occurredOn?.value, () => []).add(r);
    }
    final keys = buckets.keys.toList()
      ..sort((a, b) {
        if (a == null) return b == null ? 0 : 1;
        if (b == null) return -1;
        return b.compareTo(a);
      });
    return [
      for (final key in keys)
        RecordDay(key, buckets[key]!, memberId: filter.memberId),
    ];
  }

  RecordFilter month(OccurredOn day) {
    final date = DateTime.parse('${day.value}T00:00:00Z');
    final end = DateTime.utc(date.year, date.month + 1, 0);
    return RecordFilter(
      from: '${day.value.substring(0, 7)}-01',
      through: end.toIso8601String().substring(0, 10),
    );
  }
}
