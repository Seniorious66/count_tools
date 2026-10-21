import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'catalog_contract.dart';
import 'catalog_schema.dart';
import 'catalog_store.dart';
import 'identity_contract.dart';
import 'identity_schema.dart';
import 'legacy_member_colors.dart';

class IdentityDirectory {
  IdentityDirectory({
    required List<CatalogEntity> groups,
    required List<IdentityEntity> persons,
    required List<IdentityEntity> members,
  }) : groups = List.unmodifiable(groups),
       persons = List.unmodifiable(persons),
       members = List.unmodifiable(members);
  final List<CatalogEntity> groups;
  final List<IdentityEntity> persons;
  final List<IdentityEntity> members;
}

class IdentityStore {
  IdentityStore(this.database, {DateTime Function()? clock, this.afterWrite})
    : clock = clock ?? DateTime.now;
  final Future<Database> Function() database;
  final DateTime Function() clock;
  final Future<void> Function()? afterWrite;

  Future<IdentityDirectory> directory() async => (await database()).transaction(
    (tx) async => IdentityDirectory(
      groups: (await tx.query(
        CatalogKind.group.table,
        orderBy: 'created_at,id',
      )).map(CatalogEntity.fromRow).toList(),
      persons: (await tx.query(
        IdentityKind.person.table,
        orderBy: 'created_at,id',
      )).map((r) => IdentityEntity.fromRow(IdentityKind.person, r)).toList(),
      members: await readMembersWithLegacyColors(tx),
    ),
  );

  Future<List<IdentityEntity>> list(
    IdentityKind kind, {
    bool includeInactive = true,
  }) async {
    final db = await database();
    if (kind == IdentityKind.member) {
      return db.transaction(
        (tx) =>
            readMembersWithLegacyColors(tx, includeInactive: includeInactive),
      );
    }
    return (await db.query(
      kind.table,
      where: includeInactive ? null : 'active=1',
      orderBy: 'created_at,id',
    )).map((r) => IdentityEntity.fromRow(kind, r)).toList();
  }

  Future<List<Map<String, Object?>>> history(IdentityEntity entity) async =>
      (await database()).query(
        IdentitySchema.history,
        where: 'kind=? AND entity_id=?',
        whereArgs: [entity.kind.name, entity.id],
        orderBy: 'id',
      );

  Future<IdentityEntity> createPerson({
    required String name,
    required String operationId,
  }) => _write(
    IdentityKind.person,
    fields: {'name': _optionalName(name), 'active': 1},
    operationId: operationId,
  );

  Future<IdentityEntity> editPerson({
    required IdentityEntity original,
    required String name,
    required bool active,
    required String operationId,
  }) => _write(
    IdentityKind.person,
    fields: {'name': _optionalName(name), 'active': active ? 1 : 0},
    original: original,
    operationId: operationId,
  );

  Future<IdentityEntity> createMember({
    required String name,
    String? groupId,
    int? colorRgb,
    String? personId,
    required String operationId,
  }) => _write(
    IdentityKind.member,
    fields: {
      'name': _optionalName(name),
      'active': 1,
      'group_id': groupId,
      'person_id': personId,
      'color_rgb': colorRgb,
    },
    operationId: operationId,
  );

  Future<IdentityEntity> editMember({
    required IdentityEntity original,
    required String name,
    required int? colorRgb,
    String? fillGroupId,
    bool correctGroup = false,
    String? correctedGroupId,
    required String? personId,
    required bool active,
    required String operationId,
    bool clearColorFallback = false,
  }) => _write(
    IdentityKind.member,
    fields: {
      'name': _optionalName(name),
      if (correctGroup)
        'group_id': correctedGroupId
      else
        'group_id': ?fillGroupId,
      'active': active ? 1 : 0,
      'person_id': personId,
      'color_rgb': colorRgb,
    },
    original: original,
    operationId: operationId,
    clearColorFallback: clearColorFallback,
    correctGroup: correctGroup,
  );

  Future<IdentityEntity> transferMember({
    required IdentityEntity original,
    required String groupId,
    required String name,
    required String operationId,
  }) {
    if (original.kind != IdentityKind.member) {
      throw const CatalogException('请选择成员身份');
    }
    if (original.personId == null) {
      throw const CatalogException('请先设置同人关联，再转团');
    }
    return _write(
      IdentityKind.member,
      fields: {
        'name': _optionalName(name),
        'active': 1,
        'group_id': groupId,
        'person_id': original.personId,
        'color_rgb': original.toRow()['color_rgb'],
      },
      operationId: operationId,
      transfer: original,
      inheritedColorRgb: original.toRow()['color_rgb'] == null
          ? original.colorRgb
          : null,
    );
  }

