#!/bin/sh

# ============================================================
# WebMon - Reconstruction réelle depuis un manifeste
# ============================================================

set -eu

MANIFEST="${1:-}"

if [ -z "$MANIFEST" ]; then
    echo "ERREUR : manifeste non fourni."
    exit 1
fi

if [ ! -s "$MANIFEST" ]; then
    echo "ERREUR : manifeste introuvable : $MANIFEST"
    exit 1
fi

if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
    echo "ERREUR : manifeste JSON invalide."
    exit 1
fi


NAME="$(jq -r '.container.name' "$MANIFEST")"
IMAGE="$(jq -r '.container.image' "$MANIFEST")"
RESTART="$(jq -r '.container.restart_policy.name // "no"' "$MANIFEST")"
MAX_RETRY="$(jq -r '.container.restart_policy.maximum_retry_count // 0' "$MANIFEST")"


echo "WebMon reconstruct: préparation de $NAME"


# ============================================================
# SECURITES
# ============================================================

if docker inspect "$NAME" >/dev/null 2>&1; then
    echo "ERREUR : $NAME existe déjà. Reconstruction refusée."
    exit 1
fi

# Pour l'instant on refuse de télécharger automatiquement
# une image avec un tag potentiellement différent.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERREUR : image absente localement : $IMAGE"
    exit 1
fi


# ============================================================
# CONSTRUCTION DES ARGUMENTS docker create
# ============================================================

set -- docker create \
    --name "$NAME"


# ------------------------------------------------------------
# Restart policy
# ------------------------------------------------------------

if [ "$RESTART" = "on-failure" ] && [ "$MAX_RETRY" -gt 0 ]; then
    set -- "$@" --restart "on-failure:$MAX_RETRY"
else
    set -- "$@" --restart "$RESTART"
fi


# ------------------------------------------------------------
# User
# ------------------------------------------------------------

USER_VALUE="$(jq -r '.container.user // ""' "$MANIFEST")"

if [ -n "$USER_VALUE" ]; then
    set -- "$@" --user "$USER_VALUE"
fi


# ------------------------------------------------------------
# Working directory
# ------------------------------------------------------------

WORKDIR="$(jq -r '.container.working_dir // ""' "$MANIFEST")"

if [ -n "$WORKDIR" ]; then
    set -- "$@" --workdir "$WORKDIR"
fi


# ------------------------------------------------------------
# Entrypoint
#
# Docker inspect renvoie généralement un tableau.
# Pour cette première version :
# - null / [] : rien à faire
# - un élément : supporté
# - plusieurs éléments : refus par sécurité
# ------------------------------------------------------------

ENTRYPOINT_COUNT="$(jq '(.container.entrypoint // []) | length' "$MANIFEST")"

if [ "$ENTRYPOINT_COUNT" -gt 1 ]; then
    echo "ERREUR : entrypoint multiple non encore supporté."
    exit 1
fi

if [ "$ENTRYPOINT_COUNT" -eq 1 ]; then
    ENTRYPOINT="$(jq -r '.container.entrypoint[0]' "$MANIFEST")"
    set -- "$@" --entrypoint "$ENTRYPOINT"
fi


# ------------------------------------------------------------
# Variables d'environnement
# ------------------------------------------------------------

ENV_COUNT="$(jq '(.container.environment // {}) | length' "$MANIFEST")"

i=0

while [ "$i" -lt "$ENV_COUNT" ]; do

    KEY="$(jq -r \
        ".container.environment | to_entries[$i].key" \
        "$MANIFEST")"

    VALUE="$(jq -r \
        ".container.environment | to_entries[$i].value" \
        "$MANIFEST")"

    set -- "$@" --env "$KEY=$VALUE"

    i=$((i + 1))
done


# ------------------------------------------------------------
# Labels
# ------------------------------------------------------------

LABEL_COUNT="$(jq '(.container.labels // {}) | length' "$MANIFEST")"

i=0

while [ "$i" -lt "$LABEL_COUNT" ]; do

    KEY="$(jq -r \
        ".container.labels | to_entries[$i].key" \
        "$MANIFEST")"

    VALUE="$(jq -r \
        ".container.labels | to_entries[$i].value" \
        "$MANIFEST")"

    set -- "$@" --label "$KEY=$VALUE"

    i=$((i + 1))
done


# ------------------------------------------------------------
# Volumes / binds
# ------------------------------------------------------------

MOUNT_COUNT="$(jq '(.container.mounts // []) | length' "$MANIFEST")"

i=0

