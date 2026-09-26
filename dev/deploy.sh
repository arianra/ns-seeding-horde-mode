#!/usr/bin/env bash
# deploy.sh — install the packaged artifact into the DEV server, and configure it.
#
#   ./dev/deploy.sh              package + install + configure the dev server
#   ./dev/deploy.sh --no-test-ext  same, without shipping the test harness
#   ./dev/deploy.sh --clean        remove our mod from the dev storage AND repair any
#                                 dev files an earlier revision left in a Workshop copy
#   ./dev/deploy.sh --check        verify state without writing (exit 1 = unsafe)
#   ./dev/deploy.sh --for-suite    arm hordetest so it runs on boot (test.sh only)
#
# This script installs an ARTIFACT, it does not copy source into a running game. The
# distinction is the whole lesson of 2026-09-21/23: dev files were once mirrored into
# the client's Workshop copy of Shine, which made every server on the internet reject
# Arian's client; the interim fix (a -game overlay) worked but is not what a player
# receives, so it validated nothing about packaging.
#
# Ownership rules: dev/STANDARDS.md. In short - never write under steamapps, never
# write inside another publisher's workshop item, never write the LIVE config.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO/dev/paths.sh"
paths_validate || exit 3

DEV_CFG="$DEV_CFG_WSL"
DEV_MODS="$DEV_MODS_WSL/content/4920"

# Repair targets: removed by --clean, never written to. Listed so this tool can undo
# what an earlier revision of itself did.
REPAIR_TARGETS=("$SERVER_SHINE_EXT" "$CLIENT_SHINE_EXT")

# LIVE_CFG_WSL is defined in paths.sh and is deliberately never written here.

INCLUDE_TEST=1
CLEAN_ONLY=0
CHECK_ONLY=0
FOR_SUITE=0
for Arg in "$@"; do
  case "$Arg" in
    --no-test-ext) INCLUDE_TEST=0 ;;
    --clean) CLEAN_ONLY=1 ;;
    --check) CHECK_ONLY=1 ;;
    --for-suite) FOR_SUITE=1 ;;
    *) echo "[deploy] unknown option: $Arg" >&2; exit 2 ;;
  esac
done



MOD_ID=$(python3 -c "import json;m=json.load(open('$REPO/mod/mod.json'));print(m.get('publishedFileId') or m['modId'])")
HEX_ID=$(printf '%x' "$MOD_ID")
VERSION=$(python3 -c "import json;print(json.load(open('$REPO/mod/mod.json'))['version'])")
INSTALL_DIR="$DEV_MODS/$MOD_ID"
ARTIFACT_DIR="$OUTPUT_WSL"

repair_workshop_copies() {
  for ROOT in "${REPAIR_TARGETS[@]}"; do
    if [[ -d "$ROOT/hordemode" || -d "$ROOT/hordetest" ]]; then
      rm -rf "$ROOT/hordemode" "$ROOT/hordetest"
      echo "[deploy] repaired Workshop copy: removed dev extensions from $ROOT"
    fi
  done
}

uninstall() {
  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "[deploy] removed installed mod $INSTALL_DIR"
  fi
  if [[ -f "$DEV_CFG/MapCycle.json" ]]; then
    python3 - "$DEV_CFG/MapCycle.json" "$HEX_ID" "$MOD_ID" <<'PY'
import json, sys
cfg, hex_id, dec = sys.argv[1:4]
d = json.load(open(cfg))
mods = d.get("mods", [])
kept = [m for m in mods if str(m) not in (hex_id, dec)]
if kept != mods:
    d["mods"] = kept
    json.dump(d, open(cfg, "w"), indent=2)
    print(f"[deploy] removed {hex_id} from dev MapCycle mods")
PY
  fi
}

