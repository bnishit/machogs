"""Fixed-schema CLI telemetry contract. Never scans or closes a real process."""
import json, os, subprocess, tempfile, unittest
from pathlib import Path
class TelemetryTests(unittest.TestCase):
    def test_default_off_and_opt_in_payload(self):
        source=(Path(__file__).resolve().parents[1]/'machogs').read_text()
        function=source[source.index('usage_event() {'):source.index('machogs_exit() {')]
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); captured=root/'payload'
            mock=root/'curl';mock.write_text('#!/bin/bash\nwhile [ "$#" -gt 0 ]; do\n if [ "$1" = --data ]; then shift; printf "%s" "$1" > "$CAPTURE"; fi\n shift\ndone\n');mock.chmod(0o700)
            env={**os.environ,'PATH':str(root)+':'+os.environ['PATH'],'CAPTURE':str(captured),'MACHOGS_TELEMETRY_STATE_DIR':str(root/'state'),'MACHOGS_ANALYTICS':'0'}
            script=function+'\nMODE=report\nusage_event 10\nwait\n'
            subprocess.run(['bash','-c',script],env=env,check=True)
            self.assertFalse(captured.exists());self.assertFalse((root/'state').exists())
            env['MACHOGS_ANALYTICS']='1';subprocess.run(['bash','-c',script],env=env,check=True)
            data=json.loads(captured.read_text())
            self.assertEqual(data['event'],'cli.report');self.assertEqual(data['outcome'],'success')
            self.assertEqual(set(data),{'id','install_id','consent','event','version','feature','outcome'})
            self.assertEqual((root/'state/analytics-install-id').stat().st_mode&0o777,0o600)
            subprocess.run(['bash','-c',function+'\nMODE=unknown\nusage_event 0\nwait\n'],env=env,check=True)
            self.assertEqual(json.loads(captured.read_text())['id'],data['id'])
if __name__=='__main__':unittest.main()