while [ "$i" -lt "$MOUNT_COUNT" ]; do

    TYPE="$(jq -r ".container.mounts[$i].type" "$MANIFEST")"
    SOURCE="$(jq -r ".container.mounts[$i].source" "$MANIFEST")"
    TARGET="$(jq -r ".container.mounts[$i].target" "$MANIFEST")"
    READ_ONLY="$(jq -r ".container.mounts[$i].read_only // false" "$MANIFEST")"

    case "$TYPE" in
        volume)
            docker volume inspect "$SOURCE" >/dev/null 2>&1 || {
                echo "ERREUR : volume absent : $SOURCE"
                exit 1
            }
            ;;

        bind)
            [ -e "$SOURCE" ] || {
                echo "ERREUR : bind absent : $SOURCE"
                exit 1
            }
            ;;

        *)
            echo "ERREUR : type de montage non supporté : $TYPE"
            exit 1
            ;;
    esac

    MOUNT_SPEC="type=$TYPE,source=$SOURCE,target=$TARGET"

    if [ "$READ_ONLY" = "true" ]; then
        MOUNT_SPEC="$MOUNT_SPEC,readonly"
    fi

    set -- "$@" --mount "$MOUNT_SPEC"

    i=$((i + 1))
done


# ------------------------------------------------------------
# Ports publiés
# ------------------------------------------------------------

PORT_COUNT="$(jq '(.container.ports // []) | length' "$MANIFEST")"

i=0

while [ "$i" -lt "$PORT_COUNT" ]; do

    CONTAINER_PORT="$(jq -r ".container.ports[$i].container_port" "$MANIFEST")"
    HOST_IP="$(jq -r ".container.ports[$i].host_ip // \"\"" "$MANIFEST")"
    HOST_PORT="$(jq -r ".container.ports[$i].host_port // \"\"" "$MANIFEST")"

    if [ -z "$HOST_PORT" ]; then
        PUBLISH="$CONTAINER_PORT"

    elif [ -z "$HOST_IP" ]; then
        PUBLISH="$HOST_PORT:$CONTAINER_PORT"

    else
        PUBLISH="$HOST_IP:$HOST_PORT:$CONTAINER_PORT"
    fi

    set -- "$@" --publish "$PUBLISH"

    i=$((i + 1))
done


# ------------------------------------------------------------
# Premier réseau
# ------------------------------------------------------------

NETWORK_COUNT="$(jq '(.container.networks // []) | length' "$MANIFEST")"

if [ "$NETWORK_COUNT" -gt 0 ]; then

    FIRST_NETWORK="$(jq -r '.container.networks[0].name' "$MANIFEST")"

    docker network inspect "$FIRST_NETWORK" >/dev/null 2>&1 || {
        echo "ERREUR : réseau absent : $FIRST_NETWORK"
        exit 1
    }

    set -- "$@" --network "$FIRST_NETWORK"
fi


# ------------------------------------------------------------
# Image + commande
# ------------------------------------------------------------

set -- "$@" "$IMAGE"

COMMAND_COUNT="$(jq '(.container.command // []) | length' "$MANIFEST")"

i=0

while [ "$i" -lt "$COMMAND_COUNT" ]; do

    ARG="$(jq -r ".container.command[$i]" "$MANIFEST")"

    set -- "$@" "$ARG"

    i=$((i + 1))
done


# ============================================================
# CREATION
# ============================================================

echo "WebMon reconstruct: création de $NAME..."

if ! "$@" >/dev/null; then
    echo "ERREUR : docker create a échoué pour $NAME"
    exit 1
fi


# ============================================================
# RESEAUX SUPPLEMENTAIRES
# ============================================================

if [ "$NETWORK_COUNT" -gt 1 ]; then

    i=1

    while [ "$i" -lt "$NETWORK_COUNT" ]; do

        NETWORK="$(jq -r ".container.networks[$i].name" "$MANIFEST")"

        docker network inspect "$NETWORK" >/dev/null 2>&1 || {
            echo "ERREUR : réseau absent : $NETWORK"
            docker rm -f "$NAME" >/dev/null 2>&1 || true
            exit 1
        }

        if ! docker network connect "$NETWORK" "$NAME"; then
            echo "ERREUR : connexion au réseau $NETWORK impossible."
            docker rm -f "$NAME" >/dev/null 2>&1 || true
            exit 1
        fi

        i=$((i + 1))
    done
fi


# ============================================================
# DEMARRAGE
# ============================================================

echo "WebMon reconstruct: démarrage de $NAME..."

if ! docker start "$NAME" >/dev/null; then

    echo "ERREUR : démarrage impossible pour $NAME"

    docker rm -f "$NAME" >/dev/null 2>&1 || true

    exit 1
fi


echo "WebMon reconstruct: $NAME reconstruit et démarré."
