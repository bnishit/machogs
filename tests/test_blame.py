"""Exercise blame/brag --since and blame --json against a throwaway log.

Read-only: blame and brag touch no processes. Run: python3 -m unittest discover -s tests
"""
from datetime import datetime
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ENGINE = Path(__file__).resolve().parents[1] / 'machogs'


class BlameTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        logs = Path(self.home.name) / 'Library' / 'Logs'
        logs.mkdir(parents=True)
        self.log = logs / 'machogs.log'
        # GNU mktemp rejects the BSD-style template the engine uses on macOS.
        shim = Path(self.home.name) / 'bin'
        shim.mkdir()
        (shim / 'mktemp').write_text('#!/bin/sh\nexec /usr/bin/mktemp\n')
        (shim / 'mktemp').chmod(stat.S_IRWXU)
        self.env = dict(os.environ, HOME=self.home.name,
                        PATH=f"{shim}{os.pathsep}{os.environ['PATH']}")

    def run_engine(self, *args):
        return subprocess.run([str(ENGINE), *args], env=self.env,
                              text=True, capture_output=True)

    def write_log(self):
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        self.log.write_text(
            '2020-01-01 10:00:00\tclosed\t1\tOld"App\thelper\t0\t500\n'
            f'{now}\tclosed\t2\tCursor\thelper\t90\t20000\n'
            f'{now}\tclosed\t3\tChatGPT\thelper\t0\t40\n'
            f'{now}\tclosed\t4\tChatGPT\thelper\t0\t60\n')

    def test_json_lists_every_app_worst_first(self):
        self.write_log()
        result = self.run_engine('blame', '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertIsNone(data['since'])
        self.assertEqual(data['first_seen'], '2020-01-01')
        self.assertEqual([a['app'] for a in data['apps']], ['ChatGPT', 'Cursor', 'Old"App'])
        self.assertEqual(data['apps'][0]['cpu_seconds'], 100)
        self.assertEqual(data['apps'][0]['worst_cpu_seconds'], 60)
        self.assertEqual(data['total'], {'closed': 4, 'cpu_seconds': 20600})

    def test_since_drops_old_closes(self):
        self.write_log()
        data = json.loads(self.run_engine('blame', '--json', '--since=7d').stdout)
        self.assertIsNotNone(data['since'])
        self.assertNotIn('Old"App', [a['app'] for a in data['apps']])
        self.assertEqual(data['total']['closed'], 3)
        text = self.run_engine('blame', '--since=7').stdout
        self.assertIn('last 7 days', text)
        self.assertNotIn('Old"App', text)

    def test_since_with_nothing_in_window(self):
        self.log.write_text('2020-01-01 10:00:00\tclosed\t1\tX\thelper\t0\t5\n')
        result = self.run_engine('brag', '--since=7d')
        self.assertEqual(result.returncode, 0)
        self.assertIn('Nothing closed in the last 7 days', result.stdout)

    def test_empty_log_json(self):
        data = json.loads(self.run_engine('blame', '--json').stdout)
        self.assertEqual(data['apps'], [])
        self.assertEqual(data['total']['closed'], 0)

    def test_bad_since_is_usage_error(self):
        for args in (['blame', '--since=0'], ['blame', '--since=week'], ['--since=7d']):
            with self.subTest(args=args):
                self.assertEqual(self.run_engine(*args).returncode, 2)


if __name__ == '__main__':
    unittest.main()
