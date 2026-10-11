"""Read-only SQLite checks; never installs, restores or edits app data."""
import argparse
import json
import sqlite3
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
        counts = {t: db.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in sorted(required)}
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
