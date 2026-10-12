import '../domain/record_contract.dart';
import '../domain/record_information.dart';
import 'catalog_contract.dart';
import 'identity_contract.dart';
import 'record_store.dart';

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

/// Record rows and names are read in one database transaction by RecordStore.
final class RecordReadModel {
  RecordReadModel({
    required Iterable<StoredRecord> records,
    required Iterable<CatalogEntity> groups,
    required Iterable<IdentityEntity> members,
    required Iterable<CatalogEntity> sizes,
  }) : records = List.unmodifiable(records),
       groups = Map.unmodifiable({for (final g in groups) g.id: g}),
       members = Map.unmodifiable({for (final m in members) m.id: m}),
       sizes = Map.unmodifiable({for (final s in sizes) s.id: s});
  final List<StoredRecord> records;
  final Map<String, CatalogEntity> groups, sizes;
  final Map<String, IdentityEntity> members;
  String memberLabel(String id) {
    final m = members[id];
    return m == null
        ? '成员信息不可用'
        : '${groups[m.groupId]?.name ?? '未填写团体'} · ${m.name}';
  }

  String recordMemberLabel(RecordInformation info, String id) {
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
