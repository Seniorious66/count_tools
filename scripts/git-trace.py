"""Guard staged planning/data and push each personal commit with remote proof."""
import argparse
import importlib.util
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_ORIGIN = 'https://github.com/Seniorious66/count_tools.git'
WORKBOOK = 'outputs/workflow-20261011/CountTools-MasterSheet.xlsx'


def git(*args, check=True):
    result = subprocess.run(['git', *args], cwd=ROOT, capture_output=True, timeout=90)
    if check and result.returncode:
        raise RuntimeError('Git operation failed: ' + args[0])
    return result


def identity():
    branch = git('branch', '--show-current').stdout.decode().strip()
    if branch != 'personal/customization' and not branch.startswith('personal/customization/'):
        raise ValueError('Commit/push requires personal/customization or its descendant branch')
    origins = git('remote', 'get-url', '--push', '--all', 'origin').stdout.decode().splitlines()
    fetch_origin = git('remote', 'get-url', 'origin').stdout.decode().strip()
    if origins != [EXPECTED_ORIGIN] or fetch_origin != EXPECTED_ORIGIN:
        raise ValueError('origin push URL differs from the approved personal fork')
    return branch


def staged_check():
    identity()
    names = git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').stdout.decode('utf-8').split('\0')
    blocked = re.compile(r'(^|/)(private-data|local-artifacts|count-tools-export)(/|$)|\.(db(?:-(?:journal|wal|shm))?|sqlite3?|bak|apk|aab|jks|keystore|pem|p12|pfx)$|(^|/)(\.env(?:\..*)?|key\.properties|FlutterSharedPreferences\.xml)$|signing.*\.properties$', re.I)
    for name in filter(None, names):
        if blocked.search(name):
            raise ValueError('Personal data/signing artifact is staged: ' + name)
        content = git('show', ':' + name).stdout
        if b'\0' not in content[:8192] and re.search(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----', content):
            raise ValueError('Private key content is staged: ' + name)
    candidate = git('show', ':' + WORKBOOK, check=False)
    if candidate.returncode == 0:
        spec = importlib.util.spec_from_file_location('planning', ROOT / 'scripts/verify-mastersheet.py')
        planning = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(planning)
        old = git('show', 'HEAD:' + WORKBOOK, check=False)
        planning.validate_book(planning.read_book(candidate.stdout),
                               planning.read_book(old.stdout) if old.returncode == 0 else None)
    print('Staged data/signing guard and applicable planning/history check passed.')


def git_path(name):
    raw = git('rev-parse', '--git-path', name).stdout.decode().strip()
    return (ROOT / raw).resolve()


def record_push(branch, head, success, reason):
    record = {'at_utc': datetime.now(timezone.utc).isoformat(), 'branch': branch, 'commit': head,
              'remote': 'origin', 'verified': success, 'reason': reason}
    state = git_path('count-tools-push-state.json')
    state.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding='utf-8')
    with git_path('count-tools-push-history.jsonl').open('a', encoding='utf-8') as output:
        output.write(json.dumps(record, ensure_ascii=False) + '\n')


def remote_matches(branch, head):
    remote = git('ls-remote', '--exit-code', '--heads', 'origin', 'refs/heads/' + branch, check=False)
    fields = remote.stdout.decode().strip().split()
    return remote.returncode == 0 and len(fields) == 2 and fields[0] == head and fields[1] == 'refs/heads/' + branch


def push():
    branch = identity()
    head = git('rev-parse', 'HEAD').stdout.decode().strip()
    try:
        sent = git('push', '--no-follow-tags', '--set-upstream', 'origin', 'HEAD:refs/heads/' + branch, check=False)
        if sent.returncode:
            record_push(branch, head, False, 'push-failed-local-commit-retained')
            raise RuntimeError('Push failed. Local commit retained; it is NOT uploaded. Retry with scripts/commit-and-push.ps1 -PushOnly.')
        if not remote_matches(branch, head):
            record_push(branch, head, False, 'remote-verification-failed')
            raise RuntimeError('Push returned success but remote proof failed; upload is not verified.')
    except subprocess.TimeoutExpired:
        record_push(branch, head, False, 'timeout-upload-unverified')
        raise RuntimeError('Push/remote verification timed out; upload is not verified.') from None
    record_push(branch, head, True, 'remote-head-matches-local')
    print('Commit uploaded to origin/' + branch + '; remote HEAD matches local.')


def verify():
    branch = identity()
    head = git('rev-parse', 'HEAD').stdout.decode().strip()
    if not remote_matches(branch, head):
        raise RuntimeError('Latest local commit is not verified on origin; retry push before delivery.')
    print('Latest local commit is present on origin/' + branch + '.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['pre-commit', 'push', 'verify'])
    args = parser.parse_args()
    try:
        {'pre-commit': staged_check, 'push': push, 'verify': verify}[args.action]()
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
