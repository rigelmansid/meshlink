#!/usr/bin/env python3
"""Probe an MCP stdio server: handshake, list tools, optionally call tools.

Spawns the given command, speaks newline-delimited JSON-RPC on its stdin/stdout,
and reports timings. Every stdout line must parse as JSON: anything else (a
banner, a shell prompt, a pty's \\r) would break a real MCP client, so it is
reported as stdout pollution. Stderr goes to a file, never mixed in: by
default mcp_probe_stderr.log in the system temp directory, so a run from the
repository leaves nothing in it.

Usage:
  experiments/mcp_stdio_probe.py [--call TOOL[:JSON]]... [--stderr FILE]
                                 [--hold SECONDS] -- CMD...

  # rhinomcp on this Mac, through the existing tunnel
  experiments/mcp_stdio_probe.py --call get_document_summary -- ~/.local/bin/rhinomcp
  # rhinomcp on Windows, stdio carried by ssh (no tunnel)
  experiments/mcp_stdio_probe.py --call get_document_summary -- \\
      ssh -T -o BatchMode=yes rhino-pc 'C:\\Users\\<user>\\.local\\bin\\rhinomcp.exe'
"""
import argparse
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time

TIMEOUT = 60


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--call", action="append", default=[],
                    help="TOOL or TOOL:{json args}; repeatable")
    ap.add_argument("--stderr", metavar="FILE",
                    default=os.path.join(tempfile.gettempdir(), "mcp_probe_stderr.log"),
                    help="where the server's stderr goes (default: %(default)s)")
    ap.add_argument("--hold", type=float, default=0, metavar="SECONDS",
                    help="keep the session open this long after the calls")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        ap.error("missing server command after --")

    t0 = time.monotonic()
    err = open(a.stderr, "wb")
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err)
    lines = queue.Queue()
    threading.Thread(target=lambda: [lines.put(l) for l in p.stdout] + [lines.put(None)],
                     daemon=True).start()
    polluted = []
    next_id = [0]

    def send(method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            next_id[0] += 1
            msg["id"] = next_id[0]
        p.stdin.write((json.dumps(msg) + "\n").encode())
        p.stdin.flush()
        return msg.get("id")

    def await_reply(rid):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            try:
                raw = lines.get(timeout=deadline - time.monotonic())
            except queue.Empty:
                break
            if raw is None:
                raise SystemExit(f"server exited (code {p.poll()}); see {a.stderr}")
            try:
                msg = json.loads(raw)
            except ValueError:
                polluted.append(raw[:120])
                continue
            if msg.get("id") == rid:
                return msg, len(raw)
        raise SystemExit(f"no reply to request {rid} within {TIMEOUT}s; see {a.stderr}")

    def timed(label, method, params=None):
        s = time.monotonic()
        msg, size = await_reply(send(method, params))
        dt = time.monotonic() - s
        status = "ERROR " + json.dumps(msg["error"]) if "error" in msg else "ok"
        if "result" in msg and msg["result"].get("isError"):
            status = "TOOL ERROR " + json.dumps(msg["result"].get("content"))[:300]
        print(f"{label:<34} {dt*1000:8.0f} ms  {size:>9} B  {status}")
        # rhinomcp reports "Could not connect to Rhino" as ordinary text with
        # isError false, so show what came back instead of trusting the flag.
        for c in msg.get("result", {}).get("content", []) if method == "tools/call" else []:
            if c.get("type") == "text":
                print("  -> " + c["text"][:160].replace("\n", " "))
            else:
                print(f"  -> [{c.get('type')} content]")
        return msg

    timed("initialize", "initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "mcp-stdio-probe", "version": "0"}})
    send("notifications/initialized", notify=True)
    tools = timed("tools/list", "tools/list")
    print(f"  tools: {len(tools.get('result', {}).get('tools', []))}")
    for spec in a.call:
        name, _, args = spec.partition(":")
        timed(f"tools/call {name}", "tools/call",
              {"name": name, "arguments": json.loads(args) if args else {}})
    print(f"{'total (incl. process start)':<34} {(time.monotonic()-t0)*1000:8.0f} ms")

    # Hold the session open, e.g. to cut the network underneath it, and report
    # if the server (or ssh carrying it) exits on its own meanwhile.
    if a.hold:
        s = time.monotonic()
        print(f"holding session for {a.hold:.0f}s (started {time.strftime('%H:%M:%S')})",
              flush=True)
        try:
            code = p.wait(timeout=a.hold)
            print(f"server exited during hold after {time.monotonic()-s:.0f}s, "
                  f"code {code}, at {time.strftime('%H:%M:%S')}")
            return
        except subprocess.TimeoutExpired:
            print("hold finished, server still running")

    # Closing stdin is how a client ends a stdio session; the server (and ssh
    # carrying it) should exit on EOF rather than linger.
    p.stdin.close()
    try:
        code = p.wait(timeout=10)
        print(f"server exited on stdin EOF, code {code}")
    except subprocess.TimeoutExpired:
        print("server still running 10s after stdin EOF -- killing it")
        p.kill()
    if polluted:
        print(f"STDOUT POLLUTION: {len(polluted)} non-JSON line(s), first: {polluted[0]!r}")
        sys.exit(1)
    print("stdout clean: every line was JSON")


if __name__ == "__main__":
    main()
