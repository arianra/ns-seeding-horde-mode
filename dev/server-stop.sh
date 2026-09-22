#!/usr/bin/env bash
# server-stop.sh — stop the NS2 dedicated server and verify no process remains.
# Usage: ./dev/server-stop.sh
set -uo pipefail

PIDFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dev/.server.pid"

if [[ ! -f "$PIDFILE" ]]; then
  # Nothing we started is tracked. Do NOT go hunting for processes named Server:
  # an untracked one may be a real server with people on it.
  echo "[stop] no dev/.server.pid — nothing to stop (refusing to kill untracked servers)"
  exit 0
fi

PID=$(tr -dc '0-9' < "$PIDFILE")

if [[ -z "$PID" ]]; then
  echo "[stop] pid file empty — nothing to stop"
  rm -f "$PIDFILE"
  exit 0
fi

echo "[stop] stopping our server pid=$PID"

# Escalation order, politest first. `taskkill /PID` (no /F) sends a close request and is
# worth trying before anything harsher; a plain Stop-Process is the same class of kill;
# -Force is last and always writes a crash dump. An earlier revision claimed plain
# Stop-Process was dump-free unconditionally - falsified repeatedly on 2026-09-21:
# stopping a server whose test suite had run wrote a 60MB minidump and uploaded a crash
# report in most trials (8s settle 2/2, 25s 0/2, 30s 2/2), while the live config with no
# suite ran 4/4 clean. There is no graceful exit path available to us: no engine switch,
# no window to close, and the web interface is not listening. So a dump after a suite run
# is the suite's un-restored state (i7a teardown), not the choice of signal.

powershell.exe -Command "taskkill /PID $PID" >/dev/null 2>&1 || true

WAITED=0
while [[ $WAITED -lt 20 ]]; do
  sleep 2
  WAITED=$((WAITED + 2))
  ALIVE=$(powershell.exe -Command "(Get-Process -Id $PID -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -dc '0-9')
  [[ "$ALIVE" == "0" || -z "$ALIVE" ]] && break
done

if [[ "$ALIVE" != "0" && -n "$ALIVE" ]]; then
  echo "[stop] taskkill ignored after ${WAITED}s; trying Stop-Process (still without -Force)" >&2
  powershell.exe -Command "Stop-Process -Id $PID -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  WAITED=0
  while [[ $WAITED -lt 10 ]]; do
    sleep 2
    WAITED=$((WAITED + 2))
    ALIVE=$(powershell.exe -Command "(Get-Process -Id $PID -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -dc '0-9')
    [[ "$ALIVE" == "0" || -z "$ALIVE" ]] && break
  done
fi

if [[ "$ALIVE" != "0" && -n "$ALIVE" ]]; then
  echo "[stop] WARN - polite stops ignored; forcing (this WILL write a crash dump)" >&2
  powershell.exe -Command "Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  sleep 3
fi

rm -f "$PIDFILE"

ALIVE=$(powershell.exe -Command "(Get-Process -Id $PID -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -dc '0-9')
if [[ "$ALIVE" == "0" || -z "$ALIVE" ]]; then
  OTHERS=$(powershell.exe -Command "(Get-Process Server -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -dc '0-9')
  echo "[stop] OK — our server is gone${OTHERS:+ ($OTHERS other Server process(es) left untouched)}"
  exit 0
else
  echo "[stop] WARN — pid $PID still alive" >&2
  exit 1
fi
