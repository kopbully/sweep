"""Install the reviewed 0.2.0 build and preserve the installed 0.1.1 copies."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

workspace = Path(__file__).resolve().parent.parent
original = Path('/Users/focus/Sweep')
application = Path('/Applications/Sweep.app')
baseline = workspace / 'verification/before-black-hole'
backup = workspace / 'verification/black-hole-installed-backup'
record_file = workspace / 'verification/black-hole-installed.json'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

with (workspace / 'Sweep.app/Contents/Info.plist').open('rb') as stream:
    assert plistlib.load(stream)['CFBundleShortVersionString'] == '0.2.0'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(workspace / 'Sweep.app')], check=True)
assert not backup.exists() and not record_file.exists(), 'Existing install checkpoint; inspect before resuming'
expected_binary = digest(baseline / 'Sweep.app/Contents/MacOS/Sweep')
for old_app in (application, original / 'Sweep.app'):
    assert digest(old_app / 'Contents/MacOS/Sweep') == expected_binary, f'Installed app changed: {old_app}'
for before in baseline.rglob('*'):
    if before.is_file() and 'Sweep.app' not in before.parts:
        installed = original / before.relative_to(baseline)
        if installed.exists():
            assert installed.read_bytes() == before.read_bytes(), f'Source changed: {installed}'

files = list((workspace / 'Sources/Sweep').rglob('*'))
files += [workspace / name for name in ('Package.swift', 'README.md', 'Scripts/make_app.sh', 'Scripts/test.sh', 'Tests/Regression.swift')]
files += [p for p in (workspace / 'BlackHoleWeb').rglob('*')
          if not any(part in {'node_modules', '.npm-cache', 'verification'} for part in p.relative_to(workspace / 'BlackHoleWeb').parts)]
files = [p for p in files if p.is_file()]
backup.mkdir()
changes = []
for source in sorted(files):
    relative = source.relative_to(workspace)
    target = original / relative
    if target.exists() and target.read_bytes() == source.read_bytes():
        continue
    if target.exists():
        saved = backup / 'source' / relative
        saved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target, saved)
    changes.append(str(relative))

stages = []
for target, saved_name in ((application, 'Applications-Sweep.app'), (original / 'Sweep.app', 'source-Sweep.app')):
    stage = target.with_name('.Sweep-0.2.0-codex-stage.app')
    assert not stage.exists(), f'Staging path exists: {stage}'
    subprocess.run(['ditto', str(workspace / 'Sweep.app'), str(stage)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
    stages.append((target, stage, backup / saved_name))

for relative in changes:
    target = original / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(workspace / relative, target)
for target, stage, saved in stages:
    target.rename(saved)
    try:
        stage.rename(target)
    except BaseException:
        saved.rename(target)
        raise

record = {
    'installed_at': datetime.now().astimezone().isoformat(),
    'version': '0.2.0',
    'apps': [str(application), str(original / 'Sweep.app')],
    'source': str(original),
    'backup': str(backup),
    'changed_source_files': changes,
    'binary_sha256': digest(workspace / 'Sweep.app/Contents/MacOS/Sweep'),
}
for target, _, _ in stages:
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
    assert digest(target / 'Contents/MacOS/Sweep') == record['binary_sha256']
record_file.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(record, ensure_ascii=False, indent=2))
