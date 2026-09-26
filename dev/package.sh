#!/usr/bin/env bash
# package.sh — assemble output/ from source/ and produce the release archives.
#
#   ./dev/package.sh            build output/ and dist/<version>/
#   ./dev/package.sh --clean    remove output/ and dist/
#
# The repo IS the LaunchPad project (mod.settings names source/ and output/), so this
# script's job is deliberately small:
#
#   source/   the mod tree, hand-written, version-controlled - the only truth
#   output/   a copy of source/, what LaunchPad publishes - generated, gitignored
#   dist/     versioned archives + manifest - generated, gitignored
#
# There is no transformation to perform. The entry file lives in
# source/lua/entry/ because it is authored content, not generated. So output/ is a
# mirror, and it exists only because that is what LaunchPad publishes.
#
# KNOWN LIMITATION, stated rather than hidden: builder_setup.xml ships rules for
# .cinematic/.fnt/.render_setup/.shader_template/.psd and NO rule for lua. If you press
# Build in LaunchPad it may clean output/ and then fail to repopulate our Lua, yielding
# an incomplete mod. Use this script to produce output/ and LaunchPad only to Publish.
# Adding a lua copy rule to a project-local builder setup would fix that; it needs the
# rule syntax verified, so it is deliberately not guessed at here.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO/dev/paths.sh"
paths_validate || exit 3

META="$REPO/mod/mod.json"
SETTINGS="$REPO/mod.settings"
SRC="$REPO/source"
OUT="$REPO/output"
DIST="$REPO/dist"

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$OUT" "$DIST"
  echo "[package] removed output/ and dist/"
  exit 0
fi

for req in "$META" "$SETTINGS" "$SRC"; do
  [[ -e "$req" ]] || { echo "[package] missing required input: $req" >&2; exit 1; }
done

eval "$(python3 -c "
import json
m = json.load(open('$META'))
mid = m.get('publishedFileId') or m['modId']
print(f'VERSION={m[\"version\"]}')
print(f'MOD_ID={mid}')
print(f'HEX_ID={mid:x}')
print(f'UNPUBLISHED={1 if m.get(\"publishedFileId\") is None else 0}')
# The protocol filename carries the mod VERSION, which for a Workshop item is Steam
# time_updated, not our semver. Pre-publication the engine asks for version 0 (observed:
# mod [999000001] with version 0), so 0 is the honest placeholder. After publication,
# record Steam number in mod.json workshopVersion and it is used verbatim.
print(f'ARCHIVE_VERSION={0 if m.get(\"publishedFileId\") is None else (m.get(\"workshopVersion\") or 0)}')
")"

# ---------------------------------------------------------------- validation
# Two files name the mod: mod.json (ours) and mod.settings (LaunchPad's). A mismatch
# would publish a tree whose entry filename disagrees with the project, which is the
# kind of silent inconsistency this project has already been bitten by.
SETTINGS_NAME=$(sed -n 's/^name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$SETTINGS")
[[ "$SETTINGS_NAME" == "$MOD_NAME" ]] || {
  echo "[package] FAIL - mod name mismatch: mod.json '$MOD_NAME' vs mod.settings '$SETTINGS_NAME'" >&2
  echo "[package]        the entry filename IS the mod name (ModLoader.lua:227-229)" >&2; exit 1; }

[[ -f "$SRC/lua/entry/$MOD_NAME.entry" ]] || {
  echo "[package] FAIL - no source/lua/entry/$MOD_NAME.entry" >&2
  echo "[package]        LaunchPad's mod name comes from this file; without it the folder" >&2
  echo "[package]        is not a mod to the loader" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || {
  echo "[package] FAIL - version '$VERSION' is not semver (0.0.1, 0.1.0-rc1)" >&2; exit 1; }

# ---------------------------------------------------------------- assemble
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$SRC/." "$OUT/"
# preview.jpg is NOT copied into output/: mod.settings declares it as `image`, i.e. a
# project-level workshop tile, not mod content. Copying it here broke the mirror check
# below, which is exactly the check that catches a stale or partial output/.

SRC_HASH=$(cd "$SRC" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
OUT_HASH=$(cd "$OUT" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
[[ "$SRC_HASH" == "$OUT_HASH" ]] || {
  echo "[package] FAIL - output [$OUT_HASH] does not mirror source [$SRC_HASH]" >&2; exit 1; }

# ---------------------------------------------------------------- archives
BUILD_DIST="$DIST/$VERSION"
mkdir -p "$BUILD_DIST"
python3 - "$OUT" "$BUILD_DIST/$MOD_NAME-$VERSION.zip" "$BUILD_DIST/m${HEX_ID}_${ARCHIVE_VERSION}.zip" <<'PY'
import os, sys, zipfile
src, a, b = sys.argv[1:4]
files = sorted(os.path.relpath(os.path.join(r, f), src) for r, _, fs in os.walk(src) for f in fs)
# Fixed timestamps and sorted members: a rebuild of identical inputs must produce
# identical bytes, or "the artifact changed" and "the source changed" become
# indistinguishable - the exact confusion WorkshopBackup's README documents as
# version skew between server and clients.
for out in (a, b):
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for n in files:
            info = zipfile.ZipInfo(n, date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            with open(os.path.join(src, n), "rb") as fh:
                z.writestr(info, fh.read())
print(f"[package] {len(files)} files per archive")
PY

# Drop archives the protocol can no longer address. The pre-publication placeholder sat in this
# folder beside the published one, and "the first m*_*.zip" found IT - then reported HTTP 200
# about the wrong bytes. A generated directory that keeps answering to a superseded name is a
# trap for anything that lists it, so it does not get to keep them.
while IFS= read -r STALE; do
  [[ -n "$STALE" ]] || continue
  echo "[package] removing superseded artifact: $(basename "$STALE")"
  rm -f "$STALE"
done < <(find "$BUILD_DIST" -maxdepth 1 -name 'm*_*.zip' ! -name "m${HEX_ID}_${ARCHIVE_VERSION}.zip" 2>/dev/null)

python3 - "$BUILD_DIST/manifest.json" "$MOD_NAME" "$VERSION" "$MOD_ID" "$HEX_ID" "$OUT_HASH" "$UNPUBLISHED" "$ARCHIVE_VERSION" <<'PY'
import json, os, sys
out, name, version, mod_id, hex_id, tree_hash, unpub, arver = sys.argv[1:9]
base = os.path.dirname(out)
files = sorted(os.path.relpath(os.path.join(r, f), os.path.join(base, "..", "..", "output"))
               for r, _, fs in os.walk(os.path.join(base, "..", "..", "output")) for f in fs)
json.dump({
    "name": name, "version": version, "modId": int(mod_id), "hexId": hex_id,
    "published": unpub == "0",
    "workshopVersion": int(arver),
    "outputHash": tree_hash,
    "archives": [f"{name}-{version}.zip", f"m{hex_id}_{int(arver)}.zip"],
    "files": files,
}, open(out, "w"), indent=2)
PY

echo "[package] mod '$MOD_NAME' v$VERSION  id=$MOD_ID (hex $HEX_ID, protocol version $ARCHIVE_VERSION$( [ "$UNPUBLISHED" = 1 ] && echo ', UNPUBLISHED'))"
echo "[package] output mirrors source [$OUT_HASH]"
echo "[package] dist -> $BUILD_DIST"
ls -1 "$BUILD_DIST" | sed 's/^/[package]   /'
