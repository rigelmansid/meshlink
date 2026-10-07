#!/usr/bin/env bash
# Points Codex's MCP server entry at rhinomcp on the PC (Option 1):
#
#   ssh -T -o BatchMode=yes <host> "set RHINO_MCP_TIMEOUT=30&& <rhinomcp.exe>"
#
# The account and address come from the Host entry in ~/.ssh/config (see
# setup.sh), so the entry carries no -l. The path of rhinomcp.exe is asked
# from the PC unless given.
#
# config.toml is edited in place rather than through `codex mcp add`, which
# rewrites the whole file without its comments and drops the replaced entry's
# env, startup timeout and per-tool approvals (pitfall 19). A new entry is
# appended; in an existing one only the command and args lines change. An
# existing, different entry is only changed after a backup and a yes (or
# --yes); an identical one is left alone. Codex reads the result back, and a
# file it cannot read is restored from the backup.
#
# An entry in another form than Codex writes (args spread over lines, an
# inline table) falls back to `codex mcp add`, listing what it will drop.
#
# Usage:
#   scripts/client-codex.sh [--host rhino-pc] [--name rhino]
#                           [--rhinomcp 'C:\Users\<user>\.local\bin\rhinomcp.exe']
#                           [--yes] [--no-doctor]
set -uo pipefail

PROG=client-codex
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

HOST_ALIAS=rhino-pc
NAME=rhino
RMCP=""
YES=no
DOCTOR=yes

while (($#)); do
  case $1 in
    --host) HOST_ALIAS=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    --rhinomcp) RMCP=${2:-}; shift 2 ;;
    --yes) YES=yes; shift ;;
    --no-doctor) DOCTOR=no; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

CODEX_CONFIG="${CODEX_HOME:-$HOME/.codex}/config.toml"
STAMP=$(date +%Y%m%d-%H%M%S)

if ! command -v codex >/dev/null 2>&1; then
  fail "codex not found in PATH"
  finish
fi

# ------------------------------------------------- 1. rhinomcp.exe on the PC
ssh_pc=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST_ALIAS")
if [[ -z $RMCP ]]; then
  out=$("${ssh_pc[@]}" 'echo PROFILE=%USERPROFILE%' 2>&1)
  if [[ $out != *PROFILE=* ]]; then
    fail "ssh $HOST_ALIAS failed, so the path of rhinomcp.exe is unknown"
    printf '%s\n' "$out" | grep -v '^\*\*' | readable | tail -3 | sed 's/^/          /'
    hint "run $CMD_SETUP first, or pass --rhinomcp <path>"
    finish
  fi
  # A non-ASCII account name comes back in the PC's code page (pitfall 18).
  profile=$(printf '%s\n' "$out" | readable | sed -n 's/^PROFILE=//p' | head -1)
  RMCP="$profile\\.local\\bin\\rhinomcp.exe"
fi
check=$("${ssh_pc[@]}" "if exist \"$RMCP\" (echo RMCP=yes) else (echo RMCP=no)" 2>/dev/null)
case $check in
  *RMCP=yes*) ok "rhinomcp.exe found at $RMCP" ;;
  *RMCP=no*)
    fail "rhinomcp.exe not found at $RMCP"
    hint "run prepare-windows.ps1 on the PC for this account, or pass --rhinomcp <path>"
    finish ;;
  *) warn "could not check $RMCP on the PC; writing it anyway" ;;
esac

# cmd.exe needs quotes around a path with spaces; no space before && (the
# space would become part of the variable's value).
target=$RMCP
[[ $target == *" "* ]] && target="\"$target\""
want=(-T -o BatchMode=yes "$HOST_ALIAS" "set RHINO_MCP_TIMEOUT=30&& $target")

# ------------------------------------------------------ 2. compare and write
# TOML basic strings: backslash and double quote escaped, nothing else occurs.
toml_str() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}
CMD_LINE='command = "ssh"'
ARGS_LINE="args = ["
for a in "${want[@]}"; do
  [[ $ARGS_LINE == "args = [" ]] || ARGS_LINE+=", "
  ARGS_LINE+=$(toml_str "$a")
done
ARGS_LINE+="]"
TMP_CONFIG="$CODEX_CONFIG.tmp-$STAMP"
BACKUP=""

