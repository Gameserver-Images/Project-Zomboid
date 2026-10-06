#!/bin/bash
# Applies the environment to the server's config files, downloads new workshop items and builds ARGS
# and the game's LD_PRELOAD. Sourced by entry.sh, which also installs the game with lib/game.sh and
# follows the server's output with lib/output.sh.

# shellcheck source=scripts/lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/game.sh
. "${SCRIPT_DIR}/lib/game.sh"
# shellcheck source=scripts/lib/mods.sh
. "${SCRIPT_DIR}/lib/mods.sh"
# shellcheck source=scripts/lib/maps.sh
. "${SCRIPT_DIR}/lib/maps.sh"
# shellcheck source=scripts/lib/args.sh
. "${SCRIPT_DIR}/lib/args.sh"
# shellcheck source=scripts/lib/watcher.sh
. "${SCRIPT_DIR}/lib/watcher.sh"
# shellcheck source=scripts/lib/output.sh
. "${SCRIPT_DIR}/lib/output.sh"

apply_preset() {
  # $1 = SandboxVars file
  local lua_file="$1" preset_dir="${STEAMAPPDIR}/media/lua/shared/Sandbox"
  [ -n "${SERVERPRESET:-}" ] || return 0
  if [ ! -f "${preset_dir}/${SERVERPRESET}.lua" ]; then
    echo "Error: the preset ${SERVERPRESET} does not exist." >&2
    echo "Available presets: $(find "${preset_dir}" -maxdepth 1 -name '*.lua' -printf '%f\n' | sed 's/\.lua$//' | sort | paste -sd ' ')" >&2
    exit 1
  fi
  if [ -f "${lua_file}" ] && ! is_true "${SERVERPRESETREPLACE:-}"; then
    return 0
  fi
  # Presets are `return { ... }` modules; the server file assigns the same table to SandboxVars.
  sed -e '1s/^return.*/SandboxVars = {/' -e 's/\r$//' "${preset_dir}/${SERVERPRESET}.lua" > "${lua_file}"
  echo "Config: SandboxVars created from the ${SERVERPRESET} preset"
}

check_locale() {
  local wanted
  [ -n "${LANG:-}" ] || return 0
  wanted="$(tr '[:upper:]' '[:lower:]' <<< "${LANG}" | tr -d '-')"
  if ! locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' | grep -qxF "${wanted}"; then
    echo "Warning: LANG=${LANG} is not installed in this image. Installed: $(locale -a 2>/dev/null | paste -sd ' ')" >&2
  fi
}

configure_server() {
  local server_dir="${HOMEDIR}/Zomboid/Server"
  local ini_file="${server_dir}/${SERVERNAME}.ini"
  local lua_file="${server_dir}/${SERVERNAME}_SandboxVars.lua"
  local spawn_file="${server_dir}/${SERVERNAME}_spawnregions.lua"
  local db_file="${HOMEDIR}/Zomboid/db/${SERVERNAME}.db"
  local content_dir="${STEAMAPPDIR}/steamapps/workshop/content/108600"
  local admin_password="" mods version

  if version="$(game_version)"; then
    echo "Game: version ${version}"
  else
    echo "Warning: could not read the game version from the game files: ${version}" >&2
    echo "         So this start leaves the maps and spawn regions of mods as they are, only checks that the mods in Mods= are on disk, doesn't check Map=, and can't count the folders the game's file watcher watches." >&2
    version=""
  fi
  check_locale
  report_unrecognized "${SCRIPT_DIR}/image-env"
  report_overlaps

  # The server keeps the values in an existing INI and fills in the rest, so creating it lets
  # settings apply on the very first start.
  mkdir -p "${server_dir}"
  [ -f "${ini_file}" ] || touch "${ini_file}"
  # The game writes it while it starts (Build 41 only without an INI), too late for the spawn regions
  # of mods.
  [ -f "${spawn_file}" ] || write_spawn_regions "${spawn_file}"

  apply_preset "${lua_file}"
  # The game's UPnP can't reach the router from Docker's bridge network and delays every start by 12s.
  grep -qixE 'INI_UPnP(_FILE)?' <<< "$(compgen -e)" || export INI_UPnP=false
  apply_ini_env "${ini_file}"

  apply_workshop_ids "${ini_file}" "${content_dir}"
  download_workshop_items "${ini_file}" "${content_dir}"
  mods="$(load_mods "${ini_file}" "${content_dir}" "${version}")"
  apply_mod_maps "${ini_file}" "${spawn_file}" "${content_dir}" "${mods}" "${version}"
  check_maps "${ini_file}" "${mods}" "${version}"
  apply_sandbox_env "${lua_file}"

  # The admin account lives in the server database, so the password is only needed to create it.
  if [ ! -f "${db_file}" ]; then
    admin_password="$(read_secret ADMINPASSWORD ADMINPASSWORD_FILE)"
    if [ -z "${admin_password}" ]; then
      echo "Error: ADMINPASSWORD (or ADMINPASSWORD_FILE) is required on the first start to create the admin account." >&2
      exit 1
    fi
  fi
  configure_file_watcher /proc/sys/fs/inotify/max_user_watches "${ini_file}" "${content_dir}" "${mods}"
  build_server_args "${admin_password}"
}
