#!/usr/bin/env python3
"""prune-mapcycle.py - remove a retired mod id from a MapCycle.json mods list.

Usage: prune-mapcycle.py <MapCycle.json> <hex-id> <decimal-id>

Ids may appear in either form (the engine accepts a string of >=7 chars or a number), so
both are checked. Prints what it removed so the caller's log stays honest about config
edits.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2

    path, hex_id, dec = sys.argv[1:4]
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)

    mods = d.get("mods", [])
    kept = [m for m in mods if str(m) not in (hex_id, dec)]

    if kept == mods:
        print(f"[deploy] MapCycle mods did not list {hex_id}")
        return 0

    d["mods"] = kept
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=2)
        fh.write("\n")
    print(f"[deploy] retired {hex_id} from dev MapCycle mods; remaining: {kept}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
