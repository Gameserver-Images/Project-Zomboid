#!/bin/bash
# Checks the maps in Map= the way the game loads them, which it doesn't log.

# The folders the game reads map files from, the one whose files win first (ZomboidFileSystem.loadMod,
# MapFiles): the mods that load, the last loaded first, each version folder before its common/, then
# the game's own.
map_roots() {
  # stdin = what load_mods printed. Prints the media/maps folder of each, its item and its mod as the
  # warnings name it; each mod in Zomboid/mods counts as an item of its own.
  local rows
  rows="$(awk -F '\t' '$1 == "load"' | cut -f 2-)"
  mod_dirs <<< "${rows}" | awk -F '\t' -v OFS='\t' '
      FNR == NR { id[$1 FS $2] = $5; next }
      $1 FS $2 != mod { mod = $1 FS $2; n++ }
      {
        workshop = $1 ~ /^[0-9]+$/
        print n, $3, $4 "/media/maps", (workshop ? $1 : $1 "/" $2), \
          id[$1 FS $2] " (" (workshop ? "workshop item " $1 : "Zomboid/mods/" $2) ")"
      }' <(printf '%s\n' "${rows}") - \
    | sort -t $'\t' -k1,1nr -k2,2n | cut -f 3-
  printf '%s\t\t\n' "${STEAMAPPDIR}/media/maps"
}

# True while the zone loader still builds its error messages and water zone bounds from x, y, z, width and
# height, which fails on a zone without them (Build 42's metazoneHandler.lua).
zone_loader_fails() {
  # $1 = metazoneHandler.lua
  grep -qF "'..v.x..','..v.y..','..v.z" "$1" && grep -qF 'v.x + v.width' "$1"
}

# Names the maps in Map= and warns about zones that stop the game's map zone loading and about maps of
# different items that share cells. Like apply_mod_maps, it needs the game version. Unlike the game, it
# matches map and file names case-sensitively, and takes a Map= without ";" as that one map, where the
# game adds the maps named in the lots= lines of its map.info.
check_maps() {
  # $1 = INI file, $2 = what load_mods printed, $3 = game version ("" when unknown)
  local ini_file="$1" version="$3" maps map item mod root dir handler="" i j line
  local -a roots=() items=() mods=() files=() sources=() table=() zone_files=(objects.lua regions.lua roomtones.lua)
  [ -n "${version}" ] || return 0
  maps="$(ini_value "${ini_file}" Map)"
  # The server loads the vanilla map for a blank Map=.
  [ -n "${maps//[[:space:]]/}" ] || maps="${VANILLA_MAP}"
  echo "Config: Map is ${maps}"
  while IFS=$'\t' read -r root item mod; do
    # The zone loader, which a mod can replace like any other game file
    [ -n "${handler}" ] || [ ! -f "${root%/maps}/lua/server/metazones/metazoneHandler.lua" ] \
      || handler="${root%/maps}/lua/server/metazones/metazoneHandler.lua"
    [ -d "${root}" ] || continue
    roots+=("${root}")
    items+=("${item}")
    mods+=("${mod}")
  done < <(map_roots <<< "$2")
  # Per entry of Map=, in the game's order (IsoMetaGrid.getLotDirectories): the map, the item and folder
  # the game reads it from, the zone files it reads for it ("" for none) and the mod each comes from.
  while IFS= read -r map; do
    item="" dir="" files=("" "" "") sources=("" "" "")
    for i in "${!roots[@]}"; do
      if [ -z "${dir}" ] && [ -d "${roots[i]}/${map}" ]; then
        item="${items[i]}"
        dir="${roots[i]}/${map}"
      fi
      for j in 0 1 2; do
        if [ -z "${files[j]}" ] && [ -f "${roots[i]}/${map}/${zone_files[j]}" ]; then
          files[j]="${roots[i]}/${map}/${zone_files[j]}"
          sources[j]="${mods[i]}"
        fi
      done
    done
    printf -v line '%s\t' "${map}" "${item}" "${dir}" "${files[@]}" "${sources[@]}"
    table+=("${line%$'\t'}")
  done < <(split_list "${maps}" | awk '!seen[$0]++')
  # The zone rules are those of Build 42's zone loader, as long as it still fails on these.
  if [ "${version%%.*}" -ge 42 ] && [ -n "${handler}" ] && zone_loader_fails "${handler}"; then
    printf '%s\n' "${table[@]}" | map_zone_warnings
  fi
  printf '%s\n' "${table[@]}" | map_overlap_warnings "${version}"
}

