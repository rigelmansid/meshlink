#!/usr/bin/env bash
# Verification harness for scripts/setup.sh and scripts/client-codex.sh.
#
# HOME points at a temp dir, and PATH puts a fake ssh, ssh-keyscan and codex
# first, so the real ~/.ssh, Codex config and PC are never touched. ssh -G is
# passed to the real ssh (setup.sh always names the config file with -F), and
# the real ssh-keygen makes keys and fingerprints, since both are what is
# being tested.
#
# Scenarios:
#   S1  fresh Mac: key, config, Windows command, fingerprint, login    -> exit 0
#   S2  run again                                -> nothing changes, no wait
#   S2b rerun without --key                       -> the Host entry's key is used
#   S3  alias exists with another account        -> WARN, config untouched
#   S4  config with Include and "Host *"         -> entry after Include, before Host *
#   S5  --fingerprint does not match             -> FAIL, known_hosts untouched
#   S6  known_hosts has another key for the PC   -> FAIL
#   S7  fingerprint asked: "yes" / "no"          -> trusted / FAIL
#   C1  no entry; config with comments, another server -> appended, the rest kept byte for byte
#   C2  identical entry                          -> nothing written
#   C3  different entry, answer "no"             -> says only command/args change; nothing changes
#   C4  different entry, --yes                   -> backup; only command and args lines changed
#   C5  path with a space; no config; exe missing -> quoted; file created 600; FAIL, nothing written
#   C6  args over several lines                  -> falls back to codex mcp add, lists what it drops
#   C7  config Codex cannot read                 -> FAIL, left alone
#   C8  config without a final newline           -> new table on its own line
#   C9  Codex reads env differently after edit   -> FAIL, restored from the backup
#
# Usage: tests/test-setup.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/scripts/setup.sh"
CLIENT="$ROOT/scripts/client-codex.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rhino-setup-test.XXXXXX")"
BIN="$WORK/bin"
mkdir -p "$BIN"
SYS_PATH=/usr/bin:/bin:/usr/sbin:/sbin
trap 'rm -rf "$WORK"' EXIT

ssh-keygen -q -t ed25519 -N "" -f "$WORK/hostkey"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/otherkey"
FP=$(ssh-keygen -lf "$WORK/hostkey.pub" | awk '{print $2}')

# ------------------------------------------------------------------ fakes
cat >"$BIN/ssh" <<'FAKE'
#!/usr/bin/env bash
# fake ssh: -G goes to the real ssh; otherwise answers by remote command.
# FAKE_LOGIN ok|denied, FAKE_PROFILE, FAKE_RMCP yes|no
for a in "$@"; do [[ $a == -G ]] && exec /usr/bin/ssh "$@"; done
[[ -n ${FAKE_ARGS_FILE:-} ]] && printf '%s\n' "$*" >>"$FAKE_ARGS_FILE"
if [[ ${FAKE_LOGIN:-ok} == denied ]]; then
  echo "agent@pc: Permission denied (publickey,keyboard-interactive)." >&2
  exit 255
fi
remote=${!#}
case $remote in
  "echo setup-ok") printf 'setup-ok\r\n' ;;
  *PROFILE=*) printf 'PROFILE=%s\r\n' "${FAKE_PROFILE:-C:\\Users\\agent}" ;;
  *"if exist"*) printf 'RMCP=%s\r\n' "${FAKE_RMCP:-yes}" ;;
  *) echo "fake ssh: unexpected: $remote" >&2; exit 1 ;;
esac
FAKE

cat >"$BIN/ssh-keyscan" <<'FAKE'
#!/usr/bin/env bash
# fake ssh-keyscan: prints $FAKE_HOSTKEY for the last argument.
[[ ${FAKE_SCAN:-ok} == fail ]] && exit 1
echo "# ${!#}:22 SSH-2.0-OpenSSH_for_Windows_fake"
echo "${!#} $(cut -d' ' -f1,2 "$FAKE_HOSTKEY")"
FAKE

