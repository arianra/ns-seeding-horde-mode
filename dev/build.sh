#!/usr/bin/env bash
# build.sh — assemble the `-game` overlay from repo source.
#
#   ./dev/build.sh [output_dir]      default: D:\games\ns2hordetest\overlay
#
# The overlay is the whole dev-loop delivery mechanism, proven on 2026-09-22: the dedicated
# server mounts it with `-game <dir>` and Shine's merged-VFS glob finds our extensions inside
# it (MODDING.md §2b). Nothing here writes into anyone's workshop copy - that was the
# 2026-09-21 incident (dev/STANDARDS.md).
#
# Deliberately absent, both because measurement says they are not needed and because adding
# them would change engine behaviour we do not own:
#   - lua/entry/<name>.entry : only required to run our OWN scripts through ModLoader. Shine is
#     our host; it loads our extensions. G1 mounted the tree with no entry file and both
#     plugins loaded.
#   - game_setup.xml         : overrides the Client/Server VM entry points for the whole game.
#     We are not replacing the game, and a wrong file here silently re-routes NS2's boot.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-/mnt/d/games/ns2hordetest/overlay}"
SRC="$REPO/source/lua/shine/extensions"

[[ -d "$SRC" ]] || { echo "[build] missing source: $SRC" >&2; exit 1; }

# Rebuild from empty: a stale extension that was renamed away in the repo must not survive in
# the overlay, or the suite passes against code that no longer exists.
rm -rf "$OUT/lua/shine/extensions"
mkdir -p "$OUT/lua/shine/extensions"
cp -r "$SRC/." "$OUT/lua/shine/extensions/"

HASH=$(cd "$OUT" && find lua -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
COUNT=$(find "$OUT" -type f | wc -l)

echo "[build] overlay: $OUT"
echo "[build] $COUNT files, payload [$HASH]"

# The overlay must be the ONLY place our dev extensions live. If a workshop copy also has them,
# two mounts answer the same path and which one wins has never been measured - so a green run
# would not tell us which code executed.
for W in "/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/workshop/content/4920/117887554/lua/shine/extensions" \
         "/mnt/c/Program Files (x86)/Steam/steamapps/workshop/content/4920/117887554/lua/shine/extensions"; do
  if [[ -d "$W/hordemode" || -d "$W/hordetest" ]]; then
    echo "[build] FAIL - dev extensions also present in a workshop copy: $W" >&2
    echo "[build]        ambiguous mount precedence; run ./dev/deploy.sh --clean" >&2
    exit 1
  fi
done

echo "[build] ok - dev extensions exist in the overlay only"
