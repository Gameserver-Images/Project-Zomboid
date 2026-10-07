#!/bin/bash
# Follows the server's output. With MOD_UPDATE_CHECK it also restarts the server when its workshop
# items have updates: players can't join while the server has an older version of an item than the
# workshop, and the server only updates its items when it starts. It also explains the game's line
# for a player whose files fail its checksum, as that line names neither the file nor the cause.

mod_update_interval() {
  # Prints MOD_UPDATE_CHECK in seconds, nothing when it is empty, or fails when it is no duration.
  local value="${MOD_UPDATE_CHECK:-}"
  [ -n "${value}" ] || return 0
  if [[ ! "${value,,}" =~ ^0*([1-9][0-9]{0,5})([smh])$ ]]; then
    echo "Error: MOD_UPDATE_CHECK=${value} is not a duration such as 30s, 15m or 1h. Leave it empty to turn the check off." >&2
    return 1
  fi
  case "${BASH_REMATCH[2]}" in
    s) echo "${BASH_REMATCH[1]}" ;;
    m) echo "$((BASH_REMATCH[1] * 60))" ;;
    h) echo "$((BASH_REMATCH[1] * 3600))" ;;
  esac
}

in_words() {
  # $1 = seconds
  local count="$1" unit=second
  if [ "$(($1 % 60))" = 0 ]; then
    count=$(($1 / 60)) unit=minute
  fi
  echo "${count} ${unit}$([ "${count}" = 1 ] || echo s)"
}

restart_warnings() {
  # $1 = seconds to the restart. Prints how long before the restart the players are warned, the first
  # warning right away.
  local at
  echo "$1"
  for at in 60 10; do
    [ "${at}" -ge "$1" ] || echo "${at}"
  done
}

# The restart is a `quit`, so the server saves the world and the container exits for its restart policy.
follow_output() {
  # $1 = ready file, $2 = console fd, $3 = seconds between update checks (empty: no checks)
  local ready="$1" console="$2" interval="$3" line="" part status now online delay restart_at player
  # The step that is due next (check, players, warn or quit) and when.
  local step="" due=""
  local -a timeout warnings
  # The answers follow the log prefix, which has two "> " on Build 41 and one on Build 42. Cutting it
  # off with ${line##*> } would take quadratic time on long lines.
  local player_count='> Players connected \(([0-9]+)\):'
  # Only right after the log prefix, so that no other line that ends like it counts. Build 41's prefix ends with the
  # server time in the server's locale (1,234,567 or 1.234.567); 42.20 adds "in <N>ms".
  local checksum_kick='^[^>]*> ([0-9][^ >]*> )?user (.+) will be kicked (in [0-9]+ms )?because Lua/script checksums do not match$'
  local -A explained=()
  while true; do
    timeout=()
    if [ -n "${due}" ]; then
      now="${EPOCHSECONDS}"
      if [ "${due}" -le "${now}" ]; then
        case "${step}" in
          check)
            printf 'checkModsNeedUpdate\n' >&"${console}"
            due=$((now + interval)) ;;
          # No player count came, so the check is due again.
          players) step=check ;;
          warn)
            printf 'servermsg "The server restarts in %s to update mods."\n' "$(in_words "${warnings[0]}")" >&"${console}"
            warnings=("${warnings[@]:1}")
            due=$((restart_at - ${warnings[0]:-0}))
            [ "${#warnings[@]}" -gt 0 ] || step=quit ;;
          quit)
            printf 'quit\n' >&"${console}"
            step="" due="" ;;
        esac
        continue
      fi
      timeout=(-t "$((due - now))")
    fi
    status=0
    IFS= read -r "${timeout[@]}" part || status=$?
    line+="${part}"
    # A timeout can end the read within a line.
    [ "${status}" -le 128 ] || continue
    [ "${status}" = 0 ] || [ -n "${line}" ] || break
    printf '%s\n' "${line}"
    if [[ "${line}" == *"*** SERVER STARTED ***"* ]]; then
      : > "${ready}"
      # A console command the server echoes can hold that text too.
      [ -z "${interval}" ] || [ -n "${step}" ] || step=check due=$((EPOCHSECONDS + interval))
    elif [ "${step}" = check ] && [[ "${line}" == *"> CheckModsNeedUpdate: Mods need update" ]]; then
      printf 'players\n' >&"${console}"
      step=players due=$((EPOCHSECONDS + interval))
    elif [ "${step}" = players ] && [[ "${line}" =~ ${player_count} ]]; then
      online="${BASH_REMATCH[1]}"
      if [ "${online}" = 0 ]; then
        echo "Workshop: items have updates, so the server restarts now to download them, as no player is online"
        step=quit
      else
        delay=$((interval < 300 ? interval : 300))
        echo "Workshop: items have updates, so the server restarts in $(in_words "${delay}") to download them, after warning the ${online} player$([ "${online}" = 1 ] || echo s) online"
        mapfile -t warnings < <(restart_warnings "${delay}")
        restart_at=$((EPOCHSECONDS + delay)) step=warn
      fi
      due="${EPOCHSECONDS}"
    elif [[ "${line}" == *" because Lua/script checksums do not match" && "${line}" =~ ${checksum_kick} ]]; then
      player="${BASH_REMATCH[2]}"
      if [ -z "${explained[${player}]:-}" ]; then
        explained[${player}]=1
        # On stdout with the server's lines, so that the log keeps it right after the line it explains.
        echo "Warning: ${player} can't join: their files differ from the server's (other versions of mods, other or changed files, or another load order)."
        echo "         The message on their screen names the first file that differs. \"File doesn't exist on the client\" followed by where that file is on their PC means they have it but load"
        echo "         their mods in another order, which happens when something on their PC reorders mods: ask them what, then put the mods it moves first in INI_Mods, in its order, or have them turn that off."
      fi
    fi
    [ "${status}" = 0 ] || break
    line=""
  done
}
