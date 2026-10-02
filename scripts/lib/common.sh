# Shared by doctor.sh, setup.sh and client-codex.sh. Source it; do not run it.
# bash 3.2 compatible. Set PROG before sourcing; it prefixes the summary line.

fails=0
warns=0

# Names for the next step in hints: the meshlink command when run through it
# (bin/meshlink exports MESHLINK_CLI), the script paths when run from a checkout.
if [[ -n ${MESHLINK_CLI:-} ]]; then
  CMD_SETUP="meshlink setup"
  CMD_CLIENT="meshlink client codex"
  CMD_DOCTOR="meshlink doctor"
  CMD_TUNNEL="meshlink tunnel"
else
  CMD_SETUP="scripts/setup.sh"
  CMD_CLIENT="scripts/client-codex.sh"
  CMD_DOCTOR="scripts/doctor.sh"
  CMD_TUNNEL="scripts/rhino-tunnel.sh"
fi

report() { # tag message
  printf '[%s] %s\n' "$1" "$2"
}
ok()   { report " OK " "$1"; }
done_() { report "DONE" "$1"; }
info() { report "INFO" "$1"; }
warn() { report "WARN" "$1"; warns=$((warns + 1)); }
fail() { report "FAIL" "$1"; fails=$((fails + 1)); }
skip() { report "SKIP" "$1"; }
hint() { printf '       -> %s\n' "$1"; }

finish() {
  echo
  if ((fails)); then
    echo "$PROG: $fails failed, $warns warning(s)"
    exit 1
  fi
  echo "$PROG: done, $warns warning(s)"
  exit 0
}

# Remote error text arrives in the PC's code page (GBK on Chinese Windows,
# pitfall 18). Show UTF-8 as is, try GBK, and otherwise keep printable bytes.
readable() {
  local raw
  raw=$(LC_ALL=C tr -d '\r')
  if printf '%s' "$raw" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    printf '%s' "$raw"
  elif printf '%s' "$raw" | iconv -f GBK -t UTF-8 2>/dev/null; then
    :
  else
    printf '%s' "$raw" | LC_ALL=C tr -cd '[:print:]\n'
  fi
  # End with a newline, so a following line does not run on in a pipeline.
  [[ -n $raw ]] && echo
  return 0
}

# Strip one JSON string literal: leading space, quotes, trailing comma, and the
# \\ and \" escapes. Enough for command lines; other escapes are left as is.
json_unquote() {
  sed -e 's/^[[:space:]]*"//' -e 's/",\{0,1\}[[:space:]]*$//' \
      -e 's/\\\\/__RHINO_BS__/g' -e 's/\\"/"/g' -e 's/__RHINO_BS__/\\/g'
}

# read_codex_server NAME -- reads `codex mcp get NAME --json` into
# CODEX_JSON, CODEX_COMMAND, CODEX_ARGS (array) and CODEX_ENVS (KEY=value
# array). Returns 1 if Codex has no such server.
#
# The JSON is pretty-printed with one array item or object member per line,
# which is what makes reading it without jq workable. An empty [] or {} sits on
# the opening line, so the block ranges below must not start there. stderr is
# dropped so a Codex warning cannot end up inside the JSON.
read_codex_server() {
  local line
  CODEX_JSON=""
  CODEX_COMMAND=""
  CODEX_ARGS=()
  CODEX_ENVS=()
  CODEX_JSON=$(codex mcp get "$1" --json 2>/dev/null) || return 1
  CODEX_COMMAND=$(printf '%s\n' "$CODEX_JSON" | grep -m1 '"command":' |
                  sed 's/^[^:]*:[[:space:]]*//' | json_unquote)
  if ! printf '%s\n' "$CODEX_JSON" | grep -q '"args": \[\]'; then
    while IFS= read -r line; do
      CODEX_ARGS+=("$line")
    done < <(printf '%s\n' "$CODEX_JSON" | sed -n '/"args": \[$/,/^[[:space:]]*\]/p' |
             sed '1d;$d' | json_unquote)
  fi
  while IFS= read -r line; do
    [[ -n $line ]] && CODEX_ENVS+=("$line")
  done < <(printf '%s\n' "$CODEX_JSON" | sed -n '/"env": {$/,/^[[:space:]]*}/p' | sed '1d;$d' |
           sed -n 's/^[[:space:]]*"\([^"]*\)":[[:space:]]*"\(.*\)",\{0,1\}[[:space:]]*$/\1=\2/p')
  return 0
}

# ask PROMPT -- reads one line from stdin into REPLY; returns 1 at end of input.
ask() {
  printf '%s' "$1"
  IFS= read -r REPLY || { echo; return 1; }
}
