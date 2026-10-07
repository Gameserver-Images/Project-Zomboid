#!/bin/bash
# Workshop items, the mods in them and the maps that enabled mods bring along.

VANILLA_MAP="Muldraugh, KY"

# Reads the mods in the given mods folders the way the game does (ChooseGameInfo, ZomboidFileSystem).
# Build 41 reads mod.info in the mod folder itself. Build 42 picks the folder with the highest
# version name (42, 42.12, ...) that isn't newer than the game, whether or not it holds a mod.info,
# reads its mod.info or else the one in common/, and compares versions only by major.minor. A
# mod.info in the mod folder itself is read with the Build 41 rules, any other with the Build 42 ones.
mod_info_rows() {
  # $1 = game version ("" when unknown), then the mods folders (<item>/mods, Zomboid/mods).
  # Prints per mod folder, in the order the game lists them: item (the name of the folder above the
  # mods folder), folder, the folder its files come from besides common/ ("." for the mod folder
  # itself, "common" when there is none, "" when the game finds no mod.info, in which case the fields
  # come from another mod.info in it), state (1 when the game finds the mod and it can load on this
  # version, 0 when it finds it but versionMin, versionMax or an empty require entry stop it, - when
  # it doesn't find it, ? for an unknown version), id, name, description, author, modversion, url,
  # category, versionMin, versionMax, the mod IDs of require, loadModAfter, loadModBefore and
  # incompatible, separated by commas, the path of the mod folder, why the game rejects the mod or,
  # when versionMin and versionMax let it load, why it can't load it by itself ("" when nothing), and
  # the require entries as the game looks them up: untrimmed, each followed by a comma.
  local version="$1" dir
  local -a dirs=()
  shift
  for dir in "$@"; do
    [ -d "${dir}" ] && dirs+=("${dir}")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  # Entries come in directory order, like the game's File.list(), which decides between equal
  # versions. The game follows symbolic links, and reads on past a loop of them, where find fails.
  { find -L "${dirs[@]}" -mindepth 1 -maxdepth 3 -printf '%H\t%P\t%y\n' 2> /dev/null || true; } \
    | LC_ALL=C awk -F '\t' -v version="${version}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # Java Integer.parseInt of the trimmed string, with 0 for anything else (PZMath.tryParseInt)
    function number(s) {
      s = trim(s)
      return s ~ /^[+-]?[0-9]+$/ && s + 0 >= -2147483648 && s + 0 <= 2147483647 ? s + 0 : 0
    }
    # Version folder names: the first part times 1000 plus the second, at most 999
    function folder_version(name,   n, p, minor) {
      n = split(name, p, ".")
      if (n == 1) return number(p[1]) * 1000
      minor = number(p[2])
      return number(p[1]) * 1000 + (minor > 999 ? 999 : minor)
    }
    # versionMin, versionMax and the game version: major.minor, -1 when the game cannot parse it
    # (GameVersion.parse)
    function game_version(s,   p) {
      if (!match(s, /^[0-9]+\.[0-9]+/)) return -1
      split(substr(s, 1, RLENGTH), p, ".")
      return number(p[2]) > 999 ? -1 : number(p[1]) * 1000 + number(p[2])
    }
    # Java String.replace(key, ""): every occurrence goes
    function remove(s, key,   out, i) {
      out = ""
      while ((i = index(s, key)) > 0) {
        out = out substr(s, 1, i - 1)
        s = substr(s, i + length(key))
      }
      return out s
    }
    # Build 42 drops every backslash; both split on commas and trim each mod ID.
    function mod_ids(s,   n, parts, i, id, out, seen) {
      if (!old_rules) gsub(/\\/, "", s)
      n = split(s, parts, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        id = trim(parts[i])
        if (id == "" || (id in seen)) continue
        seen[id] = 1
        out = out (out == "" ? "" : ",") id
      }
      return out
    }
    function field(key,   v) { v = trim(info[key]); gsub(/\t/, " ", v); return v }
    # The first line that makes the game reject the whole mod.info (readModInfoAux returns null)
    function reject(why) { if (!("rejected" in info)) info["rejected"] = why }
    # pack=<file> or pack=<file> type=<type>: the game cuts the second at the first space, and fails
    # without one.
    function pack(v) {
      v = trim(v)
      if (v == "") reject("its mod.info has an empty pack= line")
      else if (index(v, "type=") && !index(v, " ")) reject("its mod.info has pack=" v ", which needs a space before type=")
    }
    # tiledef=<file> <number from 100 to highest>
    function tiledef(v, highest,   parts) {
      v = trim(v)
      if (split(v, parts, /[ \t]+/) != 2 || parts[2] !~ /^[+-]?[0-9]+$/ || parts[2] + 0 < 100 || parts[2] + 0 > highest) {
        reject("its mod.info has tiledef=" v ", which needs a file name and a number from 100 to " highest)
      }
    }
    # An empty value leaves the one of an earlier line.
    function bound(key, line,   v) {
      v = remove(line, key "=")
      if (trim(v) == "") return
      info[tolower(key)] = v
      v = field(tolower(key))
      if (game_version(v) < 0) reject("its mod.info has " key "=" v ", which is not a major.minor version like 42.13")
    }
    # The keys are tested in the game'"'"'s order, so a line counts for the first key it contains. Like
    # Java'"'"'s readLine, lines also end at a lone \r, and a byte order mark stays part of the first line.
    function read_info(path, default_id,   text, lines, n, i, line) {
      split("", info)
      info["id"] = default_id
      while ((getline text < path) > 0) {
        n = split(text, lines, "\r")
        for (i = 1; i <= n; i++) {
          line = lines[i]
          if (old_rules) {
            if (index(line, "name=")) info["name"] = remove(line, "name=")
            else if (index(line, "poster=")) continue
            else if (index(line, "description=")) info["description"] = info["description"] remove(line, "description=")
            else if (index(line, "require=")) info["require"] = remove(line, "require=")
            else if (index(line, "id=")) info["id"] = remove(line, "id=")
            else if (index(line, "url=")) info["url"] = remove(line, "url=")
            else if (index(line, "pack=")) pack(remove(line, "pack="))
            else if (index(line, "tiledef=")) tiledef(remove(line, "tiledef="), 16382)
            else if (index(line, "versionMax=") == 1) bound("versionMax", line)
            else if (index(line, "versionMin=") == 1) bound("versionMin", line)
          } else {
            if (index(line, "name=")) { if (trim(remove(line, "name=")) != "") info["name"] = remove(line, "name=") }
            else if (index(line, "poster=")) continue
            else if (index(line, "description=")) info["description"] = info["description"] remove(line, "description=")
            else if (index(line, "require=")) info["require"] = remove(line, "require=")
            else if (index(line, "incompatible=")) info["incompatible"] = remove(line, "incompatible=")
            else if (index(line, "loadModAfter=")) info["loadmodafter"] = remove(line, "loadModAfter=")
            else if (index(line, "loadModBefore=")) info["loadmodbefore"] = remove(line, "loadModBefore=")
            else if (index(line, "id=") == 1) { if (trim(remove(line, "id=")) != "") info["id"] = remove(line, "id=") }
            else if (index(line, "author=")) info["author"] = remove(line, "author=")
            else if (index(line, "modversion=")) info["modversion"] = remove(line, "modversion=")
            else if (index(line, "icon=")) continue
            else if (index(line, "category=")) info["category"] = remove(line, "category=")
            else if (index(line, "url=")) info["url"] = remove(line, "url=")
            else if (index(line, "pack=")) pack(remove(line, "pack="))
            else if (index(line, "tiledef=")) tiledef(remove(line, "tiledef="), 8189)
            else if (index(line, "versionMax=") == 1) bound("versionMax", line)
            else if (index(line, "versionMin=") == 1) bound("versionMin", line)
          }
        }
      }
      close(path)
    }
    # The game checks that the trimmed require entries name mods that can load, then loads them as
    # written (Mod.isAvailableRequired, ZomboidFileSystem.loadModAndRequired), so an empty entry stops
    # the mod and one with spaces around it is never found. Java'"'"'s split drops empty entries only at
    # the end, and "require=" alone is one empty entry.
    function read_require(   s, n, parts, i) {
      require = ""
      empty = 0
      spaced = ""
      if (!("require" in info)) return
      s = info["require"]
      if (!old_rules) gsub(/\\/, "", s)
      gsub(/\t/, " ", s)
      n = split(s, parts, ",")
      while (n > 0 && parts[n] == "") n--
      if (s == "") n = 1
      for (i = 1; i <= n; i++) {
        require = require parts[i] ","
        if (trim(parts[i]) == "") empty = 1
        else if (spaced == "" && parts[i] != trim(parts[i])) spaced = trim(parts[i])
      }
    }
    BEGIN { game = game_version(version) }
    # <mods folder> TAB <path below it> TAB <type>: mod folders, what is in them, and the mod.info
    # files one level further down.
    {
      dir = $1
      sub(/\/+$/, "", dir)
      n = split($2, part, "/")
      key = dir "/" part[1]
      if (n == 1) {
        if ($3 != "d" || tolower(part[1]) == "examplemod") next
        keys[++count] = key
        item[key] = dir
        sub(/\/[^\/]*$/, "", item[key])
        sub(/.*\//, "", item[key])
        folder[key] = part[1]
        best[key] = 42000
        chosen[key] = "42.0"
        next
      }
      if (n == 2) {
        entry[key, part[2]] = 1
        names[key, ++entries[key]] = part[2]
        if (part[2] == "mod.info") info_in[key, "."] = 1
        v = folder_version(part[2])
        if (game >= 0 && v >= best[key] && v <= game) {
          best[key] = v
          chosen[key] = part[2]
        }
        next
      }
      if (part[3] == "mod.info") info_in[key, part[2]] = 1
    }
    END {
      for (i = 1; i <= count; i++) {
        key = keys[i]
        if (game < 0) {
          files = ""
        } else if (game < 42000) {
          files = ((key, ".") in info_in) ? "." : ""
        } else if ((key, chosen[key]) in info_in) {
          files = chosen[key]
          info_dir = chosen[key]
        } else if ((key, "common") in info_in) {
          files = ((key, chosen[key]) in entry) ? chosen[key] : "common"
          info_dir = "common"
        } else {
          files = ""
        }
        if (files == ".") info_dir = "."
        if (files == "") {
          # Not a mod the game sees on this version: show the mod.info most likely meant for it, from
          # common/, the newest version folder that has one, or the mod folder itself.
          info_dir = ""
          if ((key, "common") in info_in) {
            info_dir = "common"
          } else {
            for (j = 1; j <= entries[key]; j++) {
              name = names[key, j]
              if (name ~ /^[0-9]+(\.[0-9]+)*$/ && ((key, name) in info_in) && (info_dir == "" || folder_version(name) > folder_version(info_dir))) info_dir = name
            }
          }
          if (info_dir == "" && ((key, ".") in info_in)) info_dir = "."
          if (info_dir == "") continue
        }
        old_rules = info_dir == "."
        read_info(key "/" info_dir "/mod.info", old_rules ? folder[key] : "")
        read_require()
        # Build 41 keeps spaces around the ID.
        id = info["id"]
        if (old_rules) gsub(/\t/, " ", id)
        else id = field("id")
        error = ""
        if (game < 0) {
          state = "?"
        } else if (files == "") {
          state = "-"
          error = "no mod.info for this game version"
        } else if ("rejected" in info) {
          state = "-"
          error = info["rejected"]
        } else {
          low = game_version(field("versionmin"))
          high = game_version(field("versionmax"))
          # The game checks versionMin and versionMax before the require entries.
          if (low > game || (high >= 0 && high < game)) {
            state = 0
          } else if (empty) {
            state = 0
            error = "its require= has an empty entry"
          } else {
            state = 1
            if (spaced != "") error = "its require= has spaces around " spaced
          }
        }
        print item[key] "\t" folder[key] "\t" files "\t" state "\t" id "\t" field("name") "\t" field("description") "\t" \
          field("author") "\t" field("modversion") "\t" field("url") "\t" field("category") "\t" field("versionmin") "\t" \
          field("versionmax") "\t" mod_ids(info["require"]) "\t" mod_ids(info["loadmodafter"]) "\t" \
          mod_ids(info["loadmodbefore"]) "\t" mod_ids(info["incompatible"]) "\t" key "\t" error "\t" require
      }
    }
  '
}

mod_dirs() {
  # stdin = mod_info_rows output. Prints for each mod whose mod.info the game reads: item, folder,
  # rank and a folder its files come from: the version folder (rank 0), then common/ (rank 1).
  awk -F '\t' '$3 != "" {
    if ($3 != "common") print $1 "\t" $2 "\t0\t" ($3 == "." ? $18 : $18 "/" $3)
    if ($3 != ".") print $1 "\t" $2 "\t1\t" $18 "/common"
  }'
}

