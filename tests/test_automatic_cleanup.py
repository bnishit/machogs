"""The automatic path must fail closed; all process and signal calls are fakes."""
from pathlib import Path
import subprocess
import unittest

ENGINE = (Path(__file__).resolve().parents[1] / 'machogs').read_text()
RULE = ENGINE[ENGINE.index('abandoned_helper()'):ENGINE.index('# ---- blame / brag')]
FLUSH = ENGINE[ENGINE.index('flush_kills()'):ENGINE.index('# Reuse the guarded close path')]
MOCK = r'''
set -uo pipefail
PARENT=1; UID_VALUE=501; TTY_VALUE='??'; CPU=0; CHILD_STATUS=1
JOB=''; FAIL_HANDLES=0; LIVE=0; CURRENT_ID=stable; SIGNAL_FAIL=0; STAYS=0
HANDLES=$'p101\nfcwd\ntDIR\nn/tmp\nf0\ntCHR\nn/dev/null\nf1\ntCHR\nn/dev/null'
is_mcp() { [ "$LIVE" != 2 ]; }
ps() { case "$*" in *uid=*) echo "$UID_VALUE";; *tty=*) echo "$TTY_VALUE";; esac; }
id() { echo 501; }
ppid_of() { echo "$PARENT"; }
cpu_of() { echo "$CPU"; }
launchctl() { printf '%s\n' "$JOB"; }
pgrep() { return "$CHILD_STATUS"; }
lsof() { [ "$FAIL_HANDLES" = 0 ] || return 1; printf '%s\n' "$HANDLES"; }
protected() { [ "$LIVE" = 1 ]; }
claude_app_pids() { :; }
codex_app_pids() { :; }
identity_of() { echo "$CURRENT_ID"; }
ABANDONED_ONLY=1; MODE=kill; YLW=''; NC=''; DIM=''; RED=''
KILL_LIST=('101|stable|abandoned'); KILLED=0; KILLED_PIDS=''; FREED_CPU=0; FREED_CSEC=0
TERMINATED=0
alive() { [ "$TERMINATED" = 0 ] || [ "$STAYS" = 1 ]; }
whose() { echo Fixture; }; whatis() { echo helper; }; cputime_of() { echo 0; }
logclose() { echo RECEIPT; }
sleep() { :; }
kill() {
  [ "$1" = -TERM ] || { echo WRONG_SIGNAL; return 99; }
  echo TERM
  [ "$SIGNAL_FAIL" = 0 ] || return 1
  TERMINATED=1
}
'''

class AutomaticCleanupTests(unittest.TestCase):
    def run_rule(self, setup='', close=False):
        tail = 'flush_kills; echo COUNT=$KILLED' if close else 'abandoned_helper 101; echo ELIGIBLE=$?'
        r = subprocess.run(['/bin/bash', '-c', MOCK + RULE + FLUSH + setup + '\n' + tail], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('WRONG_SIGNAL', r.stdout)
        return r.stdout

    def test_disconnected_orphan_is_eligible(self):
        self.assertIn('ELIGIBLE=0', self.run_rule())

    def test_uncertain_or_live_helpers_are_never_eligible(self):
        for setup in ['PARENT=20', 'UID_VALUE=0', "TTY_VALUE=ttys001", 'CPU=5',
                      'CHILD_STATUS=0', 'CHILD_STATUS=2', "JOB='101 0 service.label'",
                      'FAIL_HANDLES=1', "HANDLES=''", 'LIVE=1', 'LIVE=2',
                      "HANDLES=$'p101\\nf0\\ntPIPE\\nnpipe'",
                      "HANDLES=$'p101\\nf5\\ntIPv4\\nnlocalhost:1234'",
                      "HANDLES=$'p101\\nf1\\ntREG\\nn/work/result.txt'",
                      "HANDLES=$'p101\\nf0\\nn/dev/null'",
                      "HANDLES=$'p101\\nf0\\ntCHR'",
                      "HANDLES=$'p101\\nf3\\ntunix\\nconnected'",
                      "HANDLES=$'p101\\nf3\\ntKQUEUE'",
                      "HANDLES=$'p999\\nf0\\ntCHR\\nn/dev/null'"]:
            with self.subTest(setup=setup):
                self.assertIn('ELIGIBLE=1', self.run_rule(setup))
                self.assertNotIn('TERM\n', self.run_rule(setup, close=True))

    def test_identity_is_rechecked_and_new_connections_block_close(self):
        self.assertNotIn('TERM\n', self.run_rule('CURRENT_ID=reused', close=True))
        self.assertNotIn('TERM\n', self.run_rule('PARENT=22', close=True))

    def test_graceful_exit_is_confirmed_before_receipt(self):
        output = self.run_rule(close=True)
        self.assertIn('TERM\n', output)
        self.assertIn('COUNT=1', output)
        self.assertIn('RECEIPT', output)

    def test_refusal_or_still_running_has_no_success_receipt(self):
        for setup in ['SIGNAL_FAIL=1', 'STAYS=1']:
            output = self.run_rule(setup, close=True)
            self.assertIn('COUNT=0', output)
            self.assertNotIn('RECEIPT', output)

    def test_automatic_cli_requires_exact_targets_to_close(self):
        r = subprocess.run(['/bin/bash', '-c', ENGINE, 'machogs', 'kill', '--abandoned-only', '--json'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn('exact targets', r.stderr)
