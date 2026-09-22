#!/usr/bin/env bash
# deploy.sh — sync repo extension source into the DEDICATED SERVER's copy of Shine,
# and enable hordemode + hordetest in the TEST config only (never the live one).
#
#   ./dev/deploy.sh                deploy into the server's mod storage
#   ./dev/deploy.sh --no-test-ext  same, without the test harness
#   ./dev/deploy.sh --clean        remove dev files everywhere, including any a
#                                  previous revision planted in the Steam library
#   ./dev/deploy.sh --check        verify state without writing (exit 1 = unsafe)
#
# READ THIS BEFORE CHANGING THE TARGETS
# -------------------------------------
# An earlier revision mirrored the payload into BOTH Shine copies - the server's and
# the client's - to make "Different number of network messages" go away. That was
# wrong, and it cost Arian the ability to join ANY server: the client copy lives under
# Steam's managed tree, and files we put there fail Workshop consistency against every
# other server ("your files are out of sync with the server"). We were damaging the
# real game to make our dev server joinable.
#
# The supported shape, per Shine's own "Developing a Shine plugin" doc:
#   "you need to make your own Steam Workshop mod, with the folder
#    lua/shine/extensions ... Run your mod alongside the main Shine mod"
# i.e. our plugins ship in OUR mod, never inside Shine's files. Until that mod exists,
# dev files may live only in the server's own mod storage, which means a vanilla client
# cannot join the dev server. That is the correct trade: headless bot testing works,
# the game stays untouched. See dev/STANDARDS.md.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# NS2's per-user mod storage. The dedicated server downloads and mounts from here;
# Steam does not validate it and the game client never reads it.
SERVER_EXT="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/workshop/content/4920/117887554/lua/shine/extensions"

# The client's copy, under Steam's managed tree. Listed ONLY so --clean can undo the
# damage an earlier revision of this script did here. Nothing may ever write to it.
STEAM_EXT_REPAIR_ONLY="/mnt/c/Program Files (x86)/Steam/steamapps/workshop/content/4920/117887554/lua/shine/extensions"

SHINE_EXT_TARGETS=("$SERVER_EXT")
CLEAN_TARGETS=("$SERVER_EXT" "$STEAM_EXT_REPAIR_ONLY")

# Hard refusal, evaluated before any write path so no code path can reach it first.
for _target in "${SHINE_EXT_TARGETS[@]}"; do
  case "$_target" in
    */steamapps/*|*"/Program Files (x86)/Steam"*)
      echo "[deploy] REFUSED: write target is Steam-managed content: $_target" >&2
      echo "[deploy]        see dev/STANDARDS.md - this breaks the real game's mod consistency." >&2
      exit 3 ;;
  esac
done
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
  # CLEAN_TARGETS, not SHINE_EXT_TARGETS: the Steam library copy must be repaired even
  # though it is never a write target.
  for ROOT in "${CLEAN_TARGETS[@]}"; do
    if [[ -d "$ROOT/hordemode" || -d "$ROOT/hordetest" ]]; then
      rm -rf "$ROOT/hordemode" "$ROOT/hordetest"
      echo "[deploy] removed dev extensions from $ROOT"
    fi
  done
}

verify_state() {
  # Two different invariants, because the two copies are not the same kind of thing.
  #
  # 1. The Steam library copy MUST be pristine. Dev files there are not a "parity
  #    mismatch" - they break the user's ability to play the game anywhere. This check
  #    exists so that regression fails loudly instead of looking like a Steam problem.
  # 2. The server copy may be deployed or clean, but if deployed it must match the repo,
  #    so a half-written deploy cannot masquerade as a good one.
  #
  # "Deployed" deliberately no longer claims joins are safe: with dev files in the
  # server's Shine copy the network message table differs from a vanilla client's, and
  # it will be kicked. Headless bot testing is what this state supports.
  local FAILED=0

  if [[ -d "$STEAM_EXT_REPAIR_ONLY/hordemode" || -d "$STEAM_EXT_REPAIR_ONLY/hordetest" ]]; then
    echo "[deploy] FAIL - dev extensions present in the CLIENT's Steam-managed copy:" >&2
    echo "[deploy]        $STEAM_EXT_REPAIR_ONLY" >&2
    echo "[deploy]        this makes every server reject Arian's client ('files out of sync')." >&2
    echo "[deploy]        repair: ./dev/deploy.sh --clean" >&2
    FAILED=1
  else
    echo "[deploy] client copy pristine (Steam-managed tree untouched)"
  fi

  local WANT
  WANT=$(cd "$REPO/source/lua/shine/extensions" && find hordemode hordetest -type f 2>/dev/null | sort | xargs -r md5sum | md5sum | cut -c1-8)

  for ROOT in "${SHINE_EXT_TARGETS[@]}"; do
    if [[ -d "$ROOT/hordemode" ]]; then
      local HAVE
      HAVE=$(cd "$ROOT" && find hordemode hordetest -type f 2>/dev/null | sort | xargs -r md5sum | md5sum | cut -c1-8)

      if [[ "$HAVE" != "$WANT" ]]; then
        echo "[deploy] FAIL - server copy [$HAVE] does not match repo [$WANT]: $ROOT" >&2
        FAILED=1
      else
        echo "[deploy] server copy deployed and matches repo [$WANT]"
        echo "[deploy] NOTE - while this state holds, vanilla clients cannot join this server."
      fi
    else
      echo "[deploy] server copy clean (vanilla) - any client may join"
    fi
  done

  return $FAILED
}

if [[ $CHECK_ONLY -eq 1 ]]; then
  verify_state
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

verify_state || exit 1

# Defence in depth against the 2026-09-21 incident, but aimed only at what is actually
# dangerous: hordetest on a live server spawns bots, takes the commander chair and locks
# the bot controller. hordemode is the gameplay itself, and Arian enabling it on his own
# server is a decision, not a leak - an earlier revision forced that off too and silently
# reverted his flag mid-session, which is how "the server stopped loading hordemode" was
# explained away as a config mystery. Only the test harness is vetoed here.
if [[ -f "$LIVECFG" ]]; then
  python3 - "$LIVECFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
ae = cfg.get("ActiveExtensions", {})
if ae.get("hordetest"):
    ae["hordetest"] = False
    json.dump(cfg, open(path, "w"), indent=4)
    print("[deploy] forced hordetest OFF in the live config (test harness must never run on a live server)")
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
