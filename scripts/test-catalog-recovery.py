"""Validate complete recovery against an actual Dart-produced synthetic schema 3."""
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


class CatalogRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='cheki-catalog-recovery-')
        self.base = Path(self.temporary.name)
        source = self.base / 'source'
        source.mkdir()
        for name in ('database.sqlite', 'preferences.json', 'synthetic-attachment'):
            shutil.copy2(SOURCE / name, source / name)
        self.database = source / 'database.sqlite'
        self.settings = source / 'preferences.json'
        self.attachment = source / 'synthetic-attachment'

    def tearDown(self):
        self.temporary.cleanup()

    def root(self):
        root = self.base / 'isolated'
        recovery.init_root(root)
        return root

    def snapshot(self, name='bundle'):
        bundle = self.base / name
        recovery.snapshot(self.database, self.settings, bundle, [self.attachment])
        return bundle

    def test_application_catalog_and_full_unknown_fields_roundtrip_cold(self):
        before = recovery.database_audit(self.database)
        self.assertEqual(before['version'], 3)
        self.assertEqual(before['tables']['cheki_groups']['count'], 1)
        self.assertEqual(before['tables']['cheki_sizes']['count'], 3)
        self.assertEqual(before['tables']['cheki_catalog_operations']['count'], 5)
        self.assertEqual(before['tables']['cheki_catalog_history']['count'], 5)
        root = self.root()
        recovery.restore(self.snapshot(), root)
        current = root / 'current'
        self.assertEqual(recovery.database_audit(current / 'database.sqlite'), before)
        self.assertEqual((current / 'settings/preferences.json').read_bytes(), self.settings.read_bytes())
        self.assertEqual((current / 'attachments/synthetic-attachment').read_bytes(), self.attachment.read_bytes())
        with closing(sqlite3.connect(current / 'database.sqlite')) as db:
            self.assertEqual(db.execute('SELECT unknown_blob FROM cheki_sizes WHERE id=?', ('size-3inch',)).fetchone()[0], b'\x00\xff')
            self.assertIsNone(db.execute('SELECT price FROM item_data WHERE id=91').fetchone()[0])
            self.assertEqual(db.execute("SELECT seq FROM sqlite_sequence WHERE name='item_data'").fetchone()[0], 1000)
        cold = subprocess.run([sys.executable, str(Path(recovery.__file__)), 'verify', '--bundle', str(current)], capture_output=True, text=True)
        self.assertEqual(cold.returncode, 0, cold.stderr)
        again = self.base / 'again'
        recovery.snapshot(current / 'database.sqlite', current / 'settings/preferences.json', again, [current / 'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'], recovery.verify_bundle(current)['database'])

    def test_forged_request_rejected_readonly(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            op, text = db.execute('SELECT id,request_json FROM cheki_catalog_operations LIMIT 1').fetchone()
            request = json.loads(text)
            request['name'] = 'forged'
            db.execute('UPDATE cheki_catalog_operations SET request_json=? WHERE id=?', (json.dumps(request), op))
        before = self.database.read_bytes()
        with self.assertRaises(ValueError): self.snapshot()
        self.assertEqual(self.database.read_bytes(), before)
        self.assertFalse((self.base / 'bundle').exists())

    def test_missing_history_or_broken_operation_reference_rejected(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('DELETE FROM cheki_catalog_history WHERE id=(SELECT MIN(id) FROM cheki_catalog_history)')
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

    def test_blob_loss_even_with_matching_current_result_and_history_rejected(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            op, text = db.execute("SELECT operation_id,after_json FROM cheki_catalog_history WHERE entity_id='size-3inch'").fetchone()
            after = json.loads(text)
            after['unknown_blob'] = None
            text = json.dumps(after)
            db.execute('UPDATE cheki_catalog_history SET after_json=? WHERE operation_id=?', (text, op))
            db.execute('UPDATE cheki_catalog_operations SET result_json=? WHERE id=?', (text, op))
            db.execute("UPDATE cheki_sizes SET unknown_blob=NULL WHERE id='size-3inch'")
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

    def test_default_identity_missing_refused(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("DELETE FROM cheki_sizes WHERE id='size-5inch'")
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

    def test_all_tables_and_settings_rollback_after_filesystem_failure(self):
        root = self.root()
        recovery.restore(self.snapshot(), root)
        before = recovery.database_audit(root / 'current/database.sqlite')
        settings = (root / 'current/settings/preferences.json').read_bytes()
        self.settings.write_text('{"changed":true}', encoding='utf-8')
        replacement = self.snapshot('replacement')
        for stage in ('old-moved', 'new-installed'):
            def fault(actual):
                if actual == stage: raise OSError('injected')
            with self.assertRaises(OSError): recovery.restore(replacement, root, _fault=fault)
            self.assertEqual(recovery.database_audit(root / 'current/database.sqlite'), before)
            self.assertEqual((root / 'current/settings/preferences.json').read_bytes(), settings)

    def test_old_format1_still_restores_after_schema3(self):
        spec = importlib.util.spec_from_file_location('legacy_recovery_tests', Path(__file__).with_name('test-recovery.py'))
        old = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(old)
        database, settings, attachment = old.fixture(self.base / 'legacy')
        legacy_bundle = self.base / 'legacy-bundle'
        recovery.snapshot(database, settings, legacy_bundle, [attachment])
        root = self.root()
        recovery.restore(self.snapshot(), root)
        recovery.restore(legacy_bundle, root)
        self.assertEqual(recovery.database_audit(root / 'current/database.sqlite'), recovery.database_audit(database))

    def test_future_version_and_malformed_audit_refused(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('PRAGMA user_version=4')
        with self.assertRaises(ValueError): recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('PRAGMA user_version=3')
            db.execute("UPDATE cheki_catalog_operations SET result_json='[]'")
        with self.assertRaises(ValueError): recovery.database_audit(self.database)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True)
    args, rest = parser.parse_known_args()
    SOURCE = recovery.external(args.source)
    marker = json.loads((SOURCE / '.catalog-acceptance.json').read_text(encoding='utf-8'))
    if marker != {'project': 'count_tools', 'purpose': 'm1-synthetic-catalog'}:
        parser.error('Required synthetic catalog marker missing')
    unittest.main(argv=[sys.argv[0], *rest])
