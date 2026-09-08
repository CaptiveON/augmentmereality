import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('baseline', Path(__file__).with_name('ar-baseline.py'))
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


class ReportTests(unittest.TestCase):
    def fixture(self):
        return {'schemaVersion': 2, 'runID': 'test', 'exportedUptime': 1000, 'epochs': [
            {'id': 1, 'kind': 'coldStart', 'generation': 1, 'intentUptime': 100,
             'series': [{'name': 'sceneUpdateProxy.interval', 'totalCount': 27000,
                         'meanMilliseconds': 1000 / 30,
                         'wholeEpochHistogram': {'p95UpperBoundMilliseconds': 34,
                                                 'p99UpperBoundMilliseconds': 40, 'overflowCount': 1}}]}]}

    def test_proxy_never_becomes_presented_success(self):
        text = baseline.summarize(self.fixture())
        self.assertIn('Actual presentation: **unmeasured**', text)
        self.assertIn('observation through 15 minutes', text)
        self.assertIn('sceneUpdateProxy.interval | 27000', text)
        self.assertIn('30.00 | 34.00 | 40.00 | 1', text)
        self.assertIn('screen recording is confirmed off', text)

    def test_missing_milestones_and_cpu_are_not_zero(self):
        text = baseline.summarize(self.fixture())
        self.assertIn('selectedAssetReady | unmeasured', text)
        self.assertIn('firstHeroSceneUpdateProxy | unmeasured', text)
        self.assertIn('CPU seconds across retained system samples: unmeasured', text)

    def test_serious_event_survives_missing_recent_system_samples(self):
        data = self.fixture()
        data['epochs'][0]['firstEventsByName'] = {'thermalSeriousOrCritical': {'details': 'state=2'}}
        self.assertIn('**serious/critical observed**', baseline.summarize(data))

    def test_schema_one_does_not_invent_full_run_percentiles(self):
        data = self.fixture()
        data['schemaVersion'] = 1
        del data['epochs'][0]['series'][0]['wholeEpochHistogram']
        text = baseline.summarize(data)
        self.assertIn('30.00 | unmeasured | unmeasured | unmeasured', text)

    def test_unknown_schema_and_nonfinite_values(self):
        with self.assertRaises(ValueError):
            baseline.summarize({'schemaVersion': 9})
        self.assertEqual(baseline.number(float('nan')), 'unmeasured')
        self.assertEqual(baseline.number(float('inf')), 'unmeasured')


if __name__ == '__main__':
    unittest.main()
