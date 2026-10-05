#!/bin/sh

# ============================================================
# WebMon - Moteur de récupération V3
# ============================================================
#
# 1. panne confirmée
# 2. restart
# 3. attente de nouveaux contrôles
# 4. si toujours KO et mode=reconstruct :
#       suppression du conteneur défectueux
#       reconstruction depuis le manifeste
#
# Aucune boucle infinie :
# - 1 restart maximum par incident
# - 1 reconstruction maximum par incident
# ============================================================

set -u

STATE_FILE="${FAILURE_STATE_FILE:-/runtime/failure-state.json}"
POLICY_FILE="${RECOVERY_POLICIES_FILE:-/config/recovery-policies.json}"
ACTION_STATE_FILE="${RECOVERY_ACTION_STATE_FILE:-/runtime/recovery-action-state.json}"

RECOVERY_ROOT="${RECOVERY_ROOT:-/recovery}"
RECONSTRUCT_SCRIPT="${RECONSTRUCT_SCRIPT:-/scripts/reconstruct-container.sh}"
VALIDATE_SCRIPT="${VALIDATE_RECONSTRUCTION_SCRIPT:-/scripts/validate-recovery-manifest.sh}"

EXECUTION_ENABLED="${RECOVERY_EXECUTION_ENABLED:-0}"

# Nombre de nouveaux contrôles critiques après le restart
# avant d'autoriser une reconstruction.
ESCALATION_FAILURES="${RECOVERY_ESCALATION_FAILURES:-3}"


case "$ESCALATION_FAILURES" in
    ''|*[!0-9]*)
        echo "WebMon recovery: RECOVERY_ESCALATION_FAILURES invalide."
        exit 1
        ;;
esac


# ============================================================
# VALIDATION
# ============================================================

if ! [ -s "$STATE_FILE" ] ||
   ! jq -e 'type == "array"' "$STATE_FILE" >/dev/null 2>&1
then
    echo "WebMon recovery: failure-state invalide ou absent."
    exit 1
fi

if ! [ -s "$POLICY_FILE" ] ||
   ! jq -e 'type == "object"' "$POLICY_FILE" >/dev/null 2>&1
then
    echo "WebMon recovery: politique invalide ou absente."
    exit 1
fi

if ! [ -s "$ACTION_STATE_FILE" ] ||
   ! jq -e 'type == "object"' "$ACTION_STATE_FILE" >/dev/null 2>&1
then
    echo '{}' > "$ACTION_STATE_FILE"
fi

if ! [ -x "$RECONSTRUCT_SCRIPT" ]; then
    echo "WebMon recovery: moteur de reconstruction absent."
    exit 1
fi

if ! [ -x "$VALIDATE_SCRIPT" ]; then
    echo "WebMon recovery: validateur de reconstruction absent."
    exit 1
fi


# ============================================================
# ETAT DES ACTIONS
# ============================================================

update_action_state() {

    NAME="$1"
    INCIDENT="$2"
    RESTART_ATTEMPTED="$3"
    RECONSTRUCT_ATTEMPTED="$4"
    LAST_ACTION="$5"
    LAST_RESULT="$6"
    FAILURE_TYPE="$7"
    RESTART_FAILURE_COUNT="$8"

    NOW="$(date +%s)"
    TMP="${ACTION_STATE_FILE}.tmp.$$"

    jq \
        --arg name "$NAME" \
        --argjson incident "$INCIDENT" \
        --argjson restart "$RESTART_ATTEMPTED" \
        --argjson reconstruct "$RECONSTRUCT_ATTEMPTED" \
        --arg action "$LAST_ACTION" \
        --arg result "$LAST_RESULT" \
        --arg failure "$FAILURE_TYPE" \
        --argjson restart_count "$RESTART_FAILURE_COUNT" \
        --argjson now "$NOW" '

        .[$name] =
        (
            (.[$name] // {})
            +
            {
                incident_active: $incident,
                restart_attempted: $restart,
                reconstruction_attempted: $reconstruct,

                restart_failure_count: $restart_count,

                last_action: $action,
                last_result: $result,
                last_failure_type: $failure,
                last_action_at: $now
            }
        )

    ' "$ACTION_STATE_FILE" > "$TMP" &&
        mv -f "$TMP" "$ACTION_STATE_FILE"
}


# ============================================================
# PREFLIGHT RECONSTRUCTION
# ============================================================

preflight_reconstruction() {

    MANIFEST="$1"

    if ! [ -s "$MANIFEST" ]; then
        echo "WebMon recovery: manifeste absent : $MANIFEST" >&2
        return 1
    fi

    if ! jq -e --arg name "$NAME" '.container.name == $name' "$MANIFEST" >/dev/null; then
        echo "WebMon recovery: le manifeste ne correspond pas à $NAME." >&2
        return 1
    fi

    if ! "$VALIDATE_SCRIPT" "$MANIFEST" >/dev/null 2>&1; then
        echo "WebMon recovery: validation du manifeste échouée." >&2
        return 1
    fi

    IMAGE="$(jq -r '.container.image_id // .container.image // empty' "$MANIFEST")"

    if [ -z "$IMAGE" ] ||
       ! docker image inspect "$IMAGE" >/dev/null 2>&1
    then
        echo "WebMon recovery: image locale indisponible : $IMAGE" >&2
        return 1
    fi

    ENTRYPOINT_COUNT="$(
        jq '(.container.entrypoint // []) | length' "$MANIFEST"
    )"

    if [ "$ENTRYPOINT_COUNT" -gt 1 ]; then
        echo "WebMon recovery: entrypoint multiple non supporté." >&2
        return 1
    fi

    return 0
}