# Works out what the server loads from Mods= (GameServer, ZomboidFileSystem.loadMods): each entry
# after the mods it requires, which load even when Mods= doesn't list them. The server sees the
# items in WorkshopItems, in that order, then Zomboid/mods, which holds mods placed there by hand,
# and the first of them with a mod ID has it. Prints the mod_info_rows it reads, each after a tag:
# "load" for the mods the server loads, in load order, "" for the rest. Warns about entries that
# don't load and why, and about load order hints and conflicts among the mods that load. The server
# downloads the items SteamCMD couldn't while it starts, so missing mods are only reported once every
# item in WorkshopItems is there; without a game version that is all it checks.
load_mods() {
  # $1 = INI file, $2 = workshop content dir, $3 = game version ("" when unknown)
  local ini_file="$1" content_dir="$2" version="$3" item check_missing=1
  local -a dirs=()
  while IFS= read -r item; do
    [ -d "${content_dir}/${item}" ] || check_missing=0
    dirs+=("${content_dir}/${item}/mods")
  done < <(split_list "$(ini_value "${ini_file}" WorkshopItems)" | awk '!seen[$0]++')
  dirs+=("${HOMEDIR}/Zomboid/mods")
  mod_info_rows "${version}" "${dirs[@]}" \
    | MODS="$(ini_value "${ini_file}" Mods)" LC_ALL=C awk -F '\t' -v version="${version}" -v check_missing="${check_missing}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function warn(text) { print "Warning: " text > "/dev/stderr" }
    function requires(id, list,   n) { n = split(raw[id], list, ","); return n ? n - 1 : 0 }
    # ChooseGameInfo.getAvailableModDetails: the game finds the mod, it can load on this version, and
    # so can every mod it requires, all the way down. needs[] keeps the requirement that stops it.
    function available(id) {
      split("", seen)
      seen[id] = 1
      return usable(id)
    }
    function usable(id,   n, list, i, other) {
      if (!(id in state) || state[id] != "1") return 0
      n = requires(id, list)
      for (i = 1; i <= n; i++) {
        other = trim(list[i])
        if (other in seen) continue
        seen[other] = 1
        if (!usable(other)) {
          needs[id] = other
          return 0
        }
      }
      return 1
    }
    # ZomboidFileSystem.loadModAndRequired: loads the mods a mod requires, as written, then the mod.
    # Returns the ID that does not load, "" when the mod loads or is skipped.
    function load(id,   n, list, i, failed) {
      if (id == "" || tolower(id) == "examplemod" || (id in loaded)) return ""
      if (!available(id)) return id
      # The game would go round in circles until it runs out of stack.
      if (id in loading) {
        if (loop == "") loop = loop_text(id)
        return id
      }
      loading[id] = ++depth
      stack[depth] = id
      n = requires(id, list)
      for (i = 1; i <= n && (failed = load(list[i])) == ""; i++) {}
      delete loading[id]
      depth--
      if (failed != "") {
        # An entry with spaces around it is the fault of this mod.info.
        if (list[i] == trim(list[i])) needs[id] = list[i]
        else delete needs[id]
        return failed
      }
      loaded[id] = ++loads
      order[loads] = id
      return ""
    }
    function loop_text(id,   k, text) {
      text = stack[1]
      for (k = 2; k <= depth; k++) text = text (k == 2 ? " requires " : ", which requires ") stack[k]
      if (loading[id] == depth) return text (depth == 1 ? " requires itself" : ", which requires itself")
      return text ", which requires " id
    }
    # What the game does with a mod it has a reason for, after "the game"; it = " it" or "".
    function verdict(id, it) {
      return "the game " how[id] it (how[id] == "does not load" ? " on " version : "") ": " reason[id]
    }
    # Why a mod does not load, to follow "which"
    function why(id) {
      if (id in needs) return "requires " needs[id] ", which " why(needs[id])
      if (id in reason) return verdict(id, "")
      return "neither a downloaded workshop item nor Zomboid/mods has"
    }
    # Warns about an entry no mod has, when it names one in a form the server reads differently:
    # Build 42 drops the backslash of <workshop id>\ModId, Build 41 keeps every backslash.
    function hint(entry, mod,   rest, cut) {
      if (b41) {
        rest = mod
        sub(/.*\\/, "", rest)
        if (rest == mod || !(rest in listed)) return 0
        warn("Mods= has " entry ", which Build 41 reads as the mod ID " mod ", backslash included; write " rest ".")
        return 1
      }
      match(mod, /^[0-9]+/)
      for (cut = RLENGTH; cut > 0; cut--) {
        rest = substr(mod, cut + 1)
        if (rest == "" || !(rest in listed)) continue
        warn("Mods= has " entry ", which the server reads as the mod ID " mod "; write \\" rest ".")
        return 1
      }
      return 0
    }
    function wrong_order(mod, other, text,   pair) {
      pair = mod < other ? mod SUBSEP other : other SUBSEP mod
      if (pair in reported) return
      reported[pair] = 1
      warn(text)
    }
    BEGIN { b41 = version != "" && version + 0 < 42 }
    { line[NR] = $0 }
    $5 == "" { next }
    { listed[$5] = 1 }
    # Per mod ID the first folder where the game finds it counts, whether or not it loads.
    ($4 == "1" || $4 == "0") && !($5 in state) {
      state[$5] = $4
      first[$5] = NR
      raw[$5] = $20
      after[$5] = $15
      before[$5] = $16
      incompatible[$5] = $17
      delete reason[$5]
      if ($19 != "") {
        reason[$5] = $19
        how[$5] = "skips"
      } else if ($4 == "0") {
        reason[$5] = "its mod.info sets" ($12 == "" ? "" : " versionMin=" $12) ($13 == "" ? "" : " versionMax=" $13)
        how[$5] = "does not load"
      }
      next
    }
    !($5 in state) && !($5 in reason) && $19 != "" {
      reason[$5] = $19
      how[$5] = $3 == "" ? "does not load" : "rejects"
    }
    END {
      n = split(ENVIRON["MODS"], entries, ";")
      for (e = 1; e <= n; e++) {
        entry = trim(entries[e])
        mod = entry
        if (!b41) gsub(/\\/, "", mod)
        mod = trim(mod)
        if (mod == "" || (mod in warned)) continue
        if (version == "") {
          if (!(mod in listed) && !hint(entry, mod) && check_missing) warn("Mods= enables " mod ", but neither a downloaded workshop item nor Zomboid/mods has it.")
          warned[mod] = 1
          continue
        }
        loop = ""
        if (load(mod) == "") continue
        warned[mod] = 1
        if (loop != "") {
          warn("Mods= enables " mod ", but " loop ", so the server never finishes loading mods and stops with a StackOverflowError.")
          continue
        }
        if (!(mod in listed) && hint(entry, mod)) continue
        for (root = mod; root in needs; root = needs[root]) {}
        if (!check_missing && !(root in reason)) continue
        if (mod in needs) warn("Mods= enables " mod ", but the game skips it: it requires " needs[mod] ", which " why(needs[mod]) ".")
        else if (mod in reason) warn("Mods= enables " mod ", but " verdict(mod, " it") ".")
        else warn("Mods= enables " mod ", but neither a downloaded workshop item nor Zomboid/mods has it.")
      }
      for (i = 1; i <= loads; i++) {
        mod = order[i]
        n = split(after[mod], list, ",")
        for (j = 1; j <= n; j++) {
          if ((list[j] in loaded) && loaded[list[j]] > i) wrong_order(mod, list[j], mod " loads before " list[j] ", but its mod.info says to load it after " list[j] ".")
        }
        n = split(before[mod], list, ",")
        for (j = 1; j <= n; j++) {
          if ((list[j] in loaded) && loaded[list[j]] < i) wrong_order(mod, list[j], mod " loads after " list[j] ", but its mod.info says to load it before " list[j] ".")
        }
        n = split(incompatible[mod], list, ",")
        for (j = 1; j <= n; j++) {
          other = list[j]
          if (!(other in loaded) || other == mod) continue
          pair = mod < other ? mod SUBSEP other : other SUBSEP mod
          if (pair in conflict) continue
          conflict[pair] = 1
          warn(mod " and " other " both load, but the mod.info of " mod " says they are incompatible.")
        }
      }
      for (i = 1; i <= loads; i++) {
        r = first[order[i]]
        printed[r] = 1
        print "load\t" line[r]
      }
      for (r = 1; r <= NR; r++) if (!(r in printed)) print "\t" line[r]
    }
  '
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

mod_maps() {
  # $1 = enabled or disabled, stdin = mod_info_rows output. Prints "$1\t<map name>\t<map dir>" for
  # each map of these mods.
  local dir map_dir
  mod_dirs | while IFS=$'\t' read -r _ _ _ dir; do
    for map_dir in "${dir}"/media/maps/*/; do
      map_dir="${map_dir%/}"
      # Mods that patch the vanilla map ship a folder with its name; it's always in Map= anyway.
      [ -d "${map_dir}" ] && [ "${map_dir##*/}" != "${VANILLA_MAP}" ] || continue
      printf '%s\t%s\t%s\n' "$1" "${map_dir##*/}" "${map_dir}"
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
  # The server trims the entries.
  mapfile -t entries < <(split_list "${current}")
  for name in "${entries[@]}"; do
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
  if [ "${vanilla}" = true ] || [ -z "${current//[[:space:]]/}" ]; then
    merged+=("${VANILLA_MAP}")
  fi
  (IFS=';'; printf '%s' "${merged[*]}")
}

