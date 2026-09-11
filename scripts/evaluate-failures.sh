#!/bin/sh

# ============================================================
# WebMon - Evaluation des pannes
# ============================================================
#
# Cette première version NE FAIT AUCUNE ACTION.
#
# Elle :
# - récupère directement l'état réel des conteneurs Docker ;
# - récupère les contrôles fonctionnels WebMon ;
# - compte les échecs consécutifs ;
# - confirme une panne après plusieurs échecs.
#
# AUCUN restart.
# AUCUNE reconstruction.
#
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

CUSTOM_FILE="${FUNCTIONAL_FILE:-/runtime/functional.json}"
HTTP_FILE="${HTTP_FUNCTIONAL_FILE:-/runtime/http-functional.json}"

# Politique de récupération.
# Par sécurité, tous les conteneurs restent observe-only
# si le fichier est absent ou invalide.
POLICY_FILE="${RECOVERY_POLICIES_FILE:-/config/recovery-policies.json}"

# Inventaire persistant des conteneurs que WebMon connaît
# et s'attend à retrouver.
EXPECTED_FILE="${EXPECTED_CONTAINERS_FILE:-/recovery/expected-containers.json}"

COUNTERS_FILE="${FAILURE_COUNTERS_FILE:-/runtime/failure-counters.json}"
STATE_FILE="${FAILURE_STATE_FILE:-/runtime/failure-state.json}"

# Nombre d'échecs consécutifs nécessaires avant
# de considérer la panne comme confirmée.
THRESHOLD="${FAILURE_THRESHOLD:-3}"


# ============================================================
# FICHIERS TEMPORAIRES
# ============================================================

DOCKER_TMP="/tmp/webmon-docker-$$.json"
CUSTOM_TMP="/tmp/webmon-custom-$$.json"
HTTP_TMP="/tmp/webmon-http-$$.json"
POLICY_TMP="/tmp/webmon-policy-$$.json"
EXPECTED_TMP="/tmp/webmon-expected-$$.json"
CURRENT_TMP="/tmp/webmon-current-$$.json"
ENRICHED_TMP="/tmp/webmon-enriched-$$.json"

COUNTERS_TMP="${COUNTERS_FILE}.tmp.$$"
STATE_TMP="${STATE_FILE}.tmp.$$"


# Nettoyage automatique des fichiers temporaires.
cleanup() {
    rm -f \
        "$DOCKER_TMP" \
        "$CUSTOM_TMP" \
        "$HTTP_TMP" \
        "$POLICY_TMP" \
        "$EXPECTED_TMP" \
        "$CURRENT_TMP" \
        "$ENRICHED_TMP"
}

trap cleanup EXIT INT TERM


# ============================================================
# 1. ETAT DOCKER REEL
# ============================================================
#
# On utilise docker inspect directement.
#
# C'est volontaire :
# le moteur de panne ne dépend ainsi ni du frontend
# ni du backend WebMon.
# ============================================================

CONTAINER_IDS="$(docker ps -aq)"


if [ -n "$CONTAINER_IDS" ]; then

    docker inspect $CONTAINER_IDS > "$DOCKER_TMP"

else

    echo '[]' > "$DOCKER_TMP"

fi


# ============================================================
# 2. CONTROLES WEBMON PERSONNALISES
# ============================================================

if [ -s "$CUSTOM_FILE" ] && jq -e . "$CUSTOM_FILE" >/dev/null 2>&1; then

    cp "$CUSTOM_FILE" "$CUSTOM_TMP"

else

    echo '[]' > "$CUSTOM_TMP"

fi


# ============================================================
# 3. CONTROLES HTTP AUTOMATIQUES
# ============================================================

if [ -s "$HTTP_FILE" ] && jq -e . "$HTTP_FILE" >/dev/null 2>&1; then

    cp "$HTTP_FILE" "$HTTP_TMP"

else

    echo '[]' > "$HTTP_TMP"

fi


# ============================================================
# 4. POLITIQUE DE RECUPERATION
# ============================================================
#
# Le fichier est purement déclaratif.
# Aucune action de récupération n'est exécutée ici.
#
# En cas de fichier absent/invalide :
# observe-only est utilisé par défaut.
# ============================================================

if [ -s "$POLICY_FILE" ] && jq -e . "$POLICY_FILE" >/dev/null 2>&1; then

    cp "$POLICY_FILE" "$POLICY_TMP"

else

    echo '{"default":{"mode":"observe-only"},"containers":{}}' > "$POLICY_TMP"

fi


# ============================================================
# INVENTAIRE DES CONTENEURS ATTENDUS
# ============================================================

