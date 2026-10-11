"""Read-only planning and history validation using only Python's standard library."""
import argparse
import io
import json
import re
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REL = 'outputs/workflow-20261011/CountTools-MasterSheet.xlsx'
NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
SHEETS = ['版本规划', 'Changelog', '决策与风险', '执行约定']


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_book(data):
    result = {}
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        shared = []
        if 'xl/sharedStrings.xml' in z.namelist():
            for si in ET.fromstring(z.read('xl/sharedStrings.xml')):
                shared.append(''.join(t.text or '' for t in si.findall('.//s:t', NS)))
        rels = {r.attrib['Id']: r.attrib['Target'] for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
        for sh in ET.fromstring(z.read('xl/workbook.xml')).findall('s:sheets/s:sheet', NS):
            target = rels[sh.attrib['{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id']]
            name = target.lstrip('/') if target.startswith('/') else 'xl/' + target
            cells = {}
            for c in ET.fromstring(z.read(name)).findall('.//s:sheetData/s:row/s:c', NS):
                typ = c.attrib.get('t')
                v = c.find('s:v', NS)
                value = v.text if v is not None else None
                if typ == 's':
                    value = shared[int(value)]
                elif typ == 'inlineStr':
                    value = ''.join(t.text or '' for t in c.findall('.//s:t', NS))
                elif value is not None and typ not in ('str', 'e', 'b'):
                    value = float(value)
                require(typ != 'e', f'Excel error at {sh.attrib["name"]}!{c.attrib["r"]}')
                f = c.find('s:f', NS)
                require(f is None or '#REF!' not in (f.text or ''), 'Broken formula reference')
                cells[c.attrib['r']] = value
            result[sh.attrib['name']] = cells
    return result


def records(book, sheet, pattern, columns):
    result = {}
    for addr, value in book[sheet].items():
        if re.fullmatch(r'A\d+', addr) and re.fullmatch(pattern, str(value)):
            require(value not in result, f'Duplicate ID in {sheet}: {value}')
            result[value] = [book[sheet].get(f'{chr(65+i)}{addr[1:]}') for i in range(columns)]
    return result


def validate_book(book, old=None):
    require(list(book) == SHEETS, 'Expected four planning sheets in the documented order')
    versions = records(book, '版本规划', r'(?:BASE-[\w-]+|WF-\d+|v\d+\.\d+\.\d+(?:-r\d+)?)', 14)
    require(bool(versions), 'No version records')
    old_versions = records(old, '版本规划', r'(?:BASE-[\w-]+|WF-\d+|v\d+\.\d+\.\d+(?:-r\d+)?)', 14) if old else {}
    require(old_versions.keys() <= versions.keys(), 'Historical version IDs removed')
    allowed = {'历史基线', '进行中', '待开发', '待定', '可选', '已合并/不开发', '已完成', '本地完成/待实机', '已安装/待验收'}
    for key, row in versions.items():
        require(row[3] in allowed, f'Invalid version state: {key}')
        require(all(row[i] for i in [1, 2, 4, 8, 9, 10, 11, 12]), f'Incomplete version scope: {key}')
        if row[3] == '待开发':
            require(isinstance(row[6], (float, int)) and isinstance(row[7], (float, int)) and 0 < row[6] <= row[7], f'Estimate missing: {key}')
    visited, active = set(), set()

    def visit(key):
        require(key not in active, f'Dependency cycle at {key}')
        if key in visited:
            return
        active.add(key)
        for dep in filter(None, re.split(r'[,，、]', versions[key][5] or '')):
            require(dep in versions, f'Missing dependency: {key} -> {dep}')
            require(versions[dep][3] not in {'已合并/不开发', '可选', '待定'}, f'Inactive dependency: {dep}')
            visit(dep)
        active.remove(key)
        visited.add(key)
    for key in versions:
        visit(key)
    codes = [(key, row[13]) for key, row in versions.items() if key.startswith('v') and row[13] is not None]
    require(all(isinstance(code, (int, float)) and code == int(code) and 0 < code <= 2100000000 for _, code in codes), 'Invalid versionCode')
    require([code for _, code in codes] == sorted({code for _, code in codes}), 'versionCode must be unique and increasing in planning order')
    for key, row in versions.items():
        for dep in filter(None, re.split(r'[,，、]', row[5] or '')):
            if key.startswith('v') and dep.startswith('v') and row[13] is not None and versions[dep][13] is not None:
                require(versions[dep][13] < row[13], f'Non-increasing dependency versionCode: {key}')
    milestones = records(book, '版本规划', r'M\d+', 14)
    old_milestones = records(old, '版本规划', r'M\d+', 14) if old else {}
    require(old_milestones.keys() <= milestones.keys(), 'Historical milestone IDs removed')
    if book['版本规划'].get('O7') == 'App目标版本':
        require(bool(milestones), 'Milestone board missing')
    if milestones:
        extended_versions = records(book, '版本规划', r'v\d+\.\d+\.\d+(?:-r\d+)?', 17)
        covered = {}
        milestone_states = {'待开始', '本地通过/待实机', '待用户复核', '已验收', '需整改'}
        for key, row in milestones.items():
            require(all(row), f'Incomplete milestone: {key}')
            require(row[3] in milestone_states, f'Invalid milestone state: {key}')
            packages = [p.strip() for p in re.split(r'[,，、]', row[2]) if p.strip()]
            for package in packages:
                require(package in extended_versions, f'Unknown milestone package: {key} -> {package}')
                require(package not in covered, f'Package assigned to multiple milestones: {package}')
                covered[package] = key
            if row[3] == '已验收':
                require(all(versions[p][3] == '已完成' for p in packages),
                        f'Accepted milestone has unfinished packages: {key}')
                require(not any(phrase in row[10] for phrase in ['未实现', '未检查']),
                        f'Accepted milestone lacks actual evidence: {key}')
        require(covered.keys() == extended_versions.keys(), 'Milestone coverage differs from development packages')
        for key, row in extended_versions.items():
            require(all(row[14:17]), f'Missing product/milestone mapping: {key}')
            require(row[15] == covered[key] and row[14] == milestones[covered[key]][4],
                    f'Product/milestone mapping mismatch: {key}')
        milestone_visited, milestone_active = set(), set()

        def visit_milestone(key):
            require(key not in milestone_active, f'Milestone dependency cycle at {key}')
            if key in milestone_visited:
                return
            milestone_active.add(key)
            deps = [] if milestones[key][12] == '—' else re.split(r'[,，、]', milestones[key][12])
            for dep in (p.strip() for p in deps if p.strip()):
                require(dep in milestones, f'Missing milestone dependency: {key} -> {dep}')
                if milestones[key][3] == '已验收':
                    require(milestones[dep][3] == '已验收', f'Accepted milestone has unaccepted predecessor: {key}')
                visit_milestone(dep)
            milestone_active.remove(key)
            milestone_visited.add(key)
        for key in milestones:
            visit_milestone(key)
    logs = records(book, 'Changelog', r'ROUND-[\w-]+', 12)
    decisions = records(book, '决策与风险', r'(?:DEC|RISK)-\d+', 9)
    requirements = records(book, '执行约定', r'REQ-\d+', 6)
    for key, row in requirements.items():
        require(all(row), f'Incomplete requirement coverage: {key}')
        require('§' in row[2], f'Requirement source section missing: {key}')
        for target in filter(None, re.split(r'[,，、]', row[3])):
            require(target in versions, f'Unknown requirement version: {key} -> {target}')
    require(bool(logs) and bool(decisions), 'Missing Changelog or decisions/risks')
    for row in logs.values():
        require(all(row[i] for i in [1, 2, 3, 4, 6, 8, 11]), 'Incomplete round record')
        require(row[2] in versions, f'Unknown round target: {row[2]}')
        if row[8] != '进行中':
            require(all(row[i] for i in [5, 7, 9, 10]), 'Closed round missing delivery evidence')
    planned = [r for r in versions.values() if r[3] == '待开发']
    expected = [len(planned), sum(r[6] for r in planned), sum(r[7] for r in planned)]
    require([book['版本规划'].get(a) for a in ['B4', 'D4', 'F4']] == expected, 'Summary formulas/cache differ from planned rows')
    if old:
        archive = '\n'.join(str(v) for v in book['执行约定'].values() if v is not None)
        for key, row in old_versions.items():
            scope = [0, 1, 2, 4, 5, 6, 7, 8, 9, 12, 13]
            if any(row[i] != versions[key][i] for i in scope):
                require(json.dumps(row, ensure_ascii=False) in archive, f'Changed scope lacks full historical archive: {key}')
        old_extended = records(old, '版本规划', r'v\d+\.\d+\.\d+(?:-r\d+)?', 17)
        new_extended = records(book, '版本规划', r'v\d+\.\d+\.\d+(?:-r\d+)?', 17)
        for key, row in old_extended.items():
            if any(row[14:17]) and row[14:17] != new_extended[key][14:17]:
                require(json.dumps(row, ensure_ascii=False) in archive,
                        f'Changed product mapping lacks full historical archive: {key}')
        for key, row in old_milestones.items():
            scope = [0, 1, 2, 4, 5, 8, 9, 11, 12, 13]
            if any(row[i] != milestones[key][i] for i in scope):
                require(json.dumps(row, ensure_ascii=False) in archive,
                        f'Changed milestone scope lacks full historical archive: {key}')
        old_requirements = records(old, '执行约定', r'REQ-\d+', 6)
        require(old_requirements.keys() <= requirements.keys(), 'Historical requirement IDs removed')
        for key, row in old_requirements.items():
            if row[:5] != requirements[key][:5]:
                require(json.dumps(row, ensure_ascii=False) in archive,
                        f'Changed requirement lacks full historical archive: {key}')
        old_logs = records(old, 'Changelog', r'ROUND-[\w-]+', 12)
        require(old_logs.keys() <= logs.keys(), 'Historical round removed')
        for key, row in old_logs.items():
            immutable = range(12) if row[8] != '进行中' else [0, 1, 2, 3, 4, 6]
            require(all(row[i] == logs[key][i] for i in immutable), f'Historical round overwritten: {key}')
        old_decisions = records(old, '决策与风险', r'(?:DEC|RISK)-\d+', 9)
        require(old_decisions.keys() <= decisions.keys(), 'Historical decision/risk removed')
        for key, row in old_decisions.items():
            require(all(row[i] == decisions[key][i] for i in [0, 1, 2, 3, 4, 6]), f'Decision description overwritten: {key}')
            for i in [7, 8]:
                require(str(decisions[key][i] or '').startswith(str(row[i] or '')), f'Evidence truncated: {key}')
    return {'versions': len(versions), 'planned_versions': expected[0], 'estimated_person_days': expected[1:], 'dependency_graph': 'acyclic', 'milestones': len(milestones), 'requirements': len(requirements), 'rounds': len(logs), 'xlsx_errors': 0, 'history_checked': old is not None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', help='Git ref containing the existing workbook; missing workbook fails')
    args = parser.parse_args()
    try:
        book = read_book((ROOT / REL).read_bytes())
        old = None
        if args.baseline:
            proc = subprocess.run(['git', 'show', f'{args.baseline}:{REL}'], cwd=ROOT, capture_output=True)
            require(proc.returncode == 0, 'History baseline lacks workbook; establish the first planning commit before using --baseline')
            old = read_book(proc.stdout)
        print(json.dumps(validate_book(book, old), ensure_ascii=False))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, ET.ParseError) as error:
        parser.exit(1, f'Planning check failed: {error}\n')


if __name__ == '__main__':
    main()
