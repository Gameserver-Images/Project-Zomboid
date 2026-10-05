#!/bin/bash
# Prints one JSON document for the mods page of the docs site: the workshop items of WORKSHOP_IDS,
# of the server's WorkshopItems and on disk, with their Steam details and the mods in them, and each
# mod's requirements, maps and sandbox options for the game version of the server's last start.
# Usage: list-mods > mods.json

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=scripts/lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/mods.sh
. "${SCRIPT_DIR}/lib/mods.sh"

content_dir="${STEAMAPPDIR}/steamapps/workshop/content/108600"
ini_file="${HOMEDIR}/Zomboid/Server/${SERVERNAME:-pzserver}.ini"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

version="$(console_game_version)"
if [ -z "${version}" ]; then
  echo "Error: ${HOMEDIR}/Zomboid/server-console.txt shows no game version. Start the server once first; it also downloads the workshop items while it starts." >&2
  exit 1
fi

ini_list() {
  # $1 = INI key
  [ -f "${ini_file}" ] || return 0
  split_list "$(ini_value "${ini_file}" "$1")"
}

workshop_ids="$(split_list "${WORKSHOP_IDS:-}")"
server_mods="$(ini_list Mods)"
server_map="$(ini_list Map)"
server_items="$(ini_list WorkshopItems)"

: > "${tmp}/tree"
if [ -n "${workshop_ids}" ] && ! bash "${SCRIPT_DIR}/resolve_workshop_collection.sh" --tree "$(paste -sd ';' <<< "${workshop_ids}")" > "${tmp}/tree"; then
  echo "Error: could not resolve WORKSHOP_IDS through the Steam API." >&2
  exit 1
fi

