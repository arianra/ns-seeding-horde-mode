#!/usr/bin/env bash
# publish.sh — stage the artifact into the LaunchPad project and drive publication.
#
#   ./dev/publish.sh              package + stage into the project's output/
#   ./dev/publish.sh --id 12345   record the PublishedFileId LaunchPad returns
#
# LaunchPad's project layout, read off this machine rather than guessed:
#
#   modproject/seedinghorde/
#     mod.settings      name, source_dir="source/", output_dir="output/", description,
#                       image, tag_modtype, tag_support
#     preview.jpg
#     source/           lua/ mapsrc/ materialsrc/ modelsrc/ soundsrc   <- author input
#     output/                                            <- WHAT GETS PUBLISHED
#
# `source/` is for content Builder must compile (maps, materials, models, sounds). Our mod is
# pure Lua, which per UWE's own flow is copied straight into the Output folder. So this script
# stages build/mod/ -> output/ and verifies the two are byte-identical: the bytes LaunchPad
# uploads are the bytes dev/package.sh produced, with no hand-placed file anywhere in between.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO/dev/paths.sh"
paths_validate || exit 3

META="$REPO/mod/mod.json"
VERSION=$(python3 -c "import json;print(json.load(open('$META'))['version'])")
ARTIFACT="$(dist_dir_for "$VERSION")/mod"
NAME=$(python3 -c "import json;print(json.load(open('$META'))['name'])")

if [[ "${1:-}" == "--id" ]]; then
  NEW_ID="${2:-}"
  [[ "$NEW_ID" =~ ^[0-9]+$ ]] || { echo "[publish] --id needs the numeric PublishedFileId" >&2; exit 2; }
  python3 - "$META" "$NEW_ID" <<'PY'
import json, sys
path, new_id = sys.argv[1:3]
m = json.load(open(path))
if m.get("publishedFileId") not in (None, int(new_id)):
    sys.exit(f"[publish] REFUSING to change publishedFileId from {m['publishedFileId']} to {new_id}: "
             "Valve addresses every future update by this id, so it is written once and never edited")
m["publishedFileId"] = int(new_id)
json.dump(m, open(path, "w"), indent=2)
print(f"[publish] recorded PublishedFileId {new_id} in mod/mod.json")
print("[publish] next: ./dev/deploy.sh   (installs under the real id) and ./dev/test.sh")
PY
  exit 0
fi

[[ -d "$MODPROJECT_WSL" ]] || {
  echo "[publish] no LaunchPad project at $MODPROJECT_WSL" >&2
  echo "[publish] create it: LaunchPad (from the install ROOT) -> New -> $HORDE_ROOT_WIN\\modproject -> name $NAME" >&2
  exit 1
}

echo "[publish] building the artifact"
"$REPO/dev/package.sh" >/dev/null
[[ -d "$ARTIFACT" ]] || { echo "[publish] artifact missing: $ARTIFACT" >&2; exit 1; }

OUT="$MODPROJECT_WSL/output"
[[ -d "$OUT" ]] || { echo "[publish] FAIL - LaunchPad's output directory is missing: $OUT" >&2
                     echo "[publish]       create the project with LaunchPad first; do not mkdir it" >&2; exit 1; }

# Sync CONTENTS; never delete the directory itself. LaunchPad owns this path, and a
# previous revision of this script did `rm -rf output/` while LaunchPad had the project
# open - which made the directory it was holding vanish and produced the misleading
# "You must specify an output directory." Removing stale files by name cannot do that.
echo "[publish] staging $ARTIFACT -> $OUT (contents only)"
find "$OUT" -mindepth 1 -maxdepth 1 ! -name '.*' -exec rm -rf {} +
cp -a "$ARTIFACT/." "$OUT/"

# Verify, don't trust: the published bytes must be the built bytes.
WANT=$(cd "$ARTIFACT" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
HAVE=$(cd "$OUT" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
if [[ "$WANT" != "$HAVE" ]]; then
  echo "[publish] FAIL - staged output [$HAVE] != artifact [$WANT]" >&2
  exit 1
fi
echo "[publish] output verified identical to artifact [$HAVE], $(find "$OUT" -type f | wc -l) files"

# Keep the Workshop tile in sync with the repo if we ship one.
if [[ -f "$REPO/mod/preview.jpg" ]]; then
  cp "$REPO/mod/preview.jpg" "$MODPROJECT_WSL/preview.jpg"
  echo "[publish] preview.jpg refreshed from repo"
fi

PUBLISHED=$(python3 -c "import json;print(json.load(open('$META')).get('publishedFileId') or '')")
if [[ -z "$PUBLISHED" ]]; then
  cat <<EOF

[publish] staged and ready. Publication is a human action - it needs Steam running under
          an account that owns NS2, and the first upload accepts the Workshop legal
          agreement. I cannot do this part.

  1. Launch  $LAUNCHPAD_WIN
     (the copy in the INSTALL ROOT - never the one in x64\\)
  2. Open the existing project: $MODPROJECT_WIN
  3. Check Configure -> name/description. Note mod.settings currently declares
     tag_support = "Must be run on Server"; our mod has a shared.lua, so clients DO
     need it. "Must be run on Server" understates that - pick the option that means
     server AND client unless you want to override the tag later on the Workshop page.
  4. Publish.
  5. Then:  ./dev/publish.sh --id <PublishedFileId>

     That writes the id into mod/mod.json, where it lives forever - Valve addresses
     every subsequent update by it, so it is recorded once and never edited.

EOF
else
  echo "[publish] already published as $PUBLISHED - run ./dev/deploy.sh to install under the real id"
fi