cat >"$BIN/codex" <<'FAKE'
#!/usr/bin/env python3
# fake codex: reads $CODEX_HOME/config.toml the way Codex does, for the few
# shapes the tests use, and fails on a file it cannot parse, as Codex does.
# `mcp get NAME --json` and `mcp list --json` print what Codex 0.160 prints;
# `mcp add NAME -- CMD ARGS...` logs the call to add.log and rewrites the
# whole file without its comments, as Codex does (pitfall 19).
# FAKE_DROP_ENV_IF_CHANGED=FILE makes `mcp get` lose the entry's env once
# config.toml differs from FILE: a write that Codex reads differently.
import json, os, re, sys

home = os.environ["CODEX_HOME"]
path = os.path.join(home, "config.toml")


class Bad(Exception):
    pass


def value(text):
    """Parses one TOML value at the start of text; returns (value, rest)."""
    text = text.lstrip()
    if text.startswith('"'):
        out, i = [], 1
        while i < len(text):
            c = text[i]
            if c == "\\":
                out.append({"\\": "\\", '"': '"', "n": "\n", "t": "\t"}[text[i + 1]])
                i += 2
                continue
            if c == '"':
                return "".join(out), text[i + 1:]
            out.append(c)
            i += 1
        raise Bad("unterminated string")
    if text.startswith("["):
        items, rest = [], text[1:]
        while True:
            rest = rest.lstrip()
            if rest.startswith("]"):
                return items, rest[1:]
            v, rest = value(rest)
            items.append(v)
            rest = rest.lstrip()
            if rest.startswith(","):
                rest = rest[1:]
            elif not rest.startswith("]"):
                raise Bad("bad array")
    m = re.match(r"(true|false|[0-9]+(\.[0-9]+)?)", text)
    if not m:
        raise Bad("bad value: " + text)
    t = m.group(1)
    v = {"true": True, "false": False}.get(t)
    if v is None:
        v = float(t) if "." in t else int(t)
    return v, text[m.end():]


def load():
    tables, order, cur = {"": {}}, [""], ""
    if not os.path.exists(path):
        return tables, order
    lines = open(path).read().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i += 1
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^\[\s*([A-Za-z0-9_.-]+)\s*\]\s*(#.*)?$", line)
        if m:
            cur = m.group(1)
            if cur in tables:
                raise Bad("duplicate table " + cur)
            tables[cur] = {}
            order.append(cur)
            continue
        m = re.match(r"^([A-Za-z0-9_-]+)\s*=\s*(.*)$", line)
        if not m:
            raise Bad("bad line: " + line)
        rest = m.group(2)
        while rest.count("[") > rest.count("]") and i < len(lines):
            rest += " " + lines[i].strip()
            i += 1
        v, tail = value(rest)
        tail = tail.strip()
        if tail and not tail.startswith("#"):
            raise Bad("trailing text: " + tail)
        tables[cur][m.group(1)] = v
    return tables, order


def entry(name, tables):
    t = tables["mcp_servers." + name]
    env = tables.get("mcp_servers." + name + ".env")
    ref = os.environ.get("FAKE_DROP_ENV_IF_CHANGED")
    if ref and open(path).read() != open(ref).read():
        env = None
    timeout = t.get("startup_timeout_sec")
    return {
        "name": name, "enabled": True, "disabled_reason": None,
        "transport": {"type": "stdio", "command": t.get("command"), "args": t.get("args", []),
                      "env": env or None, "env_vars": [], "cwd": None},
        "enabled_tools": None, "disabled_tools": None,
        "startup_timeout_sec": None if timeout is None else float(timeout),
        "tool_timeout_sec": None,
    }


def toml(v):
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, list):
        return "[" + ", ".join(toml(x) for x in v) + "]"
    return str(v).lower() if isinstance(v, bool) else str(v)


args = sys.argv[1:]
try:
    if args[:1] == ["--version"]:
        print("codex-cli 0.0.0-fake")
    elif args[:2] == ["mcp", "get"]:
        tables, _ = load()
        if "mcp_servers." + args[2] not in tables:
            sys.exit(1)
        print(json.dumps(entry(args[2], tables), indent=2))
    elif args[:2] == ["mcp", "list"]:
        tables, _ = load()
        names = [k.split(".")[1] for k in tables if re.match(r"^mcp_servers\.[^.]+$", k)]
        print(json.dumps([entry(n, tables) for n in names], indent=2))
    elif args[:2] == ["mcp", "add"]:
        name, cmd = args[2], args[args.index("--") + 1:]
        with open(os.path.join(home, "add.log"), "a") as f:
            f.write("%s|%s|%s\n" % (name, cmd[0], " ".join(cmd[1:])))
        tables, order = load()
        key = "mcp_servers." + name
        order = [k for k in order if k != key and not k.startswith(key + ".")] + [key]
        tables[key] = {"command": cmd[0], "args": cmd[1:]}
        out = []
        for k in order:
            if k:
                out.append("\n[%s]" % k)
            out += ["%s = %s" % (kk, toml(vv)) for kk, vv in tables[k].items()]
        open(path, "w").write("\n".join(out).lstrip("\n") + "\n")
    else:
        sys.exit(1)
