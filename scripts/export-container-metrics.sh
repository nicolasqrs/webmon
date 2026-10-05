#!/bin/sh
# Exporter l'inventaire et les contrôles WebMon vers le textfile collector existant.
set -eu
STATE_FILE="${FAILURE_STATE_FILE:-/runtime/failure-state.json}"
METRIC_FILE="${CONTAINER_METRIC_FILE:-/metrics/containers.prom}"
TMP="${METRIC_FILE}.tmp.$$"
trap 'rm -f "$TMP"' EXIT INT TERM
mkdir -p "$(dirname "$METRIC_FILE")"
jq -e 'type == "array" and all(.[]; (.name | type == "string") and (.docker_state | type == "string"))' "$STATE_FILE" >/dev/null
NOW="$(date +%s)"
cat > "$TMP" <<'HEADER'
# HELP webmon_monitor_last_cycle_timestamp_seconds Date du dernier cycle de supervision termine.
# TYPE webmon_monitor_last_cycle_timestamp_seconds gauge
# HELP webmon_container_running Conteneur demarre (1) ou arrete/absent (0).
# TYPE webmon_container_running gauge
# HELP webmon_container_functional Controle OK (1), KO (0), non teste (-1), demarrage (2).
# TYPE webmon_container_functional gauge
# HELP webmon_container_failure_confirmed Panne confirmee apres plusieurs controles (1 ou 0).
# TYPE webmon_container_failure_confirmed gauge
HEADER
printf 'webmon_monitor_last_cycle_timestamp_seconds %s\n' "$NOW" >> "$TMP"
# @json produit l'echappement requis pour les guillemets, backslashes et retours ligne des labels.
jq -r '
  def quoted: tojson;
  .[] |
  (.name | quoted) as $name |
  (.docker_state | quoted) as $state |
  ((.source // "docker-state") | quoted) as $probe |
  ((.recovery_mode // "observe-only") | quoted) as $mode |
  ("container=" + $name) as $identity |
  (if .docker_state == "running" then 1 else 0 end) as $running |
  (if .status == "ok" then 1 elif .status == "starting" then 2 elif .status == "unconfigured" then -1 else 0 end) as $functional |
  (if .failure_confirmed == true then 1 else 0 end) as $confirmed |
  "webmon_container_running{" + $identity + ",docker_state=" + $state + "} " + ($running | tostring),
  "webmon_container_functional{" + $identity + ",docker_state=" + $state + ",probe=" + $probe + ",recovery_mode=" + $mode + "} " + ($functional | tostring),
  "webmon_container_failure_confirmed{" + $identity + "} " + ($confirmed | tostring)
' "$STATE_FILE" >> "$TMP"
chmod 644 "$TMP"
mv -f "$TMP" "$METRIC_FILE"
