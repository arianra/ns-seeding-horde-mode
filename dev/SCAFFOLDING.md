# SCAFFOLDING.md — the mod, the pipeline, and how to publish

Procedure. `MODDING.md` holds the cited engine facts, `MODDING-CASES.md` the case studies,
`dev/STANDARDS.md` the ownership boundaries, `PLAN.md` the working method.

## 1. The repo IS the LaunchPad project

```
D:\projects\ns-seeding-horde-mode/
  mod.settings          LaunchPad's project file: name, source_dir, output_dir, tags
  preview.jpg           workshop tile (mod.settings: image) - NOT part of the mod
  mod/mod.json          our identity file: version (semver), mod id, publishedFileId
  source/               THE MOD. Hand-written, version-controlled, the only truth.
    lua/entry/seedinghorde.entry      filename IS the mod name; sets global modEntry
    lua/shine/extensions/hordemode/   our Shine plugin
    lua/shine/extensions/hordetest/   headless scenario harness
  output/               GENERATED copy of source/ - what LaunchPad publishes
  dist/<version>/       GENERATED archives + manifest
  dev/                  the scripts
```

`D:\games\horde\server\` holds **runtime state only** — nothing is authored there:

```
  cfg/     DEV server config (disposable; deploy.sh rebuilds it)
  mods/    DEV mod storage, isolated by -modstorage
```

The repo lives on `D:\` deliberately. It **is** the LaunchPad project, and LaunchPad is a
Windows program: when the repo was in WSL, `wslpath` resolved it to
`\\wsl.localhost\Ubuntu\...`, LaunchPad mangled that to `C:\wsl.localhost\...`, and then
truthfully reported *"output directory cannot be empty"* about a project that was fine on
disk. Measured after moving: `git commit` works, `git status` 0.21 s, `git log` 0.27 s, and
the beads/Dolt tracker runs — so there was no cost to pay, only the export layer removed.
`core.fileMode false` is required, because 9P reports every file `0777` and git would
otherwise see 48 phantom mode changes.

There is one copy of every authored file. That is the point: an earlier layout kept
`repo/source`, a build tree, a project `source/` and a project `output/` — four copies with
no answer to which was real.

Generated trees are gitignored. `dev/paths.sh` is the only place any path is defined.

## 2. The pipeline

```
edit source/
   │
   ├── ./dev/package.sh      validate → output/ (mirror of source/) → dist/<ver>/{zips,manifest}
   │
   ├── ./dev/deploy.sh       install output/ into the DEV mod storage + MapCycle + config
   │
   ├── ./dev/server-start.sh boot DEV on :27025 with -modstorage isolation
   │
   ├── ./dev/test.sh         arm hordetest, run the 45-scenario suite, stop
   │
   └── ./dev/publish.sh      refresh output/, then tell you what to click in LaunchPad
          └── after you publish:  ./dev/publish.sh --id <PublishedFileId>