except Bad as e:
    sys.stderr.write("fake codex: cannot read config.toml: %s\n" % e)
    sys.exit(1)
FAKE
chmod +x "$BIN/ssh" "$BIN/ssh-keyscan" "$BIN/codex"

# ---------------------------------------------------------------- harness
pass=0; fail=0
ok()  { echo "  ok   : $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL : $1"; fail=$((fail + 1)); }
has()     { grep -qF -- "$2" "$1" && ok "$3" || bad "$3 (missing [$2] in $1)"; }
hasnt()   { grep -qF -- "$2" "$1" && bad "$3 (unexpected [$2] in $1)" || ok "$3"; }
exit_is() { [[ $1 == "$2" ]] && ok "$3" || bad "$3 (exit $1, want $2)"; }

fresh_home() {
  H="$WORK/home-$1"
  rm -rf "$H"
  mkdir -p "$H/.codex"
}

# run NAME INPUT SCRIPT ARGS... (env: H, plus FAKE_* passed through)
run() {
  local name=$1 input=$2 script=$3
  shift 3
  out="$WORK/$name.log"
  printf '%b' "$input" | env -i HOME="$H" CODEX_HOME="$H/.codex" PATH="$BIN:$SYS_PATH" \
      TMPDIR="$WORK" FAKE_HOSTKEY="${FAKE_HOSTKEY:-$WORK/hostkey.pub}" \
      FAKE_LOGIN="${FAKE_LOGIN:-ok}" FAKE_RMCP="${FAKE_RMCP:-yes}" \
      FAKE_PROFILE="${FAKE_PROFILE:-C:\\Users\\agent}" \
      FAKE_DROP_ENV_IF_CHANGED="${FAKE_DROP_ENV_IF_CHANGED:-}" \
      /bin/bash "$script" "$@" >"$out" 2>&1
  rc=$?
}

# ------------------------------------------------------------ setup cases
echo "S1 fresh Mac"
fresh_home s1
run s1 '\n' "$SETUP" --address 192.0.2.9 --user agent --fingerprint "$FP"
exit_is "$rc" 0 "exit 0"
[[ -f $H/.ssh/id_ed25519_rhino && -f $H/.ssh/id_ed25519_rhino.pub ]] && ok "key pair created" || bad "key pair created"
[[ $(stat -f %Lp "$H/.ssh") == 700 && $(stat -f %Lp "$H/.ssh/config") == 600 ]] &&
  ok "~/.ssh is 700 and config 600" || bad "~/.ssh is 700 and config 600"
has "$H/.ssh/config" "Host rhino-pc" "config has the Host entry"
has "$H/.ssh/config" "IdentityFile ~/.ssh/id_ed25519_rhino" "IdentityFile written with ~"
has "$out" "-User agent -PublicKey \"ssh-ed25519 " "Windows command carries the public key"
[[ $(cut -d' ' -f3- "$H/.ssh/id_ed25519_rhino.pub") == meshlink ]] && ok "key comment is 'meshlink', not user@host" ||
  bad "key comment is 'meshlink', not user@host ($(cut -d' ' -f3- "$H/.ssh/id_ed25519_rhino.pub"))"
has "$H/.ssh/known_hosts" "192.0.2.9 ssh-ed25519 " "host key trusted under the address"
has "$out" "[ OK ] ssh rhino-pc logs in as agent" "test login"
[[ $(/usr/bin/ssh -F "$H/.ssh/config" -G rhino-pc | awk '$1=="user"{print $2}') == agent ]] &&
  ok "ssh -G resolves user agent" || bad "ssh -G resolves user agent"

