#!/usr/bin/env bash
# paths.sh — the ONE definition of every path this project uses.
#
# Sourced by dev/*.sh. Nothing else may hard-code a location. The reason is not
# tidiness: paths were scattered across D:\games during early sessions (an abandoned
# config dump holding live tokens, a hyphenated dir the engine could not parse, a
# "test" directory that had quietly become the project's permanent home), and the
# human had to ask what all of it was. One file answers that question permanently.
#
# Layout
#   D:\games\horde\                 permanent root for this project's own files
#       modproject\seedinghorde\    LaunchPad project - the publication vehicle
#       dist\<version>\             release artifacts produced by package.sh
#       server\cfg\                 DEV server config   (disposable, generated)
#       server\mods\                DEV mod storage     (isolated via -modstorage)
#   D:\games\ns2srv\cfg             LIVE server config  - ARIAN'S, never written
#   D:\games\ns2-server\            engine + dedicated server (steamcmd app 4940)
#
# Two constraints encoded below, both learned expensively:
#   1. No hyphens. The launch-argument parser's token break-set is `-+;`, so a hyphen
#      inside -config_path truncates the value (MODDING.md fact 17).
#   2. Nothing under steamapps is ever a write target (dev/STANDARDS.md).

# --- root --------------------------------------------------------------------
HORDE_ROOT_WIN='D:\games\horde'
HORDE_ROOT_WSL='/mnt/d/games/horde'

# --- project-owned, permanent ------------------------------------------------
MOD_NAME='seedinghorde'
MODPROJECT_WIN="$HORDE_ROOT_WIN\\modproject\\$MOD_NAME"
MODPROJECT_WSL="$HORDE_ROOT_WSL/modproject/$MOD_NAME"
DIST_WIN="$HORDE_ROOT_WIN\\dist"
DIST_WSL="$HORDE_ROOT_WSL/dist"

# --- dev server instance (disposable: delete it and deploy.sh rebuilds it) ----
DEV_CFG_WIN="$HORDE_ROOT_WIN\\server\\cfg"
DEV_CFG_WSL="$HORDE_ROOT_WSL/server/cfg"
DEV_MODS_WIN="$HORDE_ROOT_WIN\\server\\mods"
DEV_MODS_WSL="$HORDE_ROOT_WSL/server/mods"
DEV_LOG_DIR="$DEV_CFG_WSL/shine/logs"

# --- the user's live server: read-only ---------------------------------------
LIVE_CFG_WIN='D:\games\ns2srv\cfg'
LIVE_CFG_WSL='/mnt/d/games/ns2srv/cfg'

# --- engine and shared runtime state -----------------------------------------
ENGINE_WIN='D:\games\ns2-server'
ENGINE_WSL='/mnt/d/games/ns2-server'
# Engine logs, crash dumps and the default mod store ignore -config_path and are
# shared by every instance on this box (MODDING.md fact 15).
APPDATA_NS2_WSL="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2"
LOG_WSL="$APPDATA_NS2_WSL/log-Server.txt"
CLIENT_LOG_WSL="$APPDATA_NS2_WSL/log.txt"
DUMPLOG_WSL="$APPDATA_NS2_WSL/dumps/dumplog.txt"

# Workshop copies of Shine. Repair targets for --clean, NEVER write targets.
SERVER_SHINE_EXT="$APPDATA_NS2_WSL/workshop/content/4920/117887554/lua/shine/extensions"
CLIENT_SHINE_EXT="/mnt/c/Program Files (x86)/Steam/steamapps/workshop/content/4920/117887554/lua/shine/extensions"

# --- ports -------------------------------------------------------------------
LIVE_PORT=27015          # engine default; a second port (27016) also opens
DEV_PORT=27025           # paired allocation: DEV takes P and P+1
MODSERVER_PORT=27020     # UWE's WorkshopBackup default for the backup protocol

# --- guards ------------------------------------------------------------------
# Fail fast, from one place, on the two rules above.
paths_validate() {
  local p
  for p in "$DEV_CFG_WIN" "$DEV_MODS_WIN" "$MODPROJECT_WIN" "$DIST_WIN"; do
    case "$p" in
      *-*) echo "[paths] FAIL - path contains a hyphen, which the engine's argument parser truncates: $p" >&2; return 1 ;;
    esac
  done
  for p in "$DEV_CFG_WSL" "$DEV_MODS_WSL" "$MODPROJECT_WSL" "$DIST_WSL"; do
    case "$p" in
      */steamapps/*|*"/Program Files (x86)/Steam"*)
        echo "[paths] FAIL - a project write path is inside Steam-managed content: $p" >&2
        echo "[paths]        see dev/STANDARDS.md - this breaks the real game's mod consistency" >&2
        return 1 ;;
    esac
  done
  return 0
}

# Where a version's artifact lives. One function so no script invents its own scheme.
dist_dir_for() {          # $1 = version
  echo "$DIST_WSL/$1"
}
dist_dir_for_win() {      # $1 = version
  echo "$DIST_WIN\\$1"
}

# --- the player's game install -------------------------------------------------
# Read-only to us (dev/STANDARDS.md). Defined here so no script hard-codes it when
# telling a human where LaunchPad lives.
CLIENT_INSTALL_WIN='C:\Program Files (x86)\Steam\steamapps\common\Natural Selection 2'
CLIENT_INSTALL_WSL='/mnt/c/Program Files (x86)/Steam/steamapps/common/Natural Selection 2'
LAUNCHPAD_WIN="$CLIENT_INSTALL_WIN\\LaunchPad.exe"
