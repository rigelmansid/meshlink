#!/bin/bash
# Phase 0 spike for D-20: advertise _meshlink-pair._tcp and accept one TCP
# connection, then clean up. Run on the Mac, then run MeshlinkProbe in Rhino.
# Usage: experiments/pairing-spike/mac-probe.sh [port] [seconds]
set -u
PORT=${1:-29950}
WAIT=${2:-120}
NAME="meshlink-probe-$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
TMP=$(mktemp -d)
DNSSD_PID=""
NC_PID=""

cleanup() {
    [ -n "$NC_PID" ] && kill "$NC_PID" 2>/dev/null
    [ -n "$DNSSD_PID" ] && kill "$DNSSD_PID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$TMP"
}
trap 'cleanup; exit 130' INT TERM HUP

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $PORT is busy" >&2
    exit 1
fi

dns-sd -R "$NAME" _meshlink-pair._tcp local "$PORT" v=0 probe=1 >"$TMP/dnssd.log" 2>&1 &
DNSSD_PID=$!
printf 'HELLO from %s\n' "$NAME" >"$TMP/resp"
nc -l "$PORT" <"$TMP/resp" >"$TMP/req" 2>"$TMP/nc.err" &
NC_PID=$!
echo "advertising '$NAME' on port $PORT for up to ${WAIT}s; run MeshlinkProbe in Rhino now"

i=0
while [ "$i" -lt "$WAIT" ] && kill -0 "$NC_PID" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
done

if kill -0 "$NC_PID" 2>/dev/null; then
    echo "RESULT: no connection within ${WAIT}s"
else
    wait "$NC_PID"
    echo "RESULT: nc exit=$? received: $(cat "$TMP/req")"
fi
echo "--- dns-sd log"; cat "$TMP/dnssd.log"
[ -s "$TMP/nc.err" ] && { echo "--- nc stderr"; cat "$TMP/nc.err"; }
cleanup
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && echo "WARN: port $PORT still listening" || echo "port $PORT free"
