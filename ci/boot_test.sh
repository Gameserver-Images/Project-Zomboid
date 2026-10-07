#!/bin/bash
# Boots an image on a game branch and checks that it installs the game, reads its version, starts the
# server, keeps settings written before its first start, creates its database and saves on
# `docker stop`, then starts it again to check the update and the settings against the files the
# server wrote. A first start on a new data volume with a map mod from the workshop checks that the
# image downloads it before the server starts, so that start has its map and spawn region; on Build 42
# a local mod in that start checks how the game's map zone loader takes a zone without x and y. The
# start after adds an item, which SteamCMD downloads next to one the server downloaded itself, and
# asks the server whether its items have updates and how many players are online. Then,
# with the host's inotify watch limit below what the game watches with a mod, it
# checks that the image turns the game's file watcher off. That limit holds for every user of the host
# for a few minutes, a desktop's programs included. Writes the env reference for the docs site to
# <out dir>/<branch>-<build id>.json, with the image version from its org.opencontainers.image.version
# label.
# Each workaround of a game bug has a canary here: the bug reproduced with the workaround off. When the
# game copes, the canary fires, which says that this branch no longer needs the workaround. The results
# go to <out dir>/canaries.jsonl, from which CI opens an issue once a canary fires.
# Usage: boot_test.sh <image> <game branch> <out dir>

set -euo pipefail

image="$1"
branch="$2"
out_dir="$3"
name="pz-boot-test"
# Kept after the test, so a failed run can be inspected.
game_volume="pz-boot-game"
home_volume="pz-boot-home"
home="/home/steam/Zomboid"
release="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image}")"
if [ -z "${release}" ] || [ "${release}" = "<no value>" ]; then
  echo "Error: ${image} has no org.opencontainers.image.version label" >&2
  exit 1
fi

mkdir -p "${out_dir}"
canaries="${out_dir}/canaries.jsonl"
: > "${canaries}"

fail() {
  echo "Error: $*" >&2
  # The start of the log has the game install and the configuration, the end what the server did last.
  docker logs "${name}" 2>&1 | sed -n '1,150p' >&2 || true
  echo "[...]" >&2
  docker logs --tail 150 "${name}" >&2 || true
  exit 1
}
# The inotify watch limit to restore, while it is lowered
watch_limit=""
cleanup() {
  docker rm -f "${name}" >/dev/null 2>&1 || true
  [ -z "${watch_limit}" ] || sudo sysctl -q -w "fs.inotify.max_user_watches=${watch_limit}" || true
}
trap cleanup EXIT

wait_healthy() {
  # Returns 1 when the server exits before it starts.
  local status=""
  echo "Waiting for the server to start"
  for _ in $(seq 1 240); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "${name}")"
    [ "${status}" = healthy ] && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "${name}")" = true ] || return 1
    sleep 5
  done
  fail "the server did not start within 20 minutes"
}

canary() {
  # $1 = workaround, $2 = fired when the game no longer needs it, held when it still does, n/a when it
  # doesn't apply to this game version, $3 = what the game did, $4 = how to remove the workaround
  jq -n -c --arg workaround "$1" --arg branch "${branch}" --arg game "${label}" --arg result "$2" --arg finding "$3" \
    --arg remove "$4" '{$workaround, $branch, label: $game, $result, $finding, $remove}' >> "${canaries}"
  if [ "$2" = fired ]; then
    echo "::warning title=$1 workaround::On ${label} $3, so this branch no longer needs the workaround. Once no branch needs it, $4"
  else
    echo "$1 workaround: on ${label} $3"
  fi
}

stop_server() {
  # $1 = how many clean stops the log should show by now
  echo "Stopping the server"
  docker stop -t 120 "${name}" >/dev/null
  exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
  [ "${exit_code}" = 0 ] || fail "the server exited with ${exit_code} on docker stop instead of saving and exiting cleanly"
  [ "$(docker logs "${name}" 2>&1 | grep -c "Server stopped with exit code 0")" = "$1" ] || fail "the shutdown did not go through quit"
}

