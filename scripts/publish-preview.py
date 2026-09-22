#!/usr/bin/env python3
"""Export only the locally approved accounts; publish a dedicated Pages branch."""
import argparse
import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = Path.home() / '.config/usage-bar'
CACHE = Path.home() / 'Library/Caches/TokenDeck-preview'
REPO = 'https://github.com/NBStarry/TokenDeck.git'


def stamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            return None
        return parsed.astimezone(dt.timezone.utc).isoformat().replace('+00:00', 'Z')
    except ValueError:
        return None


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError('Invalid numeric usage')
    return value


def count(value):
    result = number(value)
    if result < 0 or int(result) != result:
        raise ValueError('Invalid count')
    return int(result)


def clean_usage(raw, kind):
    result = {'windows': [], 'plan': None, 'balance': None}
    if kind == 'codexWham':
        if raw.get('plan') in ('Free', 'Plus', 'Pro', 'Team', 'Business', 'Enterprise', 'Edu'):
            result['plan'] = raw['plan']
        for window in raw.get('windows', []):
            if window.get('label') not in ('周', '5 小时'):
                continue
            result['windows'].append({'label': window['label'], 'pct': number(window['pct']),
                                      'resetAt': stamp(window.get('resetAt'))})
        credits = raw.get('resetCredits')
        if isinstance(credits, dict):
            safe = {'availableCount': count(credits['availableCount'])}
            if credits.get('applicableCount') is not None:
                safe['applicableCount'] = count(credits['applicableCount'])
            if isinstance(credits.get('credits'), list):
                safe['credits'] = [{'expiresAt': stamp(c.get('expiresAt')), 'applicable': c.get('applicable') is True}
                                   for c in credits['credits']]
            result['resetCredits'] = safe
    else:
        info = raw.get('apiInfo', {})
        balances = []
        for balance in info.get('balances', []):
            if balance.get('currency') not in ('CNY', 'USD'):
                raise ValueError('Unsupported currency')
            balances.append({'currency': balance['currency'], **{k: number(balance[k]) for k in ('total', 'toppedUp', 'granted')}})
        if not balances:
            raise ValueError('Missing DeepSeek balance')
        result['apiInfo'] = {'balances': balances}
        if isinstance(info.get('isAvailable'), bool):
            result['apiInfo']['isAvailable'] = info['isAvailable']
    return result


def sanitize(snapshot, selection):
    selected = [('codexWham', selection['codexServiceID'], 'codex-1', 'Codex · 个人账号', '#10A37F'),
                ('deepseek', 'deepseek', 'deepseek', 'DeepSeek', '#4D6BFE')]
    services, dates = [], []
    for kind, source_id, public_id, title, accent in selected:
        matches = [s for s in snapshot['services'] if s.get('config', {}).get('id') == source_id
                   and s['config'].get('fetcher') == kind]
        if len(matches) != 1:
            raise ValueError('Approved service missing or ambiguous; no fallback allowed')
        raw = matches[0]['status']
        state = raw.get('kind')
        if state not in ('ok', 'stale'):
            raise ValueError('Approved service has no usage; keep previously published snapshot')
        date_key = 'fetchedAt' if state == 'ok' else 'cachedAt'
        timestamp = stamp(raw.get(date_key))
        if not timestamp:
            raise ValueError('Missing usage timestamp')
        dates.append(timestamp)
        status = {'kind': state, date_key: timestamp, 'usage': clean_usage(raw['usage'], kind)}
        if state == 'stale':
            status['error'] = '上次数据'
        display = {k: True for k in ('plan', 'fiveHour', 'weekly', 'resetCountdown', 'updatedAt', 'balance', 'used', 'requestCount')}
        display['models'] = False
        services.append({'config': {'id': public_id, 'title': title, 'accent': accent, 'fetcher': kind,
                                     'category': 'subscription' if kind == 'codexWham' else 'apiUsage',
                                     'enabled': True, 'credentialFile': None, 'display': display},
                         'status': status, 'isCurrentAccount': False})
    return {'schemaVersion': 1, 'mode': 'live', 'capturedAt': min(dates),
            'publishedAt': dt.datetime.now(dt.timezone.utc).isoformat(), 'services': services}


