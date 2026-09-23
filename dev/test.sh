#!/usr/bin/env bash
# test.sh — headless integration runner (bead i0c).
#
# Builds an isolated server config (live cfg + repo overlay), deploys the repo's
# extensions, boots the dedicated server, waits for the hordetest suite to report
# '[TEST] ALL-DONE', prints the summary, and exits nonzero when anything failed.
#
# Usage: ./dev/test.sh [map] [timeout_seconds] [--map M] [--bad-config]
# Unknown options are fatal. A previous version of this parser swallowed any
# unrecognised token into MAP and any bare number into TIMEOUT, so
# './dev/test.sh --iters 1' booted a map called '--iters' with a 1-second
# budget. There is no --iters/--runs: the suite has no repetition knob.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_CFG_WIN='D:\games\ns2srv\cfg'
SRC_CFG_WSL="/mnt/d/games/ns2srv/cfg"
CFG_WIN='D:\games\ns2hordetest\cfg'      # hyphen-free: -config_path breaks on hyphens
CFG_WSL="/mnt/d/games/ns2hordetest/cfg"
LOG_WSL="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/log-Server.txt"
MAP="ns2_summit"
TIMEOUT=0
BAD_CONFIG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bad-config) BAD_CONFIG=1; shift ;;
    --map)
      [[ $# -ge 2 ]] || { echo "[test] --map needs a value" >&2; exit 2; }
      MAP="$2"; shift 2 ;;
    -*)
      echo "[test] unknown option: $1" >&2
      echo "[test] usage: ./dev/test.sh [map] [timeout_seconds] [--map M] [--bad-config]" >&2
      exit 2 ;;
    *)
      if [[ "$TIMEOUT" == "0" && "$1" =~ ^[0-9]+$ ]]; then
        TIMEOUT="$1"
      elif [[ "$MAP" == "ns2_summit" ]]; then
        MAP="$1"
      else
        echo "[test] unexpected argument: $1 (map already $MAP)" >&2; exit 2
      fi
      shift ;;
  esac
done
[[ "$TIMEOUT" == "0" ]] && TIMEOUT=300

bail() { echo "[test] FAIL: $*" >&2; exit 2; }

echo "[test] 1/7 static lint"
# Cheapest gate first: a Lua syntax error costs two minutes to discover through a
# server boot and a couple of seconds here. Note the capture — `cmd | sed || bail`
# would test sed's status and pass on a lint failure.
LINT_OUT=$("$REPO/dev/lint.sh" 2>&1); LINT_RC=$?
sed 's/^/[test]   /' <<<"$LINT_OUT"
[[ $LINT_RC -eq 0 ]] || bail "static lint failed (exit $LINT_RC)"

echo "[test] 2/7 stopping any stale server"
"$REPO/dev/server-stop.sh" >/dev/null 2>&1 || true

echo "[test] 3/7 building test config -> $CFG_WIN"
[[ -d "$SRC_CFG_WSL" ]] || bail "source config missing: $SRC_CFG_WSL"
rm -rf "$CFG_WSL"
mkdir -p "$CFG_WSL/shine"
cp -r "$SRC_CFG_WSL/." "$CFG_WSL/"      || bail "config copy failed"
cp -f "$REPO/dev/horde-test-cfg/ServerConfig.json" "$CFG_WSL/ServerConfig.json" || bail "overlay ServerConfig"
cp -f "$REPO/dev/horde-test-cfg/MapCycle.json"     "$CFG_WSL/MapCycle.json"     || bail "overlay MapCycle"
cp -f "$REPO/dev/horde-test-cfg/shine/BaseConfig.json" "$CFG_WSL/shine/BaseConfig.json" || bail "overlay BaseConfig"
# Only the TEST config is authorised to run the suite; nothing here touches the live cfg.
mkdir -p "$CFG_WSL/shine/plugins"
cp -f "$REPO/dev/horde-test-cfg/shine/plugins/HordeTest.json" "$CFG_WSL/shine/plugins/HordeTest.json" || bail "overlay HordeTest"

if [[ $BAD_CONFIG -eq 1 ]]; then
  # Real load-path test: Shine reads this file, our Sanitize must repair it, and
  # Shine must warn that the config "required changes to be valid".
  mkdir -p "$CFG_WSL/shine/plugins"
  cp -f "$REPO/dev/horde-test-cfg/shine/plugins/HordeMode.bad.json" "$CFG_WSL/shine/plugins/HordeMode.json"
  echo "[test]   bad-config mode: planted HordeMode.bad.json as HordeMode.json"
