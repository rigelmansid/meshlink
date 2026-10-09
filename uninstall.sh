#!/usr/bin/env bash
# Removes what install.sh installed: ~/.local/share/meshlink and the meshlink
# launcher. Nothing else is deleted without asking.
#
# Codex's MCP entry is removed only after a yes (or --remove-codex). Like
# `codex mcp add`, `codex mcp remove` rewrites config.toml without its comments
# (pitfall 19), so a backup is made first. ~/.ssh is never changed; the entries
# and key that `meshlink setup` made are listed so they can be removed by hand.
#
# Usage:  meshlink uninstall [--remove-codex | --keep-codex] [--name rhino]
set -uo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
DEST="$PREFIX/share/meshlink"
LAUNCHER="$PREFIX/bin/meshlink"
MARK="# meshlink launcher, written by install.sh"
CODEX=ask
NAME=rhino

while (($#)); do
  case $1 in
    --remove-codex) CODEX=yes; shift ;;
    --keep-codex) CODEX=no; shift ;;
    --name) NAME=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [[ ! -f $DEST/INSTALLED ]]; then
  echo "uninstall: no meshlink installation found in $DEST" >&2
  exit 1
fi

# --------------------------------------------------------- Codex's entry
if command -v codex >/dev/null 2>&1 && codex mcp get "$NAME" --json >/dev/null 2>&1; then
  if [[ $CODEX == ask ]]; then
    printf "Also remove Codex's '%s' MCP entry? Its comments in config.toml go too; a backup is made. (yes/no) [no]: " "$NAME"
    IFS= read -r reply || reply=""
    [[ $reply == yes ]] && CODEX=yes || CODEX=no
  fi
  if [[ $CODEX == yes ]]; then
    cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
    if [[ -f $cfg ]]; then
      cp -p "$cfg" "$cfg.bak-$(date +%Y%m%d-%H%M%S)"
      echo "backup of $cfg made"
    fi
    if codex mcp remove "$NAME" >/dev/null 2>&1; then
      echo "removed Codex's '$NAME' entry"
    else
      echo "codex mcp remove $NAME failed; Codex's config is unchanged" >&2
    fi
  else
    echo "kept Codex's '$NAME' entry"
  fi
fi

# ------------------------------------------------------------------ files
if [[ -f $LAUNCHER ]] && grep -qxF "$MARK" "$LAUNCHER"; then
  rm -f "$LAUNCHER"
  echo "removed $LAUNCHER"
fi
# Last, since this script may itself live in $DEST.
case $DEST in
  */share/meshlink) rm -rf "$DEST" && echo "removed $DEST" ;;
  *) echo "uninstall: refusing to delete unexpected path $DEST" >&2; exit 1 ;;
esac

# ------------------------------------------------------------ left as is
left=()
ssh_cfg="$HOME/.ssh/config"
if [[ -f $ssh_cfg ]] && grep -qE '^# Added by scripts/(setup|pair)\.sh' "$ssh_cfg"; then
  left+=("Host entries in ~/.ssh/config added by setup or pair (each starts with '# Added by scripts/setup.sh' or '# Added by scripts/pair.sh')"
         "the key ~/.ssh/id_ed25519_rhino(.pub), if setup or pair created it"
         "the PC's line in ~/.ssh/known_hosts (ssh-keygen -R <pc-address>)"
         "on the PC: the public key (MeshlinkUnpair in Rhino removes a paired Mac's), the firewall rule and the sshd_config settings")
fi
# get.sh adds ~/.local/bin to PATH; other tools may install there too.
for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
  if grep -qxF '# Added by meshlink get.sh' "$rc" 2>/dev/null; then
    left+=("the PATH line in ${rc/#$HOME/~} after '# Added by meshlink get.sh' (other tools in ~/.local/bin may use it)")
  fi
done
if ((${#left[@]})); then
  echo
  echo "Left in place (remove by hand if you no longer need them):"
  printf '  %s\n' "${left[@]}"
fi
