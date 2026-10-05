#!/bin/bash
# Workshop items, the mods in them and the maps that enabled mods bring along.

VANILLA_MAP="Muldraugh, KY"

console_game_version() {
  # Prints the game version the server logged at its last start, nothing before the first start.
  local console="${HOMEDIR}/Zomboid/server-console.txt"
  [ -f "${console}" ] || return 0
  grep -m 1 -oE '(versionNumber=|[[:space:]>]version=|ZNet: Startup version )[0-9]+\.[0-9]+(\.[0-9]+)?' "${console}" \
    | head -n 1 | sed 's/.*[= ]//' || true
}

# Reads the mod.info of every mod in the given items. Build 41 loads the one in the mod folder itself,
# Build 42 the one in the highest version folder (42, 42.12, ...) that is not newer than the game.
mod_info_rows() {
  # $1 = game version ("" when unknown), then the mods folders of the items (<item>/mods).
  # Prints per mod folder: item (the item folder's name), folder, version folder ("." for the mod
  # folder itself), whether it loads (1, 0, or ? for an unknown version; when it doesn't, the newest
  # mod.info is read), id, name, description, author, modversion, url, category, versionMin,
  # versionMax, the mod IDs of require, loadModAfter, loadModBefore and incompatible, separated by
  # commas, and the path of the mod folder.
  local version="$1" dir
  local -a dirs=()
  shift
  for dir in "$@"; do
    [ -d "${dir}" ] && dirs+=("${dir}")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  find "${dirs[@]}" -mindepth 2 -maxdepth 3 -name mod.info -type f -printf '%H\t%P\n' \
    | LC_ALL=C awk -F '\t' -v version="${version}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function newer(a, b,   x, y, n, m, i, d) {
      n = split(a, x, ".")
      m = split(b, y, ".")
      for (i = 1; i <= n || i <= m; i++) {
        d = (i <= n ? x[i] + 0 : 0) - (i <= m ? y[i] + 0 : 0)
        if (d != 0) return d > 0
      }
      return 0
    }
    # "\A, 2392709985\B;C;A" -> "A,B,C"
    function mod_ids(s,   n, parts, i, id, out, seen) {
      n = split(s, parts, /[,;]/)
      out = ""
      for (i = 1; i <= n; i++) {
        id = parts[i]
        sub(/.*\\/, "", id)
        id = trim(id)
        if (id == "" || (id in seen)) continue
        seen[id] = 1
        out = out (out == "" ? "" : ",") id
      }
      return out
    }
    function field(key,   v) { v = info[key]; gsub(/\t/, " ", v); return v }
    function read_info(path,   line, i, first) {
      split("", info)
      first = 1
      while ((getline line < path) > 0) {
        if (first) sub(/^\357\273\277/, "", line)
        first = 0
        sub(/\r$/, "", line)
        i = index(line, "=")
        if (i > 1) info[tolower(trim(substr(line, 1, i - 1)))] = trim(substr(line, i + 1))
      }
      close(path)
    }
    # <mods folder> TAB <mod folder>/mod.info or <mod folder>/<version folder>/mod.info
    {
      dir = $1
      sub(/\/+$/, "", dir)
      n = split($2, part, "/")
      key = dir "/" part[1]
      if (!(key in found)) {
        found[key] = 1
        keys[++count] = key
        item[key] = dir
        sub(/\/[^\/]*$/, "", item[key])
        sub(/.*\//, "", item[key])
        folder[key] = part[1]
      }
      if (n == 2) {
        root[key] = 1
        next
      }
      if (part[2] !~ /^[0-9]+(\.[0-9]+)*$/) next
      if (!(key in newest) || newer(part[2], newest[key])) newest[key] = part[2]
      if (version != "" && !newer(part[2], version) && (!(key in loads) || newer(part[2], loads[key]))) loads[key] = part[2]
    }
    END {
      split(version, v, ".")
      for (i = 1; i <= count; i++) {
        key = keys[i]
        best = (key in newest) ? newest[key] : ((key in root) ? "." : "")
        if (best == "") continue
        if (version == "") {
          state = "?"
        } else if (v[1] + 0 < 42) {
          state = (key in root) ? 1 : 0
          if (state) best = "."
        } else {
          state = (key in loads) ? 1 : 0
          if (state) best = loads[key]
        }
        read_info(key "/" best "/mod.info")
        author = ("author" in info) ? field("author") : field("authors")
        print item[key] "\t" folder[key] "\t" best "\t" state "\t" field("id") "\t" field("name") "\t" field("description") "\t" \
          author "\t" field("modversion") "\t" field("url") "\t" field("category") "\t" field("versionmin") "\t" \
          field("versionmax") "\t" mod_ids(info["require"]) "\t" mod_ids(info["loadmodafter"]) "\t" \
          mod_ids(info["loadmodbefore"]) "\t" mod_ids(info["incompatible"]) "\t" key
      }
    }
  '
}

