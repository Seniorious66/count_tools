"""Combined M1 dataset, complete-store roundtrip, and fault recovery."""
import argparse
import importlib.util
import json
import sqlite3
import unittest
from contextlib import closing
from pathlib import Path
import recovery
spec=importlib.util.spec_from_file_location('nullable_recovery_checks',Path(__file__).with_name('test-nullable-recovery.py'))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)

class M1RecoveryTests(base.NullableRecoveryTests):
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before=recovery.database_audit(self.database);self.assertEqual(before['version'],5)
        with closing(sqlite3.connect(self.database)) as db:
            infos=[json.loads(r[0]) for r in db.execute('SELECT information_json FROM cheki_records')];self.assertEqual(len(infos),5);self.assertIn({},infos)
            known=[i for i in infos if isinstance(i.get('quantity'),int)];self.assertEqual(sum(i['quantity'] for i in known),7);self.assertEqual(sum(i['quantity']*len(i['member_ids']) for i in known),9)
            self.assertEqual(sum(b['quantity'] for i in known for b in i['receipt_batches']),5)
            joint=next(i for i in known if len(i['member_ids'])==2);self.assertEqual(len(joint['receipt_batches']),2);self.assertEqual(joint['receipt_batches'][0]['received_at'],'2026-10-12T01:00:00.123456Z')
            self.assertEqual([s['member_name'] for s in joint['member_snapshots']],['A','B']);self.assertEqual(joint['occurred_on'],'2026-10-11')
            old=next(i for i in infos if 'legacy_raw' in i);self.assertIsNone(old['quantity']);self.assertNotIn('occurred_on',old);self.assertIsNone(old['member_snapshots']);self.assertEqual(old['legacy_raw']['price'],'25.00');self.assertEqual(old['legacy_raw']['unknown'],[None,'原文']);self.assertNotIn('origin',old['receipt_batches'][0])
        root=self.root();recovery.restore(self.bundle(),root);current=root/'current';self.assertEqual(recovery.database_audit(current/'database.sqlite'),before)
        self.assertEqual((current/'settings/preferences.json').read_bytes(),self.settings.read_bytes());self.assertEqual((current/'attachments/synthetic-attachment').read_bytes(),self.attachment.read_bytes())
        again=self.base/'again';recovery.snapshot(current/'database.sqlite',current/'settings/preferences.json',again,[current/'attachments/synthetic-attachment']);self.assertEqual(recovery.verify_bundle(again)['database'],json.loads(json.dumps(before)))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);args=p.parse_args();source=args.source.resolve(strict=True);marker=json.loads((source/'.m1-acceptance.json').read_text(encoding='utf-8-sig'))
    if marker.get('project')!='count_tools' or marker.get('purpose')!='m1-synthetic-combined':raise ValueError('Explicit synthetic M1 marker required')
    base.SOURCE=source;unittest.main(argv=[__file__])
