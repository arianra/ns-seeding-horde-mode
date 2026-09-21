#!/usr/bin/env bash
# server-start.sh — launch the NS2 dedicated server in the background and
# wait until Shine finishes loading extensions (ready) or timeout.
# Usage: ./dev/server-start.sh [config_path_win] [map]
#   config_path_win defaults to D:\games\ns2srv\cfg
# Prints the WSL path to the live log on stdout (last line) for callers.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CFG_WIN="${1:-D:\\games\\ns2srv\\cfg}"
MAP="${2:-ns2_summit}"
PORT=27015
NS2SRV_WIN='D:\games\ns2-server'
LOG_WSL="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/log-Server.txt"

# Stop ONLY the server this script started (tracked by PID). Killing every process
# named "Server" would take down any server Arian is actually running - which is what
# happened: every dev loop silently stopped the live one.
PIDFILE="$REPO_DIR/dev/.server.pid"

if [[ -f "$PIDFILE" ]]; then
  OLD_PID=$(tr -dc '0-9' < "$PIDFILE")
  if [[ -n "$OLD_PID" ]]; then
    # Graceful, and wait - see server-stop.sh for why -Force is the wrong default.
    powershell.exe -Command "Stop-Process -Id $OLD_PID -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 2
      LEFT=$(powershell.exe -Command "(Get-Process -Id $OLD_PID -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -dc '0-9')
      [[ "$LEFT" == "0" || -z "$LEFT" ]] && break
    done
  fi
fi
rm -f "$LOG_WSL" 2>/dev/null || true

echo "[start] launching Server.exe (cfg=$CFG_WIN map=$MAP port=$PORT)..."
# Launch detached via powershell Start-Process so this script can return and
# the caller can poll the log. Window hidden.
NEW_PID=$(powershell.exe -Command "(Start-Process -FilePath '$NS2SRV_WIN\\x64\\Server.exe' -ArgumentList '-config_path','$CFG_WIN','-port','$PORT','-limit','16','+map','$MAP' -WorkingDirectory '$NS2SRV_WIN' -WindowStyle Hidden -PassThru).Id" 2>/dev/null | tr -dc '0-9')
if [[ -z "$NEW_PID" ]]; then
  echo "[start] could not launch Server.exe" >&2
  exit 1
fi
echo "$NEW_PID" > "$PIDFILE"
echo "[start] pid=$NEW_PID (tracked in dev/.server.pid)"

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

# Reap what we started. Leaving it running holds the port, keeps writing to the log
# and (worse) keeps whoever owns this machine guessing about a mystery server.
if [[ -n "${NEW_PID:-}" ]]; then
  # Graceful first; only escalate if it ignores us, and say so - a forced kill reads
  # as a crash in dumps/dumplog.txt and sends everyone hunting a bug that isn't there.
  powershell.exe -Command "Stop-Process -Id $NEW_PID -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  sleep 6
  if [[ -n "$(powershell.exe -Command "Get-Process -Id $NEW_PID -ErrorAction SilentlyContinue" 2>/dev/null | tr -d '\r')" ]]; then
    echo "[start] WARN - server ignored graceful close; forcing (writes a crash dump)" >&2
    powershell.exe -Command "Stop-Process -Id $NEW_PID -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  fi
  rm -f "$PIDFILE"
  echo "[start] stopped pid=$NEW_PID after timeout"
fi

echo "$LOG_WSL"
exit 1
