const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { mergeFailureStates } = require('../backend/src/container-state');

// Exécuter la vraie route avec ses fichiers runtime et des doubles des dépendances HTTP/DB.
async function containersRoute(snapshot, failures = []) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'webmon-api-'));
  try {
    const env = {};
    for (const [key, name, value] of [
      ['CONTAINERS_FILE', 'containers.json', snapshot],
      ['FUNCTIONAL_FILE', 'functional.json', []],
      ['HTTP_FUNCTIONAL_FILE', 'http.json', []],
      ['FAILURE_STATE_FILE', 'failure.json', failures]
    ]) {
      env[key] = path.join(directory, name);
      fs.writeFileSync(env[key], JSON.stringify(value));
    }
    const routes = new Map();
    const app = { use() {}, get: (route, handler) => routes.set(route, handler), post() {}, patch() {}, delete() {}, listen() {} };
    const express = () => app;
    express.json = () => () => {};
    class Metric { startTimer() { return () => {}; } }
    const dependencies = {
      'fs/promises': require('node:fs/promises'),
      express, cors: () => () => {},
      'prom-client': { Registry: Metric, Counter: Metric, Histogram: Metric, collectDefaultMetrics() {} },
      './db': { initDb: async () => {} }, './container-state': { mergeFailureStates }
    };
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../backend/src/index.js'), 'utf8'), {
      require: name => dependencies[name], process: { env }, console
    });
    let body;
    let status = 200;
    await routes.get('/api/containers')({}, { json(value) { body = value; }, status(value) { status = value; return this; } });
    assert.equal(status, 200);
    return body;
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

test('API : healthcheck sain uniquement pour un conteneur en cours d’exécution', async () => {
  const result = await containersRoute([
    { Names: 'up', State: 'running', HealthStatus: 'healthy' },
    { Names: 'down', State: 'exited', HealthStatus: 'healthy' }
  ]);
  assert.equal(result[0].webmon.functional, true);
  assert.equal(result[1].webmon.functional, false);
});

test('API : composants internes masqués et conteneur attendu disparu visible', async () => {
  const result = await containersRoute([
    { Names: 'monitor', State: 'running', Labels: 'webmon.internal=true' }
  ], [{ name: 'worker', docker_state: 'missing', status: 'critical' }]);
  assert.equal(result.length, 1);
  assert.equal(result[0].Names, 'worker');
  assert.equal(result[0].State, 'missing');
});
