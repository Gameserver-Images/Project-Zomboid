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
  set_ini_value "${ini}" Mods '\RavenCreekMod;2392709985\BedfordFalls;\VanillaPatch;\Old41Mod;\MultiMod;\NewId'
  set_ini_value "${ini}" Map 'Admin Map;Unused Map;Muldraugh, KY'

  # Before the first start the game version, and with it the version folders, is unknown.
  apply_mod_maps "${ini}" "${spawn}" "${content}" >/dev/null
  expect_line "${ini}" 'Map=Admin Map;Unused Map;Muldraugh, KY'
  grep -q 'Raven Creek' "${spawn}" && fail "spawnregions changed without a game version"

  echo 'LOG  : General     , 1727000000000> versionNumber=42.21.0 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  apply_mod_maps "${ini}" "${spawn}" "${content}" >/dev/null
  expect_line "${ini}" 'Map=Admin Map;Raven Creek;Raven Creek Extra;Bedford Falls;New Map;Renamed Map;Muldraugh, KY'
  expect_line "${spawn}" '		{ name = "Raven Creek", file = "media/maps/Raven Creek/spawnpoints.lua" },'

  # A second start changes nothing.
  cp "${ini}" "${WORK}/ini.before"
  cp "${spawn}" "${WORK}/spawn.before"
  apply_mod_maps "${ini}" "${spawn}" "${content}" >/dev/null
  cmp -s "${ini}" "${WORK}/ini.before" || fail "the Map line changed on the second start"
  cmp -s "${spawn}" "${WORK}/spawn.before" || fail "spawnregions changed on the second start"

  # Disabling a mod takes its maps and spawn points out again.
  set_ini_value "${ini}" Mods '2392709985\BedfordFalls'
  apply_mod_maps "${ini}" "${spawn}" "${content}" >/dev/null
  expect_line "${ini}" 'Map=Admin Map;Bedford Falls;Muldraugh, KY'
  grep -q 'Raven Creek' "${spawn}" && fail "the spawn region of a disabled mod was kept"
  expect_line "${spawn}" '		{ name = "Muldraugh, KY", file = "media/maps/Muldraugh, KY/spawnpoints.lua" },'

  # Build 41 loads the mod folder itself.
  echo 'LOG  : General     , 1700000000000> version=41.78.16 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  set_ini_value "${ini}" Mods 'Old41Mod;RavenCreekMod'
  set_ini_value "${ini}" Map 'Muldraugh, KY'
  apply_mod_maps "${ini}" "${spawn}" "${content}" >/dev/null
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
  # no version, and a second mod. Item 102 only has Build 41 and a folder that is no version, item 106
  # is on disk only and has 42.0 and 42.5, which is older than 42.21.
  printf '%s\r\n' 'name=Multi B41' 'id=MultiMod' 'modversion=41' | mod_file "${multi}/mod.info"
  printf '%s\r\n' 'name=Multi 42' 'id=MultiMod' 'modversion=42' | mod_file "${multi}/42/mod.info"
  printf '%s\r\n' 'name=Multi 42.5' 'id=MultiMod' 'modversion=42.5' | mod_file "${multi}/42.5/mod.info"
  printf '%s\r\n' 'name=Multi 42.22' 'id=MultiMod' 'modversion=42.22' | mod_file "${multi}/42.22/mod.info"
  printf '%s\r\n' 'name=Multi backup' 'id=MultiMod' 'modversion=backup' | mod_file "${multi}/backup/mod.info"
  printf '%s\r\n' 'Name = Multi 42.21' 'id=MultiMod' 'modversion=42.21' 'authors=Someone' 'url=https://example.com' \
    'Require=\StarlitLibrary , 2392709985\TsarLib; PlainReq' 'loadModAfter=AfterMe' 'loadModBefore=\BeforeOne,\BeforeTwo' \
    'incompatible=\Enemy,' 'versionMin=42.21' | mod_file "${multi}/42.21/mod.info"
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
*/ option Multi.Shared { type = double, /* was 2 */ default = 1.5, }
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
  printf '\357\273\277id=MultiAddon\r\nname=Addon\r\n' | mod_file 101/mods/Addon/42/mod.info
  printf '%s\n' 'option Addon.Flag' '{' 'type = boolean,' 'default = false,' 'translation = Addon_Flag,' '}' \
    'option Addon.Mode' '{' 'type = enum, numValues = 2,' 'default = 1,' 'valueTranslation = Addon_Modes,' '}' | mod_file 101/mods/Addon/42/media/sandbox-options.txt
  printf '%s\n' 'Sandbox_EN = {' '    Sandbox_Addon_Flag = "The \"best\" flag", -- why' '}' | mod_file 101/mods/Addon/42/media/lua/shared/Translate/EN/Sandbox_EN.txt
  make_mod 102 "Old Mod" OldMod "" "Old Map"
  make_mod 102 "Old Mod" OldMod backup
  make_mod 104 Hidden HiddenMod 42
  printf '%s\n' 'option Hidden.X' '{' 'type = integer,' 'default = 3,' 'translation = Hidden_X,' '}' | mod_file 104/mods/Hidden/42/media/sandbox-options.txt
  echo '{"Sandbox_Hidden_X": "X",}' | mod_file 104/mods/Hidden/42/media/lua/shared/Translate/EN/Sandbox.json
  make_mod 106 Loose LooseMod 42.0
  make_mod 106 Loose LooseMod 42.5
  # A mod.info without an id still brings its maps and options.
  make_mod 106 "No Id" "" 42 "No Id Map"
  printf '%s\n' 'option NoId.X' '{' 'type = integer,' 'default = 3,' '}' | mod_file "106/mods/No Id/42/media/sandbox-options.txt"
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
  jq -e '.format == 1 and .gameVersion == "42.21.0" and .workshopIds == ["900", "104"]' "${out}" > /dev/null || fail "wrong header"
  expect_eq "$(jq -c .server "${out}")" '{"mods":["\\MultiMod","2392709985\\TsarLib","\\OldMod"],"map":["Variant Map","Muldraugh, KY"],"workshopItems":["101","102","105"]}'
  expect_eq "$(jq -c .collections "${out}")" '[{"id":"900","title":"Item 900","children":["101","910","102"]},{"id":"910","title":"Item 910","children":["103","920"]},{"id":"920","title":"Item 920","children":[]}]'
  expect_eq "$(jq -c '[.items[] | [.id, .available, .downloaded, (.mods | map(.folder))]]' "${out}")" \
    '[["101",true,true,["Addon","Multi Version"]],["102",true,true,["Old Mod"]],["103",true,false,[]],["104",false,true,["Hidden"]],["105",true,false,[]],["106",true,true,["Loose","No Id"]]]'
  expect_eq "$(jq -c '.items[0] | [.title, .description, .tags, .updated, .size, .requiredItems]' "${out}")" '["Item 101","[b]About 101[/b]",["Build 42"],1700000000,4096,null]'
  expect_eq "$(jq -c '.items[3] | [.title, .description, .tags, .updated, .size]' "${out}")" '[null,null,null,null,null]'
  expect_eq "$(jq -c '.items[3].mods[0].sandbox | map([.env, .label])' "${out}")" '[["SANDBOX_Hidden__X",null]]'
  expect_eq "$(jq -c '.items[0].mods[1] | del(.sandbox)' "${out}")" \
    '{"id":"MultiMod","folder":"Multi Version","versionFolder":"42.21","name":"Multi 42.21","description":null,"author":"Someone","modVersion":"42.21","url":"https://example.com","category":null,"versionMin":"42.21","versionMax":null,"require":["StarlitLibrary","TsarLib","PlainReq"],"loadModAfter":["AfterMe"],"loadModBefore":["BeforeOne","BeforeTwo"],"incompatible":["Enemy"],"maps":["Common Map","Variant Map"]}'
  expect_eq "$(jq -c '.items[0].mods[1].sandbox | map([.env, .type, .default, .current])' "${out}")" \
    '[["SANDBOX_Multi__Mode","enum","1","2"],["SANDBOX_Multi__Strength","integer","10",null],["SANDBOX_Multi__Shared","double","1.5",null],["SANDBOX_MultiNoDot","boolean","true","false"],["SANDBOX_Multi__CommonOnly","string","Base.Axe;Base.Saw","a \"b\""]]'
  expect_eq "$(jq -c '.items[0].mods[1].sandbox[0:2]' "${out}")" \
    '[{"env":"SANDBOX_Multi__Mode","option":"Multi.Mode","type":"enum","default":"1","min":null,"max":null,"values":["Easy","2","Hard"],"page":"Multi","pageLabel":"Multi settings","label":"Mode","tooltip":null,"current":"2"},{"env":"SANDBOX_Multi__Strength","option":"Multi.Strength","type":"integer","default":"10","min":"-5","max":"50","values":null,"page":"Multi","pageLabel":"Multi settings","label":null,"tooltip":"How strong","current":null}]'
  expect_eq "$(jq -c '.items[0].mods[1].sandbox[4] | [.page, .pageLabel, .label]' "${out}")" '["Elsewhere",null,null]'
  expect_eq "$(jq -c '.items[0].mods[0] | [.id, .versionFolder, .sandbox[0].label, .sandbox[0].values, .sandbox[1].values]' "${out}")" '["MultiAddon","42","The \"best\" flag",null,null]'
  expect_eq "$(jq -c '.items[1].mods[0] | [.id, .name, .versionFolder, .maps, .sandbox]' "${out}")" '["OldMod","Old Mod",null,[],[]]'
  expect_eq "$(jq -c '.items[5].mods[0].versionFolder' "${out}")" '"42.5"'
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
  expect_eq "$(jq -c '[.items[] | select(.id | length == 3) | .requiredItems]' "${out}")" '[["102"],[],[],[]]'
  expect_eq "$(jq -c '[.items[].id] | length' "${out}")" 155
  expect_eq "$(paste -sd ' ' "${HOMEDIR}/steam-calls")" "GetPublishedFileDetails 100 GetPublishedFileDetails 55 GetDetails 100 GetDetails 55"
  (PATH="${WORK}/bin:${PATH}" STEAM_API_KEY=wrong bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" 2> "${WORK}/err") && fail "list-mods succeeded with a wrong key"
  [ -s "${out}" ] && fail "list-mods printed output with a wrong key"
  grep -q '^Error: .*STEAM_API_KEY' "${WORK}/err" || fail "the wrong key was not explained"
  (PATH="${WORK}/bin:${PATH}" FAKE_STEAM_PARTIAL=1000 bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" 2> /dev/null) && fail "list-mods succeeded with an incomplete first batch"

  # Build 41 loads the mod.info in the mod folder itself.
  echo 'LOG  : General     , 1700000000000> version=41.78.16 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  PATH="${WORK}/bin:${PATH}" bash "${SCRIPT_DIR}/list_mods.sh" > "${out}" || fail "list-mods failed on Build 41"
  expect_eq "$(jq -c '[.gameVersion, (.items[] | select(.id | length == 3) | .mods[] | [.folder, .versionFolder, .modVersion, .maps])]' "${out}")" \
    '["41.78.16",["Addon",null,null,[]],["Multi Version","","41",[]],["Old Mod","",null,["Old Map"]],["Hidden",null,null,[]],["Loose",null,null,[]],["No Id",null,null,[]]]'

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

test_mod_warnings() {
  TEST=warnings
  new_env
  local ini="${SERVER}/pzserver.ini" content="${STEAMAPPDIR}/steamapps/workshop/content/108600"
  echo 'LOG  : General     , 1727000000000> versionNumber=42.21.0 demo=false' > "${HOMEDIR}/Zomboid/server-console.txt"
  printf '%s\r\n' 'id=ModA' 'require=\ModB' 'loadModAfter=ModC,\ModB' 'incompatible=\ModD' | mod_file 201/mods/A/42/mod.info
  make_mod 202 B ModB 42
  printf '%s\n' 'id=ModC' 'loadModBefore=\ModE' | mod_file 203/mods/C/42.21/mod.info
  printf '%s\n' 'id=ModD' 'incompatible=ModA' | mod_file 204/mods/D/42/mod.info
  make_mod 205 E ModE 42
  printf '%s\n' 'id=ModF' 'require=2392709985\ModMissing,\ModMissing' | mod_file 206/mods/F/42/mod.info
  # Not loaded on 42.21, so its mod.info doesn't count.
  printf '%s\n' 'id=ModG' 'require=ModMissing' | mod_file 207/mods/G/42.30/mod.info
  # Mods placed by hand in Zomboid/mods, for Build 42 and for Build 41.
  mkdir -p "${HOMEDIR}/Zomboid/mods/My Local/42" "${HOMEDIR}/Zomboid/mods/Old Local"
  printf '%s\r\n' 'id=ModLocal' 'require=\ModB' > "${HOMEDIR}/Zomboid/mods/My Local/42/mod.info"
  printf '%s\r\n' 'id=ModLocal41' > "${HOMEDIR}/Zomboid/mods/Old Local/mod.info"

  set_ini_value "${ini}" WorkshopItems '201;202;203;204;205;206;207'
  set_ini_value "${ini}" Mods '\ModB;\ModC;\ModA;\ModE;\ModG;\ModLocal;\ModLocal41'
  report_mod_problems "${ini}" "${content}" 2> "${WORK}/err"
  [ -s "${WORK}/err" ] && fail "warned about mods in order: $(cat "${WORK}/err")"

  # Each problem once, also for mods listed twice.
  set_ini_value "${ini}" Mods '\ModA;2392709985\ModB;\ModE;\ModC;\ModD;\ModF;\Ghost;\ModA;\ModF;\Ghost;\ModLocal'
  report_mod_problems "${ini}" "${content}" 2> "${WORK}/err"
  expect_line "${WORK}/err" 'Warning: Mods= lists ModA before ModB, which it requires.'
  expect_line "${WORK}/err" 'Warning: Mods= lists ModA before ModC, but its mod.info says to load it after ModC.'
  expect_line "${WORK}/err" 'Warning: ModA and ModD are both in Mods=, but the mod.info of ModA says they are incompatible.'
  expect_line "${WORK}/err" 'Warning: Mods= lists ModC after ModE, but its mod.info says to load it before ModE.'
  expect_line "${WORK}/err" 'Warning: ModF requires ModMissing, which is not in Mods=.'
  expect_line "${WORK}/err" 'Warning: Mods= enables Ghost, but neither a downloaded workshop item nor Zomboid/mods has it.'
  expect_eq "$(wc -l < "${WORK}/err")" 6

  # Items download while the server starts, so a new item's mods may not be there yet.
  set_ini_value "${ini}" WorkshopItems '201;202;203;204;205;206;207;299'
  report_mod_problems "${ini}" "${content}" 2> "${WORK}/err"
  grep -q Ghost "${WORK}/err" && fail "missing mods were reported while an item was not downloaded"
  expect_eq "$(wc -l < "${WORK}/err")" 5

  # The mod.info of a mod in Zomboid/mods is checked too.
  set_ini_value "${ini}" Mods '\ModLocal;\ModB'
  report_mod_problems "${ini}" "${content}" 2> "${WORK}/err"
  expect_eq "$(cat "${WORK}/err")" 'Warning: Mods= lists ModLocal before ModB, which it requires.'

  # A `<workshop id>\` prefix picks the copy of a mod ID that two items have. Without one, the first
  # copy counts. A requirement both copies have is reported once.
  printf '%s\n' 'id=ModX' 'require=\Dep,\Shared' 'incompatible=\ModB' | mod_file 301/mods/X/42/mod.info
  printf '%s\n' 'id=ModX' 'require=\Need,\Shared' | mod_file 302/mods/X/42/mod.info
  set_ini_value "${ini}" WorkshopItems '202;301;302'
  set_ini_value "${ini}" Mods '302\ModX;\ModB'
  report_mod_problems "${ini}" "${content}" 2> "${WORK}/err"
  expect_eq "$(cat "${WORK}/err")" 'Warning: ModX requires Need, which is not in Mods=.
Warning: ModX requires Shared, which is not in Mods=.'
  set_ini_value "${ini}" Mods '\ModX;301\ModX;302\ModX;\ModB'
  report_mod_problems "${ini}" "${content}" 2> "${WORK}/err"
  expect_line "${WORK}/err" 'Warning: ModX requires Dep, which is not in Mods=.'
  expect_line "${WORK}/err" 'Warning: ModX requires Need, which is not in Mods=.'
  expect_line "${WORK}/err" 'Warning: ModX requires Shared, which is not in Mods=.'
  expect_line "${WORK}/err" 'Warning: ModX and ModB are both in Mods=, but the mod.info of ModX says they are incompatible.'
  expect_eq "$(wc -l < "${WORK}/err")" 4

  # Without the game version the version folder is unknown, so only missing mods are reported.
  set_ini_value "${ini}" WorkshopItems '201;202;203;204;205;206;207'
  set_ini_value "${ini}" Mods '\ModA;2392709985\ModB;\ModE;\ModC;\ModD;\ModF;\Ghost;\ModA;\ModLocal'
  rm "${HOMEDIR}/Zomboid/server-console.txt"
  report_mod_problems "${ini}" "${content}" 2> "${WORK}/err"
  expect_eq "$(cat "${WORK}/err")" 'Warning: Mods= enables Ghost, but neither a downloaded workshop item nor Zomboid/mods has it.'
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
    MEMORY=2048m DEBUG=true ADMINUSERNAME=boss PORT=17000 STEAMVAC=TRUE WORKSHOP_IDS="" INI_Mods='\Ghost'
  configure_server > /dev/null 2> "${WORK}/err"
  # The startup warnings check the Mods= of this start.
  expect_line "${WORK}/err" 'Warning: Mods= enables Ghost, but neither a downloaded workshop item nor Zomboid/mods has it.'
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
      HOMEDIR|STEAMAPPDIR|STEAMAPPID|STEAMCMDDIR|SERVERNAME|SCRIPT_DIR|LD_LIBRARY_PATH|SERVER_*|SHUTDOWN_*|CONSOLE_FD|ARGS|VANILLA_MAP|KEY|VALUE|NAME|LOG_*) continue ;;
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
echo "LOG  : Network      f:0> *** SERVER STARTED ****"
while IFS= read -r line; do
  [ "${line}" = quit ] && { echo "saving"; sleep 0.2; echo "saved"; exit 0; }
  echo "command: ${line}"
done
EOF
  chmod +x "${STEAMAPPDIR}/start-server.sh"
  (cd "${WORK}" && exec bash "${SCRIPT_DIR}/entry.sh") > "${WORK}/entry.log" 2>&1 &
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
}

for t in test_ini test_sandbox test_preset test_maps test_workshop test_list_mods test_mod_warnings test_overlaps test_unrecognized test_configure test_list_env test_vars_documented test_game test_entry; do
  ( "${t}"; exit "${FAILED}" ) || FAILED=1
done

if [ "${FAILED}" -ne 0 ]; then
  echo "Smoke tests failed" >&2
  exit 1
fi
echo "Smoke tests passed"