echo "S2 run again"
cp "$H/.ssh/config" "$WORK/s1.config"
run s2 '' "$SETUP" --address 192.0.2.9 --user agent
exit_is "$rc" 0 "exit 0"
cmp -s "$H/.ssh/config" "$WORK/s1.config" && ok "config unchanged" || bad "config unchanged"
hasnt "$out" "prepare-windows.ps1 -User" "no Windows step when already working"
has "$out" "already trusted" "host key recognised"
[[ -z $(ls "$H/.ssh" | grep bak-) ]] && ok "no backup made" || bad "no backup made"

echo "S2b rerun without --key uses the entry's key"
fresh_home s2b
run s2b1 '\n' "$SETUP" --host other-pc --address 192.0.2.9 --user agent --key "$H/.ssh/id_other" --fingerprint "$FP"
exit_is "$rc" 0 "first run with --key"
run s2b2 '' "$SETUP" --host other-pc
has "$out" "key ~/.ssh/id_other already exists" "rerun picks the key named in the Host entry"

echo "S3 alias exists with another account"
H="$WORK/home-s1"   # S3 continues from S1/S2
run s3 '' "$SETUP" --address 192.0.2.9 --user other
cmp -s "$H/.ssh/config" "$WORK/s1.config" && ok "config untouched" || bad "config untouched"
has "$out" "[WARN] it logs in as agent, not other" "difference reported"

echo "S4 Include and Host * already there"
fresh_home s4
mkdir -p "$H/.ssh"
printf 'Include extra.conf\n\nHost *\n    User nobody\n' >"$H/.ssh/config"
: >"$H/.ssh/extra.conf"
run s4 '\n' "$SETUP" --address 192.0.2.9 --user agent --fingerprint "$FP"
exit_is "$rc" 0 "exit 0"
order=$(grep -nE '^(Include|Host)' "$H/.ssh/config" | tr '\n' ' ')
[[ $order == "1:Include extra.conf 4:Host rhino-pc 13:Host * " ]] &&
  ok "entry between Include and Host *" || bad "entry between Include and Host * ($order)"
[[ $(/usr/bin/ssh -F "$H/.ssh/config" -G rhino-pc | awk '$1=="user"{print $2}') == agent ]] &&
  ok "Host * does not override the user" || bad "Host * does not override the user"
ls "$H/.ssh" | grep -q '^config.bak-' && ok "backup of the old config" || bad "backup of the old config"

echo "S5 wrong --fingerprint"
fresh_home s5
run s5 '\n' "$SETUP" --address 192.0.2.9 --user agent --fingerprint SHA256:not-this-one
exit_is "$rc" 1 "exit 1"
has "$out" "is not the expected SHA256:not-this-one" "mismatch reported"
[[ ! -s $H/.ssh/known_hosts ]] && ok "known_hosts untouched" || bad "known_hosts untouched"

echo "S6 known_hosts has another key for the PC"
fresh_home s6
mkdir -p "$H/.ssh"
echo "192.0.2.9 $(cut -d' ' -f1,2 "$WORK/otherkey.pub")" >"$H/.ssh/known_hosts"
FAKE_LOGIN=denied run s6 '\n' "$SETUP" --address 192.0.2.9 --user agent
exit_is "$rc" 1 "exit 1"
has "$out" "does not match the one in" "changed host key reported"
has "$out" "ssh-keygen -R" "removal hint"

echo "S7 fingerprint asked"
fresh_home s7
run s7a '\nyes\n' "$SETUP" --address 192.0.2.9 --user agent
exit_is "$rc" 0 "yes: exit 0"
has "$out" "$FP" "fingerprint shown"
has "$H/.ssh/known_hosts" "192.0.2.9 ssh-ed25519" "yes: trusted"
fresh_home s7b
run s7b '\nno\n' "$SETUP" --address 192.0.2.9 --user agent
exit_is "$rc" 1 "no: exit 1"
[[ ! -s $H/.ssh/known_hosts ]] && ok "no: known_hosts untouched" || bad "no: known_hosts untouched"

