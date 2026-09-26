#!/usr/bin/env python3
"""set-mod-delivery.py — make the config's mod-delivery claims match the bytes it can get.

    ./dev/set-mod-delivery.py <cfg-dir> <path/to/m<hex>_<ver>.zip> <published:true|false>

Why this exists. `deploy.sh` used to write `mod_backup_servers = [http://127.0.0.1:27020]` and
`mod_backup_before_steam = true` unconditionally, while the thing that has to answer that URL —
`dev/modserver.sh` — is a separate manual step nobody runs. On 2026-09-25 that combination nearly
cost a join: a 22-hour-old orphaned `http.server`, left by the repo's old WSL path and rooted in
a **deleted** directory, held port 27020 and answered 404, while `modserver.sh status` reported
"stopped" because it only ever consulted its own pidfile.

So the check is not "is the port open". An HTTP server answers 200 for whatever it happens to
have, and on 2026-09-25 the dist folder still held the pre-publication placeholder artifact, so
even a passing fetch proved nothing about WHICH bytes a client would receive. This script GETs
the exact path the engine asks for and **compares the bytes** to the artifact we just built.

Advertise a delivery path only when it verifiably serves this build; take the advertisement away
when it does not. Config must never claim a capability the machine lacks.

Exit codes:
  0  config now agrees with reality (advertised and byte-identical, or cleanly Steam-only)
  1  config unreadable, or an unpublished mod has no working backup
  2  usage
"""
import hashlib
import json
import pathlib
import sys
import urllib.error
import urllib.request

PORT = 27020  # dev/paths.sh MODSERVER_PORT; UWE's WorkshopBackup default


def fetch(url: str, seconds: float = 5.0):
    """Return (reachable, http_code, body). Never raises."""
    try:
        with urllib.request.urlopen(url, timeout=seconds) as response:
            return True, getattr(response, "status", 200), response.read()
    except urllib.error.HTTPError as err:
        return True, err.code, b""        # answered — just not with what we wanted
    except Exception:
        return False, None, b""            # nothing listening, refused, or timed out


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <cfg-dir> <artifact-path> <published:true|false>", file=sys.stderr)
        return 2

    cfg = pathlib.Path(sys.argv[1])
    artifact = pathlib.Path(sys.argv[2])
    published = {"true": True, "false": False}.get(sys.argv[3].strip().lower())

    if published is None:
        print(f"[delivery] REFUSED: published must be true|false, got {sys.argv[3]!r}", file=sys.stderr)
        return 2
    if not artifact.is_file():
        print(f"[delivery] REFUSED: artifact missing: {artifact}", file=sys.stderr)
        return 1

    want = hashlib.sha256(artifact.read_bytes()).hexdigest()
    name = artifact.name

    target = cfg / "ServerConfig.json"

    if not target.exists():
        print(f"[delivery] REFUSED: {target} missing - nothing to configure", file=sys.stderr)
        return 1

    try:
        config = json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as err:
        # Refusing beats rewriting: this file carries the server's live identity (name, port,
        # password), so rebuilding it from scratch would quietly invent all of that.
        print(f"[delivery] REFUSED: cannot parse {target}: {err}", file=sys.stderr)
        return 1

    if not isinstance(config, dict):
        print(f"[delivery] REFUSED: {target} is not a JSON object", file=sys.stderr)
        return 1

    settings = config.get("settings")

    if settings is None:
        settings = config["settings"] = {}
    if not isinstance(settings, dict):
        print(f"[delivery] REFUSED: {target} has no 'settings' object", file=sys.stderr)
        return 1

    url = f"http://127.0.0.1:{PORT}"
    servers = settings.get("mod_backup_servers")
    servers = [s for s in servers if isinstance(s, str)] if isinstance(servers, list) else []

    reachable, code, body = fetch(f"{url}/{name}")
    served = code == 200 and hashlib.sha256(body).hexdigest() == want

    if served:
        if url not in servers:
            servers.append(url)
        settings["mod_backup_servers"] = servers
        # Backup first on purpose, even once published: it guarantees the joining client gets
        # byte-for-byte the build this server runs, so a Workshop copy that lags the dev build
        # cannot turn into an unexplained version disagreement at the door.
        settings["mod_backup_before_steam"] = True
        verdict = "advertised, before Steam"
    else:
        kept = [s for s in servers if s != url]
        if kept:
            settings["mod_backup_servers"] = kept
        else:
            settings.pop("mod_backup_servers", None)
        settings["mod_backup_before_steam"] = False
        verdict = "withdrawing the advertisement; clients will use Steam"

        if not published:
            # Without Steam there is no other route: the mod simply will not mount.
            print(f"[delivery] FAIL: unpublished mod and {url}/{name} does not serve it. "
                  "Run ./dev/modserver.sh start", file=sys.stderr)
            return 1

    try:
        target.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        check = json.loads(target.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as err:
        print(f"[delivery] FAIL: could not write and re-read {target}: {err}", file=sys.stderr)
        return 1

    got = (check.get("settings") or {}).get("mod_backup_before_steam")

    if bool(got) is not served:
        print(f"[delivery] FAIL: asked before_steam={served}, the file says {got!r}", file=sys.stderr)
        return 1

    if served:
        detail = f"HTTP {code}, {len(body)} bytes identical to {name}"
    elif reachable:
        detail = f"HTTP {code}, {(len(body) if code == 200 else 0)} usable bytes - not this artifact"
    else:
        detail = "no listener"

    print(f"[delivery] {url}/{name}: {detail} -> {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
