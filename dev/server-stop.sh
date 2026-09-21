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
powershell.exe -Command "Stop-Process -Id $PID -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
sleep 3
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
