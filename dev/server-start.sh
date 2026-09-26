#!/usr/bin/env bash
# server-start.sh — launch the NS2 dedicated server in the background and wait until Shine
# finishes loading extensions (ready) or timeout.
#
# Usage: ./dev/server-start.sh [map]                     # DEV instance (safe default)
#        ./dev/server-start.sh --live [map]              # Arian's live server, opt-in only
#        ./dev/server-start.sh <config_path_win> [map]   # explicit config (legacy form)
#        --port N                                        # override the instance port
#        --with-suite                                    # let hordetest run (test.sh only)
#
# DEV is the default now. It used to be the LIVE config, so a bare invocation restarted
# Arian's server — the same class of mistake as the workshop-copy incident (dev/STANDARDS.md).
# Passing the live path positionally without --live is refused outright.
#
# Prints the WSL path to the live log on the last line of stdout for callers.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=paths.sh
source "$REPO_DIR/dev/paths.sh"
paths_validate || exit 3

DEV_CFG_WIN="$HORDE_ROOT_WIN\\server\\cfg"
LIVE_CFG_WIN="$LIVE_CFG_WIN"
MODS_WIN="$HORDE_ROOT_WIN\\server\\mods"
MODS_WSL="$DEV_MODS_WSL/content/4920"
NS2SRV_WIN="$ENGINE_WIN"

