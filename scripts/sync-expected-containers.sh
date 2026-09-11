#!/bin/sh

# ============================================================
# WebMon - Inventaire des conteneurs attendus
# ============================================================
#
# Tout conteneur pour lequel WebMon possède un manifeste
# capturé est considéré comme connu/attendu.
#
# La disparition du conteneur ne supprime PAS son manifeste,
# donc il reste dans cet inventaire.
#
# AUCUNE action Docker.
# ============================================================

set -eu

CAPTURE_DIR="${RECOVERY_CAPTURE_DIR:-/recovery/captured}"
EXPECTED_FILE="${EXPECTED_CONTAINERS_FILE:-/recovery/expected-containers.json}"

mkdir -p "$CAPTURE_DIR"

TMP="${EXPECTED_FILE}.tmp.$$"

cleanup() {
    rm -f "$TMP"
}

trap cleanup EXIT INT TERM

{
    for file in "$CAPTURE_DIR"/*.json; do

        [ -f "$file" ] || continue

        if ! jq -e . "$file" >/dev/null 2>&1; then
            continue
        fi

        NAME="$(jq -r '.container.name // empty' "$file")"
        CAPTURED="$(jq -r '.captured_at // ""' "$file")"

        [ -n "$NAME" ] || continue

        BASENAME="$(basename "$file")"

        jq -n \
            --arg name "$NAME" \
            --arg manifest "captured/$BASENAME" \
            --arg captured_at "$CAPTURED" \
            '{
                name: $name,
                manifest: $manifest,
                captured_at: $captured_at
            }'
    done
} | jq -s 'sort_by(.name)' > "$TMP"

chmod 644 "$TMP"
mv -f "$TMP" "$EXPECTED_FILE"

echo "Inventaire attendu mis à jour : $EXPECTED_FILE"