mod_dirs() {
  # stdin = mod_info_rows output. Prints for each mod that loads: item, folder, rank, a folder its
  # files come from and the mod ID: the version folder (rank 0), then common/ (rank 1), which Build
  # 42 mods share between versions. The ID goes last because it can be empty, and read with a tab
  # IFS merges empty fields.
  awk -F '\t' '$4 == 1 {
    print $1 "\t" $2 "\t0\t" ($3 == "." ? $18 : $18 "/" $3) "\t" $5
    if ($3 != ".") print $1 "\t" $2 "\t1\t" $18 "/common\t" $5
  }'
}

# Warns about enabled mods that are in no downloaded item and not in Zomboid/mods, that miss a mod
# they require, that are listed in the wrong order or that conflict. Items download while the server
# starts, so missing mods are only reported once every item in WorkshopItems is there, and the
# version folders are picked by the game version of the last start.
report_mod_problems() {
  # $1 = INI file, $2 = workshop content dir
  local ini_file="$1" content_dir="$2" mods item check_missing=1
  local -a items=()
  mods="$(ini_value "${ini_file}" Mods)"
  [ -n "${mods//[[:space:];\\]/}" ] || return 0
  IFS=';' read -ra items <<< "$(ini_value "${ini_file}" WorkshopItems)"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    if [ -n "${item}" ] && [ ! -d "${content_dir}/${item}" ]; then
      check_missing=0
    fi
  done
  # Zomboid/mods holds mods placed there by hand, which load like the ones of an item.
  mod_info_rows "$(console_game_version)" "${content_dir}"/*/mods "${HOMEDIR}/Zomboid/mods" \
    | MODS="${mods}" awk -F '\t' -v check_missing="${check_missing}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function wrong_order(mod, other, text,   pair) {
      pair = mod < other ? mod SUBSEP other : other SUBSEP mod
      if (pair in reported) return
      reported[pair] = 1
      print "Warning: " text
    }
    # The lists of the first copy that loads, per mod ID and per item and mod ID.
    function keep(k) {
      if (k in requires) return
      requires[k] = $14
      after[k] = $15
      before[k] = $16
      incompatible[k] = $17
    }
    # Entries are `\ModId`, `<workshop id>\ModId` or a plain Build 41 `ModId`.
    BEGIN {
      n = split(ENVIRON["MODS"], entries, ";")
      for (e = 1; e <= n; e++) {
        m = split(entries[e], part, /\\/)
        id = trim(part[m])
        if (id == "") continue
        item = ""
        for (k = 1; k < m && item == ""; k++) item = trim(part[k])
        order[++count] = id
        from[count] = item
        if (!(id in pos)) pos[id] = count
      }
    }
    { downloaded[$5] = 1 }
    $4 == 1 && ($5 in pos) {
      keep($5)
      keep($1 SUBSEP $5)
    }
    END {
      for (i = 1; i <= count; i++) {
        mod = order[i]
        if (pos[mod] == i && check_missing && !(mod in downloaded)) {
          print "Warning: Mods= enables " mod ", but neither a downloaded workshop item nor Zomboid/mods has it."
        }
        # An entry naming its item checks that copy; one without, or naming an item without it, the first copy.
        key = (from[i] SUBSEP mod) in requires ? from[i] SUBSEP mod : mod
        if (!(key in requires) || checked[key]++) continue
        n = split(requires[key], list, ",")
        for (j = 1; j <= n; j++) {
          if (!(list[j] in pos)) {
            # Two copies of a mod ID can require the same mod.
            if (!((mod, list[j]) in unmet)) print "Warning: " mod " requires " list[j] ", which is not in Mods=."
            unmet[mod, list[j]] = 1
          } else if (pos[list[j]] > i) {
            wrong_order(mod, list[j], "Mods= lists " mod " before " list[j] ", which it requires.")
          }
        }
        n = split(after[key], list, ",")
        for (j = 1; j <= n; j++) {
          if ((list[j] in pos) && pos[list[j]] > i) wrong_order(mod, list[j], "Mods= lists " mod " before " list[j] ", but its mod.info says to load it after " list[j] ".")
        }
        n = split(before[key], list, ",")
        for (j = 1; j <= n; j++) {
          if ((list[j] in pos) && pos[list[j]] < i) wrong_order(mod, list[j], "Mods= lists " mod " after " list[j] ", but its mod.info says to load it before " list[j] ".")
        }
        n = split(incompatible[key], list, ",")
        for (j = 1; j <= n; j++) {
          other = list[j]
          if (!(other in pos) || other == mod) continue
          pair = mod < other ? mod SUBSEP other : other SUBSEP mod
          if (pair in conflict) continue
          conflict[pair] = 1
          print "Warning: " mod " and " other " are both in Mods=, but the mod.info of " mod " says they are incompatible."
        }
      }
    }
  ' >&2
}

split_list() {
  # $1 = ';'-separated list; prints the entries one per line, trimmed, without empty ones
  tr ';' '\n' <<< "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

workshop_details() {
  # stdin = workshop IDs, one per line. Prints Steam's details of each 100 of them as one JSON line;
  # fails when Steam can't be reached or leaves an item out.
  local i response
  local -a batch=() ids=()
  while mapfile -t -n 100 batch && [ "${#batch[@]}" -gt 0 ]; do
    ids=()
    for i in "${!batch[@]}"; do
      ids+=(--data-urlencode "publishedfileids[$i]=${batch[$i]}")
    done
    response="$(curl -fsS --max-time 30 -X POST --data-urlencode "itemcount=${#batch[@]}" "${ids[@]}" \
      'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/')" || return 1
    jq -ce --argjson count "${#batch[@]}" 'select((.response.publishedfiledetails | length) == $count)' \
      <<< "${response}" 2>/dev/null || return 1
  done
}

apply_workshop_ids() {
  # $1 = INI file, $2 = workshop content dir. Collections in WORKSHOP_IDS are expanded to the items
  # they contain.
  local ini_file="$1" content_dir="$2" ids resolved details id
  local -a unavailable=() kept=() dropped=()
  [ -n "${WORKSHOP_IDS+x}" ] || return 0
  ids="$(split_list "${WORKSHOP_IDS}" | paste -sd ';')"
  if [ -z "${ids}" ]; then
    set_ini_value "${ini_file}" WorkshopItems ""
    return 0
  fi
  if ! resolved="$(bash "${SCRIPT_DIR}/resolve_workshop_collection.sh" "${ids}")" || [ -z "${resolved}" ]; then
    echo "Warning: could not resolve WORKSHOP_IDS through the Steam API, leaving WorkshopItems unchanged." >&2
    return 0
  fi
  if ! details="$(workshop_details <<< "${resolved}")"; then
    echo "Warning: could not check the workshop items through the Steam API, leaving WorkshopItems unchanged." >&2
    return 0
  fi
  # Steam answers result 9 for items that are removed, hidden or private. The server stops with an
  # error on one it can't download, but keeps using one it downloaded before.
  mapfile -t unavailable < <(jq -r '.response.publishedfiledetails[] | select(.result == 9) | .publishedfileid' <<< "${details}")
  for id in "${unavailable[@]}"; do
    if [ -d "${content_dir}/${id}" ]; then
      kept+=("${id}")
    else
      dropped+=("${id}")
    fi
  done
  if [ "${#kept[@]}" -gt 0 ]; then
    echo "Warning: these workshop items are removed, hidden or private; the server keeps the copy it downloaded, which gets no more updates: ${kept[*]}" >&2
  fi
  if [ "${#dropped[@]}" -gt 0 ]; then
    echo "Warning: these workshop items are removed, hidden or private, so they were left out of WorkshopItems: ${dropped[*]}" >&2
    echo "         Take them out of WORKSHOP_IDS or its collections." >&2
    resolved="$(grep -vxF -f <(printf '%s\n' "${dropped[@]}") <<< "${resolved}")"
  fi
  resolved="$(paste -sd ';' <<< "${resolved}")"
  set_ini_value "${ini_file}" WorkshopItems "${resolved}"
  echo "Config: WorkshopItems set to ${resolved}"
}

enabled_mod_ids() {
  # $1 = INI file; one mod ID per line. B42 entries look like `\ModId` or `<workshop id>\ModId`.
  ini_value "$1" Mods | tr ';' '\n' | sed -e 's/.*\\//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d'
}

mod_maps() {
  # stdin = mod_info_rows output, $1 = enabled mod IDs, one per line.
  # Prints "<enabled|disabled>\t<map name>\t<map dir>" for each map of a mod that loads.
  local id dir map_dir state
  local -A enabled=()
  while IFS= read -r id; do
    [ -n "${id}" ] && enabled["${id}"]=1
  done <<< "$1"
  mod_dirs | while IFS=$'\t' read -r _ _ _ dir id; do
    [ -n "${id}" ] || continue
    state=disabled
    [ -n "${enabled[${id}]+x}" ] && state=enabled
    for map_dir in "${dir}"/media/maps/*/; do
      map_dir="${map_dir%/}"
      # Mods that patch the vanilla map ship a folder with its name; it's always in Map= anyway.
      [ -d "${map_dir}" ] && [ "${map_dir##*/}" != "${VANILLA_MAP}" ] || continue
      printf '%s\t%s\t%s\n' "${state}" "${map_dir##*/}" "${map_dir}"
    done
  done
}

