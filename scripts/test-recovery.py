"""Fault injection and complete roundtrips, only in disposable isolation."""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
import recovery


def fixture(directory, title='fixture'):
    directory.mkdir()
    database = directory / 'source.db'
    with closing(sqlite3.connect(database)) as db:
        db.executescript('''
            PRAGMA user_version=1;
            CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT,username TEXT NOT NULL,user_key TEXT NOT NULL,ext TEXT);
            CREATE TABLE project_data(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,subTitle TEXT,count TEXT,ext TEXT);
            CREATE TABLE sub_project_data(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL,count TEXT NOT NULL,countPre TEXT NOT NULL,color TEXT NOT NULL,textColor TEXT NOT NULL,parentId TEXT NOT NULL,ext TEXT);
            CREATE TABLE item_data(id INTEGER PRIMARY KEY AUTOINCREMENT,price TEXT,eventName TEXT,type TEXT,date TEXT NOT NULL,itemName TEXT NOT NULL,parentId TEXT NOT NULL,projectId TEXT NOT NULL,ext TEXT,unknown_value TEXT);
            CREATE TABLE unknown_table(id INTEGER PRIMARY KEY,payload BLOB,nullable_value TEXT);
            CREATE INDEX legacy_custom_index ON item_data(date);
            CREATE VIEW legacy_custom_view AS SELECT id,date FROM item_data;
        ''')
        db.execute('INSERT INTO users VALUES(9,?,?,?)', ('synthetic-user','SECRET-SYNTHETIC','opaque'))
        db.execute('INSERT INTO project_data VALUES(17,?,NULL,1,NULL)', (title,))
        db.execute("INSERT INTO sub_project_data VALUES(41,'member',2,'100.0','4280391411','4278190080','17',NULL)")
        db.execute("INSERT INTO item_data VALUES(91,NULL,NULL,NULL,'2024-01-02 13:14:15','record','41','17',NULL,'未知原文')")
        db.execute("INSERT INTO item_data VALUES(92,'25.00','event','type','2024-01-03','record2','41','17','{\"old\":true}',NULL)")
        db.execute('INSERT INTO unknown_table VALUES(5,?,NULL)', (b'\x00\xffopaque',))
        db.execute("UPDATE sqlite_sequence SET seq=1000 WHERE name='item_data'")
        db.commit()
    settings = directory / 'preferences.json'
    settings.write_text(json.dumps({'themeColor':'blue','unknownPreference':['a','b'],
                                    'counter':7,'enabled':True,'opaque':'SECRET-SYNTHETIC'}), encoding='utf-8')
    attachment = directory / 'evidence-journal'
    attachment.write_bytes(b'original sidecar evidence')
    return database, settings, attachment


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='count-tools-recovery-')
        self.base = Path(self.temporary.name)
        self.database, self.settings, self.attachment = fixture(self.base / 'source')
        self.bundle = self.base / 'bundle'
        recovery.snapshot(self.database, self.settings, self.bundle, [self.attachment])
        self.root = self.base / 'isolated'
        recovery.init_root(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def tree_state(self, root):
        return {p.relative_to(root).as_posix():p.read_bytes() for p in root.rglob('*') if p.is_file()}

    def second_bundle(self):
        database, settings, attachment = fixture(self.base / 'second', 'replacement')
        settings.write_text('{"themeColor":"pink","counter":19}', encoding='utf-8')
        bundle = self.base / 'second-bundle'
        recovery.snapshot(database, settings, bundle, [attachment])
        return bundle

    def test_complete_roundtrip_and_cold_reopen(self):
        before = recovery.database_audit(self.database)
        result = recovery.restore(self.bundle, self.root)
        self.assertFalse(result['previous_generation_retained'])
        current = self.root / 'current'
        self.assertEqual(recovery.database_audit(current / 'database.sqlite'), before)
        self.assertEqual((current / 'settings' / self.settings.name).read_bytes(), self.settings.read_bytes())
        self.assertEqual((current / 'attachments' / self.attachment.name).read_bytes(), self.attachment.read_bytes())
        with closing(sqlite3.connect(current / 'database.sqlite')) as db:
            self.assertIsNone(db.execute('SELECT price FROM item_data WHERE id=91').fetchone()[0])
            self.assertEqual(db.execute("SELECT seq FROM sqlite_sequence WHERE name='item_data'").fetchone()[0],1000)
            self.assertEqual(db.execute('SELECT payload FROM unknown_table').fetchone()[0],b'\x00\xffopaque')
        cold = subprocess.run([sys.executable, str(Path(recovery.__file__)), 'verify','--bundle',str(current)],capture_output=True,text=True)
        self.assertEqual(cold.returncode,0,cold.stderr)
        self.assertNotIn('SECRET-SYNTHETIC',cold.stdout)

    def test_committed_wal_included_and_uncommitted_write_excluded(self):
        with closing(sqlite3.connect(self.database)) as writer:
            writer.execute('PRAGMA journal_mode=WAL')
            writer.execute("UPDATE project_data SET title='committed WAL'")
            writer.commit()
            writer.execute("UPDATE project_data SET title='uncommitted WAL'")
            bundle = self.base / 'wal-bundle'
            recovery.snapshot(self.database,self.settings,bundle)
            with closing(sqlite3.connect(bundle / 'database.sqlite')) as restored:
                self.assertEqual(restored.execute('SELECT title FROM project_data').fetchone()[0],'committed WAL')
            writer.rollback()

    def test_preview_is_read_only_and_counts_match(self):
        recovery.restore(self.bundle,self.root)
        before = self.tree_state(self.root)
        result = recovery.preview(self.second_bundle(),self.root)
        self.assertFalse(result['writes_applied'])
        self.assertEqual(result['incoming']['row_counts']['item_data'],2)
        self.assertEqual(result['incoming']['settings']['count'],2)
        self.assertEqual(self.tree_state(self.root),before)
        self.assertNotIn('SECRET-SYNTHETIC',json.dumps(result))

    def test_damaged_bundle_rejected_before_original_changes(self):
        recovery.restore(self.bundle,self.root)
        before = self.tree_state(self.root / 'current')
        damaged = self.second_bundle()
        (damaged / 'settings' / self.settings.name).write_text('{}',encoding='utf-8')
        with self.assertRaises(ValueError): recovery.restore(damaged,self.root)
        self.assertEqual(self.tree_state(self.root / 'current'),before)

    def test_faults_rollback_database_and_settings_together(self):
        recovery.restore(self.bundle,self.root)
        before = self.tree_state(self.root / 'current')
        replacement = self.second_bundle()
        for stage in ('old-moved','new-installed'):
            def fault(actual):
                if actual == stage: raise OSError('injected filesystem failure')
            with self.assertRaises(OSError): recovery.restore(replacement,self.root,_fault=fault)
            self.assertEqual(self.tree_state(self.root / 'current'),before)
            self.assertFalse((self.root / 'recovery-transaction.json').exists())

    def test_process_crash_recovered_by_new_process(self):
        recovery.restore(self.bundle,self.root)
        before = self.tree_state(self.root / 'current')
        replacement = self.second_bundle()
        for stage in ('old-moved','new-installed'):
            crashed = subprocess.run([sys.executable,__file__,'--crash-helper',str(replacement),str(self.root),stage],capture_output=True)
            self.assertEqual(crashed.returncode,77)
            self.assertTrue((self.root / 'recovery-transaction.json').exists())
            recovered = subprocess.run([sys.executable,str(Path(recovery.__file__)),'recover','--root',str(self.root)],capture_output=True,text=True)
            self.assertEqual(recovered.returncode,0,recovered.stderr)
            self.assertEqual(self.tree_state(self.root / 'current'),before)

    def test_failed_first_restore_returns_empty_original(self):
        def fault(stage): raise OSError('injected')
        with self.assertRaises(OSError): recovery.restore(self.bundle,self.root,_fault=fault)
        self.assertFalse((self.root / 'current').exists())
        self.assertFalse((self.root / 'recovery-transaction.json').exists())

    def test_old_generation_retained_after_success(self):
        recovery.restore(self.bundle,self.root)
        before = self.tree_state(self.root / 'current')
        result = recovery.restore(self.second_bundle(),self.root)
        self.assertTrue(result['previous_generation_retained'])
        rollback = list(self.root.glob('.rollback-*'))
        self.assertEqual(len(rollback),1)
        self.assertEqual(self.tree_state(rollback[0]),before)

    def test_android_settings_preserved_verbatim(self):
        xml = self.database.parent / 'FlutterSharedPreferences.xml'
        xml.write_text('<map><string name="flutter.opaque">serialized unchanged</string><boolean name="flutter.enabled" value="true"/><long name="flutter.integer" value="7"/><float name="flutter.scale" value="1.5"/><set name="flutter.labels"><string>a</string><string>b</string></set></map>',encoding='utf-8')
        bundle = self.base / 'xml-bundle'
        recovery.snapshot(self.database,xml,bundle)
        recovery.restore(bundle,self.root)
        self.assertEqual((self.root / 'current/settings/FlutterSharedPreferences.xml').read_bytes(),xml.read_bytes())

    def test_missing_source_and_existing_target_not_overwritten(self):
        original = self.tree_state(self.bundle)
        with self.assertRaises(ValueError): recovery.snapshot(self.database,self.settings,self.bundle)
        missing = self.base / 'missing.db'
        with self.assertRaises(FileNotFoundError): recovery.snapshot(missing,self.settings,self.base / 'new')
        self.assertFalse(missing.exists())
        self.assertEqual(self.tree_state(self.bundle),original)

    def test_business_invalid_database_rejected_without_source_edits(self):
        with closing(sqlite3.connect(self.database)) as db:
            db.execute("UPDATE item_data SET parentId='missing'")
            db.commit()
        before = self.database.read_bytes()
        with self.assertRaises(ValueError): recovery.snapshot(self.database,self.settings,self.base / 'invalid')
        self.assertEqual(self.database.read_bytes(),before)
        self.assertFalse((self.base / 'invalid').exists())

    def test_manifest_paths_and_unmarked_root_rejected(self):
        manifest = json.loads((self.bundle / 'manifest.json').read_text(encoding='utf-8'))
        manifest['files']['../outside'] = {'size':0,'sha256':''}
        recovery.write_json(self.bundle / 'manifest.json',manifest)
        with self.assertRaises(ValueError): recovery.verify_bundle(self.bundle)
        unmarked = self.base / 'unmarked'
        unmarked.mkdir()
        with self.assertRaises(FileNotFoundError): recovery.restore(self.bundle,unmarked)
        self.assertEqual(list(unmarked.iterdir()),[])

    def test_duplicate_settings_keys_and_source_child_output_rejected(self):
        duplicate = self.base / 'duplicate.json'
        duplicate.write_text('{"opaque":"first","opaque":"second"}',encoding='utf-8')
        with self.assertRaises(ValueError): recovery.snapshot(self.database,duplicate,self.base / 'duplicate-bundle')
        with self.assertRaises(ValueError): recovery.snapshot(self.database,self.settings,self.database.parent / 'backup-child')
        self.assertFalse((self.database.parent / 'backup-child').exists())

    def test_schema2_and_old_format1_both_roundtrip_with_full_fields(self):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('CREATE TABLE count_tools_migrations(version INTEGER PRIMARY KEY,migration TEXT NOT NULL)')
            db.execute("INSERT INTO count_tools_migrations VALUES(2,'preserve_legacy_v1')")
            db.execute('PRAGMA user_version=2')
        newer = self.base / 'schema2-bundle'
        recovery.snapshot(self.database,self.settings,newer,[self.attachment])
        recovery.restore(newer,self.root)
        self.assertEqual(recovery.database_audit(self.database),recovery.database_audit(self.root / 'current/database.sqlite'))
        recovery.restore(self.bundle,self.root)
        self.assertEqual(recovery.verify_bundle(self.bundle)['database']['version'],1)
        self.assertEqual(recovery.database_audit(self.root / 'current/database.sqlite')['version'],1)

    def test_unsupported_and_false_schema2_reject_readonly(self):
        for version in (3,2):
            with closing(sqlite3.connect(self.database)) as db,db:
                db.execute(f'PRAGMA user_version={version}')
            before=self.database.read_bytes()
            with self.assertRaises(ValueError): recovery.database_audit(self.database)
            self.assertEqual(self.database.read_bytes(),before)


if __name__ == '__main__':
    if sys.argv[1:2] == ['--crash-helper']:
        def crash(stage):
            if stage == sys.argv[4]: os._exit(77)
        recovery.restore(sys.argv[2],sys.argv[3],_fault=crash)
        raise SystemExit(1)
    unittest.main()
