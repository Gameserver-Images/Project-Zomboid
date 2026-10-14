#!/bin/bash
# Edits the server's INI and SandboxVars files from environment variables.

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

read_secret() {
  # $1 = variable holding the value, $2 = variable naming a file that holds it (preferred)
  local value_var="$1" file_var="$2"
  local file_path="${!file_var:-}"
  if [ -n "${file_path}" ]; then
    if [ -f "${file_path}" ]; then
      printf '%s' "$(<"${file_path}")"
      return
    fi
    echo "Warning: ${file_var} is set but the file does not exist: ${file_path}" >&2
  fi
  printf '%s' "${!value_var:-}"
}

ini_value() {
  # $1 = INI file, $2 = key; prints the value, empty when the key is missing
  KEY="$2" awk '
    BEGIN { k = tolower(ENVIRON["KEY"]) }
    { sub(/\r$/, ""); i = index($0, "=") }
    i > 1 && tolower(substr($0, 1, i - 1)) == k { print substr($0, i + 1); exit }
  ' "$1"
}

set_ini_value() {
  # $1 = INI file, $2 = key, $3 = value; replaces the key (case-insensitive) or appends it
  KEY="$2" VALUE="$3" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"] }
    { i = index($0, "=") }
    !found && i > 1 && tolower(substr($0, 1, i - 1)) == tolower(k) {
      print substr($0, 1, i - 1) "=" v
      found = 1
      next
    }
    { print }
    END { if (!found) print k "=" v }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# Applies every INI_<Key> variable to the INI file. INI_<Key>_FILE reads the value from a file
# (for Docker secrets) and wins over INI_<Key>. On the first start the INI is empty and every key
# is written; afterwards the server has written all its keys, so a key that isn't there is a typo
# and is reported instead of written.
apply_ini_env() {
  local ini_file="$1" name key value old check_unknown=true unknown="" invalid=""
  [ -s "${ini_file}" ] || check_unknown=false
  while IFS= read -r name; do
    key="${name#INI_}"
    key="${key%_FILE}"
    if [[ "${name}" == *_FILE ]]; then
      [ -f "${!name}" ] || { echo "Warning: ${name} is set but the file does not exist: ${!name}" >&2; continue; }
      value="$(<"${!name}")"
    elif [ -n "$(printenv "${name}_FILE")" ]; then
      continue
    else
      value="${!name}"
    fi
    if [ "${check_unknown}" = true ] && ! grep -qi "^${key}=" "${ini_file}"; then
      unknown="${unknown} ${name}"
      continue
    fi
    old="$(ini_value "${ini_file}" "${key}")"
    if [[ "${old,,}" =~ ^(true|false)$ ]]; then
      if [[ ! "${value,,}" =~ ^(true|false)$ ]]; then
        invalid="${invalid} ${name}"
        continue
      fi
      value="${value,,}"
    fi
    set_ini_value "${ini_file}" "${key}" "${value}"
    echo "Config: ${key} set from ${name}"
  done < <(compgen -e | grep '^INI_' | sort)
  report_problems "match no setting in ${ini_file}" "${unknown}"
  report_problems "need true or false in ${ini_file}" "${invalid}"
}

# Applies every SANDBOX_<Group>__<Key> variable to the SandboxVars file. The value must have the
# type of the current one (number, true/false or string), so a typo can't break the Lua file; a
# string setting gets its quotes added when the value has none. The game writes the options of a mod
# into the file on the first start that loads it, so on that start the file lacks them: one a mod the
# server loads declares is added, with a value its declaration allows.
apply_sandbox_env() {
  # $1 = SandboxVars file, $2 = what load_mods printed
  local lua_file="$1" rows="$2" names declared problems=""
  names="$(compgen -e | grep '^SANDBOX_' | sort || true)"
  [ -n "${names}" ] || return 0
  if [ ! -f "${lua_file}" ]; then
    echo "Warning: ${lua_file} does not exist yet, so SANDBOX_ settings apply from the next start (or set SERVERPRESET to create it now)." >&2
    return 0
  fi
  declared="$(mktemp)"
  awk -F '\t' '$1 == "load"' <<< "${rows}" | cut -f 2- | sandbox_options > "${declared}"
  # A partly written file must not replace the real one (a full disk, for example).
  if NAMES="${names}" awk -v declared_file="${declared}" -v out="${lua_file}.tmp" '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    # The line without its comment, which starts at -- outside a string
    function code_of(line,   i, c, quote) {
      quote = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (quote != "") {
          if (c == "\\") i++
          else if (c == quote) quote = ""
        } else if (c == "\"" || c == "\047") {
          quote = c
        } else if (substr(line, i, 2) == "--") {
          return substr(line, 1, i - 1)
        }
      }
      return line
    }
    # The file is written at the end, so a separator can still go after the last field.
    function emit(line,   code) {
      kept[++lines] = line
      code = code_of(line)
      sub(/[ \t\r]+$/, "", code)
      if (code != "") {
        last = lines
        last_end = length(code)
      }
    }
    # Fields need a comma or semicolon between them. The game writes one after each field, but its
    # presets leave it out after the last field of a table.
    function separate(   c) {
      c = substr(kept[last], last_end, 1)
      if (c != "," && c != ";" && c != "{") kept[last] = substr(kept[last], 1, last_end) "," substr(kept[last], last_end + 1)
    }
    # The game writes strings back with their line breaks unescaped, which breaks the file.
    function one_line(s) { return s !~ /[\n\r]/ }
    # A value in quotes is a Lua string already, in which \" and \\ stand for a quote and a backslash.
    function lua_string(s,   text, i) {
      if (s ~ /^".*"$/) {
        text = ""
        for (i = 2; i < length(s); i++) {
          if (substr(s, i, 1) == "\\" && i + 1 < length(s) && index("\\\"", substr(s, i + 1, 1))) i++
          text = text substr(s, i, 1)
        }
        s = text
      }
      gsub(/[\\"]/, "\\\\&", s)
      return "\"" s "\""
    }
    # The Lua value of v for an option of a mod (CustomSandboxOptions, SandboxOptions), "" when the
    # option takes no such value.
    function allowed(v, type, low, high) {
      if (type == "boolean") return tolower(v) ~ /^(true|false)$/ ? tolower(v) : ""
      if (type == "string") return one_line(v) ? lua_string(v) : ""
      return v ~ (type == "double" ? "^-?[0-9]+(\\.[0-9]+)?$" : "^-?[0-9]+$") && v + 0 >= low + 0 && v + 0 <= high + 0 ? v : ""
    }
    function pending(k) { return !(k in applied) && lua_value[k] != "" }
    # The options of the mods the server loads that the file lacks, before the closing brace of their
    # table ("" for SandboxVars itself), in the order the game writes them.
    function add(table, indent,   i, k) {
      for (i = 1; i <= count; i++) {
        k = order[i]
        if (table_of[k] != table || !pending(k)) continue
        separate()
        emit(indent short_of[k] " = " lua_value[k] ",")
        applied[k] = 1
        printf "Config: sandbox %s set from %s\n", id_of[k], env_of[k] > "/dev/stderr"
      }
    }
    BEGIN {
      n = split(ENVIRON["NAMES"], names, "\n")
      for (i = 1; i <= n; i++) {
        path = names[i]
        sub(/^SANDBOX_/, "", path)
        gsub(/__/, ".", path)
        k = tolower(path)
        env_of[k] = names[i]
        path_of[k] = path
      }
      # Of options with the same id the last one counts, since the game writes their values in turn.
      # It writes the id as the table and key names, which only makes valid Lua with one dot at most.
      while ((getline line < declared_file) > 0) {
        split(line, f, "\t")
        k = tolower(f[3])
        if (!(k in env_of) || f[3] !~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$/) continue
        id_of[k] = f[3]
        order[++count] = k
        dot = index(f[3], ".")
        table_of[k] = substr(f[3], 1, dot - 1)
        short_of[k] = substr(f[3], dot + 1)
        enum = f[4] == "enum"
        lua_value[k] = allowed(ENVIRON[env_of[k]], f[4], enum ? 1 : f[6], enum ? f[11] : f[7])
      }
      close(declared_file)
    }
    {
      line = $0
      code = trim(code_of(line))
      if (code ~ /^[A-Za-z0-9_]+[ \t]*=[ \t]*\{$/) {
        key = code
        sub(/[ \t]*=.*/, "", key)
        if (seen_root) stack[++depth] = key
        seen_root = 1
        emit(line)
        next
      }
      if (code ~ /^\}[ \t]*[,;]?$/) {
        if (depth == 1) {
          add(stack[1], "        ")
        } else if (depth == 0) {
          add("", "    ")
          for (i = 1; i <= count; i++) {
            k = order[i]
            if (!pending(k)) continue
            separate()
            emit("    " table_of[k] " = {")
            add(table_of[k], "        ")
            emit("    },")
          }
        }
        if (depth > 0) depth--
        emit(line)
        next
      }
      if (code ~ /^[A-Za-z0-9_]+[ \t]*=/) {
        key = code
        sub(/[ \t]*=.*/, "", key)
        path = ""
        for (i = 1; i <= depth; i++) path = path stack[i] "."
        path = tolower(path key)
        if (path in env_of) {
          old = code
          sub(/^[^=]*=[ \t]*/, "", old)
          sub(/[ \t]*[,;]$/, "", old)
          new = ENVIRON[env_of[path]]
          applied[path] = 1
          if (old ~ /^".*"$/) {
            if (!one_line(new)) { invalid[path] = 1; emit(line); next }
            new = lua_string(new)
          } else if (old ~ /^(true|false)$/) {
            new = tolower(new)
            if (new !~ /^(true|false)$/) { invalid[path] = 1; emit(line); next }
          } else if (old ~ /^-?[0-9]+(\.[0-9]+)?$/) {
            if (new !~ /^-?[0-9]+(\.[0-9]+)?$/) { invalid[path] = 1; emit(line); next }
          } else if (new == "") {
            invalid[path] = 1; emit(line); next
          }
          indent = line
          sub(/[^ \t].*$/, "", indent)
          emit(indent key " = " new ",")
          printf "Config: sandbox %s set from %s\n", path_of[path], env_of[path] > "/dev/stderr"
          next
        }
      }
      emit(line)
    }
    END {
      for (i = 1; i <= lines; i++) print kept[i] > out
      for (k in env_of) {
        if (k in invalid) print "invalid " env_of[k]
        else if (k in applied) continue
        else if (k in id_of) print "disallowed " env_of[k]
        else print "unknown " env_of[k]
      }
    }
  ' "${lua_file}" > "${declared}.problems"; then
    mv "${lua_file}.tmp" "${lua_file}"
    problems="$(sort "${declared}.problems")"
  fi
  rm -f "${declared}" "${declared}.problems" "${lua_file}.tmp"
  report_problems "match no setting in ${lua_file} or of the mods the server loads" "$(sed -n 's/^unknown / /p' <<< "${problems}" | tr -d '\n')"
  report_problems "need a value of the same type as the current one (number, true/false or text on one line) in ${lua_file}" \
    "$(sed -n 's/^invalid / /p' <<< "${problems}" | tr -d '\n')"
  report_problems "need a value their mod's sandbox-options.txt allows (true/false, a number from its min to its max, 1 to numValues for an enum, or text on one line)" \
    "$(sed -n 's/^disallowed / /p' <<< "${problems}" | tr -d '\n')"
}

# Warns about variables that set the same thing, saying which one is used.
report_overlaps() {
  local names name lower
  names="$(compgen -e | grep -E '^(INI|SANDBOX)_' || true)"
  overlap() {
    # $1 = variable that wins, $2 = case-insensitive pattern for the variables it overrides
    local losers
    [ -n "${!1+x}" ] || return 0
    losers="$(grep -ixE "$2" <<< "${names}" | grep -vxF "$1" | paste -sd ' ' || true)"
    [ -z "${losers}" ] || echo "Warning: $1 and ${losers} set the same thing; $1 is used." >&2
  }
  overlap WORKSHOP_IDS 'INI_WorkshopItems(_FILE)?'
  overlap PORT 'INI_DefaultPort(_FILE)?'
  overlap UDPPORT 'INI_UDPPort(_FILE)?'
  if [ -n "${ADMINPASSWORD_FILE:-}" ] && [ -n "${ADMINPASSWORD:-}" ]; then
    echo "Warning: ADMINPASSWORD and ADMINPASSWORD_FILE are both set; ADMINPASSWORD_FILE is used." >&2
  fi
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    if [[ "${name}" == INI_*_FILE ]] && grep -qixF "${name%_FILE}" <<< "${names}"; then
      echo "Warning: ${name%_FILE} and ${name} are both set; ${name} is used." >&2
    fi
  done <<< "${names}"
  # Names are matched case-insensitively, so these differ only in case and one silently wins.
  while IFS= read -r lower; do
    [ -n "${lower}" ] || continue
    echo "Warning: $(grep -ixF "${lower}" <<< "${names}" | paste -sd ' ') differ only in case; only one is used." >&2
  done < <(tr '[:upper:]' '[:lower:]' <<< "${names}" | sort | uniq -d)
}

report_problems() {
  # $1 = what is wrong with them, $2 = space-separated variable names (none: nothing to report)
  [ -n "${2// /}" ] || return 0
  echo "Warning: these variables $1, so they were not applied:$2" >&2
  echo "         Run 'docker exec <container> list-env' to see the valid names and current values." >&2
  if is_true "${CONFIG_STRICT:-}"; then
    echo "Error: CONFIG_STRICT is set, refusing to start." >&2
    exit 1
  fi
}

# Warns about variables this image doesn't read, such as a misspelled or renamed one. All-lowercase
# names are left alone, since those are conventions of other tools (http_proxy and the like).
report_unrecognized() {
  # $1 = file listing the variables the image sets itself
  local image_env="$1" known unrecognized
  [ -f "${image_env}" ] || return 0
  # docker-compose.yml reads IMAGE and EXTRA_LOCALES from the .env file it also passes to the container.
  known="$(cut -f1 "${SCRIPT_DIR}/vars.tsv"; cat "${image_env}"; printf '%s\n' HOSTNAME HOME OLDPWD PATH PWD SHLVL TERM TZ HTTP_PROXY HTTPS_PROXY NO_PROXY IMAGE EXTRA_LOCALES)"
  unrecognized="$(compgen -e | grep -vE '^(INI|SANDBOX)_|^[a-z_][a-z0-9_]*$|_SERVICE_(HOST|PORT)|_PORT_[0-9]+_|^KUBERNETES_' \
    | grep -vxF -f <(printf '%s\n' "${known}") | paste -sd ' ' || true)"
  [ -z "${unrecognized}" ] || echo "Warning: this image does not read ${unrecognized}. Run 'docker exec <container> list-env' to see the valid names." >&2
}
