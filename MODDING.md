# MODDING.md — how we build, mount, ship, and run this mod

Status: **proposal.** §1 facts are cited; §8 lists the decisions needed from Arian.
Full research evidence: `/tmp/ns2-research/T1..T4-*.md` (promote to
`Atlas/Projects/ns2-tower-defense/research/` once §8 is settled).

Written 2026-09-22 after the incident where dev files were mirrored into the client's
Steam-managed copy of Shine and broke joins to every server. Read `dev/STANDARDS.md` first;
this document is the workflow that standard implies.

---

## 1. Facts, with sources

### Mod structure

| # | Fact | Source |
|---|---|---|
| 1 | A mod is a **plain overlay directory**. The only registration is `lua/entry/<name>.entry`, and the entry **file name is the mod name**. There is no `info.txt`/manifest | `ns2/lua/entry/readme.txt` (shipped); all three mounted mods have exactly one `.entry` and no manifest |
| 2 | Entry format: the file is **executed as Lua** and must set a global `modEntry` table `{ Client=…, Server=…, Predict=…, Shared=…, FileHooks=…, Priority=… }`. A comma/colon string form is supported only as a legacy fallback (`type(modEntry)=="table" and modEntry or ParseEntryFile(modEntry)`). Load order: ModLoader first in every VM except GUIView; `FileHooks` immediately after ModLoader; `Shared` before Client/Server/Predict | `core/lua/ModLoader.lua:215-232`; `ns2/lua/entry/readme.txt`; real examples `shine.entry` (FileHooks+Priority 50), `NSLBadges` entry (Priority 999) |
| 2b | **Mod name = the entry filename minus `.entry`**, set as `parsedEntry.ModName` | `ModLoader.lua:227-229` |
| 2c | **Priority sort is `priority1 > priority2`, i.e. HIGHER loads FIRST**; absent priority defaults to 10. Shine is 50, NSL Badges 999. So to load **after** Shine we need a value **below 50** | `ModLoader.lua:236-242` |
| 3 | Mod id = the workshop **folder name** (decimal published-file id); hex forms in logs are the same number base-16: `117887554 = 0x706d242` | arithmetic + `ns2/lua/ServerWebInterface.lua:141-165` (`ModsIdsToHex`/`ModIdsFromHex`) |
| 4 | Loader discovers mods by union glob over the mounted FS | `core/lua/ModLoader.lua:196` |

### Shine plugin discovery — the fact our architecture rests on

| # | Fact | Source |
|---|---|---|
| 5 | Shine scans the **merged virtual filesystem** at the fixed prefix `lua/shine/extensions/*.lua` (recursive) — *not* a Shine-relative path. So a **second mod alongside Shine contributes plugins**, exactly as its docs say | `shine/core/shared/extensions.lua:36-46`; engine proof of union-glob `ns2/lua/Badges_Shared.lua:294`; Shine's mod-scoped call at `extensions.lua:1013` exists only to flag "official" plugins |
| 6 | Plugin names must be **one path level deep** and must not collide with another mod's. **No hot-load**: adding/renaming an extension needs a restart | `extensions.lua:36-46`, `829-834` |
| 7 | There is **no** way to load plugin Lua from outside a mounted mod: no `-extra_plugin_dir`; `ExtensionDir` is the plugin **config** dir and is hard-forced to start with `config://`; `WebConfigs`/users are JSON-data-only | `shine/core/server/config.lua:26,126-136,189-192`; `base_plugin/config.lua:92-127` |
| 8 | Base-config precedence is a first-wins chain: `BaseConfig_<gamemode>.json` → `BaseConfig.json` → `Shine_BaseConfig_<gamemode>.json` → `Shine_BaseConfig.json`; gamemode = `<name>` in `game_setup.xml` | `config.lua:104-112,253-276`; `shine/lib/game.lua:11-25` |

### The vanilla-client constraint (this is why the old approach could never work)

