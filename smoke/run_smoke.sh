#!/bin/bash
# Tests the startup scripts against fixture files and a stub server. Run: bash smoke/run_smoke.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${REPO}/scripts"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILED=0

fail() { echo "FAIL [${TEST}]: $*" >&2; FAILED=1; }
expect_line() {
  # $1 = file, $2 = exact line
  grep -qxF -- "$2" "$1" || fail "expected line '$2' in $(basename "$1")"
}
expect_eq() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

# Each test runs in a subshell with a fresh fake HOMEDIR/STEAMAPPDIR and no INI_/SANDBOX_ leftovers.
new_env() {
  rm -rf "${WORK:?}/home"
  export HOMEDIR="${WORK}/home" STEAMAPPDIR="${WORK}/home/pz-dedicated" SERVERNAME=pzserver
  # The tests check the LD_PRELOAD the scripts set.
  unset LD_PRELOAD
  SERVER="${HOMEDIR}/Zomboid/Server"
  mkdir -p "${SERVER}" "${STEAMAPPDIR}/media/lua/shared/Sandbox" "${HOMEDIR}/Zomboid/db"
  cp "${REPO}/smoke/fixtures/pzserver.ini" "${SERVER}/pzserver.ini"
  cp "${REPO}/smoke/fixtures/pzserver_SandboxVars.lua" "${SERVER}/pzserver_SandboxVars.lua"
  cp "${REPO}/smoke/fixtures/pzserver_spawnregions.lua" "${SERVER}/pzserver_spawnregions.lua"
  touch "${HOMEDIR}/Zomboid/db/pzserver.db"
  export STEAMAPPID=380870 STEAMCMDDIR="${WORK}/home/steamcmd"
  mkdir -p "${STEAMCMDDIR}"
  # Logs its arguments and installs a fake game with build FAKE_BUILD. Like the real one, its output
  # doesn't end with a newline.
  cat > "${STEAMCMDDIR}/steamcmd.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${HOMEDIR}/steamcmd-calls"
[ -n "${FAKE_STEAM_FAIL:-}" ] && { echo "ERROR! Failed to install app '380870' (No connection)"; exit 8; }
[ -n "${FAKE_STEAM_SILENT:-}" ] && exit 0
dir="$2"
mkdir -p "${dir}/steamapps"
[ -f "${dir}/start-server.sh" ] || printf '#!/bin/bash\n' > "${dir}/start-server.sh"
chmod +x "${dir}/start-server.sh"
printf '"AppState"\n{\n\t"appid"\t\t"380870"\n\t"buildid"\t\t"%s"\n}\n' "${FAKE_BUILD:-100}" > "${dir}/steamapps/appmanifest_380870.acf"
printf "Success! App '380870' fully installed.\nUnloading Steam API...OK"
EOF
  chmod +x "${STEAMCMDDIR}/steamcmd.sh"
  # shellcheck source=scripts/configure.sh
  . "${SCRIPT_DIR}/configure.sh"
  # shellcheck source=scripts/lib/game.sh
  . "${SCRIPT_DIR}/lib/game.sh"
}

test_ini() {
  TEST=ini
  new_env
  export INI_PublicName='My "best" server & co | $HOME \x' INI_public=TRUE INI_NewKey=1
  apply_ini_env "${SERVER}/pzserver.ini" > /dev/null 2> "${WORK}/err"
  expect_line "${SERVER}/pzserver.ini" 'PublicName=My "best" server & co | $HOME \x'
  expect_line "${SERVER}/pzserver.ini" 'Public=true'
  expect_line "${SERVER}/pzserver.ini" '# Players can hurt and kill other players'
  grep -q '^NewKey=' "${SERVER}/pzserver.ini" && fail "an unknown key was written to an existing INI"
  grep -q 'match no setting.*INI_NewKey' "${WORK}/err" || fail "unknown INI key was not reported"
  grep -q 'INI_public' "${WORK}/err" && fail "a known key in other case was reported unknown"
  (CONFIG_STRICT=true apply_ini_env "${SERVER}/pzserver.ini" > /dev/null 2>&1) && fail "CONFIG_STRICT did not stop on an unknown key"
  unset INI_NewKey

  INI_PVP=1 apply_ini_env "${SERVER}/pzserver.ini" > /dev/null 2> "${WORK}/err"
  expect_line "${SERVER}/pzserver.ini" 'PVP=true'
  grep -q 'need true or false.*INI_PVP' "${WORK}/err" || fail "a non-boolean value for a boolean key was not reported"

  # On the first start the INI is empty, so nothing can be checked yet and every key is appended.
  : > "${SERVER}/pzserver.ini"
  (INI_NewKey=1 CONFIG_STRICT=true apply_ini_env "${SERVER}/pzserver.ini" > /dev/null 2> "${WORK}/err") || fail "first start failed in strict mode"
  expect_line "${SERVER}/pzserver.ini" 'NewKey=1'
  [ -s "${WORK}/err" ] && fail "first start reported unknown keys"
}

test_sandbox() {
  TEST=sandbox
  new_env
  export SANDBOX_Zombies=2 SANDBOX_ZombieLore__Transmission=3 SANDBOX_zombielore__mortality=7 \
    SANDBOX_Map__MapAllKnown=TRUE SANDBOX_WorldItemRemovalList='Base.Hat, "Base.Glasses"' SANDBOX_Nope__Key=1
  apply_sandbox_env "${SERVER}/pzserver_SandboxVars.lua" 2> "${WORK}/err"
  local lua="${SERVER}/pzserver_SandboxVars.lua"
  expect_line "${lua}" '    Zombies = 2,'
  expect_line "${lua}" '        Transmission = 3,'
  expect_line "${lua}" '        Mortality = 7,'
  expect_line "${lua}" '        MapAllKnown = true,'
  expect_line "${lua}" '    WorldItemRemovalList = "Base.Hat, \"Base.Glasses\"",'
  expect_line "${lua}" '    -- Default = Normal'
  grep -q 'match no setting.*SANDBOX_Nope__Key' "${WORK}/err" || fail "unknown sandbox path was not reported"
  (CONFIG_STRICT=true apply_sandbox_env "${lua}" 2>/dev/null) && fail "CONFIG_STRICT did not stop on an unknown path"
  unset SANDBOX_Nope__Key

  # A value of the wrong type would break the Lua file or the setting, so the old line stays.
  SANDBOX_Zombies=lots SANDBOX_Map__MapAllKnown=1 apply_sandbox_env "${lua}" 2> "${WORK}/err"
  expect_line "${lua}" '    Zombies = 2,'
  expect_line "${lua}" '        MapAllKnown = true,'
  grep -q 'same type.*SANDBOX_Map__MapAllKnown SANDBOX_Zombies' "${WORK}/err" || fail "wrong value types were not reported"

  rm "${lua}"
  apply_sandbox_env "${lua}" 2> "${WORK}/err"
  grep -q 'apply from the next start' "${WORK}/err" || fail "missing SandboxVars file was not reported"
}

test_preset() {
  TEST=preset
  new_env
  printf 'return {\r\n    Zombies = 4,\r\n}\r\n' > "${STEAMAPPDIR}/media/lua/shared/Sandbox/Apocalypse.lua"
  rm "${SERVER}/pzserver_SandboxVars.lua"
  SERVERPRESET=Apocalypse apply_preset "${SERVER}/pzserver_SandboxVars.lua" >/dev/null
  expect_line "${SERVER}/pzserver_SandboxVars.lua" 'SandboxVars = {'
  expect_line "${SERVER}/pzserver_SandboxVars.lua" '    Zombies = 4,'
  (SERVERPRESET=Missing apply_preset "${SERVER}/pzserver_SandboxVars.lua" 2> "${WORK}/err") && fail "a missing preset did not stop the start"
  grep -q 'Available presets: Apocalypse' "${WORK}/err" || fail "available presets were not listed"
}

make_mod() {
  # $1 = workshop item, $2 = mod folder, $3 = mod id, $4 = path of the version folder ("" for B41), $5.. = maps
  local item="$1" mod="$2" id="$3" version="$4"
  shift 4
  local base="${STEAMAPPDIR}/steamapps/workshop/content/108600/${item}/mods/${mod}"
  mkdir -p "${base}/${version}"
  printf 'name=%s\r\nid=%s\r\n' "${mod}" "${id}" > "${base}/${version}/mod.info"
  for map in "$@"; do
    mkdir -p "${base}/${version:-.}/media/maps/${map}"
    [ "${map}" = "Raven Creek" ] && touch "${base}/${version:-.}/media/maps/${map}/spawnpoints.lua"
  done
}

