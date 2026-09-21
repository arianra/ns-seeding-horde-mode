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
MAP="${1:-ns2_summit}"
TIMEOUT="${2:-300}"

bail() { echo "[test] FAIL: $*" >&2; exit 2; }

echo "[test] 1/6 stopping any stale server"
"$REPO/dev/server-stop.sh" >/dev/null 2>&1 || true

echo "[test] 2/6 building test config -> $CFG_WIN"
[[ -d "$SRC_CFG_WSL" ]] || bail "source config missing: $SRC_CFG_WSL"
rm -rf "$CFG_WSL"
mkdir -p "$CFG_WSL/shine"
cp -r "$SRC_CFG_WSL/." "$CFG_WSL/"      || bail "config copy failed"
cp -f "$REPO/dev/horde-test-cfg/ServerConfig.json" "$CFG_WSL/ServerConfig.json" || bail "overlay ServerConfig"
cp -f "$REPO/dev/horde-test-cfg/MapCycle.json"     "$CFG_WSL/MapCycle.json"     || bail "overlay MapCycle"
cp -f "$REPO/dev/horde-test-cfg/shine/BaseConfig.json" "$CFG_WSL/shine/BaseConfig.json" || bail "overlay BaseConfig"

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

echo "[test] 3/6 deploying repo extensions to the server's shine dir"
"$REPO/dev/deploy.sh" | sed 's/^/[deploy] /' || bail "deploy failed"

echo "[test] 4/6 starting server (map=$MAP cfg=$CFG_WIN)"
"$REPO/dev/server-start.sh" "$CFG_WIN" "$MAP" | sed 's/^/[start] /'
START_RC=${PIPESTATUS[0]}
[[ $START_RC -eq 0 ]] || bail "server never reached READY (see log above)"

echo "[test] 5/6 waiting up to ${TIMEOUT}s for [TEST] ALL-DONE"
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

echo "[test] 6/6 stopping server"
"$REPO/dev/server-stop.sh" | sed 's/^/[stop] /' || true

if [[ -z "$ALDONE" ]]; then
  echo "[test] FAIL — no '[TEST] ALL-DONE' after ${TIMEOUT}s" >&2
  echo "[test] last scenario lines:" >&2
  [[ -f "$LOG_WSL" ]] && grep -a "\[TEST\]" "$LOG_WSL" | tail -10 >&2
  echo "[test] engine/shine errors (diagnostics only; the exit code follows the suite):" >&2
  [[ -f "$LOG_WSL" ]] && grep -aiE "script error|lua error|attempt to |error:" "$LOG_WSL" | tail -10 >&2
  exit 1
fi

PASS=$(sed -n 's/.*pass=\([0-9]*\).*/\1/p' <<<"$ALDONE")
FAILN=$(sed -n 's/.*fail=\([0-9]*\).*/\1/p' <<<"$ALDONE")
echo "[test] suite finished in ~${elapsed}s after READY: $ALDONE"
echo "[test] scenario lines:"
grep -a "\[TEST\]" "$LOG_WSL" | grep -av "ALL-DONE" | tail -40 | sed 's/^/[test]   /'

if [[ "${FAILN:-1}" -gt 0 ]]; then
  echo "[test] FAIL — ${FAILN} scenario(s) failed, ${PASS} passed" >&2
  exit 1
fi
echo "[test] OK — ${PASS:-0} scenario(s) passed, 0 failed"
exit 0
