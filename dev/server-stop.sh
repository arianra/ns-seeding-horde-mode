#!/usr/bin/env bash
# server-stop.sh — stop the NS2 dedicated server and verify no process remains.
# Usage: ./dev/server-stop.sh
set -uo pipefail

echo "[stop] stopping Server.exe..."
powershell.exe -Command "Stop-Process -Name Server -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
sleep 3

COUNT=$(powershell.exe -Command "(Get-Process Server -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\r\n ')
if [[ "$COUNT" == "0" ]]; then
  echo "[stop] OK — no Server process running"
  exit 0
else
  echo "[stop] WARN — $COUNT Server process(es) still alive" >&2
  exit 1
fi
