#!/bin/sh

# ============================================================
# WebMon - Reconstruction réelle depuis un manifeste
# ============================================================

set -eu
HOST_ROOT="${HOST_ROOT:-}"

MANIFEST="${1:-}"
DRY_RUN="${2:-}"
case "$DRY_RUN" in
    ''|--dry-run) ;;
    *) echo "ERREUR : argument inconnu : $DRY_RUN"; exit 1 ;;
esac

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
IMAGE="$(jq -r '.container.image_id // .container.image' "$MANIFEST")"
RESTART="$(jq -r '.container.restart_policy.name // "no"' "$MANIFEST")"
MAX_RETRY="$(jq -r '.container.restart_policy.maximum_retry_count // 0' "$MANIFEST")"


echo "WebMon reconstruct: préparation de $NAME"


# ============================================================
# SECURITES
# ============================================================

if [ "$DRY_RUN" != "--dry-run" ] && docker inspect "$NAME" >/dev/null 2>&1; then
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
            [ -e "$HOST_ROOT$SOURCE" ] || {
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

    ALIAS_COUNT="$(jq '(.container.networks[0].aliases // []) | length' "$MANIFEST")"
    a=0
    while [ "$a" -lt "$ALIAS_COUNT" ]; do
        ALIAS="$(jq -r ".container.networks[0].aliases[$a]" "$MANIFEST")"
        set -- "$@" --network-alias "$ALIAS"
        a=$((a + 1))
    done
fi

# Restituer le healthcheck défini au déploiement, pas seulement celui de l'image.
HEALTH_TYPE="$(jq -r '.container.healthcheck.Test[0] // empty' "$MANIFEST")"
case "$HEALTH_TYPE" in
    NONE)
        set -- "$@" --no-healthcheck
        ;;
    CMD|CMD-SHELL)
        if [ "$HEALTH_TYPE" = "CMD" ]; then
            HEALTH_CMD="$(jq -r '.container.healthcheck.Test[1:] | @sh' "$MANIFEST")"
        else
            HEALTH_CMD="$(jq -r '.container.healthcheck.Test[1]' "$MANIFEST")"
        fi
        set -- "$@" --health-cmd "$HEALTH_CMD"
        for FIELD in Interval Timeout StartPeriod StartInterval; do
            VALUE="$(jq -r --arg field "$FIELD" '.container.healthcheck[$field] // 0' "$MANIFEST")"
            [ "$VALUE" -gt 0 ] || continue
            case "$FIELD" in
                Interval) OPTION=--health-interval ;;
                Timeout) OPTION=--health-timeout ;;
                StartPeriod) OPTION=--health-start-period ;;
                StartInterval) OPTION=--health-start-interval ;;
            esac
            set -- "$@" "$OPTION" "${VALUE}ns"
        done
        RETRIES="$(jq -r '.container.healthcheck.Retries // 0' "$MANIFEST")"
        if [ "$RETRIES" -gt 0 ]; then
            set -- "$@" --health-retries "$RETRIES"
        fi
        ;;
esac


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

if [ "$DRY_RUN" = "--dry-run" ]; then
    jq -nr --args '$ARGS.positional | @sh' -- "$@"
elif ! "$@" >/dev/null; then
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

        set -- docker network connect
        ALIAS_COUNT="$(jq "(.container.networks[$i].aliases // []) | length" "$MANIFEST")"
        a=0
        while [ "$a" -lt "$ALIAS_COUNT" ]; do
            ALIAS="$(jq -r ".container.networks[$i].aliases[$a]" "$MANIFEST")"
            set -- "$@" --alias "$ALIAS"
            a=$((a + 1))
        done
        if [ "$DRY_RUN" = "--dry-run" ]; then
            jq -nr --args '$ARGS.positional | @sh' -- "$@" "$NETWORK" "$NAME"
        elif ! "$@" "$NETWORK" "$NAME"; then
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

if [ "$DRY_RUN" = "--dry-run" ]; then
    jq -nr --arg name "$NAME" '["docker", "start", $name] | @sh'
    echo "DRY-RUN TERMINE : aucune modification Docker."
    exit 0
fi

if ! docker start "$NAME" >/dev/null; then

    echo "ERREUR : démarrage impossible pour $NAME"

    docker rm -f "$NAME" >/dev/null 2>&1 || true

    exit 1
fi


echo "WebMon reconstruct: $NAME reconstruit et démarré."
