#!/bin/bash
set -euo pipefail

BASE="https://app.testomat.io"
PROJECT_ID="${TESTOMAT_PROJECT_ID:-}"
TOKEN="${TESTOMAT_TOKEN:-}"
SLACK="${SLACK_WEBHOOK_URL:-}"

STATE_FILE="data/state.json"
COOLDOWN_SECONDS=600  # 10 хв антиспам на один тест

if [[ -z "$PROJECT_ID" ]]; then echo "ERROR: TESTOMAT_PROJECT_ID empty"; exit 2; fi
if [[ -z "$TOKEN" ]]; then echo "ERROR: TESTOMAT_TOKEN empty"; exit 2; fi
if [[ -z "$SLACK" ]]; then echo "ERROR: SLACK_WEBHOOK_URL empty"; exit 2; fi

mkdir -p data
if [[ ! -f "$STATE_FILE" ]]; then echo "{}" > "$STATE_FILE"; fi
now=$(date +%s)

api_get() {
  local url="$1"
  curl -sS -w "\n__HTTP_STATUS__:%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/json" \
    "$url"
}

http_status() { echo "$1" | sed -n 's/__HTTP_STATUS__:\([0-9]\{3\}\)/\1/p'; }
http_body()   { echo "$1" | sed '/__HTTP_STATUS__:/,$d'; }

# --------- 0) Sanity check: token+project should work (testruns) ----------
SANITY_URL="$BASE/api/$PROJECT_ID/testruns"
sresp=$(api_get "$SANITY_URL")
sstatus=$(http_status "$sresp")
if [[ "$sstatus" != "200" ]]; then
  echo "ERROR: Sanity check failed: $SANITY_URL returned HTTP $sstatus"
  echo "Body:"
  echo "$(http_body "$sresp")" | head -c 500; echo
  exit 5
fi
echo "Sanity OK: /testruns доступний (HTTP 200)"

# --------- 1) Find tests list endpoint automatically ----------
# Ми пробуємо кілька найбільш типових шляхів.
# Якщо у вас доступ до suites/tests обмежений, буде видно по статусах.
CANDIDATES=(
  "$BASE/api/$PROJECT_ID/tests?state=automated"
  "$BASE/api/$PROJECT_ID/tests"
  "$BASE/api/$PROJECT_ID/testcases?state=automated"
  "$BASE/api/$PROJECT_ID/testcases"
  "$BASE/api/$PROJECT_ID/cases?state=automated"
  "$BASE/api/$PROJECT_ID/cases"
  "$BASE/api/$PROJECT_ID/suites"  # fallback: якщо є тільки suites дерево
)

LIST_URL=""
LIST_MODE=""  # "direct" або "suites"

echo "Trying endpoints for tests list..."
for u in "${CANDIDATES[@]}"; do
  r=$(api_get "$u")
  st=$(http_status "$r")
  echo " - $st $u"
  if [[ "$st" == "200" ]]; then
    LIST_URL="$u"
    if [[ "$u" == *"/suites" ]]; then
      LIST_MODE="suites"
    else
      LIST_MODE="direct"
    fi
    break
  fi
done

if [[ -z "$LIST_URL" ]]; then
  echo "ERROR: Could not find a working tests/suites endpoint."
  echo "Token+project works for /testruns, but tests management endpoints are returning non-200."
  echo "Possible causes: insufficient permissions (role), different endpoint naming, or project key mismatch."
  exit 5
fi

echo "Selected list endpoint: $LIST_URL (mode=$LIST_MODE)"

# --------- Helpers to parse list shapes ----------
# Підтримуємо формати:
#   - [ {...}, {...} ]
#   - { data: [ {...} ] }
# Для direct list: очікуємо, що елементи мають хоча б id/title/state.
parse_list_items_to_ndjson() {
  jq -c '
    if type=="array" then .[]
    elif (has("data") and (.data|type=="array")) then .data[]
    else empty end
  '
}

