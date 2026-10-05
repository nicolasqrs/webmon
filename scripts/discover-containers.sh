#!/bin/sh
# Découverte atomique : conserver le dernier snapshot si Docker est indisponible.
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONTAINERS_FILE="${CONTAINERS_FILE:-$PROJECT_DIR/runtime/containers.json}"
TMP_FILE="${CONTAINERS_FILE}.tmp.$$"
PS_FILE="${TMP_FILE}.ps"
INSPECT_FILE="${TMP_FILE}.inspect"
trap 'rm -f "$TMP_FILE" "$PS_FILE" "$INSPECT_FILE"' EXIT INT TERM
mkdir -p "$(dirname "$CONTAINERS_FILE")"
docker ps -a --format '{{json .}}' > "$PS_FILE"
IDS="$(jq -rs 'map(.ID) | join(" ")' "$PS_FILE")"
if [ -n "$IDS" ]; then
    # Les identifiants Docker ne contiennent pas d'espaces.
    docker inspect $IDS > "$INSPECT_FILE"
else
    echo '[]' > "$INSPECT_FILE"
fi
jq -s --slurpfile inspected "$INSPECT_FILE" '
    map(. as $row |
        (first($inspected[0][] | select(.Id | startswith($row.ID))) // {}) as $detail |
        . + {HealthStatus: ($detail.State.Health.Status // "")})
' "$PS_FILE" > "$TMP_FILE"
mv "$TMP_FILE" "$CONTAINERS_FILE"
echo "Découverte terminée : $CONTAINERS_FILE"
