#!/bin/bash
# Installs the game into STEAMAPPDIR from the Steam branch in GAME_BRANCH and keeps it up to date,
# reads its version and downloads new workshop items before it starts.

VERSION_READER=/usr/local/lib/read_game_version.jar

game_build() {
  sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' \
    "${STEAMAPPDIR}/steamapps/appmanifest_${STEAMAPPID}.acf" 2>/dev/null | head -n 1
}

update_game() {
  local branch="${GAME_BRANCH:-public}" marker="${STEAMAPPDIR}/.game-branch" installed="" log status
  local beta_args=() validate=()
  [ -f "${marker}" ] && installed="$(<"${marker}")"

  if [ -f "${STEAMAPPDIR}/start-server.sh" ] && [ "${installed}" = "${branch}" ] && ! is_true "${GAME_UPDATE:-true}"; then
    echo "Game: ${branch} branch, build $(game_build), not checked for updates (GAME_UPDATE=false)"
    return 0
  fi

  # "-beta public" is not a valid beta, so the flag is only passed for other branches.
  [ "${branch}" = public ] || beta_args=(-beta "${branch}")
  if [ -f "${STEAMAPPDIR}/start-server.sh" ] && [ "${installed}" != "${branch}" ]; then
    # Without -beta SteamCMD keeps updating from the beta it last installed, so it has to forget
    # the install and check every file against the new branch.
    echo "Game: switching from the ${installed:-unknown} branch to ${branch}"
    rm -f "${STEAMAPPDIR}/steamapps/appmanifest_${STEAMAPPID}.acf"
    validate=(validate)
  fi

  echo "Game: installing or updating the ${branch} branch with SteamCMD"
  log="$(mktemp)"
  # SteamCMD can fail the first attempt with "Missing configuration" until the app info is cached.
  for attempt in 1 2 3; do
    # In the background, so a stop signal doesn't wait for a download to finish.
    (
      set -o pipefail
      "${STEAMCMDDIR}/steamcmd.sh" +force_install_dir "${STEAMAPPDIR}" +login anonymous \
        +app_update "${STEAMAPPID}" "${beta_args[@]}" "${validate[@]}" +quit 2>&1 | tee "${log}"
    ) &
    status=0
    wait "$!" || status=$?
    # SteamCMD doesn't end its output with a newline, so the next line would be appended to its last.
    [ -z "$(tail -c 1 "${log}")" ] || echo
    if [ "${status}" = 0 ] && grep -q "Success! App '${STEAMAPPID}'" "${log}" && [ -f "${STEAMAPPDIR}/start-server.sh" ]; then
      rm -f "${log}"
      printf '%s\n' "${branch}" > "${marker}"
      echo "Game: ${branch} branch, build $(game_build)"
      return 0
    fi
    [ "${attempt}" = 3 ] || sleep 10
  done
  rm -f "${log}"
  echo "Error: SteamCMD could not install or update the ${branch} branch of the game; its output is above." >&2
  if [ -f "${STEAMAPPDIR}/start-server.sh" ] && [ "${installed}" = "${branch}" ]; then
    echo "GAME_UPDATE=false starts the installed game without updating it." >&2
  fi
  exit 1
}

game_version() {
  # Prints the version of the installed game as the server logs it (major.minor.build), read from its
  # files with its own Java, or else why it can't, and fails.
  local why status=0
  local -a classpath=()
  mapfile -t classpath < <(jq -r '.classpath[]' "${STEAMAPPDIR}/ProjectZomboid64.json" 2> /dev/null)
  if [ "${#classpath[@]}" = 0 ]; then
    echo "${STEAMAPPDIR}/ProjectZomboid64.json is missing or lists no classpath"
    return 1
  fi
  # The version goes to stdout; what the JVM says on stderr only counts when it fails. The JVM would
  # announce the options in these variables there. The classpath is relative to the game folder.
  { why="$(cd "${STEAMAPPDIR}" && env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS -u _JAVA_OPTIONS \
    "${STEAMAPPDIR}/jre64/bin/java" -jar "${VERSION_READER}" "${classpath[@]}" 2>&1 >&3)" || status=$?; } 3>&1
  [ "${status}" = 0 ] || printf '%s\n' "${why}"
  return "${status}"
}

# The server downloads the items in WorkshopItems while it starts, too late for the maps and spawn
# regions of their mods, so the ones not on disk yet are downloaded before. The server takes them as
# installed, and updates the items itself.
download_workshop_items() {
  # $1 = INI file, $2 = workshop content dir
  local ini_file="$1" content_dir="$2" item log attempt count
  local -a missing=() failed=() tried=() args=()
  # Without Steam the server doesn't use workshop items.
  is_true "${NOSTEAM:-}" && return 0
  # The server skips entries that are no Steam ID.
  while IFS= read -r item; do
    [ -d "${content_dir}/${item}" ] || missing+=("${item}")
  done < <(split_list "$(ini_value "${ini_file}" WorkshopItems)" | awk '/^[0-9]+$/ && !seen[$0]++')
  [ "${#missing[@]}" -gt 0 ] || return 0

  echo "Workshop: downloading ${#missing[@]} new item$([ "${#missing[@]}" = 1 ] || echo s) with SteamCMD"
  log="$(mktemp)"
  failed=("${missing[@]}")
  for attempt in 1 2 3; do
    args=()
    for item in "${failed[@]}"; do
      args+=(+workshop_download_item 108600 "${item}")
    done
    # In the background, so a stop signal doesn't wait for a download to finish.
    (
      "${STEAMCMDDIR}/steamcmd.sh" +force_install_dir "${STEAMAPPDIR}" +login anonymous "${args[@]}" +quit 2>&1 | tee "${log}"
    ) &
    wait "$!"
    # SteamCMD doesn't end its output with a newline, so the next line would be appended to its last.
    [ -z "$(tail -c 1 "${log}")" ] || echo
    tried=("${failed[@]}")
    failed=()
    for item in "${tried[@]}"; do
      grep -qF "Success. Downloaded item ${item} " "${log}" && [ -d "${content_dir}/${item}" ] || failed+=("${item}")
    done
    [ "${#failed[@]}" -gt 0 ] || break
    [ "${attempt}" = 3 ] || sleep 10
  done
  rm -f "${log}"
  count=$((${#missing[@]} - ${#failed[@]}))
  [ "${count}" = 0 ] || echo "Workshop: downloaded ${count} new item$([ "${count}" = 1 ] || echo s) with SteamCMD"
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "Warning: SteamCMD could not download these workshop items (its output is above), so the server downloads them while it starts and their maps are added on the start after: ${failed[*]}" >&2
  fi
  return 0
}
