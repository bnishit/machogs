"""Exercise CLI consent and guarded closes; every signal and process is mocked."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ENGINE_PATH = Path(__file__).resolve().parents[1] / 'machogs'
ENGINE = ENGINE_PATH.read_text()
FLOW = ENGINE[ENGINE.index('KILLED=0; FOUND=0;'):ENGINE.index('# Printing a section header')]

MOCKS = r'''
set -uo pipefail
MODE=fix
DIM=''; NC=''; YLW=''; RED=''; GRN=''; BLD=''
SELF_SAFE=''; CLAUDE_SAFE=''; AGENT_SAFE=''
BECOMES_PROTECTED=''; GONE=''; CHANGED=''; FAILED=''
count_unit() { printf '%s %ss' "$1" "$2"; }
claude_app_pids() { :; }
codex_app_pids() { printf '%s' "$BECOMES_PROTECTED"; }
alive() { case " $GONE " in *" $1 "*) return 1;; *) return 0;; esac; }
protected() { case " $AGENT_SAFE " in *" $1 "*) return 0;; *) return 1;; esac; }
identity_of() { case " $CHANGED " in *" $1 "*) echo changed;; *) echo "identity-$1";; esac; }
whose() { echo "Owner-$1"; }
whatis() { echo "Helper-$1"; }
cpu_of() { case "$1" in 101) echo 12.5;; 102) echo 80.0;; *) echo 25.0;; esac; }
cputime_of() { case "$1" in 101) echo 100;; 102) echo 900;; *) echo 300;; esac; }
logclose() { printf 'LOG %s %s %s %s %s\n' "$@"; }
# This function shadows the shell builtin; no test can signal a real process.
kill() {
  [ "$1" = '-9' ] || { echo 'UNEXPECTED SIGNAL FORM'; return 99; }
  echo "SIGNAL $2"
  case " $FAILED " in *" $2 "*) return 1;; *) return 0;; esac
}
'''


class CLIFlowTests(unittest.TestCase):
    def run_flow(self, tail, input_text=''):
        with tempfile.TemporaryDirectory() as directory:
            rows = Path(directory) / 'rows.tsv'
            rows.write_text(''.join(
                f'{pid}\t2\treapable\t999\t01:00\tscan finding\t99999\tidentity-{pid}\n'
                for pid in (101, 102, 303)))
            result = subprocess.run(
                ['/bin/bash', '-c', MOCKS + '\n' + FLOW + '\nROWS=$1\n' + tail,
                 'test', str(rows)], input=input_text, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn('UNEXPECTED SIGNAL FORM', result.stdout)
        return result.stdout

    def close(self, setup='', targets='101'):
        return self.run_flow(setup + '\nclose_reviewed_group "' + targets + '"\n' +
                             'printf "TOTAL %s %s %s\\n" "$KILLED" "$FREED_CPU" "$FREED_CSEC"')

    def test_prompt_accepts_yes_skip_stop_and_eof(self):
        for answer, expected in [('y\n', 0), ('yes\n', 0), ('YES\n', 0),
                                 ('n\n', 1), ('no\n', 1), ('\n', 1),
                                 ('q\n', 2), ('QUIT\n', 2), ('', 2)]:
            with self.subTest(answer=answer):
                output = self.run_flow('ask_close 2; result=$?; echo "ANSWER $result"', answer)
                self.assertIn(f'ANSWER {expected}', output)
                self.assertNotIn('SIGNAL ', output)

    def test_invalid_answer_reprompts_without_consent(self):
        output = self.run_flow('ask_close 1; result=$?; echo "ANSWER $result"', 'maybe\ny\n')
        self.assertEqual(output.count('Close '), 2)
        self.assertIn('Choose y', output)
        self.assertIn('ANSWER 0', output)
        self.assertNotIn('SIGNAL ', output)

    def test_invalid_answer_then_eof_stops(self):
        output = self.run_flow('ask_close 1; result=$?; echo "ANSWER $result"', 'maybe\n')
        self.assertIn('ANSWER 2', output)
        self.assertNotIn('SIGNAL ', output)

    def test_ordinary_flush_in_fix_mode_cannot_close_before_review(self):
        output = self.run_flow('KILL_LIST=("101|identity-101|unreviewed"); flush_kills; echo DONE')
        self.assertNotIn('SIGNAL ', output)

    def test_new_protection_is_refreshed_after_prompt(self):
        output = self.close('BECOMES_PROTECTED=101')
        self.assertIn('became protected', output)
        self.assertNotIn('SIGNAL ', output)
        self.assertIn('TOTAL 0 0 0', output)

    def test_reused_identity_is_not_closed(self):
        output = self.close('CHANGED=101')
        self.assertIn('identity changed', output)
        self.assertNotIn('SIGNAL ', output)
        self.assertIn('TOTAL 0 0 0', output)

    def test_already_gone_is_not_signalled_or_counted(self):
        output = self.close('GONE=101')
        self.assertNotIn('SIGNAL ', output)
        self.assertNotIn('LOG ', output)
        self.assertIn('TOTAL 0 0 0', output)

    def test_failed_signal_has_no_success_log_or_savings(self):
        output = self.close('FAILED=101')
        self.assertIn('SIGNAL 101', output)
        self.assertNotIn('LOG ', output)
        self.assertIn('TOTAL 0 0 0', output)

    def test_partial_success_uses_only_successful_process_measurements(self):
        output = self.close('FAILED=102', targets='101 102')
        self.assertIn('LOG 101 Owner-101 Helper-101 12.5 100', output)
        self.assertNotIn('LOG 102', output)
        self.assertIn('TOTAL 1 12.5 100', output)
        self.assertNotIn('99999', output, 'Scan-era group totals must not become per-process receipts')

    def test_approval_cannot_flush_other_queued_groups(self):
        output = self.close('KILL_LIST=("303|identity-303|not approved")')
        self.assertIn('SIGNAL 101', output)
        self.assertNotIn('SIGNAL 303', output)
        self.assertIn('TOTAL 1 12.5 100', output)

    def test_pid_without_reviewed_scan_identity_is_not_closed(self):
        output = self.close(targets='404')
        self.assertNotIn('SIGNAL ', output)
        self.assertIn('TOTAL 0 0 0', output)

    def test_help_exits_before_scanning(self):
        result = subprocess.run(['/bin/bash', str(ENGINE_PATH), '--help'],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('machogs fix', result.stdout)
        self.assertIn('machogs --json', result.stdout)
        self.assertNotIn('=== machogs ===', result.stdout)

    def test_fix_without_terminal_refuses_before_scanning(self):
        result = subprocess.run(['/bin/bash', str(ENGINE_PATH), 'fix'],
                                input='yes\n', text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('needs a terminal', result.stderr)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
