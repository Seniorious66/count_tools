"""Read-only SQLite checks; never installs, restores or edits app data."""
import argparse
import json
import sqlite3
from record_validation import verify_records
from catalog_validation import verify_catalog
from identity_validation import verify_identity
from contextlib import closing
from pathlib import Path


def verify(path):
    path = Path(path).resolve(strict=True)
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        if [r[0] for r in db.execute('PRAGMA integrity_check')] != ['ok']:
            raise ValueError('SQLite integrity check failed')
        required = {'users', 'project_data', 'sub_project_data', 'item_data'}
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not required <= tables:
            raise ValueError('Required tables missing')
        schema = db.execute('PRAGMA user_version').fetchone()[0]
        if schema not in (1, 2, 3, 4, 5):
            raise ValueError('Unsupported storage version')
        columns = {
            'users': ('id', 'username', 'user_key', 'ext'),
            'project_data': ('id', 'title', 'subTitle', 'count', 'ext'),
            'sub_project_data': ('id', 'name', 'count', 'countPre', 'color', 'textColor', 'parentId', 'ext'),
            'item_data': ('id', 'price', 'eventName', 'type', 'date', 'itemName', 'parentId', 'projectId', 'ext'),
        }
        import re
        for table, fields in columns.items():
            names = {r[1] for r in db.execute(f'PRAGMA table_info("{table}")')}
            if not set(fields) <= names:
                raise ValueError('Required storage columns missing')
            for row in db.execute(f'SELECT {",".join(fields)} FROM "{table}"'):
                if type(row[0]) is not int or row[0] <= 0:
                    raise ValueError('Invalid record ID')
                if any(v is not None and not isinstance(v, str) for v in row[1:]):
                    raise ValueError('Invalid legacy field storage type')
                if table in ('project_data', 'sub_project_data'):
                    count = row[fields.index('count')]
                    if not isinstance(count, str) or not re.fullmatch(r'\d+', count):
                        raise ValueError('Invalid legacy count')
        if schema >= 2:
            expected = [(2, 'preserve_legacy_v1')] + ([(3, 'catalog_base_v1')] if schema >= 3 else []) + ([(4, 'identity_base_v1')] if schema >= 4 else []) + ([(5, 'nullable_business_v1')] if schema >= 5 else [])
            if 'count_tools_migrations' not in tables or db.execute(
                'SELECT version,migration FROM count_tools_migrations ORDER BY version').fetchall() != expected:
                raise ValueError('Storage migration ledger is invalid')
        counts = {t: db.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in sorted(required)}
        if schema >= 3:
            counts.update(verify_catalog(db))
        if schema >= 4:
            counts.update(verify_identity(db))
        if schema >= 5:
            counts.update(verify_records(db))
        queries = {
            'orphan_subprojects': 'SELECT COUNT(*) FROM sub_project_data s LEFT JOIN project_data p ON s.parentId=p.id WHERE p.id IS NULL',
            'orphan_items': 'SELECT COUNT(*) FROM item_data i LEFT JOIN sub_project_data s ON i.parentId=s.id LEFT JOIN project_data p ON i.projectId=p.id WHERE s.id IS NULL OR p.id IS NULL OR CAST(i.projectId AS TEXT) != CAST(s.parentId AS TEXT)',
            'subproject_count_mismatches': 'SELECT COUNT(*) FROM sub_project_data s WHERE CAST(s.count AS INTEGER) != (SELECT COUNT(*) FROM item_data i WHERE i.parentId=s.id)',
            'project_count_mismatches': 'SELECT COUNT(*) FROM project_data p WHERE CAST(p.count AS INTEGER) != (SELECT COUNT(*) FROM sub_project_data s WHERE s.parentId=p.id)',
        }
        checks = {k: db.execute(q).fetchone()[0] for k, q in queries.items()}
        if any(checks.values()):
            raise ValueError('Relationship/count checks failed: ' + json.dumps(checks))
        return {'integrity': 'ok', 'schema_version': db.execute('PRAGMA user_version').fetchone()[0], 'row_counts': counts, 'checks': checks}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.database), ensure_ascii=False))
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f'Database check failed: {error}\n')