LIVE=0
WITH_SUITE=0
PORT_OVERRIDE=""
POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) LIVE=1; shift ;;
    --with-suite) WITH_SUITE=1; shift ;;
    --port=*) PORT_OVERRIDE="${1#*=}"; shift ;;
    --port)
      [[ $# -ge 2 && "${2}" =~ ^[0-9]+$ ]] || { echo "[start] --port needs a number" >&2; exit 2; }
      PORT_OVERRIDE="$2"; shift 2 ;;
    -*) echo "[start] unknown option: $1" >&2; exit 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done

if [[ $LIVE -eq 1 ]]; then
  CFG_WIN="$LIVE_CFG_WIN"; PORT=$LIVE_PORT
else
  CFG_WIN="$DEV_CFG_WIN"; PORT=$DEV_PORT
fi

[[ -n "$PORT_OVERRIDE" ]] && PORT="$PORT_OVERRIDE"

MAP="ns2_summit"
if [[ ${#POS[@]} -ge 1 ]]; then
  if [[ "${POS[0]}" == "$LIVE_CFG_WIN" && $LIVE -eq 0 ]]; then
    echo "[start] REFUSED: that config path is the LIVE server. Use --live deliberately." >&2
    exit 3
  fi
  # One positional is the map, unless it looks like a config path (legacy callers pass cfg first).
  if [[ "${POS[0]}" == *cfg ]]; then
    CFG_WIN="${POS[0]}"
    [[ "${POS[0]}" == "$LIVE_CFG_WIN" ]] && PORT=$LIVE_PORT
    [[ ${#POS[@]} -ge 2 ]] && MAP="${POS[1]}"
  else
    MAP="${POS[0]}"
  fi
fi

# G1d: give DEV its own mod storage. The engine keeps mod storage in %APPDATA% regardless of
# -config_path, so without this a dev instance reads - and any dev edit writes - the SAME tree
# the live server mounts. That shared tree is the exact channel the 2026-09-21 incident used:
# a file placed for the dev loop was executed by Arian's server.
MODS_ARG=""
if [[ $LIVE -eq 0 && -d "$MODS_WSL" ]]; then
  MODS_ARG=",'-modstorage','$MODS_WIN'"
  echo "[start] using isolated -modstorage $MODS_WIN"
fi

# A DEV boot must be a server you can join. The suite spawns and destroys bots, takes the
# commander chair and locks the bot controller, so leaving it armed made every manual boot
# auto-start a horde and behave unpredictably for whoever was connected - which is exactly
# what Arian caught. test.sh passes --with-suite explicitly; nothing else arms it. The LIVE
# config is never touched here (dev/STANDARDS.md).
HARDCFG="$DEV_CFG_WSL/shine/plugins/HordeTest.json"
if [[ $LIVE -eq 0 && -d "$DEV_CFG_WSL/shine/plugins" ]]; then
  # Written unconditionally, and WITHOUT jq: `jq` resolves in an interactive shell here but
  # not inside a non-interactive script, so a condition built on it silently evaluated to
  # empty and the disarm never ran - the suite then booted a second time while a human was
  # connected and looked like the mod auto-starting. Always writing the wanted state has no
  # such failure mode, and the file is two lines.
  if [[ $WITH_SUITE -eq 1 ]]; then
    printf '{\n    "RunSuite" : true\n}\n' > "$HARDCFG"
    echo "[start] hordetest ARMED - the suite will run on this boot"
  else
    printf '{\n    "RunSuite" : false\n}\n' > "$HARDCFG"
    echo "[start] hordetest disarmed - this boot is a joinable server (./dev/test.sh runs the suite)"
  fi
fi

# Debug.RevealMouths follows the same rule as RunSuite: authorised per boot, written
# unconditionally, never against LIVE. A joinable DEV boot is a debugging session, so the
# mouths get marine-side markers; the suite is not, and must measure what a public server
# would actually do. Failing here stops the boot: starting a server whose reveal state we
# could not set means the next person reads an absent marker as "placement is wrong".
if [[ $LIVE -eq 0 && -d "$DEV_CFG_WSL/shine/plugins" ]]; then
  REVEAL=false
  [[ $WITH_SUITE -eq 0 ]] && REVEAL=true
  python3 "$REPO_DIR/dev/set-reveal.py" "$DEV_CFG_WSL" "$REVEAL" || exit 3
fi

# Interlock: never disturb a server someone is playing on. Each kill of a busy server
# makes NS2 write a crash dump, which reads to the user as a game bug.
if [[ $LIVE -eq 0 && "${SKIP_GUARD:-0}" != "1" ]]; then
  "$REPO_DIR/dev/guard-server.sh" free || exit 4
fi

# Clear the previous tracked instance through server-stop.sh, which owns the whole policy:
# PID-scoped, identity-checked against -config_path, politest signal first. The inline
# Stop-Process this replaces had no identity check, so a stale pidfile could kill whatever
# Windows had reusing that number - including a live server with people on it.
PIDFILE="$REPO_DIR/dev/.server.pid"

if [[ -f "$PIDFILE" ]]; then
  LIVEFLAG=""
  [[ $LIVE -eq 1 ]] && LIVEFLAG="--live"
  "$REPO_DIR/dev/server-stop.sh" $LIVEFLAG || echo "[start] WARN: previous instance not released (see [stop] lines above)" >&2
fi

# The engine log is shared by every instance on this box (it does not follow -config_path) and
# used to be deleted here on every boot, destroying the evidence trail for any other server
# including Arian's. It is no longer truncated, so the readiness wait must still distinguish
# this boot from the last one - but NOT by byte offset: the engine rotates log-Server.txt on
# boot, so an offset sampled before launch points past the end of the new file and nothing ever
# matches (measured: a fully successful boot timed out). Counting occurrences of the readiness
# line and requiring an increase works whether or not the file was rotated.
READY_LINE="Completed loading Shine extensions"
# Two things can happen to the shared log at boot: the engine appends to it, or it rotates it
# away and starts a new file. Byte offsets break on rotation (they point past the end of the
# smaller new file) and a plain occurrence count breaks too (1 before, 1 after - the new boot's
# line replaced the old one). So watch both signals and accept either.
log_state() {
  local C S
  if [[ -f "$LOG_WSL" ]]; then
    C=$(grep -ac "$READY_LINE" "$LOG_WSL" 2>/dev/null || true)
    S=$(stat -c %s "$LOG_WSL" 2>/dev/null || echo 0)
  else
    C=0; S=0
  fi
  echo "${C:-0} ${S}"
}
read -r READY_BEFORE SIZE_BEFORE <<<"$(log_state)"
echo "[start] log baseline: ready=$READY_BEFORE size=$SIZE_BEFORE"

echo "[start] launching Server.exe (cfg=$CFG_WIN map=$MAP port=$PORT)..."
# Detached via Start-Process so this script can return and poll the log. Window hidden.
NEW_PID=$(powershell.exe -Command "(Start-Process -FilePath '$NS2SRV_WIN\\x64\\Server.exe' -ArgumentList '-config_path','$CFG_WIN','-port','$PORT','-limit','16'${MODS_ARG},'+map','$MAP' -WorkingDirectory '$NS2SRV_WIN' -WindowStyle Hidden -PassThru).Id" 2>/dev/null | tr -dc '0-9')
if [[ -z "$NEW_PID" ]]; then
  echo "[start] could not launch Server.exe" >&2
  exit 1
fi
echo "$NEW_PID" > "$PIDFILE"
echo "[start] pid=$NEW_PID (tracked in dev/.server.pid)"

# Wait for readiness: one more occurrence of the line than existed before we launched.
TIMEOUT=180
elapsed=0
while [[ $elapsed -lt $TIMEOUT ]]; do
  sleep 5
  elapsed=$((elapsed + 5))
  read -r NOW_COUNT NOW_SIZE <<<"$(log_state)"
  if [[ "$NOW_COUNT" -gt "$READY_BEFORE" ]] || { [[ "$NOW_SIZE" -lt "$SIZE_BEFORE" ]] && [[ "$NOW_COUNT" -ge 1 ]]; }; then
    echo "[start] READY after ${elapsed}s (ready=$NOW_COUNT size=$NOW_SIZE)"
    echo "$LOG_WSL"
    exit 0
  fi
done

read -r TIMEOUT_COUNT TIMEOUT_SIZE <<<"$(log_state)"
echo "[start] TIMEOUT after ${TIMEOUT}s - this boot never reported Shine ready (baseline ready=$READY_BEFORE size=$SIZE_BEFORE, now ready=$TIMEOUT_COUNT size=$TIMEOUT_SIZE)" >&2
[[ -f "$LOG_WSL" ]] && tail -25 "$LOG_WSL" >&2

# Reap what we started. Leaving it running holds the port, keeps writing to the log and (worse)
# keeps whoever owns this machine guessing about a mystery server.
if [[ -n "${NEW_PID:-}" ]]; then
  # Graceful first; only escalate if it ignores us, and say so - a forced kill reads as a crash
  # in dumps/dumplog.txt and sends everyone hunting a bug that isn't there.
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
