#!/usr/bin/env bash
# check-env.sh — assert the tools our scripts need resolve in a NON-interactive shell.
#
#   ./dev/check-env.sh
#
# Why: a safety control silently became a no-op when it called `jq`, because jq resolves in
# an interactive login shell but not inside a script. The control read the current value,
# got nothing, compared it to "true", and never fired - so the test suite booted a server
# that immediately ran a destructive scenario while a human was connected.
#
# The general rule: any dependency a guard relies on must be proven present in the same
# environment the guard runs in, or the guard must fail loudly when it is absent. This
# script is that proof, and it is run by dev/test.sh so drift cannot go unnoticed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The environment a script actually runs in: inherited PATH, non-interactive, no rc files,
# no aliases or shell functions. NOT `env -i` with a hand-written PATH - that strips the
# Windows system paths WSL appends, and then powershell.exe "goes missing" and the check
# reports a problem that does not exist. What we are hunting is a tool that only resolves
# because an interactive shell sourced something, which is exactly how jq behaved here.
CLEAN_ENV=(env -u BASH_ENV -u ENV bash --norc --noprofile -c)

REQUIRED=(bash python3 curl grep sed awk find md5sum stat tr wc sort xargs)
OPTIONAL_BUT_ADVERTISED=()

fail=0
for tool in "${REQUIRED[@]}"; do
  if ! "${CLEAN_ENV[@]}" "command -v $tool" >/dev/null 2>&1; then
    echo "[env] FAIL - '$tool' is not resolvable in a clean non-interactive shell" >&2
    echo "[env]        a guard depending on it would silently do nothing" >&2
    fail=1
  fi
done

# Anything the scripts invoke by name from a user-owned location must be on PATH for real.
for tool in "${OPTIONAL_BUT_ADVERTISED[@]}"; do
  if ! "${CLEAN_ENV[@]}" "command -v $tool" >/dev/null 2>&1; then
    echo "[env] WARN - '$tool' missing in a clean shell" >&2
  fi
done

# The specific trap we already fell into: never let a script shell out to jq silently.
if ! "${CLEAN_ENV[@]}" "command -v jq" >/dev/null 2>&1; then
  if grep -RInq --exclude=check-env.sh '\bjq \|--jq\b\|\$(jq' "$REPO/dev" 2>/dev/null; then
    echo "[env] FAIL - a script calls jq, which does not resolve non-interactively here" >&2
    grep -RIn --exclude=check-env.sh '\$(jq\| jq ' "$REPO/dev" 2>/dev/null | head -3 | sed 's/^/        /' >&2
    fail=1
  else
    echo "[env] ok - jq absent from clean shell, and no script depends on it (python3 does the JSON)"
  fi
fi

# python3 must be able to do the things we ask of it, not merely exist.
if ! "${CLEAN_ENV[@]}" "python3 -c 'import json,hashlib,zipfile,re'" >/dev/null 2>&1; then
  echo "[env] FAIL - python3 present but required stdlib modules unavailable" >&2
  fail=1
fi

# Windows interop: the launcher drives the server through powershell.exe.
if ! "${CLEAN_ENV[@]}" "command -v powershell.exe" >/dev/null 2>&1; then
  echo "[env] FAIL - powershell.exe not resolvable; server-start/stop cannot function" >&2
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "[env] ok - ${#REQUIRED[@]} required tools resolve non-interactively"
  exit 0
fi
exit 1
