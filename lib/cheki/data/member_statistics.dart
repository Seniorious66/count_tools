import 'identity_contract.dart';
import 'record_query.dart';
import 'record_store.dart';

/// Rebuildable identity projection. Never changes member flags or history.
class MemberStatistics {
  MemberStatistics(this.model) {
    for (final r in model.records) {
      final day = r.information.occurredOn?.value;
      if (day == null) continue;
      for (final id in r.information.memberIds ?? <String>[]) {
        if (latest[id] == null || day.compareTo(latest[id]!) > 0) {
          latest[id] = day;
        }
      }
    }
  }
  final RecordReadModel model;
  final latest = <String, String>{};
  String key(String id) => model.members[id]?.personId == null
      ? 'member:$id'
      : 'person:${model.members[id]!.personId}';
  Set<String> identities(String id) => {
    id,
    for (final m in model.members.values)
      if (key(m.id) == key(id)) m.id,
  };
  bool same(String a, String b) => key(a) == key(b);
  String representative(String id) {
    final ids = identities(id).toList();
    ids.sort((a, b) {
      bool active(String x) {
        final m = model.members[x];
        return m != null &&
            MemberAvailability.fromMember(m, model.groups[m.groupId]).available;
      }

      final availability = (active(b) ? 1 : 0).compareTo(active(a) ? 1 : 0);
      if (availability != 0) return availability;
      final recency = (latest[b] ?? '').compareTo(latest[a] ?? '');
      return recency != 0 ? recency : a.compareTo(b);
    });
    return ids.first;
  }

  String label(String id) {
    final chosen = representative(id), m = model.members[chosen];
    final reason = m == null
        ? null
        : MemberAvailability.fromMember(m, model.groups[m.groupId]).description;
    return '${model.memberLabel(chosen)}${reason == null ? '' : ' · $reason'}';
  }

  int? color(String id) => model.members[representative(id)]?.colorRgb;
  String? groupOf(StoredRecord r, String id) =>
      r.information.memberSnapshot(id)?['group_id'] as String? ??
      model.members[id]?.groupId;
}