test_maps() {
  TEST=maps
  new_env
  local content="${STEAMAPPDIR}/steamapps/workshop/content/108600" ini="${SERVER}/pzserver.ini" spawn="${SERVER}/pzserver_spawnregions.lua"
  # As on a start: what load_mods makes of Mods= decides the maps.
  maps() { apply_mod_maps "${ini}" "${spawn}" "${content}" "$(load_mods "${ini}" "${content}" "$(console_game_version)" 2> "${WORK}/err")" > /dev/null; }
  make_mod 100 RavenCreek RavenCreekMod 42 "Raven Creek"
  make_mod 200 Bedford BedfordFalls 42 "Bedford Falls"
  make_mod 300 Unused UnusedMod 42 "Unused Map"
  make_mod 400 Patch VanillaPatch 42 "Muldraugh, KY"
  mkdir -p "${content}/100/mods/RavenCreek/common/media/maps/Raven Creek Extra"
  # Build 41 files and a version folder newer than the game don't load on 42.21.
  make_mod 500 Old41 Old41Mod "" "B41 Map"
  make_mod 600 Multi MultiMod 42 "Older Map"
  make_mod 600 Multi MultiMod 42.21 "New Map"
  make_mod 600 Multi MultiMod 42.22 "Future Map"
  # The mod ID comes from the version folder that loads, not from the mod folder itself.
  make_mod 700 Renamed OldId "" "Renamed Map"
  make_mod 700 Renamed NewId 42 "Renamed Map"
  set_ini_value "${ini}" WorkshopItems '100;200;300;400;500;600;700'
  set_ini_value "${ini}" Mods '\RavenCreekMod;BedfordFalls;\VanillaPatch;\Old41Mod;\MultiMod;\NewId'
  set_ini_value "${ini}" Map 'Admin Map;Unused Map;Muldraugh, KY'

  # Before the first start the game version, and with it the version folders, is unknown.
  maps
  expect_line "${ini}" 'Map=Admin Map;Unused Map;Muldraugh, KY'
  grep -q 'Raven Creek' "${spawn}" && fail "spawnregions changed without a game version"

  echo 'LOG  : General     , 1727000000000> versionNumber=42.21.0 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  maps
  expect_line "${ini}" 'Map=Admin Map;Raven Creek;Raven Creek Extra;Bedford Falls;New Map;Renamed Map;Muldraugh, KY'
  expect_line "${spawn}" '		{ name = "Raven Creek", file = "media/maps/Raven Creek/spawnpoints.lua" },'

  # A second start changes nothing.
  cp "${ini}" "${WORK}/ini.before"
  cp "${spawn}" "${WORK}/spawn.before"
  maps
  cmp -s "${ini}" "${WORK}/ini.before" || fail "the Map line changed on the second start"
  cmp -s "${spawn}" "${WORK}/spawn.before" || fail "spawnregions changed on the second start"

  # Disabling a mod takes its maps and spawn points out again.
  set_ini_value "${ini}" Mods '\BedfordFalls'
  maps
  expect_line "${ini}" 'Map=Admin Map;Bedford Falls;Muldraugh, KY'
  grep -q 'Raven Creek' "${spawn}" && fail "the spawn region of a disabled mod was kept"
  expect_line "${spawn}" '		{ name = "Muldraugh, KY", file = "media/maps/Muldraugh, KY/spawnpoints.lua" },'

  # The server drops every backslash, so this is the mod ID 2392709985BedfordFalls, which no item has.
  set_ini_value "${ini}" Mods '2392709985\BedfordFalls'
  maps
  expect_line "${ini}" 'Map=Admin Map;Muldraugh, KY'

  # The server trims the lines of an INI with Windows line ends.
  set_ini_value "${ini}" Mods '\RavenCreekMod;\BedfordFalls'
  set_ini_value "${ini}" Map 'Bedford Falls;Muldraugh, KY'
  sed -i 's/$/\r/' "${ini}"
  maps
  expect_line "${ini}" 'Map=Bedford Falls;Raven Creek;Raven Creek Extra;Muldraugh, KY'
  [ -s "${WORK}/err" ] && fail "warned about an INI with Windows line ends: $(cat "${WORK}/err")"
  sed -i 's/\r$//' "${ini}"

  # A mod that an enabled one requires loads with it, maps included, also from Zomboid/mods. Of two
  # items with a mod ID, the first in WorkshopItems has it, even when its copy doesn't load there.
  # The server doesn't see an item that isn't in WorkshopItems.
  printf '%s\n' 'id=Hub' 'require=\LocalMod' | mod_file 800/mods/Hub/42/mod.info
  mkdir -p "${HOMEDIR}/Zomboid/mods/Local/42/media/maps/Local Map"
  printf '%s\n' 'id=LocalMod' > "${HOMEDIR}/Zomboid/mods/Local/42/mod.info"
  make_mod 810 Copy CopyMod 42 "Second Copy"
  make_mod 820 Copy CopyMod 42 "First Copy"
  printf '%s\n' 'id=CopyMod' 'versionMax=42.20' | mod_file 820/mods/Copy/42/mod.info
  make_mod 900 Unseen UnseenMod 42 "Unseen Map"
  set_ini_value "${ini}" WorkshopItems '100;800;820;810'
  set_ini_value "${ini}" Mods '\Hub;\CopyMod;\UnseenMod'
  set_ini_value "${ini}" Map 'Admin Map;Unseen Map;Second Copy;Muldraugh, KY'
  maps
  expect_line "${ini}" 'Map=Admin Map;Local Map;Muldraugh, KY'
  set_ini_value "${ini}" WorkshopItems '100;800;810;820'
  maps
  expect_line "${ini}" 'Map=Admin Map;Local Map;Second Copy;Muldraugh, KY'

  # A map mod that doesn't load on this game version loses its maps and spawn points, enabled or not.
  # An empty versionMax= line leaves the one before.
  make_mod 830 Checkpoint SZ_Checkpoint6 42.0 "SZ Checkpoint"
  printf '%s\n' 'id=SZ_Checkpoint6' 'versionMin=42.0' 'versionMax=42.20' 'versionMax=' | mod_file 830/mods/Checkpoint/42.0/mod.info
  touch "${content}/830/mods/Checkpoint/42.0/media/maps/SZ Checkpoint/spawnpoints.lua"
  add_spawn_region "${spawn}" "SZ Checkpoint" >/dev/null
  set_ini_value "${ini}" WorkshopItems '830'
  set_ini_value "${ini}" Mods '\SZ_Checkpoint6'
  set_ini_value "${ini}" Map 'SZ Checkpoint;Local Map;Muldraugh, KY'
  maps
  expect_line "${ini}" 'Map=Muldraugh, KY'
  grep -q 'SZ Checkpoint' "${spawn}" && fail "the spawn region of a mod that doesn't load was kept"

  # While an item in WorkshopItems is still downloading, maps are only added, since a mod may wait for
  # it, like this one for a mod in item 850. Once the item is there, maps leave Map= again.
  printf '%s\n' 'id=WaitMod' 'require=\WaitBase,\LaterLib' | mod_file 840/mods/Wait/42/mod.info
  mkdir -p "${content}/840/mods/Wait/42/media/maps/Wait Map"
  touch "${content}/840/mods/Wait/42/media/maps/Wait Map/spawnpoints.lua"
  make_mod 840 Base WaitBase 42 "Base Map"
  make_mod 840 Ready ReadyMod 42 "Ready Map"
  add_spawn_region "${spawn}" "Wait Map" >/dev/null
  set_ini_value "${ini}" WorkshopItems '840;850'
  set_ini_value "${ini}" Mods '\WaitMod;\LaterLib;\ReadyMod'
  set_ini_value "${ini}" Map 'Wait Map;Base Map;Muldraugh, KY'
  maps
  expect_line "${ini}" 'Map=Wait Map;Base Map;Ready Map;Muldraugh, KY'
  grep -q 'Wait Map' "${spawn}" || fail "a spawn region was removed while an item was downloading"
  [ -s "${WORK}/err" ] && fail "warned about a mod waiting for a download: $(cat "${WORK}/err")"
  mkdir -p "${content}/850/mods"
  set_ini_value "${ini}" Mods '\WaitMod;\LaterLib'
  maps
  expect_line "${ini}" 'Map=Muldraugh, KY'
  grep -q 'Wait Map' "${spawn}" && fail "the spawn region of a mod that doesn't load was kept"

  # Build 41 loads the mod folder itself, and keeps backslashes in Mods=.
  echo 'LOG  : General     , 1700000000000> version=41.78.16 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  set_ini_value "${ini}" WorkshopItems '100;500'
  set_ini_value "${ini}" Mods '\Old41Mod'
  maps
  expect_line "${ini}" 'Map=Muldraugh, KY'
  set_ini_value "${ini}" Mods 'Old41Mod;RavenCreekMod'
  maps
  expect_line "${ini}" 'Map=B41 Map;Muldraugh, KY'

  expect_eq "$(merge_map_list "" "" "A")" "A;Muldraugh, KY"
  expect_eq "$(merge_map_list "B;Muldraugh, KY;B" "" "A")" "B;A;Muldraugh, KY"
  expect_eq "$(merge_map_list "B;C;Muldraugh, KY" "C;D" "A")" "B;A;Muldraugh, KY"
}

test_workshop() {
  TEST=workshop
  new_env
  fake_steam
  local content="${STEAMAPPDIR}/steamapps/workshop/content/108600"
  apply() { PATH="${WORK}/bin:${PATH}" apply_workshop_ids "${SERVER}/pzserver.ini" "${content}" > /dev/null 2> "${WORK}/err"; }
  # 900 holds items 101, 102 and 103 (in nested collections, one of them empty); 104 is hidden, and
  # the server stops with an error on an item it can't download.
  WORKSHOP_IDS=' 900;;104; ' apply
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems=101;102;103'
  grep -q "left out of WorkshopItems: 104$" "${WORK}/err" || fail "the hidden item was not reported"
  WORKSHOP_IDS=' ; ' apply
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems='
  WORKSHOP_IDS='104' apply
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems='
  # Only result 9 means the item is gone; other failures can pass.
  WORKSHOP_IDS='107' apply
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems=107'
  # A hidden item the server downloaded before still loads from that copy.
  make_mod 104 Hidden HiddenMod 42
  WORKSHOP_IDS='900;104' apply
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems=101;102;103;104'
  grep -q "keeps the copy it downloaded.*: 104$" "${WORK}/err" || fail "the kept hidden item was not reported"
  rm -rf "${content}/104"
  PATH="${WORK}/bin:${PATH}" bash "${SCRIPT_DIR}/resolve_workshop_collection.sh" --tree '900;104' > "${WORK}/out"
  expect_eq "$(jq -s -c 'map({id, children: (.children // [] | map(.id + (if .collection then "c" else "" end)))})' "${WORK}/out")" \
    '[{"id":"900","children":["101","910c","102"]},{"id":"104","children":[]},{"id":"910","children":["103","920c"]},{"id":"920","children":[]}]'
  jq -e -s '.[1].children == null and .[3].children == []' "${WORK}/out" > /dev/null || fail "--tree did not tell items from empty collections"
  set_ini_value "${SERVER}/pzserver.ini" WorkshopItems 105
  FAKE_STEAM_DOWN=1 WORKSHOP_IDS='900' apply
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems=105'
  # An answer that leaves an item out says nothing about it.
  FAKE_STEAM_PARTIAL=104 WORKSHOP_IDS='900;104' apply
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems=105'
  grep -q "could not check the workshop items" "${WORK}/err" || fail "the incomplete answer was not reported"
}

mod_file() {
  # $1 = path in the workshop content dir; the content comes from stdin
  local file="${STEAMAPPDIR}/steamapps/workshop/content/108600/$1"
  mkdir -p "$(dirname "${file}")"
  cat > "${file}"
}

