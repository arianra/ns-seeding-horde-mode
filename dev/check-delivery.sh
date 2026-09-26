#!/usr/bin/env bash
# check-delivery.sh — make a server config's mod-delivery claims match what answers right now.
#
#   ./dev/check-delivery.sh <cfg-dir>
#
# One owner for one decision, called by dev/deploy.sh and dev/server-start.sh. The reason it is
# shared: the backup mod server is started by hand (`dev/modserver.sh start`), so "is it serving
# the current artifact" can change between a deploy and the boot that follows it. A check that
# only ran at deploy time would be a snapshot of the past, which is exactly how the config ended
# up advertising a URL that answered 404 for 22 hours (see dev/set-mod-delivery.py).
#
# Exit 0 when the config is consistent (advertised and live, or cleanly Steam-only).
# Exit 1 when an unpublished mod has no working backup - nothing else can deliver it.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=paths.sh
source "$REPO_DIR/dev/paths.sh"
paths_validate || exit 3

CFG="${1:-}"
[[ -n "$CFG" && -d "$CFG" ]] || { echo "[delivery] usage: check-delivery.sh <cfg-dir>" >&2; exit 2; }

VERSION=$(python3 -c "import json;print(json.load(open('$REPO_DIR/mod/mod.json'))['version'])")
PUBLISHED=$(python3 -c "import json;print('true' if json.load(open('$REPO_DIR/mod/mod.json')).get('publishedFileId') else 'false')")
DIST="$(dist_dir_for "$VERSION")"

# The name is derived, never guessed: on 2026-09-25 the dist directory still held the
# pre-publication placeholder artifact, and "first match" advertised a 200 for that instead of
# the file the joining engine will actually request.
ARTIFACT=$(mod_archive_name) || { echo "[delivery] cannot derive the artifact name from mod.json" >&2; exit 1; }

if [[ -z "$ARTIFACT" || ! -f "$DIST/$ARTIFACT" ]]; then
  echo "[delivery] no $ARTIFACT in $DIST - run ./dev/package.sh first" >&2
  exit 1
fi

python3 "$REPO_DIR/dev/set-mod-delivery.py" "$CFG" "$DIST/$ARTIFACT" "$PUBLISHED"
