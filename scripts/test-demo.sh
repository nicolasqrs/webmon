#!/bin/bash
# Test réel, à lancer explicitement après le démarrage de la stack de démonstration.
# La seule cible modifiée est webmon-demo-worker, marquée webmon.demo=true.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=webmon-demo-worker
API_URL="${WEBMON_URL:-http://localhost}"
WAIT_SECONDS="${WEBMON_DEMO_TIMEOUT:-240}"

fail() { echo "ECHEC : $*" >&2; exit 1; }
for tool in docker curl jq; do command -v "$tool" >/dev/null || fail "$tool requis"; done
[[ "$(docker inspect --format '{{index .Config.Labels "webmon.demo"}}' "$NAME")" == true ]] || fail "cible non marquée comme démo"
[[ "$(docker inspect --format '{{.State.Running}}' "$NAME")" == true ]] || fail "worker arrêté"

wait_until() {
    local end=$((SECONDS + WAIT_SECONDS))
    until "$@"; do
        (( SECONDS < end )) || fail "délai dépassé pour $* ; consulter docker logs webmon-monitor"
        sleep 2
    done
}
worker_ok() {
    curl -fsS --max-time 5 "$API_URL/api/containers" 2>/dev/null |
      jq -e --arg name "$NAME" 'any(.[]; .Names == $name and .webmon.source == "webmon" and .webmon.functional == true and .recovery.status == "ok")' >/dev/null
}
manifest_ready() {
    docker exec webmon-monitor jq -e --arg name "$NAME" \
      '.container.name == $name and (.container.image_id | type == "string")' \
      "/recovery/captured/$NAME.json" >/dev/null 2>&1
}
worker_reconstructed() {
    local current
    current="$(docker inspect --format '{{.Id}}' "$NAME" 2>/dev/null)" || return 1
    [[ "$current" != "$BEFORE_ID" ]] && worker_ok
}

echo '1/4 Attente du worker sain et du manifeste...'
wait_until worker_ok
wait_until manifest_ready
docker exec webmon-monitor jq -e --arg name "$NAME" \
  '.containers[$name].mode == "reconstruct" and (.containers[$name].maintenance != true)' \
  /config/recovery-policies.json >/dev/null || fail "politique reconstruct absente"
BEFORE_ID="$(docker inspect --format '{{.Id}}' "$NAME")"
BEFORE_COUNT="$(docker exec "$NAME" cat /data/counter)"
[[ "$BEFORE_COUNT" =~ ^[0-9]+$ ]] || fail "compteur invalide"

echo '2/4 Panne volontaire : suppression de /bin/date dans le worker de démo...'
docker exec "$NAME" rm /bin/date
echo '3/4 Attente de la détection, du restart puis de la reconstruction...'
wait_until worker_reconstructed
AFTER_COUNT="$(docker exec "$NAME" cat /data/counter)"
[[ "$AFTER_COUNT" =~ ^[0-9]+$ ]] || fail "compteur restauré invalide"
(( AFTER_COUNT >= BEFORE_COUNT )) || fail "le compteur a perdu des données"
docker exec "$NAME" date +%s >/dev/null || fail "date non restauré"
docker inspect "$NAME" | jq -e '.[0].NetworkSettings.Networks | any(.[]; (.Aliases // []) | index("demo-worker"))' >/dev/null || fail "alias réseau perdu"
echo "4/4 OK : nouveau conteneur, heartbeat sain, alias conservé, compteur $BEFORE_COUNT -> $AFTER_COUNT."
