"""Schema8 recovery on marked actual Dart synthetic data only."""
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

spec=importlib.util.spec_from_file_location('base',Path(__file__).with_name('test-nullable-recovery.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
class TransferRecoveryTests(base.NullableRecoveryTests):
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before=recovery.database_audit(self.database);self.assertEqual(before['version'],8)
        with closing(sqlite3.connect(self.database)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_transfer_objects').fetchone()[0],5)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_entry_operations').fetchone()[0],1)
            self.assertIn('{}',[r[0] for r in db.execute('SELECT information_json FROM cheki_records')])
            self.assertIn('10/3',[r[0] for r in db.execute('SELECT unit_cost FROM cheki_transfer_lots')])
            self.assertIn(None,[r[0] for r in db.execute('SELECT unit_cost FROM cheki_transfer_lots')])
            self.assertEqual(db.execute("SELECT seq FROM sqlite_sequence WHERE name='item_data'").fetchone()[0],1000)
        root=self.root();recovery.restore(self.bundle(),root);current=root/'current'
        self.assertEqual(recovery.database_audit(current/'database.sqlite'),before)
        self.assertEqual((current/'settings/preferences.json').read_bytes(),self.settings.read_bytes())
        self.assertEqual((current/'attachments/synthetic-attachment').read_bytes(),self.attachment.read_bytes())
        again=self.base/'again';recovery.snapshot(current/'database.sqlite',current/'settings/preferences.json',again,[current/'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'],json.loads(json.dumps(before)))
        code='import sys;sys.path.insert(0,sys.argv[1]);import recovery;assert recovery.database_audit(sys.argv[2])["version"]==8'
        subprocess.run([sys.executable,'-c',code,str(Path(recovery.__file__).parent),str(current/'database.sqlite')],check=True)
    def test_future_schema_and_missing_record_table_refuse(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('PRAGMA user_version=9')
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('PRAGMA user_version=8');db.execute('DROP TABLE cheki_transfer_lots')
        with self.assertRaises((ValueError,sqlite3.Error)):recovery.database_audit(self.database)
    def test_inherited_unit_or_unknown_cost_corruption_refuses(self):
        with closing(sqlite3.connect(self.database)) as db,db:
            db.execute("UPDATE cheki_transfer_lots SET unit_cost='0',source_unit_cost='0' WHERE unit_cost IS NULL")
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
    def test_transfer_child_binding_or_current_state_corruption_refuses(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('DELETE FROM cheki_transfer_bindings WHERE ticket_id=(SELECT MIN(ticket_id) FROM cheki_transfer_bindings)')
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
    def test_missing_transfer_original_operations_refuses(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('DELETE FROM cheki_transfer_operations WHERE seq=(SELECT MIN(seq) FROM cheki_transfer_operations)')
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
    def test_transfer_original_cost_snapshot_corruption_refuses(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute("UPDATE cheki_transfer_lots SET source_json='{}' WHERE ticket_id=(SELECT MIN(ticket_id) FROM cheki_transfer_lots)")
        with self.assertRaises((ValueError,KeyError)):recovery.database_audit(self.database)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,required=True);args=parser.parse_args();source=args.source.resolve(strict=True)
    if json.loads((source/'.transfer-acceptance.json').read_text(encoding='utf-8-sig'))!={'project':'count_tools','purpose':'transfer-synthetic'}:raise ValueError('Marked synthetic source required')
    base.SOURCE=source;unittest.main(argv=[__file__])