merge_map_list() {
  # $1 = current Map= value, $2 = ';'-separated maps to drop, then the maps to add. Keeps the
  # admin's order, adds new maps before the vanilla map and keeps the vanilla map last.
  local current="$1" name vanilla=false
  local -a merged=() entries=() dropped=()
  local -A present=()
  IFS=';' read -ra dropped <<< "$2"
  shift 2
  for name in "${dropped[@]}"; do
    present["${name}"]=1
  done
  IFS=';' read -ra entries <<< "${current}"
  for name in "${entries[@]}"; do
    [ -n "${name}" ] || continue
    if [ "${name}" = "${VANILLA_MAP}" ]; then
      vanilla=true
      continue
    fi
    [ -n "${present[${name}]+x}" ] && continue
    present["${name}"]=1
    merged+=("${name}")
  done
  for name in "$@"; do
    [ -n "${present[${name}]+x}" ] && continue
    present["${name}"]=1
    merged+=("${name}")
  done
  if [ "${vanilla}" = true ] || [ -z "${current}" ]; then
    merged+=("${VANILLA_MAP}")
  fi
  (IFS=';'; printf '%s' "${merged[*]}")
}

add_spawn_region() {
  # $1 = spawnregions file, $2 = map name. Adds the map's spawn points when they are missing.
  local file="$1" name="$2"
  grep -qF "media/maps/${name}/spawnpoints.lua" "${file}" && return 0
  NAME="${name}" awk '
    { print }
    !done && /^[[:space:]]*return[[:space:]]*\{/ {
      printf "\t\t{ name = \"%s\", file = \"media/maps/%s/spawnpoints.lua\" },\n", ENVIRON["NAME"], ENVIRON["NAME"]
      done = 1
    }
  ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  echo "Config: spawn region added for ${name}"
}

remove_spawn_region() {
  # $1 = spawnregions file, $2 = map name
  local file="$1" name="$2"
  grep -qF "media/maps/${name}/spawnpoints.lua" "${file}" || return 0
  grep -vF "media/maps/${name}/spawnpoints.lua" "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  echo "Config: spawn region removed for ${name}"
}

# Adds the maps of enabled mods to Map= and their spawn points to the spawnregions file, and
# removes the maps of downloaded mods that are no longer enabled, which the server can't load.
apply_mod_maps() {
  # $1 = INI file, $2 = spawnregions file, $3 = workshop content dir
  local ini_file="$1" spawn_file="$2" content_dir="$3" version maps current merged state name dir
  # The game version picks the version folders. It is known from the first start on, and nothing is
  # downloaded before that.
  version="$(console_game_version)"
  [ -n "${version}" ] || return 0
  maps="$(mod_info_rows "${version}" "${content_dir}"/*/mods | mod_maps "$(enabled_mod_ids "${ini_file}")")"
  [ -n "${maps}" ] || return 0

  local -a added=() dropped=()
  local -A enabled_map=()
  while IFS=$'\t' read -r state name dir; do
    if [ "${state}" = enabled ]; then
      added+=("${name}")
      enabled_map["${name}"]=1
    fi
  done <<< "${maps}"
  while IFS=$'\t' read -r state name dir; do
    [ "${state}" = disabled ] && [ -z "${enabled_map[${name}]+x}" ] && dropped+=("${name}")
  done <<< "${maps}"

  current="$(ini_value "${ini_file}" Map)"
  merged="$(merge_map_list "${current}" "$(IFS=';'; printf '%s' "${dropped[*]}")" "${added[@]}")"
  if [ "${merged}" != "${current}" ]; then
    set_ini_value "${ini_file}" Map "${merged}"
    echo "Config: Map set to ${merged}"
  fi

  [ -f "${spawn_file}" ] || return 0
  while IFS=$'\t' read -r state name dir; do
    if [ -n "${enabled_map[${name}]+x}" ]; then
      [ -f "${dir}/spawnpoints.lua" ] && add_spawn_region "${spawn_file}" "${name}"
    else
      remove_spawn_region "${spawn_file}" "${name}"
    fi
  done <<< "${maps}"
  return 0
}
