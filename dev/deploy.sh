#!/usr/bin/env bash
# deploy.sh — stage the dev extensions into the `-game` overlay and enable them in the TEST
# config only. It never writes into anyone's workshop copy.
#
#   ./dev/deploy.sh              build the overlay + enable extensions in the test config
#   ./dev/deploy.sh --no-test-ext  same, without the test harness
#   ./dev/deploy.sh --clean      remove dev extensions from every workshop copy (repair)
#   ./dev/deploy.sh --check      verify state without writing (exit 1 = unsafe)
#
# Why not workshop copies (2026-09-21 incident, dev/STANDARDS.md): the server mounts its Shine
# copy from %APPDATA%, the client mounts its own from steamapps. Writing dev files into either
# is what made every server reject Arian's client. The overlay replaces both: proven in
# MODDING.md §2b that `-game <dir>` mounts and Shine discovers extensions inside it.
#
# The workshop paths survive ONLY in CLEAN_TARGETS, so this tool can undo what an earlier
# revision of itself did.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY_DIR="${OVERLAY_DIR:-/mnt/d/games/ns2hordetest/overlay}"

# Repair targets: removed by --clean, never written to.
SERVER_SHINE_EXT="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/workshop/content/4920/117887554/lua/shine/extensions"
CLIENT_SHINE_EXT="/mnt/c/Program Files (x86)/Steam/steamapps/workshop/content/4920/117887554/lua/shine/extensions"
CLEAN_TARGETS=("$SERVER_SHINE_EXT" "$CLIENT_SHINE_EXT")

# Refuse, at parse time, any write target that lives in Steam-managed territory. The overlay is
# user space today; this guard exists so a future edit cannot quietly make it something else.
for _target in "$OVERLAY_DIR"; do
  case "$_target" in
    */steamapps/*|*"/Program Files (x86)/Steam"*)
      echo "[deploy] REFUSED: write target is Steam-managed content: $_target" >&2
      echo "[deploy]        see dev/STANDARDS.md - this breaks the real game's mod consistency." >&2
      exit 3 ;;
  esac
done

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
    *) echo "[deploy] unknown option: $Arg" >&2; exit 2 ;;
  esac
done

remove_from_targets() {
  for ROOT in "${CLEAN_TARGETS[@]}"; do
    if [[ -d "$ROOT/hordemode" || -d "$ROOT/hordetest" ]]; then
      rm -rf "$ROOT/hordemode" "$ROOT/hordetest"
      echo "[deploy] repaired workshop copy: removed dev extensions from $ROOT"
    fi
  done
}

verify_state() {
  # Three invariants, in order of how bad each failure is.
  #
  # 1. No dev extensions in ANY workshop copy. The client copy breaks the game outright; the
  #    server copy is subtler - it silently wins or loses against the overlay, and mount
  #    precedence has never been measured, so a green suite would not say which code ran.
  # 2. The overlay exists and matches the repo payload.
  local FAILED=0

  for ROOT in "${CLEAN_TARGETS[@]}"; do
    if [[ -d "$ROOT/hordemode" || -d "$ROOT/hordetest" ]]; then
      echo "[deploy] FAIL - dev extensions present in a workshop copy: $ROOT" >&2
      echo "[deploy]        mount precedence vs the overlay is unmeasured, so results are ambiguous;" >&2
      echo "[deploy]        if this is the client copy, joins to every server will fail." >&2
      echo "[deploy]        repair: ./dev/deploy.sh --clean" >&2
      FAILED=1
    fi
  done

  if [[ -d "$CLIENT_SHINE_EXT" ]]; then
    echo "[deploy] client workshop copy clean (Steam-managed tree untouched)"
  else
    echo "[deploy] NOTE - client workshop copy not found at: $CLIENT_SHINE_EXT"
  fi

  local WANT HAVE COUNT
  WANT=$(cd "$REPO/source/lua/shine/extensions" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)

  if [[ ! -d "$OVERLAY_DIR/lua/shine/extensions/hordemode" ]]; then
    echo "[deploy] overlay not built (run ./dev/build.sh) - $OVERLAY_DIR"
    return $FAILED
  fi

  HAVE=$(cd "$OVERLAY_DIR/lua/shine/extensions" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
  COUNT=$(find "$OVERLAY_DIR" -type f | wc -l)

  if [[ "$HAVE" != "$WANT" ]]; then
    echo "[deploy] FAIL - overlay [$HAVE] does not match repo [$WANT] ($COUNT files)" >&2
    echo "[deploy]        run ./dev/deploy.sh to rebuild" >&2
    FAILED=1
  else
    echo "[deploy] overlay matches repo [$WANT], $COUNT files"
    echo "[deploy] NOTE - boot with: -game D:\\games\\ns2hordetest\\overlay"
  fi

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
"$REPO/dev/build.sh" "$OVERLAY_DIR"

if [[ $INCLUDE_TEST -eq 0 ]]; then
  rm -rf "$OVERLAY_DIR/lua/shine/extensions/hordetest"
  echo "[deploy] removed hordetest from the overlay (--no-test-ext)"
fi

verify_state || exit 1

# Defence in depth against the 2026-09-21 incident, aimed only at what is dangerous: hordetest
# on a live server spawns bots, takes the commander chair and locks the bot controller.
# hordemode is the gameplay itself and enabling it on Arian's server is his decision - an earlier
# revision vetoed that too and silently reverted his flag mid-session.
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

# Enable our extensions in the TEST config only.
if [[ -f "$BASECFG" ]]; then
  python3 - "$BASECFG" "$INCLUDE_TEST" <<'PY'
import json, sys
path, include_test = sys.argv[1], sys.argv[2] == "1"
cfg = json.load(open(path))
ae = cfg.setdefault("ActiveExtensions", {})
ae["hordemode"] = True
ae["hordetest"] = include_test
json.dump(cfg, open(path, "w"), indent=4)
print(f"[deploy] test config ActiveExtensions: hordemode=True hordetest={include_test}")
PY
else
  echo "[deploy] WARN - no test BaseConfig at $BASECFG; boot once so Shine creates it, then re-run" >&2
fi

echo "[deploy] done"
