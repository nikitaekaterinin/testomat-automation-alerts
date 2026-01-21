#!/bin/bash
set -euo pipefail

API="https://app.testomat.io/api/v1"
STATE_FILE="data/state.json"

# ===== REQUIRED ENV =====
if [[ -z "${TESTOMAT_TOKEN:-}" ]]; then
  echo "ERROR: TESTOMAT_TOKEN is empty. Add it as GitHub Actions secret."
  exit 2
fi

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  echo "ERROR: SLACK_WEBHOOK_URL is empty. Add it as GitHub Actions secret."
  exit 2
fi

mkdir -p data
if [ ! -f "$STATE_FILE" ]; then
  echo "{}" > "$STATE_FILE"
fi

# ===== GET AUTOMATED TESTS (with HTTP status) =====
resp=$(curl -sS -w "\n__HTTP_STATUS__:%{http_code}\n" \
  -H "Authorization: Bearer $TESTOMAT_TOKEN" \
  -H "Accept: application/json" \
  "$API/tests?state=automated")

status=$(echo "$resp" | sed -n 's/__HTTP_STATUS__:\([0-9]\{3\}\)/\1/p')
body=$(echo "$resp" | sed '/__HTTP_STATUS__:/,$d')

echo "Testomat list status: $status"
echo "Testomat list body (first 300 chars):"
echo "$body" | head -c 300
echo

if [[ "$status" != "200" ]]; then
  echo "ERROR: Testomat API returned HTTP $status"
  exit 5
fi

# ===== PARSE LIST (supports [] and {data:[]}) =====
items=$(echo "$body" | jq -c '
  if type=="array" then .[]
  elif (has("data") and (.data|type=="array")) then .data[]
  else empty end
')

if [[ -z "$items" ]]; then
  echo "ERROR: No automated tests found or unexpected JSON shape."
  exit 5
fi

# ===== PROCESS TESTS =====
echo "$items" | while read -r test; do
  id=$(echo "$test" | jq -r '.id // empty')
  title=$(echo "$test" | jq -r '.title // .name // ("Test " + ((.id // "unknown")|tostring))')
  [[ -z "$id" ]] && continue

  details=$(curl -sS \
    -H "Authorization: Bearer $TESTOMAT_TOKEN" \
    -H "Accept: application/json" \
    "$API/tests/$id")

  steps=$(echo "$details" | jq -r '.code // .description // ""')
  hash=$(printf "%s" "$steps" | sha256sum | awk '{print $1}')
  old_hash=$(jq -r --arg id "$id" '.[$id] // empty' "$STATE_FILE")

  if [[ -n "$old_hash" && "$old_hash" != "$hash" ]]; then
    payload=$(jq -n \
      --arg title "$title" \
      --arg id "$id" \
      '{
        text: ("🚨 *Automated test updated in Testomat*\n" +
              "• *Test:* " + $title + "\n" +
              "• *ID:* " + $id + "\n" +
              "here")
      }')

    curl -sS -X POST -H "Content-Type: application/json" \
      -d "$payload" \
      "$SLACK_WEBHOOK_URL" >/dev/null
  fi

  jq --arg id "$id" --arg hash "$hash" '.[$id]=$hash' \
    "$STATE_FILE" > data/tmp.json && mv data/tmp.json "$STATE_FILE"
done

echo "Done."
