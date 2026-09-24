#!/usr/bin/env python3
"""register-launchpad.py - point LaunchPad at our exported project.

LaunchPad does not discover projects from folders. It reads

    %APPDATA%\\Natural Selection 2\\Launch Pad\\options.xml

and opens whatever <recent_mod> entries list there. NS2Combat ships a .vbs that writes
into this same file, so registering is normal practice rather than a hack.

Two real bugs this fixes:

  1. Deleting a project directory without updating this file leaves a pointer to a path
     that no longer exists. LaunchPad then reports "output directory cannot be empty"
     about a project that is fine on disk - which is exactly what happened after the
     repo became the project and modproject/ was removed.

  2. Opening the WSL-resident repo gives LaunchPad a mangled path such as
     C:\\wsl.localhost\\Ubuntu\\...  (the \\\\wsl.localhost UNC prefix collapsed to a drive
     root). Every path under it is then unresolvable, so output/ really is empty to the
     tool. Hence the D:\\games\\horde\\publish export, and hence this registration.

Usage: register-launchpad.py <options.xml> <mod.settings-in-windows-form>
"""
import os
import re
import sys

WSL_PREFIX = re.compile(r"^/mnt/([a-z])/")


def to_wsl(win_path: str) -> str:
    """D:/games/x -> /mnt/d/games/x, so we can stat it from here."""
    p = win_path.replace("\\", "/")
    m = re.match(r"^([A-Za-z]):/(.*)$", p)
    if m:
        return f"/mnt/{m.group(1).lower()}/{m.group(2)}"
    return p


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    opts_path, target = sys.argv[1], sys.argv[2]

    if os.path.exists(opts_path):
        with open(opts_path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
    else:
        src = "<options>\n  <recent_mods>\n  </recent_mods>\n</options>\n"

    entries = re.findall(r"<recent_mod>([^<]*)</recent_mod>", src)

    stale = [e for e in entries if not os.path.exists(to_wsl(e))]
    for s in stale:
        print(f"[register] dropping dead LaunchPad entry: {s}")

    fresh = [e for e in entries if e not in stale and e != target]
    fresh.insert(0, target)

    lines = "\n".join(f"    <recent_mod>{e}</recent_mod>" for e in fresh)

    if "<recent_mods>" in src:
        out = re.sub(r"<recent_mods>.*?</recent_mods>",
                     lambda _m: f"<recent_mods>\n{lines}\n  </recent_mods>",
                     src, flags=re.S)
    else:
        out = src.replace("</options>",
                          f"  <recent_mods>\n{lines}\n  </recent_mods>\n</options>")

    with open(opts_path, "w", encoding="utf-8") as fh:
        fh.write(out)

    print(f"[register] LaunchPad will open: {target}")
    if os.environ.get("LAUNCHPAD_RUNNING") == "1":
        print("[register] WARNING - LaunchPad appears to be running; it rewrites this file "
              "on exit, so close it and reopen the project.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