if [ -s "$EXPECTED_FILE" ] &&    jq -e 'type == "array"' "$EXPECTED_FILE" >/dev/null 2>&1
then

    cp "$EXPECTED_FILE" "$EXPECTED_TMP"

else

    echo '[]' > "$EXPECTED_TMP"

fi


# ============================================================
# 5. ETAT FONCTIONNEL ACTUEL
# ============================================================
#
# Priorité :
#
# 1. contrôle WebMon personnalisé
# 2. healthcheck Docker
# 3. contrôle HTTP automatique
# 4. aucun contrôle
#
# ============================================================

jq -n \
    --slurpfile docker "$DOCKER_TMP" \
    --slurpfile custom "$CUSTOM_TMP" \
    --slurpfile http "$HTTP_TMP" '

    ($docker[0] // []) as $containers |
    ($custom[0] // []) as $customChecks |
    ($http[0] // []) as $httpChecks |

    [
        $containers[] |

        . as $container |

        ($container.Name | ltrimstr("/")) as $name |

        (
            $container.Config.Labels["webmon.internal"]
            // "false"
        ) as $internal |

        # Les composants techniques internes de WebMon
        # ne participent pas au moteur de récupération.
        select($internal != "true") |

        (
            first(
                $customChecks[]
                | select(.name == $name)
            ) // null
        ) as $custom |

        (
            first(
                $httpChecks[]
                | select(.name == $name)
            ) // null
        ) as $http |

        (
            ($container.State.Status // "unknown")
            | ascii_downcase
        ) as $dockerState |

        (
            ($container.State.Health.Status // "")
            | ascii_downcase
        ) as $healthStatus |

        (
            ($container.Config.Healthcheck // null) != null
        ) as $hasHealthcheck |


        # ----------------------------------------------------
        # PRIORITE 1 : contrôle personnalisé WebMon
        # ----------------------------------------------------

        if $custom != null then

            {
                name: $name,
                source: "webmon",
                docker_state: $dockerState,

                status:
                    (
                        if $custom.functional == 1
                        then "ok"
                        else "critical"
                        end
                    )
            }


        # ----------------------------------------------------
        # PRIORITE 2 : healthcheck Docker
        # ----------------------------------------------------

        elif $hasHealthcheck then

            {
                name: $name,
                source: "docker-healthcheck",
                docker_state: $dockerState,
                health_status: $healthStatus,

                status:
                    (
                        if $dockerState != "running" then
                            "critical"

                        elif $healthStatus == "healthy" then
                            "ok"

                        elif $healthStatus == "starting" then
                            "starting"

                        else
                            "critical"
                        end
                    )
            }


        # ----------------------------------------------------
        # PRIORITE 3 : HTTP automatique
        # ----------------------------------------------------

        elif $http != null then

            {
                name: $name,
                source: "auto-http",
                docker_state: $dockerState,

                status:
                    (
                        if $http.functional == 1
                        then "ok"
                        else "critical"
                        end
                    )
            }


        # ----------------------------------------------------
        # PRIORITE 4 : aucun contrôle
        # ----------------------------------------------------

        else

            {
                name: $name,
                source: null,
                docker_state: $dockerState,
                status: "unconfigured"
            }

        end
    ]
' > "$CURRENT_TMP"


# ============================================================
# AJOUT DE LA POLITIQUE DE RECUPERATION
# ============================================================
#
# Priorité :
# 1. politique spécifique au conteneur ;
# 2. politique default ;
# 3. observe-only.
#
# Toute valeur inconnue retombe sur observe-only.
# ============================================================

jq \
    --slurpfile policy "$POLICY_TMP" \
    --slurpfile expected "$EXPECTED_TMP" '

    ($policy[0] // {}) as $policy |
    ($expected[0] // []) as $expected |

    . as $current |

    ($current | map(.name)) as $existingNames |

    # --------------------------------------------------------
    # Services actuellement présents dans Docker
    # --------------------------------------------------------

    (
        $current
        | map(
            . as $service |

            (
                first(
                    $expected[]?
                    | select(.name == $service.name)
                ) // null
            ) as $inventory |

            (
                $policy.containers[$service.name].mode
                // $policy.default.mode
                // "observe-only"
            ) as $requestedMode |

            . + {
                recovery_manifest: ($inventory.manifest // null),
                captured_at: ($inventory.captured_at // null),

                recovery_mode:
                    (
                        if (
                            $requestedMode == "observe-only"
                            or $requestedMode == "restart"
                            or $requestedMode == "reconstruct"
                        )
                        then $requestedMode
                        else "observe-only"
                        end
                    )
            }
        )
    ) as $presentServices |

    # --------------------------------------------------------
    # Services explicitement déclarés dans la politique
    # mais totalement absents de Docker.
    # --------------------------------------------------------

    (
        ($expected // [])
        | map(
            . as $expectedService |

            select(
                ($existingNames | index($expectedService.name)) == null
            )

            |

            (
                $policy.containers[$expectedService.name].mode
                // $policy.default.mode
                // "observe-only"
            ) as $requestedMode |

            {
                name: $expectedService.name,
                source: null,
                docker_state: "missing",
                status: "critical",

                recovery_manifest:
                    ($expectedService.manifest // null),

                captured_at:
                    ($expectedService.captured_at // null),

                recovery_mode:
                    (
                        if (
                            $requestedMode == "observe-only"
                            or $requestedMode == "restart"
                            or $requestedMode == "reconstruct"
                        )
                        then $requestedMode
                        else "observe-only"
                        end
                    )
            }
        )
    ) as $missingServices |

    ($presentServices + $missingServices)

' "$CURRENT_TMP" > "$ENRICHED_TMP"

mv "$ENRICHED_TMP" "$CURRENT_TMP"


# ============================================================
# 5. ANCIENS COMPTEURS
# ============================================================

if ! [ -s "$COUNTERS_FILE" ] ||
   ! jq -e 'type == "object"' "$COUNTERS_FILE" >/dev/null 2>&1
then

    echo '{}' > "$COUNTERS_FILE"

fi


# ============================================================
# 6. MISE A JOUR DES COMPTEURS
# ============================================================
#
# CRITICAL :
# compteur + 1
#
# OK / STARTING / UNCONFIGURED :
# compteur remis à zéro
#
# ============================================================

jq -n \
    --slurpfile current "$CURRENT_TMP" \
    --slurpfile previous "$COUNTERS_FILE" '

    ($current[0] // []) as $states |
    ($previous[0] // {}) as $old |

    reduce $states[] as $service
    (
        {};

        .[$service.name] =
            (
                if $service.status == "critical"
                then (($old[$service.name] // 0) + 1)
                else 0
                end
            )
    )
' > "$COUNTERS_TMP"


mv -f "$COUNTERS_TMP" "$COUNTERS_FILE"


# ============================================================
# 7. GENERATION DE L'ETAT FINAL
# ============================================================

jq -n \
    --argjson threshold "$THRESHOLD" \
    --slurpfile current "$CURRENT_TMP" \
    --slurpfile counters "$COUNTERS_FILE" '

    ($current[0] // []) as $states |
    ($counters[0] // {}) as $counts |

    [
        $states[] |

        . as $service |

        ($counts[$service.name] // 0) as $failures |

(
    $service.status == "critical"
    and
    $failures >= $threshold
) as $confirmed |

(
    if $service.status == "ok" then
        "none"

    elif $service.status == "starting" then
        "starting"

    elif $service.status == "unconfigured" then
        "unconfigured"

    elif $service.docker_state == "missing" then
        "missing_container"

    elif $service.docker_state == "restarting" then
        "crash_loop"

    elif $service.docker_state != "running" then
        "container_stopped"

    elif (
        $service.source == "docker-healthcheck"
        and
        ($service.health_status // "") == "unhealthy"
    ) then
        "docker_unhealthy"

    elif $service.status == "critical" then
        "functional_failure"

    else
        "unknown"
    end
) as $failureType |

($service.recovery_mode // "observe-only") as $recoveryMode |

$service + {

    consecutive_failures: $failures,

    failure_confirmed: $confirmed,

    failure_type: $failureType,

    recovery_decision:
        (
            if $confirmed != true then
                "none"

            elif $recoveryMode == "observe-only" then
                "no_action"

            elif (
                $failureType == "missing_container"
                and
                $recoveryMode == "restart"
            ) then
                "reconstruction_not_authorized"

            elif (
                $failureType == "missing_container"
                and
                $recoveryMode == "reconstruct"
            ) then
                "reconstruct_candidate"

            elif (
                $recoveryMode == "restart"
                or
                $recoveryMode == "reconstruct"
            ) then
                "restart_candidate"

            else
                "no_action"
            end
        ),

    action: "none"
}

    ]
' > "$STATE_TMP"


mv -f "$STATE_TMP" "$STATE_FILE"


# ============================================================
# 8. RESUME
# ============================================================

echo "=== WebMon - Etat des pannes ==="

jq -r '
    .[] |
    "\(.name): status=\(.status) failures=\(.consecutive_failures) confirmed=\(.failure_confirmed) action=\(.action)"
' "$STATE_FILE"
