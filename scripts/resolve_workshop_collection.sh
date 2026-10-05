#!/bin/bash
# Expands workshop collections into the items they contain; plain item IDs are kept as they are.
# Usage: resolve_workshop_collection.sh [--tree] <id1>[;<id2>...]
# Prints one item ID per line. --tree prints instead one JSON object per ID looked up, in workshop
# order: {"id": ..., "children": [{"id": ..., "collection": true|false}, ...]}, children null for items.
# STEAM_API_KEY is only needed for private or unlisted collections.

set -euo pipefail

tree=false
if [ "${1:-}" = "--tree" ]; then
  tree=true
  shift
fi

declare -A visited=()
declare -A items=()
to_process=()

queue() {
  # $1 = workshop ID. Each is looked up once, also when several collections contain it.
  if [ -z "$1" ] || [ -n "${visited[$1]+x}" ]; then
    return 0
  fi
  visited["$1"]=1
  to_process+=("$1")
}

IFS=';' read -ra ids <<< "$1"
for id in "${ids[@]}"; do
  queue "${id}"
done

for _ in 1 2 3; do
  [ "${#to_process[@]}" -gt 0 ] || break
  args=(--data-urlencode "collectioncount=${#to_process[@]}")
  for i in "${!to_process[@]}"; do
    args+=(--data-urlencode "publishedfileids[$i]=${to_process[$i]}")
  done
  if [ -n "${STEAM_API_KEY:-}" ]; then
    args+=(--data-urlencode "key=${STEAM_API_KEY}")
  fi
  response="$(curl -fsS --max-time 30 -X POST "${args[@]}" \
    'https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/')"

  # Rows: "item <id>" for workshop items, "collection <id>" for nested collections.
  # Only collections come back with result 1, empty ones included; plain items get result 9.
  rows="$(jq -r '
    .response.collectiondetails[]
    | if .result == 1 then (.children // [])[] | "\(if .filetype == 2 then "collection" else "item" end) \(.publishedfileid)"
      else "item \(.publishedfileid)"
      end
  ' <<< "${response}")"
  if [ "${tree}" = true ]; then
    jq -c '
      .response.collectiondetails[]
      | {id: .publishedfileid, children: (if .result == 1 then [(.children // [])[] | {id: .publishedfileid, collection: (.filetype == 2)}] else null end)}
    ' <<< "${response}"
  fi

  to_process=()
  while read -r kind id; do
    [ -n "${id}" ] || continue
    if [ "${kind}" = collection ]; then
      queue "${id}"
    else
      items["${id}"]=1
    fi
  done <<< "${rows}"
done

if [ "${tree}" = false ]; then
  printf '%s\n' "${!items[@]}" | sed '/^$/d' | sort -u
fi
