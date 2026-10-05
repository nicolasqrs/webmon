#!/bin/sh
# Sondes explicites pour sites HTTP(S), independantes de la recuperation Docker.
set -eu
CONFIG="${WEBSITES_CONFIG_FILE:-/config/websites.json}"
STATE="${WEBSITES_STATE_FILE:-/runtime/websites.json}"
METRICS="${WEBSITES_METRIC_FILE:-/metrics/websites.prom}"
TMP="${STATE}.tmp.$$"
ROWS="${STATE}.rows.$$"
MTMP="${METRICS}.tmp.$$"
trap 'rm -f "$TMP" "$ROWS" "$MTMP"' EXIT INT TERM
mkdir -p "$(dirname "$STATE")" "$(dirname "$METRICS")"
# Une configuration invalide conserve les derniers resultats sans lancer de requete.
jq -e '
  type == "array" and
  all(.[]; (.name | type == "string" and length > 0) and
    (.url | type == "string" and test("^https?://[^/[:space:]]+") and (test("[[:space:]]") | not)) and
    ((.expected_status // 200) | type == "number" and floor == . and . >= 100 and . <= 599) and
    ((.timeout_seconds // 5) | type == "number" and floor == . and . >= 1 and . <= 60) and
    ((.failure_threshold // 3) | type == "number" and floor == . and . >= 1 and . <= 100)) and
  ([.[].name] | length == (unique | length))
' "$CONFIG" >/dev/null
if [ -f "$STATE" ]; then
  jq -e 'type == "array"' "$STATE" >/dev/null
fi
: > "$ROWS"
# Base64 conserve les noms et URL sans interpretation par le shell.
jq -r '.[] | @base64' "$CONFIG" | while IFS= read -r row; do
  site="$(printf '%s' "$row" | base64 -d)"
  name="$(printf '%s' "$site" | jq -r .name)"
  url="$(printf '%s' "$site" | jq -r .url)"
  expected="$(printf '%s' "$site" | jq -r '.expected_status // 200')"
  timeout="$(printf '%s' "$site" | jq -r '.timeout_seconds // 5')"
  threshold="$(printf '%s' "$site" | jq -r '.failure_threshold // 3')"
  failures=0
  if [ -f "$STATE" ]; then
    failures="$(jq -r --arg name "$name" --arg url "$url" --argjson expected "$expected" '
      [.[] | select(.name == $name and .url == $url and .expected_status == $expected)][0].consecutive_failures // 0
    ' "$STATE")"
  fi
  exit_code=0
  response="$(curl --silent --output /dev/null --location --max-redirs 5 \
    --proto '=http,https' --proto-redir '=http,https' \
    --connect-timeout "$timeout" --max-time "$timeout" \
    --write-out '%{http_code} %{time_total}' --url "$url")" || exit_code=$?
  code="${response%% *}"
  duration="${response#* }"
  # Ne pas journaliser les URL : elles peuvent contenir des parametres prives.
  code="$(printf '%s' "$code" | sed 's/^0*//')"
  code="${code:-0}"
  duration="${duration:-0}"
  ok=0
  if [ "$exit_code" -eq 0 ] && [ "$code" -eq "$expected" ]; then
    ok=1
    failures=0
  else
    failures=$((failures + 1))
  fi
  confirmed=0
  [ "$failures" -lt "$threshold" ] || confirmed=1
  jq -cn --arg name "$name" --arg url "$url" \
    --argjson expected "$expected" --argjson threshold "$threshold" \
    --argjson code "$code" --argjson duration "$duration" \
    --argjson ok "$ok" --argjson failures "$failures" \
    --argjson confirmed "$confirmed" --argjson exit_code "$exit_code" \
    --argjson checked_at "$(date +%s)" '
      {name:$name,url:$url,expected_status:$expected,failure_threshold:$threshold,
       status_code:$code,response_seconds:$duration,functional:$ok,
       consecutive_failures:$failures,failure_confirmed:$confirmed,
       curl_exit_code:$exit_code,checked_at:$checked_at}
    ' >> "$ROWS"
done
jq -s . "$ROWS" > "$TMP"
cat > "$MTMP" <<'HEADER'
# HELP webmon_websites_last_cycle_timestamp_seconds Dernier cycle termine des sondes web.
# TYPE webmon_websites_last_cycle_timestamp_seconds gauge
# HELP webmon_website_up Code HTTP attendu et requete terminee (1 ou 0).
# TYPE webmon_website_up gauge
# HELP webmon_website_failure_confirmed Panne confirmee apres plusieurs echecs (1 ou 0).
# TYPE webmon_website_failure_confirmed gauge
# HELP webmon_website_status_code Dernier code HTTP recu (0 sans reponse HTTP).
# TYPE webmon_website_status_code gauge
# HELP webmon_website_response_seconds Duree de la requete en secondes, erreurs incluses.
# TYPE webmon_website_response_seconds gauge
HEADER
printf 'webmon_websites_last_cycle_timestamp_seconds %s\n' "$(date +%s)" >> "$MTMP"
jq -r '.[] | ("{site=" + (.name | tojson) + "}") as $labels |
  "webmon_website_up" + $labels + " " + (.functional | tostring),
  "webmon_website_failure_confirmed" + $labels + " " + (.failure_confirmed | tostring),
  "webmon_website_status_code" + $labels + " " + (.status_code | tostring),
  "webmon_website_response_seconds" + $labels + " " + (.response_seconds | tostring)
' "$TMP" >> "$MTMP"
chmod 644 "$TMP" "$MTMP"
mv -f "$TMP" "$STATE"
mv -f "$MTMP" "$METRICS"
echo "WebMon: cycle des sondes web termine."
