#!/usr/bin/env bash
# modserver.sh — the mod backup server, speaking NS2's documented protocol.
#
#   ./dev/modserver.sh start|stop|status|url
#
# Why this exists
# ---------------
# The engine will not mount a mod folder that merely exists on disk. Measured
# 2026-09-23 with an unpublished id in the dev mod storage and no backup server:
#
#   Adding mod 999000001 from MapCycle.json to active mod list
#   Error: Failed to fetch info for Mod 999000001, steam returned file not found
#   Mod 999000001 is unavailable because its has no cached versions to use.
#   Error: SteamVersionAvailable was false for mod [999000001] with version 0
#   Error: Can't use cached version of mod [999000001] because backup mod server isn't running
#   Error: Mod [999000001] wasn't available
#
# That last-but-one line is the door: the engine looks for a backup server. UWE ships
# one (utils/WorkshopBackup) but it mirrors *published* Workshop items and needs a
# Steam API key, so it cannot serve an item that does not exist yet. This script
# implements the same wire protocol instead - the request path grammar is
# '/m<hexModId>_<version>.zip' (WorkshopBackup check_path + make_key), default port
# 27020 - over the artifact dev/package.sh produced. Nothing is hand-placed: the served
# bytes are the release artifact, so the dev loop exercises the real delivery path.
#
# After publication this script stays useful: it becomes the backup server that
# WorkshopBackup's README recommends for surviving Steam's documented failure rate
# (~1 in 4 normally, ~9 in 10 during sales).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO/dev/paths.sh"
VERSION=$(python3 -c "import json;print(json.load(open('$REPO/mod/mod.json'))['version'])")
DIST="$(dist_dir_for "$VERSION")/artifacts"
PORT="$MODSERVER_PORT"
PIDFILE="$REPO/dev/.modserver.pid"
LOG="$(dist_dir_for "$VERSION")/modserver.log"

url() { echo "http://127.0.0.1:$PORT"; }

running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid; pid=$(tr -dc '0-9' < "$PIDFILE")
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

case "${1:-status}" in
  start)
    if running; then echo "[modserver] already running (pid $(cat "$PIDFILE")) at $(url)"; exit 0; fi
    [[ -d "$DIST" ]] || { echo "[modserver] no artifact - run ./dev/package.sh first" >&2; exit 1; }

    ARCHIVE=$(ls "$DIST"/m*_*.zip 2>/dev/null | head -1)
    [[ -n "$ARCHIVE" ]] || { echo "[modserver] no m<hex>_<version>.zip in $DIST" >&2; exit 1; }
    echo "[modserver] serving $(basename "$ARCHIVE") [$(md5sum "$ARCHIVE" | cut -c1-8)]"

    mkdir -p "$REPO/build"
    # http.server serves the request path verbatim from cwd, so /m<hex>_<ver>.zip
    # resolves to the artifact dev/package.sh named. -b on loopback only: this is a
    # dev-time source for an unpublished artifact, not a public host.
    ( cd "$DIST" && setsid nohup python3 -m http.server "$PORT" --bind 127.0.0.1 </dev/null >"$LOG" 2>&1 & echo $! > "$PIDFILE" )
    sleep 2
    if running; then
      echo "[modserver] pid $(cat "$PIDFILE") at $(url)"
      # Prove the contract end to end rather than trusting that a listener exists.
      CODE=$(curl -s -o /dev/null -w '%{http_code}' "$(url)/$(basename "$ARCHIVE")")
      SIZE=$(curl -s "$(url)/$(basename "$ARCHIVE")" | wc -c)
      echo "[modserver] fetch check: HTTP $CODE, $SIZE bytes"
      [[ "$CODE" == "200" ]] || { echo "[modserver] FAIL - artifact not retrievable over the protocol" >&2; exit 1; }
    else
      echo "[modserver] FAIL - did not start; see $LOG" >&2; exit 1
    fi
    ;;

  stop)
    if running; then
      kill "$(tr -dc '0-9' < "$PIDFILE")" 2>/dev/null
      rm -f "$PIDFILE"
      echo "[modserver] stopped"
    else
      rm -f "$PIDFILE"; echo "[modserver] not running"
    fi
    ;;

  url) url ;;

  status)
    if running; then echo "[modserver] running pid $(cat "$PIDFILE") at $(url)"; else echo "[modserver] stopped"; fi
    ;;

  *) echo "usage: $0 start|stop|status|url" >&2; exit 2 ;;
esac
