#!/bin/sh

# ============================================================
# WebMon - Moteur de contrôle HTTP automatique
# ============================================================
#
# Trois méthodes sont disponibles :
#
# HOST
#   Le service publie un port sur l'hôte Docker.
#
# INTERNAL
#   Le service partage déjà un réseau Docker avec
#   webmon-monitor.
#
# PROBE
#   Le service est sur un réseau Docker isolé.
#   WebMon crée alors une petite sonde BusyBox temporaire
#   sur ce réseau pour effectuer le test HTTP.
#
# Les contrôles détectés sont mémorisés sous la forme :
#
# nom|mode|network|port|url
#
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

CHECKS_FILE="${HTTP_CHECKS_FILE:-/runtime/http-checks.tsv}"
RESULT_FILE="${HTTP_FUNCTIONAL_FILE:-/runtime/http-functional.json}"

HTTP_HOST="${HTTP_HOST:-host.docker.internal}"
TIMEOUT="${HTTP_TIMEOUT:-3}"

MONITOR_NAME="${MONITOR_NAME:-webmon-monitor}"

PROBE_NAME="${HTTP_PROBE_NAME:-webmon-probe}"


# Ports susceptibles d'héberger un service HTTP.
WEB_PORTS="
80
3000
3001
3100
5000
8000
8080
8096
8888
9000
9080
9090
9100
9187
"


# Endpoints courants essayés automatiquement.
HTTP_PATHS="
/
/health
/healthz
/ready
/metrics
"


RESULT_TMP="${RESULT_FILE}.tmp"

touch "$CHECKS_FILE"


# ============================================================
# FONCTIONS UTILITAIRES
# ============================================================


# ------------------------------------------------------------
# Vérifie si un port fait partie des ports web connus.
# ------------------------------------------------------------

is_web_port() {

    SEARCHED_PORT="$1"

    for WEB_PORT in $WEB_PORTS
    do

        if [ "$SEARCHED_PORT" = "$WEB_PORT" ]; then
            return 0
        fi

    done

    return 1
}


# ------------------------------------------------------------
# Vérifie si un code HTTP représente un service fonctionnel.
#
# 2xx = succès
# 3xx = redirection valide
# ------------------------------------------------------------

is_http_ok() {

    STATUS_CODE="$1"

    case "$STATUS_CODE" in

        2??|3??)
            return 0
            ;;

        *)
            return 1
            ;;

    esac
}


# ------------------------------------------------------------
# Test HTTP effectué directement depuis webmon-monitor.
#
# Utilisé pour :
# - HOST
# - INTERNAL
# ------------------------------------------------------------

get_http_status_direct() {

    URL="$1"

    RESPONSE="$(
        wget \
            -S \
            -O /dev/null \
            -T "$TIMEOUT" \
            "$URL" \
            2>&1 || true
    )"

    printf '%s\n' "$RESPONSE" |
    awk '
        /HTTP\/[0-9.]+ [0-9][0-9][0-9]/ {
            code=$2
        }

        END {
            print code
        }
    '
}


# ------------------------------------------------------------
# Test HTTP avec la sonde permanente WebMon.
#
# Fonctionnement :
#
# 1. webmon-probe reste normalement sur son réseau dédié.
#
# 2. WebMon connecte temporairement la sonde au réseau
#    contenant le service à tester.
#
# 3. La requête HTTP est exécutée depuis webmon-probe.
#
# 4. La sonde est immédiatement déconnectée du réseau cible.
#
# Si un ancien test a laissé la sonde connectée accidentellement,
# la déconnexion à la fin remettra automatiquement la situation
# au propre.
# ------------------------------------------------------------

