import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/slow':
            time.sleep(1.2)
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/ok')
        else:
            self.send_response(503 if self.path == '/bad' else 200)
        self.end_headers()
    def log_message(self, *args):
        pass

class WebsiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f'http://127.0.0.1:{cls.server.server_port}'
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.env = dict(os.environ, WEBSITES_CONFIG_FILE=str(self.dir/'config.json'),
            WEBSITES_STATE_FILE=str(self.dir/'state.json'), WEBSITES_METRIC_FILE=str(self.dir/'websites.prom'))
    def run_probe(self, sites, success=True):
        (self.dir/'config.json').write_text(json.dumps(sites))
        result = subprocess.run(['sh', str(ROOT/'scripts/check-websites.sh')], env=self.env,
            capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return json.loads((self.dir/'state.json').read_text()) if success else None
    def site(self, path='/ok', **kw):
        return dict(name='Site "test"', url=self.url+path, **kw)
    def test_success_redirect_and_custom_expected_code(self):
        sites=[self.site(), dict(self.site('/redirect'),name='redirect'),
               dict(self.site('/bad',expected_status=503),name='custom')]
        states=self.run_probe(sites)
        self.assertEqual([s['functional'] for s in states],[1,1,1])
        metrics=(self.dir/'websites.prom').read_text()
        self.assertIn('webmon_website_up{site="Site \\"test\\""} 1',metrics)
        self.assertNotIn(self.url, metrics)
    def test_failure_confirmation_and_recovery(self):
        sites=[self.site('/bad',failure_threshold=2)]
        self.assertEqual(self.run_probe(sites)[0]['failure_confirmed'],0)
        self.assertEqual(self.run_probe(sites)[0]['failure_confirmed'],1)
        recovered=self.run_probe([self.site()])[0]
        self.assertEqual(recovered['consecutive_failures'],0)
        self.assertEqual(recovered['functional'],1)
    def test_timeout_is_failure_even_when_status_is_200(self):
        state=self.run_probe([self.site('/slow',timeout_seconds=1,failure_threshold=1)])[0]
        self.assertEqual(state['functional'],0)
        self.assertEqual(state['curl_exit_code'],28)
        self.assertEqual(state['failure_confirmed'],1)
    def test_removed_site_and_empty_configuration(self):
        self.run_probe([self.site()])
        self.assertEqual(self.run_probe([]),[])
        self.assertNotIn('webmon_website_up{', (self.dir/'websites.prom').read_text())
    def test_invalid_configuration_preserves_snapshot(self):
        self.run_probe([self.site()])
        original=(self.dir/'websites.prom').read_text()
        self.run_probe([self.site(''), self.site('')],success=False)
        self.run_probe([dict(self.site(),url='file:///etc/passwd')],success=False)
        self.run_probe([self.site(timeout_seconds=0)],success=False)
        self.assertEqual((self.dir/'websites.prom').read_text(),original)
    def test_change_target_resets_failure_count(self):
        self.run_probe([self.site('/bad',failure_threshold=2)])
        state=self.run_probe([self.site('/bad?new',expected_status=201,failure_threshold=2)])[0]
        self.assertEqual(state['consecutive_failures'],1)
        self.assertEqual(state['failure_confirmed'],0)

if __name__ == '__main__':
    unittest.main()
