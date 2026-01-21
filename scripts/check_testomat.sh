#!/bin/bash
set -euo pipefail

BASE="https://app.testomat.io"
PROJECT_ID="${TESTOMAT_PROJECT_ID:-}"
TOKEN="${TESTOMAT_TOKEN:-}"
SLACK="${SLACK_WEBHOOK_URL:-}"

STATE_FILE="data/state.json"
COOLDOWN_SECONDS=600   # 10 хв антиспам на один тест

if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: TESTOMAT_PROJECT_ID is empty (GitHub secret)."
  exit 2
fi
if [[ -z "$TOKEN" ]]; then
  echo "ERROR: TESTOMAT_TOKEN is empty (GitHub secret)."
  exit 2
fi
if [[ -z "$SLACK" ]]; then
  echo "ERROR: SLACK_WEBHOOK_URL is empty (GitHub secret)."
  exit 2
fi

mkdir -p data
if [ ! -f "$STATE_FILE" ]; then
  echo "{}" > "$STATE_FILE"
fi

now=$(date +%s)

api_get() {
  local url="$1"
  curl -sS -w "\n__HTTP_STATUS__:%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$url"
}

# IMPORTANT:
# Далі ми маємо взяти список automated тестів.
# У вашому API приклад для analytics є /api/{project_id}/analytics/tags
# Для тестів endpoint може бути інший (tests, cases, etc).
# Нижче я поставив найтиповіший варіант: /api/{project_id}/tests?state=automated
LIST_URL="$BASE/api/$PROJECT_ID/tests?state=automated"

resp=$(api_get "$LIST_URL")
status=$(echo "$resp" | sed -n 's/__HTTP_STATUS__:\([0-9]\{3\}\)/\1/p')
body=$(echo "$resp" | sed '/__HTTP_STATUS__:/,$d')

echo "Testomat list status: $status"
echo "List URL: $LIST_URL"
echo "Body (first 300 chars):"
echo "$body" | head -c 300
echo

if [[ "$status" != "200" ]]; then
  echo "ERROR: List request failed with HTTP $status"
  exit 5
fi

# Підтримка двох форматів: [] або {data:[]}
items=$(echo "$body" | jq -c '
  if type=="array" then .[]
  elif (has("data") and (.data|type=="array")) then .data[]
  else empty end
')

if [[ -z "$items" ]]; then
  echo "ERROR: No items found in list response or unexpected JSON."
  exit 5
fi

echo "$items" | while read -r test; do
  id=$(echo "$test" | jq -r '.id // empty')
  title=$(echo "$test" | jq -r '.title // .name // ("Test " + ((.id // "unknown")|tostring))')
  [[ -z "$id" ]] && continue

  # Деталі тесту (типово /tests/{id})
  DETAILS_URL="$BASE/api/$PROJECT_ID/tests/$id"
  dresp=$(api_get "$DETAILS_URL")
  dstatus=$(echo "$dresp" | sed -n 's/__HTTP_STATUS__:\([0-9]\{3\}\)/\1/p')
  dbody=$(echo "$dresp" | sed '/__HTTP_STATUS__:/,$d')

  if [[ "$dstatus" != "200" ]]; then
    echo "WARN: details HTTP $dstatus for id=$id"
    continue
  fi

  steps=$(echo "$dbody" | jq -r '.code // .description // ""')
  hash=$(printf "%s" "$steps" | sha256sum | awk '{print $1}')

  old_hash=$(jq -r --arg id "$id" '.[$id].hash // empty' "$STATE_FILE")
  last_alert=$(jq -r --arg id "$id" '.[$id].last_alert_ts // 0' "$STATE_FILE")
  [[ "$last_alert" == "null" || -z "$last_alert" ]] && last_alert=0

  # перший раз — тільки запамʼятати
  if [[ -z "$old_hash" ]]; then
    jq --arg id "$id" --arg hash "$hash" '.[$id]={hash:$hash,last_alert_ts:0}' \
      "$STATE_FILE" > data/tmp.json && mv data/tmp.json "$STATE_FILE"
    continue
  fi

  if [[ "$old_hash" != "$hash" ]]; then
    # cooldown
    if (( now - last_alert >= COOLDOWN_SECONDS )); then
      payload=$(jq -n \
        --arg title "$title" \
        --arg id "$id" \
        --arg link "$BASE/tests/$id" \
        '{
          text: ("🚨 *Automated test updated in Testomat*\n" +
                "• *Test:* " + $title + "\n" +
                "• *ID:* " + $id + "\n" +
                "• *Link:* " + $link + "\n" +
                "here")
        }')

      curl -sS -X POST -H "Content-Type: application/json" \
        -d "$payload" \
        "$SLACK" >/dev/null

      jq --arg id "$id" --arg hash "$hash" --argjson ts '"'"$now"'" \
        '.[$id]={hash:$hash,last_alert_ts:$ts}' \
        "$STATE_FILE" > data/tmp.json && mv data/tmp.json "$STATE_FILE"
    else
      # hash оновили, алерт не шлемо
      jq --arg id "$id" --arg hash "$hash" \
        '.[$id].hash=$hash' \
        "$STATE_FILE" > data/tmp.json && mv data/tmp.json "$STATE_FILE"
    fi
  fi
done

echo "Done."
