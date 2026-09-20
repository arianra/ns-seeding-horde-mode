#!/usr/bin/env bash
# server-start.sh — launch the NS2 dedicated server in the background and
# wait until Shine finishes loading extensions (ready) or timeout.
# Usage: ./dev/server-start.sh [config_path_win] [map]
#   config_path_win defaults to D:\games\ns2srv\cfg
# Prints the WSL path to the live log on stdout (last line) for callers.
set -uo pipefail

CFG_WIN="${1:-D:\\games\\ns2srv\\cfg}"
MAP="${2:-ns2_summit}"
PORT=27015
NS2SRV_WIN='D:\games\ns2-server'
LOG_WSL="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/log-Server.txt"

# Ensure no stale server holds the port
powershell.exe -Command "Stop-Process -Name Server -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
sleep 3
rm -f "$LOG_WSL" 2>/dev/null || true

echo "[start] launching Server.exe (cfg=$CFG_WIN map=$MAP port=$PORT)..."
# Launch detached via powershell Start-Process so this script can return and
# the caller can poll the log. Window hidden.
powershell.exe -Command "Start-Process -FilePath '$NS2SRV_WIN\\x64\\Server.exe' -ArgumentList '-config_path','$CFG_WIN','-port','$PORT','-limit','16','+map','$MAP' -WorkingDirectory '$NS2SRV_WIN' -WindowStyle Hidden" >/dev/null 2>&1

# Wait for readiness
READY_LINE="Completed loading Shine extensions"
TIMEOUT=180
elapsed=0
while [[ $elapsed -lt $TIMEOUT ]]; do
  if [[ -f "$LOG_WSL" ]] && grep -q "$READY_LINE" "$LOG_WSL" 2>/dev/null; then
    echo "[start] READY after ${elapsed}s"
    echo "$LOG_WSL"
    exit 0
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

echo "[start] TIMEOUT after ${TIMEOUT}s — readiness line not found" >&2
[[ -f "$LOG_WSL" ]] && tail -20 "$LOG_WSL" >&2
echo "$LOG_WSL"
exit 1
