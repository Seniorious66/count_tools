"""Read-only schema 3 catalog checks, also used by complete recovery."""
import base64
import datetime
import json
import re

ENTITY_FIELDS = ('id', 'name', 'active', 'created_at', 'updated_at', 'revision', 'source', 'ext')
TABLES = {'group': 'cheki_groups', 'size': 'cheki_sizes'}
DEFAULT_SIZES = {'size-3inch': '三寸', 'size-5inch': '五寸'}


def action_stamp(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.000Z', value):
        return False
    try:
        return datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%S.000Z').isoformat(timespec='milliseconds') + 'Z' == value
    except ValueError:
        return False


def entity(row):
    if not set(ENTITY_FIELDS) <= row.keys() or not isinstance(row['id'], str) or not row['id'].strip() or (row['name'] is not None and not isinstance(row['name'], str)):
        raise ValueError('Catalog identity/name invalid')
    if type(row['active']) is not int or row['active'] not in (0, 1) or type(row['revision']) is not int or row['revision'] < 1:
        raise ValueError('Catalog state/revision invalid')
    if row['source'] not in ('default', 'user') or any(not action_stamp(row[k]) for k in ('created_at', 'updated_at')) or row['updated_at'] < row['created_at']:
        raise ValueError('Catalog source/action timestamps invalid')
    if row['ext'] is not None and not isinstance(row['ext'], str):
        raise ValueError('Catalog ext storage type invalid')


def decode_json(value):
    def pairs(items):
        result = {}
        for key, item in items:
            if key in result:
                raise ValueError('Duplicate catalog JSON key')
            result[key] = item
        return result
    def invalid_constant(_):
        raise ValueError('Nonfinite catalog JSON number')
    if not isinstance(value, str):
        raise ValueError('Catalog audit JSON type invalid')
    try:
        parsed = json.loads(value, object_pairs_hook=pairs, parse_constant=invalid_constant)
    except (ValueError, TypeError) as error:
        raise ValueError('Catalog audit JSON invalid') from error
    if not isinstance(parsed, dict):
        raise ValueError('Catalog audit JSON must be an object')
    return parsed


def decode_row(value):
    row = decode_json(value)
    for key, data in row.items():
        if isinstance(data, dict) and set(data) == {'sqlite_blob_base64'}:
            try:
                row[key] = base64.b64decode(data['sqlite_blob_base64'], validate=True)
            except (ValueError, TypeError) as error:
                raise ValueError('Catalog blob encoding invalid') from error
        elif isinstance(data, (dict, list, bool)):
            raise ValueError('Catalog snapshot contains a non-SQL value')
    return row


def table_rows(db, table, fields, order='id'):
    names = {r[1] for r in db.execute(f'PRAGMA table_info("{table}")')}
    if not set(fields) <= names:
        raise ValueError('Catalog required columns missing')
    cursor = db.execute(f'SELECT * FROM "{table}" ORDER BY "{order}"')
    keys = [d[0] for d in cursor.description]
    return [dict(zip(keys, row)) for row in cursor]


def verify_catalog(db):
    # This extension owns only the new catalog foreign key; unknown legacy
    # objects continue to be preserved by the generic full-database transport.
    if db.execute('PRAGMA foreign_key_check(cheki_catalog_history)').fetchall():
        raise ValueError('Catalog foreign key violation')
    ops = table_rows(db, 'cheki_catalog_operations', ('id', 'kind', 'entity_id', 'request_json', 'result_json', 'created_at'))
    operation_map = {row['id']: row for row in ops}
    if len(operation_map) != len(ops):
        raise ValueError('Duplicate catalog operation ID')
    histories = table_rows(db, 'cheki_catalog_history', ('id', 'kind', 'entity_id', 'operation_id', 'before_json', 'after_json', 'created_at'))
    linked = set()
    last = {}
    for history in histories:
        kind, entity_id, op_id = history['kind'], history['entity_id'], history['operation_id']
        op = operation_map.get(op_id)
        if kind not in TABLES or type(history['id']) is not int or history['id'] <= 0 or not op:
            raise ValueError('Catalog operation/history invalid')
        if not isinstance(op_id, str) or not op_id.strip() or op_id in linked or op['kind'] != kind or op['entity_id'] != entity_id or op['created_at'] != history['created_at'] or not action_stamp(history['created_at']):
            raise ValueError('Catalog operation/history relationship invalid')
        linked.add(op_id)
        request = decode_json(op['request_json'])
        after = decode_row(history['after_json'])
        result = decode_row(op['result_json'])
        before = None if history['before_json'] is None else decode_row(history['before_json'])
        entity(after)
        key = (kind, entity_id)
        previous = last.get(key)
        if request.get('kind') != kind or after['id'] != entity_id or after != result or after['updated_at'] != history['created_at']:
            raise ValueError('Catalog result/audit mismatch')
        if request.get('name') != after['name'] or type(request.get('active')) is not bool or request['active'] != bool(after['active']):
            raise ValueError('Catalog request/result mismatch')
        if before is None:
            if previous is not None or after['revision'] != 1 or after['source'] != 'user' or after['created_at'] != after['updated_at'] or request.get('action') != 'create' or request.get('id') is not None or request.get('revision') is not None:
                raise ValueError('Catalog creation audit invalid')
        else:
            entity(before)
            if before['id'] != entity_id or after['revision'] != before['revision'] + 1 or after['created_at'] != before['created_at'] or after['source'] != before['source'] or after['updated_at'] < before['updated_at']:
                raise ValueError('Catalog revision chain invalid')
            if request.get('action') != 'edit' or request.get('id') != entity_id or type(request.get('revision')) is not int or request['revision'] != before['revision']:
                raise ValueError('Catalog edit request invalid')
            if previous is not None and before != previous:
                raise ValueError('Catalog history discontinuity')
            if previous is None and not (kind == 'size' and before['source'] == 'default' and before['revision'] == 1 and DEFAULT_SIZES.get(entity_id) == before['name'] and before['active'] == 1 and before['created_at'] == before['updated_at']):
                raise ValueError('Catalog history starting fact missing')
            preserved = set(before) - {'name', 'active', 'updated_at', 'revision'}
            if preserved != set(after) - {'name', 'active', 'updated_at', 'revision'}:
                raise ValueError('Catalog edit changed original field set')
            for field in preserved:
                if field not in after or after[field] != before[field]:
                    raise ValueError('Catalog edit lost an original field')
        last[key] = after
    if len(linked) != len(ops):
        raise ValueError('Catalog operation missing history')
    found = set()
    counts = {}
    for kind, table in TABLES.items():
        rows = table_rows(db, table, ENTITY_FIELDS)
        counts[table] = len(rows)
        for row in rows:
            entity(row)
            key = (kind, row['id'])
            found.add(key)
            if row['source'] == 'default' and not (kind == 'size' and row['id'] in DEFAULT_SIZES):
                raise ValueError('Catalog default source invalid')
            if kind == 'size' and row['id'] in DEFAULT_SIZES and row['source'] != 'default':
                raise ValueError('Catalog default size replaced')
            if key not in last:
                if not (kind == 'size' and row['source'] == 'default' and row['revision'] == 1 and DEFAULT_SIZES.get(row['id']) == row['name'] and row['active'] == 1 and row['created_at'] == row['updated_at']):
                    raise ValueError('Catalog entity missing history')
            elif row != last[key]:
                raise ValueError('Catalog current row/history mismatch')
    if not set(last) <= found or not {('size', key) for key in DEFAULT_SIZES} <= found:
        raise ValueError('Catalog referenced/default entity missing')
    return {**counts, 'cheki_catalog_operations': len(ops), 'cheki_catalog_history': len(histories)}
