#!/usr/bin/env python3
"""set-reveal.py — write Debug.RevealMouths into a server's HordeMode.json.

    ./dev/set-reveal.py <cfg-dir> <true|false>

Why a script and not a `jq` line in server-start.sh: `jq` resolves in an interactive
shell here and fails inside a script, and a command substitution that silently produced
"" once made a disarm never run (dev/check-env.sh records that trap). python3 is already
what test.sh uses for exactly this reason.

Why the value is written UNCONDITIONALLY, both ways: "only write it when it should be on"
leaves a previous boot's setting in place, which is how a debug marker survives into a run
that was supposed to be clean. Whatever we ask for is what the file says afterwards, and the
script exits non-zero if it cannot make that true — a silent no-op here would read as
"reveal is off" while the markers were still on the map. The value is re-read from disk
before we claim success.

The file may not exist yet: Shine writes it on first boot from the extension's defaults.
Creating a minimal one is correct then — the extension merges its own defaults around it.
"""
import json
import pathlib
import sys

YES = {"true", "1", "yes", "on"}
NO = {"false", "0", "no", "off"}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: set-reveal.py <cfg-dir> <true|false>", file=sys.stderr)
        return 2

    cfg = pathlib.Path(sys.argv[1])
    raw = sys.argv[2].strip().lower()

    if raw in YES:
        want = True
    elif raw in NO:
        want = False
    else:
        print(f"[reveal] REFUSED: not a boolean: {sys.argv[2]!r}", file=sys.stderr)
        return 2

    if not cfg.is_dir():
        print(f"[reveal] REFUSED: config dir missing: {cfg}", file=sys.stderr)
        return 1

    target = cfg / "shine" / "plugins" / "HordeMode.json"
    config = {}
    existed = target.exists()

    if existed:
        try:
            config = json.loads(target.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as err:
            # Refusing is right here. Overwriting an unreadable config with a two-key
            # file would quietly delete whatever balance numbers it held.
            print(f"[reveal] REFUSED: cannot parse {target}: {err}", file=sys.stderr)
            return 1

        if not isinstance(config, dict):
            print(f"[reveal] REFUSED: {target} is not a JSON object", file=sys.stderr)
            return 1

    debug = config.get("Debug")

    if not isinstance(debug, dict):
        debug = {}

    debug["RevealMouths"] = want
    config["Debug"] = debug

    target.parent.mkdir(parents=True, exist_ok=True)
    # 4-space indent + trailing newline: this file is hand-edited, and a rewrite that
    # reformats the whole thing buries the one line anyone was looking for in a diff.
    target.write_text(json.dumps(config, indent=4) + "\n", encoding="utf-8")

    try:
        check = json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as err:
        print(f"[reveal] FAIL: wrote {target} but cannot re-read it: {err}", file=sys.stderr)
        return 1

    got = (check.get("Debug") or {}).get("RevealMouths") if isinstance(check, dict) else None

    if got is not want:
        print(f"[reveal] FAIL: asked for {want}, the file says {got!r}", file=sys.stderr)
        return 1

    kept = len([key for key in check if key != "Debug"])
    where = "created" if not existed else f"{kept} other section(s) kept"
    print(f"[reveal] Debug.RevealMouths = {str(want).lower()} in {target.name} ({where})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
