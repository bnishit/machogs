"""Exercise the real engine's safety and duplicate paths with fake processes.

No real processes are started or signalled. Run: python3 -m unittest discover -s tests
"""
from pathlib import Path
import subprocess
import unittest

ENGINE = (Path(__file__).resolve().parents[1] / 'machogs').read_text()
HELPERS = ENGINE.split('# ---- helpers ')[1].split('# ---- blame / brag ')[0]
HELPERS = HELPERS[HELPERS.index('ppid_of()'):]
QUEUE = ENGINE[ENGINE.index('KILLED=0; FOUND=0;'):ENGINE.index('# ---- 0. system health')]
DUPLICATES = ENGINE[ENGINE.index('# ---- 2b. duplicate'):ENGINE.index('# ---- 3. headless')]

MOCKS = r'''
set -uo pipefail
SELF_SAFE=''; CLAUDE_SAFE=''; AGENT_SAFE=''
MCP_PATTERNS='playwright-mcp'; NOT_MCP='--type=|Google Chrome'
TARGETS=''; TAB=$'\t'; DIM=''; NC=''; BLD=''; YLW=''; RED=''; GRN=''; BLU=''
MODE=report
ps() {
  local pid="${@: -1}"
  case "$*" in
    '-o ppid='*) case "$pid" in 101|102) echo 50;; 50) echo 20;; *) echo 1;; esac;;
    '-o comm='*) case "$pid" in 20) echo "$APP_COMMAND";; *) echo node;; esac;;
    '-o command='*) case "$pid" in 101|102) echo 'node playwright-mcp';; *) echo "$APP_COMMAND";; esac;;
    '-o pcpu='*) echo 0;;
    '-o etime='*) echo 02:00:00;;
    *) echo 'stable identity';;
  esac
}
pgrep() {
  if [ "$1" = '-P' ]; then return 1; fi
  if [ "$2" = "$MCP_PATTERNS" ]; then printf '101\n102\n'; return; fi
  printf '%s\n' "$APP_COMMAND" | grep -qE -- "$2" && echo 20
}
# No invocation can reach the system kill command.
kill() { [ "$1" = '-0' ] || { echo 'UNEXPECTED SIGNAL'; return 99; }; }
row() { printf 'ROW %s %s\n' "$1" "$3"; }
'''


class SessionSafetyTests(unittest.TestCase):
    def run_engine(self, app, dupes=0, tail=''):
        result = subprocess.run(
            ['/bin/bash', '-c', MOCKS + '\nAPP_COMMAND=$1\n' + HELPERS + '\n' +
             QUEUE + f'\nDUPES={dupes}\n' + DUPLICATES + '\n' + tail + '\ntrue', 'test', app],
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn('UNEXPECTED SIGNAL', result.stdout)
        return result.stdout

    def test_coding_apps_and_cli_protect_duplicate_helpers_in_both_modes(self):
        for app in ['/Applications/Codex.app/Contents/MacOS/Codex',
                    '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT',
                    '/opt/homebrew/bin/codex',
                    '/vendor/codex-aarch64-apple-darwin',
                    '/vendor/codex-x86_64-apple-darwin',
                    '/Applications/Claude.app/Contents/MacOS/Claude']:
            for dupes in [0, 1]:
                with self.subTest(app=app, dupes=dupes):
                    output = self.run_engine(app, dupes, 'MODE=kill; flush_kills; echo DONE')
                    self.assertIn('ROW 101 protected', output)
                    self.assertNotIn('ROW 101 reapable', output)

    def test_unrelated_apps_are_still_reported(self):
        for app in ['/Applications/Other.app/Contents/MacOS/Other', '/bin/codex-helper']:
            for dupes, action in [(0, 'needs-dupes-flag'), (1, 'reapable')]:
                with self.subTest(app=app, dupes=dupes):
                    self.assertIn('ROW 101 ' + action, self.run_engine(app, dupes))

    def test_fresh_protection_stops_an_already_queued_close(self):
        output = self.run_engine('/Applications/Other.app/Contents/MacOS/Other', 1,
                                 'AGENT_SAFE=" 20 "; MODE=kill; flush_kills; echo DONE')
        self.assertIn('became protected before close', output)

    def test_reused_process_identity_stops_an_already_queued_close(self):
        output = self.run_engine('/Applications/Other.app/Contents/MacOS/Other', 1,
                                 'identity_of() { echo changed; }; MODE=kill; flush_kills; echo DONE')
        self.assertIn('process identity changed before close', output)


if __name__ == '__main__':
    unittest.main()
