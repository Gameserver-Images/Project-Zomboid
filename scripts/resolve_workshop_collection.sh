#!/bin/bash
# Expands workshop collections into the items they contain; plain item IDs are kept as they are.
# Usage: resolve_workshop_collection.sh <id1>[;<id2>...]
# Prints one item ID per line. STEAM_API_KEY is only needed for private or unlisted collections.

set -euo pipefail

IFS=';' read -ra to_process <<< "$1"
declare -A visited=()
declare -A items=()

for _ in 1 2 3; do
  [ "${#to_process[@]}" -gt 0 ] || break
  args=(--data-urlencode "collectioncount=${#to_process[@]}")
  for i in "${!to_process[@]}"; do
    visited["${to_process[$i]}"]=1
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

  to_process=()
  while read -r kind id; do
    [ -n "${id}" ] || continue
    if [ "${kind}" = collection ]; then
      [ -n "${visited[${id}]+x}" ] || to_process+=("${id}")
    else
      items["${id}"]=1
    fi
  done <<< "${rows}"
done

printf '%s\n' "${!items[@]}" | sed '/^$/d' | sort -u
