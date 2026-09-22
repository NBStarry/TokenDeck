import copy
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).with_name('publish-preview.py'))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PreviewExportTests(unittest.TestCase):
    def setUp(self):
        self.raw = json.loads((publisher.ROOT / 'tauri/src-tauri/tests/fixtures/mac-relay.json').read_text())
        self.selection = {'codexServiceID': 'codex-synthetic-a'}
        for item in self.raw['services']:
            item['config']['title'] = 'PRIVATE_EMAIL@example.test'
            item['config']['credentialFile'] = 'PRIVATE_PATH'
            item['status']['usage']['privateToken'] = 'PRIVATE_TOKEN'
        self.raw['services'][0]['status']['usage']['apiInfo'] = {'models': ['PRIVATE_NESTED_MODEL']}
        self.raw['services'][2]['status']['usage']['resetCredits'] = {'private': 'PRIVATE_NESTED_CREDIT'}

    def test_only_approved_sources_and_fields(self):
        result = publisher.sanitize(self.raw, self.selection)
        self.assertEqual([s['config']['id'] for s in result['services']], ['codex-1', 'deepseek'])
        self.assertEqual(result['services'][0]['status']['usage']['windows'][0]['pct'], 42)
        self.assertEqual(result['services'][1]['status']['usage']['apiInfo']['balances'][1]['total'], 12.34)
        encoded = json.dumps(result)
        for secret in ['PRIVATE_', 'synthetic', 'yicloud', 'Kimi', 'openRouter']:
            self.assertNotIn(secret, encoded)
        self.raw['services'].reverse()
        self.assertEqual(publisher.sanitize(self.raw, self.selection)['services'], result['services'])

    def test_missing_duplicate_and_wrong_source_fail_closed(self):
        for mutation in ['missing', 'duplicate', 'wrong_kind']:
            raw = copy.deepcopy(self.raw)
            if mutation == 'missing':
                raw['services'].pop(0)
            elif mutation == 'duplicate':
                raw['services'].append(raw['services'][0])
            else:
                raw['services'][0]['config']['fetcher'] = 'unsupported'
            with self.assertRaises(ValueError):
                publisher.sanitize(raw, self.selection)

    def test_error_and_bad_values_do_not_publish_fake_zero(self):
        for bad in [True, float('nan'), float('inf'), 'secret']:
            raw = copy.deepcopy(self.raw)
            raw['services'][0]['status']['usage']['windows'][0]['pct'] = bad
            with self.assertRaises(ValueError):
                publisher.sanitize(raw, self.selection)
        self.raw['services'][0]['status'] = {'kind': 'error', 'message': 'PRIVATE_ERROR'}
        with self.assertRaises(ValueError):
            publisher.sanitize(self.raw, self.selection)

    def test_stale_time_and_errors_are_sanitized(self):
        self.raw['ts'] = '2099-01-01T00:00:00Z'
        self.raw['services'][0]['status'].update(kind='stale', cachedAt='2029-12-01T00:00:00Z', error='PRIVATE_ERROR')
        result = publisher.sanitize(self.raw, self.selection)
        self.assertEqual(result['capturedAt'], '2029-12-01T00:00:00Z')
        self.assertNotIn('PRIVATE_ERROR', json.dumps(result))


if __name__ == '__main__':
    unittest.main()
