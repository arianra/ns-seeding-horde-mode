#!/usr/bin/env bash
# guard-server.sh — refuse to disturb a server that someone is playing on.
#
#   ./dev/guard-server.sh free      exit 0 only if no client session is open
#   ./dev/guard-server.sh status    human-readable session state
#
# Why: the dev loop restarted the server repeatedly while Arian was connected. Each kill
# of a busy server makes NS2's crash handler write a ~60 MB minidump, so his machine
# filled with crash reports that looked like a game bug and were actually our iteration.
# A rule written in a doc did not stop it; this check does, because the launcher refuses.
#
# Detection is from the engine log, which is the only shared truth we have: a
# "Client connecting" without a matching "Client disconnected" means someone is in.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO/dev/paths.sh"

LOG="$LOG_WSL"

session_counts() {
  if [[ ! -f "$LOG" ]]; then echo "0 0"; return; fi
  # Only this boot: the engine rotates log-Server.txt at startup, so count within the
  # current file and treat a rotated file as a fresh session ledger.
  local c d
  c=$(grep -acE "^[[:space:]]*Client connecting \(" "$LOG" 2>/dev/null || true)
  d=$(grep -acE "^[[:space:]]*Client disconnected \(" "$LOG" 2>/dev/null || true)
  echo "${c:-0} ${d:-0}"
}

process_running() {
  local pid=""
  [[ -f "$REPO/dev/.server.pid" ]] && pid=$(tr -dc '0-9' < "$REPO/dev/.server.pid")
  [[ -z "$pid" ]] && return 1
  powershell.exe -NoProfile -Command "(Get-Process -Id $pid -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -dc '0-9' | grep -q "^1$"
}

case "${1:-status}" in
  status)
    read -r C D <<<"$(session_counts)"
    OPEN=$(( C - D )); (( OPEN < 0 )) && OPEN=0
    echo "[guard] sessions: $C connect(s), $D disconnect(s), $OPEN open"
    echo "[guard] our server process: $(process_running && echo running || echo not running)"
    ;;

  free)
    read -r C D <<<"$(session_counts)"
    OPEN=$(( C - D ))
    if (( OPEN > 0 )); then
      echo "[guard] REFUSED - $OPEN client session(s) still connected to the server." >&2
      echo "[guard]       stopping it now writes a crash dump and looks like a game bug." >&2
      echo "[guard]       ask Arian to quit to the desktop, then retry." >&2
      exit 4
    fi
    echo "[guard] free - no open client sessions"
    ;;

  *) echo "usage: $0 free|status" >&2; exit 2 ;;
esac