for dir in "${content_dir}"/*/; do
  dir="${dir%/}"
  if [[ "${dir##*/}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${dir##*/}"
  fi
done > "${tmp}/downloaded"

# Collections are looked up too, for their titles. The API takes 100 IDs per call.
mapfile -t lookup < <({
  jq -r '.id, (.children // [] | .[].id)' "${tmp}/tree"
  printf '%s\n' "${server_items}"
  cat "${tmp}/downloaded"
} | sed '/^$/d' | sort -u)
if ! printf '%s\n' "${lookup[@]}" | sed '/^$/d' | workshop_details > "${tmp}/details"; then
  echo "Error: could not get the workshop item details from the Steam API." >&2
  exit 1
fi
# Required items ("Required items" on the workshop page) are only in this API, which needs a key.
: > "${tmp}/required"
if [ -n "${STEAM_API_KEY:-}" ]; then
  for ((start = 0; start < ${#lookup[@]}; start += 100)); do
    batch=("${lookup[@]:start:100}")
    ids=()
    for i in "${!batch[@]}"; do
      ids+=(--data-urlencode "publishedfileids[$i]=${batch[$i]}")
    done
    if ! curl -fsS --max-time 30 -G --data-urlencode "key=${STEAM_API_KEY}" --data-urlencode includechildren=true "${ids[@]}" \
      'https://api.steampowered.com/IPublishedFileService/GetDetails/v1/' > "${tmp}/response" \
      || ! jq -e '.response' "${tmp}/response" > /dev/null 2>&1; then
      echo "Error: could not get the required items from the Steam API; check that STEAM_API_KEY is a valid key." >&2
      exit 1
    fi
    cat "${tmp}/response" >> "${tmp}/required"
  done
fi

mod_info_rows "${version}" "${content_dir}"/*/mods > "${tmp}/mods"

{
  # The sandbox options and English translations of the mods that load by themselves
  awk -F '\t' '$4 == 1 && $19 == ""' "${tmp}/mods" | mod_dirs | while IFS=$'\t' read -r item folder rank dir; do
    translate="${dir}/media/lua/shared/Translate/EN"
    if [ -f "${dir}/media/sandbox-options.txt" ]; then
      printf 'options\t%s/%s\t%s\t%s\n' "${item}" "${folder}" "${rank}" "${dir}/media/sandbox-options.txt"
    fi
    if [ -f "${translate}/Sandbox.json" ]; then
      printf 'json\t%s/%s\t%s\t%s\n' "${item}" "${folder}" "${rank}" "${translate}/Sandbox.json"
    elif [ -f "${translate}/Sandbox_EN.txt" ]; then
      printf 'txt\t%s/%s\t%s\t%s\n' "${item}" "${folder}" "${rank}" "${translate}/Sandbox_EN.txt"
    fi
  done
  # The maps of every mod whose mod.info the game reads: like the image, the page takes them out of
  # Map= when the mod doesn't load.
  mod_dirs < "${tmp}/mods" | while IFS=$'\t' read -r item folder rank dir; do
    for map_dir in "${dir}"/media/maps/*/; do
      map_dir="${map_dir%/}"
      if [ "${map_dir##*/}" != "${VANILLA_MAP}" ]; then
        printf 'map\t%s/%s\t%s\t%s\n' "${item}" "${folder}" "${rank}" "${map_dir##*/}"
      fi
    done
  done
} | LC_ALL=C awk -F '\t' '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function clean(s) { gsub(/\t/, " ", s); return s }
  # option <name> { key = value, ... }, with /* */ comments. Statements end at commas or braces, not
  # at line ends. Options of an unknown type are no setting the game creates.
  function options(key, rank, path,   line, n, parts, p, s, i, j, rest, comment, name, open, field, type) {
    name = ""
    open = 0
    comment = 0
    while ((getline line < path) > 0) {
      sub(/\r$/, "", line)
      if (comment) {
        if ((i = index(line, "*/")) == 0) continue
        line = substr(line, i + 2)
        comment = 0
      }
      while ((i = index(line, "/*")) > 0) {
        rest = substr(line, i + 2)
        if ((j = index(rest, "*/")) == 0) {
          line = substr(line, 1, i - 1)
          comment = 1
          break
        }
        line = substr(line, 1, i - 1) substr(rest, j + 2)
      }
      gsub(/[{}]/, ",&,", line)
      n = split(line, parts, ",")
      for (p = 1; p <= n; p++) {
        s = trim(parts[p])
        if (s ~ /^option[ \t]/) {
          name = trim(substr(s, 7))
          open = 0
          split("", field)
        } else if (name != "" && s == "{") {
          open = 1
        } else if (name != "" && s == "}") {
          type = tolower(field["type"])
          if (open && type ~ /^(boolean|integer|double|enum|string)$/) {
            print "option\t" key "\t" rank "\t" (++seq) "\t" clean(name) "\t" type "\t" clean(field["default"]) "\t" \
              clean(field["min"]) "\t" clean(field["max"]) "\t" clean(field["page"]) "\t" clean(field["translation"]) "\t" \
              clean(field["valuetranslation"]) "\t" clean(field["numvalues"])
          }
          name = ""
        } else if (open && (i = index(s, "=")) > 1) {
          field[tolower(trim(substr(s, 1, i - 1)))] = trim(substr(s, i + 1))
        }
      }
    }
    close(path)
  }
  # JSON has no line breaks inside strings, so the file goes on one line for jq to parse.
  function json(key, rank, path,   line) {
    printf "json\t%s\t%s\t", key, rank
    while ((getline line < path) > 0) {
      sub(/\r$/, "", line)
      printf "%s ", line
    }
    close(path)
    print ""
  }
  # Sandbox_EN = { Sandbox_Key = "Label", ... }
  function lua(key, rank, path,   line, name, value) {
    while ((getline line < path) > 0) {
      sub(/\r$/, "", line)
      if (!match(line, /^[ \t]*[A-Za-z0-9_.-]+[ \t]*=[ \t]*"/)) continue
      name = line
      sub(/^[ \t]*/, "", name)
      sub(/[ \t]*=.*/, "", name)
      value = substr(line, RLENGTH + 1)
      sub(/"[ \t]*,?[ \t]*(--.*)?$/, "", value)
      print "label\t" key "\t" rank "\t" name "\t" value
    }
    close(path)
  }
  $1 == "options" { options($2, $3, $4) }
  $1 == "json" { json($2, $3, $4) }
  $1 == "txt" { lua($2, $3, $4) }
  $1 == "map" { print }
' > "${tmp}/files"

bash "${SCRIPT_DIR}/list_env.sh" --tsv | awk -F '\t' '$1 == "sandbox"' > "${tmp}/current"

jq -n -c \
  --arg version "${version}" \
  --arg workshop_ids "${workshop_ids}" \
  --arg server_mods "${server_mods}" \
  --arg server_map "${server_map}" \
  --arg server_items "${server_items}" \
  --argjson keyed "$([ -n "${STEAM_API_KEY:-}" ] && echo true || echo false)" \
  --slurpfile tree "${tmp}/tree" \
  --slurpfile details "${tmp}/details" \
  --slurpfile required "${tmp}/required" \
  --rawfile downloaded "${tmp}/downloaded" \
  --rawfile mods "${tmp}/mods" \
  --rawfile files "${tmp}/files" \
  --rawfile current "${tmp}/current" '
  def lines: split("\n") | map(select(length > 0));
  def rows: lines | map(split("\t"));
  def text: if . == "" then null else . end;
  def ids: if . == "" then [] else split(",") end;
  def number: tonumber? // null;
  def unquote: if test("^\".*\"$") then .[1:-1] | gsub("\\\\(?<c>[\"\\\\])"; .c) else . end;

  ($files | rows) as $files
  | ($files | map(select(.[0] == "map")) | group_by(.[1])
      | map({key: .[0][1], value: (map(.[3]) | unique)}) | from_entries) as $maps
  # Labels per mod: the version folder (rank 0) wins over common/ (rank 1). A file that is not valid
  # JSON gives no labels.
  | ([$files[] | select(.[0] == "json") | {key: .[1], rank: .[2], labels: (.[3:] | join("\t")
        | (try fromjson catch null) | if type == "object" then with_entries(select(.value | type == "string")) else {} end)}]
     + [$files | map(select(.[0] == "label")) | group_by(.[1] + "\t" + .[2])[]
        | {key: .[0][1], rank: .[0][2], labels: (map({key: .[3], value: (.[4:] | join("\t") | gsub("\\\\(?<c>.)"; .c))}) | from_entries)}]
     | group_by(.key) | map({key: .[0].key, value: (sort_by(.rank) | reverse | map(.labels) | add)}) | from_entries) as $labels
  | ($current | rows | map({key: (.[1] | ascii_downcase), value: (.[2] // "" | unquote)}) | from_entries) as $current
  | ($files | map(select(.[0] == "option")
      | {key: .[1], rank: .[2], seq: (.[3] | tonumber), env: ("SANDBOX_" + (.[4] | split(".") | join("__"))), option: .[4],
         type: .[5], default: .[6], min: .[7], max: .[8], page: .[9], translation: .[10], valueTranslation: .[11], numValues: .[12]})
      | group_by(.key) | map({key: .[0].key, value: (sort_by(.rank, .seq) | unique_by(.env) | sort_by(.rank, .seq))}) | from_entries) as $options
  | ($details | map(.response.publishedfiledetails // [] | .[] | select(.result == 1)) | INDEX(.publishedfileid)) as $info
  | ($required | map(.response.publishedfiledetails // [] | .[]) | INDEX(.publishedfileid)) as $required
  | ($downloaded | lines | map({key: ., value: true}) | from_entries) as $downloaded

  | def sandbox($labels):
      {env, option, type, default: (.default | text), min: (.min | text), max: (.max | text),
       values: (if .type == "enum" and .valueTranslation != "" then
           .valueTranslation as $values
           | [range(1; [(.numValues | number // 0 | floor), 1000] | min + 1) as $i | $labels["Sandbox_\($values)_option\($i)"]]
           | if all(. == null) then null else [to_entries[] | .value // (.key + 1 | tostring)] end
         else null end),
       page: (.page | text), pageLabel: (if .page == "" then null else $labels["Sandbox_" + .page] end),
       label: (if .translation == "" then null else $labels["Sandbox_" + .translation] end),
       tooltip: (if .translation == "" then null else $labels["Sandbox_" + .translation + "_tooltip"] end),
       current: $current[.env | ascii_downcase]};

  # error: why the game does not find the mod. requireEntries: the require entries as the game loads
  # them, untrimmed and with empty ones.
  ($mods | rows | map((.[0] + "/" + .[1]) as $key | [.[0], {
      id: (.[4] | text), folder: .[1], versionFolder: (if .[2] == "" then null elif .[2] == "." then "" else .[2] end),
      name: (.[5] | text), description: (.[6] | text), author: (.[7] | text), modVersion: (.[8] | text),
      url: (.[9] | text), category: (.[10] | text), versionMin: (.[11] | text), versionMax: (.[12] | text),
      error: (if .[3] == "-" then .[18] | text else null end),
      require: (.[13] | ids), requireEntries: [.[19] // "" | scan("([^,]*),") | .[0]],
      loadModAfter: (.[14] | ids), loadModBefore: (.[15] | ids), incompatible: (.[16] | ids),
      maps: ($maps[$key] // []), sandbox: [($options[$key] // [])[] | sandbox($labels[$key] // {})]}])
    | group_by(.[0]) | map({key: .[0][0], value: (map(.[1]) | sort_by(.folder))}) | from_entries) as $item_mods

  | {
      format: 2,
      gameVersion: $version,
      workshopIds: ($workshop_ids | lines),
      server: {mods: ($server_mods | lines), map: ($server_map | lines), workshopItems: ($server_items | lines)},
      collections: [$tree[] | select(.children != null) | {id, title: $info[.id].title, children: [.children[].id]}],
      items: [
        [$tree[] | if .children == null then .id else .children[] | select(.collection | not) | .id end]
        + ($server_items | lines) + ($downloaded | keys) | unique | sort_by(length, .)
        | .[] as $id | $info[$id] as $i
        | {id: $id, available: ($i != null),
           title: $i.title, description: $i.description, tags: (if $i then [$i.tags[]?.tag] else null end),
           updated: ($i.time_updated | number), size: ($i.file_size | number),
           requiredItems: (if $keyed then [$required[$id].children[]?.publishedfileid] else null end),
           downloaded: ($downloaded[$id] != null), mods: ($item_mods[$id] // [])}
      ]
    }
'
