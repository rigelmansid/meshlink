#!/usr/bin/env bash
# Builds the Rhino plug-in's Yak package (D-24):
#   dist/meshlink-<version>-rh8_<minor>-win.yak, and a .sha256 next to it
# yak works out the Rhino version tag from the .rhp. Install the package by
# dragging it onto Rhino, or with the Package Manager; uninstall it there.
# Publishing it is a separate step, and the user's decision.
#
# Needs the .NET SDK (D-21) and McNeel's yak tool: YAK=/path/to/yak, or yak
# on PATH (standalone downloads: developer.rhino3d.com, Yak CLI reference).
#
# Usage: YAK=/path/to/yak scripts/package-yak.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/rhino-plugin/Meshlink.Rhino"
YAK=${YAK:-$(command -v yak || true)}

if [[ -z $YAK || ! -x $YAK ]]; then
  echo "package-yak: yak not found; set YAK=/path/to/yak" >&2
  exit 2
fi
# yak runs from the package folder below, so a relative path would break.
YAK="$(cd "$(dirname "$YAK")" && pwd)/$(basename "$YAK")"
command -v dotnet >/dev/null 2>&1 || { echo "package-yak: dotnet not found; install the .NET SDK" >&2; exit 2; }

# One version, the plug-in's own: yak would read a git hash into it otherwise.
VERSION=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$PROJECT/Meshlink.Rhino.csproj")
if [[ -z $VERSION ]]; then
  echo "package-yak: no <Version> in Meshlink.Rhino.csproj" >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/meshlink-yak.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# yak packs every file in the folder it runs in, so only the package goes there.
PKG="$WORK/package"

if ! DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
     dotnet build "$PROJECT" -c Release -o "$PKG" >"$WORK/build.log" 2>&1; then
  tail -20 "$WORK/build.log" >&2
  exit 1
fi
mkdir -p "$PKG/misc"
cp "$ROOT/LICENSE" "$PKG/misc/LICENSE.txt"
cat >"$PKG/manifest.yml" <<MANIFEST
name: meshlink
version: $VERSION
authors:
  - Cheng Yuan
description: >
  Pairs this Windows PC with a Mac, so that an AI agent on the Mac can use
  Rhino here over SSH through rhinomcp. When a Mac runs "meshlink pair",
  Rhino asks whether to pair; once both people confirm the same six-digit
  code, the plug-in installs the Mac's SSH key and from then on starts
  rhinomcp's listener when Rhino opens. Needs OpenSSH Server and rhinomcp.
url: "https://github.com/rigelmansid/meshlink"
keywords:
  - mcp
  - rhinomcp
  - ssh
  - pairing
MANIFEST

if ! (cd "$PKG" && "$YAK" build --platform win) >"$WORK/yak.log" 2>&1; then
  cat "$WORK/yak.log" >&2
  exit 1
fi
built=("$PKG"/*.yak)
name=$(basename "${built[0]}")
mkdir -p "$ROOT/dist"
mv "${built[0]}" "$ROOT/dist/$name"
(cd "$ROOT/dist" && shasum -a 256 "$name" >"$name.sha256")
echo "dist/$name"
