#!/usr/bin/env bash
# state.sh — the ledger: every path this project claims to own, versus what is on disk.
#
#   ./dev/state.sh          report; exit 1 if undeclared state is found
#
# Why: over several sessions the tooling left directories scattered across D:\games -
# an abandoned config dump holding live progression tokens, a hyphenated path the engine
# could not parse, a "test" folder that had quietly become the project's home. The human
# noticed before the tooling did, and asked "what is all this?". A rule cannot fix that;
# a ledger that fails on undeclared paths can.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=paths.sh
source "$REPO/dev/paths.sh"

fail=0

echo "[state] declared by dev/paths.sh:"
for p in "$HORDE_ROOT_WSL/server/cfg" "$HORDE_ROOT_WSL/server/mods" "$REPO_DIR"; do
  printf "  %-58s %s\n" "$p" "$([ -e "$p" ] && echo present || echo absent)"
done

echo "[state] generated, must stay gitignored:"
for p in "$OUTPUT_WSL" "$DIST_WSL"; do
  if [[ -e "$p" ]]; then
    if git -C "$REPO" check-ignore -q "$p" 2>/dev/null; then
      printf "  %-58s gitignored\n" "$p"
    else
      printf "  %-58s NOT IGNORED - generated state would be committed\n" "$p" >&2; fail=1
    fi
  fi
done

# Anything under D:\games we did not declare is reported, but it is NOT a failure: this
# box is Arian's, and a guard that blocks the loop because he downloaded a game is a guard
# that will get disabled. It fails only when the evidence says the directory is OURS -
# a marker we write, or our mod's name inside it.
echo "[state] scanning D:\\games for directories we may have created but not declared:"
DECLARED="ns2-server|steamcmd|ns2srv|horde|.stale-.*"
while IFS= read -r d; do
  name=$(basename "$d")
  if [[ "$name" =~ ^($DECLARED)$ ]]; then continue; fi
  if [[ -e "$d/.installed-id" ]] || [[ -d "$d/seedinghorde" ]] || \
     find "$d" -maxdepth 2 -iname "*seedinghorde*" -print -quit 2>/dev/null | grep -q .; then
    echo "  OURS but undeclared: $d" >&2
    echo "                     declare it in dev/paths.sh or remove it with ./dev/deploy.sh --clean" >&2
    fail=1
  else
    echo "  not ours, left alone: $name"
  fi
done < <(find /mnt/d/games -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

# horde/ itself must contain only server/ - no authored content, no exports.
echo "[state] scanning D:\\games\\horde for non-runtime directories:"
while IFS= read -r d; do
  name=$(basename "$d")
  if [[ "$name" != "server" && ! "$name" =~ ^\. ]]; then
    echo "  UNDECLARED: $d  (horde/ is runtime only; publish/ and modproject/ were removed for this reason)" >&2
    fail=1
  fi
done < <(find "$HORDE_ROOT_WSL" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

# The incident check: no dev extensions inside anyone's Workshop copy.
for ROOT in "$SERVER_SHINE_EXT" "$CLIENT_SHINE_EXT"; do
  if [[ -d "$ROOT/hordemode" || -d "$ROOT/hordetest" ]]; then
    echo "  VIOLATION: dev extensions inside a Workshop copy: $ROOT" >&2
    echo "             repair: ./dev/deploy.sh --clean" >&2
    fail=1
  fi
done
echo "[state] Workshop copies free of dev extensions"

if [[ $fail -eq 0 ]]; then
  echo "[state] ok - no undeclared or violating paths"
  exit 0
fi
echo "[state] FAIL - state on disk does not match the declared ledger" >&2
exit 1
