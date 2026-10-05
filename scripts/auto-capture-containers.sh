#!/bin/sh

# ============================================================
# WebMon - Capture automatique des conteneurs découverts
# ============================================================

set -eu

CAPTURE_SCRIPT="${CAPTURE_SCRIPT:-/scripts/capture-recovery-manifest.sh}"
CAPTURE_DIR="${RECOVERY_CAPTURE_DIR:-/recovery/captured}"

mkdir -p "$CAPTURE_DIR"

IDS="$(docker ps -aq --no-trunc)"
printf '%s\n' "$IDS" | while read -r id; do

    [ -n "$id" ] || continue

    name="$(docker inspect \
        --format '{{.Name}}' "$id" 2>/dev/null \
        | sed 's#^/##')"

    [ -n "$name" ] || continue

    internal="$(docker inspect \
        --format '{{index .Config.Labels "webmon.internal"}}' \
        "$id" 2>/dev/null || true)"

    # Ne jamais enregistrer les composants internes de WebMon.
    if [ "$internal" = "true" ]; then
        continue
    fi

    file="$CAPTURE_DIR/$name.json"

    # Première découverte :
    # sauvegarde immédiatement la configuration.
    captured_id=""
    if [ -s "$file" ]; then
        captured_id="$(jq -r '.container.container_id // empty' "$file" 2>/dev/null || true)"
    fi

    # Une recréation volontaire doit remplacer l'ancienne configuration capturée.
    if [ ! -s "$file" ] || [ "$captured_id" != "$id" ]; then

        echo "WebMon: nouvelle configuration détectée : $name"

        RECOVERY_CAPTURE_DIR="$CAPTURE_DIR" \
            "$CAPTURE_SCRIPT" "$name" \
            >/dev/null 2>&1 || {
                echo "WebMon: échec capture : $name" >&2
                continue
            }

        chmod 600 "$file" 2>/dev/null || true
    fi

done
