"""Cross-runtime recovery of the current Dart CSV transport result; synthetic only."""
import argparse
import importlib.util
import json
import sqlite3
import subprocess
import sys
import zipfile
from contextlib import closing
from pathlib import Path
import recovery

spec = importlib.util.spec_from_file_location('base', Path(__file__).with_name('test-nullable-recovery.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


class TransportRecoveryTests(base.NullableRecoveryTests):
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

    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before = recovery.database_audit(self.database)
        self.assertEqual(before['version'], 8)
        with closing(sqlite3.connect(self.database)) as db:
            self.assertGreater(db.execute('SELECT COUNT(*) FROM cheki_entry_ticket_bindings').fetchone()[0], 0)
            self.assertGreater(db.execute('SELECT COUNT(*) FROM cheki_transfer_objects').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT raw,text_value FROM unknown_future WHERE id=99').fetchone(),
                             (b'\x00\xff', '=原文,\n"001"'))
            self.assertEqual(db.execute("SELECT seq FROM sqlite_sequence WHERE name='unknown_future'").fetchone()[0], 150)
        target = self.root()
        recovery.restore(self.bundle(), target)
        current = target/'current'
        self.assertEqual(recovery.database_audit(current/'database.sqlite'), before)
        self.assertEqual((current/'settings/preferences.json').read_bytes(), self.settings.read_bytes())
        self.assertEqual((current/'attachments/synthetic-attachment').read_bytes(), self.attachment.read_bytes())
        again = self.base/'again'
        recovery.snapshot(current/'database.sqlite', current/'settings/preferences.json', again,
                          [current/'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'], json.loads(json.dumps(before)))
        code = 'import sys;sys.path.insert(0,sys.argv[1]);import recovery;assert recovery.database_audit(sys.argv[2])["version"]==8'
        subprocess.run([sys.executable, '-c', code, str(Path(recovery.__file__).parent),
                        str(current/'database.sqlite')], check=True)

    def test_corrupt_record_type_and_missing_audit_reject(self):
        # Select an actually present nullable record, without rewriting a whole fixture.
        with closing(sqlite3.connect(self.database)) as db, db:
            id_ = db.execute('SELECT id FROM cheki_records LIMIT 1').fetchone()[0]
            db.execute('UPDATE cheki_records SET information_json=? WHERE id=?', ('{"quantity":0}', id_))
        with self.assertRaises(ValueError):
            recovery.database_audit(self.database)

    def test_unknown_does_not_allow_dangling_known_reference(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            id_ = db.execute('SELECT id FROM cheki_records LIMIT 1').fetchone()[0]
            db.execute('UPDATE cheki_records SET information_json=? WHERE id=?',
                       ('{"member_ids":["does-not-exist"]}', id_))
        with self.assertRaises(ValueError):
            recovery.database_audit(self.database)

    def test_standard_zip_reader_and_exact_csv_payload_are_interoperable(self):
        with zipfile.ZipFile(SOURCE/'full.chekicsv.zip') as zipped:
            self.assertIsNone(zipped.testzip())
            manifest = json.loads(zipped.read('manifest.json'))
            self.assertEqual(manifest['mode'], 'snapshot')
            self.assertEqual(manifest['schema'], 8)
            self.assertTrue(all(zipped.read(t['file']) for t in manifest['tables']))
            outer = json.loads(zipped.read('seed.chekibackup'))
            self.assertEqual(outer['format'], 'cheki-full-backup')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    SOURCE = args.source.resolve(strict=True)
    if (SOURCE/'.transport-synthetic').read_text(encoding='utf-8-sig') != 'count_tools':
        raise ValueError('Marked synthetic source required')
    base.SOURCE = SOURCE
    import unittest
    unittest.main(argv=[__file__])