# The game loads the zones of the maps in Map= from the last map to the first, from each map's
# objects.lua, regions.lua and roomtones.lua, and stops at the first zone it fails on (doMapZones in
# media/lua/server/metazones/metazoneHandler.lua). It puts x, y and z of a water zone, water flow,
# mannequin or room tone without the properties it needs into an error message, and adds up x, y,
# width and height of a water zone with them, which fails on a missing one, as on a polygon. For an
# animal zone without geometry it calls a method that IsoWorld doesn't have, and Java fails on a
# Direction property other than N, NW, W, SW, S, SE, E or NE of a vehicle, parking stall or mannequin
# zone. Numbers missing where the game passes them to Java aren't counted (the boot test checks that
# this doesn't stop it), nor other errors in Java, such as an unknown geometry. WorldEd writes one zone
# per line. Only lines that hold a whole zone are read, after the line that sets the table the game
# takes the zones from. The game can't compile a file that starts with a UTF-8 byte order mark and
# reads none of its zones, so those files are skipped; other files Lua can't compile are read as they
# are.
zone_stops() {
  # stdin = paths of objects.lua, regions.lua and roomtones.lua files. Prints "<path>\t<line>" for each
  # file the game stops in, with the line of the zone it fails on.
  LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function text_of(value) { return value ~ /^\$[0-9]+$/ ? str[substr(value, 2) + 0] : "" }
    # The code of a line without comments, with each string replaced by $<n> and its text in str[n].
    # closing is the end of the long comment or string the next line starts in.
    function code(line,   out, t, i) {
      gsub(/\\./, "", line)
      split("", str)
      nstr = 0
      out = ""
      while (1) {
        if (closing != "") {
          if (!(i = index(line, closing))) return out
          line = substr(line, i + length(closing))
          closing = ""
          out = out " "
        }
        if (!match(line, token)) return out line
        out = out substr(line, 1, RSTART - 1)
        t = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (t == "--") {
          if (!match(line, /^\[=*\[/)) return out
          closing = substr(line, 1, RLENGTH)
          line = substr(line, RLENGTH + 1)
          gsub(/\[/, "]", closing)
        } else {
          gsub(/\[/, "]", t)
          if (!(i = index(line, t))) {
            if (t ~ /\]/) closing = t
            return out
          }
          str[++nstr] = substr(line, 1, i - 1)
          out = out "$" nstr
          line = substr(line, i + length(t))
        }
      }
    }
    # The fields of a Lua table that aren'"'"'t nil, from its code without nested tables
    function fields(text, into,   n, parts, i, key, value) {
      split("", into)
      n = split(text, parts, /[,;]/)
      for (i = 1; i <= n; i++) {
        if (match(parts[i], /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/)) key = trim(substr(parts[i], 1, RLENGTH - 1))
        else if (match(parts[i], /^[ \t]*\[[ \t]*\$[0-9]+[ \t]*\][ \t]*=/)) {
          key = substr(parts[i], 1, RLENGTH)
          gsub(/[^0-9]/, "", key)
          key = str[key + 0]
        } else continue
        value = trim(substr(parts[i], RLENGTH + 1))
        if (value == "nil") delete into[key]
        else into[key] = value
      }
    }
    # Reads the code of a line. Returns 1 when it holds a whole zone, with its fields in f, its type in
    # type and the fields of its properties table in p; props is 1 when it has one.
    function zone(line,   before, inner) {
      if (line !~ /^[ \t]*\{.*\}[ \t]*[,;]?[ \t]*$/) return 0
      sub(/^[ \t]*\{/, "", line)
      sub(/\}[ \t]*[,;]?[ \t]*$/, "", line)
      props = 0
      split("", p)
      while (match(line, /\{[^{}]*\}/)) {
        before = substr(line, 1, RSTART - 1)
        inner = substr(line, RSTART + 1, RLENGTH - 2)
        line = before "T" substr(line, RSTART + RLENGTH)
        if (before !~ /\{/ && before ~ /(^|[,;])[ \t]*properties[ \t]*=[ \t]*$/) {
          props = 1
          fields(inner, p)
        }
      }
      if (line ~ /[{}]/) return 0
      fields(line, f)
      type = text_of(f["type"])
      return 1
    }
    function has(key) { return key in f }
    function stops(file,   xyz) {
      xyz = has("x") && has("y") && has("z")
      if (file == "roomtones.lua") return type == "RoomTone" && !props && !xyz
      if ((type == "Vehicle" || type == "ParkingStall" || type == "Mannequin" && props) && ("Direction" in p) \
        && p["Direction"] ~ /^\$/ && !(text_of(p["Direction"]) in directions)) return 1
      if (type == "Mannequin") return !props && !xyz
      if (file == "regions.lua") return 0
      if (type == "Animal") return !has("geometry")
      if (type == "WaterFlow") return !(("WaterDirection" in p) && ("WaterSpeed" in p)) && !xyz
      if (type == "WaterZone") {
        if (("WaterGround" in p) && ("WaterShore" in p)) return !(has("x") && has("y") && has("width") && has("height"))
        return !xyz
      }
      return 0
    }
    BEGIN {
      token = "[\"\047]|--|\\[=*\\["
      split("N NW W SW S SE E NE", d, " ")
      for (i in d) directions[d[i]]
    }
    {
      path = $0
      file = path
      sub(/.*\//, "", file)
      global = file == "regions.lua" ? "regions" : "objects"
      closing = ""
      inside = 0
      n = 0
      while ((getline line < path) > 0) {
        if (++n == 1 && substr(line, 1, 3) == "\357\273\277") break
        sub(/\r$/, "", line)
        if (closing == "" && line !~ /Water|Mannequin|RoomTone|Animal|Vehicle|ParkingStall|objects|regions|\[/) continue
        line = code(line)
        if (!inside) inside = line ~ "^[ \t]*" global "[ \t]*="
        else if (zone(line) && stops(file)) {
          print path "\t" n
          break
        }
      }
      close(path)
    }
  '
}

# The spawn points of spawnpoints.lua files, in squares, as SpawnPoints.parsePoint reads them: worldX and
# worldY count cells of 300 squares on both builds, posX and posY squares within them, or squares of the
# world without them; posZ is the level, 0 when it is missing. Points are read from one-line tables, as
# the game and WorldEd write them; points named by position ("center") and points made by code aren't.
spawn_points() {
  # stdin = paths of spawnpoints.lua files. Prints "<path>\t<x>\t<y>\t<z>" for each point, once.
  LC_ALL=C awk '
    function num(t, key) {
      if (!match(t, "[^A-Za-z0-9_]" key "[ \t]*=[ \t]*-?[0-9]+(\\.[0-9]+)?")) return ""
      t = substr(t, RSTART, RLENGTH)
      sub(/^[^=]*=[ \t]*/, "", t)
      return t
    }
    {
      path = $0
      while ((getline line < path) > 0) {
        sub(/\r$/, "", line)
        sub(/--.*/, "", line)
        while (match(line, /\{[^{}]*\}/)) {
          t = " " substr(line, RSTART + 1, RLENGTH - 2) " "
          line = substr(line, RSTART + RLENGTH)
          px = num(t, "posX")
          py = num(t, "posY")
          if (px == "" || py == "") continue
          wx = num(t, "worldX")
          wy = num(t, "worldY")
          if (wx == "" && wy == "") {
            x = int(px)
            y = int(py)
          } else if (wx != "" && wy != "") {
            x = int(wx) * 300 + int(px)
            y = int(wy) * 300 + int(py)
          } else continue
          z = num(t, "posZ")
          z = z == "" ? 0 : int(z)
          if (!((path, x, y, z) in seen)) {
            seen[path, x, y, z]
            print path "\t" x "\t" y "\t" z
          }
        }
      }
      close(path)
    }
  '
}

ROOMS_READER=/usr/local/lib/read_spawn_rooms.jar

spawn_rooms() {
  # $1 = squares per cell (256 or 300), then map folders; stdin = points, "<x>\t<y>\t<z>". Prints the
  # buildings of the folders that hold the points, as read_spawn_rooms.jar does with the game's Java, or
  # fails with what it said. The JVM would announce the options in these variables on stderr.
  local why status=0
  { why="$(env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS -u _JAVA_OPTIONS \
    "${STEAMAPPDIR}/jre64/bin/java" -jar "${ROOMS_READER}" "$@" 2>&1 >&3)" || status=$?; } 3>&1
  [ "${status}" = 0 ] || printf '%s\n' "${why}" >&2
  return "${status}"
}

# Warns about the first map the game stops loading zones at, and the maps that lose their zones by it.
map_zone_warnings() {
  # stdin = per entry of Map=: map, item, folder, objects.lua, regions.lua, roomtones.lua and the mod
  # each of these comes from
  local table
  table="$(cat)"
  LC_ALL=C awk -F '\t' '
    # "a", "a and b", "a, b and c"
    function list(items, n,   i, s) {
      s = items[1]
      for (i = 2; i <= n; i++) s = s (i < n ? ", " : " and ") items[i]
      return s
    }
    FNR == NR {
      if ($0 != "") stop_line[$1] = $2
      next
    }
    {
      row[++rows] = $0
      name[rows] = $1
    }
    END {
      # In the order the game reads them, from the last map to the first: it stops at the first broken
      # map it reaches, and reaches the others once that one is fixed.
      for (m = rows; m >= 1; m--) {
        split(row[m], col, "\t")
        at = ""
        for (k = 4; k <= 6 && at == ""; k++) {
          if (col[k] == "" || !(col[k] in stop_line)) continue
          at = col[k] ":" stop_line[col[k]]
          if (col[k + 3] != "" && !(col[k + 3] in named)) {
            named[col[k + 3]]
            mods[++nm] = col[k + 3]
          }
        }
        if (at != "") {
          stop[++nb] = m
          where[nb] = at
        }
      }
      if (!nb) exit
      s = stop[1]
      text = "Warning: the game fails on the zone at " where[1] " and stops loading map zones there on every start.\n         So "
      if (s == 1) text = text name[s] " loses its zones from that line on."
      else {
        before = name[1]
        for (i = 2; i < s; i++) before = before ";" name[i]
        what = " (car spawns, animals, basements, water and the like)"
        text = text (s == rows ? "every other map loses its zones" what \
          : "the maps before " name[s] " in Map= lose their zones" what ": " before) ", and " name[s] " loses its own zones from that line on."
      }
      if (nb > 1) {
        text = text "\n         Once that zone is fixed, it stops at " where[2]
        for (i = 3; i <= nb; i++) text = text ", then at " where[i]
        text = text "."
      }
      n = 0
      if (nm) option[++n] = "remove the mod" (nm > 1 ? "s " : " ") list(mods, nm)
      option[++n] = "report " (nb > 1 ? "the zones to the maps\047 authors" : "the zone to the map\047s author")
      # With the broken maps first, the others keep their zones.
      if (s > nb) {
        for (i = 1; i <= nb; i++) moved[i] = name[stop[nb + 1 - i]]
        option[++n] = "set INI_Map to the Map= list above with " list(moved, nb) " moved to the front, so " \
          (nb > 1 ? "only those maps lose zones" : "it only loses its own zones from that line on")
      }
      text = text "\n         " toupper(substr(option[1], 1, 1)) substr(option[1], 2)
      for (i = 2; i <= n; i++) text = text (i < n ? ", " : n > 2 ? ", or " : " or ") option[i]
      print text "." > "/dev/stderr"
    }
  ' <(cut -f 4-6 <<< "${table}" | tr '\t' '\n' | sed '/^$/d' | LC_ALL=C sort -u | zone_stops; echo) <(printf '%s\n' "${table}")
}

# Where maps share a cell (<x>_<y>.lotheader), the game takes the cell from the map earlier in Map=.
# Build 42 then fills the squares it leaves empty from later maps and drops a later map's buildings
# only where an earlier one covers the whole area (IsoMetaGrid.CreateStep1 and consolidateBuildings,
# CellLoader.LoadCellBinaryChunk); Build 41 leaves out the later map's cell. Maps of one item aren't
# compared, as their author lays them out together.
map_overlap_warnings() {
  # $1 = game version, stdin = per entry of Map=: map, item, folder, ...
  local version="$1" table
  local -a dirs=()
  table="$(cat)"
  mapfile -t dirs < <(awk -F '\t' -v vanilla="${VANILLA_MAP}" '$3 != "" && $1 != vanilla { print $3 }' <<< "${table}")
  [ "${#dirs[@]}" -gt 1 ] || return 0
  find -L "${dirs[@]}" -maxdepth 1 -name '*.lotheader' -printf '%H\t%f\n' 2> /dev/null | LC_ALL=C sort -t $'\t' -k2,2 \
    | LC_ALL=C awk -F '\t' -v version="${version}" '
      BEGIN { b41 = version + 0 < 42 }
      FNR == NR {
        at[$3] = FNR
        name[FNR] = $1
        item[FNR] = $2
        n = FNR
        next
      }
      {
        m = at[$1]
        cell = $2
        sub(/\.lotheader$/, "", cell)
        if (cell != last) {
          seen = 0
          last = cell
        }
        for (j = 1; j <= seen; j++) {
          a = maps[j] < m ? maps[j] : m
          b = maps[j] < m ? m : maps[j]
          if (item[a] == item[b]) continue
          if (++shared[a, b] <= 3) cells[a, b] = cells[a, b] (shared[a, b] > 1 ? ", " : "") cell
        }
        maps[++seen] = m
      }
      END {
        for (a = 1; a <= n; a++) {
          for (b = a + 1; b <= n; b++) {
            if (!((a, b) in shared)) continue
            text = "Warning: the maps " name[a] " and " name[b] " share " shared[a, b] (shared[a, b] == 1 ? " cell" : " cells") \
              " (" cells[a, b] (shared[a, b] > 3 ? " and " shared[a, b] - 3 " more" : "") ").\n         " name[a] \
              " comes earlier in Map= (INI_Map), so "
            if (b41) print text "those cells are " name[a] "'"'"'s." > "/dev/stderr"
            else print text "where both have something on a square it wins, and " name[b] " loses its buildings only where " \
              name[a] " covers a whole cell." > "/dev/stderr"
          }
        }
      }
    ' <(printf '%s\n' "${table}") -
}