get_http_status_probe() {

    NETWORK="$1"
    URL="$2"


    # --------------------------------------------------------
    # La sonde existe-t-elle ?
    # --------------------------------------------------------

    if ! docker inspect "$PROBE_NAME" >/dev/null 2>&1; then
        echo ""
        return
    fi


    # --------------------------------------------------------
    # La sonde est-elle démarrée ?
    # --------------------------------------------------------

    PROBE_STATE="$(
        docker inspect \
            --format '{{.State.Status}}' \
            "$PROBE_NAME" \
            2>/dev/null
    )"


    if [ "$PROBE_STATE" != "running" ]; then
        echo ""
        return
    fi


    # --------------------------------------------------------
    # Connexion temporaire au réseau cible
    # --------------------------------------------------------
    #
    # Si elle est déjà connectée à cause d'un ancien test
    # interrompu, Docker retournera simplement une erreur
    # que l'on peut ignorer ici.
    # --------------------------------------------------------

    docker network connect \
        "$NETWORK" \
        "$PROBE_NAME" \
        >/dev/null 2>&1 || true


    # --------------------------------------------------------
    # Vérification que la connexion réseau existe réellement
    # --------------------------------------------------------

    if ! docker inspect \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        "$PROBE_NAME" \
        2>/dev/null |
        grep -Fx "$NETWORK" >/dev/null 2>&1
    then
        echo ""
        return
    fi


    # --------------------------------------------------------
    # Test HTTP depuis la sonde
    # --------------------------------------------------------

    RESPONSE="$(
        docker exec \
            "$PROBE_NAME" \
            wget \
                -S \
                -O /dev/null \
                -T "$TIMEOUT" \
                "$URL" \
            2>&1 || true
    )"


    # --------------------------------------------------------
    # Déconnexion immédiate du réseau cible
    # --------------------------------------------------------

    docker network disconnect \
        "$NETWORK" \
        "$PROBE_NAME" \
        >/dev/null 2>&1 || true


    # --------------------------------------------------------
    # Extraction du code HTTP
    # --------------------------------------------------------

    printf '%s\n' "$RESPONSE" |
    awk '
        /HTTP\/[0-9.]+ [0-9][0-9][0-9]/ {
            code=$2
        }

        END {
            print code
        }
    '
}


# ------------------------------------------------------------
# Le conteneur possède-t-il déjà un contrôle HTTP mémorisé ?
# ------------------------------------------------------------

is_already_known() {

    NAME="$1"

    awk -F '|' -v name="$NAME" '$1 == name {found=1} END {exit !found}' "$CHECKS_FILE"
}


# ------------------------------------------------------------
# Mémorise un nouveau contrôle.
# ------------------------------------------------------------

remember_check() {

    NAME="$1"
    MODE="$2"
    NETWORK="$3"
    PORT="$4"
    URL="$5"

    echo "${NAME}|${MODE}|${NETWORK}|${PORT}|${URL}" \
        >> "$CHECKS_FILE"

    echo "HTTP détecté : ${NAME} | ${MODE} | ${URL}"
}


# ============================================================
# RESEAUX ACTUELS DE WEBMON-MONITOR
# ============================================================

MONITOR_NETWORKS="$(
    docker inspect \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
        "$MONITOR_NAME" \
        2>/dev/null
)"


# ============================================================
# 1. DECOUVERTE AUTOMATIQUE DES NOUVEAUX SERVICES
# ============================================================