# ============================================================
# TRAITEMENT
# ============================================================

jq -c '.[]' "$STATE_FILE" |
while IFS= read -r service
do

    NAME="$(printf '%s' "$service" | jq -r '.name')"
    STATUS="$(printf '%s' "$service" | jq -r '.status // "unknown"')"
    CONFIRMED="$(printf '%s' "$service" | jq -r '.failure_confirmed // false')"
    DECISION="$(printf '%s' "$service" | jq -r '.recovery_decision // "none"')"
    FAILURE_TYPE="$(printf '%s' "$service" | jq -r '.failure_type // "unknown"')"
    RECOVERY_MODE="$(printf '%s' "$service" | jq -r '.recovery_mode // "observe-only"')"
    FAILURES="$(printf '%s' "$service" | jq -r '.consecutive_failures // 0')"

    MANIFEST_REL="$(
        printf '%s' "$service" |
            jq -r '.recovery_manifest // empty'
    )"


    # ========================================================
    # RETOUR A LA NORMALE
    # ========================================================

    if [ "$STATUS" = "ok" ]; then

        OLD_RESTART="$(
            jq -r --arg name "$NAME" \
                '.[$name].restart_attempted // false' \
                "$ACTION_STATE_FILE"
        )"

        OLD_RECONSTRUCT="$(
            jq -r --arg name "$NAME" \
                '.[$name].reconstruction_attempted // false' \
                "$ACTION_STATE_FILE"
        )"

        if [ "$OLD_RESTART" = "true" ] ||
           [ "$OLD_RECONSTRUCT" = "true" ]; then

            update_action_state \
                "$NAME" \
                false \
                false \
                false \
                "recovered" \
                "success" \
                "none" \
                0

            echo "WebMon recovery: $NAME revenu à l'état sain."
        fi

        continue
    fi


    # Panne pas encore confirmée
    [ "$CONFIRMED" = "true" ] || continue


    # ========================================================
    # MAINTENANCE
    # ========================================================

    MAINTENANCE="$(
        jq -r \
            --arg name "$NAME" \
            '.containers[$name].maintenance // false' \
            "$POLICY_FILE"
    )"

    if [ "$MAINTENANCE" = "true" ]; then
        echo "WebMon recovery: $NAME ignoré (maintenance)."
        continue
    fi


    # ========================================================
    # CONTENEUR MANQUANT : RECONSTRUCTION DIRECTE
    # ========================================================

    if [ "$DECISION" = "reconstruct_candidate" ]; then

        ALREADY_RECONSTRUCTED="$(
            jq -r --arg name "$NAME" \
                '.[$name].reconstruction_attempted // false' \
                "$ACTION_STATE_FILE"
        )"

        [ "$ALREADY_RECONSTRUCTED" = "false" ] || continue

        if [ -z "$MANIFEST_REL" ]; then
            echo "WebMon recovery: aucun manifeste pour $NAME." >&2
            continue
        fi

        MANIFEST="$RECOVERY_ROOT/$MANIFEST_REL"

        if ! preflight_reconstruction "$MANIFEST"; then
            continue
        fi

        if [ "$EXECUTION_ENABLED" != "1" ]; then
            echo "WebMon recovery: DRY-RUN reconstruct_candidate -> $NAME"
            continue
        fi

        echo "WebMon recovery: reconstruction de $NAME..."

        if "$RECONSTRUCT_SCRIPT" "$MANIFEST"; then

            update_action_state \
                "$NAME" \
                true \
                false \
                true \
                "reconstruction" \
                "success" \
                "$FAILURE_TYPE" \
                0

            echo "WebMon recovery: reconstruction exécutée pour $NAME."

        else

            update_action_state \
                "$NAME" \
                true \
                false \
                true \
                "reconstruction" \
                "failed" \
                "$FAILURE_TYPE" \
                0

            echo "WebMon recovery: ECHEC reconstruction de $NAME." >&2
        fi

        continue
    fi


    # ========================================================
    # RESTART / ESCALADE
    # ========================================================

    if [ "$DECISION" = "restart_candidate" ]; then

        RESTART_ATTEMPTED="$(
            jq -r --arg name "$NAME" \
                '.[$name].restart_attempted // false' \
                "$ACTION_STATE_FILE"
        )"


        # ----------------------------------------------------
        # PREMIERE ACTION : RESTART
        # ----------------------------------------------------

        if [ "$RESTART_ATTEMPTED" != "true" ]; then

            if [ "$EXECUTION_ENABLED" != "1" ]; then
                echo "WebMon recovery: DRY-RUN restart_candidate -> $NAME"
                continue
            fi

            if ! docker inspect "$NAME" >/dev/null 2>&1; then
                echo "WebMon recovery: $NAME absent, restart impossible."
                continue
            fi

            echo "WebMon recovery: restart de $NAME..."

            if docker restart "$NAME" >/dev/null 2>&1; then

                update_action_state \
                    "$NAME" \
                    true \
                    true \
                    false \
                    "restart" \
                    "success" \
                    "$FAILURE_TYPE" \
                    "$FAILURES"

                echo "WebMon recovery: restart exécuté pour $NAME."

            else

                update_action_state \
                    "$NAME" \
                    true \
                    true \
                    false \
                    "restart" \
                    "failed" \
                    "$FAILURE_TYPE" \
                    "$FAILURES"

                echo "WebMon recovery: ECHEC restart de $NAME." >&2
            fi

            continue
        fi


        # ----------------------------------------------------
        # Un restart a déjà été tenté.
        #
        # Si mode != reconstruct :
        # on s'arrête là.
        # ----------------------------------------------------

        if [ "$RECOVERY_MODE" != "reconstruct" ]; then
            echo "WebMon recovery: restart déjà tenté pour $NAME."
            continue
        fi


        RECONSTRUCTION_ATTEMPTED="$(
            jq -r --arg name "$NAME" \
                '.[$name].reconstruction_attempted // false' \
                "$ACTION_STATE_FILE"
        )"

        if [ "$RECONSTRUCTION_ATTEMPTED" = "true" ]; then
            continue
        fi


        RESTART_COUNT="$(
            jq -r --arg name "$NAME" \
                '.[$name].restart_failure_count // 0' \
                "$ACTION_STATE_FILE"
        )"

        ESCALATE_AT=$((RESTART_COUNT + ESCALATION_FAILURES))


        # ----------------------------------------------------
        # On laisse plusieurs nouveaux contrôles au service
        # pour avoir le temps de redevenir fonctionnel.
        # ----------------------------------------------------

        if [ "$FAILURES" -lt "$ESCALATE_AT" ]; then

            echo "WebMon recovery: $NAME toujours KO après restart, attente ($FAILURES/$ESCALATE_AT)."

            continue
        fi


        # ----------------------------------------------------
        # ESCALADE VERS RECONSTRUCTION
        # ----------------------------------------------------

        if [ -z "$MANIFEST_REL" ]; then
            echo "WebMon recovery: aucun manifeste pour $NAME." >&2
            continue
        fi

        MANIFEST="$RECOVERY_ROOT/$MANIFEST_REL"

        # Très important :
        # on valide TOUT AVANT de supprimer le conteneur.
        if ! preflight_reconstruction "$MANIFEST"; then
            echo "WebMon recovery: reconstruction refusée pour $NAME."
            continue
        fi


        if [ "$EXECUTION_ENABLED" != "1" ]; then
            echo "WebMon recovery: DRY-RUN escalation reconstruction -> $NAME"
            continue
        fi


        echo "WebMon recovery: escalade vers reconstruction de $NAME..."


        # Le conteneur existe encore mais sa couche writable
        # peut être corrompue.
        #
        # Les volumes nommés ne sont PAS supprimés.
        if docker inspect "$NAME" >/dev/null 2>&1; then

            if ! docker rm -f "$NAME" >/dev/null 2>&1; then
                echo "WebMon recovery: impossible de supprimer $NAME." >&2
                continue
            fi
        fi


        if "$RECONSTRUCT_SCRIPT" "$MANIFEST"; then

            update_action_state \
                "$NAME" \
                true \
                true \
                true \
                "reconstruction" \
                "success" \
                "$FAILURE_TYPE" \
                "$RESTART_COUNT"

            echo "WebMon recovery: reconstruction après restart exécutée pour $NAME."

        else

            update_action_state \
                "$NAME" \
                true \
                true \
                true \
                "reconstruction" \
                "failed" \
                "$FAILURE_TYPE" \
                "$RESTART_COUNT"

            echo "WebMon recovery: ECHEC reconstruction de $NAME." >&2
        fi

        continue
    fi

done