  /// Snapshot of selected identities. Unlinked members remain independent;
  /// known same-Person duplicates never become two participants in one Cheki.
  Future<List<IdentityEntity>> validateSelection(
    List<String> ids, {
    Set<String> retainedIds = const {},
  }) async => (await database()).transaction(
    (tx) => selectionIn(tx, ids, retainedIds: retainedIds),
  );

  /// Used by the record service inside its existing write transaction.
  /// Never start a nested database transaction to check participants.
  static Future<List<IdentityEntity>> selectionIn(
    DatabaseExecutor tx,
    List<String> ids, {
    Set<String> retainedIds = const {},
  }) async {
    if (ids.toSet().length != ids.length) {
      throw const CatalogException('成员不能重复');
    }
    final persons = <String>{};
    final result = <IdentityEntity>[];
    for (final id in ids) {
      final rows = await tx.query(
        IdentityKind.member.table,
        where: 'id=?',
        whereArgs: [id],
      );
      if (rows.isEmpty) throw const CatalogException('成员信息已变化，请重新选择');
      final member = IdentityEntity.fromRow(IdentityKind.member, rows.single);
      final groups = member.groupId == null
          ? <Map<String, Object?>>[]
          : await tx.query(
              CatalogKind.group.table,
              where: 'id=?',
              whereArgs: [member.groupId],
            );
      final availability = MemberAvailability.fromMember(
        member,
        groups.isEmpty ? null : CatalogEntity.fromRow(groups.single),
      );
      if (availability.groupMissing ||
          (!retainedIds.contains(id) && !availability.available)) {
        throw CatalogException(
          '${member.name}${groups.isEmpty ? '' : '（${CatalogEntity.fromRow(groups.single).name}）'}：${availability.description}，请重新选择',
        );
      }
      if (member.personId != null && !persons.add(member.personId!)) {
        throw const CatalogException('同一张 Cheki 只能选择同一人的一个成员身份');
      }
      result.add(member);
    }
    return List<IdentityEntity>.unmodifiable(result);
  }

