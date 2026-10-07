#!/bin/bash
# Prints one JSON document for the mods page of the docs site: the workshop items of WORKSHOP_IDS,
# of the server's WorkshopItems and on disk, with their Steam details and the mods in them, each
# mod's requirements, maps and sandbox options for the version of the installed game, and the few server
# INI settings the mods page uses. The values of passwords, tokens, webhooks, Discord and RCON settings and
# the announced IP stay out, mods' sandbox options included.
# --upload sends it gzipped to pastes.dev, which keeps it for good, or to the bytebin server at that URL,
# and prints a mods page link that loads it.
# Usage: list-mods [--upload [https://<your bytebin>]]

set -euo pipefail
shopt -s nullglob

mods_page='https://gameserver-images.github.io/Project-Zomboid/mods.html'
user_agent='project-zomboid-list-mods (github.com/Gameserver-Images/Project-Zomboid)'

usage() {
  echo 'Usage: list-mods [--upload [https://<your bytebin>]]' >&2
  exit 2
}

# https without user info, in characters the mods page link needs no escaping for.
bytebin_url='^https://([A-Za-z0-9.-]+(:[0-9]+)?)(/[A-Za-z0-9._~-]+)*/?$'
base=""
case "$#:${1:-}" in
  0:) ;;
  1:--upload)
    base=https://api.pastes.dev host=pastes.dev deleted='which keeps it for good; nobody can delete it' ;;
  2:--upload)
    [[ "$2" =~ ${bytebin_url} ]] || usage
    base="${2%/}" host="${BASH_REMATCH[1]}" deleted='whose settings decide when it is deleted' ;;
  *) usage ;;
esac

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=scripts/lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/mods.sh
. "${SCRIPT_DIR}/lib/mods.sh"
# shellcheck source=scripts/lib/game.sh
. "${SCRIPT_DIR}/lib/game.sh"

content_dir="${STEAMAPPDIR}/steamapps/workshop/content/108600"
ini_file="${HOMEDIR}/Zomboid/Server/${SERVERNAME:-pzserver}.ini"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

if ! version="$(game_version)"; then
  echo "Error: could not read the game version from the game files: ${version}" >&2
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
  versioned=""
  awk -F '\t' '$4 == 1 && $19 == ""' "${tmp}/mods" | mod_dirs | while IFS=$'\t' read -r item folder rank dir; do
    translate="${dir}/media/lua/shared/Translate/EN"
    # The game reads the sandbox options of the version folder, or else those of common/.
    if [ -f "${dir}/media/sandbox-options.txt" ] && [ "${versioned}" != "${item}/${folder}" ]; then
      printf 'options\t%s/%s\t%s\t%s\n' "${item}" "${folder}" "${rank}" "${dir}/media/sandbox-options.txt"
    fi
    [ "${rank}" = 0 ] && [ -f "${dir}/media/sandbox-options.txt" ] && versioned="${item}/${folder}"
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
  # Reads sandbox-options.txt like the game (CustomSandboxOptions, ScriptParser.readBlock): the lines
  # joined without separators, /* */ comments removed, then blocks "<type> <id> {" holding values that
  # each end at a comma. Text before a closing brace is no value, and the character right after it is
  # skipped. Only a file with VERSION = 1 counts, and only its option blocks before any other kind of
  # block. Keys and types match exactly, and each type needs certain values.
  # Java ints; the game takes the smallest one as missing.
  function int_ok(v) { v = trim(v); return v ~ /^[+-]?[0-9]+$/ && v + 0 > -2147483648 && v + 0 <= 2147483647 }
  function double_ok(v) { return trim(v) ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?[fFdD]?$/ }
  function options(key, rank, path,   line, s, i, j, n, c, start, depth, head, ss, version, stopped, id, type, field, value, out) {
    s = ""
    while ((getline line < path) > 0) {
      gsub(/\r/, "", line)
      s = s line
    }
    close(path)
    while ((i = index(s, "/*")) > 0 && (j = index(substr(s, i + 2), "*/")) > 0) s = substr(s, 1, i - 1) substr(s, i + j + 3)
    n = length(s)
    start = 1
    depth = 0
    version = ""
    stopped = 0
    out = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "{") {
        if (++depth == 1) {
          head = trim(substr(s, start, i - start))
          split(head, ss, /[ \t\n]+/)
          if (tolower(ss[1]) != "option") stopped = 1
          id = ss[2]
          split("", field)
        }
        start = i + 1
      } else if (c == "}") {
        if (depth == 0) break
        if (depth-- == 1 && !stopped && id != "") {
          type = ("type" in field) ? trim(field["type"]) : ""
          if ((type == "boolean" || type == "string") && ("default" in field) ||
              type == "integer" && int_ok(field["min"]) && int_ok(field["max"]) && int_ok(field["default"]) ||
              type == "double" && double_ok(field["min"]) && double_ok(field["max"]) && double_ok(field["default"]) ||
              type == "enum" && int_ok(field["numValues"]) && trim(field["numValues"]) + 0 > 0 && int_ok(field["default"]) && trim(field["default"]) + 0 > 0) {
            out = out "option\t" key "\t" rank "\t" (++seq) "\t" clean(id) "\t" type "\t" clean(trim(field["default"])) "\t" \
              clean(trim(field["min"])) "\t" clean(trim(field["max"])) "\t" clean(trim(field["page"])) "\t" clean(trim(field["translation"])) "\t" \
              clean(trim(field["valueTranslation"])) "\t" clean(trim(field["numValues"])) "\n"
          }
        }
        start = i + 1
        i++
      } else if (c == ",") {
        value = substr(s, start, i - start)
        if ((j = index(value, "=")) > 1) {
          if (depth == 0 && trim(substr(value, 1, j - 1)) == "VERSION" && version == "") version = int_ok(substr(value, j + 1)) ? trim(substr(value, j + 1)) + 0 : -1
          else if (depth == 1 && !(trim(substr(value, 1, j - 1)) in field)) field[trim(substr(value, 1, j - 1))] = substr(value, j + 1)
        }
        start = i + 1
      }
    }
    if (version == 1) printf "%s", out
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

