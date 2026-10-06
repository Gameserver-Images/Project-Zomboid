#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVERNAME="pzserver"
SERVER_CONSOLE="/tmp/pz-console"
SERVER_READY="/tmp/pz-ready"
SERVER_PID_FILE="/tmp/pz-server.pid"

# As PID 1 the shell ignores signals it has no trap for, so `docker stop` would wait out the grace period.
trap 'exit 143' TERM INT

# shellcheck source=scripts/configure.sh
. "${SCRIPT_DIR}/configure.sh"

update_check="$(mod_update_interval)" || exit 1

for dir in "${HOMEDIR}/Zomboid" "${STEAMAPPDIR}"; do
  blocked="$(find "${dir}" -type d ! -writable -print -quit 2>/dev/null)"
  if [ -n "${blocked}" ]; then
    echo "Error: ${blocked} is not writable by $(id -un) (uid $(id -u)). For a bind mount, run: chown -R $(id -u):$(id -g) <host folder>" >&2
    echo "If a volume is mounted inside ${dir} (such as an old steamapps/workshop volume), Docker created the folders leading to it as root: remove that mount, then recreate or chown the volume at ${dir}." >&2
    exit 1
  fi
done

update_game
cd "${STEAMAPPDIR}" || exit 1
configure_server

# start-server.sh preloads libjsig.so, which is only found through this path.
export LD_LIBRARY_PATH="${STEAMAPPDIR}/jre64/lib:${LD_LIBRARY_PATH:-}"
export LANG

echo "Server ports: ${PORT:-16261}/udp and ${UDPPORT:-16262}/udp"

# The server saves the world on the console command `quit`. Docker only signals PID 1, so stdin is a
# FIFO held open here and SIGTERM/SIGINT write `quit` into it instead of killing the JVM.
rm -f "${SERVER_CONSOLE}" "${SERVER_READY}"
mkfifo "${SERVER_CONSOLE}"
exec {CONSOLE_FD}<>"${SERVER_CONSOLE}"

shutdown_server() {
  [ -n "${SHUTDOWN_STARTED:-}" ] && return
  SHUTDOWN_STARTED=1
  echo "*** INFO: Shutdown signal received, sending 'quit' to save the world ***"
  printf 'quit\n' >&"${CONSOLE_FD}"
  # A further signal interrupts wait with 128+n while the server is still saving.
  while true; do
    wait "${SERVER_PID}"
    SHUTDOWN_EXIT=$?
    if [ "${SHUTDOWN_EXIT}" -le 128 ] || ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      break
    fi
  done
  echo "*** INFO: Server stopped with exit code ${SHUTDOWN_EXIT} ***"
}

# Output passes through this loop, which marks the server ready for the health check once it has
# started and runs the workshop update checks. It's a child of this shell, so the last lines are
# waited for before the container exits.
exec {LOG_FD}> >(
  trap '' TERM INT
  follow_output "${SERVER_READY}" "${CONSOLE_FD}" "${update_check}"
)
LOG_PID=$!
./start-server.sh "${ARGS[@]}" <"${SERVER_CONSOLE}" >&"${LOG_FD}" 2>&1 &
SERVER_PID=$!
exec {LOG_FD}>&-
echo "${SERVER_PID}" > "${SERVER_PID_FILE}"
trap shutdown_server TERM INT

wait "${SERVER_PID}"
SERVER_EXIT=$?
if [ -n "${SHUTDOWN_STARTED:-}" ]; then
  SERVER_EXIT="${SHUTDOWN_EXIT}"
fi
# A process the server leaves behind could hold the log pipe open, so this wait is bounded.
{ sleep 10; kill -KILL "${LOG_PID}" 2>/dev/null; } &
wait "${LOG_PID}"
rm -f "${SERVER_CONSOLE}" "${SERVER_READY}" "${SERVER_PID_FILE}"
exit "${SERVER_EXIT}"
