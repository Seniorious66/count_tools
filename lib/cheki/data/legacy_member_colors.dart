import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../domain/member_color.dart';
import 'identity_contract.dart';
import 'identity_schema.dart';
import 'catalog_contract.dart';

/// Read-only compatibility for the scoped migration's original stable IDs.
/// Raw member rows and their audit history remain unchanged.
Future<List<IdentityEntity>> readMembersWithLegacyColors(
  DatabaseExecutor db, {
  bool includeInactive = true,
}) async {
  final rows = await db.query(
    IdentityKind.member.table,
    where: includeInactive ? null : 'active=1',
    orderBy: 'created_at,id',
  );
  final sources = {
    for (final row in await db.query('sub_project_data'))
      row['id'].toString(): parseLegacyMemberColor(row['color'] as String?),
  };
  final colors = <String, int>{}, cleared = <String>{};
  for (final op in await db.query(
    IdentitySchema.operations,
    where: 'kind=?',
    whereArgs: ['member'],
  )) {
    final id = op['id'] as String;
    const prefix = 's25-legacy-member:';
    if (id.startsWith(prefix)) {
      final color = sources[id.substring(prefix.length)];
      if (color != null) colors[op['entity_id'] as String] = color;
    }
    final request = jsonDecode(op['request_json'] as String) as Map;
    final inherited = request['inherited_color_rgb'];
    if (request['transfer'] is Map &&
        inherited is int &&
        inherited >= 0 &&
        inherited <= 0xffffff) {
      colors[op['entity_id'] as String] = inherited;
    }
    if (request['color_fallback_cleared'] == true) {
      cleared.add(op['entity_id'] as String);
    }
  }
  // A clear saved by an earlier candidate must remain a deliberate unknown.
  for (final h in await db.query(
    IdentitySchema.history,
    where: 'kind=? AND before_json IS NOT NULL',
    whereArgs: ['member'],
  )) {
    if (!colors.containsKey(h['entity_id'])) continue;
    final before = decodeSqlRow(h['before_json'] as String);
    final after = decodeSqlRow(h['after_json'] as String);
    if (before['color_rgb'] != null && after['color_rgb'] == null) {
      cleared.add(h['entity_id'] as String);
    }
  }
  return [
    for (final row in rows)
      IdentityEntity.fromRow(
        IdentityKind.member,
        row,
        fallbackColorRgb: cleared.contains(row['id'])
            ? null
            : colors[row['id']],
      ),
  ];
}
