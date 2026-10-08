#!/usr/bin/env python3
"""Opt-in integration test: only touches one random synthetic keychain entry."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import uuid

root = pathlib.Path(__file__).resolve().parent.parent
helper = root / 'TokenDeck.app/Contents/Helpers/TokenDeckKeychain'
signing = pathlib.Path.home() / '.config/tokendeck/signing'
identity = (signing / 'identity').read_text().strip()
account = 'tokendeck-helper-test-' + str(uuid.uuid4())

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)

with tempfile.TemporaryDirectory(prefix='tokendeck-helper-test-') as tmp:
    first, second = [pathlib.Path(tmp) / name for name in ['first', 'second']]
    source = root / 'scripts/keychain-helper-probe.swift'
    run('swiftc', source, '-o', first)
    run(first, helper, account, 'untrusted')
    run('swiftc', '-DSECOND_VERSION', source, '-o', second)
    for probe in [first, second]:
        run('codesign', '--force', '--identifier', 'app.tokenusagedashboard.menu',
            '--sign', identity, '--keychain', signing / 'signing.keychain-db', probe)
    app = pathlib.Path(tmp) / 'Probe.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    (app / 'Contents/Helpers').mkdir()
    shutil.copy2(helper, app / 'Contents/Helpers/TokenDeckKeychain')
    main = pathlib.Path(tmp) / 'main.swift'
    shutil.copy2(source, main)
    packaged = app / 'Contents/MacOS/Probe'
    with (app / 'Contents/Info.plist').open('wb') as output:
        plistlib.dump({'CFBundleIdentifier': 'app.tokenusagedashboard.menu',
                      'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL'}, output)
    run('swiftc', '-DPACKAGED_BRIDGE', main, root / 'Sources/UsageBar/KeychainBridge.swift', '-o', packaged)
    run('codesign', '--force', '--sign', identity, '--keychain', signing / 'signing.keychain-db', app)
    try:
        run(first, helper, account, 'create')
        run(first, helper, account, 'verify')
        run(second, helper, account, 'verify')
        run(packaged, helper, account, 'verify')
    finally:
        run(second, helper, account, 'delete')
