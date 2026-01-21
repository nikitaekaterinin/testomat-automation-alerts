#!/bin/bash
set -euo pipefail

BASE_URL="${TESTOMAT_BASE_URL:-https://app.testomat.io}"
API="$BASE_URL/api/v1"
STATE_FILE="data/state.json"

mkdir -p data
if [ ! -f "$STATE_FILE" ]; then
  echo "{}" > "$STATE_FILE"
fi

# 1) Отримати automated тести
tests=$(curl -sS \
  -H "Authorization: Bearer $TESTOMAT_TOKEN" \
  -H "Accept: application/json" \
  "$API/tests?state=automated")

# Підтримка обох форматів відповіді
echo "$tests" | jq -c 'if type=="array" then .[] else .data[] end' | while read -r test; do
  id=$(echo "$test" | jq -r '.id')
  title=$(echo "$test" | jq -r '.title // .name // ("Test " + (.id|tostring))')

  # 2) Деталі тесту
  details=$(curl -sS \
    -H "Authorization: Bearer $TESTOMAT_TOKEN" \
    -H "Accept: application/json" \
    "$API/tests/$id")

  # 3) ЩО ВВАЖАЄМО STEPS
  steps=$(echo "$details" | jq -r '.code // .description // ""')

  hash=$(printf "%s" "$steps" | sha256sum | awk '{print $1}')
  old_hash=$(jq -r --arg id "$id" '.[$id] // empty' "$STATE_FILE")

  # 4) АЛЕРТ (не перший запуск і steps змінились)
  if [[ -n "$old_hash" && "$old_hash" != "$hash" ]]; then
    link="$BASE_URL/tests/$id"

    payload=$(jq -n \
      --arg title "$title" \
      --arg id "$id" \
      --arg link "$link" \
      '{
        text: ("🚨 *Automated test updated in Testomat*\n" +
              "• *Test:* " + $title + "\n" +
              "• *ID:* " + $id + "\n" +
              "• *Link:* " + $link + "\n" +
              "here")
      }')

    curl -sS -X POST -H "Content-Type: application/json" \
      -d "$payload" \
      "$SLACK_WEBHOOK" >/dev/null
  fi

  # 5) Оновити state
  jq --arg id "$id" --arg hash "$hash" '.[$id]=$hash' \
    "$STATE_FILE" > data/tmp.json && mv data/tmp.json "$STATE_FILE"
done

echo "Done."
