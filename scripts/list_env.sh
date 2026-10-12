#!/bin/bash
# Lists every environment variable the image reads: its own variables, then one INI_ and
# SANDBOX_ variable per setting in the server's current files, mod settings included.

set -euo pipefail

usage='Usage: list-env [--tsv] [filter]'
case "${1:-}" in
  -h | --help)
    cat <<EOF
${usage}
Lists the variables you can set, with their current values: the image's own, then an INI_ and a
SANDBOX_ variable for every setting in the server's files, mod settings included. Passwords and
tokens show as (set).
  filter  only the variables whose name or description contains it, in any case,
          e.g. list-env anticheat
  --tsv   tab-separated rows (kind, name, value, description), for scripts
The other commands are list-mods and console; each takes --help.
EOF
    exit 0 ;;
esac

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SERVER_DIR="${HOMEDIR}/Zomboid/Server"

tsv=false
if [ "${1:-}" = "--tsv" ]; then
  tsv=true
  shift
fi
if [ "$#" -gt 1 ] || [[ "${1:-}" == -* ]]; then
  echo "${usage}" >&2
  exit 2
fi
filter="${1:-}"

image_vars() {
  local name description value
  while IFS=$'\t' read -r name description; do
    value="${!name:-}"
    case "${name}" in
      ADMINPASSWORD|STEAM_API_KEY) [ -n "${value}" ] && value="(set)" ;;
    esac
    printf 'image\t%s\t%s\t%s\n' "${name}" "${value}" "${description}"
  done < "${SCRIPT_DIR}/vars.tsv"
}

# Comment lines directly above a setting become its description.
ini_vars() {
  [ -f "$1" ] || return 0
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    { line = trim($0); sub(/\r$/, "", line) }
    line == "" { desc = ""; next }
    line ~ /^[#;]/ { sub(/^[#;][ \t]*/, "", line); desc = (desc == "" ? line : desc " " line); next }
    index(line, "=") > 1 {
      i = index(line, "=")
      key = substr(line, 1, i - 1)
      value = substr(line, i + 1)
      if (tolower(key) ~ /password|token/ && value != "") value = "(set)"
      printf "ini\tINI_%s\t%s\t%s\n", key, value, desc
    }
    { desc = "" }
  ' "$1"
}

sandbox_vars() {
  [ -f "$1" ] || return 0
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    { line = trim($0); sub(/\r$/, "", line) }
    line == "" { next }
    line ~ /^--/ { sub(/^--[ \t]*/, "", line); desc = (desc == "" ? line : desc " " line); next }
    line ~ /^[A-Za-z0-9_]+[ \t]*=[ \t]*\{$/ {
      key = line
      sub(/[ \t]*=.*/, "", key)
      if (seen_root) stack[++depth] = key
      seen_root = 1
      desc = ""
      next
    }
    line ~ /^\}[ \t]*,?$/ { if (depth > 0) depth--; desc = ""; next }
    line ~ /^[A-Za-z0-9_]+[ \t]*=/ {
      key = line
      sub(/[ \t]*=.*/, "", key)
      value = line
      sub(/^[^=]*=[ \t]*/, "", value)
      sub(/[ \t]*,$/, "", value)
      name = ""
      for (i = 1; i <= depth; i++) name = name stack[i] "__"
      printf "sandbox\tSANDBOX_%s%s\t%s\t%s\n", name, key, value, desc
    }
    { desc = "" }
  ' "$1"
}

rows() {
  image_vars
  ini_vars "${SERVER_DIR}/${SERVERNAME:-pzserver}.ini"
  sandbox_vars "${SERVER_DIR}/${SERVERNAME:-pzserver}_SandboxVars.lua"
}

rows | awk -F '\t' -v filter="${filter}" -v tsv="${tsv}" '
  filter != "" && index(tolower($2 " " $4), tolower(filter)) == 0 { next }
  tsv == "true" { print; next }
  {
    if ($1 != kind) {
      kind = $1
      printf "%s## %s\n", (shown ? "\n" : ""), (kind == "image" ? "Image settings" : kind == "ini" ? "Server settings (pzserver.ini)" : "Sandbox settings (pzserver_SandboxVars.lua)")
    }
    shown = 1
    if ($4 != "") print "# " $4
    print $2 "=" $3
  }
'
