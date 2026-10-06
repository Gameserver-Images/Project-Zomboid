#!/bin/bash
# Turns off the game's file watcher for a start when the game could run out of inotify watches.

# The game watches its media folder and Zomboid/messaging with every directory in them
# (DebugFileWatcher). Once Mods= names a mod, it also watches Zomboid/mods, the mods folder of each
# workshop item and each mod folder it finds, with every directory in the media folders of the mod's
# version folder and common/ (ZomboidFileSystem.getAllModFolders).
watched_dirs() {
  # $1 = INI file, $2 = workshop content dir, $3 = what load_mods printed. Prints how many directories
  # the game watches. Fails when that leaves out mods: those of workshop items still to download, or
  # all of them while the game version is unknown.
  local ini_file="$1" content_dir="$2" rows item dir folders=0 missing=0
  local -a trees=("${STEAMAPPDIR}/media" "${HOMEDIR}/Zomboid/messaging")
  if [ -n "$(split_list "$(ini_value "${ini_file}" Mods)")" ]; then
    folders=1
    while IFS= read -r item; do
      [ -d "${content_dir}/${item}" ] || missing=1
      [ -d "${content_dir}/${item}/mods" ] && folders=$((folders + 1))
    done < <(split_list "$(ini_value "${ini_file}" WorkshopItems)" | sort -u)
    rows="$(cut -f 2- <<< "$3")"
    awk -F '\t' '$4 == "?" { exit 1 }' <<< "${rows}" || missing=1
    folders=$((folders + $(awk -F '\t' '$3 != ""' <<< "${rows}" | wc -l)))
    while IFS=$'\t' read -r _ _ _ dir; do
      trees+=("${dir}/media")
    done < <(mod_dirs <<< "${rows}")
  fi
  echo $((folders + $(find -H "${trees[@]}" -type d 2>/dev/null | wc -l)))
  return "${missing}"
}

# GAME_FILE_WATCHER=auto turns the watcher off when the game could run out of watches, true keeps it
# on and false keeps it off. Off preloads a library that makes the JDK's inotify watches succeed
# without watching anything.
configure_file_watcher() {
  # $1 = file holding the host's inotify watch limit, $2 = INI file, $3 = workshop content dir,
  # $4 = what load_mods printed
  local limit_file="$1" setting="${GAME_FILE_WATCHER:-auto}" limit dirs counted=true size=524288
  if [ "${setting,,}" != auto ]; then
    is_true "${setting}" && return 0
  else
    # Without it there is no limit to check against.
    [ -f "${limit_file}" ] || return 0
    limit="$(<"${limit_file}")"
    dirs="$(watched_dirs "$2" "$3" "$4")" || counted=false
    # The limit is per user on the host and shared with every program of the same uid, such as a
    # second server, so the game leaves them half.
    if [ "$((dirs * 2))" -le "${limit}" ]; then
      # The watcher only reloads files that change, so it's off rather than risk the start.
      [ "${counted}" = false ] || return 0
      echo "Config: the game's file watcher is off for this start, as its mod folders can't be counted before every workshop item is downloaded and the game version is known"
    else
      while [ "${size}" -lt "$((dirs * 2))" ]; do
        size=$((size * 2))
      done
      cat >&2 <<EOF
Warning: the game would watch ${dirs} folders for file changes, more than half of the ${limit} inotify watches per user that the host allows (fs.inotify.max_user_watches).
         Every program of the container's user on the host shares that limit, and running out stops the server while it starts.
         So the game's file watcher is off for this start; it only reloads game and mod files that change while the server runs.
         To keep it on, raise the limit on the Docker host, not in the container:
           sudo sysctl -w fs.inotify.max_user_watches=${size}
           echo 'fs.inotify.max_user_watches=${size}' | sudo tee /etc/sysctl.d/90-inotify.conf
         GAME_FILE_WATCHER=false turns it off without this warning.
EOF
    fi
  fi
  # start-server.sh adds its own library to LD_PRELOAD.
  export LD_PRELOAD="/usr/local/lib/no_file_watcher.so${LD_PRELOAD:+:${LD_PRELOAD}}"
}
