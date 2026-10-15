"""Independent full recovery of a Dart-generated synthetic legacy migration."""
import argparse
import importlib.util
import json
import sqlite3
import subprocess
import sys
from contextlib import closing
from pathlib import Path
import recovery

spec = importlib.util.spec_from_file_location('base', Path(__file__).with_name('test-nullable-recovery.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


class LegacyMappingRecoveryTests(base.NullableRecoveryTests):
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before = recovery.database_audit(self.database)
        self.assertEqual(before['version'], 8)
        with closing(sqlite3.connect(self.database)) as db:
            rows = [json.loads(r[0]) for r in db.execute('SELECT information_json FROM cheki_records')]
            self.assertEqual(len(rows), 342)
            self.assertEqual({r['legacy_raw']['id'] for r in rows}, set(range(1, 343)))
            blank = next(r for r in rows if r['legacy_raw']['id'] == 1)
            self.assertNotIn('quantity', blank)
            self.assertNotIn('occurred_on', blank)
            self.assertIsNone(blank['legacy_raw']['price'])
            self.assertEqual(blank['legacy_raw']['unknown_value'], {'sqlite_blob_base64': 'AP8='})
            self.assertEqual(sum(r.get('quantity') or 0 for r in rows), 341)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM item_data').fetchone()[0], 342)
            self.assertEqual(db.execute("SELECT seq FROM sqlite_sequence WHERE name='item_data'").fetchone()[0], 1000)
            self.assertEqual(db.execute('SELECT raw,unknown FROM future_values WHERE id=97').fetchone(), (b'\x00\xff\x01', None))
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_ticket_objects').fetchone()[0], 0)
            self.assertTrue(all('receipt_status_hint' not in r for r in rows))
        root = self.root()
        recovery.restore(self.bundle(), root)
        current = root/'current'
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
        with closing(sqlite3.connect(self.database)) as db, db:
            row = db.execute('SELECT id,information_json FROM cheki_records LIMIT 1').fetchone()
            info = json.loads(row[1]); info['quantity'] = 0
            db.execute('UPDATE cheki_records SET information_json=? WHERE id=?', (json.dumps(info), row[0]))
        with self.assertRaises(ValueError):
            recovery.database_audit(self.database)

    def test_unknown_does_not_allow_dangling_known_reference(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            row = db.execute('SELECT id,information_json FROM cheki_records LIMIT 1').fetchone()
            info = json.loads(row[1]); info['member_ids'] = ['missing']
            db.execute('UPDATE cheki_records SET information_json=? WHERE id=?', (json.dumps(info), row[0]))
        with self.assertRaises(ValueError):
            recovery.database_audit(self.database)

    def test_future_schema_and_missing_record_table_refuse(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('PRAGMA user_version=9')
        with self.assertRaises(ValueError):
            recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('PRAGMA user_version=8'); db.execute('DROP TABLE cheki_records')
        with self.assertRaises((ValueError, sqlite3.Error)):
            recovery.database_audit(self.database)

    def test_difference_report_retains_all_sources_and_never_creates_inventory(self):
        report = json.loads((SOURCE/'mapping-report.json').read_text(encoding='utf8'))
        self.assertEqual(report['added'], 342)
        self.assertEqual(len(report['changes']), 342)
        self.assertEqual(report['inventory_and_purchase_changes'], 0)
        self.assertTrue(report['originals_preserved'])
        self.assertEqual(report['already_mapped'], 0)
        self.assertTrue(all(r['before'] is None for r in report['changes']))
        self.assertEqual({r['original']['id'] for r in report['changes']}, set(range(1, 343)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    SOURCE = args.source.resolve(strict=True)
    if (SOURCE/'.legacy-synthetic').read_text(encoding='utf-8-sig') != 'count_tools':
        raise ValueError('Marked synthetic source required')
    base.SOURCE = SOURCE
    import unittest
    unittest.main(argv=[__file__])
