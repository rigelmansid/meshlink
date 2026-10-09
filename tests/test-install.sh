#!/usr/bin/env bash
# Verification harness for scripts/package.sh, install.sh, uninstall.sh and
# bin/meshlink.
#
# Builds a real release archive, unpacks it, and installs into a temporary
# HOME with a fake codex first in PATH, so the real ~/.local, ~/.ssh and Codex
# config are never touched.
#
# Scenarios:
#   I1  package: archive + checksum, only the listed files
#   I2  install into an empty home                  -> launcher, files, PATH hint
#   I3  meshlink dispatch                           -> version, windows-script, usage errors, doctor
#   I4  reinstall and upgrade                       -> new version, no leftovers
#   I5  someone else's ~/.local/bin/meshlink        -> refused, file untouched
#   I6  install.sh run from the installed copy      -> refused
#   I7  uninstall, keep Codex entry                 -> only meshlink's files gone
#   I8  uninstall, remove Codex entry               -> backup, codex mcp remove
#
# Usage: tests/test-install.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/meshlink-install-test.XXXXXX")"
BIN="$WORK/fakebin"
mkdir -p "$BIN"
SYS_PATH=/usr/bin:/bin:/usr/sbin:/sbin
VERSION=$(cat "$ROOT/VERSION")
trap 'rm -rf "$WORK" "$ROOT/dist/meshlink-$VERSION.tar.gz" "$ROOT/dist/meshlink-$VERSION.tar.gz.sha256"; rmdir "$ROOT/dist" 2>/dev/null' EXIT

cat >"$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
# fake codex: an entry exists while $CODEX_HOME/rhino.json does; remove logs.
case "$1 $2" in
  "--version "*) echo "codex-cli 0.0.0-fake" ;;
  "mcp get") [[ -f $CODEX_HOME/$3.json ]] && cat "$CODEX_HOME/$3.json" || exit 1 ;;
  "mcp remove") echo "remove $3" >>"$CODEX_HOME/calls.log"; rm -f "$CODEX_HOME/$3.json" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$BIN/codex"

