#!/bin/bash
# Prints "<branch> <build id>" for the Steam branches CI boot-tests: every branch without a
# password, the same list as the game's "Betas" tab in Steam. Asks SteamCMD in the base image, or
# reads a saved app_info_print output.
# Usage: game_branches.sh [app_info_print output file]

set -euo pipefail

if [ -n "${1:-}" ]; then
  info="$(<"$1")"
# The base image's SteamCMD is a 32-bit build, whose sockets Docker 29's default seccomp profile refuses.
elif ! info="$(docker run --rm --security-opt seccomp=unconfined cm2network/steamcmd:root bash -c \
  '"${STEAMCMDDIR}/steamcmd.sh" +login anonymous +app_info_update 1 +app_info_print 380870 +quit')"; then
  echo "Error: SteamCMD failed to print the app info. The end of its output:" >&2
  tail -n 30 <<< "${info}" >&2
  exit 1
fi

branches="$(awk '
  { line = $0; gsub(/[\r"]/, "", line); sub(/^[ \t]+/, "", line) }
  !done && line == "branches" { inside = 1; depth = 0; next }
  inside && line == "{" { depth++; next }
  inside && line == "}" && depth == 2 && build != "" && !pwd { print name, build }
  inside && line == "}" { if (--depth == 0) { inside = 0; done = 1 } next }
  inside && depth == 1 && line !~ /[ \t]/ { name = line; build = ""; pwd = 0; next }
  inside && depth == 2 && line ~ /^buildid[ \t]/ { split(line, f, /[ \t]+/); build = f[2] }
  inside && depth == 2 && line ~ /^pwdrequired[ \t]+1$/ { pwd = 1 }
' <<< "${info}")"

echo "Steam branches: $(cut -d' ' -f1 <<< "${branches}" | paste -sd ' ')" >&2
selected="$(grep -E '^[A-Za-z0-9._-]+ [0-9]+$' <<< "${branches}" || true)"
public_build="$(sed -n 's/^public //p' <<< "${selected}")"
if [ -z "${public_build}" ]; then
  echo "Error: no build id for the public branch in SteamCMD's app info" >&2
  exit 1
fi
# Other branches with the public build add nothing, like unstable between betas.
awk -v build="${public_build}" '$1 == "public" || $2 != build' <<< "${selected}"
