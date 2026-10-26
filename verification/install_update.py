"""Apply this reviewed local build; preserve the complete original app and sources."""
from pathlib import Path
import hashlib
import json
import shutil

workspace = Path(__file__).resolve().parent.parent
original = Path('/Users/focus/Sweep')
verification = workspace / 'verification'
hashes = json.loads((verification / 'original-hashes.json').read_text())
for name, expected in hashes.items():
    actual = hashlib.sha256((original / name).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f'Original changed since inspection: {name}')

stage = original / '.Sweep-0.1.1-stage.app'
retired = verification / 'replaced-original.app'
if stage.exists() or retired.exists():
    raise SystemExit('Existing update checkpoint; inspect before resuming')
shutil.copytree(workspace / 'Sweep.app', stage, symlinks=True)

changed = []
files = list((workspace / 'Sources/Sweep').glob('*.swift')) + [
    workspace / 'README.md',
    workspace / 'Scripts/make_app.sh',
    workspace / 'Scripts/test.sh',
    workspace / 'Tests/Regression.swift',
    verification / 'investigation.md',
    verification / 'regression-after.txt',
    verification / 'live-system-readings.json',
]
for source in files:
    relative = source.relative_to(workspace)
    target = original / relative
    if target.exists() and source.read_bytes() == target.read_bytes():
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    changed.append(str(relative))

(original / 'Sweep.app').rename(retired)
try:
    stage.rename(original / 'Sweep.app')
except BaseException:
    retired.rename(original / 'Sweep.app')
    raise

record = {
    'installed_app': str(original / 'Sweep.app'),
    'version': '0.1.1',
    'changed_source_files': changed,
    'backup': str(verification / 'backup-before-update'),
    'old_app_retained': str(retired),
    'binary_sha256': hashlib.sha256((original / 'Sweep.app/Contents/MacOS/Sweep').read_bytes()).hexdigest(),
}
(verification / 'installed.json').write_text(json.dumps(record, indent=2))
print(json.dumps(record, ensure_ascii=False, indent=2))