# SANDBOX_ only applies once the server has written SandboxVars, so it's checked on the second start.
docker run -d --name "${name}" --health-interval=5s \
  -v "${game_volume}:/home/steam/pz-dedicated" -e GAME_BRANCH="${branch}" \
  -e ADMINPASSWORD=boot-test -e INI_PublicName="Boot test" -e INI_Public=false \
  -e SANDBOX_ZombieLore__Transmission=4 -e CONFIG_STRICT=true \
  "${image}" >/dev/null
wait_healthy || fail "the server exited before it started"

game_lines="$(docker logs "${name}" 2>&1 | grep 'Game: ' || true)"
build="$(sed -n "s/^Game: ${branch} branch, build \([0-9][0-9]*\)$/\1/p" <<< "${game_lines}" | tail -n 1)"
[ -n "${build}" ] || fail "the log does not say which build of the ${branch} branch was installed. Its lines with 'Game: ' are:
${game_lines:-none}"
# The server logs its version at startup (version=<version> <revision> demo=false); java.version and
# the like are not it. The image reads it from the game files before.
version="$(docker logs "${name}" 2>&1 | grep -oE '[[:space:]>]version=[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 | sed 's/.*=//' || true)"
[ -n "${version}" ] || fail "the log does not show the game version"
read_version="$(docker logs "${name}" 2>/dev/null | sed -n 's/^Game: version //p' | head -n 1 || true)"
[ "${read_version}" = "${version}" ] \
  || fail "the image read the game version ${read_version:-(none)} from the game files, but the server logs ${version}"
case "${branch}" in
  public) channel=stable ;;
  unstable) channel=beta ;;
  *) channel="(${branch} branch)" ;;
esac
label="${version} ${channel}"
echo "Installed ${label}, build ${build}"

docker exec "${name}" grep -qx 'PublicName=Boot test' "${home}/Server/pzserver.ini" \
  || fail "INI_PublicName written before the first start was not kept"
docker exec "${name}" grep -qx 'UPnP=false' "${home}/Server/pzserver.ini" \
  || fail "the image did not turn UPnP off by default"
grep -q 'set UPnP=false' <<< "$(docker logs "${name}" 2>&1)" && fail "the server looked for a UPnP gateway"
docker exec "${name}" test -f "${home}/db/pzserver.db" \
  || fail "no database at Zomboid/db/pzserver.db; configure.sh uses it to tell the first start apart"
docker exec "${name}" test -s "${home}/Server/pzserver_SandboxVars.lua" \
  || fail "the server did not write pzserver_SandboxVars.lua"

# INI_ and SANDBOX_ cover these two files; a new settings file from the game needs its own prefix.
others="$(docker exec "${name}" find "${home}/Server" -maxdepth 1 -type f ! -name pzserver.ini ! -name pzserver_SandboxVars.lua ! -name pzserver_spawnregions.lua ! -name pzserver_spawnpoints.lua ! -name '*.bak' -printf '%f ')"
[ -z "${others}" ] || echo "::warning title=New server files::No env vars cover ${others}"

rows="$(docker exec "${name}" list-env --tsv)"
for kind in image ini sandbox; do
  grep -q "^${kind}	" <<< "${rows}" || fail "list-env found no ${kind} settings"
