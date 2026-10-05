// Réunir les conteneurs présents et les services attendus disparus.
function mergeFailureStates(containers, failures) {
  const byName = new Map(failures.map(item => [item.name, item]));
  const names = new Set(containers.map(item => item.Names));
  const result = containers.map(container => ({
    ...container,
    recovery: byName.get(container.Names) || null
  }));
  for (const failure of failures) {
    if (failure.docker_state === 'missing' && !names.has(failure.name)) {
      result.push({
        Names: failure.name,
        Image: '',
        State: 'missing',
        Status: 'Conteneur attendu mais absent',
        webmon: { configured: true, source: 'inventory', functional: false },
        recovery: failure
      });
    }
  }
  return result;
}
module.exports = { mergeFailureStates };
