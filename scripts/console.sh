#!/bin/bash
# Sends a command to the running server's console.

set -euo pipefail

usage='Usage: console <server command>'
case "$#:${1:-}" in
  0:)
    echo "${usage}, e.g. console players" >&2
    exit 2 ;;
  1:-h | 1:--help)
    cat <<EOF
${usage}
Sends a command to the running server's console. The reply shows up in the container log.
For example:
  console save
  console players
  console servermsg "Restart in 5 minutes"
The other commands are list-env and list-mods; each takes --help.
EOF
    exit 0 ;;
esac
if [ ! -p /tmp/pz-console ] || [ ! -f /tmp/pz-ready ]; then
  echo "Error: the server is not running yet." >&2
  exit 1
fi
# Arguments with spaces are quoted, as the server expects for messages and names.
command=""
for arg in "$@"; do
  [[ "${arg}" == *" "* ]] && arg="\"${arg}\""
  command="${command:+${command} }${arg}"
done
printf '%s\n' "${command}" > /tmp/pz-console
echo "Sent: ${command}  (the reply is in docker logs)"
