"""Full schema8 restore and group-correction audit checks on a marked synthetic fixture."""
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


class DailyRecoveryTests(base.NullableRecoveryTests):
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before = recovery.database_audit(self.database)
        self.assertEqual(before['version'], 8)
        with closing(sqlite3.connect(self.database)) as db:
            corrections = [json.loads(r[0]) for r in db.execute('SELECT request_json FROM cheki_identity_operations') if 'group_correction' in json.loads(r[0])]
            self.assertEqual(len(corrections), 3)
            self.assertTrue(all(r['group_correction'] is True for r in corrections))
            self.assertIn(None, [r['fields']['group_id'] for r in corrections])
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_entry_ticket_bindings').fetchone()[0], 1)
            self.assertIn('{}', [r[0] for r in db.execute('SELECT information_json FROM cheki_records')])
        target = self.root()
        recovery.restore(self.bundle(), target)
        current = target / 'current'
        self.assertEqual(recovery.database_audit(current / 'database.sqlite'), before)
        self.assertEqual((current / 'settings/preferences.json').read_bytes(), self.settings.read_bytes())
        self.assertEqual((current / 'attachments/synthetic-attachment').read_bytes(), self.attachment.read_bytes())
        again = self.base / 'again'
        recovery.snapshot(current / 'database.sqlite', current / 'settings/preferences.json', again, [current / 'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'], json.loads(json.dumps(before)))
        code = 'import sys;sys.path.insert(0,sys.argv[1]);import recovery;assert recovery.database_audit(sys.argv[2])["version"]==8'
        subprocess.run([sys.executable, '-c', code, str(Path(recovery.__file__).parent), str(current / 'database.sqlite')], check=True)

    def test_future_schema_and_missing_record_table_refuse(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('PRAGMA user_version=9')
        with self.assertRaises(ValueError):
            recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('PRAGMA user_version=8')
            db.execute('DROP TABLE cheki_records')
        with self.assertRaises((ValueError, sqlite3.Error)):
            recovery.database_audit(self.database)

    def corrupt_correction(self, value=None, remove=False):
        with closing(sqlite3.connect(self.database)) as db, db:
            for id_, text in db.execute('SELECT id,request_json FROM cheki_identity_operations'):
                request = json.loads(text)
                if request.get('group_correction') is True:
                    if remove:
                        request.pop('group_correction')
                    else:
                        request['group_correction'] = value
                    db.execute('UPDATE cheki_identity_operations SET request_json=? WHERE id=?', (json.dumps(request), id_))
                    return
        self.fail('Correction fixture missing')

    def test_unmarked_known_group_edit_rejected(self):
        self.corrupt_correction(remove=True)
        with self.assertRaises(ValueError):
            recovery.database_audit(self.database)

    def test_false_or_numeric_correction_flag_rejected(self):
        self.corrupt_correction(1)
        with self.assertRaises(ValueError):
            recovery.database_audit(self.database)

    def test_damaged_correction_does_not_replace_current_generation(self):
        target = self.root()
        recovery.restore(self.bundle(), target)
        current = target / 'current/database.sqlite'
        before = recovery.database_audit(current)
        self.corrupt_correction(False)
        with self.assertRaises(ValueError):
            recovery.snapshot(self.database, self.settings, self.base / 'damaged', [self.attachment])
        self.assertEqual(recovery.database_audit(current), before)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if json.loads((source / '.daily-acceptance.json').read_text(encoding='utf-8-sig')) != {'project': 'count_tools', 'purpose': 'daily-fix-synthetic'}:
        raise ValueError('Marked synthetic source required')
    base.SOURCE = source
    unittest.main(argv=[__file__])
