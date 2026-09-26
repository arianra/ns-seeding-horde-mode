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
# That last-but-one line is the door: the engine looks for a backup server. UWE ships one
# (utils/WorkshopBackup) but it mirrors *published* items and needs a Steam API key, so it
# cannot serve an item that does not exist yet. This script implements the same wire protocol
# instead — request path '/m<hexModId>_<version>.zip' (WorkshopBackup check_path + make_key),
# default port 27020 — over the artifact dev/package.sh produced. Nothing is hand-placed: the
# served bytes are the release artifact, so the dev loop exercises the real delivery path.
# After publication it stays useful as the backup WorkshopBackup's own README recommends for
# Steam's documented failure rate (~1 in 4 normally, ~9 in 10 during sales).
#
# Four defects this version closes, all found on 2026-09-25 asking a practical question: "can a
# human join right now?"
#   1. DIST pointed at `dist/<version>/artifacts`, which package.sh never creates, so `start`
#      could only answer "no artifact" — broken silently since the repo moved to D:\.
#   2. The pidfile recorded `echo $!` from inside `( cd ... && setsid nohup python3 ... & )`:
#      the subshell's pid, not the detached server's. Measured here — pidfile 709378, real
#      server 709380 — so `running` was false while a healthy server was answering 200, and
#      `status` said "stopped" about a process that existed. A pid we did not start is not
#      evidence about who is serving. Identity comes from the process itself: our command line
#      AND our directory.
#   3. The artifact was chosen with `ls m*_*.zip | head -1`, which found the superseded
#      pre-publication placeholder (m3b8b87c1_0.zip = id 999000001, sorts first) and reported
#      HTTP 200 about the wrong file. The name is now derived by paths.sh mod_archive_name(),
#      and dev/package.sh prunes archives for other ids.
#   4. Success meant "a socket answered", not "a client gets this build". An HTTP server
#      answers 200 for whatever it has, so every verdict here is a sha256 comparison against
#      the artifact on disk. A passing check against the wrong artifact is worse than a
#      failing one. (package.sh also writes `seedinghorde-<version>.zip` with identical bytes
#      under a different name, which is how my first attempt at an "impostor" test served the
#      right content by accident and proved nothing.)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO/dev/paths.sh"
VERSION=$(python3 -c "import json;print(json.load(open('$REPO/mod/mod.json'))['version'])")
DIST="$(dist_dir_for "$VERSION")"
PORT="$MODSERVER_PORT"
PIDFILE="$REPO/dev/.modserver.pid"
LOG="$DIST/modserver.log"

url() { echo "http://127.0.0.1:$PORT"; }

# Our server, identified by what it is rather than by a file we wrote: same command line, and
# rooted in the directory holding our artifact. Prints the pid; empty if nobody qualifies.
our_pid() {
  local pid cwd
  for pid in $(pgrep -f "http\.server $PORT --bind 127\.0\.0\.1" 2>/dev/null); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    [[ -n "$cwd" && "$cwd" == "$DIST" ]] && { echo "$pid"; return; }
  done
}

# Anything at all holding the port, ours or not.
port_held() { ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q ":$PORT"; }

running() {
  local pid
  pid=$(our_pid)
  [[ -n "$pid" ]] || return 1
  # Keep the pidfile as a convenience for whoever looks at it, never as the truth.
  [[ -f "$PIDFILE" && "$(tr -dc '0-9' < "$PIDFILE")" == "$pid" ]] || echo "$pid" > "$PIDFILE"
}

# Our artifact, by name — never "whichever zip a listing happened to return first".
artifact_name() {
  local name
  name=$(mod_archive_name 2>/dev/null) || return 1
  [[ -n "$name" && -f "$DIST/$name" ]] || return 1
  echo "$name"
}

