#!/usr/bin/env bash
# deploy.sh — sync repo extension source -> the server's Shine workshop dir
# and ensure ActiveExtensions enables hordemode + hordetest.
# Usage: ./dev/deploy.sh [--no-test-ext]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHINE_EXT_WIN='C:\Users\aria\AppData\Roaming\Natural Selection 2\workshop\content\4920\117887554\lua\shine\extensions'
SHINE_EXT_WSL="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/workshop/content/4920/117887554/lua/shine/extensions"
BASECFG="/mnt/d/games/ns2srv/cfg/shine/BaseConfig.json"

INCLUDE_TEST=1
[[ "${1:-}" == "--no-test-ext" ]] && INCLUDE_TEST=0

echo "[deploy] repo=$REPO"
mkdir -p "$SHINE_EXT_WSL"

# Copy hordemode (always) + hordetest (unless --no-test-ext)
cp -rf "$REPO/source/lua/shine/extensions/hordemode" "$SHINE_EXT_WSL/"
echo "[deploy] copied hordemode"
if [[ $INCLUDE_TEST -eq 1 ]]; then
  cp -rf "$REPO/source/lua/shine/extensions/hordetest" "$SHINE_EXT_WSL/"
  echo "[deploy] copied hordetest"
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
