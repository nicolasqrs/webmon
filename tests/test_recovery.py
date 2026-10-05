import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

def container(status='running', health=None):
    result = {
        'Id': 'a' * 64, 'Image': 'sha256:demo', 'Name': '/worker',
        'Config': {'Image': 'busybox:1.37', 'Env': ['TOKEN=demo'], 'Labels': {},
                   'Entrypoint': ['/bin/sh'], 'Cmd': ['-c', 'sleep 100'], 'User': '', 'WorkingDir': ''},
        'State': {'Status': status},
        'HostConfig': {'RestartPolicy': {'Name': 'unless-stopped'}, 'PortBindings': {}},
        'Mounts': [{'Type': 'volume', 'Name': 'data', 'Destination': '/data', 'RW': True}],
        'NetworkSettings': {'Networks': {'network-a': {'Aliases': ['worker-alias']}}}
    }
    if health:
        result['Config']['Healthcheck'] = {'Test': ['CMD-SHELL', 'test -f /data/heartbeat'], 'Interval': 5000000000, 'Retries': 3}
        result['State']['Health'] = {'Status': health}
    return result

class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        (self.path / 'bin').mkdir()
        shutil.copyfile(ROOT / 'tests/fake-docker.py', self.path / 'bin/docker')
        (self.path / 'bin/docker').chmod(0o755)
        self.state = {'containers': [container()], 'images': ['sha256:demo', 'busybox:1.37'], 'volumes': ['data'], 'networks': ['network-a', 'network-b']}
        self.env = dict(os.environ, PATH=str(self.path / 'bin') + os.pathsep + os.environ['PATH'])
        self.env.update({
            'FAKE_DOCKER_STATE': str(self.path / 'docker.json'), 'FAKE_DOCKER_LOG': str(self.path / 'docker.log'),
            'CONTAINERS_FILE': str(self.path / 'containers.json'), 'FUNCTIONAL_FILE': str(self.path / 'functional.json'),
            'HTTP_FUNCTIONAL_FILE': str(self.path / 'http.json'), 'RECOVERY_POLICIES_FILE': str(self.path / 'policy.json'),
            'EXPECTED_CONTAINERS_FILE': str(self.path / 'expected.json'), 'FAILURE_COUNTERS_FILE': str(self.path / 'counts.json'),
            'FAILURE_STATE_FILE': str(self.path / 'failures.json'), 'RECOVERY_ACTION_STATE_FILE': str(self.path / 'actions.json'),
            'RECOVERY_ROOT': str(self.path), 'RECOVERY_CAPTURE_DIR': str(self.path / 'captured'),
            'RECONSTRUCT_SCRIPT': str(ROOT / 'scripts/reconstruct-container.sh'),
            'VALIDATE_RECONSTRUCTION_SCRIPT': str(ROOT / 'scripts/validate-recovery-manifest.sh'),
            'CAPTURE_SCRIPT': str(ROOT / 'scripts/capture-recovery-manifest.sh'),
            'METRIC_FILE': str(self.path / 'workers.prom'), 'WORKERS': '', 'HOST_ROOT': '',
            'RECOVERY_EXECUTION_ENABLED': '1', 'FAILURE_THRESHOLD': '3', 'RECOVERY_ESCALATION_FAILURES': '3'
        })
        self.write('policy.json', {'default': {'mode': 'observe-only'}, 'containers': {}})
        self.write('expected.json', [])
        self.write('functional.json', [])
        self.write('http.json', [])

    def write(self, name, value):
        target = self.path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(value))

    def read(self, name):
        return json.loads((self.path / name).read_text())

    def run_script(self, script, *args, ok=True):
        self.write('docker.json', self.state)
        result = subprocess.run(['sh', str(ROOT / 'scripts' / script), *map(str, args)], env=self.env, text=True, capture_output=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def mutations(self):
        path = self.path / 'docker.log'
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [call for call in calls if call[0] in ('restart', 'rm', 'create', 'start') or call[:2] == ['network', 'connect']]

    def capture(self):
        self.run_script('capture-recovery-manifest.sh', 'worker')
        return self.path / 'captured/worker.json'

    def test_healthcheck_discovery_and_docker_outage_preserve_snapshot(self):
        self.state['containers'] = [container(health='healthy')]
        self.run_script('discover-containers.sh')
        self.assertEqual(self.read('containers.json')[0]['HealthStatus'], 'healthy')
        previous = (self.path / 'containers.json').read_text()
        self.state['offline'] = True
        self.run_script('discover-containers.sh', ok=False)
        self.assertEqual((self.path / 'containers.json').read_text(), previous)

    def test_workers_empty_and_future_heartbeat(self):
        self.run_script('check-workers.sh')
        self.assertEqual(self.read('functional.json'), [])
        self.env['WORKERS'] = 'worker:15'
        self.state['containers'][0]['heartbeat'] = int(time.time()) + 3600
        self.run_script('check-workers.sh')
        self.assertEqual(self.read('functional.json')[0]['functional'], 0)
        self.state['containers'][0]['heartbeat'] = int(time.time())
        self.run_script('check-workers.sh')
        self.assertEqual(self.read('functional.json')[0]['functional'], 1)

    def test_stopped_container_without_check_is_confirmed_but_observed(self):
        self.state['containers'] = [container(status='exited')]
        for i in range(3):
            self.run_script('evaluate-failures.sh')
            self.assertEqual(self.read('failures.json')[0]['failure_confirmed'], i == 2)
        failure = self.read('failures.json')[0]
        self.assertEqual(failure['failure_type'], 'container_stopped')
        self.assertEqual(failure['recovery_decision'], 'no_action')
        self.run_script('execute-recovery-actions.sh')
        self.assertEqual(self.mutations(), [])

    def test_disabled_healthcheck_is_unconfigured(self):
        self.state['containers'][0]['Config']['Healthcheck'] = {'Test': ['NONE']}
        self.run_script('evaluate-failures.sh')
        self.assertEqual(self.read('failures.json')[0]['status'], 'unconfigured')

    def test_docker_outage_does_not_generate_missing_container_failure(self):
        self.write('failures.json', [{'name': 'worker', 'status': 'ok'}])
        self.state['offline'] = True
        self.run_script('evaluate-failures.sh', ok=False)
        self.assertEqual(self.read('failures.json')[0]['status'], 'ok')

    def test_capture_permissions_and_refresh_only_after_recreation(self):
        self.run_script('auto-capture-containers.sh')
        file = self.path / 'captured/worker.json'
        self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        manifest = json.loads(file.read_text())
        self.assertEqual(manifest['container']['image_id'], 'sha256:demo')
        manifest['sentinel'] = True
        file.write_text(json.dumps(manifest))
        self.run_script('auto-capture-containers.sh')
        self.assertTrue(json.loads(file.read_text())['sentinel'])
        self.state['containers'][0]['Id'] = 'b' * 64
        self.run_script('auto-capture-containers.sh')
        self.assertNotIn('sentinel', json.loads(file.read_text()))

    def test_reconstruction_preserves_aliases_healthcheck_image_and_host_bind(self):
        self.state['containers'] = [container(health='healthy')]
        manifest_path = self.capture()
        manifest = json.loads(manifest_path.read_text())
        (self.path / 'host/srv/app').mkdir(parents=True)
        manifest['container']['mounts'].append({'type': 'bind', 'source': '/srv/app', 'target': '/app', 'read_only': True})
        manifest['container']['networks'].append({'name': 'network-b', 'aliases': ['second-alias']})
        manifest_path.write_text(json.dumps(manifest))
        self.env['HOST_ROOT'] = str(self.path / 'host')
        self.state['containers'] = []
        self.run_script('validate-recovery-manifest.sh', manifest_path)
        self.run_script('reconstruct-container.sh', manifest_path)
        calls = self.mutations()
        create = next(c for c in calls if c[0] == 'create')
        self.assertIn('sha256:demo', create)
        self.assertIn('type=bind,source=/srv/app,target=/app,readonly', create)
        self.assertIn('--network-alias', create)
        self.assertIn('worker-alias', create)
        self.assertIn('--health-cmd', create)
        self.assertIn('5000000000ns', create)
        self.assertIn(['network', 'connect', '--alias', 'second-alias', 'network-b', 'worker'], calls)

    def test_dry_run_uses_same_arguments_without_mutations(self):
        manifest_path = self.capture()
        self.run_script('render-recovery-dry-run.sh', manifest_path)
        self.assertEqual(self.mutations(), [])

    def test_restart_escalation_one_reconstruction_and_recovered_reset(self):
        self.capture()
        self.write('expected.json', [{'name': 'worker', 'manifest': 'captured/worker.json'}])
        self.write('policy.json', {'default': {'mode': 'observe-only'}, 'containers': {'worker': {'mode': 'reconstruct'}}})
        self.write('functional.json', [{'name': 'worker', 'functional': 0}])
        for _ in range(8):
            self.run_script('evaluate-failures.sh')
            self.run_script('execute-recovery-actions.sh')
        calls = self.mutations()
        self.assertEqual(sum(c[0] == 'restart' for c in calls), 1)
        self.assertEqual(sum(c[0] == 'create' for c in calls), 1)
        self.assertTrue(self.read('actions.json')['worker']['reconstruction_attempted'])
        self.write('functional.json', [{'name': 'worker', 'functional': 1}])
        self.run_script('evaluate-failures.sh')
        self.run_script('execute-recovery-actions.sh')
        self.assertFalse(self.read('actions.json')['worker']['incident_active'])

    def test_missing_container_maintenance_and_restart_policy(self):
        self.capture()
        self.state['containers'] = []
        self.write('expected.json', [{'name': 'worker', 'manifest': 'captured/worker.json'}])
        self.write('policy.json', {'containers': {'worker': {'mode': 'restart'}}})
        for _ in range(3):
            self.run_script('evaluate-failures.sh')
        self.assertEqual(self.read('failures.json')[0]['recovery_decision'], 'reconstruction_not_authorized')
        self.run_script('execute-recovery-actions.sh')
        self.assertEqual(self.mutations(), [])
        self.write('policy.json', {'containers': {'worker': {'mode': 'reconstruct', 'maintenance': True}}})
        self.run_script('evaluate-failures.sh')
        self.run_script('execute-recovery-actions.sh')
        self.assertEqual(self.mutations(), [])
        self.write('policy.json', {'containers': {'worker': {'mode': 'reconstruct'}}})
        self.run_script('evaluate-failures.sh')
        self.run_script('execute-recovery-actions.sh')
        self.assertEqual(sum(c[0] == 'create' for c in self.mutations()), 1)

    def test_preflight_refuses_unavailable_image_without_deleting_service(self):
        self.capture()
        self.state['images'] = []
        self.write('expected.json', [{'name': 'worker', 'manifest': 'captured/worker.json'}])
        self.write('policy.json', {'containers': {'worker': {'mode': 'reconstruct'}}})
        self.write('functional.json', [{'name': 'worker', 'functional': 0}])
        for _ in range(7):
            self.run_script('evaluate-failures.sh')
            self.run_script('execute-recovery-actions.sh')
        self.assertEqual(sum(c[0] == 'restart' for c in self.mutations()), 1)
        self.assertFalse(any(c[0] in ('rm', 'create') for c in self.mutations()))

    def test_failed_reconstruction_is_not_repeated(self):
        self.capture()
        self.state['containers'] = []
        self.state['fail_create'] = True
        self.write('expected.json', [{'name': 'worker', 'manifest': 'captured/worker.json'}])
        self.write('policy.json', {'containers': {'worker': {'mode': 'reconstruct'}}})
        for _ in range(5):
            self.run_script('evaluate-failures.sh')
            self.run_script('execute-recovery-actions.sh')
        self.assertEqual(sum(c[0] == 'create' for c in self.mutations()), 1)
        self.assertEqual(self.read('actions.json')['worker']['last_result'], 'failed')

if __name__ == '__main__':
    unittest.main()
