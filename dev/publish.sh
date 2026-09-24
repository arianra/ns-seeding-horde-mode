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
SRC="$REPO/source"
VERSION=$(python3 -c "import json;print(json.load(open('$META'))['version'])")
ARTIFACT="$(dist_dir_for "$VERSION")/mod"
NAME=$(python3 -c "import json;print(json.load(open('$META'))['name'])")

if [[ "${1:-}" == "--id" ]]; then
  NEW_ID="${2:-}"
  [[ "$NEW_ID" =~ ^[0-9]+$ ]] || { echo "[publish] --id needs the numeric PublishedFileId" >&2; exit 2; }
  python3 - "$REPO/mod/mod.json" "$NEW_ID" <<'PY'
import json, sys
path, new_id = sys.argv[1:3]
m = json.load(open(path))
if m.get("publishedFileId") not in (None, int(new_id)):
    sys.exit(f"[publish] REFUSING to change publishedFileId from {m['publishedFileId']} to {new_id}: "
             "Valve addresses every future update by this id, so it is written once and never edited")
m["publishedFileId"] = int(new_id)
json.dump(m, open(path, "w"), indent=2)
print(f"[publish] recorded PublishedFileId {new_id} in mod/mod.json")
print("[publish] next: ./dev/deploy.sh   (installs under the real id), then ./dev/test.sh")
PY
  exit 0
fi

# package.sh is the only producer of output/. publish.sh verifies it is current and then
# says what a human has to click. No copying between trees, no second copy of the mod.
"$REPO/dev/package.sh"

if [[ ! -d "$OUTPUT_WSL/lua/entry" ]]; then
  echo "[publish] FAIL - output/ missing after package; investigate instead of continuing" >&2
  exit 1
fi
echo "[publish] output/ current: $(find "$OUTPUT_WSL" -type f | wc -l) files"

# ---------------------------------------------------------------- export
# LaunchPad gets a plain Windows path and a self-contained project, generated one way
# from the repo. Nothing is authored in it, so it can be deleted and recreated freely.
mkdir -p "$PUBLISH_ROOT_WSL"
rm -rf "$PUBLISH_PROJECT_WSL"
mkdir -p "$PUBLISH_PROJECT_WSL"
cp -a "$REPO/mod.settings" "$PUBLISH_PROJECT_WSL/mod.settings"
[[ -f "$REPO/preview.jpg" ]] && cp -a "$REPO/preview.jpg" "$PUBLISH_PROJECT_WSL/preview.jpg"
cp -a "$OUTPUT_WSL" "$PUBLISH_PROJECT_WSL/output"
cp -a "$SRC" "$PUBLISH_PROJECT_WSL/source"

# Verify the export survived the copy rather than assuming it did.
REPO_HASH=$(cd "$OUTPUT_WSL" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
EXP_HASH=$(cd "$PUBLISH_PROJECT_WSL/output" && find . -type f | sort | xargs -r md5sum | md5sum | cut -c1-8)
if [[ "$REPO_HASH" != "$EXP_HASH" ]]; then
  echo "[publish] FAIL - exported output [$EXP_HASH] != repo output [$REPO_HASH]" >&2
  exit 1
fi
echo "[publish] exported project -> $PUBLISH_PROJECT_WIN  (output verified [$EXP_HASH])"

PUBLISHED=$(python3 -c "import json;print(json.load(open('$META')).get('publishedFileId') or '')")
if [[ -z "$PUBLISHED" ]]; then
  cat <<EOF

[publish] staged and ready. Publication is a human action - it needs Steam running under
          an account that owns NS2, and the first upload accepts the Workshop legal
          agreement. I cannot do this part.

  1. Launch  $LAUNCHPAD_WIN
     (the copy in the INSTALL ROOT - never the one in x64\\)
  2. Open this project (File -> Open Mod): $PUBLISH_PROJECT_WIN
  3. Configure -> check name/description and the tags. mod.settings says
     tag_support = "Must be run on Server", but our extension has a shared.lua, so
     clients must mount it too. Choose the server AND client option if offered.
     Do NOT press Build: builder_setup.xml has no rule for lua, so Build can clean
     output/ without repopulating it. Publish only.
  4. Publish.
  5. Then:  ./dev/publish.sh --id <PublishedFileId>

     That writes the id into mod/mod.json, where it lives forever - Valve addresses
     every subsequent update by it, so it is recorded once and never edited.

EOF
else
  echo "[publish] already published as $PUBLISHED - run ./dev/deploy.sh to install under the real id"
fi
