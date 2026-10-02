#!/usr/bin/env bash
# Builds a release archive from this checkout:
#
#   dist/meshlink-<VERSION>.tar.gz          the files install.sh --list names
#   dist/meshlink-<VERSION>.tar.gz.sha256   check with: shasum -a 256 -c <file>
#
# Uploading it anywhere is a separate, manual step.
#
# Usage:  scripts/package.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(cat "$ROOT/VERSION")
NAME="meshlink-$VERSION"
DIST="$ROOT/dist"

die() { echo "package: $*" >&2; exit 1; }

files=()
while IFS= read -r f; do files+=("$f"); done < <("$ROOT/install.sh" --list)
((${#files[@]})) || die "install.sh --list printed nothing"

rm -rf "$DIST/$NAME" "$DIST/$NAME.tar.gz" "$DIST/$NAME.tar.gz.sha256"
mkdir -p "$DIST/$NAME" || die "cannot create $DIST/$NAME"
for f in "${files[@]}"; do
  [[ -f $ROOT/$f ]] || die "missing $f"
  mkdir -p "$DIST/$NAME/$(dirname "$f")"
  cp -p "$ROOT/$f" "$DIST/$NAME/$f"
done

# COPYFILE_DISABLE keeps macOS tar from adding ._ metadata files. tar also
# records each file's owner, which would be the builder's login name; store a
# neutral root:wheel instead, and leave out macOS extended attributes.
(cd "$DIST" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --uid 0 --gid 0 --uname root --gname wheel \
   -czf "$NAME.tar.gz" "$NAME") || die "tar failed"
(cd "$DIST" && shasum -a 256 "$NAME.tar.gz" >"$NAME.tar.gz.sha256") || die "shasum failed"
rm -rf "$DIST/$NAME"

echo "built $DIST/$NAME.tar.gz (${#files[@]} files)"
cat "$DIST/$NAME.tar.gz.sha256"