done
# Nested sandbox tables are joined with "__", so a key containing "__" could collide with a path.
duplicates="$(cut -f2 <<< "${rows}" | sort | uniq -d)"
[ -z "${duplicates}" ] || fail "list-env produced duplicate names: ${duplicates}"
jq -R -s --arg label "${label}" --arg release "${release}" '
  split("\n")
  | map(select(length > 0) | split("\t") | {kind: .[0], name: .[1], description: (.[3] // "")})
  | {label: $label, release: $release, vars: .}
' <<< "${rows}" > "${out_dir}/${branch}-${build}.json"

mods_json="$(docker exec "${name}" list-mods)" || fail "list-mods failed"
jq -e --arg version "${version}" '.format == 2 and .items == [] and .gameVersion == $version' <<< "${mods_json}" >/dev/null \
  || fail "list-mods did not describe a server without mods on game version ${version}: ${mods_json}"

stop_server 1

# CONFIG_STRICT now checks every variable against the server's own files.
docker start "${name}" >/dev/null
wait_healthy || fail "the server exited before it started"
[ "$(docker logs "${name}" 2>&1 | grep -c "^Game: ${branch} branch, build ")" = 2 ] \
  || fail "the second start did not check the game for updates"
docker exec "${name}" grep -qx 'PublicName=Boot test' "${home}/Server/pzserver.ini" \
  || fail "PublicName did not survive a restart"
docker exec "${name}" grep -qE '^[[:space:]]*Transmission = 4,' "${home}/Server/pzserver_SandboxVars.lua" \
  || fail "SANDBOX_ZombieLore__Transmission was not applied on the second start"
# The maps in Map= are checked, the game's own too.
logs="$(docker logs "${name}" 2>&1)"
grep -qx 'Config: Map is Muldraugh, KY' <<< "${logs}" || fail "the second start did not name the maps in Map="
grep -q 'stops loading map zones' <<< "${logs}" && fail "the zone check failed the game's own map"
# Once the database exists the admin password must stay out of the command line.
docker exec "${name}" sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" " "' | grep -q -- '-adminpassword' \
  && fail "-adminpassword was passed although the database exists"
stop_server 2

# A first start on a new data volume, with a small map mod from the workshop that has Build 41 and 42
# versions of its map, each with a spawn point. A server downloads workshop items while it starts, too
# late for the maps and spawn regions of their mods, so the image downloads new ones with SteamCMD
# before. The server has to take that download as installed rather than download it again. It
# downloads another item itself, which the image leaves to it because it has a folder, like the items of
# a server that ran before the image downloaded any.
map_item=2963883586
map_mod=Louisville_Riverboat
map=Louisville_Riverboat
# Mod Options and Players On Map: a few KB each, and rarely updated
server_item=2169435993
new_item=2732804047
workshop=/home/steam/pz-dedicated/steamapps/workshop
content="${workshop}/content/108600"
map_failed() {
  # $1 = what went wrong
  fail "$1. If workshop item ${map_item} no longer has a map ${map} with a spawnpoints.lua for ${label}, pick another small map item. Its spawnpoints.lua files: $(docker run --rm -v "${game_volume}:/home/steam/pz-dedicated" --entrypoint find "${image}" "${content}/${map_item}" -name spawnpoints.lua 2>&1 | paste -sd ' ')"
}
docker rm -f "${name}" >/dev/null
docker volume rm -f "${home_volume}" >/dev/null
# The game volume is kept, so the items of an earlier run would be on disk.
docker run --rm -v "${game_volume}:/home/steam/pz-dedicated" --entrypoint bash "${image}" -c 'rm -rf "$1" && mkdir -p "$2"' \
  _ "${workshop}" "${content}/${server_item}"
mods="${map_mod}"
map_line="${map};Muldraugh, KY"
# map_zone_warnings counts the zones the zone loader's Lua code fails on, not those it passes to Java
# without x and y. This start also finds out whether the game takes those: a mod's regions.lua for the
# vanilla map has a polygon Region zone, which goes to Java without x and y, and after it a mannequin
# zone without properties, which the game logs. Build 41 has another zone loader.
# The zone check's canary is a map of that mod, first in Map=, so the loader reads it last: its
# objects.lua has a polygon water zone without properties between two mannequin zones without
# properties, which the game logs, the second one only if the loader gets past the water zone.
zone_file="${home}/mods/BootZones/common/media/maps/BootZones/objects.lua"
zone_remove="remove map_zone_warnings and its call in check_maps (scripts/lib/maps.sh), the README bullet on zones the game fails on, its cases in test_map_checks (smoke/run_smoke.sh) and the BootZones mod and its checks in ci/boot_test.sh."
if [[ "${version}" != 41.* ]]; then
  docker run --rm -v "${home_volume}:${home}" --entrypoint bash "${image}" -c \
    'mkdir -p "$1/media/maps/Muldraugh, KY" "$1/media/maps/BootZones" && printf "id=BootZones\n" > "$1/mod.info" \
      && printf "%s\n" "regions = {" "$2" "$3" "}" > "$1/media/maps/Muldraugh, KY/regions.lua" \
      && printf "title=BootZones\n" > "$1/media/maps/BootZones/map.info" \
      && printf "%s\n" "objects = {" "$4" "$5" "$6" "}" > "$1/media/maps/BootZones/objects.lua"' \
    _ "${home}/mods/BootZones/common" \
    '{ name = "", type = "Region", z = 0, geometry = "polygon", points = { 10,10, 20,10, 20,20 } },' \
    '{ name = "", type = "Mannequin", x = 1, y = 1, z = 0, width = 1, height = 1 },' \
    '{ name = "", type = "Mannequin", x = 3, y = 3, z = 0, width = 1, height = 1 },' \
    '{ name = "", type = "WaterZone", z = 0, geometry = "polygon", points = { 10,10, 20,10, 20,20 } },' \
    '{ name = "", type = "Mannequin", x = 4, y = 4, z = 0, width = 1, height = 1 },'
  mods="BootZones;${map_mod}"
  map_line="BootZones;${map_line}"
fi
docker run -d --name "${name}" --health-interval=5s \
  -v "${game_volume}:/home/steam/pz-dedicated" -v "${home_volume}:${home}" -e GAME_BRANCH="${branch}" \
  -e GAME_UPDATE=false -e ADMINPASSWORD=boot-test -e WORKSHOP_IDS="${server_item};${map_item}" -e INI_Mods="${mods}" \
  "${image}" >/dev/null
wait_healthy || map_failed "the server with the workshop map ${map_mod} exited before it started"
logs="$(docker logs "${name}" 2>&1)"
grep -q "Workshop: item state .* -> DownloadPending ID=${server_item}\$" <<< "${logs}" \
  || fail "the server did not download workshop item ${server_item} itself: $(grep "Workshop: .*${server_item}" <<< "${logs}")"
grep -qx 'Workshop: downloaded 1 new item with SteamCMD' <<< "${logs}" \
  || fail "the image did not download workshop item ${map_item} with SteamCMD before the server started"
grep -qE "Workshop: ${map_item} installed to .*steamapps/workshop/content/108600/${map_item}/?\$" <<< "${logs}" \
  || fail "the server did not use workshop item ${map_item} from where SteamCMD put it: $(grep "Workshop: .*${map_item}" <<< "${logs}")"
grep -q "Workshop: item state .* -> DownloadPending ID=${map_item}\$" <<< "${logs}" \
  && fail "the server downloaded workshop item ${map_item} again, so it doesn't take SteamCMD's download as installed: $(grep "Workshop: .*${map_item}" <<< "${logs}")"
grep -qE "loading ${map_mod}\$" <<< "${logs}" || map_failed "the server did not load the mod ${map_mod}"
if problems="$(grep -E "^Warning: Mods= .*${map_mod}|skipping non-existent map folder .*${map}" <<< "${logs}")"; then
  map_failed "the map mod did not load as it should: ${problems}"
fi
docker exec "${name}" grep -qx "Map=${map_line}" "${home}/Server/pzserver.ini" \
  || map_failed "after the first start Map= is not ${map_line} but $(docker exec "${name}" grep '^Map=' "${home}/Server/pzserver.ini")"
docker exec "${name}" grep -qF "{ name = \"${map}\", file = \"media/maps/${map}/spawnpoints.lua\" }," "${home}/Server/pzserver_spawnregions.lua" \
  || map_failed "after the first start pzserver_spawnregions.lua has no spawn region for ${map}"
if [[ "${version}" != 41.* ]]; then
  region_taken=false
  if grep -q 'Mannequin zone missing properties in media/maps/Muldraugh, KY/regions.lua' <<< "${logs}"; then
    region_taken=true
    echo "The game's map zone loader takes a zone that goes to Java without x and y"
  else
    echo "::warning title=Zone check::On ${label} a zone that goes to Java without x and y stops the game's map zone loading, so map_zone_warnings misses those zones and should count them too."
  fi
  zone_logged() {
    # $1 = the mannequin zone's x and y; the game logs "coords: 3, 3, 0" since 42.16, "at 3,3,0" before
    grep -qE "Mannequin zone missing properties in media/maps/BootZones/objects\.lua (coords: $1(\.0)?, |at $1(\.0)?,)" <<< "${logs}"
  }
  zone_lines="$(grep -E ' media/maps/BootZones/objects\.lua|handleWaterZone' <<< "${logs}" || true)"
  zone_warned=false
  grep -qF "Warning: the game fails on the zone at ${zone_file}:3 and stops loading map zones there" <<< "${logs}" && zone_warned=true
  if ! zone_logged 3; then
    [ "${region_taken}" = false ] \
      || fail "the game's map zone loader, which reads the maps from the last in Map= to the first, did not get to media/maps/BootZones/objects.lua, so the zone check's canary tested nothing. The log's lines for that file: ${zone_lines:-none}"
    canary "Zone check" held "the game's map zone loader stops loading map zones at a zone that goes to Java without x and y in media/maps/Muldraugh, KY/regions.lua, before it gets to the polygon water zone" "${zone_remove}"
  elif zone_logged 4; then
    canary "Zone check" fired "the game's map zone loader takes a polygon water zone without properties and loads the zones after it$([ "${zone_warned}" = false ] || echo ", although the image still warned about it")" "${zone_remove}"
  elif grep -q 'handleWaterZone' <<< "${logs}"; then
    [ "${zone_warned}" = true ] \
      || fail "the game failed in handleWaterZone on the polygon water zone at media/maps/BootZones/objects.lua:3 and stopped loading map zones there, but the image did not warn about that zone. Its zone warnings: $(grep -A 3 '^Warning: the game fails on the zone' <<< "${logs}" || echo none)"
    canary "Zone check" held "the game's map zone loader still fails on a polygon water zone without properties in handleWaterZone" "${zone_remove}"
  else
    fail "the game's map zone loader stopped at the polygon water zone in media/maps/BootZones/objects.lua without failing in handleWaterZone. The log's lines for that file: ${zone_lines}"
  fi
else
  canary "Zone check" n/a "the game has another map zone loader, which the zone check leaves alone" "${zone_remove}"
fi
stop_server 1

# SteamCMD writes its download of a new item next to those of the server and its own, and the server
# has to take all of them as installed rather than download them again.
docker rm -f "${name}" >/dev/null
docker run -d --name "${name}" --health-interval=5s \
  -v "${game_volume}:/home/steam/pz-dedicated" -v "${home_volume}:${home}" -e GAME_BRANCH="${branch}" \
  -e GAME_UPDATE=false -e WORKSHOP_IDS="${server_item};${map_item};${new_item}" -e INI_Mods="${mods}" "${image}" >/dev/null
wait_healthy || fail "the server exited before it started with workshop item ${new_item} added"
logs="$(docker logs "${name}" 2>&1)"
grep -qx 'Workshop: downloaded 1 new item with SteamCMD' <<< "${logs}" \
  || fail "the image did not download the added workshop item ${new_item} with SteamCMD"
for item in "${server_item}" "${map_item}" "${new_item}"; do
  grep -qE "Workshop: ${item} installed to .*steamapps/workshop/content/108600/${item}/?\$" <<< "${logs}" \
    && ! grep -q "Workshop: item state .* -> DownloadPending ID=${item}\$" <<< "${logs}" \
    || fail "after SteamCMD downloaded workshop item ${new_item}, the server did not take ${item} as installed: $(grep -E "Workshop: .*${item}|timeUpdated" <<< "${logs}")"
done
# MOD_UPDATE_CHECK restarts the server on these answers, read after the game's log prefix.
docker exec "${name}" console checkModsNeedUpdate >/dev/null
docker exec "${name}" console players >/dev/null
answer='> CheckModsNeedUpdate: (Mods need update|Mods updated|Check not completed)$'
for _ in $(seq 1 30); do
  logs="$(docker logs "${name}" 2>&1)"
  grep -qE "${answer}" <<< "${logs}" && break
  sleep 2
done
grep -qE "${answer}" <<< "${logs}" \
  || fail "the server did not answer checkModsNeedUpdate as MOD_UPDATE_CHECK expects: $(grep CheckModsNeedUpdate <<< "${logs}")"
grep -qE '> Players connected \(0\):' <<< "${logs}" \
  || fail "the server did not answer players as MOD_UPDATE_CHECK expects: $(grep 'Players connected' <<< "${logs}")"
stop_server 1
docker rm -f "${name}" >/dev/null

# The hidden item filter's canary: the start before with one more item, which Steam answers with
# result 9, set with INI_WorkshopItems, which the image leaves as it is. The game stops when an item
# fails to install (GameServerWorkshopItems), on Build 42 with a NullPointerException.
# An ID Steam never issued: it answers 9 like a hidden item, and nobody can make it public again.
hidden_item=99999999999
hidden_remove="remove the result-9 branch of apply_workshop_ids (scripts/lib/mods.sh) and its warnings, the README sentence on items that are removed, hidden or private, its cases in test_workshop (smoke/run_smoke.sh) and this canary in ci/boot_test.sh."
hidden_result="$(curl -fsS --retry 3 --retry-all-errors --max-time 30 -X POST -d itemcount=1 -d "publishedfileids[0]=${hidden_item}" \
  https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/ | jq -r '.response.publishedfiledetails[0].result')" \
  || fail "could not look up workshop item ${hidden_item} with Steam's API"
[ "${hidden_result}" = 9 ] \
  || fail "Steam's API answers result ${hidden_result} for workshop item ${hidden_item}, not 9 (removed, hidden or private), so the image would not leave it out; the hidden item filter's canary needs an ID it answers with 9"
docker run -d --name "${name}" --health-interval=5s \
  -v "${game_volume}:/home/steam/pz-dedicated" -v "${home_volume}:${home}" -e GAME_BRANCH="${branch}" -e GAME_UPDATE=false \
  -e INI_WorkshopItems="${server_item};${map_item};${new_item};${hidden_item}" -e INI_Mods="${mods}" "${image}" >/dev/null
if wait_healthy; then
  logs="$(docker logs "${name}" 2>&1)"
  grep -qE "Workshop: .*ID=${hidden_item}( |\$)" <<< "${logs}" \
    || fail "the server started with workshop item ${hidden_item} in WorkshopItems, but its log doesn't show that it tried to install it"
  canary "Hidden item filter" fired "the server starts with workshop item ${hidden_item} in WorkshopItems, which Steam answers with result 9" "${hidden_remove}"
  stop_server 1
else
  logs="$(docker logs "${name}" 2>&1)"
  hidden_lines="$(grep -E "Workshop: (.*ID=${hidden_item}( |\$)|${hidden_item} )" <<< "${logs}" || echo none)"
  grep -qE "Workshop: item state [A-Za-z]+ -> Fail ID=${hidden_item}\$" <<< "${logs}" \
    || fail "with workshop item ${hidden_item} in WorkshopItems the server exited before it started, but its log doesn't show that the item failed to install. The log's lines for the item: ${hidden_lines}"
  grep -q "Workshop: ${hidden_item} installed to " <<< "${logs}" \
    && fail "with workshop item ${hidden_item} in WorkshopItems the server exited before it started, but after it had installed its workshop items, that one included. The log's lines for the item: ${hidden_lines}"
  hidden_finding="the server still stops when a workshop item that Steam answers with result 9 fails to install"
  grep -q "Workshop: onItemNotDownloaded itemID=${hidden_item} result=9\$" <<< "${logs}" \
    && hidden_finding+=": its download ended with result 9"
  grep -q 'NullPointerException' <<< "${logs}" && hidden_finding+=", followed by a NullPointerException"
  canary "Hidden item filter" held "${hidden_finding}" "${hidden_remove}"
fi
docker rm -f "${name}" >/dev/null

# The game stops when it runs out of inotify watches in its media folder or in a mod folder. With a
# limit of one and a half times the folders of its media folder and a mod with twice as many, the
# media folder fits and the mod alone doesn't, so these starts run out where a real server's mods make
# the game run out. It only stops when that happens before the last mods folder it lists, Zomboid/mods,
# so the mod is a local workshop item in Zomboid/Workshop, which it lists first; the image doesn't read
# those and warns that it can't find the mod. Without update checks these starts are quick.
start_low_limit() {
  # $@ = more docker run options
  docker rm -f "${name}" >/dev/null
  docker run -d --name "${name}" --health-interval=5s \
    -v "${game_volume}:/home/steam/pz-dedicated" -v "${home_volume}:${home}" -e GAME_BRANCH="${branch}" \
    -e GAME_UPDATE=false -e ADMINPASSWORD=boot-test -e INI_Mods=BootWatch "$@" "${image}" >/dev/null
}
media_dirs="$(docker run --rm -v "${game_volume}:/home/steam/pz-dedicated" --entrypoint find "${image}" \
  /home/steam/pz-dedicated/media -type d | wc -l)"
mod="${home}/Workshop/BootWatch/Contents/mods/BootWatch"
# Build 41 reads mod.info and media/ in the mod folder, Build 42 those in common/.
[[ "${version}" == 41.* ]] || mod="${mod}/common"
docker volume rm -f "${home_volume}" >/dev/null
docker run --rm -v "${home_volume}:${home}" --entrypoint bash "${image}" -c \
  'mkdir -p "$1/media" && printf "name=BootWatch\nid=BootWatch\n" > "$1/mod.info" && cd "$1/media" && seq "$2" | xargs mkdir' \
  _ "${mod}" "$((media_dirs * 2))"
low_limit=$((media_dirs * 3 / 2))
watch_limit="$(< /proc/sys/fs/inotify/max_user_watches)"
echo "Lowering the inotify watch limit from ${watch_limit} to ${low_limit}; the game's media folder has ${media_dirs} folders"
sudo sysctl -q -w "fs.inotify.max_user_watches=${low_limit}"

start_low_limit
wait_healthy || fail "the server stopped with ${low_limit} inotify watches, although the image should turn the game's file watcher off"
grep -q "file watcher is off for this start" <<< "$(docker logs "${name}" 2>&1)" \
  || fail "the image did not say that it turned the game's file watcher off with ${low_limit} inotify watches"
stop_server 1

# The file watcher workaround's canary
watcher_remove="remove shim/ and its rule in .gitignore, its paths in .github/workflows/docker-image.yml, the Dockerfile's shim stage and its COPY --from=shim line, scripts/lib/watcher.sh and its call in scripts/configure.sh, GAME_FILE_WATCHER in scripts/vars.tsv, the README paragraph on inotify watches, test_file_watcher (smoke/run_smoke.sh) and the low-limit starts in ci/boot_test.sh."
start_low_limit -e GAME_FILE_WATCHER=true
if wait_healthy; then
  canary "File watcher" fired "the game no longer stops when it runs out of inotify watches" "${watcher_remove}"
  stop_server 1
else
  logs="$(docker logs "${name}" 2>&1)"
  grep -q "User limit of inotify watches reached" <<< "${logs}" && grep -q "Server Terminated" <<< "${logs}" \
    || fail "with the file watcher on, the server exited before it started, but not because it ran out of inotify watches"
  canary "File watcher" held "the game still stops when it runs out of inotify watches" "${watcher_remove}"
fi
sudo sysctl -q -w "fs.inotify.max_user_watches=${watch_limit}"
watch_limit=""
echo "Boot test passed"