write_spawn_regions() {
  # $1 = spawnregions file. Writes what the game writes when there is none (ServerOptions), the same
  # on Build 41 and 42, and the spawn points file its commented line names, unless that exists.
  local region points
  points="$(dirname "$1")/${SERVERNAME}_spawnpoints.lua"
  {
    printf 'function SpawnRegions()\n\treturn {\n'
    for region in "${VANILLA_MAP}" "West Point, KY" "Rosewood, KY" "Riverside, KY"; do
      printf '\t\t{ name = "%s", file = "media/maps/%s/spawnpoints.lua" },\n' "${region}" "${region}"
    done
    printf '\t\t-- Uncomment the line below to add a custom spawnpoint for this server.\n'
    printf -- '--\t\t{ name = "Twiggy'"'"'s Bar", serverfile = "%s_spawnpoints.lua" },\n' "${SERVERNAME}"
    printf '\t}\nend\n'
  } > "$1"
  [ -f "${points}" ] || {
    printf 'function SpawnPoints()\n\treturn {\n\t\tunemployed = {\n'
    printf '\t\t\t{ worldX = 40, worldY = 22, posX = 67, posY = 201 }\n'
    printf '\t\t}\n\t}\nend\n'
  } > "${points}"
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

# Adds the maps of the mods the server loads to Map= and their spawn points to the spawnregions
# file, and removes the maps of the other mods on disk, which the server can't load. Until every
# item in WorkshopItems is downloaded it only adds, since a mod may wait for an item it requires.
apply_mod_maps() {
  # $1 = INI file, $2 = spawnregions file, $3 = workshop content dir, $4 = what load_mods printed,
  # $5 = game version ("" when unknown)
  local ini_file="$1" spawn_file="$2" content_dir="$3" rows="$4" version="$5" maps current merged state name dir item complete=1
  local -a unread=()
  local -A workshop_items=()
  # The game version picks the version folders.
  [ -n "${version}" ] || return 0
  while IFS= read -r item; do
    workshop_items["${item}"]=1
    [ -d "${content_dir}/${item}" ] || complete=0
  done < <(split_list "$(ini_value "${ini_file}" WorkshopItems)")
  for dir in "${content_dir}"/*/mods; do
    item="${dir%/mods}"
    [ -n "${workshop_items[${item##*/}]+x}" ] || unread+=("${dir}")
  done
  maps="$(awk -F '\t' '$1 == "load"' <<< "${rows}" | cut -f 2- | mod_maps enabled
    if [ "${complete}" = 1 ]; then
      { awk -F '\t' '$1 == ""' <<< "${rows}" | cut -f 2-; mod_info_rows "${version}" "${unread[@]}"; } | mod_maps disabled
    fi)"
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
  [ "${merged}" = "${current}" ] || set_ini_value "${ini_file}" Map "${merged}"

  while IFS=$'\t' read -r state name dir; do
    if [ -n "${enabled_map[${name}]+x}" ]; then
      [ -f "${dir}/spawnpoints.lua" ] && add_spawn_region "${spawn_file}" "${name}"
    else
      remove_spawn_region "${spawn_file}" "${name}"
    fi
  done <<< "${maps}"
  return 0
}
