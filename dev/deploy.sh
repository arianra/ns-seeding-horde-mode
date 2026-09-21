#!/usr/bin/env bash
# deploy.sh — sync repo extension source -> EVERY Shine workshop copy the machine
# mounts from (server-side and client-side), and enable hordemode + hordetest in the
# TEST config only (never the live one).
#
#   ./dev/deploy.sh              mirror dev extensions to all workshop copies
#   ./dev/deploy.sh --no-test-ext  same, without the test harness
#   ./dev/deploy.sh --clean      remove them again (vanilla-identical copies)
#   ./dev/deploy.sh --check      verify parity against the repo without copying
# Usage: ./dev/deploy.sh [--no-test-ext]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# NS2 requires the mod a server mounts and the mod a client mounts to AGREE.
# The server takes its copy from %APPDATA%\...\workshop, the client from the Steam
# library - two separate trees. Deploying to only one of them is what produced
# "Different number of network messages on the Client from the Server" and the
# resulting "Invalid data" kick: 15 dev files existed on one side only.
# So every target gets the same payload, and --clean removes it from all of them.
SHINE_EXT_TARGETS=(
  "/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/workshop/content/4920/117887554/lua/shine/extensions"
  "/mnt/c/Program Files (x86)/Steam/steamapps/workshop/content/4920/117887554/lua/shine/extensions"
)
# Only the TEST config is ever edited. The live config at D:/games/ns2srv belongs
# to whatever server Arian is actually running.
BASECFG="/mnt/d/games/ns2hordetest/cfg/shine/BaseConfig.json"
LIVECFG="/mnt/d/games/ns2srv/cfg/shine/BaseConfig.json"

INCLUDE_TEST=1
CLEAN_ONLY=0
CHECK_ONLY=0
for Arg in "$@"; do
  case "$Arg" in
    --no-test-ext) INCLUDE_TEST=0 ;;
    --clean) CLEAN_ONLY=1 ;;
    --check) CHECK_ONLY=1 ;;
  esac
done

remove_from_targets() {
  for ROOT in "${SHINE_EXT_TARGETS[@]}"; do
    rm -rf "$ROOT/hordemode" "$ROOT/hordetest"
    echo "[deploy] removed dev extensions from $ROOT"
  done
}

verify_parity() {
  # The invariant is not "copies match the repo" - a fully clean, vanilla machine is a
  # legitimate state where client and server also agree. The invariant is that the copies
  # agree WITH EACH OTHER, because that is what NS2 checks at join time. Mixed states are
  # the dangerous ones, and they are invisible to every dev run that only ever boots
  # headless. Each copy is hashed against the repo payload so "deployed" and "clean" are
  # distinguishable in the output.
  local WANT FIRST="" SEEN_DEPLOYED=0 SEEN_CLEAN=0
  WANT=$(cd "$REPO/source/lua/shine/extensions" && find hordemode hordetest -type f 2>/dev/null | sort | xargs -r md5sum | md5sum | cut -c1-8)

  for ROOT in "${SHINE_EXT_TARGETS[@]}"; do
    local STATE
    if [[ -d "$ROOT/hordemode" ]]; then
      local H
      H=$(cd "$ROOT" && find hordemode hordetest -type f 2>/dev/null | sort | xargs -r md5sum | md5sum | cut -c1-8)
      if [[ "$H" == "$WANT" ]]; then STATE="deployed"; SEEN_DEPLOYED=$((SEEN_DEPLOYED + 1)); else STATE="stale:$H"; SEEN_DEPLOYED=$((SEEN_DEPLOYED + 1)); fi
    else
      STATE="clean"; SEEN_CLEAN=$((SEEN_CLEAN + 1))
    fi

    if [[ -z "$FIRST" ]]; then FIRST="$STATE"; elif [[ "$FIRST" != "$STATE" ]]; then
      echo "[deploy] FAIL - workshop copies disagree: [$FIRST] vs [$STATE] ($ROOT)" >&2
      echo "[deploy]        client/server mod mismatch -> joins are kicked with 'Invalid data'." >&2
      echo "[deploy]        fix: ./dev/deploy.sh   (or ./dev/deploy.sh --clean for vanilla)" >&2
      return 1
    fi
    echo "[deploy] $STATE: $ROOT"
  done

  if [[ "$SEEN_CLEAN" -gt 0 && "$SEEN_DEPLOYED" -gt 0 ]]; then return 1; fi
  echo "[deploy] copies agree (${FIRST}, ${#SHINE_EXT_TARGETS[@]} targets) - joins safe"
}

if [[ $CHECK_ONLY -eq 1 ]]; then
  verify_parity
  exit $?
fi

if [[ $CLEAN_ONLY -eq 1 ]]; then
  echo "[deploy] --clean: restoring vanilla workshop copies"
  remove_from_targets
  exit 0
fi

echo "[deploy] repo=$REPO"

for ROOT in "${SHINE_EXT_TARGETS[@]}"; do
  mkdir -p "$ROOT"
  cp -rf "$REPO/source/lua/shine/extensions/hordemode" "$ROOT/"
  if [[ $INCLUDE_TEST -eq 1 ]]; then
    cp -rf "$REPO/source/lua/shine/extensions/hordetest" "$ROOT/"
  else
    rm -rf "$ROOT/hordetest"
  fi
  echo "[deploy] synced dev extensions -> $ROOT"
done

verify_parity || exit 1

# Defence in depth: if the live config somehow has the dev extensions on, turn them
# off. A live server must never load hordetest (it spawns bots, takes the chair and
# locks the bot controller) no matter what happened to the test config.
if [[ -f "$LIVECFG" ]]; then
  python3 - "$LIVECFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
ae = cfg.get("ActiveExtensions", {})
if ae.get("hordemode") or ae.get("hordetest"):
    ae["hordemode"] = False
    ae["hordetest"] = False
    json.dump(cfg, open(path, "w"), indent=4)
    print("[deploy] forced hordemode+hordetest OFF in the live config (dev-only extensions)")
PY
fi

# Ensure ActiveExtensions flags. BaseConfig may not exist until first Shine
# boot; if missing, we only warn (it's regenerated with defaults + our keys
# must be added after first boot). Use python for safe JSON edit.
python3 - "$BASECFG" "$INCLUDE_TEST" <<'PY'
import json, sys, os
path, include_test = sys.argv[1], sys.argv[2] == "1"
if not os.path.exists(path):
    print(f"[deploy] WARN: {path} not found (boot server once to generate). Skipping ActiveExtensions edit.")
    sys.exit(0)
with open(path) as f:
    cfg = json.load(f)
ae = cfg.setdefault("ActiveExtensions", {})
ae["hordemode"] = True
if include_test:
    ae["hordetest"] = True
with open(path, "w") as f:
    json.dump(cfg, f, indent=4)
print(f"[deploy] ActiveExtensions: hordemode=True hordetest={include_test}")
PY

echo "[deploy] done"