fi

python3 - "$CFG_WSL" <<'PY' || bail "test config invalid"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
tags = json.loads((root / "ServerConfig.json").read_text()).get("tags")
if not isinstance(tags, list):
    sys.exit(f"ServerConfig.tags must be an array, got {type(tags).__name__}")
ae = json.loads((root / "shine" / "BaseConfig.json").read_text()).get("ActiveExtensions", {})
if not (ae.get("hordemode") and ae.get("hordetest")):
    sys.exit("hordemode and hordetest must both be active in the test config")
print(f"[test]   config valid: tags={tags} extensions=hordemode+hordetest")
PY

echo "[test] 4/7 deploying repo extensions to the server's shine dir"
DEPLOY_OUT=$("$REPO/dev/deploy.sh" --for-suite 2>&1); DEPLOY_RC=$?
sed 's/^/[deploy] /' <<<"$DEPLOY_OUT"
[[ $DEPLOY_RC -eq 0 ]] || bail "deploy failed (exit $DEPLOY_RC)"

echo "[test] 5/7 starting server (map=$MAP cfg=$CFG_WIN)"
"$REPO/dev/server-start.sh" --with-suite "$CFG_WIN" "$MAP" | sed 's/^/[start] /'
START_RC=${PIPESTATUS[0]}
[[ $START_RC -eq 0 ]] || bail "server never reached READY (see log above)"

# Fence AFTER the boot: NS2 recreates log-Server.txt when the server starts, so an
# offset sampled before launch would point past the end of the new file and hide the
# whole run. Un-fenced instead, a previous run's ALL-DONE would satisfy this one.
LOG_OFFSET=$(stat -c %s "$LOG_WSL" 2>/dev/null || echo 0)
echo "[test]   log fenced at byte $LOG_OFFSET (post-boot)"

echo "[test] 6/7 waiting up to ${TIMEOUT}s for [TEST] ALL-DONE"
elapsed=0
ALDONE=""
while [[ $elapsed -lt $TIMEOUT ]]; do
  if [[ -f "$LOG_WSL" ]]; then
    ALDONE=$(tail -c +$((LOG_OFFSET + 1)) "$LOG_WSL" 2>/dev/null | grep -a "\[TEST\] ALL-DONE" | tail -1 || true)
    [[ -n "$ALDONE" ]] && break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

# Drain window. This is NOT a crash fix and must not be described as one: measured on
# this box by counting dumps/dumplog.txt 55s after each stop, an 8s settle dumped 2/2, a
# 25s settle 0/2, a 30s settle 2/2. The settle does not predict it. What is solid: the
# live config with no suite ran 4/4 clean stops, while stopping a server whose suite had
# run almost always writes a 60MB minidump and uploads a crash report - so the trigger is
# state the suite leaves behind (bots, BTC lock, registry entities, timers), i.e. the
# teardown that i7a has not implemented yet. Until that lands, treat a post-suite dump as
# expected. This wait exists only so deferred checks finish logging before we go.
if [[ -n "$ALDONE" ]]; then
  echo "[test]   draining 8s for deferred checks before shutdown"
  sleep 8
fi

echo "[test] 7/7 stopping server"
"$REPO/dev/server-stop.sh" | sed 's/^/[stop] /' || true

if [[ -z "$ALDONE" ]]; then
  echo "[test] FAIL — no '[TEST] ALL-DONE' after ${TIMEOUT}s" >&2
  echo "[test] last scenario lines (this run only):" >&2
  [[ -f "$LOG_WSL" ]] && tail -c +$((LOG_OFFSET + 1)) "$LOG_WSL" | grep -a "\[TEST\]" | tail -10 >&2
  echo "[test] engine/shine errors (diagnostics only; the exit code follows the suite):" >&2
  [[ -f "$LOG_WSL" ]] && tail -c +$((LOG_OFFSET + 1)) "$LOG_WSL" | grep -aiE "script error|lua error|attempt to |error:" | tail -10 >&2
  exit 1
fi

