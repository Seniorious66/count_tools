"""Actual schema7 compound-entry recovery; only marked synthetic sources."""
import argparse
import importlib.util
import json
import sqlite3
import subprocess
import sys
import unittest
from contextlib import closing
from pathlib import Path
import recovery

spec = importlib.util.spec_from_file_location('base', Path(__file__).with_name('test-nullable-recovery.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

class EntryRecoveryTests(base.NullableRecoveryTests):
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before = recovery.database_audit(self.database)
        self.assertEqual(before['version'], 7)
        with closing(sqlite3.connect(self.database)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_entry_states').fetchone()[0], 4)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_entry_operations').fetchone()[0], 5)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_entry_ticket_bindings').fetchone()[0], 4)
            self.assertIn('{}', [r[0] for r in db.execute('SELECT information_json FROM cheki_records')])
            self.assertTrue(any(json.loads(r[0]).get('legacy_raw', {}).get('ext', 'missing') is None for r in db.execute('SELECT information_json FROM cheki_records')))
        root = self.root()
        recovery.restore(self.bundle(), root)
        current = root/'current'
        self.assertEqual(recovery.database_audit(current/'database.sqlite'), before)
        self.assertEqual((current/'settings/preferences.json').read_bytes(), self.settings.read_bytes())
        self.assertEqual((current/'attachments/synthetic-attachment').read_bytes(), self.attachment.read_bytes())
        again = self.base/'again'
        recovery.snapshot(current/'database.sqlite', current/'settings/preferences.json', again, [current/'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'], json.loads(json.dumps(before)))
        code = 'import sys;sys.path.insert(0,sys.argv[1]);import recovery;assert recovery.database_audit(sys.argv[2])["version"]==7'
        subprocess.run([sys.executable, '-c', code, str(Path(recovery.__file__).parent), str(current/'database.sqlite')], check=True)

    def test_future_schema_and_missing_record_table_refuse(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('PRAGMA user_version=8')
        with self.assertRaises(ValueError): recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('PRAGMA user_version=7')
            db.execute('DROP TABLE cheki_entry_states')
        with self.assertRaises((ValueError, sqlite3.Error)): recovery.database_audit(self.database)

    def test_corrupt_record_type_and_missing_audit_reject(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("UPDATE cheki_records SET information_json=? WHERE information_json='{}'", (json.dumps({'quantity': 0}),))
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

    def test_unknown_does_not_allow_dangling_known_reference(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('DELETE FROM cheki_entry_ticket_bindings WHERE ticket_id=(SELECT MIN(ticket_id) FROM cheki_entry_ticket_bindings)')
        target = self.base/'invalid-bundle'
        original = self.database.read_bytes()
        with self.assertRaises(ValueError): recovery.snapshot(self.database, self.settings, target, [self.attachment])
        self.assertFalse(target.exists())
        self.assertEqual(self.database.read_bytes(), original)

    def test_current_revision_or_compound_audit_corruption_reject(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('UPDATE cheki_entry_states SET record_revision=record_revision+1')
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

    def test_missing_compound_operation_refuses(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('DELETE FROM cheki_entry_operations WHERE seq=(SELECT MIN(seq) FROM cheki_entry_operations)')
        with self.assertRaises(ValueError): recovery.database_audit(self.database)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if json.loads((source/'.entry-acceptance.json').read_text(encoding='utf-8-sig')) != {'project': 'count_tools', 'purpose': 'entry-synthetic'}:
        raise ValueError('Marked synthetic source required')
    base.SOURCE = source
    unittest.main(argv=[__file__])
