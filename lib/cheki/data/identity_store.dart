import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'catalog_contract.dart';
import 'catalog_schema.dart';
import 'catalog_store.dart';
import 'identity_contract.dart';
import 'identity_schema.dart';

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
      members: (await tx.query(
        IdentityKind.member.table,
        orderBy: 'created_at,id',
      )).map((r) => IdentityEntity.fromRow(IdentityKind.member, r)).toList(),
    ),
  );

  Future<List<IdentityEntity>> list(
    IdentityKind kind, {
    bool includeInactive = true,
  }) async => (await (await database()).query(
    kind.table,
    where: includeInactive ? null : 'active=1',
    orderBy: 'created_at,id',
  )).map((r) => IdentityEntity.fromRow(kind, r)).toList();

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
    fields: {'name': name.trim(), 'active': 1},
    operationId: operationId,
  );

  Future<IdentityEntity> editPerson({
    required IdentityEntity original,
    required String name,
    required bool active,
    required String operationId,
  }) => _write(
    IdentityKind.person,
    fields: {'name': name.trim(), 'active': active ? 1 : 0},
    original: original,
    operationId: operationId,
  );

  Future<IdentityEntity> createMember({
    required String name,
    required String groupId,
    required int colorRgb,
    String? personId,
    required String operationId,
  }) => _write(
    IdentityKind.member,
    fields: {
      'name': name.trim(),
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
    required int colorRgb,
    required String? personId,
    required bool active,
    required String operationId,
  }) => _write(
    IdentityKind.member,
    fields: {
      'name': name.trim(),
      'active': active ? 1 : 0,
      'person_id': personId,
      'color_rgb': colorRgb,
    },
    original: original,
    operationId: operationId,
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
        'name': name.trim(),
        'active': 1,
        'group_id': groupId,
        'person_id': original.personId,
        'color_rgb': original.colorRgb,
      },
      operationId: operationId,
      transfer: original,
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
    if (ids.isEmpty || ids.toSet().length != ids.length) {
      throw const CatalogException('请选择成员，且不能重复');
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
      final groups = await tx.query(
        CatalogKind.group.table,
        where: 'id=?',
        whereArgs: [member.groupId],
      );
      if (groups.isEmpty ||
          (!retainedIds.contains(id) &&
              (!member.active || groups.single['active'] != 1))) {
        throw const CatalogException('成员或团体已停用，请重新选择');
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
  }) async {
    if ((fields['name'] as String).isEmpty) {
      throw const CatalogException('请输入名称');
    }
    if (operationId.trim().isEmpty) {
      throw const CatalogException('操作标识缺失，请重新打开表单');
    }
    if (original != null && original.kind != kind) {
      throw const CatalogException('身份类型不匹配');
    }
    if (kind == IdentityKind.member &&
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
        );
      }
      if ((await tx.query(
        CatalogSchema.operations,
        where: 'id=?',
        whereArgs: [operationId],
      )).isNotEmpty) {
        throw const CatalogException('此操作已用于其他修改，请重新核对');
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
        final groupId = before?['group_id'] ?? fields['group_id'];
        final groups = await tx.query(
          CatalogKind.group.table,
          where: 'id=?',
          whereArgs: [groupId],
        );
        if (groups.isEmpty ||
            (before == null && groups.single['active'] != 1)) {
          throw const CatalogException('请选择有效团体');
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
      return IdentityEntity.fromRow(kind, row);
    });
  }
}
