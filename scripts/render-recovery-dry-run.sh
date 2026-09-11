#!/bin/sh

# ============================================================
# WebMon - Dry-run d'une reconstruction
# ============================================================
#
# Ce script :
# - valide le manifeste ;
# - prépare les commandes Docker ;
# - les AFFICHE uniquement.
#
# AUCUNE commande docker create/start/network connect
# n'est exécutée.
# ============================================================

set -eu

MANIFEST="${1:-}"

if [ -z "$MANIFEST" ]; then
    echo "Usage : $0 <manifest.json>"
    exit 1
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

echo "=== 1. Validation du manifeste ==="
echo

"$SCRIPT_DIR/validate-recovery-manifest.sh" "$MANIFEST"

echo
echo "=== 2. Plan de reconstruction DRY-RUN ==="
echo

# ------------------------------------------------------------
# Commande docker create
# ------------------------------------------------------------

CREATE_CMD="$(
jq -r '

    .container as $c |

    (
        reduce ($c.mounts[]?) as $m
        (
            [];
            . + [
                "--mount",
                (
                    "type=" + $m.type
                    + ",source=" + $m.source
                    + ",target=" + $m.target
                    + (
                        if ($m.read_only // false)
                        then ",readonly"
                        else ""
                        end
                    )
                )
            ]
        )
    ) as $mountArgs |

    (
        reduce (
            ($c.environment // {})
            | to_entries[]
        ) as $e
        (
            [];
            . + [
                "--env",
                ($e.key + "=" + ($e.value | tostring))
            ]
        )
    ) as $envArgs |

    (
        reduce (($c.ports // [])[]) as $p
        (
            [];

            . + [
                "--publish",

                (
                    if (($p.host_port // "") | length) == 0 then
                        $p.container_port

                    elif (($p.host_ip // "") | length) == 0 then
                        (
                            $p.host_port
                            + ":"
                            + $p.container_port
                        )

                    else
                        (
                            $p.host_ip
                            + ":"
                            + $p.host_port
                            + ":"
                            + $p.container_port
                        )
                    end
                )
            ]
        )
    ) as $portArgs |

    (
        if (($c.networks // []) | length) > 0
        then [
            "--network",
            $c.networks[0].name
        ]
        else []
        end
    ) as $networkArgs |

    (
        [
            "docker",
            "create",
            "--name",
            $c.name,
            "--restart",
            ($c.restart_policy.name // "no")
        ]
        + $mountArgs
        + $envArgs
        + $portArgs
        + $networkArgs
        + [$c.image]
        + ($c.command // [])
    )

    | @sh

' "$MANIFEST"
)"

echo "[DRY-RUN] Etape 1 - Création du conteneur"
echo "$CREATE_CMD"
echo


# ------------------------------------------------------------
# Réseaux supplémentaires éventuels
# ------------------------------------------------------------

NETWORK_COUNT="$(jq '.container.networks | length' "$MANIFEST")"
NAME="$(jq -r '.container.name' "$MANIFEST")"

if [ "$NETWORK_COUNT" -gt 1 ]; then

    echo "[DRY-RUN] Etape 2 - Réseaux supplémentaires"

    i=1

    while [ "$i" -lt "$NETWORK_COUNT" ]; do

        NETWORK="$(jq -r ".container.networks[$i].name" "$MANIFEST")"

        jq -nr \
            --arg network "$NETWORK" \
            --arg name "$NAME" \
            '["docker","network","connect",$network,$name] | @sh'

        i=$((i + 1))

    done

    echo
fi


# ------------------------------------------------------------
# Démarrage
# ------------------------------------------------------------

echo "[DRY-RUN] Etape finale - Démarrage"

jq -nr \
    --arg name "$NAME" \
    '["docker","start",$name] | @sh'

echo
echo "DRY-RUN TERMINE"
echo "Aucune modification Docker n'a été effectuée."