fake_steam() {
  # A fake Steam API on PATH that logs "<API> <ID count>" per call. 900 is a collection holding item
  # 101, collection 910 (item 103 and the empty collection 920) and item 102. Item 104 is hidden, and
  # Steam fails to answer for item 107 (result 2).
  # With the key "secret", item 101 requires item 102.
  mkdir -p "${WORK}/bin"
  cat > "${WORK}/bin/curl" <<'CURL'
#!/bin/bash
ids=()
count=
declare -A index=()
for arg in "$@"; do
  case "${arg}" in
    publishedfileids\[*\]=*) i="${arg#*[}"; index[${i%%]*}]=1; ids+=("${arg#*=}") ;;
    itemcount=* | collectioncount=*) count="${arg#*=}" ;;
    https://*) url="${arg}" ;;
  esac
done
url="${url%/v1/}"
printf '%s %s\n' "${url##*/}" "${#ids[@]}" >> "${HOMEDIR}/steam-calls"
[ -n "${FAKE_STEAM_DOWN:-}" ] && exit 6
# Like Steam, refuse a request without publishedfileids[0..n-1] or, but for GetDetails, without a count of n.
for ((i = 0; i < ${#ids[@]}; i++)); do
  [ -n "${index[$i]:-}" ] || exit 22
done
[[ "${url}" == */GetDetails || "${count}" == "${#ids[@]}" ]] || exit 22
ids="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s -c .)"
case "${url}" in
  */GetCollectionDetails)
    jq -n -c --argjson ids "${ids}" '
      {"900": [["101", 0], ["910", 2], ["102", 0]], "910": [["103", 0], ["920", 2]], "920": []} as $collections
      | {response: {collectiondetails: [$ids[] | if $collections[.] then
          {publishedfileid: ., result: 1, children: [$collections[.][] | {publishedfileid: .[0], filetype: .[1]}]}
        else {publishedfileid: ., result: 9} end]}}' ;;
  */GetPublishedFileDetails)
    [ -n "${FAKE_STEAM_PARTIAL:-}" ] && ids="$(jq -c --arg drop "${FAKE_STEAM_PARTIAL}" 'map(select(. != $drop))' <<< "${ids}")"
    jq -n -c --argjson ids "${ids}" '{response: {publishedfiledetails: [$ids[] | if . == "104" then {publishedfileid: ., result: 9}
      elif . == "107" then {publishedfileid: ., result: 2} else
      {publishedfileid: ., result: 1, title: "Item \(.)", description: "[b]About \(.)[/b]", tags: [{tag: "Build 42"}],
       time_updated: 1700000000, file_size: "4096"} end]}}' ;;
  */GetDetails)
    [[ "$*" == *"key=secret"* ]] || exit 22
    jq -n -c --argjson ids "${ids}" '{response: {publishedfiledetails: [$ids[] | {publishedfileid: ., result: 1}
      + if . == "101" then {children: [{publishedfileid: "102", sortorder: 1, file_type: 0}]} else {} end]}}' ;;
esac
CURL
  chmod +x "${WORK}/bin/curl"
}

