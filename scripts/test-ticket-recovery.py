"""Schema6 complete recovery and corrupted allocation/audit rejection, synthetic only."""
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
spec=importlib.util.spec_from_file_location('base',Path(__file__).with_name('test-nullable-recovery.py'));base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
class TicketRecoveryTests(base.NullableRecoveryTests):
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before=recovery.database_audit(self.database);self.assertEqual(before['version'],6)
        with closing(sqlite3.connect(self.database)) as db:
            info=[json.loads(r[0]) for r in db.execute('SELECT information_json FROM cheki_ticket_objects')];self.assertIn({},info)
            self.assertIn('30',[i.get('unit_price') for i in info]);self.assertIn('20',[i.get('unit_price') for i in info])
            self.assertTrue(any(i.get('ext')=={'缺键':[None,'原文']} for i in info))
            allocation=json.loads(db.execute("SELECT allocations_json FROM cheki_ticket_objects WHERE posted=1 AND kind='adjustment'").fetchone()[0]);self.assertEqual(allocation[0]['cost'],'30')
        root=self.root();recovery.restore(self.bundle(),root);current=root/'current'
        self.assertEqual(recovery.database_audit(current/'database.sqlite'),before)
        self.assertEqual((current/'settings/preferences.json').read_bytes(),self.settings.read_bytes());self.assertEqual((current/'attachments/synthetic-attachment').read_bytes(),self.attachment.read_bytes())
        again=self.base/'again';recovery.snapshot(current/'database.sqlite',current/'settings/preferences.json',again,[current/'attachments/synthetic-attachment']);self.assertEqual(recovery.verify_bundle(again)['database'],json.loads(json.dumps(before)))
        code='import sys;sys.path.insert(0,sys.argv[1]);import recovery;assert recovery.database_audit(sys.argv[2])["version"]==6'
        subprocess.run([sys.executable,'-c',code,str(Path(recovery.__file__).parent),str(current/'database.sqlite')],check=True)
    def test_future_schema_and_missing_record_table_refuse(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('PRAGMA user_version=7')
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('PRAGMA user_version=6');db.execute('DROP TABLE cheki_ticket_operations')
        with self.assertRaises((ValueError,sqlite3.Error)):recovery.database_audit(self.database)
    def test_corrupt_allocation_or_missing_ticket_history_reject_without_target(self):
        with closing(sqlite3.connect(self.database)) as db,db:
            db.execute("UPDATE cheki_ticket_objects SET allocations_json='[]' WHERE posted=1 AND kind='adjustment'")
        target=self.base/'bundle';original=self.database.read_bytes()
        with self.assertRaises(ValueError):recovery.snapshot(self.database,self.settings,target,[self.attachment])
        self.assertEqual(self.database.read_bytes(),original);self.assertFalse(target.exists())
    def test_missing_ticket_audit_reject(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('DELETE FROM cheki_ticket_history WHERE id=(SELECT MIN(id) FROM cheki_ticket_history)')
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);a=p.parse_args();source=a.source.resolve(strict=True)
    marker=json.loads((source/'.ticket-acceptance.json').read_text(encoding='utf-8-sig'))
    if marker!={'project':'count_tools','purpose':'ticket-synthetic'}:raise ValueError('Synthetic source required')
    base.SOURCE=source;unittest.main(argv=[__file__])
