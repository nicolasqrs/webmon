# Image utilisée par webmon-monitor.
#
# On part de l'image Docker CLI actuelle afin de conserver
# l'accès aux commandes docker utilisées par WebMon.
FROM docker:29-cli

# jq permettra au moteur de récupération de lire proprement
# les fichiers JSON générés par WebMon.
RUN apk add --no-cache jq curl ca-certificates
