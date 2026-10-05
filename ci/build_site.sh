#!/bin/bash
# Assembles the docs site: the pages, the env references in <site>/env, and an index of them.
# References for earlier game builds are copied from the live site, because each deploy replaces it.
# Usage: build_site.sh <site dir> <live site URL>

set -euo pipefail

site="$1"
base="$2"
env_dir="${site}/env"
mkdir -p "${env_dir}"
cp site/index.html site/mods.html "${site}/"

live_index="$(mktemp)"
status="$(curl -sS -o "${live_index}" -w '%{http_code}' "${base}/env/index.json")"
case "${status}" in
  200)
    jq -r '.files[].file | select(test("^[A-Za-z0-9._-]+\\.json$"))' "${live_index}" | while IFS= read -r file; do
      [ -f "${env_dir}/${file}" ] && continue
      curl -fsS -o "${env_dir}/${file}" "${base}/env/${file}"
      # References from images that carried the game are labelled by image tag and are dropped.
      jq -e '.label' "${env_dir}/${file}" >/dev/null || rm "${env_dir}/${file}"
    done
    ;;
  404) echo "No published env references yet" ;;
  *) echo "Error: ${base}/env/index.json returned ${status}" >&2; exit 1 ;;
esac

# A build that is also the public one (a beta that went public) is listed as public.
for file in "${env_dir}"/*-*.json; do
  name="${file##*/}"
  if [ "${name%-*}" != public ] && [ -e "${env_dir}/public-${name##*-}" ]; then
    rm "${file}"
  fi
done

find "${env_dir}" -maxdepth 1 -name '*.json' ! -name index.json -print0 | sort -z \
  | xargs -0 -r jq -c '{file: (input_filename | split("/") | last), label, release}' \
  | jq -s '{files: .}' > "${env_dir}/index.json"