# ----------------------------------------------------------- client cases
WANT='rhino|ssh|-T -o BatchMode=yes rhino-pc set RHINO_MCP_TIMEOUT=30&& C:\Users\agent\.local\bin\rhinomcp.exe'
WANT_ARGS='args = ["-T", "-o", "BatchMode=yes", "rhino-pc", "set RHINO_MCP_TIMEOUT=30&& C:\\Users\\agent\\.local\\bin\\rhinomcp.exe"]'
codex_get() { env CODEX_HOME="$H/.codex" PATH="$BIN:$SYS_PATH" codex mcp get rhino --json; }
backups() { ls "$H/.codex" | grep -c '^config.toml.bak-'; }

echo "C1 no entry; config with comments and another server"
fresh_home c1
cat >"$H/.codex/config.toml" <<'TOML'
# my settings
model = "o4"

[mcp_servers.other]
# keep this comment
command = "other"
args = ["--flag"]
TOML
cp "$H/.codex/config.toml" "$WORK/c1.toml"
run c1 '' "$CLIENT" --no-doctor
exit_is "$rc" 0 "exit 0"
[[ ! -f $H/.codex/add.log ]] && ok "codex mcp add not used" || bad "codex mcp add not used"
head -c "$(wc -c <"$WORK/c1.toml")" "$H/.codex/config.toml" | cmp -s - "$WORK/c1.toml" &&
  ok "everything before the new entry kept byte for byte" || bad "everything before the new entry kept byte for byte"
has "$H/.codex/config.toml" "$WANT_ARGS" "args written as TOML, backslashes doubled"
has "$out" "[DONE] Codex's 'rhino' entry now runs" "read back after writing"
has "$out" "the rest of config.toml is unchanged" "says the rest is unchanged"
[[ $(backups) == 1 ]] && ok "backup made" || bad "backup made"

echo "C2 identical entry"
cp "$H/.codex/config.toml" "$WORK/c2.toml"
run c2 '' "$CLIENT" --no-doctor
exit_is "$rc" 0 "exit 0"
has "$out" "already runs" "reported as already set"
cmp -s "$H/.codex/config.toml" "$WORK/c2.toml" && ok "config.toml untouched" || bad "config.toml untouched"
[[ $(backups) == 1 ]] && ok "no new backup" || bad "no new backup"

echo "C3 different entry, answer no"
fresh_home c3
cat >"$H/.codex/config.toml" <<'TOML'
# top comment
[mcp_servers.rhino]
# how rhino runs
command = "/Users/x/.local/bin/rhinomcp"
args = []
startup_timeout_sec = 60

[mcp_servers.rhino.env]
RHINO_MCP_PORT = "1999"

[mcp_servers.rhino.tools.delete_object]
approval_mode = "approve"
TOML
cp "$H/.codex/config.toml" "$WORK/c3.toml"
run c3 'no\n' "$CLIENT" --no-doctor
exit_is "$rc" 0 "exit 0 (declined is not an error)"
has "$out" "Only its command and args change" "says only command and args change"
hasnt "$out" "drops" "nothing listed as dropped"
has "$out" "[INFO] nothing changed" "declined"
cmp -s "$H/.codex/config.toml" "$WORK/c3.toml" && ok "config.toml untouched" || bad "config.toml untouched"
[[ $(backups) == 0 ]] && ok "no backup when declined" || bad "no backup when declined"
[[ -z $(ls "$H/.codex" | grep tmp-) ]] && ok "no temporary file left" || bad "no temporary file left"

echo "C4 different entry, --yes"
run c4 '' "$CLIENT" --yes --no-doctor
exit_is "$rc" 0 "exit 0"
[[ $(backups) == 1 ]] && ok "backup made" || bad "backup made"
[[ ! -f $H/.codex/add.log ]] && ok "codex mcp add not used" || bad "codex mcp add not used"
diff <(grep -vE '^(command|args) = ' "$WORK/c3.toml") <(grep -vE '^(command|args) = ' "$H/.codex/config.toml") >/dev/null &&
  ok "every other line kept, comments included" || bad "every other line kept, comments included"
has "$H/.codex/config.toml" 'command = "ssh"' "command line replaced"
has "$H/.codex/config.toml" "$WANT_ARGS" "args line replaced"
codex_get >"$WORK/c4.json"
has "$WORK/c4.json" '"RHINO_MCP_PORT": "1999"' "Codex still reads the env"
has "$WORK/c4.json" '"startup_timeout_sec": 60.0' "Codex still reads the startup timeout"

