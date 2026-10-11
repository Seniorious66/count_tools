"""Regression checks for planning history protection and isolated DB validation."""
import copy
import io
import importlib.util
import sqlite3
import tempfile
import unittest
import zipfile
import xml.etree.ElementTree as ET
from contextlib import closing
from pathlib import Path

HERE = Path(__file__).resolve().parent


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


planning = module('planning', 'verify-mastersheet.py')
database = module('database', 'verify-database.py')


class PlanningTests(unittest.TestCase):
    def setUp(self):
        self.book = planning.read_book((planning.ROOT / planning.REL).read_bytes())

    def cell(self, record_id, col, sheet='版本规划'):
        address = next(addr for addr, value in self.book[sheet].items()
                       if addr.startswith('A') and addr[1:].isdigit() and value == record_id)
        return col + address[1:]

    def test_current(self):
        planning.validate_book(self.book, copy.deepcopy(self.book))

    def iso_date_fixture(self, value):
        original = (planning.ROOT / planning.REL).read_bytes()
        output = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(original)) as source, zipfile.ZipFile(output, 'w') as target:
            for name in source.namelist():
                content = source.read(name)
                if name == 'xl/worksheets/sheet2.xml':
                    xml = ET.fromstring(content)
                    cell = xml.find('.//s:c[@r="B8"]', planning.NS)
                    cell.set('t', 'd')
                    cell.find('s:v', planning.NS).text = value
                    content = ET.tostring(xml)
                target.writestr(name, content)
        return output.getvalue()

    def test_iso_date_matches_numeric_history(self):
        parsed = planning.read_book(self.iso_date_fixture('2026-10-11T00:00:00.000Z'))
        self.assertEqual(parsed, self.book)
        planning.validate_book(parsed, self.book)

    def test_invalid_iso_date_rejected(self):
        with self.assertRaises(ValueError): planning.read_book(self.iso_date_fixture('invalid-date'))

    def test_missing_dependency(self):
        self.book['版本规划'][self.cell('v1.1.0', 'F')] = 'v99.0.0'
        with self.assertRaisesRegex(ValueError, 'Missing dependency'):
            planning.validate_book(self.book)

    def test_cycle(self):
        self.book['版本规划'][self.cell('WF-001', 'F')] = 'v1.1.0'
        with self.assertRaisesRegex(ValueError, 'Dependency cycle'):
            planning.validate_book(self.book)

    def test_duplicate_round(self):
        self.book['Changelog']['A99'] = self.book['Changelog']['A8']
        with self.assertRaisesRegex(ValueError, 'Duplicate ID'):
            planning.validate_book(self.book)

    def test_removed_version(self):
        old = copy.deepcopy(self.book)
        # Remove a leaf version so graph validity cannot mask history protection.
        records = planning.records(self.book, '版本规划',
                                   r'v\d+\.\d+\.\d+(?:-r\d+)?', 14)
        referenced = set()
        for row in records.values():
            referenced.update(filter(None, (row[5] or '').replace('，', ',')
                                     .replace('、', ',').split(',')))
        leaf = next(key for key in reversed(records) if key not in referenced)
        cell = next(addr for addr, value in self.book['版本规划'].items()
                    if addr.startswith('A') and value == leaf)
        self.book['版本规划'].pop(cell)
        # Match summary to the remaining valid graph; the failure must be history.
        row = records[leaf]
        if row[3] == '待开发':
            for addr, amount in [('B4', 1), ('D4', row[6]), ('F4', row[7])]:
                self.book['版本规划'][addr] -= amount
        with self.assertRaisesRegex(ValueError, 'Historical version IDs removed'):
            planning.validate_book(self.book, old)

    def test_frozen_round(self):
        old = copy.deepcopy(self.book)
        old['Changelog']['I8'] = '已完成'
        self.book['Changelog']['I8'] = '已完成'
        self.book['Changelog']['H8'] = 'Overwritten evidence'
        with self.assertRaisesRegex(ValueError, 'Historical round overwritten'):
            planning.validate_book(self.book, old)

    def test_in_progress_can_finish(self):
        old = copy.deepcopy(self.book)
        old['Changelog']['I8'] = '进行中'
        for col in ['F', 'H', 'J', 'K']:
            self.book['Changelog'][col + '8'] = 'Completed with recorded evidence'
        self.book['Changelog']['I8'] = '已完成'
        planning.validate_book(self.book, old)

    def test_scope_requires_archive(self):
        old = copy.deepcopy(self.book)
        self.book['版本规划'][self.cell('v1.1.0', 'J')] = 'Different scope'
        with self.assertRaisesRegex(ValueError, 'full historical archive'):
            planning.validate_book(self.book, old)

    def test_summary_mismatch(self):
        self.book['版本规划']['B4'] = 999
        with self.assertRaisesRegex(ValueError, 'Summary'):
            planning.validate_book(self.book)

    def test_non_increasing_version(self):
        self.book['版本规划'][self.cell('v1.1.1', 'N')] = self.book['版本规划'][self.cell('v1.1.0', 'N')]
        with self.assertRaisesRegex(ValueError, 'versionCode'):
            planning.validate_book(self.book)

    def test_requirement_unknown_version(self):
        self.book['执行约定']['D27'] = 'v99.0.0'
        with self.assertRaisesRegex(ValueError, 'Unknown requirement version'):
            planning.validate_book(self.book)

    def test_requirement_without_acceptance(self):
        self.book['执行约定']['E27'] = ''
        with self.assertRaisesRegex(ValueError, 'Incomplete requirement coverage'):
            planning.validate_book(self.book)

    def test_requirement_scope_history(self):
        old = copy.deepcopy(self.book)
        self.book['执行约定']['E27'] = 'Replacement acceptance'
        with self.assertRaisesRegex(ValueError, 'Changed requirement lacks full historical archive'):
            planning.validate_book(self.book, old)

    def test_requirement_history_removal(self):
        old = copy.deepcopy(self.book)
        self.book['执行约定'].pop('A27')
        with self.assertRaisesRegex(ValueError, 'Historical requirement IDs removed'):
            planning.validate_book(self.book, old)

    def test_milestone_unknown_package(self):
        self.book['版本规划'][self.cell('M0', 'C')] = 'v99.0.0'
        with self.assertRaisesRegex(ValueError, 'Unknown milestone package'):
            planning.validate_book(self.book)

    def test_milestone_premature_acceptance(self):
        self.book['版本规划'][self.cell('M2', 'D')] = '已验收'
        self.book['版本规划'][self.cell('M2', 'K')] = 'Reported passed without completing packages'
        with self.assertRaisesRegex(ValueError, 'Accepted milestone has unfinished packages'):
            planning.validate_book(self.book)

    def test_product_mapping_mismatch(self):
        self.book['版本规划'][self.cell('v1.3.2', 'O')] = '1.0.99'
        with self.assertRaisesRegex(ValueError, 'Product/milestone mapping mismatch'):
            planning.validate_book(self.book)

    def test_milestone_dependency_cycle(self):
        self.book['版本规划'][self.cell('M0', 'M')] = 'M5'
        with self.assertRaisesRegex(ValueError, 'Milestone dependency cycle'):
            planning.validate_book(self.book)

    def swap_rows(self, first, second):
        cells = self.book['版本规划']
        a, b = self.cell(first, 'A')[1:], self.cell(second, 'A')[1:]
        for col in 'ABCDEFGHIJKLMNOPQ':
            cells[col + a], cells[col + b] = cells.get(col + b), cells.get(col + a)

    def test_milestone_outside_stage_rejected(self):
        self.swap_rows('M0', 'WF-012')
        with self.assertRaisesRegex(ValueError, 'Milestone placement'):
            planning.validate_book(self.book)

    def test_ui_fix_after_m1_rejected(self):
        self.swap_rows('WF-012', 'WF-005')
        with self.assertRaisesRegex(ValueError, 'UI-FIX-001 placement'):
            planning.validate_book(self.book)