| # | Fact | Source |
|---|---|---|
| 9 | The game requires **identical network-message counts** on client and server | `shine/lib/datatables.lua:17-21` |
| 10 | A datatable registers **1 message for the table + 1 per key**, on each VM; and *any* plugin folder with `shared.lua` adds a field to `Shine_PluginSync` | `datatables.lua:182-194`; `extensions.lua:846,988-994` |
| 11 | **Therefore a plugin with `shared.lua`/datatables can never be server-only.** Only a plugin whose files register nothing networked is skipped on the client and thus vanilla-safe | `extensions.lua:868-871` |
| 12 | Restricting datatable access does **not** help — messages still register; access only gates who receives values | `datatables.lua:130-141` |
| 13 | Our plugin is in that class today: `shared.lua:41-46` registers `HordePhase`, `HordeWave`, `HordeIntermissionEndsAt`, `HordeMouthsActive`, `HordeMouthsTotal` | repo `source/lua/shine/extensions/hordemode/shared.lua` |

### Mounting and running

| # | Fact | Source |
|---|---|---|
| 14 | **`-game <path>` + `-hotload` is UWE's documented local playtest path.** Both binaries carry the tokens. Two machines playtest by running the **identical** `-game` overlay — zero writes under `steamapps/**` | UWE "Time to make the mods" tutorial; `game`/`hotload` tokens in `x64/NS2.exe` (verified on this box) |
| 15 | Server mod storage defaults to `%APPDATA%\Natural Selection 2\workshop\` and **ignores `-config_path`**; override with `-modstorage`. It is scanned by directory, so a hand-placed folder with an `.entry` is discovered | boot log `Passed '…/workshop/' as mod-storage directory`; `Server.exe` cmdline token table (`modstorage`, `mods`, `mods2`, `game`, `hotload`, `config_path`) |
| 16 | Client `localmods/` exists but its `mods.json` lives **inside the game install** (`steamapps/common/**`) → managed-content write, **ruled out** by `dev/STANDARDS.md`. `thunderdome/` has no `.entry` and is absent from `mods.json` | directory listing + `localmods/mods.json` |
| 17 | `-config_path` must be hyphen-free because the parser's token break-set is `-+;`, which truncates the value mid-path | `libSpark_Core.so` `GetToken`/`Parse` (binary-proven) |
| 18 | Game port default is **27015** (constant `0x6987` in `ServerGame::GetDefaultServerPort`), exclusive — a second instance logs `Error binding server to :27015`. A second port (27016) also opens; **allocate P and P+1 per instance**. NS2 has **no RCON** | `log-Server-2.txt:8-9`; binary strings; `Spark_Network.dll` `AuthPort/ServerPort/QueryPort` |
| 19 | Web admin is Mongoose-based and **off unless `-webadmin`**; then `webport`/`webuser`/`webpassword`/`webtoken`/`webreqip` apply. Its handler runs console commands (`Shared.ConsoleCommand(actions.rcon)`) | `ns2/lua/ServerWebInterface.lua:278-280`; switch table |
| 20 | Boot auto-creates 7 JSONs + `shine/` in `config://`. `ProgressionConfig.json` is created by the **auto-mounted UWE Hotfix 344 mod**, not the engine | `ServerConfig.lua:65,90-95,276-282`; `core/lua/MapCycle.lua:39`; `ConfigFileUtility.lua:69-101` |
| 21 | Every map change runs a Steam UGC update pass against a UWE **whitelist of 114 hotfix mods**, with join lockdown while installing. `workshopupdater` is a Shine extension (default **off**) that polls published-file details every 60 s and map-cycles to force re-download | boot log lines 23-58; Shine `Workshop-Updater.md` |
| 22 | Windows→server packets arrive source-NATed as `172.30.128.1` (WSL/Hyper-V), so per-IP logic sees the gateway, not the client | boot log join lines |
| 22b | **The shared engine log is rotated at boot, not appended to**: a successful boot replaced a 10873-byte file with a 7295-byte one. Byte-offset fencing breaks on this (offset points past the end of the new file) and a plain occurrence count breaks too (1 before, 1 after). Readiness now accepts *either* a count increase *or* a size shrink with ≥1 occurrence | measured 2026-09-22; `dev/server-start.sh:log_state` |

### Publishing

| # | Fact | Source |
|---|---|---|
| 23 | **First-party publisher is on this box: `x64/LaunchPad.exe` (4.6 MB).** The 81 KB `LaunchPad.exe` at install root is a stub. It contains `ModPublisher::PublishMod`, "Publish changes to Steam", preview/progress stages, "Cannot publish, not connected to Steam" | binary strings; UWE tutorial flow New → Builder → Configure → Launch Game → Publish |
| 24 | Any Steam account **owning NS2** may publish; no partner account. First upload must accept the Workshop legal agreement | Valve workshop docs + FAQ |
| 25 | Visibility has 4 states: Public, **FriendsOnly** (tester must be a friend), **Private** (creator only — *not* two-person testable), **Unlisted** (link-shareable, absent from queries → best low-exposure shared state). Whether LaunchPad exposes Unlisted is UNVERIFIED | Valve `ERemoteStoragePublishedFileVisibility`; UWE tutorial endorses FriendsOnly/Private while testing |
| 26 | Cycle: `CreateItem(4920,…)` → **store `PublishedFileId` forever** → `StartItemUpdate` → `SetItemContent(folder)` → `SubmitItemUpdate` (uncancellable). Item content is replaced wholesale per update | Valve ISteamUGC docs |
| 27 | A connecting client **auto-downloads the Workshop mods the server is running** | `Dedicated_Server_Usage.txt:180-181` |
| 28 | Anonymous game servers can pull **public** items (confirmed in our own `logs/workshop_log.txt`, 2-12 s). Server auto-download of Private/FriendsOnly items: **UNVERIFIED** | Valve `DownloadItem`; observed logs |
| 29 | Iteration latency is real: UWE's bundled `WorkshopBackup` README reports Steam content failures ~1-in-4 normally, ~9-in-10 during sales, and servers lagging a just-uploaded version | `utils/WorkshopBackup/README.md` |

---

## 2. The architecture

**Our plugins live in our own mod. The dev loop mounts that mod with `-game` overlays; the
Workshop item exists only for shipping and for remote testers.**

```
mod/
  lua/
    entry/horde.entry            # modEntry = { Shared = "lua/horde_shared.lua", Priority = <TBD> }
    shine/extensions/
      hordemode/{shared,server,config,statemachine,registry,takeover,placement,
                 spawner,waves,triggers,economy,hud}.lua
      hordetest/{shared,server,scenarios}.lua      # see §8 decision 6
dev/
  build.sh                       # source/ -> build/mod/  (deterministic)
  overlay/                       # -game overlay tree: build/mod mounted here, machine-local
```

Why this shape and not the old one:

- Fact 5 says Shine will find our extensions in a second mod. Fact 7 says there is **no other**
  way to get Lua into the VM. So a second mod is mandatory, not stylistic.
- Facts 9-13 say our plugin can never be server-only. So **the client must mount it too** —
  which the old approach could only achieve by editing managed content. `-game` (fact 14)
  achieves it for both sides without touching anything owned.
- Publishing stops being a dev-loop dependency (fact 29), so Steam latency and the 114-mod
  hotfix pass (fact 21) are no longer in our iteration path.

**Priority is settled from source** (`ModLoader.lua:236-242`, fact 2c): higher loads first, so our
entry uses **`Priority = 40`** to load after Shine's 50.

**This risk is retired — see §2b.** The worry was that a `-game` overlay's non-entry files might
not be visible to Shine's `lua/shine/extensions/*.lua` glob, or not in time. Measured: they are.
Entry *discovery* was already proven from source (`ModLoader.lua:215-218` globs
`lua/entry/*.entry` over the merged FS, and the server install ships the same ModLoader).

---

## 2b. G1 result — packaging and mounting are proven on this machine

Ran the experiment directly against `Server.exe` (no tooling changes), with the workshop copy
verified **clean (0 dev dirs)** and the files present only in the overlay:

```
D:\games\ns2-server\x64\Server.exe -config_path D:\games\ns2hordetest\cfg -port 27025
    -limit 16 -game D:\games\ns2hordetest\overlay +map ns2_summit

[19:36:17]- Extension 'hordemode' loaded.
[19:36:17]- Extension 'hordetest' loaded.
[TEST] suite not authorised for this config (RunSuite=false) - hordetest idling
```

**`-game <absolute path>` mounts on the dedicated server, and Shine's merged-VFS glob finds
extensions inside it.** No Workshop item, no subscription, no managed-content write. The whole
dev loop can run out of a directory we own.

The experiment also settled the plugin-shape rules, because three deliberately different probe
shapes were mounted in one boot:

| Shape placed in the overlay | Outcome | Rule |
|---|---|---|
| `hordemode/` (`shared.lua` + `server.lua`) | **loaded** | the working shape |
| `hordehello/server.lua` only | not loaded, no error | a folder with no `shared.lua`/`client.lua` is **not a plugin** |
| `hordehello2/shared.lua` doing `local Plugin = ...` | `Plugin loading error: attempt to index local 'Plugin' (a string value)` | in `shared.lua` the vararg is the **name string** |
| `hordehello3.lua` (flat file, same mistake) | same error, but **discovered** (`ServerFile = …/hordehello3.lua`) | flat server-only files work, and still take the name |

So the canonical scaffolding is:

```lua
-- lua/shine/extensions/<name>/shared.lua   -> receives the NAME
local Plugin = Shine.Plugin( ... )
Plugin.Version = "0.1"
return Plugin

-- lua/shine/extensions/<name>/server.lua   -> receives the TABLE
local Plugin = ...
```

**Our repo already follows this** (`hordemode/shared.lua:18` `Shine.Plugin( ... )`, `:49`
`return Plugin`; `hordemode/server.lua:22` `local Plugin = ...`). The i0a scaffold was right; it
is now confirmed by experiment instead of by reading.

Two caveats carried forward:
- **Precedence is untested.** With the same extension present in both an overlay and a workshop
  copy, which one wins has not been measured. Until P2 removes the workshop copy from the loop,
  the overlay must be kept empty or the experiment is ambiguous.
- **Client side is not yet proven.** `-game` on `NS2.exe` is documented (UWE + wiki) and the
  tokens are in the binary, but we have not booted a client with an overlay. That is G1c.

## 3. Server standard (two instances, one box)

| | **LIVE** (Arian's) | **DEV** (ours) |
|---|---|---|
| config dir | `D:\games\ns2srv\cfg` | `D:\games\ns2hordetest\cfg` |
| ports | 27015 + 27016 | **27025 + 27026** (paired, fact 18) |
| mod storage | engine default `%APPDATA%\…\workshop` | `-modstorage D:\games\ns2hordetest\mods` |
| `-game` overlay | none | `dev/overlay/` with our built mod |
| ownership | user; **agents read-only** | agent-owned, disposable |
| pidfile | — | per-instance, under `dev/` |
| web admin | never enabled without your decision | optional, G2 only |

Shared today regardless of config dir (fact 15 + observed): engine log, `dumps/`, and **the mod
store**. That last one is the sharpest edge: while DEV and LIVE share `%APPDATA%\…\workshop`,
a dev edit inside Shine's copy is a file the **live** server will mount. Isolating DEV's
mod storage is therefore not tidiness, it is the containment for the exact incident we had.

Fixes required, in priority order:

1. **S1 — `server-start.sh:10` defaults to the LIVE config dir.** A bare invocation restarts
   your server. Invert: default DEV, require `--live`, and refuse any `-config_path` outside an
   allow-list.
2. **S2 — isolate DEV mod storage** with `-modstorage` (switch is parse-verified; a boot proving
   it takes effect is still outstanding — call it **G1d**).
3. **S3 — paired ports** so both instances can run at once; document the Windows Defender UDP
   allow needed for each.
4. **S4 — instance identity in logs.** Engine log and dumps are shared; the runner already
   fences by byte offset post-boot, and `-instance_id` should be added for legibility.
5. **S5 — stop stays PID-scoped** (`taskkill` → `Stop-Process` → `-Force` last).

### Versioned vs machine-local

| Kind | Files | In repo? |
|---|---|---|
| Templates | `ServerConfig.json`, `MapCycle.json`, `shine/BaseConfig.json`, `shine/plugins/HordeMode.json` | **yes** (`dev/horde-test-cfg/`) |
| Secrets | `ProgressionConfig.json` (access/refresh tokens), `RemoteStats.json` (endpoint auth token) | **never** |
| PII | `shine/logs/*`, `ReservedSlotsConfig.json`, `ServerAdmin.json`, `shine/UserConfig.json`, `BannedPlayers.json` | never — templates only |
| Runtime | logs, `dumps/`, `build/`, `dev/overlay/`, pidfiles | never (gitignore) |

`steamcmd` update policy: `D:\games\steamcmd` already has an `install_ns2.txt` runscript
(`login anonymous` / `force_install_dir D:\games\ns2-server` / `app_update 4940 validate`).
A depot re-apply touches only `ns2-server\**` — never cfg dirs, never the `%APPDATA%` mod
copies, never the repo. DEV may be updated anytime; **LIVE only with your consent, while empty.**

---

## 4. Possible fix for the crash-on-stop

Every stop of a busy server currently makes NS2's crash handler write a ~60 MB minidump
(the server requests it itself: `Client requested dump: <pid>`), and `upload-dumps` was set
false so reports no longer leave the machine. Facts 18-19 say there is **no RCON**, but the web
interface runs console commands when `-webadmin` is on. **G2**: enable it on DEV, enumerate
actions, attempt a graceful exit. Success means clean stops; failure is also a usable answer,
written down once instead of re-litigated. Never enabled on LIVE without you deciding.

---

## 5. Publishing (later, not first)

1. One item, ours: "Seeding Horde Mode (dev)". Store `PublishedFileId` in `mod/publish.json`
   **in the repo** — an identifier, not a secret; Valve says keep it forever.
2. Visibility: **FriendsOnly** during playtesting (or Unlisted if LaunchPad offers it);
   Public only at sign-off; Private is a takedown state, not a testing state (fact 25).
3. Publisher: `x64/LaunchPad.exe`. Requires Steam running under an account that owns NS2, and
   the Workshop legal agreement accepted once.
4. Do not depend on Workshop for iteration (fact 29). It is for distribution.
5. **Radioactive, per `dev/STANDARDS.md`:** every mounted workshop dir — under `steamapps` *and*
   under `%APPDATA%\…\workshop\content` — and every PublishedFileId we do not own. Mount
   precedence makes a doctored local copy authoritative while every server runs canonical
   content, which is exactly how the Shine incident broke joins everywhere.

---

## 6. Migration plan

| Step | Work | Acceptance (observable, before the next step) |
|---|---|---|
| ~~**G1**~~ **PASSED 2026-09-22** | `-game` overlay mounts on the dedicated server and Shine discovers extensions inside it | §2b: `Extension 'hordemode' loaded` with the workshop copy verified clean; plugin-shape rules settled |
| **G1b** | Same overlay, but the extension registers a datatable | **expected to fail vanilla joins** — proves facts 9-13 empirically and measures what "client must mount our mod" costs |
| **G2** | `-webadmin` on DEV: enumerate actions, attempt graceful shutdown | clean exit with **0** new `dumplog.txt` entries, or a written "no graceful path" verdict |
| ~~**P1**~~ **DONE** | `dev/build.sh` assembles the overlay from `source/`, rebuilt from empty each run so a renamed-away extension cannot survive and make the suite pass against dead code. No `.entry`, no `game_setup.xml` — §2b shows neither is needed and both change engine behaviour we don't own. It also **fails if dev extensions exist in any workshop copy**, because mount precedence is unmeasured and ambiguity would make a green run meaningless. | verified: `overlay matches repo [291f5a02], 15 files` |
| **P2** | Rewrite `deploy.sh`: delete **every** write into any workshop `content/4920/<foreign-id>` dir; deploy = build + stage into `dev/overlay/`; keep `--clean` as the repair path for the Steam copy | `grep -rn "117887554" dev/*.sh` → nothing; suite green; `--check` pristine |
| **P3** | Server standard S1-S5 (default DEV, `--live` opt-in, paired ports, isolated `-modstorage`, per-instance pidfile) | bare `./dev/server-start.sh` provably cannot touch LIVE |
| **P4** | Config templates split DEV/LIVE + read-only `dev/config-check.sh` reporting LIVE drift | drift report produced; nothing written |
| **P5** | Bead + doc reconciliation (§7) | `bd ready` matches reality; `WORKFLOW.md:66` no longer names a forbidden target |
| **P6** | Real mod: move `hordemode`/`hordetest` into `mod/`, mount via overlay, re-run the 45-scenario suite | suite green from the overlay, not from Shine's dir |
| **P7** | Publishing via LaunchPad, FriendsOnly; your client subscribes/auto-downloads | you join DEV **and** still join a public server afterwards |

**G1 is load-bearing for everything.** If `-game` does not mount on the dedicated server, the
fallback is `-modstorage` + a hand-placed folder (fact 15), and if that also fails, publishing
becomes the dev path and iteration inherits Steam's latency (fact 29).

---

## 7. Drift to clear

- Beads: **16 closed / 16 open**; `i4a (hpo)`, `i4b (tc1)`, `i7a (q4s)` are still open though
  `9536c74` landed them. Close with commit refs. `i4c (t6u)` is **partial** —
  `placement_collects_on_live_map` covers pool/band on summit but not the ">60° apart" assertion.
- File new infra beads for G1, G1b, G2, P1-P4.
- `WORKFLOW.md:66` still documents the forbidden deploy target (Shine's own directory).
- `DESIGN.md:282` says tunnel band 25-60 m; shipped defaults are 56-90 m from spike tby.
  DESIGN.md is canonical, so one of them is wrong.

---

## 8. Decisions needed from Arian

1. **Sequencing (recommend first):** let me run **G1 + G1b + G2** now. They need no publishing,
   change nothing you own, and they either unlock the whole plan or tell us the fallback. G1b
   deliberately breaks a vanilla join against a *throwaway* extension on the DEV instance.
2. **Publishing account:** yours, or a separate one? Needed only at P7.
3. **Visibility at P7:** FriendsOnly (you must be Steam friends with the publishing account) or
   Unlisted if LaunchPad offers it?
4. **`-webadmin` on DEV** for G2 — yes/no. Never on LIVE without you.
5. **DEV on 27025/27026 with its own `-modstorage`** — confirm.
6. **`hordetest` in the shipped mod:** it has a `shared.lua`, so per fact 11 it changes the
   message table even when disabled. Options: (a) ship it in a **separate dev-only mod** never
   mounted for release, (b) strip its `shared.lua` so it is server-only, (c) accept it in the
   mod and gate on config. I recommend (a).
7. **Band 25-60 vs 56-90:** which is authoritative?
