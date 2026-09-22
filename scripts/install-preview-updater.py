#!/usr/bin/env python3
"""Install this user's ten-minute, read-only usage snapshot publisher."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
label = 'app.tokendeck.preview'
path = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
cache = Path.home() / 'Library/Caches/TokenDeck-preview'
assert (Path.home() / '.config/usage-bar/preview.json').is_file(), 'Configure approved account first'
assert (root / 'tauri/build-preview/index.html').is_file(), 'Build the preview first'
assert not path.exists(), 'An existing updater must be inspected before replacement'
python = shutil.which('python3')
assert python
cache.mkdir(parents=True, exist_ok=True)
path.parent.mkdir(parents=True, exist_ok=True)
settings = {
    'Label': label,
    'ProgramArguments': [python, str(root / 'scripts/publish-preview.py')],
    'WorkingDirectory': str(root),
    'StartInterval': 600,
    'RunAtLoad': True,
    'ProcessType': 'Background',
    'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
    'StandardOutPath': str(cache / 'publisher.log'),
    'StandardErrorPath': str(cache / 'publisher-error.log'),
}
path.write_bytes(plistlib.dumps(settings))
os.chmod(path, 0o600)
subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(path)], check=True)
print('Preview updater installed: every 10 minutes while signed in')