# Anchor on the exact 'pass=N fail=M' pair: a bare .*fail= would also match the
# trailing expected_fail= field and read a passing suite as failed.
PASS=$(sed -n 's/.*pass=\([0-9]*\) fail=\([0-9]*\).*/\1/p' <<<"$ALDONE")
FAILN=$(sed -n 's/.*pass=\([0-9]*\) fail=\([0-9]*\).*/\2/p' <<<"$ALDONE")
EXPECTED=$(sed -n 's/.*expected_fail=\([0-9]*\).*/\1/p' <<<"$ALDONE")
echo "[test] suite finished in ~${elapsed}s after READY: $ALDONE"
echo "[test] scenario lines:"
grep -a "\[TEST\]" "$LOG_WSL" | grep -av "ALL-DONE" | tail -40 | sed 's/^/[test]   /'

if [[ -z "$PASS" || -z "$FAILN" ]]; then
  echo "[test] FAIL — ALL-DONE line did not parse: $ALDONE" >&2
  exit 1
fi
if [[ "$FAILN" -gt 0 ]]; then
  echo "[test] FAIL — $FAILN scenario(s) failed, $PASS passed, ${EXPECTED:-0} expected" >&2
  exit 1
fi
if [[ $BAD_CONFIG -eq 1 ]]; then
  echo "[test] bad-config checks:"
  # Not a log assertion: Shine reports config-validation fixes as a client-facing
  # SystemNotification (base_plugin/config.lua:296-309), which is invisible when no
  # player is connected. The durable evidence is the file it wrote back.
  if grep -aq "hordemode config file" "$LOG_WSL"; then
    echo "[test]   Shine rewrote the plugin config"
  else
    echo "[test] FAIL - plugin config was never written back" >&2
    exit 1
  fi
  REPAIRED=$(python3 - "$CFG_WSL/shine/plugins/HordeMode.json" <<'PY'
import json, sys

c = json.load(open(sys.argv[1]))
w, s, e, d, i = c["Waves"], c["Start"], c["Economy"], c["Difficulty"], c["Intermission"]
# Exact expected results, not ranges: each value was planted broken in
# HordeMode.bad.json, so an exact match proves the sanitiser ran and repaired it
# rather than the file merely being valid.
checks = {
    "cooldown -5 -> 0": s["Cooldown"] == 0,
    "minplayers 9001 -> 16": s["MinPlayers"] == 16,
    "seconds 99999 -> 600": i["Seconds"] == 600,
    "skipcost 'free' -> 0": i["SkipCost"] == 0,
    "band 300/5 swapped": (w["BandMin"], w["BandMax"]) == (40, 300),
    "pool 99 -> 12": w["PoolSize"] == 12,
    "active 0 -> 1": w["ActivePerWave"] == 1,
    "payout -10 -> 0": e["WaveClearPayout"] == 0,
    "comp string -> curve": isinstance(w["Composition"], dict) and w["Composition"]["Start"] == 1,
    "accuracy null -> curve": isinstance(d["Accuracy"], dict) and len(d["Accuracy"]["Bezier"]) == 4,
    "aggro bezier filled": len(d["Aggro"].get("Bezier", [])) == 4,
    "health x clamped": w["Health"]["Bezier"][0] <= 1 and w["Health"]["Bezier"][2] <= 1,
}
bad = sorted(k for k, ok in checks.items() if not ok)
shown = f"cooldown={s['Cooldown']} minplayers={s['MinPlayers']} band={w['BandMin']}..{w['BandMax']} pool={w['PoolSize']} active={w['ActivePerWave']}"
print(("OK " + shown) if not bad else ("BAD " + shown + " | failed: " + ", ".join(bad)))
PY
)
  echo "[test]   repaired on disk: $REPAIRED"
  case "$REPAIRED" in
    OK\ *) echo "[test]   every value is inside its declared range" ;;
    *) echo "[test] FAIL - config on disk is still invalid: $REPAIRED" >&2; exit 1 ;;
  esac
fi

# Tripwire for the 2026-09-21 incident: a dev loop that leaves files in the client's
# Steam-managed copy stops Arian joining ANY server. This is the only automatic check for
# it - every headless run is structurally blind to the client side, which is precisely how
# the damage survived a full green suite. See dev/STANDARDS.md.
CHECK_OUT=$("$REPO/dev/deploy.sh" --check 2>&1); CHECK_RC=$?
sed 's/^/[deploy]   /' <<<"$CHECK_OUT"
[[ $CHECK_RC -eq 0 ]] || { echo "[test] FAIL - managed-content check failed (dev/STANDARDS.md)" >&2; exit 1; }

echo "[test] OK — $PASS passed, 0 failed, ${EXPECTED:-0} expected (negative controls)"
exit 0
