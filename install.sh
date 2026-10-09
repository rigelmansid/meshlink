#!/usr/bin/env bash
# Installs meshlink for the current user, from an unpacked release or a
# checkout. No sudo.
#
#   files      ~/.local/share/meshlink/      (replaced whole on every install)
#   command    ~/.local/bin/meshlink          (a two-line launcher)
#
# Run it again to upgrade. It never touches ~/.ssh or Codex's config; that is
# what `meshlink setup` and `meshlink client codex` are for, when asked.
#
# Usage:  ./install.sh            PREFIX=/other/prefix ./install.sh
#         ./install.sh --list     print the files a release must contain
set -uo pipefail

# The one list of what gets installed; scripts/package.sh builds releases
# from it too.
FILES=(
  VERSION LICENSE README.md install.sh uninstall.sh
  bin/meshlink
  scripts/lib/common.sh scripts/lib/sshcfg.sh scripts/lib/pairing.sh
  scripts/setup.sh scripts/pair.sh scripts/client-codex.sh scripts/doctor.sh
  scripts/rhino-tunnel.sh scripts/prepare-windows.ps1
  docs/remote-setup.md
)
if [[ ${1:-} == --list ]]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
DEST="$PREFIX/share/meshlink"
BIN="$PREFIX/bin"
LAUNCHER="$BIN/meshlink"
MARK="# meshlink launcher, written by install.sh"

die() { echo "install: $*" >&2; exit 1; }

# Compare physical paths: HOME may be a symlink or contain "//".
if [[ -d $DEST && $(cd "$SRC" && pwd -P) == "$(cd "$DEST" && pwd -P)" ]]; then
  die "this is the installed copy; run install.sh from an unpacked release"
fi
for f in "${FILES[@]}"; do
  [[ -f $SRC/$f ]] || die "missing $f in $SRC (not a complete release?)"
done
# Never overwrite a meshlink command that some other tool put there.
if [[ -e $LAUNCHER ]] && ! grep -qxF "$MARK" "$LAUNCHER" 2>/dev/null; then
  die "$LAUNCHER exists and was not written by meshlink; move it away and run this again"
fi

new_version=$(cat "$SRC/VERSION")
old_version=$(cat "$DEST/VERSION" 2>/dev/null || true)

# Build the new tree next to the old one, then swap, so a failed copy never
# leaves a half-installed meshlink behind.
mkdir -p "$PREFIX/share" "$BIN" || die "cannot create $PREFIX/share or $BIN"
stage="$DEST.new-$$"
rm -rf "$stage"
for f in "${FILES[@]}"; do
  mkdir -p "$stage/$(dirname "$f")" && cp -p "$SRC/$f" "$stage/$f" || {
    rm -rf "$stage"
    die "copying $f failed"
  }
done
printf '%s\n' "$LAUNCHER" "$DEST" >"$stage/INSTALLED"
if [[ -d $DEST ]]; then
  rm -rf "$DEST.old-$$"
  mv "$DEST" "$DEST.old-$$" || die "cannot move the old $DEST aside"
fi
mv "$stage" "$DEST" || die "cannot move the new files into $DEST"
rm -rf "$DEST.old-$$"

printf '#!/bin/sh\n%s\nexec "%s/bin/meshlink" "$@"\n' "$MARK" "$DEST" >"$LAUNCHER"
chmod 755 "$LAUNCHER"

if [[ -n $old_version ]]; then
  echo "meshlink $old_version -> $new_version installed in $DEST"
else
  echo "meshlink $new_version installed in $DEST"
fi
echo "command: $LAUNCHER"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    echo
    echo "$BIN is not in your PATH. Add it, for zsh:"
    echo "  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
esac
echo
echo "next: meshlink pair (with the meshlink plug-in in Rhino on the PC), or meshlink setup --help"