docker ps --format '{{.Names}}' | while read -r NAME
do

    [ -z "$NAME" ] && continue


    # WebMon ne se teste pas lui-même.
    if [ "$NAME" = "$MONITOR_NAME" ]; then
        continue
    fi

    # Les sondes internes et les workers avec heartbeat n'ont pas besoin de scan HTTP.
    INTERNAL="$(docker inspect --format '{{index .Config.Labels "webmon.internal"}}' "$NAME" 2>/dev/null)"
    [ "$INTERNAL" = "true" ] && continue
    CUSTOM=0
    for WORKER in ${WORKERS-}; do
        [ "${WORKER%%:*}" = "$NAME" ] && CUSTOM=1
    done
    [ "$CUSTOM" -eq 1 ] && continue


    # --------------------------------------------------------
    # Healthcheck Docker natif ?
    # --------------------------------------------------------

    HAS_HEALTHCHECK="$(
        docker inspect \
            --format '{{if .State.Health}}yes{{else}}no{{end}}' \
            "$NAME" \
            2>/dev/null
    )"


    # Le healthcheck Docker reste prioritaire.
    if [ "$HAS_HEALTHCHECK" = "yes" ]; then
        continue
    fi


    # --------------------------------------------------------
    # Déjà connu ?
    # --------------------------------------------------------

    if is_already_known "$NAME"; then
        continue
    fi


    # ========================================================
    # MODE 1 : HOST
    # ========================================================
    #
    # On cherche d'abord un port publié sur la VM.
    # ========================================================

    PUBLISHED_PORTS="$(
        docker inspect \
            --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{if $bindings}}{{range $bindings}}{{println $port .HostPort}}{{end}}{{end}}{{end}}' \
            "$NAME" \
            2>/dev/null
    )"


    printf '%s\n' "$PUBLISHED_PORTS" |
    while read -r PORT_PROTOCOL HOST_PORT
    do

        [ -z "$PORT_PROTOCOL" ] && continue
        [ -z "$HOST_PORT" ] && continue


        INTERNAL_PORT="${PORT_PROTOCOL%/*}"
        PROTOCOL="${PORT_PROTOCOL#*/}"


        [ "$PROTOCOL" != "tcp" ] && continue


        if ! is_web_port "$INTERNAL_PORT"; then
            continue
        fi


        for PATH_TO_TEST in $HTTP_PATHS
        do

            URL="http://${HTTP_HOST}:${HOST_PORT}${PATH_TO_TEST}"

            STATUS_CODE="$(
                get_http_status_direct "$URL"
            )"


            if is_http_ok "$STATUS_CODE"; then

                remember_check \
                    "$NAME" \
                    "host" \
                    "-" \
                    "$HOST_PORT" \
                    "$URL"

                break 2
            fi

        done

    done


    # Si HOST a trouvé quelque chose, inutile d'aller plus loin.
    if is_already_known "$NAME"; then
        continue
    fi


    # ========================================================
    # INFORMATIONS RESEAU DU CONTENEUR
    # ========================================================

    TARGET_NETWORKS="$(
        docker inspect \
            --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
            "$NAME" \
            2>/dev/null
    )"


    EXPOSED_PORTS="$(
        docker inspect \
            --format '{{range $port, $_ := .Config.ExposedPorts}}{{println $port}}{{end}}' \
            "$NAME" \
            2>/dev/null
    )"


    # ========================================================
    # MODE 2 : INTERNAL
    # ========================================================
    #
    # Recherche d'un réseau déjà commun à la cible et
    # webmon-monitor.
    # ========================================================

    SHARED_NETWORK=""


    for TARGET_NETWORK in $TARGET_NETWORKS
    do

        for MONITOR_NETWORK in $MONITOR_NETWORKS
        do

            if [ "$TARGET_NETWORK" = "$MONITOR_NETWORK" ]; then

                SHARED_NETWORK="$TARGET_NETWORK"
                break

            fi

        done


        [ -n "$SHARED_NETWORK" ] && break

    done


    if [ -n "$SHARED_NETWORK" ]; then

        FOUND=0


        # ====================================================
        # FALLBACK : aucun ExposedPorts déclaré
        # ====================================================
        #
        # Certains services écoutent bien sur un port TCP mais
        # leur image Docker ne déclare aucun EXPOSE.
        #
        # Exemple actuel : Promtail écoute sur 9080 mais
        # .Config.ExposedPorts vaut null.
        #
        # Dans ce cas, et uniquement parce que le conteneur
        # partage déjà un réseau avec webmon-monitor, WebMon
        # essaie prudemment la liste des ports web connus.
        # ====================================================

        INTERNAL_CANDIDATE_PORTS="$EXPOSED_PORTS"

        if [ -z "$INTERNAL_CANDIDATE_PORTS" ]; then

            INTERNAL_CANDIDATE_PORTS="$(
                for PORT in $WEB_PORTS
                do
                    echo "${PORT}/tcp"
                done
            )"

        fi


        for PORT_PROTOCOL in $INTERNAL_CANDIDATE_PORTS
        do

            INTERNAL_PORT="${PORT_PROTOCOL%/*}"
            PROTOCOL="${PORT_PROTOCOL#*/}"


            [ "$PROTOCOL" != "tcp" ] && continue


            if ! is_web_port "$INTERNAL_PORT"; then
                continue
            fi


            for PATH_TO_TEST in $HTTP_PATHS
            do

                URL="http://${NAME}:${INTERNAL_PORT}${PATH_TO_TEST}"

                STATUS_CODE="$(
                    get_http_status_direct "$URL"
                )"


                if is_http_ok "$STATUS_CODE"; then

                    remember_check \
                        "$NAME" \
                        "internal" \
                        "$SHARED_NETWORK" \
                        "$INTERNAL_PORT" \
                        "$URL"

                    FOUND=1
                    break
                fi

            done


            [ "$FOUND" -eq 1 ] && break

        done

    fi


    # Si INTERNAL a fonctionné, inutile d'utiliser une sonde.
    if is_already_known "$NAME"; then
        continue
    fi


    # ========================================================
    # MODE 3 : PROBE
    # ========================================================
    #
    # Aucun réseau commun avec WebMon.
    #
    # On lance temporairement BusyBox sur chacun des réseaux
    # du conteneur jusqu'à trouver un service HTTP.
    # ========================================================

    FOUND=0


    for TARGET_NETWORK in $TARGET_NETWORKS
    do

        # Ces réseaux spéciaux ne sont pas adaptés à cette
        # méthode de découverte.
        [ "$TARGET_NETWORK" = "host" ] && continue
        [ "$TARGET_NETWORK" = "none" ] && continue


        for PORT_PROTOCOL in $EXPOSED_PORTS
        do

            INTERNAL_PORT="${PORT_PROTOCOL%/*}"
            PROTOCOL="${PORT_PROTOCOL#*/}"


            [ "$PROTOCOL" != "tcp" ] && continue


            if ! is_web_port "$INTERNAL_PORT"; then
                continue
            fi


            for PATH_TO_TEST in $HTTP_PATHS
            do

                URL="http://${NAME}:${INTERNAL_PORT}${PATH_TO_TEST}"


                STATUS_CODE="$(
                    get_http_status_probe \
                        "$TARGET_NETWORK" \
                        "$URL"
                )"


                if is_http_ok "$STATUS_CODE"; then

                    remember_check \
                        "$NAME" \
                        "probe" \
                        "$TARGET_NETWORK" \
                        "$INTERNAL_PORT" \
                        "$URL"

                    FOUND=1
                    break
                fi

            done


            [ "$FOUND" -eq 1 ] && break

        done


        [ "$FOUND" -eq 1 ] && break

    done

