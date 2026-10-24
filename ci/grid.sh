#!/bin/bash
# Puts the map grid next to the mods page as <site>/grid.js: the Zomboid Map Index's site/grid.js, fetched from
# GRID_REPO at GRID_COMMIT (or read from GRID_FILE), as a classic script that defines ZomboidMapGrid, since browsers
# load no modules into a page opened from a file.
# Usage: grid.sh <site dir>

set -euo pipefail

# The index repository, and the commit of its grid the page is tested with.
GRID_REPO="${GRID_REPO:-zexyqag/Zomboid-Map-Index}"
GRID_COMMIT="${GRID_COMMIT:-a4aa811005e6203fc2785bd75100c1f519dbfe82}"
# The major version whose functions the page calls.
GRID_MAJOR=1

site="${1:?usage: grid.sh <site dir>}"
module="$(mktemp)"
trap 'rm -f "${module}"' EXIT
if [ -n "${GRID_FILE:-}" ]; then
  from="${GRID_FILE}"
  cp "${GRID_FILE}" "${module}"
else
  from="${GRID_REPO}@${GRID_COMMIT}"
  curl -fsS --max-time 30 -o "${module}" "https://raw.githubusercontent.com/${GRID_REPO}/${GRID_COMMIT}/site/grid.js"
fi

version="$(sed -n "s/^export const VERSION = '\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)';$/\1/p" "${module}")"
if [ "${version%%.*}" != "${GRID_MAJOR}" ]; then
  echo "Error: the grid script from ${from} is version ${version:-unknown}, the page calls ${GRID_MAJOR}.x" >&2
  exit 1
fi
# Its exports become ZomboidMapGrid's names: top-level `export const` and `export function` lines, and nothing else
# of a module.
if grep -nE '^[[:space:]]*import[[:space:]({*"'"'"']|^[[:space:]]*export[[:space:]]+(default|let|var|class|async|\{|\*)' "${module}" >&2; then
  echo "Error: the grid script from ${from} uses more of modules than the page reads" >&2
  exit 1
fi
names="$(sed -n -E 's/^export (const|function) ([A-Za-z_][A-Za-z0-9_]*).*/\2/p' "${module}" | paste -sd ',' - | sed 's/,/, /g')"
{
  echo "// The Zomboid Map Index's grid ${version} (${from}) as a classic script."
  echo "const ZomboidMapGrid = (() => {"
  sed -E 's/^export (const|function) /\1 /' "${module}"
  echo "return Object.freeze({ ${names} });"
  echo "})();"
} > "${site}/grid.js"
