"""Complete local engineering backup/restore. Writes only marked isolated roots."""
import argparse
import base64
import hashlib
import json
import math
import os
import re
import shutil
import sqlite3
import uuid
import xml.etree.ElementTree as ET
from contextlib import closing, contextmanager
from pathlib import Path

from importlib.util import spec_from_file_location, module_from_spec

REPO = Path(__file__).resolve().parents[1]
spec = spec_from_file_location('legacy_check', REPO / 'scripts/verify-database.py')
legacy_check = module_from_spec(spec)
spec.loader.exec_module(legacy_check)
MARKER = {'project': 'count_tools', 'purpose': 'isolated-recovery', 'format': 1}


def external(path):
    path = Path(path).resolve()
    if path == path.parent or path == REPO or REPO in path.parents:
        raise ValueError('Private recovery artifacts require an external non-root directory')
    return path


def write_json(path, value):
    temporary = path.with_name(path.name + '.writing-' + uuid.uuid4().hex)
    with temporary.open('x', encoding='utf-8') as output:
        json.dump(value, output, ensure_ascii=False, sort_keys=True, allow_nan=False)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def unsafe_link(path):
    return path.is_symlink() or path.is_junction()


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def canonical(value):
    if isinstance(value, bytes):
        return {'blob': base64.b64encode(value).decode('ascii')}
    if isinstance(value, float) and not math.isfinite(value):
        return {'sqlite_float': repr(value)}
    return value


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key; refusing to discard a value')
        result[key] = value
    return result


def database_audit(path):
    path = Path(path).resolve(strict=True)
    checks = legacy_check.verify(path)
    if checks['schema_version'] not in (1, 2, 3, 4, 5, 6, 7):
        raise ValueError('Unsupported database schema; no automatic conversion')
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        objects = db.execute('SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name').fetchall()
        tables = {}
        for table, in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"):
            columns = db.execute('PRAGMA table_info(' + quote(table) + ')').fetchall()
            rows = sorted(json.dumps([canonical(v) for v in row], ensure_ascii=False, allow_nan=False)
                          for row in db.execute('SELECT * FROM ' + quote(table)))
            tables[table] = {'columns': columns, 'count': len(rows),
                             'content': hashlib.sha256('\n'.join(rows).encode()).hexdigest()}
        return {'version': checks['schema_version'], 'objects': objects, 'tables': tables}


def settings_summary(path):
    path = Path(path)
    if path.suffix.lower() == '.xml':
        root = ET.parse(path).getroot()
        if root.tag != 'map':
            raise ValueError('Android settings root must be map')
        names = set()
        types = {}
        for node in root:
            name = node.get('name')
            if not name or name in names:
                raise ValueError('Settings keys missing or duplicated')
            names.add(name)
            if node.tag == 'boolean':
                if node.get('value') not in ('true', 'false'):
                    raise ValueError('Invalid boolean setting')
            elif node.tag in ('int', 'long'):
                int(node.attrib['value'])
            elif node.tag == 'float':
                if not math.isfinite(float(node.attrib['value'])):
                    raise ValueError('Nonfinite setting')
            elif node.tag == 'set':
                if any(child.tag != 'string' for child in node):
                    raise ValueError('Unsupported settings set')
            elif node.tag != 'string':
                raise ValueError('Unsupported settings type; preserve source and extend reader')
            types[node.tag] = types.get(node.tag, 0) + 1
        return {'format': 'android-xml', 'count': len(names), 'types': types}
    with path.open(encoding='utf-8-sig') as source:
        data = json.load(source, object_pairs_hook=unique_pairs)
    if not isinstance(data, dict):
        raise ValueError('Preferences JSON must contain a complete key/value map')
    types = {}
    for key, value in data.items():
        if not isinstance(key, str) or not isinstance(value, (str, int, float, bool, list)):
            raise ValueError('Unsupported preference value')
        if isinstance(value, list) and any(not isinstance(v, str) for v in value):
            raise ValueError('Preference lists must contain strings')
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError('Nonfinite preference')
        kind = type(value).__name__
        types[kind] = types.get(kind, 0) + 1
    return {'format': 'preferences-json', 'count': len(data), 'types': types}


def file_inventory(bundle):
    inventory = {}
    for path in sorted(bundle.rglob('*')):
        if unsafe_link(path):
            raise ValueError('Backup symbolic links are not supported')
        if path.is_file() and path != bundle / 'manifest.json':
            relative = path.relative_to(bundle).as_posix()
            inventory[relative] = {'size': path.stat().st_size, 'sha256': digest(path)}
    return inventory