class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'fixture.db'
        with closing(sqlite3.connect(self.path)) as db, db:
            db.executescript('''
                CREATE TABLE users (id INTEGER PRIMARY KEY);
                CREATE TABLE project_data (id INTEGER PRIMARY KEY, count TEXT);
                CREATE TABLE sub_project_data (id INTEGER PRIMARY KEY, parentId TEXT, count TEXT);
                CREATE TABLE item_data (id INTEGER PRIMARY KEY, parentId TEXT, projectId TEXT);
                INSERT INTO project_data VALUES (10, '1');
                INSERT INTO sub_project_data VALUES (20, '10', '1');
                INSERT INTO item_data VALUES (30, '20', '10');
            ''')

    def test_read_only_valid(self):
        before = self.path.read_bytes()
        result = database.verify(self.path)
        self.assertEqual(result['row_counts']['item_data'], 1)
        self.assertEqual(before, self.path.read_bytes())

    def test_orphan_rejected(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("UPDATE item_data SET parentId='999'")
        with self.assertRaisesRegex(ValueError, 'Relationship/count'):
            database.verify(self.path)

    def test_wrong_project_rejected(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("INSERT INTO project_data VALUES (11, '0')")
            db.execute("UPDATE item_data SET projectId='11'")
        with self.assertRaisesRegex(ValueError, 'Relationship/count'):
            database.verify(self.path)

    def test_count_mismatch(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("UPDATE sub_project_data SET count='2'")
        with self.assertRaisesRegex(ValueError, 'Relationship/count'):
            database.verify(self.path)

    def test_missing_file_not_created(self):
        missing = self.path.parent / 'absent.db'
        with self.assertRaises(FileNotFoundError):
            database.verify(missing)
        self.assertFalse(missing.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
