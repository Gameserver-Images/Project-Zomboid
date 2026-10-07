#!/bin/bash
# Turns the canary results of a run's boot tests into GitHub issues. A workaround whose canary fired
# gets an issue titled "<workaround> workaround can be removed", once, with a table of how its canary
# did on each branch CI tests; a firing on a branch where it hadn't fired the time before adds a
# comment, and every run with results for it updates the table, whose data the issue keeps in a
# comment at its end. The workaround can go once the canary has fired on every branch.
# Usage: canary_issues.sh <folder with the boot tests' canaries.jsonl files>
# Needs GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SERVER_URL, GITHUB_RUN_ID and BRANCHES, the Steam branches
# CI tests, separated by spaces.

set -euo pipefail

shown="$(jq -c -n --arg branches "${BRANCHES}" '$branches | split(" ") | map(select(. != ""))')"
[ "${shown}" != "[]" ] || { echo "Error: BRANCHES names no branch" >&2; exit 1; }
run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
results="$( { [ ! -d "$1" ] || find "$1" -name canaries.jsonl -exec cat {} +; } | jq -s -c --arg run "${run_url}" 'map(. + {run: $run})')"
[ "${results}" != "[]" ] || exit 0
# Only the issues this workflow opened, as github-actions: anyone can open one with that title.
issues="$(gh issue list --repo "${GITHUB_REPOSITORY}" --state all --limit 1000 --json number,title,body,author \
  | jq -c 'map(select(.author.login | test("^(app/)?github-actions(\\[bot\\])?$")))')"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mapfile -t workarounds < <(jq -r 'map(.workaround) | unique[]' <<< "${results}")
for workaround in "${workarounds[@]}"; do
  title="${workaround} workaround can be removed"
  mine="$(jq -c --arg workaround "${workaround}" 'map(select(.workaround == $workaround))' <<< "${results}")"
  issue="$(jq -c --arg title "${title}" 'map(select(.title == $title)) | max_by(.number) // empty' <<< "${issues}")"
  if [ -z "${issue}" ] && ! jq -e 'any(.result == "fired")' <<< "${mine}" >/dev/null; then
    continue
  fi
  old_body="$(jq -r '.body // ""' <<< "${issue:-null}" | tr -d '\r')"
  # Per branch: the canary's last result, the game version, what the game did and the run
  state="$(sed -n 's/^<!-- canaries \(.*\) -->$/\1/p' <<< "${old_body}" | tail -n 1)"
  jq -e 'type == "object"' <<< "${state:-null}" >/dev/null 2>&1 || state='{}'
  fired="$(jq -c --argjson state "${state}" 'map(select(.result == "fired" and $state[.branch].result != "fired"))' <<< "${mine}")"
  state="$(jq -S -c --argjson mine "${mine}" '. + ($mine | map({key: .branch, value: {result: .result, label: .label, finding: .finding, run: .run}}) | from_entries)' <<< "${state}")"
  jq -r --arg workaround "${workaround}" --argjson shown "${shown}" --arg remove "$(jq -r 'last.remove' <<< "${mine}")" '
    . as $state
    | ($remove | (.[:1] | ascii_upcase) + .[1:]) as $steps
    | "The canary of the \($workaround) workaround in `ci/boot_test.sh` reproduces the game bug the workaround is for, with the workaround off. Where it fired, the game no longer has that bug.",
      "",
      "| Branch | Game | Canary | Run |",
      "| --- | --- | --- | --- |",
      ($shown[] | . as $branch | $state[$branch] as $s
        | if $s == null then "| \($branch) | | not run since this issue was opened | |"
          else "| \($branch) | \($s.label) | \({fired: "fired", held: "still needed", "n/a": "does not apply"}[$s.result]): \($s.finding) | [run](\($s.run)) |"
          end),
      "",
      (if all($shown[]; $state[.].result == "fired" or $state[.].result == "n/a")
       then "**It has fired on every branch, so the workaround can go.** \($steps)"
       else "Once it has fired on every branch, the workaround can go. \($steps)"
       end),
      "",
      "<!-- canaries \($state | tojson) -->"
  ' <<< "${state}" > "${work}/body"
  if [ -z "${issue}" ]; then
    echo "Opening the issue \"${title}\""
    gh issue create --repo "${GITHUB_REPOSITORY}" --title "${title}" --body-file "${work}/body" < /dev/null
    continue
  fi
  number="$(jq -r '.number' <<< "${issue}")"
  if [ "$(cat "${work}/body")" != "${old_body}" ]; then
    echo "Updating issue #${number}, \"${title}\""
    gh issue edit "${number}" --repo "${GITHUB_REPOSITORY}" --body-file "${work}/body" < /dev/null
  fi
  if [ "${fired}" != "[]" ]; then
    jq -r --arg run "${run_url}" 'map("Fired on \(.label): \(.finding).") + ["", $run] | .[]' <<< "${fired}" > "${work}/comment"
    echo "Commenting on issue #${number}, \"${title}\""
    gh issue comment "${number}" --repo "${GITHUB_REPOSITORY}" --body-file "${work}/comment" < /dev/null
  fi
done