test_list_mods() {
  TEST=list-mods
  new_env
  fake_steam
  local out="${WORK}/mods.json" multi="101/mods/Multi Version"
  echo 'LOG  : General     , 1727000000000> versionNumber=42.21.0 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  # Item 101 has a Build 41 mod.info, Build 42 versions up to one newer than the game, a folder that is
  # no version, and a second mod. Item 102 only has Build 41 and a folder that is no version, items 106
  # and 108 are on disk only, and 106 has 42.0 and 42.5, which is older than 42.21.
  printf '%s\r\n' 'name=Multi B41' 'id=MultiMod' 'modversion=41' | mod_file "${multi}/mod.info"
  printf '%s\r\n' 'name=Multi 42' 'id=MultiMod' 'modversion=42' | mod_file "${multi}/42/mod.info"
  printf '%s\r\n' 'name=Multi 42.5' 'id=MultiMod' 'modversion=42.5' | mod_file "${multi}/42.5/mod.info"
  printf '%s\r\n' 'name=Multi 42.22' 'id=MultiMod' 'modversion=42.22' | mod_file "${multi}/42.22/mod.info"
  printf '%s\r\n' 'name=Multi backup' 'id=MultiMod' 'modversion=backup' | mod_file "${multi}/backup/mod.info"
  # The game matches keys exactly, drops every backslash in lists and splits them on commas.
  printf '%s\r\n' 'Name = Ignored' 'name=Multi 42.21' 'id=MultiMod' 'modversion=42.21' 'authors=Ignored' 'author=Someone' \
    'url=https://example.com' 'Require=Ignored' 'require=\StarlitLibrary,2392709985\TsarLib,PlainReq,' 'loadModAfter=AfterMe' \
    'loadModBefore=\BeforeOne,\BeforeTwo' 'incompatible=\Enemy,' 'versionMin=42.21' | mod_file "${multi}/42.21/mod.info"
  mod_file "${multi}/42.21/media/sandbox-options.txt" <<'EOF'
VERSION = 1,
option Multi.Mode
{
	type = enum, numValues = 3,
	default = 1,
	page = Multi,
	translation = Multi_Mode,
	valueTranslation = Multi_Modes,
}
option Multi.Strength
{
	type = integer,
	min = -5,
	max = 50,
	default = 10,
	page = Multi,
	translation = Multi_Strength,
}
/*
option Multi.Old
{
	type = boolean,
	default = true,
}
*/ option Multi.Shared { type = double, /* was 2 */ min = 0, max = 5, default = 1.5, }
option Multi.Separator
{
	translation = Multi_Separator,
}
option MultiNoDot
{
	type = boolean,
	default = true,
}
EOF
  printf '%s\r\n' 'option Multi.Shared' '{' '  type = double,' '  default = 9,' '}' 'option Multi.CommonOnly' '{' '  type = string,' \
    '  default = Base.Axe;Base.Saw,' '  page = Elsewhere,' '}' | mod_file "${multi}/common/media/sandbox-options.txt"
  printf '\357\273\277{\n  "Sandbox_Multi": "Multi settings",\n  "Sandbox_Multi_Mode": "Mode",\n  "Sandbox_Multi_Modes_option1": "Easy",\n  "Sandbox_Multi_Modes_option3": "Hard",\n  "Sandbox_Multi_Strength_tooltip": "How strong"\n}\n' \
    | mod_file "${multi}/common/media/lua/shared/Translate/EN/Sandbox.json"
  mkdir -p "${STEAMAPPDIR}/steamapps/workshop/content/108600/${multi}/"{42.21/media/maps/Variant\ Map,common/media/maps/Common\ Map,common/media/maps/Muldraugh\,\ KY,42/media/maps/Old\ Map}
  # A byte order mark hides the id= line from the game.
  printf '\357\273\277id=MultiAddon\r\nname=Addon\r\n' | mod_file 101/mods/Addon/42/mod.info
  printf '%s\r\n' 'VERSION = 1,' 'option Addon.Flag' '{' 'type = boolean,' 'default = false,' 'translation = Addon_Flag,' '}' \
    'option Addon.Mode' '{' 'type = enum, numValues = 2,' 'default = 1,' 'valueTranslation = Addon_Modes,' '}' | mod_file 101/mods/Addon/42/media/sandbox-options.txt
  printf '%s\n' 'Sandbox_EN = {' '    Sandbox_Addon_Flag = "The \"best\" flag", -- why' '}' | mod_file 101/mods/Addon/42/media/lua/shared/Translate/EN/Sandbox_EN.txt
  make_mod 102 "Old Mod" OldMod "" "Old Map"
  make_mod 102 "Old Mod" OldMod backup
  make_mod 104 Hidden HiddenMod 42
  printf '%s\n' 'VERSION = 1,' 'option Hidden.X' '{' 'type = integer,' 'min = 0,' 'max = 9,' 'default = 3,' 'translation = Hidden_X,' '}' | mod_file 104/mods/Hidden/42/media/sandbox-options.txt
  echo '{"Sandbox_Hidden_X": "X",}' | mod_file 104/mods/Hidden/42/media/lua/shared/Translate/EN/Sandbox.json
  make_mod 106 Loose LooseMod 42.0
  make_mod 106 Loose LooseMod 42.5
  # The game reads only the version folder's sandbox options when it has some. An option's id is the
  # word after "option", keys and types match exactly, the first value of a key counts, each type needs
  # its values (ints within Java's range), and a value is only what ends at a comma. It skips the character after a closing brace, so after "}," it reads a block
  # of type "," and stops.
  mod_file 106/mods/Loose/42.5/media/sandbox-options.txt <<'EOF'
VERSION = 1,
option Loose.Spaced = {
	type = boolean, default = true,
}
option Loose.Key { Type = boolean, default = true, }
option Loose.Cased { type = Boolean, default = true, }
option Loose.NoMax { type = integer, min = 0, default = 1, }
option Loose.Big { type = integer, min = 0, max = 99999999999, default = 1, }
option Loose.Twice { type = boolean, default = true, default = false, }
option Loose.Word { type = double, min = 0, max = 1, default = half, }
option Loose.NoValues { type = enum, numValues = 0, default = 1, }
option Loose.Last { type = string, default = a }
option Loose.Number { type = double, min = -1, max = 1e3, default = .5, }
option Loose.Str { type = string, default = a b , page = P,}, option Loose.Skipped { type = boolean, default = true, }
option Loose.After { type = boolean, default = true, }
EOF
  printf '%s\n' 'VERSION = 1,' 'option Loose.Common' '{' 'type = boolean,' 'default = true,' '}' | mod_file 106/mods/Loose/common/media/sandbox-options.txt
  make_mod 106 "No Version" NoVersionMod 42
  printf '%s\n' 'option NoVersion.X' '{' 'type = boolean,' 'default = true,' '}' | mod_file "106/mods/No Version/42/media/sandbox-options.txt"
  # A mod.info without an id still brings its maps and options.
  make_mod 106 "No Id" "" 42 "No Id Map"
  printf '%s\n' 'VERSION = 1,' 'option NoId.X' '{' 'type = integer,' 'min = 0,' 'max = 9,' 'default = 3,' '}' | mod_file "106/mods/No Id/common/media/sandbox-options.txt"
  # The game rejects these, or can't load them by themselves, so their options don't count. Their maps
  # do: the page takes them out of Map=.
  make_mod 108 Bad BadMod 42 "Bad Map"
  printf '%s\n' 'id=BadMod' 'versionMin=42' | mod_file 108/mods/Bad/42/mod.info
  make_mod 108 Spaces SpacesMod 42 "Spaces Map"
  printf '%s\n' 'id=SpacesMod' 'require=\A, \B' | mod_file 108/mods/Spaces/42/mod.info
  make_mod 108 Capped CappedMod 42 "Capped Map"
  printf '%s\n' 'id=CappedMod' 'versionMax=42.20' | mod_file 108/mods/Capped/42/mod.info
  printf '%s\n' 'VERSION = 1,' 'option Capped.X' '{' 'type = boolean,' 'default = true,' '}' | mod_file 108/mods/Capped/42/media/sandbox-options.txt
  make_mod 108 examplemod ExampleMod 42
  set_ini_value "${SERVER}/pzserver.ini" Mods '\MultiMod;2392709985\TsarLib; \OldMod;'
  set_ini_value "${SERVER}/pzserver.ini" Map 'Variant Map;Muldraugh, KY'
  set_ini_value "${SERVER}/pzserver.ini" WorkshopItems '101;102;105'
  cat > "${SERVER}/pzserver_SandboxVars.lua" <<'EOF'
SandboxVars = {
    Zombies = 4,
    Multi = {
        Mode = 2,
        CommonOnly = "a \"b\"",
    },
    MultiNoDot = false,
}
EOF

  (PATH="${WORK}/bin:${PATH}" WORKSHOP_IDS=' 900;;104 ' bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" 2> "${WORK}/err") || { fail "list-mods failed"; cat "${WORK}/err" >&2; return; }
  jq -e '.format == 2 and .gameVersion == "42.21.0" and .workshopIds == ["900", "104"]' "${out}" > /dev/null || fail "wrong header"
  expect_eq "$(jq -c .server "${out}")" '{"mods":["\\MultiMod","2392709985\\TsarLib","\\OldMod"],"map":["Variant Map","Muldraugh, KY"],"workshopItems":["101","102","105"]}'
  expect_eq "$(jq -c .collections "${out}")" '[{"id":"900","title":"Item 900","children":["101","910","102"]},{"id":"910","title":"Item 910","children":["103","920"]},{"id":"920","title":"Item 920","children":[]}]'
  expect_eq "$(jq -c '[.items[] | [.id, .available, .downloaded, (.mods | map(.folder))]]' "${out}")" \
    '[["101",true,true,["Addon","Multi Version"]],["102",true,true,["Old Mod"]],["103",true,false,[]],["104",false,true,["Hidden"]],["105",true,false,[]],["106",true,true,["Loose","No Id","No Version"]],["108",true,true,["Bad","Capped","Spaces"]]]'
  expect_eq "$(jq -c '.items[0] | [.title, .description, .tags, .updated, .size, .requiredItems]' "${out}")" '["Item 101","[b]About 101[/b]",["Build 42"],1700000000,4096,null]'
  expect_eq "$(jq -c '.items[3] | [.title, .description, .tags, .updated, .size]' "${out}")" '[null,null,null,null,null]'
  expect_eq "$(jq -c '.items[3].mods[0].sandbox | map([.env, .label])' "${out}")" '[["SANDBOX_Hidden__X",null]]'
  expect_eq "$(jq -c '.items[0].mods[1] | del(.sandbox)' "${out}")" \
    '{"id":"MultiMod","folder":"Multi Version","versionFolder":"42.21","name":"Multi 42.21","description":null,"author":"Someone","modVersion":"42.21","url":"https://example.com","category":null,"versionMin":"42.21","versionMax":null,"error":null,"require":["StarlitLibrary","2392709985TsarLib","PlainReq"],"requireEntries":["StarlitLibrary","2392709985TsarLib","PlainReq"],"loadModAfter":["AfterMe"],"loadModBefore":["BeforeOne","BeforeTwo"],"incompatible":["Enemy"],"maps":["Common Map","Variant Map"]}'
  expect_eq "$(jq -c '.items[0].mods[1].sandbox | map([.env, .type, .default, .current])' "${out}")" \
    '[["SANDBOX_Multi__Mode","enum","1","2"],["SANDBOX_Multi__Strength","integer","10",null],["SANDBOX_Multi__Shared","double","1.5",null],["SANDBOX_MultiNoDot","boolean","true","false"]]'
  expect_eq "$(jq -c '.items[0].mods[1].sandbox[0:2]' "${out}")" \
    '[{"env":"SANDBOX_Multi__Mode","option":"Multi.Mode","type":"enum","default":"1","min":null,"max":null,"values":["Easy","2","Hard"],"page":"Multi","pageLabel":"Multi settings","label":"Mode","tooltip":null,"current":"2"},{"env":"SANDBOX_Multi__Strength","option":"Multi.Strength","type":"integer","default":"10","min":"-5","max":"50","values":null,"page":"Multi","pageLabel":"Multi settings","label":null,"tooltip":"How strong","current":null}]'
  expect_eq "$(jq -c '.items[0].mods[0] | [.id, .versionFolder, .sandbox[0].label, .sandbox[0].values, .sandbox[1].values]' "${out}")" '[null,"42","The \"best\" flag",null,null]'
  expect_eq "$(jq -c '.items[1].mods[0] | [.id, .name, .versionFolder, .error, .maps, .sandbox]' "${out}")" '["OldMod","Old Mod",null,"no mod.info for this game version",[],[]]'
  expect_eq "$(jq -c '.items[6].mods | map([.id, .versionFolder, .error, .require, .requireEntries, .maps, (.sandbox | length)])' "${out}")" \
    '[["BadMod","42","its mod.info has versionMin=42, which is not a major.minor version like 42.13",[],[],["Bad Map"],0],["CappedMod","42",null,[],[],["Capped Map"],0],["SpacesMod","42",null,["A","B"],["A"," B"],["Spaces Map"],0]]'
  expect_eq "$(jq -c '.items[5].mods[0] | [.versionFolder, (.sandbox | map([.option, .type, .default, .min, .max, .page]))]' "${out}")" \
    '["42.5",[["Loose.Spaced","boolean","true",null,null,null],["Loose.Twice","boolean","true",null,null,null],["Loose.Number","double",".5","-1","1e3",null],["Loose.Str","string","a b",null,null,"P"]]]'
  expect_eq "$(jq -c '.items[5].mods[2].sandbox' "${out}")" '[]'
  expect_eq "$(jq -c '.items[5].mods[1] | [.id, .versionFolder, .maps, [.sandbox[].env]]' "${out}")" '[null,"42",["No Id Map"],["SANDBOX_NoId__X"]]'
  [ -s "${WORK}/err" ] && fail "list-mods wrote to stderr: $(cat "${WORK}/err")"

  # Each collection is looked up once, also when it is given twice.
  rm "${HOMEDIR}/steam-calls"
  PATH="${WORK}/bin:${PATH}" bash "${SCRIPT_DIR}/resolve_workshop_collection.sh" --tree '900;;900' > /dev/null || fail "the resolver failed on an empty entry"
  expect_eq "$(paste -sd ' ' "${HOMEDIR}/steam-calls")" "GetCollectionDetails 1 GetCollectionDetails 1 GetCollectionDetails 1"
  expect_eq "$(PATH="${WORK}/bin:${PATH}" WORKSHOP_IDS='900;900' bash "${SCRIPT_DIR}/list_mods.sh" | jq -c '[.collections[].id]')" '["900","910","920"]'

  # Required items need a key, and the API takes at most 100 IDs per call.
  rm "${HOMEDIR}/steam-calls"
  set_ini_value "${SERVER}/pzserver.ini" WorkshopItems "$(seq -s ';' 1000 1150)"
  PATH="${WORK}/bin:${PATH}" STEAM_API_KEY=secret bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" || fail "list-mods failed with a key"
  expect_eq "$(jq -c '[.items[] | select(.id | length == 3) | .requiredItems]' "${out}")" '[["102"],[],[],[],[]]'
  expect_eq "$(jq -c '[.items[].id] | length' "${out}")" 156
  expect_eq "$(paste -sd ' ' "${HOMEDIR}/steam-calls")" "GetPublishedFileDetails 100 GetPublishedFileDetails 56 GetDetails 100 GetDetails 56"
  (PATH="${WORK}/bin:${PATH}" STEAM_API_KEY=wrong bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" 2> "${WORK}/err") && fail "list-mods succeeded with a wrong key"
  [ -s "${out}" ] && fail "list-mods printed output with a wrong key"
  grep -q '^Error: .*STEAM_API_KEY' "${WORK}/err" || fail "the wrong key was not explained"
  (PATH="${WORK}/bin:${PATH}" FAKE_STEAM_PARTIAL=1000 bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" 2> /dev/null) && fail "list-mods succeeded with an incomplete first batch"

  # Build 41 loads the mod.info in the mod folder itself.
  echo 'LOG  : General     , 1700000000000> version=41.78.16 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  PATH="${WORK}/bin:${PATH}" bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" || fail "list-mods failed on Build 41"
  expect_eq "$(jq -c '[.gameVersion, (.items[] | select(.id | length == 3) | .mods[] | [.folder, .versionFolder, .modVersion, .maps])]' "${out}")" \
    '["41.78.16",["Addon",null,null,[]],["Multi Version","",null,[]],["Old Mod","",null,["Old Map"]],["Hidden",null,null,[]],["Loose",null,null,[]],["No Id",null,null,[]],["No Version",null,null,[]],["Bad",null,null,[]],["Capped",null,null,[]],["Spaces",null,null,[]]]'

  # Nothing to look up needs no network.
  set_ini_value "${SERVER}/pzserver.ini" WorkshopItems ''
  rm -rf "${STEAMAPPDIR}/steamapps/workshop" "${HOMEDIR}/steam-calls"
  PATH="${WORK}/bin:${PATH}" bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" || fail "list-mods failed without items"
  jq -e '.items == [] and .collections == [] and .workshopIds == []' "${out}" > /dev/null || fail "list-mods without items printed $(cat "${out}")"
  [ -f "${HOMEDIR}/steam-calls" ] && fail "list-mods called the Steam API without items"

  (PATH="${WORK}/bin:${PATH}" FAKE_STEAM_DOWN=1 WORKSHOP_IDS=900 bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" 2> "${WORK}/err") && fail "list-mods succeeded without the Steam API"
  [ -s "${out}" ] && fail "list-mods printed output without the Steam API"
  grep -q '^Error: could not resolve WORKSHOP_IDS' "${WORK}/err" || fail "the Steam API failure was not explained"
  set_ini_value "${SERVER}/pzserver.ini" WorkshopItems 101
  (PATH="${WORK}/bin:${PATH}" FAKE_STEAM_DOWN=1 bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" 2> "${WORK}/err") && fail "list-mods succeeded without the item details"
  [ -s "${out}" ] && fail "list-mods printed output without the item details"
  grep -q '^Error: could not get the workshop item details' "${WORK}/err" || fail "the details failure was not explained"

  rm "${HOMEDIR}/Zomboid/server-console.txt"
  (PATH="${WORK}/bin:${PATH}" bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" 2> "${WORK}/err") && fail "list-mods succeeded without a game version"
  grep -q 'Start the server once first' "${WORK}/err" || fail "the unknown game version was not explained"
}

test_mod_folders() {
  TEST=folders
  new_env
  local mods="${WORK}/item/mods"
  mod_info() { mkdir -p "${mods}/$1"; printf '%s\n' "${@:2}" > "${mods}/$1/mod.info"; }
  rows() { mod_info_rows "$1" "${mods}" | awk -F '\t' -v OFS='\t' '{ print $2, $3, $4, $5, $14, $19, $20 }' | sort; }
  row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
  # Version folders without a mod.info still count; the game then reads common/mod.info.
  mkdir -p "${mods}/Lib/42" "${mods}/Lib/42.13" "${mods}/Lib/42.17"
  mod_info Lib/common 'id=Lib' 'versionMin=42.0.0'
  mod_info Lib 'id=Lib' 'require=OldLib'
  # Only common/ (and an old Build 41 mod.info).
  mod_info Cargo/common 'id=Cargo' 'versionMin=42.15.0'
  mod_info Cargo 'id=Cargo'
  # The newest version folder has no mod.info and neither has common/, so the game sees no mod.
  mod_info Broken/42 'id=Broken'
  mkdir -p "${mods}/Broken/42.13" "${mods}/Broken/common"
  # Version folders compare by major.minor only, a versionMin above the game or a versionMax below it
  # stops a mod, and one the game can't parse makes it reject the mod.info. Parsing numbers, Java
  # trims them and takes one too big for an int as 0.
  mod_info Patch/42.21.5 'id=Patch'
  mod_info Patch/42.13 'id=PatchOld'
  mod_info 'Spaced/ 42.13' 'id=Spaced'
  mod_info Spaced/42.12 'id=SpacedOld'
  mod_info Capped/42 'id=Capped' 'versionMin=42.0' 'versionMax=42.20.9'
  mod_info Future/42 'id=Future' 'versionMin=42.22'
  mod_info Edge/42 'id=Edge' 'versionMax=42.21'
  mod_info Huge/42 'id=Huge' 'versionMin=42.99999999999'
  mod_info Ranged/42 'id=Ranged' 'versionMin=42.21.7' 'versionMax=42'
  mod_info Minor/42 'id=Minor' 'versionMin=42.1000'
  # An empty value leaves the one before, and the game checks the versions before the require entries.
  mod_info Bound/42 'id=Bound' 'versionMax=42.20' 'versionMax=' 'versionMin= '
  mod_info OldEmpty/42 'id=OldEmpty' 'versionMax=42.13' 'require='
  # A mod the game doesn't see is named by the mod.info of common/, its newest version folder, or itself.
  mod_info Gone 'id=OldGone'
  mod_info Gone/42.25 'id=GoneMid'
  mod_info Gone/42.30 'id=Gone'
  # Lists split on commas only. The game checks the trimmed require entries, but loads them as
  # written, and Java's split drops empty entries only at the end.
  mod_info Semi/42 'id=Semi' 'require=\A;\B,C,'
  mod_info Spaces/42 'id=Spaces' 'require=\A, \B'
  mod_info Empty/42 'id=Empty' 'require='
  mod_info Gap/42 'id=Gap' 'require=\A,,\B'
  # An empty pack=, one with type= but no space, and a tiledef= without a name and a number from 100
  # to 8189 make the game reject the mod.info; Build 41 allows numbers up to 16382.
  mod_info Pack/42 'id=Pack' 'pack= '
  mod_info Typed/42 'id=Typed' 'pack=tiles;type=ui'
  mod_info Packs/42 'id=Packs' 'pack=tiles type=ui' 'tiledef=tiles 8189'
  mod_info Tiles/42 'id=Tiles' 'tiledef=tiles 9000'
  mod_info Tiles 'id=Tiles' 'tiledef=tiles 9000'
  mod_info Tiny/42 'id=Tiny' 'tiledef=tiles 99'
  mod_info Three/42 'id=Three' 'tiledef=tiles 100 more'
  mod_info Plus/42 'id=Plus' 'tiledef=tiles +150'
  mod_info TwoBad/42 'id=TwoBad' 'pack=' 'tiledef=tiles 5'
  # Java's readLine also ends lines at a lone \r, and keeps a byte order mark, which hides the first key.
  mkdir -p "${mods}/Cr/42" "${mods}/Bom/42"
  printf 'id=Cr\rversionMax=42.20\r' > "${mods}/Cr/42/mod.info"
  printf '\357\273\277versionMin=42.22\nid=Bom\n' > "${mods}/Bom/42/mod.info"
  # The game skips folders named examplemod and follows symbolic links.
  mod_info ExampleMod/42 'id=Example'
  mkdir -p "${WORK}/elsewhere/Linked/42"
  printf '%s\n' 'id=Linked' > "${WORK}/elsewhere/Linked/42/mod.info"
  ln -s "${WORK}/elsewhere/Linked" "${mods}/Linked"
  # The game reads on past a loop of symbolic links.
  ln -s . "${mods}/Lib/self"
  mod_info_rows 42.21.0 "${mods}" > "${WORK}/rows" 2> "${WORK}/err" || fail "mod_info_rows failed on a loop of links"
  [ -s "${WORK}/err" ] && fail "mod_info_rows wrote to stderr: $(cat "${WORK}/err")"
  expect_eq "$(awk -F '\t' 'NF != 20' "${WORK}/rows")" ''
  local bad='which is not a major.minor version like 42.13' tiles='which needs a file name and a number from 100 to 8189'
  expect_eq "$(rows 42.21.0)" "$({
    row Bom 42 1 Bom '' '' ''
    row Bound 42 0 Bound '' '' ''
    row Broken '' - Broken '' 'no mod.info for this game version' ''
    row Capped 42 0 Capped '' '' ''
    row Cargo common 1 Cargo '' '' ''
    row Cr 42 0 Cr '' '' ''
    row Edge 42 1 Edge '' '' ''
    row Empty 42 0 Empty '' 'its require= has an empty entry' ','
    row Future 42 0 Future '' '' ''
    row Gap 42 0 Gap 'A,B' 'its require= has an empty entry' 'A,,B,'
    row Gone '' - Gone '' 'no mod.info for this game version' ''
    row Huge 42 1 Huge '' '' ''
    row Lib 42.17 1 Lib '' '' ''
    row Linked 42 1 Linked '' '' ''
    row Minor 42 - Minor '' "its mod.info has versionMin=42.1000, ${bad}" ''
    row OldEmpty 42 0 OldEmpty '' '' ','
    row Pack 42 - Pack '' 'its mod.info has an empty pack= line' ''
    row Packs 42 1 Packs '' '' ''
    row Patch 42.21.5 1 Patch '' '' ''
    row Plus 42 1 Plus '' '' ''
    row Ranged 42 - Ranged '' "its mod.info has versionMax=42, ${bad}" ''
    row Semi 42 1 Semi 'A;B,C' '' 'A;B,C,'
    row Spaced ' 42.13' 1 Spaced '' '' ''
    row Spaces 42 1 Spaces 'A,B' 'its require= has spaces around B' 'A, B,'
    row Three 42 - Three '' "its mod.info has tiledef=tiles 100 more, ${tiles}" ''
    row Tiles 42 - Tiles '' "its mod.info has tiledef=tiles 9000, ${tiles}" ''
    row Tiny 42 - Tiny '' "its mod.info has tiledef=tiles 99, ${tiles}" ''
    row TwoBad 42 - TwoBad '' 'its mod.info has an empty pack= line' ''
    row Typed 42 - Typed '' 'its mod.info has pack=tiles;type=ui, which needs a space before type=' ''
  } | sort)"
  # Build 41 reads the mod folder itself, and the folder name is the ID until an id= line, which keeps
  # its spaces. Any other mod.info is read with the Build 42 rules.
  mod_info Old 'name=Old mod' 'require=\Lib, Cargo'
  mod_info Spacey 'id= Spacey '
  mod_info New/common 'id=New' 'author=Someone' 'require=\Lib'
  mod_info Packed41 'pack= '
  mod_info Desc 'description=Needs require=Other'
  expect_eq "$(mod_info_rows 41.78.16 "${mods}" | awk -F '\t' '$2 ~ /^(Old|Lib|Tiles|Spacey|New|Packed41|Desc)$/ { print $2 "|" $3 "|" $4 "|" $5 "|" $8 "|" $14 "|" $19 }' | sort)" \
    "$(printf '%s\n' 'Desc|.|1|Desc|||' 'Lib|.|1|Lib||OldLib|' 'New||-|New|Someone|Lib|no mod.info for this game version' \
      'Old|.|1|Old||\Lib,Cargo|its require= has spaces around Cargo' 'Packed41|.|-|Packed41|||its mod.info has an empty pack= line' \
      'Spacey|.|1| Spacey |||' 'Tiles|.|1|Tiles|||')"
  # Without a game version nothing is known to load.
  expect_eq "$(mod_info_rows '' "${mods}" | cut -f4 | sort -u)" '?'
}

test_mod_warnings() {
  TEST=warnings
  new_env
  local ini="${SERVER}/pzserver.ini" content="${STEAMAPPDIR}/steamapps/workshop/content/108600"
  echo 'LOG  : General     , 1727000000000> versionNumber=42.21.0 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  printf '%s\r\n' 'id=ModA' 'require=\ModB' 'loadModAfter=ModC,\ModB' 'incompatible=\ModD' | mod_file 201/mods/A/42/mod.info
  make_mod 202 B ModB 42
  # The hint for 2392709985\ModB takes the longest run of digits as the workshop ID.
  make_mod 202 B5 5ModB 42
  printf '%s\n' 'id=ModC' 'loadModBefore=\ModE,\ModA' | mod_file 203/mods/C/42.21/mod.info
  printf '%s\n' 'id=ModD' 'incompatible=ModA' | mod_file 204/mods/D/42/mod.info
  make_mod 205 E ModE 42
  printf '%s\n' 'id=ModF' 'require=\ModMissing,ModMissing' | mod_file 206/mods/F/42/mod.info
  # Not loaded on 42.21, so its mod.info doesn't count.
  printf '%s\n' 'id=ModG' 'require=ModMissing' | mod_file 207/mods/G/42.30/mod.info
  # Mods placed by hand in Zomboid/mods, for Build 42 and for Build 41.
  mkdir -p "${HOMEDIR}/Zomboid/mods/My Local/42" "${HOMEDIR}/Zomboid/mods/Old Local"
  printf '%s\r\n' 'id=ModLocal' 'require=\ModB' > "${HOMEDIR}/Zomboid/mods/My Local/42/mod.info"
  printf '%s\r\n' 'id=ModLocal41' > "${HOMEDIR}/Zomboid/mods/Old Local/mod.info"
  printf '%s\n' 'id=ModH' 'versionMin=42.0' 'versionMax=42.20.9' | mod_file 208/mods/H/common/mod.info
  warnings() { load_mods "${ini}" "${content}" "$(console_game_version)" > /dev/null 2> "${WORK}/err"; }
  loaded() { load_mods "${ini}" "${content}" 42.21.0 2> "${WORK}/err" | awk -F '\t' '$1 == "load" { print $6 }' | paste -sd ' '; }
  local stops='so the server never finishes loading mods and stops with a StackOverflowError'

  set_ini_value "${ini}" WorkshopItems '201;202;203;204;205;206;207;208'
  set_ini_value "${ini}" Mods '\ModB;\ModC;\ModA;\ModE;\ModLocal;\examplemod'
  warnings
  [ -s "${WORK}/err" ] && fail "warned about mods in order: $(cat "${WORK}/err")"

  # The game doesn't load these on 42.21: no mod.info for it, or a version range it is outside of.
  set_ini_value "${ini}" Mods '\ModG;\ModLocal41;\ModH'
  warnings
  expect_eq "$(cat "${WORK}/err")" 'Warning: Mods= enables ModG, but the game does not load it on 42.21.0: no mod.info for this game version.
Warning: Mods= enables ModLocal41, but the game does not load it on 42.21.0: no mod.info for this game version.
Warning: Mods= enables ModH, but the game does not load it on 42.21.0: its mod.info sets versionMin=42.0 versionMax=42.20.9.'

  # Each problem once, also for mods listed twice and for a pair of mods whose mod.info files both
  # want another order. The server loads ModB for ModA, in front of it, and takes 2392709985\ModB for
  # the mod ID 2392709985ModB.
  set_ini_value "${ini}" Mods '\ModA;2392709985\ModB;\ModE;\ModC;\ModD;\ModF;\Ghost;\ModA;\ModF;\Ghost;\ModLocal'
  warnings
  expect_line "${WORK}/err" 'Warning: Mods= has 2392709985\ModB, which the server reads as the mod ID 2392709985ModB; write \ModB.'
  expect_line "${WORK}/err" 'Warning: Mods= enables ModF, but the game skips it: it requires ModMissing, which neither a downloaded workshop item nor Zomboid/mods has.'
  expect_line "${WORK}/err" 'Warning: Mods= enables Ghost, but neither a downloaded workshop item nor Zomboid/mods has it.'
  expect_line "${WORK}/err" 'Warning: ModA loads before ModC, but its mod.info says to load it after ModC.'
  expect_line "${WORK}/err" 'Warning: ModC loads after ModE, but its mod.info says to load it before ModE.'
  expect_line "${WORK}/err" 'Warning: ModA and ModD both load, but the mod.info of ModA says they are incompatible.'
  expect_eq "$(wc -l < "${WORK}/err")" 6
  expect_eq "$(loaded)" 'ModB ModA ModE ModC ModD ModLocal'

  # Items download while the server starts, so a new item's mods may not be there yet.
  set_ini_value "${ini}" WorkshopItems '201;202;203;204;205;206;207;208;299'
  warnings
  grep -q 'Ghost\|ModMissing' "${WORK}/err" && fail "missing mods were reported while an item was not downloaded"
  expect_eq "$(wc -l < "${WORK}/err")" 4

  # A required mod that doesn't load stops the mods that require it, all the way up. An empty require
  # entry stops the mod, and one with spaces around it stops it after the entries before it loaded. A
  # mod that requires itself, directly or not, stops the server.
  printf '%s\n' 'id=ModP' 'require=\ModQ' | mod_file 210/mods/P/42/mod.info
  printf '%s\n' 'id=ModQ' 'require=\ModF' | mod_file 210/mods/Q/42/mod.info
  printf '%s\n' 'id=ModR' 'require=\ModH' | mod_file 210/mods/R/42/mod.info
  printf '%s\n' 'id=ModS' 'require=\ModB, \ModE' | mod_file 210/mods/S/42/mod.info
  printf '%s\n' 'id=ModT' 'require=\ModC,,\ModE' | mod_file 210/mods/T/42/mod.info
  printf '%s\n' 'id=ModU' 'require=\ModU' | mod_file 210/mods/U/42/mod.info
  printf '%s\n' 'id=ModV' 'require=\ModW' | mod_file 210/mods/V/42/mod.info
  printf '%s\n' 'id=ModW' 'require=\ModV' | mod_file 210/mods/W/42/mod.info
  printf '%s\n' 'id=ModY' 'require=\ModE,\ModMissing' | mod_file 210/mods/Y/42/mod.info
  printf '%s\n' 'id=ModZ' 'require=\ModU' | mod_file 210/mods/Z/42/mod.info
  # Outside its version window, the game doesn't get to the require entries.
  printf '%s\n' 'id=ModO' 'versionMax=42.13' 'require=\ModB, \ModE' | mod_file 210/mods/O/42/mod.info
  set_ini_value "${ini}" WorkshopItems '201;202;203;204;205;206;207;208;210'
  set_ini_value "${ini}" Mods '\ModY;\ModP;\ModR;\ModS;\ModT;\ModO;\ModZ;\ModU;\ModV'
  expect_eq "$(loaded)" 'ModB'
  expect_eq "$(cat "${WORK}/err")" "Warning: Mods= enables ModY, but the game skips it: it requires ModMissing, which neither a downloaded workshop item nor Zomboid/mods has.
Warning: Mods= enables ModP, but the game skips it: it requires ModQ, which requires ModF, which requires ModMissing, which neither a downloaded workshop item nor Zomboid/mods has.
Warning: Mods= enables ModR, but the game skips it: it requires ModH, which the game does not load on 42.21.0: its mod.info sets versionMin=42.0 versionMax=42.20.9.
Warning: Mods= enables ModS, but the game skips it: its require= has spaces around ModE.
Warning: Mods= enables ModT, but the game skips it: its require= has an empty entry.
Warning: Mods= enables ModO, but the game does not load it on 42.21.0: its mod.info sets versionMax=42.13.
Warning: Mods= enables ModZ, but ModZ requires ModU, which requires itself, ${stops}.
Warning: Mods= enables ModU, but ModU requires itself, ${stops}.
Warning: Mods= enables ModV, but ModV requires ModW, which requires ModV, ${stops}."
  # While an item is missing, problems of the mods that are there are still reported.
  set_ini_value "${ini}" WorkshopItems '201;202;203;204;205;206;207;208;210;299'
  warnings
  expect_eq "$(grep -o 'enables [A-Za-z]*' "${WORK}/err" | paste -sd ' ')" 'enables ModR enables ModS enables ModT enables ModO enables ModZ enables ModU enables ModV'

  # A mod the game rejects, also as a requirement. Of two rejected copies, the first one's reason counts.
  printf '%s\n' 'id=ModK' 'pack=' | mod_file 211/mods/K/42/mod.info
  printf '%s\n' 'id=ModJ' 'require=\ModK' | mod_file 211/mods/J/42/mod.info
  printf '%s\n' 'id=ModK' 'versionMin=B42' | mod_file 212/mods/K/42/mod.info
  set_ini_value "${ini}" WorkshopItems '211;212'
  set_ini_value "${ini}" Mods '\ModK;\ModJ'
  warnings
  expect_eq "$(cat "${WORK}/err")" 'Warning: Mods= enables ModK, but the game rejects it: its mod.info has an empty pack= line.
Warning: Mods= enables ModJ, but the game skips it: it requires ModK, which the game rejects: its mod.info has an empty pack= line.'

  # Of two items with a mod ID, the first in WorkshopItems has it, also when its copy doesn't load. One
  # without a mod.info for this version doesn't count.
  printf '%s\n' 'id=ModX' 'require=\Dep' | mod_file 301/mods/X/42/mod.info
  printf '%s\n' 'id=ModX' | mod_file 302/mods/X/42/mod.info
  printf '%s\n' 'id=ModX' | mod_file 303/mods/X/42.30/mod.info
  set_ini_value "${ini}" Mods '\ModX;301\ModX'
  set_ini_value "${ini}" WorkshopItems '303;301;302'
  warnings
  expect_eq "$(cat "${WORK}/err")" 'Warning: Mods= enables ModX, but the game skips it: it requires Dep, which neither a downloaded workshop item nor Zomboid/mods has.
Warning: Mods= has 301\ModX, which the server reads as the mod ID 301ModX; write \ModX.'
  set_ini_value "${ini}" WorkshopItems '303;302;301'
  set_ini_value "${ini}" Mods '\ModX'
  warnings
  [ -s "${WORK}/err" ] && fail "warned about the copy of a mod that the game doesn't use: $(cat "${WORK}/err")"

  # Build 41 keeps the backslashes in Mods=.
  echo 'LOG  : General     , 1700000000000> version=41.78.16 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  set_ini_value "${ini}" Mods '\ModLocal41;ModLocal41;\Ghost'
  warnings
  expect_eq "$(cat "${WORK}/err")" 'Warning: Mods= has \ModLocal41, which Build 41 reads as the mod ID \ModLocal41, backslash included; write ModLocal41.
Warning: Mods= enables \Ghost, but neither a downloaded workshop item nor Zomboid/mods has it.'

  # Without the game version the version folder is unknown, so only missing mods are reported, and
  # only once every item is downloaded.
  set_ini_value "${ini}" WorkshopItems '201;202;203;204;205;206;207'
  set_ini_value "${ini}" Mods '\ModA;2392709985\ModB;\ModE;\ModC;\ModD;\ModF;\Ghost;\ModA;\ModLocal'
  rm "${HOMEDIR}/Zomboid/server-console.txt"
  warnings
  expect_eq "$(cat "${WORK}/err")" 'Warning: Mods= has 2392709985\ModB, which the server reads as the mod ID 2392709985ModB; write \ModB.
Warning: Mods= enables Ghost, but neither a downloaded workshop item nor Zomboid/mods has it.'
  set_ini_value "${ini}" WorkshopItems '201;299'
  set_ini_value "${ini}" Mods '\ModA;\Ghost'
  warnings
  [ -s "${WORK}/err" ] && fail "warned before every item was downloaded: $(cat "${WORK}/err")"
}

test_file_watcher() {
  TEST=watcher
  new_env
  local ini="${SERVER}/pzserver.ini" content="${STEAMAPPDIR}/steamapps/workshop/content/108600" limit="${WORK}/limit"
  local shim=/usr/local/lib/no_file_watcher.so
  watcher() {
    # $1 = inotify watch limit; prints the LD_PRELOAD the game gets
    printf '%s\n' "$1" > "${limit}"
    (configure_file_watcher "${limit}" "${ini}" "${content}" "$(load_mods "${ini}" "${content}" "$(console_game_version)" 2> /dev/null)" \
      > "${WORK}/out" 2> "${WORK}/err"; printf '%s' "${LD_PRELOAD:-}")
  }
  quiet() {
    # $1 = why the last watcher should have printed nothing
    [ ! -s "${WORK}/out" ] && [ ! -s "${WORK}/err" ] || fail "$1: $(cat "${WORK}/out" "${WORK}/err")"
  }
  # Here the game's media folder holds media, lua, shared and Sandbox, and a link the game doesn't follow.
  mkdir -p "${HOMEDIR}/Zomboid/messaging"
  ln -s "${STEAMAPPDIR}/media/lua" "${STEAMAPPDIR}/media/linked"
  echo 'LOG  : General     , 1727000000000> versionNumber=42.21.0 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  make_mod 100 RavenCreek RavenCreekMod 42 "Raven Creek"
  mkdir -p "${content}/100/mods/RavenCreek/common/media/lua/client"
  mkdir -p "${HOMEDIR}/Zomboid/mods/Local/42/media/lua"
  printf 'id=LocalMod\n' > "${HOMEDIR}/Zomboid/mods/Local/42/mod.info"
  # A version folder newer than the game, a mod without a mod.info for it, an item outside
  # WorkshopItems and one without a mods folder don't count.
  mkdir -p "${content}/100/mods/RavenCreek/42.22/media/scripts" "${content}/300"
  make_mod 100 Old41 Old41Mod "" "B41 Map"
  make_mod 200 Unseen UnseenMod 42 "Unseen Map"
  set_ini_value "${ini}" WorkshopItems '100;300;100'
  rows() { load_mods "${ini}" "${content}" "$1" 2> /dev/null; }

  # Mod folders are only read once Mods= names a mod, whether or not it loads: then Zomboid/mods, the
  # mods folder of item 100, two mod folders, 42/media and common/media of RavenCreek (3 each) and
  # 42/media of Local (2) come on top, once however often WorkshopItems lists the item.
  set_ini_value "${ini}" Mods ''
  expect_eq "$(watched_dirs "${ini}" "${content}" "$(rows 42.21.0)")" 5
  set_ini_value "${ini}" Mods '\Ghost'
  expect_eq "$(watched_dirs "${ini}" "${content}" "$(rows 42.21.0)")" 17

  # The game gets at most half of the limit.
  expect_eq "$(watcher 34)" ''
  quiet "said something although the game fits"
  expect_eq "$(GAME_FILE_WATCHER='' watcher 34)" ''
  expect_eq "$(GAME_FILE_WATCHER=AUTO watcher 34)" ''
  expect_eq "$(watcher 33)" "${shim}"
  [ -s "${WORK}/out" ] && fail "printed more than the warning: $(cat "${WORK}/out")"
  expect_eq "$(cat "${WORK}/err")" "Warning: the game would watch 17 folders for file changes, more than half of the 33 inotify watches per user that the host allows (fs.inotify.max_user_watches).
         Every program of the container's user on the host shares that limit, and running out stops the server while it starts.
         So the game's file watcher is off for this start; it only reloads game and mod files that change while the server runs.
         To keep it on, raise the limit on the Docker host, not in the container:
           sudo sysctl -w fs.inotify.max_user_watches=524288
           echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/90-inotify.conf
         GAME_FILE_WATCHER=false turns it off without this warning."
  expect_eq "$(LD_PRELOAD=/other.so; watcher 33)" "${shim}:/other.so"
  # The suggested limit leaves the game half of it.
  (watched_dirs() { echo 300000; }; watcher 100 > /dev/null)
  expect_eq "$(grep -o 'max_user_watches=[0-9]*' "${WORK}/err" | sort -u)" 'max_user_watches=1048576'

  # Mods of workshop items still to download, and all mods while the game version is unknown, can't
  # be counted, so the watcher is off for that start unless the rest is too much already.
  set_ini_value "${ini}" WorkshopItems '100;300;400'
  expect_eq "$(watcher 34)" "${shim}"
  expect_eq "$(cat "${WORK}/out")" "Config: the game's file watcher is off for this start, as its mod folders can't be counted before every workshop item is downloaded and the game version is known"
  [ -s "${WORK}/err" ] && fail "warned about mods it can't count: $(cat "${WORK}/err")"
  expect_eq "$(watcher 33)" "${shim}"
  grep -q '^Warning: the game would watch 17 folders' "${WORK}/err" || fail "the folders it could count did not get the warning"
  [ -s "${WORK}/out" ] && fail "printed more than the warning: $(cat "${WORK}/out")"
  set_ini_value "${ini}" WorkshopItems '100;300'
  rm "${HOMEDIR}/Zomboid/server-console.txt"
  expect_eq "$(watcher 1000)" "${shim}"
  grep -q "^Config: the game's file watcher is off" "${WORK}/out" || fail "the unknown game version did not turn the watcher off"
  set_ini_value "${ini}" Mods ''
  expect_eq "$(watcher 1000)" ''
  set_ini_value "${ini}" Mods '\Ghost'

  expect_eq "$(GAME_FILE_WATCHER=true watcher 1)" ''
  quiet "said something although GAME_FILE_WATCHER is true"
  expect_eq "$(GAME_FILE_WATCHER=on watcher 1)" ''
  expect_eq "$(GAME_FILE_WATCHER=false watcher 1000000)" "${shim}"
  expect_eq "$(GAME_FILE_WATCHER=off watcher 1000000)" "${shim}"
  quiet "said something although GAME_FILE_WATCHER is off"
  # Without the file there is no limit to check against.
  rm "${limit}"
  expect_eq "$(configure_file_watcher "${limit}" "${ini}" "${content}" "$(rows 42.21.0)" > "${WORK}/out" 2> "${WORK}/err"; printf '%s' "${LD_PRELOAD:-}")" ''
  quiet "said something without a limit"

  # Build 41 reads mod.info and media/ in the mod folder itself, whatever else is in it: that adds
  # Old41 and its media folder (3).
  mkdir -p "${content}/100/mods/Old41/42/media/lua" "${content}/100/mods/Old41/common/media/lua"
  printf 'id=Old41Mod\n' > "${content}/100/mods/Old41/42/mod.info"
  expect_eq "$(watched_dirs "${ini}" "${content}" "$(rows 41.78.16)")" 11
}

test_overlaps() {
  TEST=overlaps
  new_env
  export WORKSHOP_IDS=1 INI_WorkshopItems=2 PORT=1 INI_defaultport=2 INI_Password=a INI_Password_FILE=/x \
    INI_Public=true INI_public=false SANDBOX_Zombies=1 ADMINPASSWORD=a ADMINPASSWORD_FILE=/y INI_PVP=true
  report_overlaps 2> "${WORK}/err"
  grep -q 'WORKSHOP_IDS and INI_WorkshopItems set the same thing' "${WORK}/err" || fail "WORKSHOP_IDS overlap not reported"
  grep -q 'PORT and INI_defaultport set the same thing' "${WORK}/err" || fail "PORT overlap not reported"
  grep -q 'INI_Password and INI_Password_FILE are both set' "${WORK}/err" || fail "_FILE overlap not reported"
  grep -q 'INI_Public INI_public differ only in case' "${WORK}/err" || fail "case duplicate not reported"
  grep -q 'ADMINPASSWORD_FILE is used' "${WORK}/err" || fail "ADMINPASSWORD overlap not reported"
  expect_eq "$(wc -l < "${WORK}/err")" 5
}

test_unrecognized() {
  TEST=unrecognized
  new_env
  # Everything the test runner itself exports counts as the image's own, except what bash adds.
  compgen -e | grep -vxE 'OLDPWD|PWD|SHLVL' > "${WORK}/image-env"
  export PASSWORD=x ini__pzserver__Public=true MEMORY=4g INI_Public=true http_proxy=x TZ=UTC
  report_unrecognized "${WORK}/image-env" 2> "${WORK}/err"
  grep -q 'does not read PASSWORD ini__pzserver__Public\.' "${WORK}/err" || { fail "unknown variables were not reported as expected"; cat "${WORK}/err" >&2; }
  unset PASSWORD ini__pzserver__Public
  report_unrecognized "${WORK}/image-env" 2> "${WORK}/err"
  [ -s "${WORK}/err" ] && fail "known variables were reported"
}

test_configure() {
  TEST=configure
  new_env
  echo 'rcon from file' > "${WORK}/rcon"
  export INI_Password='p&ss|word' INI_RCONPassword=ignored INI_RCONPassword_FILE="${WORK}/rcon" ADMINPASSWORD='p@ss word$USER' \
    MEMORY=2048m DEBUG=true ADMINUSERNAME=boss PORT=17000 STEAMVAC=TRUE WORKSHOP_IDS="" INI_Mods='\Ghost;\LocalMap'
  mkdir -p "${HOMEDIR}/Zomboid/mods/Local/42/media/maps/Local Map"
  printf 'id=LocalMap\n' > "${HOMEDIR}/Zomboid/mods/Local/42/mod.info"
  echo 'LOG  : General     , 1727000000000> versionNumber=42.21.0 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  configure_file_watcher() { printf '%s\n' "$@" > "${WORK}/watcher"; }
  configure_server > /dev/null 2> "${WORK}/err"
  # The startup warnings, the maps and the file watcher follow the Mods= of this start.
  expect_line "${WORK}/err" 'Warning: Mods= enables Ghost, but neither a downloaded workshop item nor Zomboid/mods has it.'
  expect_line "${WORK}/watcher" /proc/sys/fs/inotify/max_user_watches
  grep -q "^load	Zomboid	Local	42	1	LocalMap	" "${WORK}/watcher" || fail "the file watcher did not get the mods that load"
  expect_eq "$(grep -c 'Mods=' "${WORK}/err")" 1
  expect_line "${SERVER}/pzserver.ini" 'Map=Local Map;Muldraugh, KY'
  expect_line "${SERVER}/pzserver.ini" 'Password=p&ss|word'
  expect_line "${SERVER}/pzserver.ini" 'RCONPassword=rcon from file'
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems='
  expect_eq "$(printf '%q ' "${ARGS[@]}")" "-Xms2048m -Xmx2048m -- -debug -adminusername boss -servername pzserver -port 17000 -steamvac true "

  # Without the database the admin password is passed, and required.
  rm "${HOMEDIR}/Zomboid/db/pzserver.db"
  configure_server > /dev/null 2>&1
  expect_eq "${ARGS[*]: -2}" "-adminpassword p@ss word\$USER"
  unset ADMINPASSWORD
  (configure_server > /dev/null 2> "${WORK}/err") && fail "the first start went ahead without ADMINPASSWORD"
  grep -q 'ADMINPASSWORD' "${WORK}/err" || fail "the missing ADMINPASSWORD was not explained"
}

test_list_env() {
  TEST=list-env
  new_env
  export ADMINPASSWORD=secret
  set_ini_value "${SERVER}/pzserver.ini" Password hunter2
  bash "${SCRIPT_DIR}/list_env.sh" > "${WORK}/out"
  expect_line "${WORK}/out" '# Players can hurt and kill other players'
  expect_line "${WORK}/out" 'INI_PVP=true'
  expect_line "${WORK}/out" 'SANDBOX_ZombieLore__Transmission=1'
  expect_line "${WORK}/out" 'ADMINPASSWORD=(set)'
  expect_line "${WORK}/out" 'INI_Password=(set)'
  expect_line "${WORK}/out" '## Sandbox settings (pzserver_SandboxVars.lua)'
  bash "${SCRIPT_DIR}/list_env.sh" zombielore > "${WORK}/out"
  grep -q '^INI_' "${WORK}/out" && fail "the filter kept unrelated rows"
  grep -q '^SANDBOX_ZombieLore__Mortality=' "${WORK}/out" || fail "the filter dropped matching rows"
  set_ini_value "${SERVER}/pzserver.ini" DiscordToken abc
  bash "${SCRIPT_DIR}/list_env.sh" | grep -qxF 'INI_DiscordToken=(set)' || fail "the Discord token was shown"
  bash "${SCRIPT_DIR}/list_env.sh" --tsv > "${WORK}/out"
  expect_line "${WORK}/out" "$(printf 'sandbox\tSANDBOX_ZombieLore__Mortality\t5\tDefault = Instant')"
}

test_vars_documented() {
  TEST=vars
  local name
  while IFS=$'\t' read -r name _; do
    grep -rq --include='*.sh' -- "${name}" "${SCRIPT_DIR}" || fail "${name} is documented but never read"
  done < "${SCRIPT_DIR}/vars.tsv"
  for name in $(grep -rhoE '\$\{[A-Z][A-Z0-9_]+(:-|\+x|\})' "${SCRIPT_DIR}" | grep -oE '[A-Z][A-Z0-9_]+' | sort -u); do
    case "${name}" in
      HOMEDIR|STEAMAPPDIR|STEAMAPPID|STEAMCMDDIR|SERVERNAME|SCRIPT_DIR|LD_LIBRARY_PATH|LD_PRELOAD|SERVER_*|SHUTDOWN_*|CONSOLE_FD|ARGS|VANILLA_MAP|KEY|VALUE|NAME|LOG_*) continue ;;
    esac
    grep -q "^${name}	" "${SCRIPT_DIR}/vars.tsv" || fail "${name} is read but not in vars.tsv"
  done
}

test_game() {
  TEST=game
  new_env
  # The retries would otherwise wait 10 seconds each.
  sleep() { :; }
  local calls="${HOMEDIR}/steamcmd-calls"
  update_game > "${WORK}/out" 2>&1 || fail "the first install failed"
  expect_line "${calls}" "+force_install_dir ${STEAMAPPDIR} +login anonymous +app_update 380870 +quit"
  expect_line "${STEAMAPPDIR}/.game-branch" public
  expect_line "${WORK}/out" "Game: public branch, build 100"

  FAKE_BUILD=101 update_game > "${WORK}/out" 2>&1
  expect_line "${WORK}/out" "Game: public branch, build 101"
  expect_eq "$(wc -l < "${calls}")" 2

  GAME_UPDATE=false update_game > "${WORK}/out" 2>&1
  expect_eq "$(wc -l < "${calls}")" 2
  expect_line "${WORK}/out" "Game: public branch, build 101, not checked for updates (GAME_UPDATE=false)"

  # A branch change goes through even with GAME_UPDATE=false, and SteamCMD has to forget the old beta.
  GAME_BRANCH=unstable GAME_UPDATE=false update_game > /dev/null 2>&1
  expect_eq "$(tail -n 1 "${calls}")" "+force_install_dir ${STEAMAPPDIR} +login anonymous +app_update 380870 -beta unstable validate +quit"
  expect_line "${STEAMAPPDIR}/.game-branch" unstable
  GAME_BRANCH=unstable update_game > /dev/null 2>&1
  expect_eq "$(tail -n 1 "${calls}")" "+force_install_dir ${STEAMAPPDIR} +login anonymous +app_update 380870 -beta unstable +quit"

  # Without its success line SteamCMD failed, whatever its exit code. The switch back to public has
  # already dropped the beta's manifest by then.
  (FAKE_STEAM_SILENT=1 update_game > /dev/null 2> "${WORK}/err") && fail "a silent SteamCMD run counted as an update"
  [ -f "${STEAMAPPDIR}/steamapps/appmanifest_380870.acf" ] && fail "the switch back to public kept the beta's manifest"
  expect_eq "$(tail -n 1 "${calls}")" "+force_install_dir ${STEAMAPPDIR} +login anonymous +app_update 380870 validate +quit"
  expect_line "${STEAMAPPDIR}/.game-branch" unstable

  update_game > /dev/null 2>&1
  expect_line "${STEAMAPPDIR}/.game-branch" public
  (FAKE_STEAM_FAIL=1 update_game > /dev/null 2> "${WORK}/err") && fail "a failed update did not stop the start"
  expect_eq "$(tail -n 3 "${calls}" | grep -c '+app_update 380870 +quit')" 3
  grep -q 'GAME_UPDATE=false starts the installed game' "${WORK}/err" || fail "the GAME_UPDATE hint was missing"
}

test_entry() {
  TEST=entry
  new_env
  cat > "${STEAMAPPDIR}/start-server.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${HOMEDIR}/args"
printf '%s\n' "${LD_PRELOAD:-}" > "${HOMEDIR}/preload"
echo "LOG  : Network      f:0> *** SERVER STARTED ****"
while IFS= read -r line; do
  [ "${line}" = quit ] && { echo "saving"; sleep 0.2; echo "saved"; exit 0; }
  echo "command: ${line}"
done
EOF
  chmod +x "${STEAMAPPDIR}/start-server.sh"
  (cd "${WORK}" && GAME_FILE_WATCHER=false exec bash "${SCRIPT_DIR}/entry.sh") > "${WORK}/entry.log" 2>&1 &
  local pid=$! healthy=false
  for _ in $(seq 1 50); do
    bash "${SCRIPT_DIR}/healthcheck.sh" && { healthy=true; break; }
    sleep 0.1
  done
  [ "${healthy}" = true ] || { fail "the health check never passed"; cat "${WORK}/entry.log" >&2; }
  bash "${SCRIPT_DIR}/console.sh" servermsg "hello there" > /dev/null || fail "console failed"
  sleep 0.2
  grep -qxF 'command: servermsg "hello there"' "${WORK}/entry.log" || fail "console command did not reach the server"
  kill -TERM "${pid}"
  wait "${pid}"
  expect_eq "$?" 0
  grep -q saving "${WORK}/entry.log" || fail "the server did not receive quit"
  grep -q saved "${WORK}/entry.log" || fail "the last server output was lost"
  bash "${SCRIPT_DIR}/healthcheck.sh" && fail "the health check passed after the server stopped"
  expect_line "${HOMEDIR}/args" "-servername"
  expect_line "${HOMEDIR}/preload" /usr/local/lib/no_file_watcher.so
}

for t in test_ini test_sandbox test_preset test_maps test_mod_folders test_workshop test_list_mods test_mod_warnings test_file_watcher test_overlaps test_unrecognized test_configure test_list_env test_vars_documented test_game test_entry; do
  ( "${t}"; exit "${FAILED}" ) || FAILED=1
done

if [ "${FAILED}" -ne 0 ]; then
  echo "Smoke tests failed" >&2
  exit 1
fi
echo "Smoke tests passed"