echo "C5 path with a space; no config; missing exe"
fresh_home c5
rm -rf "$H/.codex"
FAKE_PROFILE='C:\Users\John Smith' run c5a '' "$CLIENT" --no-doctor
exit_is "$rc" 0 "space: exit 0"
has "$H/.codex/config.toml" 'set RHINO_MCP_TIMEOUT=30&& \"C:\\Users\\John Smith\\.local\\bin\\rhinomcp.exe\"' "space: path quoted in TOML"
[[ $(stat -f %Lp "$H/.codex/config.toml") == 600 ]] && ok "new config.toml is mode 600" || bad "new config.toml is mode 600"
fresh_home c5b
FAKE_RMCP=no run c5b '' "$CLIENT" --no-doctor
exit_is "$rc" 1 "missing: exit 1"
has "$out" "[FAIL] rhinomcp.exe not found at" "missing: reported"
[[ ! -f $H/.codex/config.toml ]] && ok "missing: nothing written" || bad "missing: nothing written"

echo "C6 args over several lines"
fresh_home c6
cat >"$H/.codex/config.toml" <<'TOML'
# a comment Codex will drop
[mcp_servers.rhino]
command = "ssh"
args = [
  "-T",
  "old-host",
]
startup_timeout_sec = 30
TOML
cp "$H/.codex/config.toml" "$WORK/c6.toml"
run c6 'no\n' "$CLIENT" --no-doctor
exit_is "$rc" 0 "no: exit 0"
has "$out" "not in the form Codex writes" "fallback explained"
has "$out" "- drops startup_timeout_sec = 30.0" "lost timeout listed"
has "$out" "- drops every comment in config.toml" "lost comments listed"
cmp -s "$H/.codex/config.toml" "$WORK/c6.toml" && ok "no: config.toml untouched" || bad "no: config.toml untouched"
run c6y '' "$CLIENT" --yes --no-doctor
exit_is "$rc" 0 "yes: exit 0"
[[ $(cat "$H/.codex/add.log" 2>/dev/null) == "$WANT" ]] && ok "yes: codex mcp add with the exact args" ||
  bad "yes: codex mcp add with the exact args ($(cat "$H/.codex/add.log" 2>/dev/null))"
[[ $(backups) == 1 ]] && ok "yes: backup made" || bad "yes: backup made"
has "$out" "Codex's default startup timeout applies now" "yes: timeout loss stated"

echo "C7 config Codex cannot read"
fresh_home c7
printf 'this = is [ not toml\n' >"$H/.codex/config.toml"
cp "$H/.codex/config.toml" "$WORK/c7.toml"
run c7 '' "$CLIENT" --no-doctor
exit_is "$rc" 1 "exit 1"
has "$out" "[FAIL] Codex cannot read" "reported"
cmp -s "$H/.codex/config.toml" "$WORK/c7.toml" && ok "config.toml untouched" || bad "config.toml untouched"

echo "C8 config without a final newline"
fresh_home c8
printf '[mcp_servers.other]\ncommand = "o"\nargs = []' >"$H/.codex/config.toml"
run c8 '' "$CLIENT" --no-doctor
exit_is "$rc" 0 "exit 0"
grep -qx 'args = \[\]' "$H/.codex/config.toml" && ok "last line kept whole" || bad "last line kept whole"
[[ $(awk '/^\[mcp_servers\.rhino\]$/ {print "[" prev "]"} {prev = $0}' "$H/.codex/config.toml") == "[]" ]] &&
  ok "new table on its own line, after one blank line" || bad "new table on its own line, after one blank line"

echo "C9 Codex reads the env differently after the edit"
fresh_home c9
cp "$WORK/c3.toml" "$H/.codex/config.toml"
FAKE_DROP_ENV_IF_CHANGED="$WORK/c3.toml" run c9 '' "$CLIENT" --yes --no-doctor
exit_is "$rc" 1 "exit 1"
has "$out" "reads other settings of 'rhino' differently" "reported"
has "$out" "config.toml restored from" "restore reported"
cmp -s "$H/.codex/config.toml" "$WORK/c3.toml" && ok "config.toml as before" || bad "config.toml as before"

echo
echo "passed: $pass  failed: $fail"
((fail == 0))
