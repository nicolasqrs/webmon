#!/bin/sh

# ============================================================
# WebMon - Capture d'un manifeste de reconstruction
# ============================================================
#
# Lecture seule vis-à-vis de Docker.
#
# Le script lit docker inspect et construit une fiche
# persistante utilisable si le conteneur disparaît plus tard.
#
# ATTENTION :
# les variables d'environnement sont sauvegardées avec leurs
# valeurs, car elles peuvent être nécessaires pour reconstruire
# fidèlement le service.
#
# Le fichier généré est donc protégé en chmod 600.
# ============================================================

set -eu
umask 077

NAME="${1:-}"

if [ -z "$NAME" ]; then
    echo "Usage : $0 <nom-du-conteneur>"
    exit 1
fi

if ! docker inspect "$NAME" >/dev/null 2>&1; then
    echo "ERREUR : conteneur introuvable : $NAME"
    exit 1
fi

OUT_DIR="${RECOVERY_CAPTURE_DIR:-recovery/captured}"
OUT_FILE="$OUT_DIR/$NAME.json"

mkdir -p "$OUT_DIR"

TMP="$(mktemp)"

cleanup() {
    rm -f "$TMP"
}

trap cleanup EXIT INT TERM

docker inspect "$NAME" > "$TMP"

jq '
    .[0] as $c |

    {
        schema_version: 1,

        captured_at:
            (
                now
                | todateiso8601
            ),

        container: {

            container_id: $c.Id,
            image_id: $c.Image,

            name:
                (
                    $c.Name
                    | ltrimstr("/")
                ),

            image:
                $c.Config.Image,

            entrypoint:
                ($c.Config.Entrypoint // null),

            command:
                ($c.Config.Cmd // []),

            environment:
                (
                    reduce (
                        ($c.Config.Env // [])[]
                        |
                        capture(
                            "^(?<key>[^=]+)=(?<value>.*)$"
                        )
                    ) as $env
                    (
                        {};
                        .[$env.key] = $env.value
                    )
                ),

            user:
                ($c.Config.User // ""),

            working_dir:
                ($c.Config.WorkingDir // ""),

            restart_policy: {
                name:
                    (
                        $c.HostConfig.RestartPolicy.Name
                        // "no"
                    ),

                maximum_retry_count:
                    (
                        $c.HostConfig.RestartPolicy.MaximumRetryCount
                        // 0
                    )
            },

            mounts:
                [
                    ($c.Mounts // [])[]
                    |
                    {
                        type: .Type,

                        source:
                            (
                                if .Type == "volume"
                                then .Name
                                else .Source
                                end
                            ),

                        target: .Destination,

                        read_only:
                            (
                                .RW
                                | not
                            )
                    }
                ],

            networks:
                [
                    (
                        $c.NetworkSettings.Networks
                        // {}
                        | to_entries[]
                    )
                    |
                    {
                        name: .key,
                        aliases:
                            (.value.Aliases // [])
                    }
                ],

            ports:
                [
                    (
                        $c.HostConfig.PortBindings
                        // {}
                        | to_entries[]
                    ) as $port

                    |

                    ($port.value // [])[] as $binding

                    |

                    {
                        container_port:
                            $port.key,

                        host_ip:
                            ($binding.HostIp // ""),

                        host_port:
                            ($binding.HostPort // "")
                    }
                ],

            healthcheck:
                ($c.Config.Healthcheck // null),

            labels:
                ($c.Config.Labels // {})
        },

        recovery: {
            source: "docker-inspect"
        }
    }
' "$TMP" > "$OUT_FILE.tmp"

mv "$OUT_FILE.tmp" "$OUT_FILE"

# Le manifeste peut contenir des mots de passe,
# tokens ou autres secrets dans les variables d'environnement.
chmod 600 "$OUT_FILE"

echo "Manifeste capturé : $OUT_FILE"
