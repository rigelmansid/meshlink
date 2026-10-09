#!/usr/bin/env bash
# Downloads and installs the newest meshlink release on this Mac (D-32):
#
#   curl -fsSL https://raw.githubusercontent.com/rigelmansid/meshlink/main/get.sh | bash
#
# It finds the newest release on GitHub (prereleases included), checks the
# archive against its SHA-256 file, runs the install.sh inside it (files in
# ~/.local, no sudo) and, if ~/.local/bin is not in PATH yet, adds it to the
# shell's startup file (~/.zshrc for zsh, ~/.bash_profile for bash). Run it
# again to upgrade. It never touches ~/.ssh or Codex's config.
#
# To read it before it runs: download it, read it, then `bash get.sh`.
#
#   MESHLINK_VERSION=0.3.0-dev   install that version instead of the newest
#   MESHLINK_NO_MODIFY_PATH=1    leave the shell's startup file alone
#
# Everything is inside one function called on the last line, so a download
# cut short runs nothing.
set -uo pipefail

meshlink_get() {
  local repo=rigelmansid/meshlink
  # Overridable for tests only. The feed, not the REST API: the API allows 60
  # anonymous requests an hour per address, which a shared network runs out of.
  local feed=${MESHLINK_FEED:-https://github.com/$repo/releases.atom}
  local download=${MESHLINK_DOWNLOAD:-https://github.com/$repo/releases/download}
  local bin="$HOME/.local/bin"
  local version tag name tmp t

  die() { echo "meshlink get: $*" >&2; exit 1; }

  [[ $(uname -s) == Darwin ]] || die "meshlink's command runs on macOS only"
  for t in curl tar shasum; do
    command -v "$t" >/dev/null 2>&1 || die "$t not found"
  done

  version=${MESHLINK_VERSION:-}
  if [[ -z $version ]]; then
    # Newest first, prereleases included (/releases/latest leaves them out).
    # Each entry's id ends in its tag: tag:github.com,2008:Repository/<n>/<tag>
    tag=$(curl -fsSL "$feed" 2>/dev/null |
          grep -o 'Repository/[0-9]*/[^<]*</id>' | head -1 | sed 's#</id>$##; s#^.*/##')
    [[ -n $tag ]] || die "could not find the newest release on GitHub; check the network, or set MESHLINK_VERSION"
    version=${tag#v}
  fi
  version=${version#v}
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "not a meshlink version: $version"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/meshlink-get.XXXXXX") || die "could not create a temporary directory"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  name="meshlink-$version.tar.gz"
  echo "downloading meshlink $version"
  curl -fsSL -o "$tmp/$name" "$download/v$version/$name" &&
    curl -fsSL -o "$tmp/$name.sha256" "$download/v$version/$name.sha256" ||
    die "could not download $name from $download/v$version/"
  (cd "$tmp" && shasum -a 256 -c "$name.sha256" >/dev/null 2>&1) ||
    die "$name does not match its SHA-256 file; nothing was installed"
  tar -xzf "$tmp/$name" -C "$tmp" || die "could not unpack $name"
  [[ -x $tmp/meshlink-$version/install.sh ]] || die "$name has no install.sh"

  # install.sh only prints PATH advice; this script acts on it below instead.
  PATH="$bin:$PATH" "$tmp/meshlink-$version/install.sh" || die "install.sh failed"

  case ":$PATH:" in
    *":$bin:"*) return 0 ;;
  esac
  local shell rc line='export PATH="$HOME/.local/bin:$PATH"'
  shell=$(basename "${SHELL:-}")
  case $shell in
    zsh) rc="$HOME/.zshrc" ;;
    bash) rc="$HOME/.bash_profile" ;;
    *) rc="" ;;
  esac
  echo
  if [[ ${MESHLINK_NO_MODIFY_PATH:-} == 1 || -z $rc ]]; then
    echo "$bin is not in your PATH. Add this line to your shell's startup file:"
    echo "  $line"
    return 0
  fi
  if ! grep -qxF "$line" "$rc" 2>/dev/null; then
    printf '\n# Added by meshlink get.sh\n%s\n' "$line" >>"$rc" || die "could not write to $rc"
    echo "added $bin to PATH in $rc"
  fi
  echo "open a new terminal window to use the meshlink command"
}

meshlink_get "$@"