verify_state() {
  local FAILED=0

  # 1. no dev extensions inside anyone's Workshop item - this is the incident check
  for ROOT in "${REPAIR_TARGETS[@]}"; do
    if [[ -d "$ROOT/hordemode" || -d "$ROOT/hordetest" ]]; then
      echo "[deploy] FAIL - dev extensions inside a Workshop copy: $ROOT" >&2
      echo "[deploy]        repair: ./dev/deploy.sh --clean" >&2
      FAILED=1
    fi
  done
  [[ -d "$CLIENT_SHINE_EXT" ]] && echo "[deploy] client Workshop copy pristine"

  # 2. the installed mod must be byte-identical to the artifact, not to source/
  if [[ ! -d "$INSTALL_DIR/lua/entry" ]]; then
    echo "[deploy] mod not installed ($INSTALL_DIR) - run ./dev/deploy.sh"
    return $FAILED
  fi

  local WANT HAVE
  WANT=$(cd "$ARTIFACT_DIR" 2>/dev/null && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
  HAVE=$(cd "$INSTALL_DIR" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)

  if [[ -z "$WANT" ]]; then
    echo "[deploy] FAIL - no output/ at $ARTIFACT_DIR; run ./dev/package.sh" >&2; FAILED=1
  elif [[ "$WANT" != "$HAVE" ]]; then
    echo "[deploy] FAIL - installed mod [$HAVE] != artifact [$WANT]" >&2
    echo "[deploy]        re-run ./dev/deploy.sh (never patch the install directory)" >&2
    FAILED=1
  else
    echo "[deploy] installed mod matches artifact [$HAVE] ($HEX_ID, $(find "$INSTALL_DIR" -type f | wc -l) files)"
  fi

  # 3. it must be listed in MapCycle or it unloads on the first map change
  if grep -q "$HEX_ID" "$DEV_CFG/MapCycle.json" 2>/dev/null; then
    echo "[deploy] dev MapCycle lists $HEX_ID"
  else
    echo "[deploy] FAIL - $HEX_ID not in dev MapCycle mods; the mod unloads on map change" >&2
    FAILED=1
  fi

  # 4. delivery: unpublished ids only mount via the backup server
  if [[ "$(python3 -c "import json;print(json.load(open('$REPO/mod/mod.json')).get('publishedFileId'))")" == "None" ]]; then
    if grep -q "127.0.0.1:$MODSERVER_PORT" "$DEV_CFG/ServerConfig.json" 2>/dev/null; then
      echo "[deploy] dev server configured to fetch mods from the local backup server"
    else
      echo "[deploy] FAIL - mod is unpublished and no backup server is configured;" >&2
      echo "[deploy]        the engine will refuse to mount it (see dev/modserver.sh)" >&2
      FAILED=1
    fi
  else
    echo "[deploy] mod is published (id $MOD_ID) - Steam can deliver it directly"
  fi

  return $FAILED
}

if [[ $CHECK_ONLY -eq 1 ]]; then
  verify_state
  exit $?
fi

if [[ $CLEAN_ONLY -eq 1 ]]; then
  echo "[deploy] --clean: uninstalling dev mod and repairing Workshop copies"
  uninstall
  repair_workshop_copies
  for _ov in "/mnt/d/games/ns2hordetest/overlay" "$HORDE_ROOT_WSL/overlay"; do
    [[ -d "$_ov" ]] && rm -rf "$_ov" && echo "[deploy] removed obsolete -game overlay: $_ov"
  done
  exit 0
fi

echo "[deploy] repo=$REPO  mod=$MOD_NAME id=$MOD_ID"

# --- 1. the artifact is the only thing we install -------------------------
"$REPO/dev/package.sh"
repair_workshop_copies

# The -game overlay was a search-path shortcut that let us develop without exercising
# mounting, delivery or the entry file. Delete it wherever an older layout left it.
for _ov in "/mnt/d/games/ns2hordetest/overlay" "$HORDE_ROOT_WSL/overlay"; do
  [[ -d "$_ov" ]] && rm -rf "$_ov" && echo "[deploy] removed obsolete -game overlay: $_ov"
done

if [[ $INCLUDE_TEST -eq 0 ]]; then
  rm -rf "$ARTIFACT_DIR/lua/shine/extensions/hordetest"
  echo "[deploy] dropped hordetest from the artifact (--no-test-ext)"
fi

# --- 2. install ------------------------------------------------------------
rm -rf "$INSTALL_DIR"
mkdir -p "$DEV_MODS"
cp -r "$ARTIFACT_DIR/." "$INSTALL_DIR/"
echo "[deploy] installed -> $INSTALL_DIR"

# --- 2b. retire the id we used last time ----------------------------------
# When mod.json's id changes (placeholder -> published, or a re-publish), the old folder
# and its MapCycle entry must go. Leaving them behind means every boot logs
# "Mod [old] wasn't available" - real errors about a stale artifact, which is exactly the
# noise that makes a working system look broken.
MARKER="$DEV_MODS/.installed-id"
if [[ -f "$MARKER" ]]; then
  PREV=$(tr -dc '0-9' < "$MARKER")
  if [[ -n "$PREV" && "$PREV" != "$MOD_ID" ]]; then
    PREV_HEX=$(printf '%x' "$PREV")
    rm -rf "$DEV_MODS/$PREV"
    echo "[deploy] retired previous id $PREV (folder removed)"
    python3 "$REPO/dev/prune-mapcycle.py" "$DEV_CFG/MapCycle.json" "$PREV_HEX" "$PREV"
  fi
fi
mkdir -p "$(dirname "$MARKER")" && echo "$MOD_ID" > "$MARKER"

# --- 3. configure the DEV server (never the live one) ---------------------
python3 - "$DEV_CFG" "$HEX_ID" "$MOD_ID" <<'PY'
import json, os, sys
cfg_dir, hex_id, dec = sys.argv[1:4]

mc_path = os.path.join(cfg_dir, "MapCycle.json")
if os.path.exists(mc_path):
    mc = json.load(open(mc_path))
    mods = mc.setdefault("mods", [])
    if hex_id not in [str(m) for m in mods]:
        mods.append(hex_id)
        json.dump(mc, open(mc_path, "w"), indent=2)
    print(f"[deploy] dev MapCycle mods: {mods}")

PY

# Mod delivery is decided by what actually answers, not by a hope written into config: the
# backup server is a separate manual step, and advertising a URL that 404s sends a joining
# client away from Steam and into nothing. See dev/set-mod-delivery.py for the incident.
"$REPO/dev/check-delivery.sh" "$DEV_CFG" || exit 1

# --- 4. test-harness arming stays explicit (a manual boot must be joinable)
# Arming is explicit. A manual boot must be a server you can join; only test.sh asks
# for the harness to run, because the suite spawns and destroys bots and takes the
# commander chair.
HARDCFG="$DEV_CFG/shine/plugins/HordeTest.json"
if [[ -f "$HARDCFG" ]]; then
  if [[ $FOR_SUITE -eq 1 ]]; then
    printf '{\n    "RunSuite" : true\n}\n' > "$HARDCFG"
    echo "[deploy] hordetest ARMED - the suite will run on this boot"
  else
    printf '{\n    "RunSuite" : false\n}\n' > "$HARDCFG"
    echo "[deploy] hordetest idle - joinable server; ./dev/test.sh arms it"
  fi
fi

verify_state || exit 1
echo "[deploy] done"
