"""Compare an existing E backup with its NAS copy, without modifying either."""
import argparse
import hashlib
import importlib.util
import json
import shlex
import subprocess
import zipfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('database', HERE / 'verify-database.py')
database = importlib.util.module_from_spec(spec)
spec.loader.exec_module(database)


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Backup symlinks are unsupported')
        if path.is_file():
            with path.open('rb') as source:
                digest = hashlib.file_digest(source, 'sha256').hexdigest()
            result[path.relative_to(root).as_posix()] = {'size': path.stat().st_size, 'sha256': digest}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local', required=True)
    parser.add_argument('--nas', required=True)
    parser.add_argument('--receipt', required=True, help='New internal receipt outside the repository and both backup directories')
    parser.add_argument('--user-confirmed-unchanged', action='store_true')
    args = parser.parse_args()
    root = Path(args.local).resolve(strict=True)
    receipt = Path(args.receipt).resolve()
    repo = HERE.parent
    if receipt.is_relative_to(repo) or receipt.is_relative_to(root) or receipt.exists():
        raise ValueError('Receipt must be a new file outside repository and backup')
    if not args.nas.startswith('/srv/nas/hdd/Code/artifacts/count-tools-export/') or '..' in Path(args.nas).parts:
        raise ValueError('NAS path is outside the approved backup location')
    snapshot = datetime.strptime(root.name, '%Y%m%d_%H%M%S')
    archive_name = root.name + '.zip'
    required = {archive_name, 'count_tools.bak', 'count_tools.tar', 'user_database.db',
                'user_database.db-journal', 'extracted/sp/FlutterSharedPreferences.xml', 'verification.json'}
    local = inventory(root)
    if not required <= local.keys():
        raise ValueError('Original backup components missing')
    old = json.loads((root / 'verification.json').read_text(encoding='utf-8'))
    if local[archive_name]['sha256'] != old['backup_sha256'] or local['user_database.db']['sha256'] != old['database_sha256']:
        raise ValueError('Original backup differs from saved verification')
    with zipfile.ZipFile(root / archive_name) as archive:
        if archive.testzip() is not None:
            raise ValueError('Backup ZIP CRC failed')
    for entry in old['files']:
        prefix = 'apps/com.example.count_tools/'
        if not entry['path'].startswith(prefix):
            raise ValueError('Unexpected original manifest path')
        relative = 'extracted/' + entry['path'][len(prefix):]
        if '..' in Path(relative).parts or local.get(relative) != {'size': entry['size'], 'sha256': entry['sha256']}:
            raise ValueError('Extracted component differs from original verification')
    db_result = database.verify(root / 'user_database.db')
    remote_code = '''import pathlib,hashlib,json,sqlite3,contextlib,sys
r=pathlib.Path(sys.argv[1]).resolve(strict=True)
files={}
for p in sorted(r.rglob('*')):
 if p.is_symlink(): raise ValueError('Backup symlink unsupported')
 if p.is_file():
  h=hashlib.sha256()
  with p.open('rb') as f:
   for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
  files[p.relative_to(r).as_posix()]={'size':p.stat().st_size,'sha256':h.hexdigest()}
with contextlib.closing(sqlite3.connect((r/'user_database.db').as_uri()+'?mode=ro',uri=True)) as db:
 db.execute('PRAGMA query_only=ON')
 integrity=[x[0] for x in db.execute('PRAGMA integrity_check')]
 counts={t:db.execute('SELECT COUNT(*) FROM '+t).fetchone()[0] for t in ['users','project_data','sub_project_data','item_data']}
print(json.dumps({'files':files,'integrity':integrity,'row_counts':counts}))
'''
    command = 'python3 -c ' + shlex.quote(remote_code) + ' ' + shlex.quote(args.nas)
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', 'home-server', command],
                            capture_output=True, text=True, encoding='utf-8', timeout=60)
    if result.returncode:
        raise ValueError('NAS read-only validation failed')
    remote = json.loads(result.stdout)
    if local != remote['files'] or remote['integrity'] != ['ok'] or db_result['row_counts'] != remote['row_counts']:
        raise ValueError('NAS files or database differ from E backup')
    record = {'verified_at_utc': datetime.now(timezone.utc).isoformat(), 'snapshot': snapshot.strftime('%Y-%m-%d %H:%M:%S Asia/Shanghai'),
              'freshness': 'user-confirmed-unchanged' if args.user_confirmed_unchanged else 'historical-snapshot-only',
              'local': str(root), 'nas_host': 'home-server', 'nas_path': args.nas,
              'file_count': len(local), 'byte_count': sum(x['size'] for x in local.values()),
              'files_match': True, 'database': db_result, 'files': local}
    receipt.parent.mkdir(parents=True, exist_ok=True)
    with receipt.open('x', encoding='utf-8') as output:
        json.dump(record, output, ensure_ascii=False, indent=2)
    print(json.dumps({k: record[k] for k in ['freshness', 'file_count', 'byte_count', 'files_match', 'database']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
