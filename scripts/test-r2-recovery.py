"""R2 recorded action stamps and confirmed legacy amounts survive isolated full recovery."""
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
from ticket_validation import info

spec=importlib.util.spec_from_file_location('base',Path(__file__).with_name('test-nullable-recovery.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
class R2RecoveryTests(base.NullableRecoveryTests):
    def test_future_schema_and_missing_record_table_refuse(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('PRAGMA user_version=9')
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db,db:
            db.execute('PRAGMA user_version=8');db.execute('DROP TABLE cheki_records')
        with self.assertRaises((ValueError,sqlite3.Error)):recovery.database_audit(self.database)
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before=recovery.database_audit(self.database)
        self.assertEqual(before['version'],8)
        with closing(sqlite3.connect(self.database)) as db:
            tickets=[json.loads(r[0]) for r in db.execute('SELECT information_json FROM cheki_ticket_objects')]
            entered=[t for t in tickets if t.get('recorded_at')]
            self.assertEqual(len(entered),1)
            self.assertEqual(entered[0]['recorded_at'],'2026-10-14T01:00:00.000Z')
            self.assertEqual(entered[0]['total_price'],'160')
            self.assertNotIn('expires_on',entered[0])
            self.assertNotIn('unit_price',entered[0])
            records=[json.loads(r[0]) for r in db.execute('SELECT information_json FROM cheki_records')]
            self.assertIn({},records)
            self.assertEqual([v['legacy_raw']['price'] for v in records if 'legacy_raw' in v],['100'])
        target=self.root();recovery.restore(self.bundle(),target)
        current=target/'current'
        self.assertEqual(recovery.database_audit(current/'database.sqlite'),before)
        self.assertEqual((current/'settings/preferences.json').read_bytes(),self.settings.read_bytes())
        self.assertEqual((current/'attachments/synthetic-attachment').read_bytes(),self.attachment.read_bytes())
        again=self.base/'again';recovery.snapshot(current/'database.sqlite',current/'settings/preferences.json',again,[current/'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'],json.loads(json.dumps(before)))
        code='import sys;sys.path.insert(0,sys.argv[1]);import recovery;assert recovery.database_audit(sys.argv[2])["version"]==8'
        subprocess.run([sys.executable,'-c',code,str(Path(recovery.__file__).parent),str(current/'database.sqlite')],check=True)
    def test_optional_recorded_action_stamp_validation(self):
        for value in ('2026-10-14','not-a-stamp',0,False):
            with self.assertRaises(ValueError):info(json.dumps({'recorded_at':value}))
        for value in (None,'2026-10-14T01:00:00.000Z'):
            self.assertEqual(info(json.dumps({'recorded_at':value}))['recorded_at'],value)
    def test_damaged_recorded_stamp_cannot_replace_verified_current(self):
        target=self.root();recovery.restore(self.bundle(),target)
        original=recovery.database_audit(target/'current/database.sqlite')
        with closing(sqlite3.connect(self.database)) as db,db:
            for id_,text in db.execute('SELECT id,information_json FROM cheki_ticket_objects'):
                v=json.loads(text)
                if 'recorded_at' in v:
                    v['recorded_at']='invalid'
                    db.execute('UPDATE cheki_ticket_objects SET information_json=? WHERE id=?',(json.dumps(v),id_));break
        with self.assertRaises(ValueError):recovery.snapshot(self.database,self.settings,self.base/'invalid',[self.attachment])
        self.assertEqual(recovery.database_audit(target/'current/database.sqlite'),original)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,required=True);args=parser.parse_args()
    source=args.source.resolve(strict=True)
    if json.loads((source/'.r2-acceptance.json').read_text(encoding='utf-8-sig'))!={'project':'count_tools','purpose':'r2-synthetic'}:raise ValueError('Marked synthetic source required')
    base.SOURCE=source
    unittest.main(argv=[__file__])
