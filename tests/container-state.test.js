const test = require('node:test');
const assert = require('node:assert/strict');
const { mergeFailureStates } = require('../backend/src/container-state');

test('un conteneur disparu reste visible et critique dans le dashboard', () => {
  const failure = { name: 'worker', docker_state: 'missing', recovery_mode: 'reconstruct' };
  const result = mergeFailureStates([], [failure]);
  assert.equal(result.length, 1);
  assert.equal(result[0].State, 'missing');
  assert.equal(result[0].webmon.functional, false);
  assert.equal(result[0].recovery, failure);
});

test('un conteneur présent conserve son contrôle et n’est pas dupliqué', () => {
  const container = { Names: 'worker', webmon: { functional: true } };
  const failure = { name: 'worker', docker_state: 'missing' };
  const result = mergeFailureStates([container], [failure]);
  assert.equal(result.length, 1);
  assert.equal(result[0].webmon.functional, true);
  assert.equal(container.recovery, undefined);
});

test('sans état des pannes, les conteneurs restent visibles', () => {
  assert.equal(mergeFailureStates([{ Names: 'web' }], [])[0].recovery, null);
});
