#!/usr/bin/env bash
# test.sh — headless integration runner (bead i0c).
#
# Builds an isolated server config (live cfg + repo overlay), deploys the repo's
# extensions, boots the dedicated server, waits for the hordetest suite to report
# '[TEST] ALL-DONE', prints the summary, and exits nonzero when anything failed.
#
# Usage: ./dev/test.sh [map] [timeout_seconds]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_CFG_WIN='D:\games\ns2srv\cfg'
SRC_CFG_WSL="/mnt/d/games/ns2srv/cfg"
CFG_WIN='D:\games\ns2hordetest\cfg'      # hyphen-free: -config_path breaks on hyphens
CFG_WSL="/mnt/d/games/ns2hordetest/cfg"
LOG_WSL="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/log-Server.txt"
MAP="ns2_summit"
TIMEOUT=300
BAD_CONFIG=0
TIMEOUT_SET=0
MAP_SET=0

for Arg in "$@"; do
  case "$Arg" in
    --bad-config) BAD_CONFIG=1 ;;
    *)
      if [[ "$TIMEOUT_SET" != "1" && "$Arg" =~ ^[0-9]+$ ]]; then
        TIMEOUT="$Arg"; TIMEOUT_SET=1
      elif [[ -z "${MAP_SET:-}" ]]; then
        MAP="$Arg"; MAP_SET=1
      fi
      ;;
  esac
done

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
DEPLOY_OUT=$("$REPO/dev/deploy.sh" 2>&1); DEPLOY_RC=$?
sed 's/^/[deploy] /' <<<"$DEPLOY_OUT"
[[ $DEPLOY_RC -eq 0 ]] || bail "deploy failed (exit $DEPLOY_RC)"

echo "[test] 5/7 starting server (map=$MAP cfg=$CFG_WIN)"
"$REPO/dev/server-start.sh" "$CFG_WIN" "$MAP" | sed 's/^/[start] /'
START_RC=${PIPESTATUS[0]}
[[ $START_RC -eq 0 ]] || bail "server never reached READY (see log above)"

echo "[test] 6/7 waiting up to ${TIMEOUT}s for [TEST] ALL-DONE"
elapsed=0
ALDONE=""
while [[ $elapsed -lt $TIMEOUT ]]; do
  if [[ -f "$LOG_WSL" ]]; then
    ALDONE=$(grep -a "\[TEST\] ALL-DONE" "$LOG_WSL" | tail -1 || true)
    [[ -n "$ALDONE" ]] && break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

echo "[test] 7/7 stopping server"
"$REPO/dev/server-stop.sh" | sed 's/^/[stop] /' || true

if [[ -z "$ALDONE" ]]; then
  echo "[test] FAIL — no '[TEST] ALL-DONE' after ${TIMEOUT}s" >&2
  echo "[test] last scenario lines:" >&2
  [[ -f "$LOG_WSL" ]] && grep -a "\[TEST\]" "$LOG_WSL" | tail -10 >&2
  echo "[test] engine/shine errors (diagnostics only; the exit code follows the suite):" >&2
  [[ -f "$LOG_WSL" ]] && grep -aiE "script error|lua error|attempt to |error:" "$LOG_WSL" | tail -10 >&2
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

echo "[test] OK — $PASS passed, 0 failed, ${EXPECTED:-0} expected (negative controls)"
exit 0
