#!/bin/bash
# Boots an image on a game branch and checks that it installs the game, starts the
# server, keeps settings written before its first start, creates its database and saves on
# `docker stop`, then starts it again to check the update and the settings against the files the
# server wrote. On Build 42 a start with a test mod checks how the game's map zone loader takes a zone
# without x and y. Then, with the host's inotify watch limit below what the game watches with a mod, it
# checks that the image turns the game's file watcher off, and whether the game still needs that. That
# limit holds for every user of the host for a few minutes, a desktop's programs included. Writes the
# env reference for the docs site to <out dir>/<branch>-<build id>.json, with the image version from
# its org.opencontainers.image.version label.
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
# The server logs its version at startup; java.version and the like are not it.
version="$(docker logs "${name}" 2>&1 | grep -oE '(versionNumber=|[[:space:]>]version=|ZNet: Startup version )[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 | sed 's/.*[= ]//' || true)"
# list-mods reads it from Zomboid/server-console.txt the same way.
[ -n "${version}" ] || fail "the log does not show the game version, so list-mods can't find it either"
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
mkdir -p "${out_dir}"
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
# From the second start the game version is known, so the maps in Map= are checked, the game's own too.
logs="$(docker logs "${name}" 2>&1)"
grep -qx 'Config: Map is Muldraugh, KY' <<< "${logs}" || fail "the second start did not name the maps in Map="
grep -q 'stops loading map zones' <<< "${logs}" && fail "the zone check failed the game's own map"
# Once the database exists the admin password must stay out of the command line.
docker exec "${name}" sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" " "' | grep -q -- '-adminpassword' \
  && fail "-adminpassword was passed although the database exists"
stop_server 2

# map_zone_warnings counts the zones the zone loader's Lua code fails on, not those it passes to Java
# without x and y. This start finds out whether the game takes those: a mod's regions.lua for the vanilla map
# has a polygon Region zone, which goes to Java without x and y, and after it a mannequin zone without
# properties, which the game logs. Build 41 has another zone loader.
if [[ "${version}" != 41.* ]]; then
  docker rm -f "${name}" >/dev/null
  docker volume rm -f "${home_volume}" >/dev/null
  docker run --rm -v "${home_volume}:${home}" --entrypoint bash "${image}" -c \
    'mkdir -p "$1/media/maps/Muldraugh, KY" && printf "id=BootZones\n" > "$1/mod.info" \
      && printf "%s\n" "regions = {" "$2" "$3" "}" > "$1/media/maps/Muldraugh, KY/regions.lua"' \
    _ "${home}/mods/BootZones/common" \
    '{ name = "", type = "Region", z = 0, geometry = "polygon", points = { 10,10, 20,10, 20,20 } },' \
    '{ name = "", type = "Mannequin", x = 1, y = 1, z = 0, width = 1, height = 1 },'
  docker run -d --name "${name}" --health-interval=5s \
    -v "${game_volume}:/home/steam/pz-dedicated" -v "${home_volume}:${home}" -e GAME_BRANCH="${branch}" \
    -e GAME_UPDATE=false -e ADMINPASSWORD=boot-test -e INI_Mods=BootZones "${image}" >/dev/null
  wait_healthy || fail "the server with the BootZones mod exited before it started"
  if grep -q 'Mannequin zone missing properties in media/maps/Muldraugh, KY/regions.lua' <<< "$(docker logs "${name}" 2>&1)"; then
    echo "The game's map zone loader takes a zone that goes to Java without x and y"
  else
    echo "::warning title=Zone check::On ${label} a zone that goes to Java without x and y stops the game's map zone loading, so map_zone_warnings misses those zones and should count them too."
  fi
  stop_server 1
  docker rm -f "${name}" >/dev/null
fi

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

start_low_limit -e GAME_FILE_WATCHER=true
if wait_healthy; then
  echo "::warning title=File watcher workaround::On ${label} the game no longer stops when it runs out of inotify watches, so once every game version the image supports does the same, GAME_FILE_WATCHER and shim/ can be removed."
  stop_server 1
else
  logs="$(docker logs "${name}" 2>&1)"
  grep -q "User limit of inotify watches reached" <<< "${logs}" && grep -q "Server Terminated" <<< "${logs}" \
    || fail "with the file watcher on, the server exited before it started, but not because it ran out of inotify watches"
  echo "With the file watcher on, the game still stops when it runs out of inotify watches"
fi
sudo sysctl -q -w "fs.inotify.max_user_watches=${watch_limit}"
watch_limit=""
echo "Boot test passed"
