"""Full current-schema transport of actual Dart blank and completed records."""
import argparse
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

SOURCE=None
class NullableRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='cheki-nullable-recovery-');self.base=Path(self.temp.name)
        source=self.base/'source';source.mkdir()
        for name in ('database.sqlite','preferences.json','synthetic-attachment'):shutil.copy2(SOURCE/name,source/name)
        self.database=source/'database.sqlite';self.settings=source/'preferences.json';self.attachment=source/'synthetic-attachment'
    def tearDown(self):self.temp.cleanup()
    def bundle(self,name='bundle'):
        target=self.base/name;recovery.snapshot(self.database,self.settings,target,[self.attachment]);return target
    def root(self):
        target=self.base/'isolated';recovery.init_root(target);return target
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before=recovery.database_audit(self.database);self.assertEqual(before['version'],5)
        with closing(sqlite3.connect(self.database)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_records').fetchone()[0],2)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM cheki_members WHERE name IS NULL AND group_id IS NULL AND color_rgb IS NULL').fetchone()[0],1)
            info=[json.loads(r[0]) for r in db.execute('SELECT information_json FROM cheki_records')]
            self.assertIn({},info);self.assertEqual([i['legacy_raw']['date'] for i in info if 'legacy_raw' in i],['2024-01-02 13:14:15'])
        root=self.root();recovery.restore(self.bundle(),root)
        current=root/'current';self.assertEqual(recovery.database_audit(current/'database.sqlite'),before)
        self.assertEqual((current/'settings/preferences.json').read_bytes(),self.settings.read_bytes())
        self.assertEqual((current/'attachments/synthetic-attachment').read_bytes(),self.attachment.read_bytes())
        again=self.base/'again';recovery.snapshot(current/'database.sqlite',current/'settings/preferences.json',again,[current/'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'],json.loads(json.dumps(before)))
        code='import sys;sys.path.insert(0,sys.argv[1]);import recovery;assert recovery.database_audit(sys.argv[2])["version"]==5'
        subprocess.run([sys.executable,'-c',code,str(Path(recovery.__file__).parent),str(current/'database.sqlite')],check=True)
    def test_corrupt_record_type_and_missing_audit_reject(self):
        with closing(sqlite3.connect(self.database)) as db,db:
            db.execute("UPDATE cheki_records SET information_json=? WHERE information_json='{}'",(json.dumps({'quantity':0}),))
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
    def test_missing_history_refuses_snapshot_before_target_changes(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('DELETE FROM cheki_record_history WHERE id=(SELECT MIN(id) FROM cheki_record_history)')
        target=self.base/'bundle'
        with self.assertRaises(ValueError):recovery.snapshot(self.database,self.settings,target,[self.attachment])
        self.assertFalse(target.exists())
    def test_operation_collision_refuses(self):
        with closing(sqlite3.connect(self.database)) as db,db:
            old=db.execute('SELECT id FROM cheki_record_operations LIMIT 1').fetchone()[0];other=db.execute('SELECT id FROM cheki_catalog_operations LIMIT 1').fetchone()[0]
            db.execute('UPDATE cheki_record_operations SET id=? WHERE id=?',(other,old));db.execute('UPDATE cheki_record_history SET operation_id=? WHERE operation_id=?',(other,old))
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
    def test_unknown_does_not_allow_dangling_known_reference(self):
        with closing(sqlite3.connect(self.database)) as db,db:
            info=json.dumps({'member_ids':['does-not-exist']})
            r=db.execute("SELECT * FROM cheki_records WHERE information_json='{}'").fetchone();keys=[x[1] for x in db.execute('PRAGMA table_info(cheki_records)')];after=dict(zip(keys,r));after['information_json']=info;text=json.dumps(after)
            op=db.execute('SELECT id,request_json FROM cheki_record_operations WHERE record_id=?',(after['id'],)).fetchone();request=json.loads(op[1]);request['information_json']=info
            db.execute('UPDATE cheki_records SET information_json=? WHERE id=?',(info,after['id']));db.execute('UPDATE cheki_record_history SET after_json=? WHERE record_id=?',(text,after['id']));db.execute('UPDATE cheki_record_operations SET request_json=?,result_json=? WHERE id=?',(json.dumps(request),text,op[0]))
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
    def test_current_filesystem_fault_and_real_process_exit_recover_original_generation(self):
        root=self.root();recovery.restore(self.bundle(),root);old=recovery.database_audit(root/'current/database.sqlite');settings=(root/'current/settings/preferences.json').read_bytes()
        self.settings.write_text('{"replacement":true}',encoding='utf-8');replacement=self.bundle('replacement')
        for phase in ('old-moved','new-installed'):
            def fault(actual):
                if actual==phase:raise OSError('synthetic interruption')
            with self.assertRaises(OSError):recovery.restore(replacement,root,_fault=fault)
            self.assertEqual(recovery.database_audit(root/'current/database.sqlite'),old);self.assertEqual((root/'current/settings/preferences.json').read_bytes(),settings)
        code='import sys,os;sys.path.insert(0,sys.argv[1]);import recovery;recovery.restore(sys.argv[2],sys.argv[3],_fault=lambda s: os._exit(29) if s=="new-installed" else None)'
        result=subprocess.run([sys.executable,'-c',code,str(Path(recovery.__file__).parent),str(replacement),str(root)])
        self.assertEqual(result.returncode,29)
        code='import sys;sys.path.insert(0,sys.argv[1]);import recovery;recovery.recover(__import__("pathlib").Path(sys.argv[2]))'
        subprocess.run([sys.executable,'-c',code,str(Path(recovery.__file__).parent),str(root)],check=True)
        self.assertEqual(recovery.database_audit(root/'current/database.sqlite'),old);self.assertEqual((root/'current/settings/preferences.json').read_bytes(),settings)
    def test_future_schema_and_missing_record_table_refuse(self):
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('PRAGMA user_version=6')
        with self.assertRaises(ValueError):recovery.database_audit(self.database)
        with closing(sqlite3.connect(self.database)) as db,db:db.execute('PRAGMA user_version=5');db.execute('DROP TABLE cheki_records')
        with self.assertRaises((ValueError,sqlite3.Error)):recovery.database_audit(self.database)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);a,remaining=p.parse_known_args();SOURCE=a.source.resolve(strict=True)
    if not (SOURCE/'.nullable-acceptance.json').is_file():raise SystemExit('Marked synthetic source required')
    unittest.main(argv=[sys.argv[0],*remaining])