done


# ============================================================
# 2. VERIFICATION DES CONTROLES MEMORISES
# ============================================================

echo "[" > "$RESULT_TMP"

FIRST=1


while IFS='|' read -r NAME MODE NETWORK PORT URL
do

    [ -z "$NAME" ] && continue


    # --------------------------------------------------------
    # Etat du conteneur Docker
    # --------------------------------------------------------

    RUNNING=0


    if docker inspect "$NAME" >/dev/null 2>&1; then

        STATE="$(
            docker inspect \
                --format '{{.State.Status}}' \
                "$NAME" \
                2>/dev/null
        )"


        if [ "$STATE" = "running" ]; then
            RUNNING=1
        fi

    fi


    FUNCTIONAL=0
    STATUS_CODE=0


    # --------------------------------------------------------
    # Test fonctionnel
    # --------------------------------------------------------

    if [ "$RUNNING" -eq 1 ]; then


        case "$MODE" in


            host|internal)

                DETECTED_CODE="$(
                    get_http_status_direct "$URL"
                )"

                ;;


            probe)

                DETECTED_CODE="$(
                    get_http_status_probe \
                        "$NETWORK" \
                        "$URL"
                )"

                ;;


            *)

                DETECTED_CODE=""

                ;;

        esac


        if [ -n "$DETECTED_CODE" ]; then
            STATUS_CODE="$DETECTED_CODE"
        fi


        if is_http_ok "$STATUS_CODE"; then
            FUNCTIONAL=1
        fi

    fi


    # --------------------------------------------------------
    # Génération JSON
    # --------------------------------------------------------

    if [ "$FIRST" -eq 0 ]; then
        echo "," >> "$RESULT_TMP"
    fi


    FIRST=0


    printf \
        '{"name":"%s","running":%s,"functional":%s,"source":"auto-http","mode":"%s","network":"%s","port":%s,"url":"%s","status_code":%s}' \
        "$NAME" \
        "$RUNNING" \
        "$FUNCTIONAL" \
        "$MODE" \
        "$NETWORK" \
        "$PORT" \
        "$URL" \
        "$STATUS_CODE" \
        >> "$RESULT_TMP"

done < "$CHECKS_FILE"


echo "" >> "$RESULT_TMP"
echo "]" >> "$RESULT_TMP"


# Remplacement atomique du résultat.
mv "$RESULT_TMP" "$RESULT_FILE"


echo "Contrôles HTTP terminés : $RESULT_FILE"