def summary(manifest):
    return {'format': manifest['format'], 'schema_version': manifest['database']['version'],
            'row_counts': {name: data['count'] for name, data in manifest['database']['tables'].items()},
            'settings': manifest['settings']['summary'], 'file_count': len(manifest['files'])}


def verify_bundle(bundle):
    if unsafe_link(Path(bundle).absolute()):
        raise ValueError('Backup cannot be a link')
    bundle = external(bundle)
    if not bundle.is_dir():
        raise ValueError('Backup directory missing or unsafe')
    with (bundle / 'manifest.json').open(encoding='utf-8') as source:
        manifest = json.load(source, object_pairs_hook=unique_pairs)
    if manifest.get('format') != 1 or not isinstance(manifest.get('files'), dict):
        raise ValueError('Unsupported backup format')
    for name in manifest['files']:
        if '\\' in name or ':' in name or any(part in ('', '.', '..') for part in name.split('/')):
            raise ValueError('Unsafe backup path')
        if name.startswith('/'):
            raise ValueError('Unsafe backup path')
    if file_inventory(bundle) != manifest['files']:
        raise ValueError('Backup file inventory or checksum differs')
    settings_path = manifest['settings']['file']
    if settings_path not in manifest['files'] or not settings_path.startswith('settings/'):
        raise ValueError('Settings file missing')
    audit = database_audit(bundle / 'database.sqlite')
    # JSON roundtrip normalizes tuples without altering any SQLite value.
    if json.loads(json.dumps(audit, ensure_ascii=False)) != manifest['database']:
        raise ValueError('Backup database fields, objects or sequence differ')
    if settings_summary(bundle / settings_path) != manifest['settings']['summary']:
        raise ValueError('Backup settings summary differs')
    return manifest


def snapshot(database, settings, output, attachments=()):
    database = Path(database).resolve(strict=True)
    settings = Path(settings).resolve(strict=True)
    output = external(output)
    if output.exists():
        raise ValueError('Refusing to overwrite an existing backup')
    if (database.parent == output or output in database.parents or output in settings.parents or
            database.parent in output.parents or settings.parent in output.parents):
        raise ValueError('Backup must be separate from source data')
    settings_summary(settings)
    output.parent.mkdir(parents=True, exist_ok=True)
    staged = output.with_name('.backup-' + uuid.uuid4().hex)
    staged.mkdir()
    # SQLite online backup reads a coherent committed image, including WAL.
    # Opening the source read-only cannot checkpoint or rewrite the source.
    with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=10)) as source:
        source.execute('PRAGMA query_only=ON')
        with closing(sqlite3.connect(staged / 'database.sqlite')) as destination:
            source.backup(destination)
    audit = database_audit(staged / 'database.sqlite')
    (staged / 'settings').mkdir()
    shutil.copyfile(settings, staged / 'settings' / settings.name)
    (staged / 'attachments').mkdir()
    names = set()
    for attachment in attachments:
        attachment = Path(attachment).resolve(strict=True)
        if not attachment.is_file() or attachment.name in names:
            raise ValueError('Attachment names collide or are not files')
        names.add(attachment.name)
        shutil.copyfile(attachment, staged / 'attachments' / attachment.name)
    manifest = {'format': 1, 'database': audit,
                'settings': {'file': 'settings/' + settings.name,
                             'summary': settings_summary(staged / 'settings' / settings.name)},
                'files': file_inventory(staged),
                'attachment_policy': 'original evidence only; never replay against snapshot database'}
    write_json(staged / 'manifest.json', manifest)
    verified = verify_bundle(staged)
    staged.rename(output)
    return summary(verified)


def init_root(root):
    root = external(root)
    if root.exists():
        raise ValueError('Isolation initialization requires a new directory')
    root.mkdir(parents=True)
    write_json(root / '.count-tools-isolated.json', MARKER)
    (root / '.recovery.lock').write_bytes(b'0')
    return {'isolated_root_created': True}


def checked_root(root):
    original = Path(root).absolute()
    if unsafe_link(original):
        raise ValueError('Isolation root cannot be a symbolic link')
    root = external(original)
    with (root / '.count-tools-isolated.json').open(encoding='utf-8') as source:
        if json.load(source) != MARKER:
            raise ValueError('Isolation ownership marker differs')
    return root