  Future<IdentityEntity> _write(
    IdentityKind kind, {
    required Map<String, Object?> fields,
    required String operationId,
    IdentityEntity? original,
    IdentityEntity? transfer,
    bool clearColorFallback = false,
    int? inheritedColorRgb,
    bool correctGroup = false,
  }) async {
    if (operationId.trim().isEmpty) {
      throw const CatalogException('操作标识缺失，请重新打开表单');
    }
    if (original != null && original.kind != kind) {
      throw const CatalogException('身份类型不匹配');
    }
    if (correctGroup &&
        (kind != IdentityKind.member ||
            original == null ||
            transfer != null ||
            !fields.containsKey('group_id') ||
            fields['group_id'] == original.groupId)) {
      throw const CatalogException('请选择需要纠正的团体');
    }
    if (clearColorFallback &&
        (kind != IdentityKind.member ||
            original == null ||
            fields['color_rgb'] != null)) {
      throw const CatalogException('清空颜色标识与输入不一致');
    }
    if (kind == IdentityKind.member &&
        fields['color_rgb'] != null &&
        (fields['color_rgb'] is! int ||
            (fields['color_rgb'] as int) < 0 ||
            (fields['color_rgb'] as int) > 0xffffff)) {
      throw const CatalogException('请选择有效成员颜色');
    }
    final request = jsonEncode({
      'kind': kind.name,
      'action': original == null ? 'create' : 'edit',
      'id': original?.id,
      'revision': original?.revision,
      'fields': fields,
      if (clearColorFallback) 'color_fallback_cleared': true,
      if (correctGroup) 'group_correction': true,
      'inherited_color_rgb': ?inheritedColorRgb,
      'transfer': transfer == null
          ? null
          : {'id': transfer.id, 'revision': transfer.revision},
    });
    return (await database()).transaction((tx) async {
      final old = await tx.query(
        IdentitySchema.operations,
        where: 'id=?',
        whereArgs: [operationId],
      );
      if (old.isNotEmpty) {
        if (old.single['request_json'] != request) {
          throw const CatalogException('此操作已用于其他修改，请重新核对');
        }
        return IdentityEntity.fromRow(
          kind,
          decodeSqlRow(old.single['result_json'] as String),
          fallbackColorRgb: inheritedColorRgb,
        );
      }
      if ((await tx.query(
        CatalogSchema.operations,
        where: 'id=?',
        whereArgs: [operationId],
      )).isNotEmpty) {
        throw const CatalogException('此操作已用于其他修改，请重新核对');
      }
      final recordTables = await tx.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cheki_record_operations'",
      );
      if (recordTables.isNotEmpty &&
          (await tx.query(
            'cheki_record_operations',
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('此操作已用于其他修改，请重新核对');
      }
      if ((await tx.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='cheki_ticket_operations'",
          )).isNotEmpty &&
          (await tx.query(
            'cheki_ticket_operations',
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('操作已用于其他修改');
      }
      if ((await tx.rawQuery(
            "SELECT name FROM sqlite_master WHERE name='cheki_transfer_operations'",
          )).isNotEmpty &&
          (await tx.query(
            'cheki_transfer_operations',
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('操作标识已用于交换赠送');
      }
      if ((await tx.rawQuery(
            "SELECT name FROM sqlite_master WHERE name='cheki_entry_operations'",
          )).isNotEmpty &&
          (await tx.query(
            'cheki_entry_operations',
            where: 'id=?',
            whereArgs: [operationId],
          )).isNotEmpty) {
        throw const CatalogException('此操作标识已用于关联记录');
      }
      Map<String, Object?>? before;
      if (original != null) {
        final rows = await tx.query(
          kind.table,
          where: 'id=?',
          whereArgs: [original.id],
        );
        if (rows.isEmpty || rows.single['revision'] != original.revision) {
          throw const CatalogException('内容已被修改，请返回列表重新打开');
        }
        before = rows.single;
      }
      if (kind == IdentityKind.member) {
        if (before != null &&
            fields.containsKey('group_id') &&
            before['group_id'] != null &&
            !correctGroup) {
          throw const CatalogException('已知团体变更请使用转团新增身份');
        }
        final groupId = fields.containsKey('group_id')
            ? fields['group_id']
            : before?['group_id'];
        final groups = groupId == null
            ? <Map<String, Object?>>[]
            : await tx.query(
                CatalogKind.group.table,
                where: 'id=?',
                whereArgs: [groupId],
              );
        if (groupId != null && groups.isEmpty) {
          throw const CatalogException('团体信息不可用，请重新选择');
        }
        if (transfer != null && groupId == null) {
          throw const CatalogException('请选择有效团体');
        }
        if ((before == null || correctGroup) &&
            groups.isNotEmpty &&
            groups.single['active'] != 1) {
          throw CatalogException(
            '${CatalogEntity.fromRow(groups.single).name}：团体已停用，请重新选择',
          );
        }
        if (correctGroup) {
          final conflicts = await groupCorrectionConflictsIn(
            tx,
            original!.id,
            groupId as String?,
          );
          if (conflicts.isNotEmpty) {
            throw CatalogException('团体纠正影响以下关联，请先核对：\n${conflicts.join('\n')}');
          }
        }
        final personId = fields['person_id'];
        if (personId != null) {
          final persons = await tx.query(
            IdentityKind.person.table,
            where: 'id=?',
            whereArgs: [personId],
          );
          if (persons.isEmpty ||
              (persons.single['active'] != 1 &&
                  (before == null || personId != before['person_id']))) {
            throw const CatalogException('请选择有效的同人关联');
          }
        }
        if (before != null &&
            personId != null &&
            personId != before['person_id'] &&
            recordTables.isNotEmpty) {
          for (final record in await tx.query('cheki_records')) {
            final info =
                jsonDecode(record['information_json'] as String) as Map;
            final ids = (info['member_ids'] as List?) ?? [];
            if (!ids.contains(before['id'])) continue;
            for (final id in ids.where((id) => id != before!['id'])) {
              final peers = await tx.query(
                kind.table,
                where: 'id=?',
                whereArgs: [id],
              );
              if (peers.isNotEmpty && peers.single['person_id'] == personId) {
                throw const CatalogException('已有合影包含此人的另一身份，请先核对记录');
              }
            }
          }
        }
        if (transfer != null) {
          final rows = await tx.query(
            kind.table,
            where: 'id=?',
            whereArgs: [transfer.id],
          );
          if (rows.isEmpty || rows.single['revision'] != transfer.revision) {
            throw const CatalogException('原身份已变化，请重新打开');
          }
          if (groupId == rows.single['group_id']) {
            throw const CatalogException('转团请选择不同团体');
          }
          if (personId != rows.single['person_id'] ||
              fields['color_rgb'] != rows.single['color_rgb']) {
            throw const CatalogException('原身份已变化，请重新核对');
          }
        }
      }
      final stamp = actionStamp(clock());
      if (before != null &&
          stamp.compareTo(before['updated_at'] as String) < 0) {
        throw const CatalogException('系统时间早于上次修改，请校准后重试');
      }
      if (transfer != null && stamp.compareTo(transfer.updatedAt) < 0) {
        throw const CatalogException('系统时间早于原身份修改，请校准后重试');
      }
      final row = before == null
          ? <String, Object?>{
              'id': newOperationId(),
              'created_at': stamp,
              'updated_at': stamp,
              'revision': 1,
              'source': 'user',
              'ext': null,
              ...fields,
            }
          : {
              ...copySqlRow(before),
              ...fields,
              'updated_at': stamp,
              'revision': (before['revision'] as int) + 1,
            };
      IdentityEntity.fromRow(kind, row);
      if (before == null) {
        await tx.insert(
          kind.table,
          row,
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
        final stored = (await tx.query(
          kind.table,
          where: 'id=?',
          whereArgs: [row['id']],
        )).single;
        row
          ..clear()
          ..addAll(copySqlRow(stored));
      } else {
        final changed = await tx.update(
          kind.table,
          {...row}..remove('id'),
          where: 'id=? AND revision=?',
          whereArgs: [original!.id, original.revision],
        );
        if (changed != 1) throw const CatalogException('内容已变化，请重新核对');
      }
      final result = encodeSqlRow(row);
      await tx.insert(IdentitySchema.operations, {
        'id': operationId,
        'kind': kind.name,
        'entity_id': row['id'],
        'request_json': request,
        'result_json': result,
        'created_at': stamp,
      });
      await tx.insert(IdentitySchema.history, {
        'kind': kind.name,
        'entity_id': row['id'],
        'operation_id': operationId,
        'before_json': before == null ? null : encodeSqlRow(before),
        'after_json': result,
        'created_at': stamp,
      });
      if (afterWrite != null) await afterWrite!();
      return IdentityEntity.fromRow(
        kind,
        row,
        fallbackColorRgb: inheritedColorRgb,
      );
    });
  }

  static String? _optionalName(String value) =>
      value.trim().isEmpty ? null : value.trim();

  /// A correction changes only current affiliation. Immutable record snapshots,
  /// ticket definitions and consumed allocations are never rewritten here.
  static Future<List<String>> groupCorrectionConflictsIn(
    DatabaseExecutor tx,
    String memberId,
    String? groupId,
  ) async {
    if ((await tx.rawQuery(
      "SELECT name FROM sqlite_master WHERE name='cheki_ticket_objects'",
    )).isEmpty) {
      return const [];
    }
    final conflicts = <String>[];
    final definitions = <String, Map>{};
    for (final row in await tx.query(
      'cheki_ticket_objects',
      where: 'kind=?',
      whereArgs: ['definition'],
    )) {
      final info = jsonDecode(row['information_json'] as String) as Map;
      definitions[row['id'] as String] = info;
      if (info['member_id'] == memberId &&
          info['group_id'] != null &&
          info['group_id'] != groupId) {
        conflicts.add('个人券 #${row['seq']} 的团体不一致');
      }
    }
    if ((await tx.rawQuery(
      "SELECT name FROM sqlite_master WHERE name='cheki_entry_states'",
    )).isNotEmpty) {
      for (final state in await tx.query('cheki_entry_states')) {
        final plan = jsonDecode(state['plan_json'] as String) as Map;
        for (final line in plan['lines'] as List? ?? []) {
          final item = line as Map;
          final def = definitions[item['definition_id']];
          if (item['member_id'] == memberId &&
              def != null &&
              def['group_id'] != null &&
              def['group_id'] != groupId) {
            conflicts.add('记录 ${state['record_id']} 的用券团体不一致');
            break;
          }
        }
      }
    }
    return List.unmodifiable(conflicts);
  }
}
