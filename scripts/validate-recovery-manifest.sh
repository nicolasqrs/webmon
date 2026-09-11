#!/bin/sh

# ============================================================
# WebMon - Validation d'un manifeste de reconstruction
# ============================================================
#
# AUCUNE modification Docker.
# AUCUNE création de conteneur.
# AUCUN téléchargement d'image.
#
# Usage :
#   ./scripts/validate-recovery-manifest.sh \
#       recovery/manifests/worker-a.json
#
# ============================================================

set -u

MANIFEST="${1:-}"

if [ -z "$MANIFEST" ]; then
    echo "ERREUR : manifeste non fourni."
    exit 1
fi

if [ ! -s "$MANIFEST" ]; then
    echo "ERREUR : manifeste absent ou vide : $MANIFEST"
    exit 1
fi

if ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
    echo "ERREUR : JSON invalide."
    exit 1
fi


# ============================================================
# 1. STRUCTURE MINIMALE
# ============================================================

if ! jq -e '
    .schema_version == 1
    and
    (.container | type == "object")
    and
    (.container.name | type == "string" and length > 0)
    and
    (.container.image | type == "string" and length > 0)
    and
    (.container.mounts | type == "array")
    and
    (.container.networks | type == "array")
    and
    (.container.ports | type == "array")
' "$MANIFEST" >/dev/null
then
    echo "ERREUR : structure du manifeste invalide."
    exit 1
fi


NAME="$(jq -r '.container.name' "$MANIFEST")"
IMAGE="$(jq -r '.container.image' "$MANIFEST")"
RESTART="$(jq -r '.container.restart_policy.name // "no"' "$MANIFEST")"

ERRORS=0


echo "=== WebMon - Validation reconstruction ==="
echo
echo "Conteneur : $NAME"
echo "Image     : $IMAGE"
echo "Restart   : $RESTART"
echo


# ============================================================
# 2. POLITIQUE DE RESTART
# ============================================================

case "$RESTART" in
    no|always|unless-stopped|on-failure)
        echo "[OK] Politique restart valide : $RESTART"
        ;;
    *)
        echo "[ERREUR] Politique restart inconnue : $RESTART"
        ERRORS=$((ERRORS + 1))
        ;;
esac


# ============================================================
# 3. ETAT ACTUEL DU CONTENEUR
# ============================================================

if docker inspect "$NAME" >/dev/null 2>&1; then
    STATE="$(docker inspect \
        --format '{{.State.Status}}' \
        "$NAME" 2>/dev/null)"

    echo "[INFO] Le conteneur existe déjà : état=$STATE"
else
    echo "[OK] Le conteneur est actuellement absent."
fi


# ============================================================
# 4. IMAGE
# ============================================================

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[OK] Image disponible localement : $IMAGE"
else
    echo "[INFO] Image non présente localement : $IMAGE"
    echo "       Elle devra être récupérée avant/pendant la reconstruction."
fi


# ============================================================
# 5. MONTAGES
# ============================================================

MOUNT_COUNT="$(jq '.container.mounts | length' "$MANIFEST")"

i=0

while [ "$i" -lt "$MOUNT_COUNT" ]; do

    TYPE="$(jq -r ".container.mounts[$i].type" "$MANIFEST")"
    SOURCE="$(jq -r ".container.mounts[$i].source" "$MANIFEST")"
    TARGET="$(jq -r ".container.mounts[$i].target" "$MANIFEST")"

    case "$TARGET" in
        /*)
            ;;
        *)
            echo "[ERREUR] Destination non absolue : $TARGET"
            ERRORS=$((ERRORS + 1))
            ;;
    esac

    case "$TYPE" in

        volume)
            if docker volume inspect "$SOURCE" >/dev/null 2>&1; then
                echo "[OK] Volume : $SOURCE -> $TARGET"
            else
                echo "[ERREUR] Volume absent : $SOURCE"
                ERRORS=$((ERRORS + 1))
            fi
            ;;

        bind)
            if [ -e "$SOURCE" ]; then
                echo "[OK] Bind : $SOURCE -> $TARGET"
            else
                echo "[ERREUR] Source bind absente : $SOURCE"
                ERRORS=$((ERRORS + 1))
            fi
            ;;

        *)
            echo "[ERREUR] Type de montage non supporté : $TYPE"
            ERRORS=$((ERRORS + 1))
            ;;

    esac

    i=$((i + 1))

done


# ============================================================
# 6. RESEAUX
# ============================================================

NETWORK_COUNT="$(jq '.container.networks | length' "$MANIFEST")"

i=0

while [ "$i" -lt "$NETWORK_COUNT" ]; do

    NETWORK="$(jq -r ".container.networks[$i].name" "$MANIFEST")"

    if docker network inspect "$NETWORK" >/dev/null 2>&1; then
        echo "[OK] Réseau : $NETWORK"
    else
        echo "[ERREUR] Réseau absent : $NETWORK"
        ERRORS=$((ERRORS + 1))
    fi

    i=$((i + 1))

done


# ============================================================
# RESULTAT
# ============================================================

echo

if [ "$ERRORS" -eq 0 ]; then
    echo "VALIDATION OK"
    echo "Le manifeste peut passer à l'étape de préparation."
    exit 0
else
    echo "VALIDATION ECHEC : $ERRORS erreur(s)"
    echo "Reconstruction interdite."
    exit 1
fi
