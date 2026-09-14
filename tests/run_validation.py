"""Run bounded release-candidate checks and persist exact local test evidence."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASE = '0a928c2d381e52373226c27deae7b1f9e1c4ece2'
RESULT = ROOT / 'tests/results/application-progress-v1.json'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def main():
    previous = json.loads(RESULT.read_bytes()) if '--resume' in sys.argv and RESULT.exists() else None
    if previous is not None:
        for name, digest in previous['source_sha256'].items():
            if name != 'tests/run_validation.py' and hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError('Cannot reuse tests after source drift: ' + name)
    hosts = [('powershell7', shutil.which('pwsh')), ('powershell51', shutil.which('powershell'))]
    if not all(path for _, path in hosts):
        raise RuntimeError('Both supported Windows PowerShell hosts are required for this qualification.')
    suites = [('layer2-python', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'tests',
                '-p', 'test_application_progress.py', '-q'], r'Ran (\d+) tests')]
    for name, path in hosts:
        for group, script, pattern in (
            ('layer1', 'tests/run_contract_tests.ps1', r'Contract tests passed: (\d+)'),
            ('layer2-renderer', 'tests/test_layer2_renderer.ps1', r'Layer 2 renderer tests passed: (\d+)'),
            ('bundle', 'tests/test_skill_bundle.ps1', r'Bundle sync tests passed: (\d+)')):
            suites.append((group + '-' + name, [path, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script], pattern))
    results = []
    for name, argv, pattern in suites:
        prior = next((row for row in previous['suites'] if row['name'] == name and row['result'] == 'PASS'), None) if previous else None
        if prior is not None:
            results.append(prior)
            print('REUSE unchanged-source PASS ' + name, flush=True)
            continue
        print('RUN ' + name, flush=True)
        environment = os.environ.copy()
        if name.endswith('powershell51'):
            # A Python child of PowerShell 7 otherwise leaks Core-only module
            # discovery into Windows PowerShell. Let 5.1 build its native path.
            environment = {key: value for key, value in environment.items() if key.casefold() != 'psmodulepath'}
        process = subprocess.run(argv, cwd=ROOT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        output = process.stdout.decode('utf-8', errors='replace')
        match = re.search(pattern, output)
        count = int(match.group(1)) if match else 0
        passed = process.returncode == 0 and match is not None and not re.search(r'FAILED|FAIL:|skipped=', output)
        results.append({'name': name, 'argv': argv, 'exit_code': process.returncode,
                        'test_count': count, 'result': 'PASS' if passed else 'FAIL',
                        'output_sha256': hashlib.sha256(process.stdout).hexdigest(), 'output': output})
        print(f'{name}: {results[-1]["result"]} ({count})', flush=True)
        if not passed:
            print(output, flush=True)
            break
    changed = set(git('diff', '--name-only', BASE).splitlines())
    changed.update(git('ls-files', '--others', '--exclude-standard').splitlines())
    changed.add(RESULT.relative_to(ROOT).as_posix())
    hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
              for name in sorted(changed) if ROOT / name != RESULT and (ROOT / name).is_file()}
    total = sum(row['test_count'] for row in results)
    success = len(results) == len(suites) and all(row['result'] == 'PASS' for row in results)
    report = {'task_id': 'ALTM-APPLICATION-PROGRESS-LAYER2-001', 'base_sha': BASE,
              'branch': git('branch', '--show-current'), 'tested_at': datetime.now(timezone.utc).isoformat(),
              'head_identity': 'Resolve the containing review commit; worktree source bytes are bound below.',
              'changed_paths': sorted(changed), 'source_sha256': hashes,
              'test_count': total, 'pass': total if success else None, 'fail': 0 if success else None,
              'status': 'PASS' if success else 'FAIL', 'suites': results,
              'prior_failed_attempts': ([] if previous is None else previous.get('prior_failed_attempts', []) +
                  [row for row in previous['suites'] if row['result'] == 'FAIL']),
              'runner_environment_note': 'Windows PowerShell 5.1 reconstructs its native PSModulePath; other environment inherited. Prior PASS results reused only after source byte checks.',
              'release_tag_created': False, 'other_project_mutated': False,
              'scope': 'Generic operational progress only; no downstream application integration.'}
    RESULT.parent.mkdir(parents=True, exist_ok=True)
    RESULT.write_text(json.dumps(report, indent=2, ensure_ascii=True) + '\n', encoding='utf-8', newline='\n')
    print(f'TOTAL {total}; {report["status"]}', flush=True)
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
