# SCAFFOLDING.md — creating and packaging this mod

Procedure, not theory. `MODDING.md` holds the cited facts, `MODDING-CASES.md` the case studies,
`dev/STANDARDS.md` the ownership boundaries, `PLAN.md` the working method.

Every path here comes from **`dev/paths.sh`** — the only place a location is defined. If a
script hard-codes a path, that is a defect.

---

## 1. Layout and ownership

| Path | What it is | Owner |
|---|---|---|
| `source/lua/shine/extensions/<name>/` | extension source — the truth | repo |
| `mod/mod.json` | identity: name, semver version, mod id, entry priority | repo |
| `D:\games\horde\dist\<version>\mod\` | built mod tree (what gets zipped) | generated |
| `D:\games\horde\dist\<version>\artifacts\` | `<name>-<version>.zip`, `m<hex>_<ver>.zip`, `manifest.json` | generated |
| `D:\games\horde\modproject\seedinghorde\` | LaunchPad project — the publication vehicle | permanent |
| `D:\games\horde\server\cfg\` | DEV server config (Shine state lives under here) | disposable |
| `D:\games\horde\server\mods\` | DEV mod storage, isolated by `-modstorage` | disposable |
| `D:\games\ns2srv\cfg\` | **LIVE server config** | **Arian — never written** |
| `D:\games\ns2-server\` | engine + dedicated server | steamcmd |
| `...\steamapps\workshop\content\4920\117887554\` | Shine's client copy | **never written** |
| `%APPDATA%\Natural Selection 2\workshop\...` | Shine's server copy (default mod store) | **never written** |

Two constraints `paths_validate` enforces: no hyphens in any path we pass to the engine (its
argument parser breaks on `-`), and no project write path inside `steamapps`.

---

## 2. The pipeline

```
source/ ──dev/package.sh──► dist/<version>/{mod,artifacts}
                                 │
                     dev/deploy.sh (installs the ARTIFACT, verifies install==artifact)
                                 │
              D:\games\horde\server\mods\content\4920\<modId>\
                                 │
   dev/modserver.sh (backup protocol) ── or ── published Workshop item
                                 │
                    dev/server-start.sh  →  DEV server on :27025
                                 │
                        client connects → auto-downloads the mod
