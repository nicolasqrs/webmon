#!/bin/sh
# Le dry-run et l'exécution utilisent exactement le même constructeur d'arguments.
set -eu
MANIFEST="${1:-}"
[ -n "$MANIFEST" ] || { echo "Usage : $0 <manifest.json>"; exit 1; }
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
"$SCRIPT_DIR/validate-recovery-manifest.sh" "$MANIFEST"
"$SCRIPT_DIR/reconstruct-container.sh" "$MANIFEST" --dry-run
