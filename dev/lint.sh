#!/usr/bin/env bash
# lint.sh — static gate for the mod's Lua (bead i0e).
#
# luacheck is not reachable on this box: there is no lua/luarocks/cargo, apt needs
# a password, and shipping a Lua runtime to host a linter is more moving parts
# than the check is worth. So the gate runs on Lua 5.1 *grammar* through
# luaparser (same tool used for the syntax spikes), which catches the class of
# error that costs a 2-minute server boot to discover.
#
# Usage: ./dev/lint.sh            lint source/
#        ./dev/lint.sh --strict   also treat warnings as failure
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

if ! command -v uv >/dev/null 2>&1; then
  echo "[lint] uv not found — install uv, or run: pip install luaparser && python3 dev/lint.py" >&2
  exit 2
fi

# --no-progress keeps CI-ish output clean; --quiet suppresses resolver noise only.
uv run --quiet --with luaparser python3 "$REPO/dev/lint.py"
RC=$?

if [[ $STRICT -eq 1 && $RC -eq 0 ]]; then
  # Re-run to count warnings; --strict promotes them to failures.
  WARNINGS=$(uv run --quiet --with luaparser python3 "$REPO/dev/lint.py" 2>/dev/null | grep -c '^\[lint\] warn' || true)
  if [[ "${WARNINGS:-0}" -gt 0 ]]; then
    echo "[lint] --strict: $WARNINGS warning(s) treated as failure" >&2
    exit 1
  fi
fi

exit $RC
