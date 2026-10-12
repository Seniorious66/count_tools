"""Cross-runtime complete recovery of an actual Dart-generated identity model."""
import argparse
import importlib.util
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
import recovery

SOURCE = None


class IdentityRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cheki-identity-recovery-')
        self.base = Path(self.temp.name)
        source = self.base / 'source'
        source.mkdir()
        for name in ('database.sqlite', 'preferences.json', 'synthetic-attachment'):
            shutil.copy2(SOURCE / name, source / name)
        self.database, self.settings, self.attachment = (source / name for name in ('database.sqlite', 'preferences.json', 'synthetic-attachment'))

    def tearDown(self): self.temp.cleanup()

    def snapshot(self, name='bundle'):
        target = self.base / name
        recovery.snapshot(self.database, self.settings, target, [self.attachment])
        return target

    def root(self):
        root = self.base / 'isolated'
        recovery.init_root(root)
        return root

    def test_full_identity_fields_settings_attachment_rebackup_and_new_process(self):
        before = recovery.database_audit(self.database)
        self.assertIn(before['version'], (4, 5))
        for table, count in [('cheki_persons', 1), ('cheki_members', 3), ('cheki_identity_operations', 6), ('cheki_identity_history', 6)]:
            self.assertEqual(before['tables'][table]['count'], count)
        root = self.root()
        bundle = self.snapshot()
        recovery.restore(bundle, root)
        current = root / 'current'
        self.assertEqual(recovery.database_audit(current / 'database.sqlite'), before)
        self.assertEqual((current / 'settings/preferences.json').read_bytes(), self.settings.read_bytes())
        self.assertEqual((current / 'attachments/synthetic-attachment').read_bytes(), self.attachment.read_bytes())
        with closing(sqlite3.connect(current / 'database.sqlite')) as db:
            self.assertEqual(db.execute('SELECT unknown_blob FROM cheki_members').fetchall(), [(b'\x00\xff',)] * 3)
            self.assertIsNone(db.execute('SELECT future_null FROM cheki_persons').fetchone()[0])
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_members WHERE active=0').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT COUNT(DISTINCT group_id) FROM cheki_members WHERE person_id IS NOT NULL').fetchone()[0], 2)
        cold = subprocess.run([sys.executable, recovery.__file__, 'verify', '--bundle', str(current)], capture_output=True, text=True)
        self.assertEqual(cold.returncode, 0, cold.stderr)
        again = self.base / 'again'
        recovery.snapshot(current / 'database.sqlite', current / 'settings/preferences.json', again, [current / 'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'], recovery.verify_bundle(current)['database'])

    def test_request_history_corruption_rejects_readonly_without_snapshot(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("UPDATE cheki_identity_operations SET request_json='{}'")
        before = self.database.read_bytes()
        with self.assertRaises(ValueError): self.snapshot()
        self.assertEqual(self.database.read_bytes(), before)
        self.assertFalse((self.base / 'bundle').exists())

    def test_history_gap_or_missing_reference_rejects(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('DELETE FROM cheki_identity_history WHERE id=(SELECT MIN(id) FROM cheki_identity_history WHERE kind=\'member\')')
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

    def test_lost_unknown_blob_even_with_matching_latest_result_and_current_rejects(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            entity_id, op_id, text = db.execute("SELECT entity_id,operation_id,after_json FROM cheki_identity_history WHERE json_extract(after_json,'$.revision')=3").fetchone()
            after = json.loads(text)
            after['unknown_blob'] = None
            text = json.dumps(after)
            db.execute('UPDATE cheki_members SET unknown_blob=NULL WHERE id=?', (entity_id,))
            db.execute('UPDATE cheki_identity_history SET after_json=? WHERE operation_id=?', (text, op_id))
            db.execute('UPDATE cheki_identity_operations SET result_json=? WHERE id=?', (text, op_id))
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

    def test_operation_namespace_collision_rejects(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            old = db.execute("SELECT id FROM cheki_identity_operations WHERE kind='person'").fetchone()[0]
            catalog = db.execute('SELECT id FROM cheki_catalog_operations LIMIT 1').fetchone()[0]
            db.execute('UPDATE cheki_identity_operations SET id=? WHERE id=?', (catalog, old))
            db.execute('UPDATE cheki_identity_history SET operation_id=? WHERE operation_id=?', (catalog, old))
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

    def test_filesystem_failure_and_actual_process_exit_restore_all_current_objects(self):
        root = self.root()
        recovery.restore(self.snapshot(), root)
        old = recovery.database_audit(root / 'current/database.sqlite')
        settings = (root / 'current/settings/preferences.json').read_bytes()
        self.settings.write_text('{"synthetic_replacement":true}', encoding='utf-8')
        replacement = self.snapshot('replacement')
        for phase in ('old-moved', 'new-installed'):
            def fault(actual):
                if actual == phase: raise OSError('synthetic fault')
            with self.assertRaises(OSError): recovery.restore(replacement, root, _fault=fault)
            self.assertEqual(recovery.database_audit(root / 'current/database.sqlite'), old)
            self.assertEqual((root / 'current/settings/preferences.json').read_bytes(), settings)
        program = f"import os,recovery; recovery.restore({str(replacement)!r},{str(root)!r},_fault=lambda phase: os._exit(29) if phase=='new-installed' else None)"
        crashed = subprocess.run([sys.executable, '-c', program], cwd=Path(recovery.__file__).parent, capture_output=True)
        self.assertEqual(crashed.returncode, 29)
        fresh = subprocess.run([sys.executable, recovery.__file__, 'recover', '--root', str(root)], capture_output=True, text=True)
        self.assertEqual(fresh.returncode, 0, fresh.stderr)
        self.assertEqual(recovery.database_audit(root / 'current/database.sqlite'), old)
        self.assertEqual((root / 'current/settings/preferences.json').read_bytes(), settings)

    def test_original_format_one_legacy_still_restores_after_schema_four(self):
        spec = importlib.util.spec_from_file_location('old_recovery', Path(__file__).with_name('test-recovery.py'))
        old = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(old)
        database, settings, attachment = old.fixture(self.base / 'legacy')
        bundle = self.base / 'legacy-bundle'
        recovery.snapshot(database, settings, bundle, [attachment])
        root = self.root()
        recovery.restore(self.snapshot(), root)
        recovery.restore(bundle, root)
        self.assertEqual(recovery.database_audit(root / 'current/database.sqlite'), recovery.database_audit(database))

    def test_missing_identity_table_and_future_version_refused(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            version = db.execute('PRAGMA user_version').fetchone()[0]
            db.execute('PRAGMA user_version=6')
        with self.assertRaises(ValueError): recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute(f'PRAGMA user_version={version}')
            db.execute('DROP TABLE cheki_identity_history')
        with self.assertRaises(ValueError): recovery.database_audit(self.database)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    args, rest = parser.parse_known_args()
    SOURCE = recovery.external(args.source)
    if json.loads((SOURCE / '.identity-acceptance.json').read_text(encoding='utf-8')) != {'project': 'count_tools', 'purpose': 'm1-synthetic-identity'}:
        parser.error('Required synthetic identity marker missing')
    unittest.main(argv=[sys.argv[0], *rest])
