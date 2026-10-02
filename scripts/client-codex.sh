#!/usr/bin/env bash
# Points Codex's MCP server entry at rhinomcp on the PC (Option 1):
#
#   ssh -T -o BatchMode=yes <host> "set RHINO_MCP_TIMEOUT=30&& <rhinomcp.exe>"
#
# The account and address come from the Host entry in ~/.ssh/config (see
# setup.sh), so the entry carries no -l. The path of rhinomcp.exe is asked
# from the PC unless given.
#
# The entry is written with `codex mcp add`, which replaces an existing entry
# of the same name whole: its env, startup timeout and per-tool approval
# settings are dropped, and it rewrites the rest of config.toml without its
# comments. So an existing, different entry is only replaced after
# a backup of config.toml and a yes (or --yes), and what will be lost is
# listed first. An identical entry is left alone.
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
if read_codex_server "$NAME"; then
  same=no
  if [[ $CODEX_COMMAND == ssh && ${#CODEX_ARGS[@]} -eq ${#want[@]} ]]; then
    same=yes
    for ((i = 0; i < ${#want[@]}; i++)); do
      [[ ${CODEX_ARGS[i]} == "${want[i]}" ]] || same=no
    done
  fi
  if [[ $same == yes ]]; then
    ok "Codex's '$NAME' entry already runs: ssh ${want[*]}"
    [[ $DOCTOR == yes ]] && { echo; SERVER=$NAME exec "$HERE/doctor.sh"; }
    finish
  fi

  echo "Codex already has an MCP server named '$NAME':"
  echo "  now:  $CODEX_COMMAND ${CODEX_ARGS[*]+${CODEX_ARGS[*]}}"
  echo "  new:  ssh ${want[*]}"
  lost=()
  for kv in ${CODEX_ENVS[@]+"${CODEX_ENVS[@]}"}; do lost+=("env ${kv%%=*}"); done
  timeout=$(printf '%s\n' "$CODEX_JSON" | sed -n 's/.*"startup_timeout_sec": \([0-9.]*\).*/\1/p' | head -1)
  [[ -n $timeout ]] && lost+=("startup_timeout_sec = $timeout")
  if [[ -f $CODEX_CONFIG ]]; then
    while IFS= read -r t; do
      [[ -n $t ]] && lost+=("tools.$t settings")
    done < <(sed -n "s/^\[mcp_servers\.$NAME\.tools\.\([^]]*\)\]/\1/p" "$CODEX_CONFIG")
  fi
  if ((${#lost[@]})); then
    echo "Replacing it drops these settings (codex mcp add rewrites the entry whole):"
    for l in "${lost[@]}"; do echo "  - $l"; done
  fi
  # Seen with Codex 0.159.3: it also rewrites the rest of config.toml, dropping
  # every comment and reformatting other entries (values stay the same).
  echo "codex mcp add also rewrites the rest of config.toml: comments are dropped."
  if [[ $YES != yes ]]; then
    ask "Replace it? A backup of config.toml is made first. (yes/no): " || REPLY=""
    if [[ $REPLY != yes ]]; then
      info "nothing changed"
      finish
    fi
  fi
  if [[ -f $CODEX_CONFIG ]]; then
    cp -p "$CODEX_CONFIG" "$CODEX_CONFIG.bak-$STAMP"
    info "backup: $CODEX_CONFIG.bak-$STAMP"
  fi
fi

if ! codex mcp add "$NAME" -- ssh "${want[@]}" >/dev/null 2>&1; then
  fail "codex mcp add failed"
  finish
fi
if read_codex_server "$NAME" && [[ $CODEX_COMMAND == ssh && ${CODEX_ARGS[*]} == "${want[*]}" ]]; then
  done_ "Codex's '$NAME' entry now runs: ssh ${want[*]}"
  info "Codex's default startup timeout applies now; restart Codex to pick up the change"
else
  fail "Codex's '$NAME' entry does not read back as written"
  finish
fi

[[ $DOCTOR == yes ]] && { echo; SERVER=$NAME exec "$HERE/doctor.sh"; }
finish