def read_local():
    relay = json.loads((CONFIG / 'relay.json').read_text())
    port = relay['port']
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('Invalid relay port')
    request = urllib.request.Request(f'http://127.0.0.1:{port}/usage',
                                     headers={'Authorization': 'Bearer ' + relay['secret']})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=10) as response:
        snapshot = json.load(response)
    return sanitize(snapshot, json.loads((CONFIG / 'preview.json').read_text()))


def run(*args, cwd=None, input=None):
    result = subprocess.run(args, cwd=cwd, input=input, text=True, capture_output=True, timeout=90)
    if result.returncode:
        # Git/HTTP output is deliberately not copied to public files or scheduler logs.
        raise RuntimeError('Command failed: ' + args[0])
    return result.stdout.strip()


def publish(data):
    build = ROOT / 'tauri/build-preview'
    if not (build / 'index.html').is_file():
        raise ValueError('Build the preview first')
    # Copy only this dedicated static build. Never use a checkout or home directory as deployment root.
    with tempfile.TemporaryDirectory(prefix='publish-', dir=CACHE) as directory:
        target = Path(directory)
        shutil.copytree(build, target, dirs_exist_ok=True)
        (target / 'usage.json').write_text(json.dumps(data, ensure_ascii=False, allow_nan=False) + '\n')
        (target / '.nojekyll').touch()
        run('git', 'init', '-q', '-b', 'gh-pages', cwd=target)
        run('git', 'remote', 'add', 'origin', REPO, cwd=target)
        existing = run('git', 'ls-remote', 'origin', 'refs/heads/gh-pages', cwd=target)
        parent = None
        if existing:
            run('git', 'fetch', '--quiet', '--depth=1', 'origin', 'gh-pages', cwd=target)
            parent = run('git', 'rev-parse', 'FETCH_HEAD', cwd=target)
            old_text = run('git', 'show', f'{parent}:usage.json', cwd=target)
            old = json.loads(old_text)
            old.pop('publishedAt', None)
            comparable = dict(data)
            comparable.pop('publishedAt', None)
            # The same sample may recur while the app sleeps; don't repeatedly publish it as fresh.
            if old == comparable:
                old_tree = run('git', 'rev-parse', f'{parent}^{{tree}}', cwd=target)
                (target / 'usage.json').write_text(old_text + '\n')
            else:
                old_tree = None
        else:
            old_tree = None
        run('git', 'add', '--all', cwd=target)
        tree = run('git', 'write-tree', cwd=target)
        if tree == old_tree:
            return 'Snapshot unchanged'
        args = ['git', '-c', 'user.name=TokenDeck Preview', '-c', 'user.email=preview@users.noreply.github.com', 'commit-tree', tree]
        if parent:
            args += ['-p', parent]
        commit = run(*args, input='Update approved usage preview\n', cwd=target)
        run('git', 'update-ref', 'refs/heads/gh-pages', commit, cwd=target)
        # Fast-forward only. A concurrent publisher cannot overwrite a newer branch head.
        run('git', 'push', '--quiet', 'origin', 'gh-pages:gh-pages', cwd=target)
        return 'Published approved preview snapshot'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, help='Write a sanitized local snapshot instead of publishing')
    args = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / 'publish.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Publisher already running')
            return
        try:
            data = read_local()
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False) + '\n')
                print('Exported two approved services')
            else:
                print(publish(data))
        except Exception as error:
            print('Preview update failed; previous snapshot retained (' + type(error).__name__ + ')')
            raise SystemExit(1)


if __name__ == '__main__':
    main()
