#!/usr/bin/env bash
# publish.sh — build the artifact and hand it to LaunchPad, which opens this repo.
#
#   ./dev/publish.sh                        build, register with LaunchPad, print steps
#   ./dev/publish.sh --id <PublishedFileId> record the id LaunchPad returns
#
# The repo IS the LaunchPad project and lives on D:\, so there is no export step and no
# second copy of anything. That is deliberate: the previous layout kept the repo in WSL
# and exported a project to D:\games\horde\publish, because LaunchPad cannot resolve a
# \\wsl.localhost path (it mangled it to C:\wsl.localhost\... and then truthfully
# reported "output directory cannot be empty"). Measured on this box: git commit, status
# and log, and the beads/Dolt tracker all work on /mnt/d with no meaningful penalty, so
# the repo moved instead of the copies multiplying.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO/dev/paths.sh"
paths_validate || exit 3

META="$REPO/mod/mod.json"

# ------------------------------------------------------------------ record the id
if [[ "${1:-}" == "--id" ]]; then
  NEW_ID="${2:-}"
  [[ "$NEW_ID" =~ ^[0-9]+$ ]] || { echo "[publish] --id needs the numeric PublishedFileId" >&2; exit 2; }
  python3 "$REPO/dev/record-published-id.py" "$META" "$NEW_ID"
  exit $?
fi

[[ -f "$REPO/mod.settings" ]] || {
  echo "[publish] FAIL - no mod.settings in $REPO; this folder is not a LaunchPad project" >&2
  exit 1
}

# ------------------------------------------------------------------ build
"$REPO/dev/package.sh"

if [[ ! -d "$OUTPUT_WSL/lua/entry" ]]; then
  echo "[publish] FAIL - output/ missing after package; investigate rather than continue" >&2
  exit 1
fi
echo "[publish] output/ current: $(find "$OUTPUT_WSL" -type f | wc -l) files"

# ------------------------------------------------------------------ register
# LaunchPad opens whatever %APPDATA%\Natural Selection 2\Launch Pad\options.xml lists as
# <recent_mod>; it does not scan folders. NS2Combat ships a .vbs that writes this same
# file, so registering is normal practice. Stale entries are dropped by the script - a
# pointer to a deleted directory is what produced the misleading empty-output error.
if pgrep -f "LaunchPad" >/dev/null 2>&1; then
  export LAUNCHPAD_RUNNING=1
fi
python3 "$REPO/dev/register-launchpad.py" \
  "$APPDATA_NS2_WSL/Launch Pad/options.xml" "$REPO_SETTINGS_WIN"

PUBLISHED=$(python3 -c "import json;print(json.load(open('$META')).get('publishedFileId') or '')")
if [[ -n "$PUBLISHED" ]]; then
  echo "[publish] already published as $PUBLISHED - run ./dev/deploy.sh to install under the real id"
  exit 0
fi

cat <<EOF

[publish] ready. Publication is a human action: it needs Steam running under an account
          that owns NS2, and the first upload accepts the Workshop legal agreement.

  1. Close LaunchPad if it is open (it rewrites options.xml on exit).
  2. Launch  $LAUNCHPAD_WIN
     (the copy in the INSTALL ROOT - never the one in x64\\)
  3. Open Mod -> $REPO_WIN
  4. Configure -> check name/description and the tags. mod.settings says
     tag_support = "Must be run on Server", but our extension has a shared.lua, so
     clients must mount it too. Choose the server AND client option if offered.
  5. Publish.  Do NOT press Build: builder_setup.xml has no rule for lua, so Build can
     clean output/ without repopulating it. Publish only.
  6. Then:  ./dev/publish.sh --id <PublishedFileId>

     Records the id in mod/mod.json, where it lives forever - Valve addresses every
     subsequent update by it, so it is written once and never edited.

EOF