# edit_in_place -- writes config.toml with the command and args lines of
# [mcp_servers.$NAME] replaced, to $TMP_CONFIG. Fails unless the entry has the
# form Codex writes: one such header, one command line, a one-line args array.
# Values go in through the environment: awk -v would eat the backslashes.
edit_in_place() {
  [[ $NAME =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  ML_NAME=$NAME ML_CMD=$CMD_LINE ML_ARGS=$ARGS_LINE awk '
    BEGIN {
      head = "^[ \t]*\\[[ \t]*mcp_servers\\." ENVIRON["ML_NAME"] "[ \t]*\\][ \t]*(#.*)?$"
    }
    /^[ \t]*\[/ { insec = ($0 ~ head); if (insec) headers++ }
    insec && /^[ \t]*command[ \t]*=/ { commands++; print ENVIRON["ML_CMD"]; next }
    insec && /^[ \t]*args[ \t]*=/ {
      argses++
      if ($0 !~ /\][ \t]*(#.*)?$/) spread = 1
      print ENVIRON["ML_ARGS"]
      next
    }
    { print }
    END { exit (headers == 1 && commands == 1 && argses == 1 && !spread) ? 0 : 1 }
  ' "$CODEX_CONFIG" >"$TMP_CONFIG" || { rm -f "$TMP_CONFIG"; return 1; }
}

backup_config() {
  if [[ -f $CODEX_CONFIG ]]; then
    BACKUP="$CODEX_CONFIG.bak-$STAMP"
    cp -p "$CODEX_CONFIG" "$BACKUP"
    info "backup: $BACKUP"
  fi
}

# install_tmp -- puts $TMP_CONFIG in place, keeping the file (and its mode).
install_tmp() {
  cat "$TMP_CONFIG" >"$CODEX_CONFIG" && rm -f "$TMP_CONFIG"
}

# reads_back -- true if Codex reads the entry as written.
reads_back() {
  local i
  read_codex_server "$NAME" && [[ $CODEX_COMMAND == ssh && ${#CODEX_ARGS[@]} -eq ${#want[@]} ]] || return 1
  for ((i = 0; i < ${#want[@]}; i++)); do
    [[ ${CODEX_ARGS[i]} == "${want[i]}" ]] || return 1
  done
}

# restore -- puts the backup back after a write Codex does not read as meant.
restore() {
  if [[ -n $BACKUP ]]; then
    cp -p "$BACKUP" "$CODEX_CONFIG"
    hint "config.toml restored from $BACKUP"
  else
    rm -f "$CODEX_CONFIG"
  fi
}

mode=append
if read_codex_server "$NAME"; then
  if reads_back; then
    ok "Codex's '$NAME' entry already runs: ssh ${want[*]}"
    [[ $DOCTOR == yes ]] && { echo; SERVER=$NAME exec "$HERE/doctor.sh"; }
    finish
  fi
  read_codex_server "$NAME"
  before_envs="${CODEX_ENVS[*]+${CODEX_ENVS[*]}}"
  before_timeout=$(printf '%s\n' "$CODEX_JSON" | sed -n 's/.*"startup_timeout_sec": \([0-9.]*\).*/\1/p' | head -1)

  echo "Codex already has an MCP server named '$NAME':"
  echo "  now:  $CODEX_COMMAND ${CODEX_ARGS[*]+${CODEX_ARGS[*]}}"
  echo "  new:  ssh ${want[*]}"
  if edit_in_place; then
    mode=edit
    echo "Only its command and args change; its other settings and the rest of config.toml stay as they are."
  else
    mode=add
    lost=()
    for kv in ${CODEX_ENVS[@]+"${CODEX_ENVS[@]}"}; do lost+=("env ${kv%%=*}"); done
    [[ -n $before_timeout ]] && lost+=("startup_timeout_sec = $before_timeout")
    if [[ -f $CODEX_CONFIG ]]; then
      while IFS= read -r t; do
        [[ -n $t ]] && lost+=("tools.$t settings")
      done < <(sed -n "s/^\[mcp_servers\.$NAME\.tools\.\([^]]*\)\]/\1/p" "$CODEX_CONFIG")
    fi
    echo "It is not in the form Codex writes (args over several lines, or an inline table),"
    echo "so it is replaced with codex mcp add, which rewrites the entry whole:"
    for l in ${lost[@]+"${lost[@]}"}; do echo "  - drops $l"; done
    # Seen with Codex 0.159.3: it also rewrites the rest of config.toml, dropping
    # every comment and reformatting other entries (values stay the same).
    echo "  - drops every comment in config.toml"
  fi
  if [[ $YES != yes ]]; then
    ask "Replace it? A backup of config.toml is made first. (yes/no): " || REPLY=""
    if [[ $REPLY != yes ]]; then
      rm -f "$TMP_CONFIG"
      info "nothing changed"
      finish
    fi
  fi
elif [[ -f $CODEX_CONFIG ]] && ! codex mcp list --json >/dev/null 2>&1; then
  fail "Codex cannot read $CODEX_CONFIG, so it is left alone"
  hint "fix the file (codex mcp list shows the error), then run this again"
  finish
fi

backup_config
case $mode in
  edit)
    install_tmp ;;
  append)
    mkdir -p "$(dirname "$CODEX_CONFIG")"
    [[ -f $CODEX_CONFIG ]] || { : >"$CODEX_CONFIG"; chmod 600 "$CODEX_CONFIG"; }
    {
      # A blank line before the new table; a missing final newline first.
      if [[ -s $CODEX_CONFIG ]]; then
        [[ -n $(tail -c 1 "$CODEX_CONFIG") ]] && echo
        echo
      fi
      printf '[mcp_servers.%s]\n%s\n%s\n' "$NAME" "$CMD_LINE" "$ARGS_LINE"
    } >>"$CODEX_CONFIG" ;;
  add)
    if ! codex mcp add "$NAME" -- ssh "${want[@]}" >/dev/null 2>&1; then
      fail "codex mcp add failed"
      restore
      finish
    fi ;;
esac

if ! reads_back; then
  fail "Codex's '$NAME' entry does not read back as written"
  restore
  finish
fi
if [[ $mode == edit ]]; then
  after_timeout=$(printf '%s\n' "$CODEX_JSON" | sed -n 's/.*"startup_timeout_sec": \([0-9.]*\).*/\1/p' | head -1)
  if [[ "${CODEX_ENVS[*]+${CODEX_ENVS[*]}}" != "$before_envs" || $after_timeout != "$before_timeout" ]]; then
    fail "Codex reads other settings of '$NAME' differently after the edit"
    restore
    finish
  fi
fi
done_ "Codex's '$NAME' entry now runs: ssh ${want[*]}"
if [[ $mode == add ]]; then
  info "Codex's default startup timeout applies now; restart Codex to pick up the change"
else
  info "the rest of config.toml is unchanged; restart Codex to pick up the change"
fi

[[ $DOCTOR == yes ]] && { echo; SERVER=$NAME exec "$HERE/doctor.sh"; }
finish
