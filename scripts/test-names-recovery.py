"""Actual Dart name snapshots survive all-store transport and audit checks."""
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
from record_validation import information
spec=importlib.util.spec_from_file_location('nullable_recovery_checks',Path(__file__).with_name('test-nullable-recovery.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)

class NamesRecoveryTests(base.NullableRecoveryTests):
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before=recovery.database_audit(self.database)
        self.assertEqual(before['version'],5)
        with closing(sqlite3.connect(self.database)) as db:
            info=[json.loads(r[0]) for r in db.execute('SELECT information_json FROM cheki_records')]
            self.assertEqual(len(info),4);self.assertIn({},info)
            old=next(i for i in info if i.get('member_ids') and 'member_snapshots' not in i)
            self.assertEqual(old['legacy_raw'],{'id':91,'date':'2024-01-02 13:14:15','ext':None})
            self.assertNotIn('origin',old['receipt_batches'][0]);self.assertEqual(old['receipt_batches'][0]['received_at'],'2026-10-12T02:00:00.654321Z')
            manual=next(i for i in info if i.get('member_snapshots') and i['member_snapshots'][0]['origin']=='manual')['member_snapshots'][0]
            self.assertEqual(manual['member_name'],'史料名');self.assertEqual(manual['group_name'],'史料团');self.assertEqual(manual['opaque'],{'keep':[None,'原文']});self.assertEqual(manual['member_name_origin'],'manual');self.assertEqual(manual['group_name_origin'],'manual')
            entry=next(i for i in info if i.get('member_snapshots') and i['member_snapshots'][0]['origin']=='entry')['member_snapshots'][0]
            self.assertEqual(entry['member_name'],'旧名');self.assertEqual(entry['group_name'],'旧团')
        root=self.root();recovery.restore(self.bundle(),root);current=root/'current'
        self.assertEqual(recovery.database_audit(current/'database.sqlite'),before)
        self.assertEqual((current/'settings/preferences.json').read_bytes(),self.settings.read_bytes());self.assertEqual((current/'attachments/synthetic-attachment').read_bytes(),self.attachment.read_bytes())
        again=self.base/'again';recovery.snapshot(current/'database.sqlite',current/'settings/preferences.json',again,[current/'attachments/synthetic-attachment']);self.assertEqual(recovery.verify_bundle(again)['database'],json.loads(json.dumps(before)))
        code='import sys;sys.path.insert(0,sys.argv[1]);import recovery;assert recovery.database_audit(sys.argv[2])["version"]==5'
        subprocess.run([sys.executable,'-c',code,str(Path(recovery.__file__).parent),str(current/'database.sqlite')],check=True)
    def test_snapshot_invalid_known_values_match_dart_contract(self):
        values=[42,[{'member_id':'other'}],[{'member_id':'m'},{'member_id':'m'}],[{'member_id':'m','member_name':3}],[{'member_id':'m','origin':'guessed'}],[{'member_id':'m','member_name_origin':'guessed'}]]
        for value in values:
            with self.subTest(value=value),self.assertRaises(ValueError):information(json.dumps({'member_ids':['m'],'member_snapshots':value}))
        self.assertEqual(information('{"member_ids":["m"],"member_snapshots":[{"member_id":"m","member_name":null,"opaque":[null,1]}]}')['member_snapshots'][0]['opaque'],[None,1])

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);a=p.parse_args();source=a.source.resolve(strict=True)
    marker=json.loads((source/'.names-acceptance.json').read_text(encoding='utf-8-sig'))
    if marker.get('project')!='count_tools' or marker.get('purpose')!='m1-synthetic-names':raise ValueError('Explicit synthetic name marker required')
    base.SOURCE=source;unittest.main(argv=[sys.argv[0]])