bash "${SCRIPT_DIR}/list_env.sh" --tsv | awk -F '\t' '$1 == "ini" || $1 == "sandbox"' > "${tmp}/settings"

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
  --rawfile settings "${tmp}/settings" '
  def lines: split("\n") | map(select(length > 0));
  def rows: lines | map(split("\t"));
  def text: if . == "" then null else . end;
  def ids: if . == "" then [] else split(",") end;
  def number: tonumber? // null;
  def unquote: if test("^\".*\"$") then .[1:-1] | gsub("\\\\(?<c>[\"\\\\])"; .c) else . end;
  # The settings whose values stay out: the keys list-env masks (password, token), webhook URLs, which hold a
  # token of their own, the Discord and RCON settings and the announced IP. RCON keys start with "rcon"; others
  # contain it, such as ItemNumbersLimitPerContainer.
  def secret: ascii_downcase | test("password|token|webhook|discord|^rcon|announced_ip");

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
  | ($settings | rows) as $settings
  | ($settings | map(select(.[0] == "sandbox") | {key: (.[1] | ascii_downcase), value: (.[2] // "" | unquote)}) | from_entries) as $current
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
       current: (if .option | split(".") | any(secret) then null else $current[.env | ascii_downcase] end)};

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

  | [
        [$tree[] | if .children == null then .id else .children[] | select(.collection | not) | .id end]
        + ($server_items | lines) + ($downloaded | keys) | unique | sort_by(length, .)
        | .[] as $id | $info[$id] as $i
        | {id: $id, available: ($i != null),
           title: $i.title, description: $i.description, tags: (if $i then [$i.tags[]?.tag] else null end),
           updated: ($i.time_updated | number), size: ($i.file_size | number),
           requiredItems: (if $keyed then [$required[$id].children[]?.publishedfileid] else null end),
           downloaded: ($downloaded[$id] != null), mods: ($item_mods[$id] // [])}
    ] as $items
  # The words of the workshop pages of the items, for the server settings they name.
  | ([$items[].description // empty | ascii_downcase | scan("[a-z0-9_]+")] | unique | map({key: ., value: true}) | from_entries) as $words
  | {
      format: 2,
      gameVersion: $version,
      workshopIds: ($workshop_ids | lines),
      server: {mods: ($server_mods | lines), map: ($server_map | lines), workshopItems: ($server_items | lines),
        # Only what the mods page reads: the Lua checksum, the anti-cheat settings and the settings a workshop page names.
        options: ($settings | map(select(.[0] == "ini") | {key: (.[1] | ltrimstr("INI_")), value: (.[2] // "")}
          | select((.key | secret | not) and (.key == "DoLuaChecksum" or (.key | test("^anticheat"; "i")) or $words[.key | ascii_downcase])))
          | from_entries)},
      collections: [$tree[] | select(.children != null) | {id, title: $info[.id].title, children: [.children[].id]}],
      items: $items
    }
' > "${tmp}/mods.json"

if [ -z "${base}" ]; then
  cat "${tmp}/mods.json"
  exit 0
fi

upload_error() {
  echo "Error: could not upload to ${host}: $1. Write the file instead: docker exec <container> list-mods > mods.json" >&2
  exit 1
}

gzip -9 < "${tmp}/mods.json" > "${tmp}/mods.json.gz"
: > "${tmp}/answer"
# Bytebin serves the file with the Content-Encoding it got, so browsers decompress it.
if ! status="$(curl -sS --connect-timeout 15 --max-time 120 -A "${user_agent}" -o "${tmp}/answer" -w '%{http_code}' \
  -H 'Content-Type: application/json' -H 'Content-Encoding: gzip' --data-binary "@${tmp}/mods.json.gz" "${base}/post" \
  2> "${tmp}/curl-error")"; then
  upload_error "$(head -n 1 "${tmp}/curl-error" | sed 's/^curl: ([0-9]*) //')"
fi
# The start of the answer for messages, on one line and without control characters.
answer="$(head -c 200 "${tmp}/answer" | LC_ALL=C tr -c '[:print:]' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
[[ "${status}" == 2[0-9][0-9] ]] || upload_error "HTTP ${status}${answer:+: ${answer}}"

if ! key="$(jq -c .key "${tmp}/answer" 2> /dev/null)" || ! [[ "${key}" =~ ^\"([A-Za-z0-9]+)\"$ ]]; then
  upload_error "unexpected answer \"${answer}\""
fi
url="${base}/${BASH_REMATCH[1]}"

echo "Uploaded to ${host}, ${deleted}. Open this link to load it on the mods page:"
echo "${mods_page}#url=${url}"
echo "The file alone, to load by hand:"
echo "${url}"
echo "Anyone with the link can read the mod list, the sandbox settings and the few server settings the mods page uses; passwords, tokens and the like are left out."
