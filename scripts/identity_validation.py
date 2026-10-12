"""Read-only schema 4 identity and full audit checks."""
from catalog_validation import ENTITY_FIELDS, action_stamp, decode_json, decode_row, entity, table_rows

TABLES = {'person': 'cheki_persons', 'member': 'cheki_members'}
OPS = 'cheki_identity_operations'
HISTORY = 'cheki_identity_history'


def identity(kind, row):
    entity(row)
    if row['source'] != 'user':
        raise ValueError('Identity source invalid')
    if kind == 'member':
        if row.get('group_id') is not None and (not isinstance(row['group_id'], str) or not row['group_id'].strip()):
            raise ValueError('Member group invalid')
        if row.get('person_id') is not None and (not isinstance(row['person_id'], str) or not row['person_id'].strip()):
            raise ValueError('Member person invalid')
        if row.get('color_rgb') is not None and (type(row['color_rgb']) is not int or not 0 <= row['color_rgb'] <= 0xffffff):
            raise ValueError('Member color invalid')


def verify_identity(db):
    entities = {kind: table_rows(db, table, ENTITY_FIELDS + (('group_id', 'person_id', 'color_rgb') if kind == 'member' else ())) for kind, table in TABLES.items()}
    ops = table_rows(db, OPS, ('id', 'kind', 'entity_id', 'request_json', 'result_json', 'created_at'))
    histories = table_rows(db, HISTORY, ('id', 'kind', 'entity_id', 'operation_id', 'before_json', 'after_json', 'created_at'))
    for table in (*TABLES.values(), OPS, HISTORY):
        if db.execute(f'PRAGMA foreign_key_check("{table}")').fetchall():
            raise ValueError('Identity foreign key violation')
    group_ids = {r[0] for r in db.execute('SELECT id FROM cheki_groups')}
    person_ids = {r['id'] for r in entities['person']}
    def references(row):
        if (row['group_id'] is not None and row['group_id'] not in group_ids) or (row['person_id'] is not None and row['person_id'] not in person_ids):
            raise ValueError('Historical member reference invalid')
    op_map = {r['id']: r for r in ops}
    catalog_ops = {r[0] for r in db.execute('SELECT id FROM cheki_catalog_operations')}
    if len(op_map) != len(ops) or catalog_ops.intersection(op_map):
        raise ValueError('Operation ID reused')
    linked, last = set(), {}
    for h in histories:
        kind, entity_id = h['kind'], h['entity_id']
        op = op_map.get(h['operation_id'])
        if kind not in TABLES or type(h['id']) is not int or h['id'] <= 0 or op is None:
            raise ValueError('Identity audit relationship invalid')
        if not isinstance(op['id'], str) or not op['id'].strip() or op['id'] in linked or op['kind'] != kind or op['entity_id'] != entity_id or op['created_at'] != h['created_at'] or not action_stamp(h['created_at']):
            raise ValueError('Identity audit operation mismatch')
        linked.add(op['id'])
        request = decode_json(op['request_json'])
        fields = request.get('fields')
        after, result = decode_row(h['after_json']), decode_row(op['result_json'])
        before = None if h['before_json'] is None else decode_row(h['before_json'])
        identity(kind, after)
        key = kind, entity_id
        previous = last.get(key)
        mutable = {'name', 'active'} | ({'person_id', 'color_rgb'} if kind == 'member' else set())
        allowed = mutable | ({'group_id'} if kind == 'member' and (before is None or (isinstance(fields, dict) and 'group_id' in fields)) else set())
        if request.get('kind') != kind or after['id'] != entity_id or after != result or after['updated_at'] != h['created_at'] or not isinstance(fields, dict) or set(fields) != allowed or any(after[k] != value for k, value in fields.items()):
            raise ValueError('Identity request/result mismatch')
        if type(fields['active']) is not int or fields['active'] not in (0, 1) or (kind == 'member' and fields['color_rgb'] is not None and type(fields['color_rgb']) is not int):
            raise ValueError('Identity request field type invalid')
        if kind == 'member': references(after)
        if before is None:
            if previous is not None or after['revision'] != 1 or after['created_at'] != after['updated_at'] or request.get('action') != 'create' or request.get('id') is not None or request.get('revision') is not None:
                raise ValueError('Identity creation history invalid')
            transfer = request.get('transfer')
            if transfer is not None:
                if not isinstance(transfer, dict) or set(transfer) != {'id', 'revision'} or type(transfer['revision']) is not int:
                    raise ValueError('Transfer request invalid')
                source = last.get(('member', transfer['id']))
                if kind != 'member' or source is None or source['person_id'] is None or source['revision'] != transfer['revision'] or source['group_id'] == after['group_id'] or source['person_id'] != after['person_id'] or source['color_rgb'] != after['color_rgb'] or source['updated_at'] > after['updated_at']:
                    raise ValueError('Transfer starting fact invalid')
        else:
            identity(kind, before)
            if kind == 'member' and 'group_id' in fields:
                if before['group_id'] is not None or after['group_id'] is None:
                    raise ValueError('Only unknown group may be completed in place')
                mutable.add('group_id')
            preserved = set(before) - mutable - {'updated_at', 'revision'}
            if previous is None or before != previous or set(after) - mutable - {'updated_at', 'revision'} != preserved or any(after[k] != before[k] for k in preserved) or after['revision'] != before['revision'] + 1 or after['updated_at'] < before['updated_at'] or request.get('action') != 'edit' or request.get('id') != entity_id or type(request.get('revision')) is not int or request['revision'] != before['revision'] or request.get('transfer') is not None:
                raise ValueError('Identity revision chain invalid')
            if kind == 'member': references(before)
        last[key] = after
    if len(linked) != len(ops): raise ValueError('Identity operation without history')
    found = set()
    for kind, rows in entities.items():
        for row in rows:
            identity(kind, row)
            if kind == 'member': references(row)
            key = kind, row['id']
            found.add(key)
            if last.get(key) != row: raise ValueError('Identity current/history mismatch')
    if not set(last) <= found: raise ValueError('Identity history references missing row')
    return {**{TABLES[k]: len(rows) for k, rows in entities.items()}, OPS: len(ops), HISTORY: len(histories)}