```

```bash
./dev/package.sh            # build the artifact only
./dev/deploy.sh             # package + install + configure the DEV server
./dev/modserver.sh start    # serve the artifact over NS2's backup protocol
./dev/server-start.sh       # boot DEV (hordetest disarmed → joinable server)
./dev/server-stop.sh        # PID-scoped; never kill by process name
./dev/deploy.sh --check     # verify state without writing (exit 1 = unsafe)
./dev/deploy.sh --clean     # uninstall + repair any Workshop copy we polluted
./dev/test.sh               # arm hordetest, boot, run the suite, stop
```

**`package.sh` is the only producer of mod files.** It is deterministic — fixed zip timestamps,
sorted members — so a rebuild cannot silently change bytes. `deploy.sh` installs the artifact and
verifies the installed tree hashes to the artifact, **not** to `source/`: an install that drifted
from the build is a failure, not a detail.

### Identity

`mod/mod.json` holds `name`, semver `version`, `modId` (placeholder until published) and
`publishedFileId` (null until published). After the first publish the real id goes in and is
**never changed** — Valve's ISteamUGC flow addresses every future update by it. Version is
`0.0.1` deliberately: nothing here is confirmed working in game yet.

---

## 3. What the artifact contains

```
lua/entry/seedinghorde.entry        generated; sets global modEntry with Priority
lua/shine/extensions/hordemode/...  from source/
lua/shine/extensions/hordetest/...  from source/ (excluded with --no-test-ext)
preview.jpg                         optional 512x512 workshop tile
```

The entry file **is** required for a real mod: its filename becomes the mod name
(`ModLoader.lua:227-229`) and it is what makes the folder a mod to the loader. It declares no
`Client`/`Server`/`Shared` scripts — Shine is the host and loads our extensions through its own
merged-VFS scan. `Priority` is declared because it governs load order against Shine (50);
**higher loads first** (`ModLoader.lua:236-242`).

`game_setup.xml` is deliberately absent: it re-routes the Client/Server VM entry points for the
whole game. We are not replacing the game.

---

## 4. Creating an extension

```bash
./dev/new-extension.sh myfeature        # emits the correct file shapes
./dev/deploy.sh && ./dev/server-start.sh
```

### The vararg rules — the most common way to break a plugin silently

| File | `...` is | Correct first line |
|---|---|---|
| `shared.lua` | the plugin **name** (string) | `local Plugin = Shine.Plugin( ... )` |
| flat `extensions/<name>.lua` | the **name** | `local Plugin = Shine.Plugin( ... )` |
| `server.lua` / `client.lua` / `predict.lua` | the plugin **table** | `local Plugin = ...` |

Measured by mounting three shapes in one boot. Get it wrong and you get
`attempt to index local 'Plugin' (a string value)` at load, and the plugin never registers.
Also: **a folder with only `server.lua` is not a plugin** — it needs `shared.lua` or
`client.lua`. And `return Plugin` from `shared.lua` is what registers it.

Extra modules are not auto-loaded; pull them in explicitly:
`Shine.LoadPluginFile( PluginName, "config.lua", Plugin )`.

---

## 5. Server-only vs client-visible — decide deliberately

The game requires **identical network-message counts** on client and server.

| Your plugin does | Vanilla clients can join |
|---|---|
| server-side logic only, registers nothing networked | **yes** |
| has any `shared.lua` (adds a `Shine_PluginSync` field) | **no** |
| `SetupDataTable` / `AddDTVar` / `AddNetworkMessage` | **no** — one message per table plus one per key |

Restricting datatable access does not help: the messages still register, access only gates who
receives values. So client-visible state means the client must mount our mod — which is the
delivery path in §2, not an optional extra.

**Declare a datatable var only if you write it.** `hordemode` shipped five declared vars that
nothing ever assigned: the client had a contract and no data. If a field exists in
`SetupDataTable`, a test must assert it changes.

---

## 6. Verify

```bash
./dev/deploy.sh --check                       # artifact installed, matches build, MapCycle lists it
grep -a "Extension 'hordemode' loaded" "$LOG" # boot log marker
./dev/test.sh                                 # full headless suite
```

Runtime assertions available from Lua: `ModLoader.GetLoadedModNames()` and
`ModLoader.GetModInfo(name)`.

**Delivery caveat, stated plainly:** an unpublished mod id will not mount — the engine checks a
mod whitelist and reports `is not whitelisted` even when a protocol-correct backup server is
serving the artifact (measured 2026-09-23, `MODDING-CASES.md` §6). Publication is mandatory, and
"published item mounts and auto-downloads to a client" is the pipeline's remaining unproven
assumption.

---

## 7. Test-authoring rules, earned the hard way

- Assert **routing and behaviour through the public seam**. A chat command is exercised with
  `Shine:RunCommand(client, "sh_horde", true, "status")`, never by calling the handler — the
  handler-level test passed while the feature was dead, because Shine forwards only arguments
  matching a declared `AddParam`.
- Never assert against **injected** state when the claim is about real state. The status
  scenarios supplied their own machine and could not see that the live machine's fields were
  never written.
- Never let a check read state a **previous run** could have written. The engine log rotates at
  boot; byte-offset fences break and a plain occurrence count reads `1 before, 1 after`.
- A new check must be **demonstrated to fail** before it is allowed to pass.
- A scenario that mutates shared plugin state must swap it back — teardown is global by design,
  so a caller must own the state it covers.

---

## 8. Never do these

- Write into any `workshop\content\4920\<someone else's id>` directory, on either side.
- Hand-edit anything under `D:\games` — generate it with the scripts.
- Delete or truncate the shared engine log, `dumps/`, or any `%APPDATA%` file we did not create.
- Kill processes by name, or restart the server while someone is connected.
- Point a dev tool at the live config, or default to it.
- Ship a client-visible feature before the delivery path is proven.
