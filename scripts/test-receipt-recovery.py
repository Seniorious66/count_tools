"""Full-store transport of actual Dart receipt edits, including missing origins."""
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

spec = importlib.util.spec_from_file_location(
    'nullable_recovery_checks', Path(__file__).with_name('test-nullable-recovery.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

class ReceiptRecoveryTests(base.NullableRecoveryTests):
    def test_all_objects_blank_fields_raw_legacy_actions_settings_attachment_rebackup_new_process(self):
        before = recovery.database_audit(self.database)
        self.assertEqual(before['version'], 5)
        with closing(sqlite3.connect(self.database)) as db:
            info = [json.loads(r[0]) for r in db.execute('SELECT information_json FROM cheki_records')]
            self.assertEqual(len(info), 3)
            self.assertIn({}, info)
            multi = next(i for i in info if 'legacy_raw' in i)
            self.assertEqual(multi['quantity'], 4)
            self.assertEqual(multi['legacy_raw']['date'], '2024-01-02 13:14:15')
            self.assertEqual([b['quantity'] for b in multi['receipt_batches']], [2, 2])
            self.assertNotIn('origin', multi['receipt_batches'][1])
            self.assertEqual(multi['receipt_batches'][1]['received_at'], '2026-10-12T02:00:00.654321Z')
            self.assertEqual(multi['receipt_batches'][0]['opaque'], {'values': [None, '原文']})
            unknown = next(i for i in info if len(i.get('receipt_batches') or []) == 1)
            self.assertNotIn('quantity', unknown)
            self.assertNotIn('origin', unknown['receipt_batches'][0])
            self.assertIsNone(unknown['receipt_batches'][0]['quantity'])
        root = self.root()
        recovery.restore(self.bundle(), root)
        current = root / 'current'
        self.assertEqual(recovery.database_audit(current / 'database.sqlite'), before)
        self.assertEqual((current / 'settings/preferences.json').read_bytes(), self.settings.read_bytes())
        self.assertEqual((current / 'attachments/synthetic-attachment').read_bytes(), self.attachment.read_bytes())
        again = self.base / 'again'
        recovery.snapshot(current / 'database.sqlite', current / 'settings/preferences.json',
                          again, [current / 'attachments/synthetic-attachment'])
        self.assertEqual(recovery.verify_bundle(again)['database'], json.loads(json.dumps(before)))
        code = ('import sys;sys.path.insert(0,sys.argv[1]);import recovery;'
                'assert recovery.database_audit(sys.argv[2])["version"]==5')
        subprocess.run([sys.executable, '-c', code, str(Path(recovery.__file__).parent),
                        str(current / 'database.sqlite')], check=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True)
    args = parser.parse_args()
    source = Path(args.source).resolve()
    marker = json.loads((source / '.receipt-acceptance.json').read_text(encoding='utf-8-sig'))
    if marker.get('project') != 'count_tools' or marker.get('purpose') != 'm1-synthetic-receipts':
        raise ValueError('Explicit synthetic receipt marker required')
    base.SOURCE = source
    unittest.main(argv=[sys.argv[0]])
