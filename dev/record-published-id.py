#!/usr/bin/env python3
"""record-published-id.py - store the Workshop PublishedFileId, once.

Usage: record-published-id.py <mod.json> <PublishedFileId>

Valve's ISteamUGC flow says keep the published file id forever: every later update is
addressed by it (StartItemUpdate takes the id, not the folder). So this refuses to
overwrite a value that is already set - a mistyped or wrong id would silently point all
future updates at somebody else's item, or at a deleted one.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    path, new_id = sys.argv[1], sys.argv[2]

    if not new_id.isdigit():
        print(f"[publish] --id must be numeric, got {new_id!r}")
        return 2

    with open(path, encoding="utf-8") as fh:
        m = json.load(fh)

    current = m.get("publishedFileId")
    if current not in (None, int(new_id)):
        print(f"[publish] REFUSING to change publishedFileId from {current} to {new_id}.")
        print("[publish] Valve addresses every future update by this id, so it is written")
        print("[publish] once and never edited. If it really is wrong, edit mod/mod.json by")
        print("[publish] hand and say why in the commit message.")
        return 1

    m["publishedFileId"] = int(new_id)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(m, fh, indent=2)
        fh.write("\n")

    print(f"[publish] recorded PublishedFileId {new_id} in mod/mod.json")
    print("[publish] next: ./dev/package.sh && ./dev/deploy.sh   (installs under the real id)")
    print("[publish] then the first real delivery test: does a published mod mount, and does")
    print("[publish] a vanilla client auto-download it on connect?")
    return 0


if __name__ == "__main__":
    sys.exit(main())
