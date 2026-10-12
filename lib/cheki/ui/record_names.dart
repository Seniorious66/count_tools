import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/identity_store.dart';
import '../domain/record_information.dart';
import 'components.dart';

/// Draft only. Selection captures entry labels only on the explicit quick-new
/// path. Historical entry and editing never infer event names from a directory.
class RecordNamesController {
  RecordNamesController(this.original) {
    for (final item in original.toMap()['member_snapshots'] as List? ?? []) {
      final row = Map<String, Object?>.from(item as Map);
      entries[row['member_id'] as String] = row;
    }
  }
  final RecordInformation original;
  final entries = <String, Map<String, Object?>>{};
  void select(
    List<String> ids,
    IdentityDirectory directory, {
    required bool captureNew,
  }) {
    if (!captureNew) return;
    for (final id in ids) {
      if (entries.containsKey(id)) continue;
      final members = directory.members.where((m) => m.id == id);
      if (members.isEmpty) continue;
      final m = members.single;
      final groups = directory.groups.where((g) => g.id == m.groupId);
      entries[id] = {
        'member_id': id,
        'member_name': m.knownName,
        'group_id': m.groupId,
        'group_name': groups.isEmpty ? null : groups.single.knownName,
        'origin': 'entry',
      };
    }
  }

  void change(String id, String key, String value) {
    final row = entries.putIfAbsent(id, () => {'member_id': id});
    if ((row[key] ?? '') == value) return;
    row[key] = value.isEmpty ? null : value;
    row.putIfAbsent('origin', () => 'manual');
    row['${key}_origin'] = 'manual';
  }

  Map<String, Object?> patch(List<String> ids) {
    final old = original.toMap();
    final value = [
      for (final row in entries.values)
        if (ids.contains(row['member_id'])) row,
    ];
    if (value.isEmpty &&
        (old['member_snapshots'] == null ||
            (old['member_snapshots'] as List).isEmpty)) {
      return {};
    }
    if (jsonEncode(value) == jsonEncode(old['member_snapshots'])) return {};
    return {'member_snapshots': value};
  }
}

class RecordNamesEditor extends StatelessWidget {
  const RecordNamesEditor({
    required this.controller,
    required this.memberIds,
    required this.currentLabels,
    required this.onChanged,
    super.key,
  });
  final RecordNamesController controller;
  final List<String> memberIds;
  final Map<String, String> currentLabels;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('记录名称'),
    subtitle: const Text('可补录当时名称'),
    children: [
      if (memberIds.isEmpty) const Text('选择参与成员后可填写名称'),
      for (final id in memberIds)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: ChekiCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(currentLabels[id] ?? '成员信息不可用'),
                TextFormField(
                  key: ValueKey('snapshot-group-$id'),
                  initialValue:
                      controller.entries[id]?['group_name'] as String? ?? '',
                  decoration: const InputDecoration(labelText: '团体名称'),
                  onChanged: (v) {
                    controller.change(id, 'group_name', v);
                    onChanged();
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: ValueKey('snapshot-member-$id'),
                  initialValue:
                      controller.entries[id]?['member_name'] as String? ?? '',
                  decoration: const InputDecoration(labelText: '成员名称'),
                  onChanged: (v) {
                    controller.change(id, 'member_name', v);
                    onChanged();
                  },
                ),
              ],
            ),
          ),
        ),
    ],
  );
}
