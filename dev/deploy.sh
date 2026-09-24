#!/usr/bin/env bash
# deploy.sh — install the packaged artifact into the DEV server, and configure it.
#
#   ./dev/deploy.sh              package + install + configure the dev server
#   ./dev/deploy.sh --no-test-ext  same, without shipping the test harness
#   ./dev/deploy.sh --clean        remove our mod from the dev storage AND repair any
#                                 dev files an earlier revision left in a Workshop copy
#   ./dev/deploy.sh --check        verify state without writing (exit 1 = unsafe)
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

DEV_ROOT="/mnt/d/games/ns2hordetest"
DEV_CFG="$DEV_ROOT/cfg"
DEV_MODS="$DEV_ROOT/mods/content/4920"
DEV_OVERLAY="$DEV_ROOT/overlay"

# Repair targets: removed by --clean, never written to. Listed so this tool can undo
# what an earlier revision of itself did.
SERVER_SHINE_EXT="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/workshop/content/4920/117887554/lua/shine/extensions"
CLIENT_SHINE_EXT="/mnt/c/Program Files (x86)/Steam/steamapps/workshop/content/4920/117887554/lua/shine/extensions"
REPAIR_TARGETS=("$SERVER_SHINE_EXT" "$CLIENT_SHINE_EXT")

LIVECFG="$DEV_CFG/../.."   # never used for writes; the live config is not this script's business

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

# Refuse, at parse time, to write anywhere Steam owns.
case "$DEV_ROOT" in
  */steamapps/*|*"/Program Files (x86)/Steam"*)
    echo "[deploy] REFUSED: dev root is Steam-managed: $DEV_ROOT" >&2; exit 3 ;;
esac

MOD_ID=$(python3 -c "import json;m=json.load(open('$REPO/mod/mod.json'));print(m.get('publishedFileId') or m['modId'])")
HEX_ID=$(printf '%x' "$MOD_ID")
MOD_NAME=$(python3 -c "import json;print(json.load(open('$REPO/mod/mod.json'))['name'])")
INSTALL_DIR="$DEV_MODS/$MOD_ID"

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
  WANT=$(cd "$REPO/build/mod" 2>/dev/null && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
  HAVE=$(cd "$INSTALL_DIR" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)

  if [[ -z "$WANT" ]]; then
    echo "[deploy] FAIL - no artifact in build/mod; run ./dev/package.sh" >&2; FAILED=1
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
    if grep -q "127.0.0.1:27020" "$DEV_CFG/ServerConfig.json" 2>/dev/null; then
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
  [[ -d "$DEV_OVERLAY" ]] && rm -rf "$DEV_OVERLAY" && echo "[deploy] removed the obsolete -game overlay"
  exit 0
fi

echo "[deploy] repo=$REPO  mod=$MOD_NAME id=$MOD_ID"

# --- 1. the artifact is the only thing we install -------------------------
"$REPO/dev/package.sh"
repair_workshop_copies

# The overlay is gone on purpose. It was a search-path shortcut that let us develop
# without ever exercising mod mounting, delivery, or the entry file.
if [[ -d "$DEV_OVERLAY" ]]; then
  rm -rf "$DEV_OVERLAY"
  echo "[deploy] removed obsolete -game overlay (dev now installs the real artifact)"
fi

if [[ $INCLUDE_TEST -eq 0 ]]; then
  rm -rf "$REPO/build/mod/lua/shine/extensions/hordetest"
  echo "[deploy] dropped hordetest from the artifact (--no-test-ext)"
fi

# --- 2. install ------------------------------------------------------------
rm -rf "$INSTALL_DIR"
mkdir -p "$DEV_MODS"
cp -r "$REPO/build/mod/." "$INSTALL_DIR/"
echo "[deploy] installed -> $INSTALL_DIR"

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

sc_path = os.path.join(cfg_dir, "ServerConfig.json")
if os.path.exists(sc_path):
    sc = json.load(open(sc_path))
    st = sc.setdefault("settings", {})
    url = "http://127.0.0.1:27020"
    servers = st.get("mod_backup_servers") or []
    if url not in servers:
        servers.append(url)
    st["mod_backup_servers"] = servers
    # Unpublished items cannot be resolved by Steam at all, so try the backup first.
    st["mod_backup_before_steam"] = True
    json.dump(sc, open(sc_path, "w"), indent=2)
    print(f"[deploy] dev ServerConfig: mod_backup_servers={servers}, before_steam=True")
PY

# --- 4. test-harness arming stays explicit (a manual boot must be joinable)
HARDCFG="$DEV_CFG/shine/plugins/HordeTest.json"
if [[ -f "$HARDCFG" ]]; then
  printf '{\n    "RunSuite" : false\n}\n' > "$HARDCFG"
  echo "[deploy] hordetest idle - this server is joinable; ./dev/test.sh arms it"
fi

verify_state || exit 1
echo "[deploy] done"
