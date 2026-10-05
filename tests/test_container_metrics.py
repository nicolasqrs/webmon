import json
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ContainerMetricsTests(unittest.TestCase):
    def test_new_container_is_discovered_evaluated_and_exported(self):
        from test_recovery import container
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            shutil.copyfile(ROOT / 'tests/fake-docker.py', root / 'bin/docker')
            (root / 'bin/docker').chmod(0o755)
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
            env.update({
                'FAKE_DOCKER_STATE': str(root / 'docker.json'), 'FAKE_DOCKER_LOG': str(root / 'docker.log'),
                'CONTAINERS_FILE': str(root / 'containers.json'), 'FUNCTIONAL_FILE': str(root / 'functional.json'),
                'HTTP_FUNCTIONAL_FILE': str(root / 'http.json'), 'RECOVERY_POLICIES_FILE': str(root / 'policy.json'),
                'EXPECTED_CONTAINERS_FILE': str(root / 'expected.json'), 'FAILURE_COUNTERS_FILE': str(root / 'counts.json'),
                'FAILURE_STATE_FILE': str(root / 'failures.json'), 'CONTAINER_METRIC_FILE': str(root / 'containers.prom')
            })
            def cycle(containers):
                (root / 'docker.json').write_text(json.dumps({'containers': containers}))
                for script in ('discover-containers.sh', 'evaluate-failures.sh', 'export-container-metrics.sh'):
                    subprocess.run(['sh', str(ROOT / 'scripts' / script)], env=env, capture_output=True, check=True)
            cycle([])
            self.assertNotIn('container="worker"', (root / 'containers.prom').read_text())
            cycle([container(health='healthy')])
            self.assertEqual(json.loads((root / 'containers.json').read_text())[0]['Names'], 'worker')
            self.assertIn('container="worker",docker_state="running",probe="docker-healthcheck",recovery_mode="observe-only"} 1', (root / 'containers.prom').read_text())

    def test_all_states_new_container_and_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state.json'
            metrics = Path(directory) / 'containers.prom'
            env = dict(os.environ, FAILURE_STATE_FILE=str(state), CONTAINER_METRIC_FILE=str(metrics))
            states = [
                {'name': 'web', 'docker_state': 'running', 'status': 'ok', 'source': 'auto-http'},
                {'name': 'db', 'docker_state': 'running', 'status': 'critical', 'source': 'docker-healthcheck', 'failure_confirmed': True},
                {'name': 'new-worker', 'docker_state': 'running', 'status': 'unconfigured'},
                {'name': 'starting', 'docker_state': 'running', 'status': 'starting'},
                {'name': 'missing', 'docker_state': 'missing', 'status': 'critical'}
            ]
            state.write_text(json.dumps(states))
            subprocess.run(['sh', str(ROOT / 'scripts/export-container-metrics.sh')], env=env, check=True)
            text = metrics.read_text()
            self.assertIn('probe="auto-http"', text)
            self.assertIn('container="new-worker",docker_state="running",probe="docker-state",recovery_mode="observe-only"} -1', text)
            self.assertIn('container="missing",docker_state="missing"} 0', text)
            self.assertIn('webmon_container_failure_confirmed{container="db"} 1', text)
            self.assertIn('container="starting",docker_state="running",probe="docker-state",recovery_mode="observe-only"} 2', text)
            states = [states[0], {'name': 'new-site', 'docker_state': 'running', 'status': 'ok', 'source': 'auto-http'}]
            state.write_text(json.dumps(states))
            subprocess.run(['sh', str(ROOT / 'scripts/export-container-metrics.sh')], env=env, check=True)
            self.assertIn('container="new-site"', metrics.read_text())
            self.assertNotIn('container="db"', metrics.read_text())
            self.assertEqual(metrics.stat().st_mode & 0o777, 0o644)

    def test_invalid_snapshot_preserves_previous_metrics(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state.json'
            metrics = Path(directory) / 'containers.prom'
            metrics.write_text('previous_snapshot 1\n')
            state.write_text('{}')
            env = dict(os.environ, FAILURE_STATE_FILE=str(state), CONTAINER_METRIC_FILE=str(metrics))
            result = subprocess.run(['sh', str(ROOT / 'scripts/export-container-metrics.sh')], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(metrics.read_text(), 'previous_snapshot 1\n')

    def test_label_escaping(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state.json'
            metrics = Path(directory) / 'containers.prom'
            state.write_text(json.dumps([{'name': 'test"\\\nname', 'docker_state': 'running', 'status': 'unconfigured'}]))
            env = dict(os.environ, FAILURE_STATE_FILE=str(state), CONTAINER_METRIC_FILE=str(metrics))
            subprocess.run(['sh', str(ROOT / 'scripts/export-container-metrics.sh')], env=env, check=True)
            text = metrics.read_text()
            self.assertIn('container="test\\"\\\\\\nname"', text)

if __name__ == '__main__':
    unittest.main()
