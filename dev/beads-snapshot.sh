#!/usr/bin/env bash
# beads-snapshot.sh — export the issue tracker into the repo so git holds it.
#
#   ./dev/beads-snapshot.sh
#
# Why this exists: beads keeps its issues in .beads/embeddeddolt/, which is GITIGNORED.
# So the tracker - every issue, dependency and status - lived only on one disk. When the
# repo moved from WSL to D:\, git was perfectly in sync and the tracker still was not
# anywhere off the machine. `bd export` writes JSONL (issues, labels, dependencies,
# comments), which is what we need versioned.
#
# Honest limit, from bd's own help text: this is an issue export, not a full database
# backup. It does not capture Dolt branches, commit history, working-set state, or
# non-issue tables. Those are regenerable bookkeeping; the issue graph is not.
#
# Run it after changing tracker state and commit the result with the code that caused it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/.beads/issues.jsonl"

command -v bd >/dev/null 2>&1 || {
  echo "[beads] FAIL - bd not on PATH (node bin dir must be exported)" >&2
  echo "[beads]        the tracker would otherwise be silently un-backupable" >&2
  exit 1
}

BEFORE=$([ -f "$OUT" ] && md5sum "$OUT" | cut -c1-8 || echo "none")
cd "$REPO"
bd export -o .beads/issues.jsonl 2>&1 | grep -v "permissions 0777" | tail -2

AFTER=$(md5sum "$OUT" | cut -c1-8)
COUNT=$(wc -l < "$OUT")
if [[ "$BEFORE" == "$AFTER" ]]; then
  echo "[beads] unchanged: $COUNT issues [$AFTER]"
else
  echo "[beads] updated: $COUNT issues  [$BEFORE -> $AFTER]  (commit this)"
fi
