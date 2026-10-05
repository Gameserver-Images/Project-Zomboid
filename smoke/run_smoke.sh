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
  make_mod 200 Bedford BedfordFalls "" "Bedford Falls"
  make_mod 300 Unused UnusedMod 42 "Unused Map"
  make_mod 400 Patch VanillaPatch 42 "Muldraugh, KY"
  mkdir -p "${content}/100/mods/RavenCreek/common/media/maps/Raven Creek Extra"
  set_ini_value "${ini}" Mods '\RavenCreekMod;2392709985\BedfordFalls;\VanillaPatch'
  set_ini_value "${ini}" Map 'Admin Map;Unused Map;Muldraugh, KY'
  apply_mod_maps "${ini}" "${spawn}" "${content}" >/dev/null
  expect_line "${ini}" 'Map=Admin Map;Raven Creek;Raven Creek Extra;Bedford Falls;Muldraugh, KY'
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

  expect_eq "$(merge_map_list "" "" "A")" "A;Muldraugh, KY"
  expect_eq "$(merge_map_list "B;Muldraugh, KY;B" "" "A")" "B;A;Muldraugh, KY"
  expect_eq "$(merge_map_list "B;C;Muldraugh, KY" "C;D" "A")" "B;A;Muldraugh, KY"
}

test_workshop() {
  TEST=workshop
  new_env
  # A fake Steam API: 111 is a collection holding item 333, collection 444 (item 555) and the empty
  # collection 666; 222 is an item.
  mkdir -p "${WORK}/bin"
  cat > "${WORK}/bin/curl" <<'CURL'
#!/bin/bash
if [[ "$*" == *"=444"* ]]; then
  echo '{"response":{"collectiondetails":[{"publishedfileid":"444","result":1,"children":[{"publishedfileid":"555","filetype":0}]},{"publishedfileid":"666","result":1,"children":[]}]}}'
else
  echo '{"response":{"collectiondetails":[{"publishedfileid":"111","result":1,"children":[{"publishedfileid":"333","filetype":0},{"publishedfileid":"444","filetype":2},{"publishedfileid":"666","filetype":2}]},{"publishedfileid":"222","result":9}]}}'
fi
CURL
  chmod +x "${WORK}/bin/curl"
  PATH="${WORK}/bin:${PATH}" WORKSHOP_IDS='111;222' apply_workshop_ids "${SERVER}/pzserver.ini" > /dev/null
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems=222;333;555'
  printf '#!/bin/bash\nexit 6\n' > "${WORK}/bin/curl"
  PATH="${WORK}/bin:${PATH}" WORKSHOP_IDS='111' apply_workshop_ids "${SERVER}/pzserver.ini" > /dev/null 2>&1
  expect_line "${SERVER}/pzserver.ini" 'WorkshopItems=222;333;555'
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
    MEMORY=2048m DEBUG=true ADMINUSERNAME=boss PORT=17000 STEAMVAC=TRUE WORKSHOP_IDS=""
  configure_server > /dev/null 2>&1
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

for t in test_ini test_sandbox test_preset test_maps test_workshop test_overlaps test_unrecognized test_configure test_list_env test_vars_documented test_game test_entry; do
  ( "${t}"; exit "${FAILED}" ) || FAILED=1
done

if [ "${FAILED}" -ne 0 ]; then
  echo "Smoke tests failed" >&2
  exit 1
fi
echo "Smoke tests passed"