extract_test_min_fields() {
  jq -c '
    {
      id: ((.id // ._id // "")|tostring),
      title: (.title // .name // ""),
      state: (.state // "")
    }
  '
}

# --------- 2) Collect tests (direct or suites traversal) ----------
tests_file="data/tests.ndjson"
: > "$tests_file"

if [[ "$LIST_MODE" == "direct" ]]; then
  lresp=$(api_get "$LIST_URL")
  lbody=$(http_body "$lresp")

  echo "$lbody" | parse_list_items_to_ndjson | extract_test_min_fields >> "$tests_file"
else
  # suites traversal (BFS) because tests might be nested
  root_resp=$(api_get "$LIST_URL")
  root_body=$(http_body "$root_resp")

  queue="data/suite_queue.txt"
  seen="data/suite_seen.txt"
  : > "$queue"; : > "$seen"

  # root suites ids
  echo "$root_body" | parse_list_items_to_ndjson | jq -r '.id // ._id // empty' >> "$queue"

  while read -r sid; do
    [[ -z "$sid" ]] && continue
    if grep -qx "$sid" "$seen" 2>/dev/null; then
      continue
    fi
    echo "$sid" >> "$seen"

    SUITE_URL="$BASE/api/$PROJECT_ID/suites/$sid"
    sresp=$(api_get "$SUITE_URL")
    sst=$(http_status "$sresp")
    sbody=$(http_body "$sresp")

    if [[ "$sst" != "200" ]]; then
      echo "WARN: suite $sid failed HTTP $sst"
      continue
    fi

    # child suites ids (several possible field names)
    echo "$sbody" | jq -r '
      ( .suites? // .children? // .child_suites? // [] )
      | (if type=="array" then .[]?.id else empty end)
    ' | sed '/^$/d' >> "$queue"

    # tests items in suite (several possible field names)
    echo "$sbody" | jq -c '
      ( .tests? // .items? // .cases? // [] )
      | (if type=="array" then .[] else empty end)
    ' | extract_test_min_fields >> "$tests_file"
  done < "$queue"
fi

if [[ ! -s "$tests_file" ]]; then
  echo "ERROR: No tests collected."
  exit 5
fi

# --------- 3) For each automated test: fetch details, hash steps, alert on change ----------
# Деталі тесту теж можуть бути в різних endpoint-ах — теж пробуємо кілька.
DETAILS_CANDIDATES=(
  "$BASE/api/$PROJECT_ID/tests/%s"
  "$BASE/api/$PROJECT_ID/testcases/%s"
  "$BASE/api/$PROJECT_ID/cases/%s"
)

get_details_body() {
  local id="$1"
  for fmt in "${DETAILS_CANDIDATES[@]}"; do
    url=$(printf "$fmt" "$id")
    dresp=$(api_get "$url")
    dst=$(http_status "$dresp")
    if [[ "$dst" == "200" ]]; then
      echo "$(http_body "$dresp")"
      return 0
    fi
  done
  return 1
}

# only state=automated
cat "$tests_file" | jq -c 'select(.state=="automated" and .id!="")' | while read -r t; do
  id=$(echo "$t" | jq -r '.id')
  title=$(echo "$t" | jq -r '.title // ("Test " + .id)')

  if ! details=$(get_details_body "$id"); then
    echo "WARN: could not fetch details for test id=$id (tried tests/testcases/cases)"
    continue
  fi

  steps=$(echo "$details" | jq -r '.code // .description // ""')
  hash=$(printf "%s" "$steps" | sha256sum | awk '{print $1}')

  old_hash=$(jq -r --arg id "$id" '.[$id].hash // empty' "$STATE_FILE")
  last_alert=$(jq -r --arg id "$id" '.[$id].last_alert_ts // 0' "$STATE_FILE")
  [[ "$last_alert" == "null" || -z "$last_alert" ]] && last_alert=0

  # baseline: перший раз без алерта
  if [[ -z "$old_hash" ]]; then
    jq --arg id "$id" --arg hash "$hash" '.[$id]={hash:$hash,last_alert_ts:0}' \
      "$STATE_FILE" > data/tmp.json && mv data/tmp.json "$STATE_FILE"
    continue
  fi

  if [[ "$old_hash" != "$hash" ]]; then
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
      jq --arg id "$id" --arg hash "$hash" '.[$id].hash=$hash' \
        "$STATE_FILE" > data/tmp.json && mv data/tmp.json "$STATE_FILE"
    fi
  fi
done

echo "Done."
