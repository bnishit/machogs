"""Old coding copies: only copies with nothing outside git may be removed."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest

ENGINE = Path(__file__).resolve().parents[1] / 'machogs'


def git(cwd, *args):
    subprocess.run(['git', '-C', str(cwd), *args], check=True, capture_output=True)


class WorktreeTests(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        (self.home / 'Library/Logs').mkdir(parents=True)
        self.repo = self.home / 'dev/app'
        self.repo.mkdir(parents=True)
        git(self.repo, 'init', '-q', '-b', 'main')
        git(self.repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'start')
        (self.repo / '.gitignore').write_text('node_modules/\n.env\n')
        git(self.repo, 'add', '.gitignore')
        git(self.repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'ignore')

    def copy(self, name, detached=False):
        path = self.home / 'copies' / name
        if detached:
            git(self.repo, 'worktree', 'add', '-q', '--detach', str(path))
        else:
            git(self.repo, 'worktree', 'add', '-q', '-b', name, str(path))
        return path

    def run_engine(self, *args, idle='0'):
        env = dict(os.environ, HOME=str(self.home), WORKTREE_IDLE_DAYS=idle)
        return subprocess.run(['/bin/bash', str(ENGINE), 'worktrees', *args, '--json'],
                              capture_output=True, text=True, env=env)

    def verdicts(self, idle='0'):
        r = self.run_engine(idle=idle)
        self.assertEqual(r.returncode, 0, r.stderr)
        return {Path(i['path']).name: (i['verdict'], i['why']) for i in json.loads(r.stdout)['items']}

    def test_only_fully_saved_copies_are_safe(self):
        self.copy('clean')
        rebuildable = self.copy('rebuildable')
        (rebuildable / 'node_modules').mkdir()
        (rebuildable / 'node_modules/x.js').write_text('x')
        (self.copy('dirty') / 'notes.txt').write_text('unsaved')
        (self.copy('secrets') / '.env').write_text('KEY=1')
        lone = self.copy('lone', detached=True)
        git(lone, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'only here')
        v = self.verdicts()
        self.assertEqual(v['clean'][0], 'safe')
        self.assertEqual(v['rebuildable'][0], 'safe')
        self.assertIn('not committed', v['dirty'][1])
        self.assertIn('.env', v['secrets'][1])
        self.assertIn('only in this copy', v['lone'][1])
        self.assertNotIn('app', v, 'the main checkout is never listed')

    def test_recent_copies_stay(self):
        self.copy('fresh')
        self.assertIn('Used in the last', self.verdicts(idle='3')['fresh'][1])

    def test_remove_rechecks_and_keeps_the_branch(self):
        clean = self.copy('clean')
        dirty = self.copy('dirty')
        (dirty / 'notes.txt').write_text('unsaved')
        refused = self.run_engine('remove', str(dirty))
        self.assertEqual(refused.returncode, 3)
        self.assertTrue((dirty / 'notes.txt').exists())
        self.assertEqual(self.run_engine('remove', str(self.repo)).returncode, 3, 'never the main checkout')
        self.assertEqual(self.run_engine('remove', str(self.home / 'elsewhere')).returncode, 3)
        done = self.run_engine('remove', str(clean))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(clean.exists())
        branches = subprocess.run(['git', '-C', str(self.repo), 'branch'], capture_output=True, text=True).stdout
        self.assertIn('clean', branches)
        self.assertIn('Old coding copy of app (clean)', (self.home / 'Library/Logs/machogs.log').read_text())


if __name__ == '__main__':
    unittest.main()
