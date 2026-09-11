#!/bin/sh

# ============================================================
# WebMon - Découverte automatique des conteneurs Docker
# ============================================================

# Trouve automatiquement le dossier du projet lorsque le script
# est exécuté directement depuis WebMon.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Emplacement du fichier généré.
#
# Cette variable pourra ensuite être remplacée depuis Docker
# par exemple avec :
# CONTAINERS_FILE=/runtime/containers.json
CONTAINERS_FILE="${CONTAINERS_FILE:-$PROJECT_DIR/runtime/containers.json}"

# On écrit d'abord dans un fichier temporaire.
# Cela évite qu'un autre composant lise un JSON à moitié écrit.
TMP_FILE="${CONTAINERS_FILE}.tmp"

mkdir -p "$(dirname "$CONTAINERS_FILE")"


# ============================================================
# Récupération des conteneurs
# ============================================================

{
    echo "["

    # docker ps -a :
    # - sans -a : uniquement les conteneurs en cours d'exécution
    # - avec -a : TOUS les conteneurs, même arrêtés
    #
    # {{json .}} demande à Docker de retourner chaque
    # conteneur sous forme JSON.
    docker ps -a --format '{{json .}}' | awk '
        BEGIN {
            first = 1
        }

        {
            if (!first) {
                printf ",\n"
            }

            printf "%s", $0
            first = 0
        }

        END {
            print "\n]"
        }
    '

} > "$TMP_FILE"


# Remplacement atomique du fichier final.
mv "$TMP_FILE" "$CONTAINERS_FILE"

echo "Découverte terminée : $CONTAINERS_FILE"
