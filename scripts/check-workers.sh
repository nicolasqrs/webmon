#!/bin/sh

# ============================================================
# WebMon - Contrôle fonctionnel des conteneurs
# ============================================================

# Retrouve automatiquement le dossier du projet lorsque
# le script est lancé directement depuis l'hôte.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"


# ============================================================
# FICHIERS DE SORTIE
# ============================================================

# Métriques destinées à Node Exporter / Prometheus.
METRIC_FILE="${METRIC_FILE:-$PROJECT_DIR/node-exporter-textfile/workers.prom}"

# État fonctionnel destiné au backend WebMon.
FUNCTIONAL_FILE="${FUNCTIONAL_FILE:-$PROJECT_DIR/runtime/functional.json}"

# Fichiers temporaires.
#
# On écrit d'abord dedans puis on fait un mv afin d'éviter
# qu'un autre composant lise un fichier à moitié écrit.
METRIC_TMP="${METRIC_FILE}.tmp"
FUNCTIONAL_TMP="${FUNCTIONAL_FILE}.tmp"

mkdir -p "$(dirname "$METRIC_FILE")"
mkdir -p "$(dirname "$FUNCTIONAL_FILE")"

: > "$METRIC_TMP"
: > "$FUNCTIONAL_TMP"


# ============================================================
# CONFIGURATION DES WORKERS
# ============================================================

# Format :
#
# nom_du_conteneur:age_max_du_heartbeat
#
# Exemple :
# worker-a:15
#
# signifie que worker-a est considéré fonctionnel si son
# heartbeat date de 15 secondes maximum.
WORKERS="${WORKERS:-worker-a:15 worker-b:25}"

# Emplacement du heartbeat à l'intérieur des workers.
HEARTBEAT_PATH="${HEARTBEAT_PATH:-/data/heartbeat}"


# ============================================================
# PRÉPARATION DU JSON
# ============================================================

echo "[" > "$FUNCTIONAL_TMP"

JSON_FIRST=1


check_worker() {

    CONTAINER="$1"
    MAX_AGE="$2"

    echo "===== $CONTAINER ====="

    RUNNING=0
    FUNCTIONAL=0
    AGE=-1


    # --------------------------------------------------------
    # 1. Le conteneur existe-t-il ?
    # --------------------------------------------------------
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then

        echo "CRITICAL : conteneur introuvable"

    else

        STATUS="$(docker inspect \
            --format '{{.State.Status}}' \
            "$CONTAINER")"

        echo "Docker status : $STATUS"


        # ----------------------------------------------------
        # 2. Le conteneur tourne-t-il ?
        # ----------------------------------------------------
        if [ "$STATUS" = "running" ]; then

            RUNNING=1


            # ------------------------------------------------
            # 3. Lecture du heartbeat
            # ------------------------------------------------
            HEARTBEAT="$(docker exec "$CONTAINER" \
                cat "$HEARTBEAT_PATH" 2>/dev/null)"


            # Vérifie que le heartbeat est bien numérique.
            case "$HEARTBEAT" in

                ''|*[!0-9]*)

                    echo "CRITICAL : heartbeat introuvable ou invalide"
                    ;;

                *)

                    NOW="$(date +%s)"
                    AGE=$((NOW - HEARTBEAT))

                    echo "Dernier travail : il y a ${AGE}s"


                    # ----------------------------------------
                    # 4. Vérification fonctionnelle
                    # ----------------------------------------
                    if [ "$AGE" -le "$MAX_AGE" ]; then

                        FUNCTIONAL=1
                        echo "OK : le worker travaille normalement"

                    else

                        echo "CRITICAL : conteneur UP mais travail bloqué"

                    fi
                    ;;
            esac

        else

            echo "CRITICAL : le conteneur ne tourne pas"

        fi
    fi


    # ========================================================
    # 5. EXPORT PROMETHEUS
    # ========================================================

    echo "webmon_worker_running{worker=\"$CONTAINER\"} $RUNNING" \
        >> "$METRIC_TMP"

    echo "webmon_worker_functional{worker=\"$CONTAINER\"} $FUNCTIONAL" \
        >> "$METRIC_TMP"

    echo "webmon_worker_heartbeat_age_seconds{worker=\"$CONTAINER\"} $AGE" \
        >> "$METRIC_TMP"


    # ========================================================
    # 6. EXPORT JSON POUR LE BACKEND
    # ========================================================

    # Ajoute une virgule entre les objets JSON,
    # sauf avant le premier.
    if [ "$JSON_FIRST" -eq 0 ]; then
        echo "," >> "$FUNCTIONAL_TMP"
    fi

    JSON_FIRST=0

    printf '  {"name":"%s","running":%s,"functional":%s,"heartbeat_age":%s,"max_age":%s}' \
        "$CONTAINER" \
        "$RUNNING" \
        "$FUNCTIONAL" \
        "$AGE" \
        "$MAX_AGE" \
        >> "$FUNCTIONAL_TMP"

    echo
}


# ============================================================
# CONTRÔLE DE TOUS LES WORKERS
# ============================================================

for WORKER in $WORKERS
do
    CONTAINER="${WORKER%%:*}"
    MAX_AGE="${WORKER##*:}"

    check_worker "$CONTAINER" "$MAX_AGE"
done


# ============================================================
# FINALISATION DES FICHIERS
# ============================================================

echo >> "$FUNCTIONAL_TMP"
echo "]" >> "$FUNCTIONAL_TMP"

# Remplacement atomique des fichiers.
mv "$METRIC_TMP" "$METRIC_FILE"
mv "$FUNCTIONAL_TMP" "$FUNCTIONAL_FILE"