```

| Script | Does | Never does |
|---|---|---|
| `paths.sh` | defines every path; validates the two hard rules | — |
| `package.sh` | validate, mirror `source/`→`output/`, zip deterministically, write manifest | transform content |
| `deploy.sh` | install the artifact into DEV, configure DEV, repair Workshop pollution | write to Steam or the live config |
| `modserver.sh` | serve the artifact over NS2's backup protocol | substitute for publication |
| `server-start.sh` | boot DEV (disarmed → joinable), wait for readiness | touch LIVE without `--live` |
| `server-stop.sh` | stop **our** PID, escalating politely | kill by process name |
| `test.sh` | arm the harness, run the suite, verify managed content untouched | — |
| `publish.sh` | build, register the repo with LaunchPad, print the human steps, record the id once | change a recorded id, or author anything |
| `new-extension.sh` | scaffold an extension with the correct vararg shapes | — |
| `lint.sh` | static Lua gate | — |

## 3. Publishing, step by step

```bash
./dev/publish.sh
```
then, in Windows:

1. Launch `C:\Program Files (x86)\Steam\steamapps\common\Natural Selection 2\LaunchPad.exe`
   — the **install-root** launcher, never the `x64` copy.
2. **Open Mod** → `D:\games\horde\publish\seedinghorde` (printed by `publish.sh`).
3. Configure → check name/description and **the tags**. `mod.settings` currently says
   `tag_support = "Must be run on Server"`, but our extension has a `shared.lua`, so clients
   must mount it too. Choose the server **and** client option if offered.
4. **Publish** (first upload accepts the Workshop legal agreement).
5. `./dev/publish.sh --id <PublishedFileId>`

**Do not press Build.** `builder_setup.xml` ships rules for `.cinematic`, `.fnt`,
`.render_setup`, `.shader_template` and `.psd` — **no rule for `lua`**. Build can therefore
clean `output/` and fail to repopulate our Lua, producing an incomplete mod. `package.sh` is
the only producer of `output/`. A project-local builder rule would make Build safe too; it
needs the rule syntax verified, so it is deliberately not guessed at.

`publishedFileId` is written **once and never edited** — Valve addresses every later update by
it, and `publish.sh --id` refuses to change a value that is already set.

## 4. Versioning

Semver in `mod/mod.json`. `0.0.1` is deliberate: nothing is confirmed working in game yet.
`dist/<version>/` holds one directory per release with a manifest recording the output hash,
the mod id, and whether the item is published.

The protocol archive is named `m<hexModId>_<workshopVersion>.zip` because that is the request
grammar NS2's backup-server protocol makes (`WorkshopBackup` `check_path`/`make_key`). Pre-
publication the engine asks for version `0`, so that is what we emit; after publication
`workshopVersion` in `mod.json` carries Steam's `time_updated`.

## 5. Creating an extension

```bash
./dev/new-extension.sh myfeature     # writes source/lua/shine/extensions/myfeature/
./dev/deploy.sh && ./dev/server-start.sh
```

### The vararg rules — the commonest way to break a plugin silently

| File | `...` is | Correct first line |
|---|---|---|
| `shared.lua` | the plugin **name** (string) | `local Plugin = Shine.Plugin( ... )` … `return Plugin` |
| flat `extensions/<name>.lua` | the **name** | same |
| `server.lua` / `client.lua` / `predict.lua` | the plugin **table** | `local Plugin = ...` |

Measured by mounting three shapes in one boot. Wrong form gives
`attempt to index local 'Plugin' (a string value)` and the plugin never registers.
A folder with only `server.lua` **is not a plugin** — it needs `shared.lua` or `client.lua`.
Extra modules are not auto-loaded: `Shine.LoadPluginFile( PluginName, "config.lua", Plugin )`.

## 6. Server-only vs client-visible

The game requires **identical network-message counts** on both sides.

| Your plugin | Vanilla clients can join |
|---|---|
| server-side only, registers nothing networked | **yes** |
| any `shared.lua` (adds a `Shine_PluginSync` field) | **no** |
| `SetupDataTable` / `AddDTVar` / `AddNetworkMessage` | **no** — one message per table plus one per key |

Restricting datatable access does not help: messages still register. So client-visible state
means the client mounts our mod — which is §3, not an optional extra.

**Declare a datatable var only if you write it**, and add a test that asserts it changes.

## 7. Verify

```bash
./dev/deploy.sh --check                                  # artifact installed, mirrors source, listed, delivery configured
grep -a "Extension 'hordemode' loaded" "$LOG"            # boot log
./dev/test.sh                                            # headless suite
```
Runtime assertion from Lua: `ModLoader.GetLoadedModNames()`, `ModLoader.GetModInfo(name)`.

**Current blocker, stated plainly:** the id is unpublished, so the engine refuses to mount it
(`Mod [999000001] wasn't available`) and `hordemode` does not load. That is the intended
consequence of removing the `-game` overlay, not a regression. "A published item mounts and
auto-downloads to a connecting client" is the pipeline's remaining unproven assumption — §6 of
`MODDING-CASES.md` records why no Workshop-free route exists.

## 8. Test-authoring rules, earned the hard way

- Exercise the **public seam**: chat commands via `Shine:RunCommand(...)`, never by calling the
  handler — Shine forwards only arguments matching a declared `AddParam`.
- Never assert against **injected** state when the claim is about real state.
- Never read state a **previous run** could have written; the engine log rotates at boot.
- A new check must be **demonstrated to fail** before it is allowed to pass.
- A scenario that mutates shared plugin state must restore it — teardown is global by design.

## 9. Never

- Write into any `workshop\content\4920\<someone else's id>` directory, on either side.
- Hand-edit anything under `D:\games` — generate it.
- Delete or truncate the shared engine log, `dumps/`, or any `%APPDATA%` file we didn't create.
- Kill processes by name, or restart the server while someone is connected.
- Press Build in LaunchPad (see §3).
- Point a dev tool at the live config, or default to it.