pass=0; fail=0
ok()  { echo "  ok   : $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL : $1"; fail=$((fail + 1)); }
check() { # description command...
  local d=$1; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
has()     { grep -qF -- "$2" "$1" && ok "$3" || bad "$3 (missing [$2] in $1)"; }
exit_is() { [[ $1 == "$2" ]] && ok "$3" || bad "$3 (exit $1, want $2)"; }

# in_home NAME LOG [VAR=value...] -- command...   (HOME=$H, fake codex in PATH)
in_home() {
  local log=$1; shift
  local envs=()
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done
  shift
  env -i HOME="$H" CODEX_HOME="$H/.codex" PATH="$BIN:$SYS_PATH" TMPDIR="$WORK" \
      ${envs[@]+"${envs[@]}"} "$@" >"$log" 2>&1
  rc=$?
}

echo "I1 package"
"$ROOT/scripts/package.sh" >"$WORK/pkg.log" 2>&1
exit_is "$?" 0 "package.sh exits 0"
tarball="$ROOT/dist/meshlink-$VERSION.tar.gz"
check "checksum verifies" bash -c "cd '$ROOT/dist' && shasum -a 256 -c 'meshlink-$VERSION.tar.gz.sha256' >/dev/null"
listed=$("$ROOT/install.sh" --list | sort)
packed=$(tar -tzf "$tarball" | grep -v '/$' | sed "s|^meshlink-$VERSION/||" | sort)
[[ $listed == "$packed" ]] && ok "archive holds exactly install.sh --list" || bad "archive holds exactly install.sh --list"
tar -tzf "$tarball" | grep -q '/\._' && bad "no ._ metadata files" || ok "no ._ metadata files"
owners=$(tar -tvzf "$tarball" | awk '{print $3 ":" $4}' | sort -u)
[[ $owners == "root:wheel" ]] && ok "archive owner is root:wheel, not the builder" ||
  bad "archive owner is root:wheel, not the builder ($owners)"
gzcat "$tarball" | LC_ALL=C grep -aqE 'xattr|com\.apple' && bad "no macOS extended attributes" ||
  ok "no macOS extended attributes"
mkdir -p "$WORK/rel" && tar -xzf "$tarball" -C "$WORK/rel"
REL="$WORK/rel/meshlink-$VERSION"

echo "I2 install into an empty home"
H="$WORK/home"
mkdir -p "$H/.codex" "$H/.local/bin"
echo "other" >"$H/.local/bin/other-tool"
in_home "$WORK/i2.log" -- "$REL/install.sh"
exit_is "$rc" 0 "exit 0"
check "launcher is executable" test -x "$H/.local/bin/meshlink"
check "files installed" test -f "$H/.local/share/meshlink/scripts/doctor.sh"
check "INSTALLED record written" test -f "$H/.local/share/meshlink/INSTALLED"
has "$WORK/i2.log" "is not in your PATH" "PATH hint when ~/.local/bin is missing from PATH"
in_home "$WORK/i2b.log" PATH="$H/.local/bin:$BIN:$SYS_PATH" -- "$REL/install.sh"
grep -q "is not in your PATH" "$WORK/i2b.log" && bad "no PATH hint when it is in PATH" || ok "no PATH hint when it is in PATH"

echo "I3 meshlink dispatch"
M="$H/.local/bin/meshlink"
in_home "$WORK/i3a.log" -- "$M" version
[[ $(cat "$WORK/i3a.log") == "meshlink $VERSION" ]] && ok "version" || bad "version ($(cat "$WORK/i3a.log"))"
in_home "$WORK/i3b.log" -- "$M" windows-script
check "windows-script points at the installed file" test -f "$(cat "$WORK/i3b.log")"
in_home "$WORK/i3c.log" -- "$M" client
exit_is "$rc" 2 "client without codex: usage error"
in_home "$WORK/i3d.log" -- "$M" bogus
exit_is "$rc" 2 "unknown command: usage error"
in_home "$WORK/i3e.log" -- "$M" doctor
exit_is "$rc" 1 "doctor runs (and fails: no rhino entry)"
has "$WORK/i3e.log" "add one with meshlink client codex" "hints name meshlink commands"
in_home "$WORK/i3f.log" -- "$M" setup --help
has "$WORK/i3f.log" "First-time setup on the Mac" "setup --help"
in_home "$WORK/i3g.log" -- "$M" doctor --help
exit_is "$rc" 0 "doctor --help exits 0"
has "$WORK/i3g.log" "Read-only health check" "doctor --help prints usage, not a check"

echo "I4 reinstall and upgrade"
cp -R "$REL" "$WORK/rel2"
echo "9.9.9" >"$WORK/rel2/VERSION"
in_home "$WORK/i4.log" -- "$WORK/rel2/install.sh"
exit_is "$rc" 0 "upgrade exits 0"
has "$WORK/i4.log" "meshlink $VERSION -> 9.9.9" "upgrade reported"
in_home "$WORK/i4b.log" -- "$M" version
has "$WORK/i4b.log" "meshlink 9.9.9" "new version runs"
leftover=$(ls -d "$H/.local/share/meshlink."* 2>/dev/null)
[[ -z $leftover ]] && ok "no staging or old dirs left" || bad "no staging or old dirs left ($leftover)"

echo "I5 someone else's launcher"
H="$WORK/home5"
mkdir -p "$H/.local/bin"
printf '#!/bin/sh\necho mine\n' >"$H/.local/bin/meshlink"
cp "$H/.local/bin/meshlink" "$WORK/mine"
in_home "$WORK/i5.log" -- "$REL/install.sh"
exit_is "$rc" 1 "refused"
cmp -s "$H/.local/bin/meshlink" "$WORK/mine" && ok "foreign file untouched" || bad "foreign file untouched"
check "nothing installed" test ! -d "$H/.local/share/meshlink"

echo "I6 install.sh from the installed copy"
H="$WORK/home"
in_home "$WORK/i6.log" -- "$H/.local/share/meshlink/install.sh"
exit_is "$rc" 1 "refused"

echo "I7 uninstall, keep the Codex entry"
echo '{"name": "rhino"}' >"$H/.codex/rhino.json"
printf '# my comment\n[mcp_servers.rhino]\n' >"$H/.codex/config.toml"
mkdir -p "$H/.ssh"
printf '# Added by scripts/setup.sh on x\nHost rhino-pc\n' >"$H/.ssh/config"
cp "$H/.ssh/config" "$WORK/ssh.before"
in_home "$WORK/i7.log" -- "$M" uninstall <<<"no"  # not a pipe: rc must reach this shell
exit_is "$rc" 0 "exit 0"
check "launcher removed" test ! -e "$H/.local/bin/meshlink"
check "files removed" test ! -d "$H/.local/share/meshlink"
check "other tools in ~/.local/bin kept" test -f "$H/.local/bin/other-tool"
check "Codex entry kept" test -f "$H/.codex/rhino.json"
[[ ! -f $H/.codex/calls.log ]] && ok "codex mcp remove not called" || bad "codex mcp remove not called"
cmp -s "$H/.ssh/config" "$WORK/ssh.before" && ok "~/.ssh untouched" || bad "~/.ssh untouched"
has "$WORK/i7.log" "Left in place" "what was left is listed"

echo "I8 uninstall, remove the Codex entry"
in_home "$WORK/i8a.log" -- "$REL/install.sh"
in_home "$WORK/i8.log" -- "$H/.local/bin/meshlink" uninstall --remove-codex
exit_is "$rc" 0 "exit 0"
has "$H/.codex/calls.log" "remove rhino" "codex mcp remove rhino called"
ls "$H/.codex" | grep -q '^config.toml.bak-' && ok "config.toml backed up first" || bad "config.toml backed up first"
in_home "$WORK/i8b.log" -- "$REL/uninstall.sh"
exit_is "$rc" 1 "second uninstall: nothing to remove"

echo
echo "passed: $pass  failed: $fail"
((fail == 0))