@contextmanager
def root_lock(root):
    with (root / '.recovery.lock').open('r+b') as lock:
        lock.seek(0)
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            lock.seek(0)
            if os.name == 'nt':
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def recover_locked(root):
    journal = root / 'recovery-transaction.json'
    if not journal.exists():
        return {'recovery': 'no pending transaction'}
    with journal.open(encoding='utf-8') as source:
        transaction = json.load(source)
    for key, prefix in [('incoming', '.incoming-'), ('rollback', '.rollback-')]:
        if not re.fullmatch(re.escape(prefix) + '[0-9a-f]{32}', transaction.get(key, '')):
            raise ValueError('Invalid recovery transaction path; no changes applied')
        if unsafe_link(root / transaction[key]):
            raise ValueError('Unsafe recovery transaction path')
    if transaction.get('phase') not in ('prepared', 'committed') or type(transaction.get('had_current')) is not bool:
        raise ValueError('Invalid recovery transaction state')
    current, rollback = root / 'current', root / transaction['rollback']
    if unsafe_link(current):
        raise ValueError('Unsafe current directory')
    if transaction['phase'] == 'committed':
        verify_bundle(current)
        journal.unlink()
        return {'recovery': 'committed generation retained'}
    if rollback.exists():
        if current.exists():
            current.rename(root / ('.failed-' + uuid.uuid4().hex))
        rollback.rename(current)
        verify_bundle(current)
    elif not transaction['had_current'] and current.exists():
        current.rename(root / ('.failed-' + uuid.uuid4().hex))
    elif transaction['had_current']:
        if not current.exists():
            raise ValueError('Original generation missing; manual inspection required')
        verify_bundle(current)
    journal.unlink()
    return {'recovery': 'original generation restored'}


def recover(root):
    root = checked_root(root)
    with root_lock(root):
        return recover_locked(root)


def preview(bundle, root):
    manifest = verify_bundle(bundle)
    root = checked_root(root)
    with root_lock(root):
        if (root / 'recovery-transaction.json').exists():
            raise ValueError('Pending recovery must be resolved before preview')
        old = verify_bundle(root / 'current') if (root / 'current').exists() else None
        return {'incoming': summary(manifest), 'current': summary(old) if old else None,
                'action': 'replace complete isolated generation; retain previous generation',
                'writes_applied': False}


def restore(bundle, root, _fault=None):
    bundle, root = external(bundle), checked_root(root)
    if bundle == root or root in bundle.parents or bundle in root.parents:
        raise ValueError('Backup and isolation target must be separate')
    with root_lock(root):
        recover_locked(root)
        manifest = verify_bundle(bundle)
        current = root / 'current'
        if current.exists():
            verify_bundle(current)
        incoming = root / ('.incoming-' + uuid.uuid4().hex)
        rollback = root / ('.rollback-' + uuid.uuid4().hex)
        shutil.copytree(bundle, incoming)
        verify_bundle(incoming)
        transaction = {'phase': 'prepared', 'incoming': incoming.name,
                       'rollback': rollback.name, 'had_current': current.exists()}
        write_json(root / 'recovery-transaction.json', transaction)
        try:
            if current.exists():
                current.rename(rollback)
            if _fault:
                _fault('old-moved')
            incoming.rename(current)
            if _fault:
                _fault('new-installed')
            verified = verify_bundle(current)
            if verified != manifest:
                raise ValueError('Installed generation differs')
            transaction['phase'] = 'committed'
            write_json(root / 'recovery-transaction.json', transaction)
            cleanup_pending = False
            try:
                (root / 'recovery-transaction.json').unlink()
            except OSError:
                cleanup_pending = True
            return {'restored': summary(verified), 'previous_generation_retained': transaction['had_current'],
                    'cleanup_pending': cleanup_pending}
        except Exception:
            recover_locked(root)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    create = commands.add_parser('snapshot')
    create.add_argument('--database', required=True)
    create.add_argument('--settings', required=True)
    create.add_argument('--output', required=True)
    create.add_argument('--attachment', action='append', default=[])
    for name in ('init', 'recover'):
        commands.add_parser(name).add_argument('--root', required=True)
    for name in ('verify', 'preview', 'restore'):
        command = commands.add_parser(name)
        command.add_argument('--bundle', required=True)
        if name != 'verify':
            command.add_argument('--root', required=True)
        if name == 'restore':
            command.add_argument('--apply', action='store_true', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'snapshot':
            result = snapshot(args.database, args.settings, args.output, args.attachment)
        elif args.command == 'init':
            result = init_root(args.root)
        elif args.command == 'verify':
            result = summary(verify_bundle(args.bundle))
        elif args.command == 'recover':
            result = recover(args.root)
        elif args.command == 'preview':
            result = preview(args.bundle, args.root)
        else:
            result = restore(args.bundle, args.root)
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, ET.ParseError):
        # Do not echo private database rows, settings or credential values.
        parser.exit(1, 'Recovery operation failed validation or filesystem access; source data retained.\n')


if __name__ == '__main__':
    main()