# Verdict on the protocol path itself: ok | differs | HTTP <code> | nolisten | noartifact.
# "differs" is the case a status code cannot see: someone is serving our filename with other
# bytes, which is exactly what a server rooted in a stale or foreign directory does.
serves_our_artifact() {
  local name="${1:-}" tmp code
  [[ -n "$name" && -f "$DIST/$name" ]] || { echo "noartifact"; return; }

  tmp=$(mktemp) || { echo "notmp"; return; }
  code=$(curl -s --max-time 10 -o "$tmp" -w '%{http_code}' "$(url)/$name" 2>/dev/null)

  if [[ "$code" != "200" ]]; then
    rm -f "$tmp"
    [[ -z "$code" ]] && echo "nolisten" || echo "HTTP $code"
    return
  fi

  if [[ "$(sha256sum "$tmp" | cut -d' ' -f1)" == "$(sha256sum "$DIST/$name" | cut -d' ' -f1)" ]]; then
    echo "ok"
  else
    echo "differs"
  fi

  rm -f "$tmp"
}

# Who else is on the port, for the refusal message to be actionable.
describe_holder() {
  local pid cwd line
  pid=$(pgrep -f "http\.server $PORT" 2>/dev/null | head -1)
  if [[ -n "$pid" ]]; then
    line=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo '<unknown>')
    echo "    pid $pid: ${line:-<cmdline unreadable>}"
    echo "    cwd $cwd"
  else
    echo "    holder not visible to us (another user or namespace); inspect with: sudo ss -ltnp"
  fi
}

case "${1:-status}" in
  start)
    ART=$(artifact_name) || {
      echo "[modserver] no artifact in $DIST - run ./dev/package.sh first" >&2
      exit 1
    }

    if running; then
      echo "[modserver] already running (pid $(cat "$PIDFILE")) at $(url) serving $ART"
      exit 0
    fi

    if port_held; then
      echo "[modserver] REFUSED: $PORT is held by a process that is not ours." >&2
      describe_holder >&2
      echo "    it answers $ART with: $(serves_our_artifact "$ART")" >&2
      echo "[modserver]        Clear it deliberately (or move MODSERVER_PORT in dev/paths.sh)." >&2
      echo "[modserver]        Starting anyway cannot bind, and the config would advertise a dead URL." >&2
      exit 1
    fi

    echo "[modserver] serving $ART [$(sha256sum "$DIST/$ART" | cut -c1-8)]"
    # http.server serves the request path verbatim from cwd, so /m<hex>_<ver>.zip resolves to
    # the artifact dev/package.sh named. --bind loopback only: a dev-time source for our own
    # artifact, not a public host. Detached so it outlives this script; its pid is discovered
    # afterwards by identity (our_pid), never guessed from $!.
    ( cd "$DIST" && setsid nohup python3 -m http.server "$PORT" --bind 127.0.0.1 </dev/null >"$LOG" 2>&1 & )
    sleep 2

    if ! running; then
      echo "[modserver] FAIL - not serving; see $LOG" >&2
      exit 1
    fi

    VERDICT=$(serves_our_artifact "$ART")
    echo "[modserver] pid $(cat "$PIDFILE") at $(url) - $ART: $VERDICT"
    [[ "$VERDICT" == "ok" ]] || {
      echo "[modserver] FAIL - the protocol path does not serve this artifact ($VERDICT)" >&2
      exit 1
    }
    ;;

  stop)
    if running; then
      kill "$(tr -dc '0-9' < "$PIDFILE")" 2>/dev/null
      rm -f "$PIDFILE"
      echo "[modserver] stopped"
    elif port_held; then
      # Same rule as dev/server-stop.sh: never kill a process we cannot prove is ours.
      echo "[modserver] REFUSED: $PORT is held by something we did not start; leaving it alone." >&2
      describe_holder >&2
      exit 3
    else
      rm -f "$PIDFILE"
      echo "[modserver] not running"
    fi
    ;;

  url) url ;;

  status)
    ART=$(artifact_name || true)

    if running; then
      VERDICT=$(serves_our_artifact "$ART")
      echo "[modserver] running pid $(cat "$PIDFILE") at $(url) - ${ART:-<no artifact>}: $VERDICT"
      [[ "$VERDICT" == "ok" ]] || exit 1
    elif port_held; then
      VERDICT=$(serves_our_artifact "$ART")
      echo "[modserver] FOREIGN HOLDER: $PORT answers, but not as our artifact - $VERDICT"
      describe_holder
      echo "[modserver]          a listener that cannot serve our artifact delivers no mod"
      exit 1
    else
      echo "[modserver] stopped"
    fi
    ;;

  *) echo "usage: $0 start|stop|status|url" >&2; exit 2 ;;
esac
