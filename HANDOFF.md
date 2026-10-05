# HANDOFF — NS2 Seeding Horde Mode

**Read this first if you are a new agent.** It is the orientation, the landmines, the operating
manual and the current state, in that order. The durable *why* lives in the Atlas vault
(`Atlas/Projects/ns2-tower-defense/`), and §12 lists which note answers which question.

Repo: `D:\projects\ns-seeding-horde-mode` (WSL: `/mnt/d/projects/ns-seeding-horde-mode`), branch
`main`, remote `origin`. Everything below was true as of the commit at the foot of this file.

---

## 1. Orientation — read in this order

| Doc | What it is |
|---|---|
| `HANDOFF.md` (this) | how to work here safely, current state, next actions |
| `DESIGN.md` | **the canonical spec.** Every mechanic, every locked decision (Q1–Q29), the config schema. When code and spec disagree, one of them is wrong — say so, don't silently pick |
| `MODDING.md` | the modding ecosystem as measured: 27+ numbered facts with file:line citations, the workflow, the gates (G/S/P series) |
| `dev/STANDARDS.md` | **binding.** What dev tooling may and may not write. Read before touching any script |
| `dev/SCAFFOLDING.md` | the LaunchPad pipeline, publishing, the vararg rules for extension files, test-authoring rules |
| `dev/REVIEW-CHECKLIST.md` | what a review of a change here must check |
| `PLAN.md`, `beads` (`bd ready`) | the decomposition and the claim list |

`AGENTS.md` / `CLAUDE.md` are generated beads boilerplate; the *user-level* `~/.omp/agent/AGENTS.md`
carries the owned-content table that actually governs.

## 2. Rules that cannot be broken

These are not style preferences. Each one is the residue of an incident, and two of them cost
Arian the ability to play the game.

0. **This is mod development. There is no community server to run.** During development the only
   server that exists is **dev** (27025, `./dev/server-start.sh`). The live tree
   (`D:\games\ns2srv\cfg`, 27015) and its boot procedure (§6) are kept documented **for possible
   future use only** — never boot, touch, or keep it running on your own initiative; a live server
   happens **only when Arian asks for one by name**. Ruled 2026-09-29 after the first
   two-servers-running evening produced exactly the confusion this rule prevents.
   If the live is not what he asked about, the answer is dev.
1. **Never write inside content another tool owns.** Writable: this repo, the dev config tree
   (`dev/paths.sh` is the single definition — currently `D:\games\horde\server\{cfg,mods}`), and
   NS2's per-user mod storage `%APPDATA%\Natural Selection 2\workshop`. **Read-only:**
   `steamapps/workshop/content/**` (the *client's* mod copies — editing them makes every server on
   earth reject Arian), `steamapps/common/**`, `D:\games\ns2-server/**` (steamcmd-owned),
   `%APPDATA%\Natural Selection 2\cfg` + `system_options.xml` (the client's), and
   `D:\games\ns2srv\cfg` (**his live server** — never on your own initiative).
   If the only way to green a check is editing managed content, **the dev path is wrong.**
2. **A PID is not an identity.** Never kill by process name; `dev/guard-server.sh` refuses to
   stop or start while a client session is open, and `server-stop.sh` resolves the process behind
   the pidfile and checks it is *ours*. Stopping a server that has live entities in it writes a
   ~60 MB minidump — that is the dev loop's shutdown, not a game crash.
3. **One writer per file, and it writes the complete state.** `server-start.sh` replaces
   `HordeTest.json` wholesale; a mode patched into that file by another script is silently lost.
   Measured: `--handback` reported a green 57-scenario suite because the boot overwrote the flag
   and the runner selected nothing.
4. **Shine persists the config table it loaded.** A key absent from `Plugin.DefaultConfig` is
   *deleted* from the JSON on the next boot, and a value a sanitizer computed wrongly is written
   back as if it had been chosen. Declare every knob in `DefaultConfig`.
5. **Never point dev tooling at live state**, and never copy a host config directory into the repo
   (`ns2srv/cfg/ProgressionConfig.json` holds live tokens).
6. **A subagent's report is a hypothesis.** Citations from scouts have been wrong in both
   directions (an invented `knownStructures`/`SetStructureAlwaysVisible` mechanism; a retracted
   "entity id vanishes on Disconnect" claim that turned out to be an artifact of our own registry
   inventing negative ids). Verify against the shipped Lua before acting.

7. **This is a marine aiming TRAINING mode — never mutate a base lifeform's stats.** A skulk
   must be a vanilla 75-HP / 10-armor skulk in every wave, or the marine learns the wrong
   time-to-kill and the mode stops training anything. Difficulty comes from **count** and **which
   lifeforms** (both vanilla units) and from pacing — never a `SetMaxHealth`/`SetMaxArmor`
   multiplier. If armored aliens are ever wanted, use the game's own **carapace** upgrade (fed by
   Shell veils off the prebuilt hives), not a stat hack. A per-alien HP/armor scaler (Q37) was
   wired and reverted the same day for exactly this reason (`3254809`; vault
   `decisions/td-training-mode-no-stat-scaling`). Bot *aim* (accuracy/aggro) is a separate,
   still-unwired lever and is fair game — that is not a base stat.

## 3. Environment map

| Thing | Value |
|---|---|
| Engine / server binaries | `D:\games\ns2-server\` (build 14.13.x, `ns2/lua` is the reference source) |
| Shipped game Lua you will read | `/mnt/d/games/ns2-server/ns2/lua/` (flat, ~650 files) |
| Dev server config | `D:\games\horde\server\cfg` (rebuilt from the live cfg + repo overlay each run) |
| Dev mod storage | `D:\games\horde\server\mods` (`-modstorage`, isolated from Steam) |
| Dev server port | **27025** (UDP; 27026 paired). Live server is 27015/27016 |
| Arian's live server | Runs ON THIS BOX: config `D:\games\ns2srv\cfg`, UDP **27015/27016**, default mod storage (`%APPDATA%\Natural Selection 2\workshop`). Boot/stop procedure in §6. Never write its cfg, never restart, never enable `hordetest` — **except on Arian's explicit request** (the 2026-09-29 restart, MapCycle/BaseConfig/Cooldown edits were such a request) |
| Engine log | `C:\Users\aria\AppData\Roaming\Natural Selection 2\log-Server.txt` (Windows-side, shared with the live server's client — treat as read-only evidence) |
| Our published mod | Workshop item **`3807461324`** (`seedinghorde`, public). Client auto-download **verified** — a vanilla client joins with no launch options |
| Shine | published item `117887554`; our plugins load *alongside* it, never inside it |
| Join | dev: client launch option `+connect 127.0.0.1:27025`; live (when booted): listed in the server browser under tag `horde`, or `+connect 127.0.0.1:27015` from this box |
| Research clones | `/mnt/d/projects/ns2-td/research/` (shine, shine-wiki, laststand, combat) |
| Issue tracker | beads (`bd`), Dolt-backed; `.beads/issues.jsonl` is a passive export committed for the remote |

## 4. Architecture

Two Shine extensions, both inside **our own mod** (`source/lua/entry/seedinghorde.entry` registers
it; Shine globs `lua/shine/extensions/*.lua` across every mounted mod, which is the only Lua
loading path that exists).

`hordemode` — the plugin:

| Module | Owns | The invariant it exists to protect |
|---|---|---|
| `shared.lua` | message table + client-side stub | **Any `shared.lua` changes the network message counts**, so the client must mount our mod. There is no server-only plugin with shared state |
| `config.lua` | `DefaultConfig`, `Resolve(map)`, `Sanitize`, curves, `DeepMerge` | Every number that reaches gameplay is clamped **and** defaulted from `DefaultConfig` — a clamp floor is not a default (see §5) |
| `registry.lua` | the created set: `Register/Unregister/Drain/Clear`, `PruneDead`, `GetEverIds`, BTC state | Accounting truth. Liveness is a **three-state** answer injected as `StateOf`; nothing may dereference a stored handle |
| `placement.lua` | candidate generation + selection, all pure except the hooks | Only points the *engine* accepts as buildable; band in **walking** metres; base-room floor in **straight-line** metres; one per sector; spread by distance; seeded per wave |
| `spawner.lua` | creates `TunnelEntrance` mouths and bot players, pending→registered across a tick, the bot join→place→EMERGE stage, the reveal | A fresh entity has no usable id in its creation tick, and a fresh bot has no *joined* player for several more; a reveal must be re-asserted every second or it lapses. Emergence = the engine's egg recipe at the mouth's ENTRANCE (capsule fit + the same `SnapToSurface` validation mouths pass) — the tunnel ORIGIN is inside its own hollow shell, and bots placed there stand in it forever (the chair's t28 symptom) |
| `statemachine.lua` | Inactive → Wave → Intermission → Teardown, cooldown | Legal transitions only; `Stop` while inactive is refused, not ignored |
| `triggers.lua` | the gate (seeding state, marine caller, MinPlayers, cooldown) + snapshots | `/horde` must be answerable from one status line |
| `takeover.lua` | hold/release of `botTeamController` | Snapshot → lock → cap 0 on the way in; restore on the way out. Release only what you took (the engine asserts on a negative lock counter) |
| `server.lua` | commands, the 1 s tick (wave phases, loss latches, grace, the t28 motion-waypoint steer, the Q30 death reaper), `BeginWave` (cull → place → deal curve + Q31 ladder), `EndWavePhase`, `ResetWorldForHorde`, `Teardown`, `HandBackWorld`, `ReportHumansKept`, game-end suppression, Q32 autobuild borrow/restore | The order of the handback: destroy → release takeover → reset world → count (touch) no players → release the win switch → restore the build clock. Every wave starts from a cleared board. Skulks neither roam nor take orders, so the tick writes their move target; death is release; borrowed engine flags are given back exactly as found |
| `waves.lua` | the wave math: `Composition`/`WaveClearPayout` curve evaluation (bezier, `Enabled` normalised at the sanitizer), the Q31 `Deal` ladder (unlock → ramp → largest remainder → one-per-unlocked → interleave), `Cleared`/`MouthsFallen`/`Wipe` predicates | Pure functions; the machine owns timing, the registry owns counts — the separations that let the loop be tested without a server |
| `economy.lua`, `hud.lua` | stubs (i9a territory) | Not yet load-bearing — the wave payout currently credits the team resource directly (Q17); per-marine share + HUD announcement are i9a's |

`hordetest` — the headless harness: `server.lua` is the runner (boot settle, scenario pass,
deferred-check queue, `ALL-DONE pass=N fail=N`), `scenarios.lua` is the suite. `RunSuite` gates it
(a manual boot must be joinable); `RunHandback` selects the probe-only run.

## 5. Engine facts we measured (these are load-bearing)

Citations are `ns2/lua` unless noted. Build 14.13.x, verified 2026-09-26/27.

1. `kGameState = {NotStarted, WarmUp, PreGame, Countdown, Started, Team1Won, Team2Won, Draw}`
   (`Globals.lua:265`), and **`GetGameStarted()` is `gameState == kGameState.Started` and nothing
   else**. WarmUp/NotStarted can never end a round; a Started round with an empty alien side has
   exactly one reachable end — marines win, map rotates.
2. `CheckGameEnd` is gated on `preventGameEnd` (`NS2Gamerules.lua:1788`); `SetPreventGameEnd` is
   the engine's own switch. `ResetGame()` (`:496`) sets `NotStarted` **and nils `preventGameEnd`**
   itself (`:~702`).
3. **A destroyed Spark entity throws on the first field access** — `if not x or not x.Foo` *is* the
   dereference. A throw inside a Shine timer kills that timer. Liveness must be answered by id
   (`Shared.GetEntity(id)`), never by touching a handle.
4. **A killed structure is present but not alive**: it stays in the entity list through its death
   sequence and reports `GetIsAlive() == false`. Vanilla distinguishes them at
   `Team.lua:502-510`.
5. `Location` / `LocationMarker` / `ScriptedTriggerVolume` origins are **volume markers**
   (`Location.lua:6` sets `ranges = {0,0,0}`) — routinely in rock or mid air. Not surfaces.
6. The build gate is `BuildUtility.GetIsBuildLegal` (`:277`): `Pathing.GetFlags`
   (`PolyFlag_Walk`/`NoBuild`, `:20-26`) → `Physics.GetGroundAtPointWithCapsule` at the
   **structure's own extents** (`kTechId.Tunnel.extents 1.2`, `TechData.lua:3035-3048`) →
   `Physics.CollideCapsule` (`:30-34`). Tunnels add an obstacle capsule + hive-count cap
   (`:411-438`).
7. `Pathing.GetPathPoints`/`GetPathPointFrom` (`:171-177`) **always include the start point**, so a
   `CommandStructure` origin (inside its own footprint, mesh carved out) cannot be a path start —
   snap to the mesh first. `BotUtils.lua:357` marks such queries `"Expensive !!!"`.
8. `Pathing.GetPathDistance` is walking length; the straight line is `Vector:GetDistanceTo`
   (3D, `Vector.lua:40`) or `GetLengthXZ` / `Placement.Distance2D` (horizontal). Build 344's shipped
   `Vector.lua` has **no `GetRangeTo`** — an earlier version of this fact named one, from an older
   build; a scenario that called it threw at runtime (measured 2026-09-28). On `ns2_summit`
   the line is ~0.7–0.8 of the walk. They are different quantities and both matter.
9. `botTeamController` is created in `NS2Gamerules:OnCreate()` (`:185`) — **per map, survives
   `ResetGame`**, so a snapshot taken at horde start is still valid at teardown.
   `SetMaxBots(n, com)` (`BotTeamController.lua:185-193`) assigns `com` to **both** commander flags
   and, for `n == 0`, immediately `RemoveBots`. Restore the flags directly, never through the
   setter. `updateLock` is a counter and `EnableUpdate` asserts `>= 0`.
   `GetUpdateEnabled()` = `MaxBots > 0 and updateLock == 0`.
10. A mouth is a team-2 entity, so its own map blip is relevancy-gated to aliens
    (`MapBlip.lua:82-96`) — a marine cannot see it. `DetectableMixin:SetDetected(true)` makes the
    engine add a marine-relevant `SensorBlip` (`SensorBlip.lua:35`, drawn through walls per
    `Marine_Client.lua:42-100`) with no client Lua and no extra entity. **Detection expires 1.5 s
    after it is last asserted** (`DetectableMixin.lua:98-105`), so it must be re-asserted.
11. Bots count as players (`Team:CountPlayers`, `Team.lua:126-134` tallies `numBots` separately),
    and a bot's virtual client owns a real `Player` entity — so "has a client" does **not**
    distinguish humans; the `gServerBots` roster does.
12. `votesurrender` calls `Gamerules:EndGame()` **directly**, bypassing `preventGameEnd`
    (`shine/extensions/votesurrender/server.lua:238`). Any plugin that ends the game by hand does.
13. Windows→server packets arrive source-NATed as `172.30.128.1` under WSL/Hyper-V, so per-IP
    logic sees the gateway.
14. Map changes run a Steam UGC update pass against a UWE whitelist of 114 hotfix mods, with join
    lockdown while installing.
15. Shine does **not** deep-merge a loaded plugin config under `DefaultConfig` — the file's table
    replaces ours wholesale, so a key missing from the file is missing at runtime, and the
    sanitizer is the only place a new key can get a default.
16. A bot's virtual client controls a **team-0 player that reports `GetIsAlive() == true`**
    (team 0 is the ready-room lobby, `kTeamReadyRoom`, `Globals.lua:119` — not the spectator team,
    which is 3): "has a player and is alive" does **not** imply "joined the team" — the
    alive-at-t+6/t+8 asserts in `takeover_live_cycle` and `registry_takeover_integration` were
    true of pre-join lobby players.
    `NS2Gamerules:GetCanJoinTeamNumber` (`:1385-1423`) refuses any join that would unbalance the teams
    when `force_even_teams_on_join` is set in `ServerConfig.json` (it is set on the dev tree), so on a
    headless boot with one marine bot and several alien bots the surplus aliens sit at team 0 forever —
    vanilla's `Bot:UpdateTeam` retries a refused gate every tick and never passes it. The horde is
    deliberately unbalanced (that is what the bot takeover, 7q7, means), so `Spawner:PlaceBots` forces
    its own joins: `JoinTeam(player, 2, true)`. A forced join replaces the player with
    `AlienTeam.respawnEntity = Skulk` (`AlienTeam.lua:48`) **in the same tick** — the lifeform class is
    real immediately, no evolve race. Measured 2026-09-28 through `bot_factory_settles`.
17. **Vanilla's own tunnel emergence is `player:SetOrigin(self:GetEntranceAPosition())`**
    (`Tunnel.lua:646`, inside the go-to-tunnel move) — the engine teleports the emerging player
    to the ENTRANCE, never the tunnel origin. Our `EmergenceSpot`/`MouthAnchor` independently
    arrived at the same anchor; this is the citation that says the design matches the game.
    Navigation note (2026-10-01): the shipped tree is now a `workspace.library` in
    `.luarc.json` (lua-language-server, vendored in `D:\projects\ns2-lua-workspace` - git repo with the engine snapshot + the tool; GitNexus indexes it file-level only, still no Lua symbols) — mod↔engine definition/reference
    queries work through the `lsp` tool; GitNexus remains blind to all Lua (no grammar, and
    the engine tree is not and must not become a git repo).
18. **`autobuild` is the engine's own instant-build+research lever**: `NS2Gamerules:SetAutobuild`
    (`:1947-1953`) makes `ConstructMixin`'s server tick force-complete every structure
    (`:133-183`) and clamps `ResearchMixin` research duration to ≤0.5 s (`:67-69`) — costs still
    paid at order time (`Commander_Server.lua:246-254`). Q32 borrows it for the horde's duration
    with snapshot/restore; `SetConstructionComplete` (`ConstructMixin.lua:463`) is the per-entity
    path if we ever need one. `SetAllTech`/warmup grants everything FREE — rejected: it deletes
    the resource sink the payout curve feeds.
19. **Shine persists the config it loaded, and `test.sh` boots the same tree it plants fixtures
    in** — hand-edits to `D:\games\horde\server\cfg\shine\plugins\HordeMode.json` are eaten by the
    next suite run's boot/stop cycle (three were, 2026-09-30, silently: the chair kept seeing
    intermission 60 after three "fixes"). Therefore `server-start.sh` DELETES the file on every
    joinable dev boot, and `Config.Resolve` (fact 20) supplies the defaults, so balance lives
    only in `config.lua`. A persisted file is runtime state, never a source of truth.
20. **`Config.Resolve` deep-merges the loaded file OVER a copy of `DefaultConfig`** — the file
    is an OVERRIDE layer, not the config. This was the fix for a full break: the old
    `Plugin.Config or Plugin.DefaultConfig` used a *minimal* loaded file (a regenerated boot
    writes just `{Debug.RevealMouths}`) as the whole config, and because Shine replaces rather
    than merges and `Sanitize`'s `Section()` only fills keys inside an EXISTING section, the
    result had no `Waves`/`Economy`/`Intermission`/`Start` at all — 1 alien, 0 res, 30 s, and
    (no `Start.ResetRound`) a skipped world reset that left the game `Started` with no ownership
    claimed, so stop could not hand it back and the seeding gate bricked every later command.
    `countdown_claims_the_round` + `resolve_fills_missing_sections` pin both halves.
21. **`ientitylist` yields `(index, entity)`** (`Entity.lua:97`) — `for Ent in ientitylist(...)`
    binds `Ent` to a NUMBER; the idiom is `for _, Ent in`. A `pcall` around the loop body turns the
    resulting "index a number" throw into a **silent no-op**: this killed `ResolveHordeTarget` for
    weeks — bots steered to the stale base-anchor, never the live command station (a real cause of
    "bots never reach base"), with a green suite. Lesson: `Shared/lessons/ientitylist-yields-index-first`.
22. **The damage pipeline cannot be hooked from Lua.** `LiveMixin:TakeDamage` calls
    `self:OnTakeDamage`, but the entity resolves that call through its own C++ path — adding
    `Alien.OnTakeDamage` never fires (yet `type(entity.OnTakeDamage)` reads as a function), and
    `ReplaceClassMethod("LiveMixin","TakeDamage")` misses instances (a mixin — instances dispatch
    the copied method). To observe damage, **poll health in the tick** (Q38 telemetry) or hook a
    real class's `OnEntityKilled`.
23. **`NS2Gamerules:OnEntityKilled` overrides the base without calling it** (`:416`), so Shine's
    `SetupClassHook(Gamerules,"OnEntityKilled")` is bypassed — wrap `NS2Gamerules` directly. And
    build 344 has **no Lua kill→resource path** (`AwardPersonalResources` uncalled; `kKillTeamReward=0`).
    Free team res comes from `PlayingTeam:UpdateMinResTick` (`:847`, 1 res/12 s when a team has no
    collecting extractor) — suppressing extractors *triggers* it, so a closed economy must silence BOTH.
24. **Higher lifeforms need a direct class swap.** Bots join as Skulk (`respawnEntity`, fact 16);
    vanilla evolves only near a hive (`canEvolve`, `distanceToNearestHive<8`) and `ProcessBuyAction`
    needs `GetIsUpgradeAllowed`+`GetCanAffordUpgrade` (a hive does not instantly research; gestation
    itself is a timer, `Embryo.lua:143`). So `ForceLifeForm` swaps the class via `Player:Replace` on
    the mouth's validated ground (no higher lifeform's capsule exceeds the skulk's 0.5 ground probe;
    `CopyPlayerDataFrom` carries no health, so the swap lands at full lifeform HP).
    `LookupTechData(techId, kTechDataMapName)` gives the class; `kTechDataMaxExtents` is a **Vector =
    C++ userdata, not a Lua "table"** — never `type()`-check one.
25. **The command hive class is `Hive`** (`Hive.kMapName="hive"`, `kTechId.Hive`), NOT `AlienHive`.
    `TechPoint:SpawnCommandStructure(team)` is public; the marine base's point is
    `marineTeam.startTechPoint` (known only after round start). Invincibility = add
    `Hive:GetCanTakeDamageOverride → false` (add/remove — `ReplaceClassMethod` can't add a
    non-existent method); teardown's `Kill()` still destroys them (that path is `GetCanDie`).
26. `SetHealth` clamps to `GetMaxHealth()` and `SetArmor` to `GetMaxArmor()` — a raise needs
    `SetMaxHealth`/`SetMaxArmor` first. (Moot for us now — stat scaling is banned by rule 7 — but the
    trap is real if anything ever touches a bot's health.)

## 6. The dev loop

```bash
./dev/check-env.sh              # is this box sane (paths, steamcmd, live-vs-dev separation)
./dev/lint.sh                   # static gate: Lua 5.1 grammar via luaparser. Run before anything
./dev/test.sh [map] [timeout]   # full headless suite on the published artifact (~45 s + boot)
./dev/test.sh --bad-config      # plants a corrupt HordeMode.json and asserts the sanitizer repaired it
./dev/test.sh --handback        # PROBE ONLY: the real ResetGame handback (see §7)
./dev/server-start.sh [map]     # joinable DEV boot (hordetest disarmed, Debug.RevealMouths on)
./dev/server-start.sh --with-suite [map]   # armed boot (test.sh uses this)
./dev/guard-server.sh           # refuses destructive action while a client session is open;
                                # a stale ledger cannot block a boot when no tracked process runs
./dev/server-stop.sh            # PID-identity-checked stop, never by name
./dev/deploy.sh [--check|--clean]  # install dev files into the dev tree; --check asserts the
                                   # client's Steam copy is pristine; --clean undoes damage
./dev/state.sh                  # declares every path we create and flags undeclared state
./dev/package.sh / publish.sh   # artifact zip / LaunchPad publication (human step for visibility)
./dev/beads-snapshot.sh         # export the issue tracker to .beads/issues.jsonl for the remote
```

The suite prints `[TEST] ALL-DONE pass=N fail=N expected_fail=N`; `test.sh` fences the log
*after* boot so a stale `ALL-DONE` cannot fake a pass, and fails the loop if the client's Workshop
copy is not pristine afterwards.

**A scenario body cannot call `ResetGame`**: all bodies run in one synchronous pass and the
deferred checks land afterwards, so a world reset invalidates another scenario's pending
assertions. That is why the handback probe is its own run, and why `handback_*` scenarios are
excluded from the normal one.

**The human half lives in `dev/PLAYTEST.md`** (bead `0kd`): a 12-step checklist covering exactly
what no headless run can see — visibility on the minimap, a mouth standing on real ground, the
status line after killing one mouth and after killing the last, a stop that declares no winner and
changes no map, humans landing back in warmup **on the teams they chose** with vanilla bots
restored, and positions differing across three consecutive `/horde` runs. Findings from it become
beads. Every serious defect in this project arrived through that door, not through the suite.

### Live server operation (same box, different tree)

Documented 2026-09-29 after it turned out no session had written the procedure down, only the prohibitions.

The live server boots **on this machine** from Arian's own config tree; since the 09-21 incident every
agent loop used the dev tree, so "never point at live" was documented thoroughly and "how to run it
when he asks" was not. Boot (canonical, from vault `reference/td-dev-environment-runbook`):

```powershell
Start-Process 'D:\games\ns2-server\x64\Server.exe' -WorkingDirectory 'D:\games\ns2-server' `
  -ArgumentList '-config_path','D:\games\ns2srv\cfg','-port','27015','-limit','16','+map','ns2_summit'
```

- No `-modstorage`: the live uses the **default** store `%APPDATA%\Natural Selection 2\workshop\content\4920\`.
  The engine downloads a Workshop item only if something names it: **`ns2srv/cfg/MapCycle.json`
  `mods` must list both `706d242` (Shine) and `e2f13fcc` (our item, = 3807461324)** — that is how
  `seedinghorde` reaches the live box, and how a republish reaches it too (fetched on boot/map-change).
- `ns2srv/cfg/shine/BaseConfig.json`: `hordemode` on is Arian's flag to set (it was left off after the
  09-21 crash-cleanup and the server ran no horde until 2026-09-29); `hordetest` must stay off there —
  and it double-disarms anyway, needing `HordeTest.json RunSuite=true`, which no live boot should have.
- **Stop**: same identity discipline as dev — resolve the PID whose command line carries
  `ns2srv\cfg` (this box can run dev and live side by side; never kill by image name), then plain
  `Stop-Process -Id`. Guard (`./dev/guard-server.sh`) first. A stop with players in it writes a large
  minidump — expected, not a game crash.
- Verify a live boot from its own rotated engine log (`log-Server-2.txt` when dev also holds the
  shared slot — S4 `0k3/7sv`): `Mounting mod 'seedinghorde'` from the `%APPDATA%` store, `- Extension
  'hordemode' loaded.`, `[HORDE] armed at game state 2`, and UDP 27015/27016 bound by that PID.
  Bytes beat all of that: sha256 the store copy against `source/` — on 2026-09-29 it was 16/16
  identical to the suite-passed build.
- Config values the live box carries (all set 2026-09-29 at Arian's request): `HordeMode.json
  Start.Cooldown = 5` — remember fact 15, the persisted file beats the code default, so a default
  change NEVER reaches a booted server; edit the file where it matters.

## 7. Verification discipline (each of these was paid for)

- **Prove both directions of every guard**: that it can fail, and that it does pass. A guard whose
  output is discarded, or whose bound defaults to the value that makes it never fire, is
  decoration (`silent-enforcement-is-not-enforcement`).
- **Assert the guarantee, not the hope** — and assert it across runs when the property is a
  cross-run property. Five placement assertions all passed while every boot produced the same
  three rooms (`assert-the-guarantee-not-the-hope`).
- **Restore before you assert.** A probe that leaks a recorder, or a scenario that reaches into
  shared plugin state while another scenario has a deferred check outstanding, breaks someone
  else's test and reads as a code bug (`restore-before-you-assert`).
- **Live end-to-end beats green headless.** Both of the two worst defects we fixed were invisible
  to the suite and obvious from the chair: mouths in rock, and a killed mouth's handle throwing in
  the tick. When Arian plays, read his log lines as requirements.
- **Print the effective bound**, not just the verdict (`0m under the 56m base-room floor` is what
  caught the clamp-floor default).
- **A report nobody can act on is not enforcement**: `controller released=false` was accurate and
  meaningless for weeks while the takeover sat never-engaged.
- Verify delivery **by bytes, not by a 200** (`verify-the-bytes-not-the-status-code`).

## 8. Current state

- **Milestones**: M0–M5 + M7 complete and shipped as the published mod; **M8 partial** —
  marines-wipe and station-destroyed end the horde; a real alien joining + seed-max remain (`7x3`).
  This session's arc (chair passes 4–6 + the design work):
  - **Economy closed and correct** (Q34/Q35, `99981cb`/`8394b09`): team res = start(50) + wave
    payout ONLY; the extractor AND vanilla's `UpdateMinResTick` free trickle both suppressed via
    `Shine.ReplaceClassMethod`; per-lifeform kill bounty via the `NS2Gamerules:OnEntityKilled` hook.
    (The first cut was silently broken — facts 22/23 explain why.)
  - **Higher lifeforms spawn** (`ForceLifeForm`, `9014bbb`): gorge/lerk/fade/onos from their unlock
    waves, vanilla stats. The factory had been silently skulk-only (fact 24).
  - **Q18 map frame** (`3c4eabe`): invincible `Hive` nests prebuilt at every TechPoint except the
    marine base (fact 25) — the spec required it and we had never built it.
  - **Bots now steer to the live command station** (`8394b09`): the `ientitylist` index bug (fact 21)
    had them walking to a stale anchor — a genuine cause of "never reach base."
  - Starting infantry portal removed; **Q38 TTK telemetry** (`Debug.CombatTelemetry`) added — measures
    time-to-kill by polling health (the damage pipeline can't be hooked, fact 22).
  - **Q37 per-alien stat multipliers REVERTED** (`3254809`) — rule 7: a training mode needs
    vanilla-consistent aliens; difficulty is count + species only.
- **Gates**: the loop runs from the published artifact, no overlay. G2 (graceful stop) and S4
  (engine log/dumps shared with the live server) remain open.
- **Suite**: 82 pass / 0 fail / 1 expected, plus `--handback` 2/0 (a real round prebuilds 4 hives on
  summit and tears them down with 0 leaked).
- **Playable today**: `/horde` runs the whole loop — validated mouths, waves of steered aliens
  (higher lifeforms from wave 3), invincible hive nests, a closed economy (flat between waves, kills
  pay a bounty), instant builds during the horde only, `/horde status` live truth, `/horde stop`
  hands the world back with no winner declared and humans on their chosen teams.
- **Still not true**: a real alien joining / seed-max don't end the horde (`7x3`); score logged not
  persisted (i16); no HUD/banner (i9a); alien RTs + building bounties (rest of §3) unbuilt; TTK fire
  rates are still estimates (telemetry not yet run in the chair); sub-wave pacing unbuilt. Vanilla
  win/loss stays suppressed by `preventGameEnd`; every remaining exit goes through our triggers.
- Tracker: 51 closed / 22 open beads (chair acceptance = PLAYTEST 13-19 + the new economy/lifeform/hive checks).

## 9. Known gaps and risks

1. **Harness ceiling (`0k3`)**: deferred checks past ~8 s never fire. i5b's pathing-QUALITY
   claims (15–60 s walks) and i6c (3-wave) cannot be written headless as specced; the waypoint
   itself is proven at `steer_pins_the_base_waypoint`, the walking is chair physics. Either fix
   the runner or make those human-watched playtests.
2. **Balance numbers are placeholders** (RD3, Arian's). The composition curve ships ENABLED at
   4→20/w20 (Q36 first-cut bump from 3→15) and the type ladder unlocks are read by `Waves.Deal`;
   none are tuned against measured TTK yet. Per rule 7 there is NO stat scaling — difficulty is
   count + species only.
3. **`votesurrender` bypasses suppression** — undecided: disable during a horde, or keep as an
   escape hatch.
4. **Vanilla draws a round when neither side has players** (measured), so i8a cannot be modelled as
   "marines win when the aliens are empty" (bead `cwo`).
5. **Full state restore is Phase 2**: teardown restores the bot controller and destroys our set;
   team resources or any other engine state we later touch is logged rather than guessed at.
6. Stopping a busy server writes a minidump (mitigated: `upload-dumps=false`, idle stops are
   clean). No graceful exit exists on this engine.
7. GitNexus has no Lua grammar — blind to all game logic (measured twice: 2026-09-28, 262 nodes
   here, none Lua; 2026-10-01, the engine snapshot repo indexed 2,847 nodes and `context` still
   answers "Symbol not found" for a shipped function — the nodes are files + FTS, not symbols).
   Use the `lsp` tool (lua-language-server over `D:\projects\ns2-lua-workspace`, fact 17's note)
   or `grep`/`read` on the shipped Lua.
8. **TTK fire rates are unmeasured.** The Threat Index (POWER-TAXONOMY §5) and the whole curve
   rest on DPS, and DPS needs animation-bound fire rates not in Lua. `Debug.CombatTelemetry`
   measures TTK (health-poll) but not per-shot rate. Until a playtest harvests real numbers, every
   power figure is an estimate.
9. **Sub-wave pacing is unbuilt** — the parked design: a wave currently dumps its whole roster at
   t=0 and ends only when all are dead (`Waves.Cleared`), so there is no drip and a straggler
   stretches the wave. The plan (decouple WHAT/WHERE/WHEN, mouths as lanes/timed windows, a
   schedule + clock/pressure wave-end) is in the frontier; it is the biggest gameplay-feel win left.
10. **The rest of §3 map frame is unbuilt**: alien RTs/harvesters prebuilt and the building-bounty
    economy. Bounties now become possible (structures exist) but collide with the Q34 closed economy —
    needs a decision on what is killable (harvesters?) vs invincible (hives) and whether bounty res
    reopens the "team res = start + payout only" rule.

## 10. Next actions, in order

1. **Chair gate — PLAYTEST 13-19 + this session's additions** (Arian runs it; findings become
   beads): the wave loop, the loss triggers, the emptied roster, instant builds both directions,
   AND the new ones — the economy is actually closed (flat between waves, kills pay the bounty by
   lifeform), higher lifeforms appear and behave from wave 3, hive nests are present and unkillable,
   no starting IP, and bots reach the base (the resolver fix). Step 14 is the walk verdict on
   steer+emergence; a bot standing through TWO rescue windows means the fit itself is trapped.
2. **Calibrate TTK from a playtest** — turn on `Debug.CombatTelemetry`, harvest real time-to-kill
   (and count shots for fire rates). This is the prerequisite for tuning the curve and building
   pacing against numbers, not estimates.
3. **Sub-wave pacing** — the parked design, now the biggest gameplay-feel win: decouple
   WHAT/WHERE/WHEN/HOW-MANY; a spawn schedule that distributes a wave's Threat-Index over time;
   mouths as lanes / timed windows; a clock/pressure wave-end instead of all-dead. The full
   brainstorm is in the frontier's Next and this era's session history.
4. **i8a remainder** (`7x3`, `qji`): a real alien joins, or seed max. Must answer the measured draw
   (vanilla DRAWS when neither side has players) and decide the surrender-vote question.
5. **Placement judgement (`5ss`)** — the bump to 4 mouths may exceed what summit's band can place;
   decide eligible sources / per-map `ActivePerWave` / band / fallback from the chair (reveal is on).
6. Fix or route around the **harness ceiling** (`0k3`) before committing any long-window test.
7. The rest of §3 (alien RTs + building-bounty economy — needs the killable-vs-invincible and
   closed-economy decision), then human polish: HUD/banner (i9a), score persistence (i16), tag v0.1-slice.

Before any of that: `./dev/lint.sh && ./dev/test.sh && ./dev/test.sh --handback` must be green on
an untouched tree, and `./dev/guard-server.sh` must show no open client session before you stop or
start anything.

## 11. What Arian owes

- **RD3 balance numbers** — the code now READS them (size curve 4→20/w20, payout 5→40/w10, ladder
  unlocks/ramps/weights, intermission 15/30, grace 3 s): tune from playtest telemetry. The
  HP/armor/damage stat curves are **gone by rule 7** (training mode) — do not re-add them; bot
  aim (accuracy/aggro) is the one remaining difficulty dial and is still unwired.
- **A playtest with `Debug.CombatTelemetry` on** — the real TTK/fire-rate numbers the whole power
  model and curve need before tuning is more than guessing.
- **Placement judgement** (`5ss`): whether the spread (now 4 mouths) reads well from the chair, and
  the eligible-source decision. `Debug.RevealMouths` makes this judgeable in-game.
- **Two design decisions before their builds**: the sub-wave pacing model (schedule + wave-end), and
  the §3 building-bounty economy vs the Q34 closed economy (what is killable vs invincible).
- **Playtest gates at M6 and M8**, and G1c if the overlay path is ever needed again.

## 12. Where the durable memory lives (Atlas)

Vault: `/mnt/c/Users/aria/iCloudDrive/Documents/obsidian/massiveboi/massiveboi/Atlas/`. Catalog
`_index.md`, rolling state `_frontier.md`, chronology `_journey.md`. Under
`Projects/ns2-tower-defense/`:

- `reference/td-ns2-bot-spawn-and-team-join` — the bot pipeline's three delays, the
  `force_even_teams_on_join` gate, "alive is not joined", and why the factory forces its own joins
- `reference/td-ns2-structure-placement-rules` — the build gate, and the four traps
- `reference/td-ns2-round-lifecycle-and-handback` — who may end a round, `ResetGame` semantics, the
  bot controller's lifetime
- `reference/td-ns2-minimap-and-entity-relevancy` — why a marine saw nothing, and the SensorBlip fix
- `reference/td-dev-environment-runbook` — how to run any of this, and what a dump means
- `decisions/td-game-end-suppression` — the `preventGameEnd` decision, measured
- `research/td-placement-summit-sector` — the open placement judgement
- `Shared/lessons/never-dereference-a-stored-handle` — one corpse, three symptoms; the three states
- `Shared/lessons/silent-enforcement-is-not-enforcement` — guards that cannot fail (4 instances)
- `Shared/lessons/assert-the-guarantee-not-the-hope` — single-draw assertions miss variety
- `Shared/lessons/restore-before-you-assert`, `a-pid-is-not-an-identity`,
  `never-write-into-managed-content`, `never-point-dev-tools-at-live-state`,
  `ship-every-mirror-or-none` (disputed), `verify-the-bytes-not-the-status-code`,
  `scout-citations-need-verification`, `live-e2e-verification`
- `Shared/lessons/a-wave-owns-its-books` — a side-effecting evaluator must pin the state it was
  created against; the wave loop's tick drained a foreign scenario's registry
- `decisions/td-death-is-release` — Q30: killed bot clients released within a tick, never reused
- `decisions/td-wave-model-v1` — Q31 ladder + Q32 instant builds + Q33 economy/pacing, with the
  power-vs-damage reasoning behind every unlock wave
- `reference/td-ns2-hive-frame-prebuild` — Q18: prebuilding invincible hives at every TechPoint
  (`TechPoint:SpawnCommandStructure`; class is `Hive` not `AlienHive`; invincibility via
  `Hive:GetCanTakeDamageOverride`; `Kill` still tears them down)
- `decisions/td-economy-closed-loop` — Q34/Q35: the closed team economy, the min-res trap, and the
  `NS2Gamerules:OnEntityKilled` bounty (build 344 has no Lua kill→resource path)
- `decisions/td-training-mode-no-stat-scaling` — **rule 7**: difficulty is count + vanilla species,
  never mutated HP/armor/damage; carapace is the sanctioned armour path (Q37 reverted)
- `Shared/lessons/ientitylist-yields-index-first` — `for Ent in ientitylist` binds a number; a
  swallowing pcall turned a dead walk-to-base resolver into a green suite
- `reference/td-ns2-bot-spawn-and-team-join` also now carries: the bounded re-deal of a bot whose
  client never materialises, `ForceLifeForm` (higher lifeforms), the unhookable damage pipeline, and
  the health-poll TTK seam.

---

Last updated: 2026-10-04 — **the chair-pass hardening arc + the map frame + the training-mode rule.**
Across four playtests the loop's rough edges were found and fixed, each invisible to a green suite
and obvious from the seat: a bot whose virtual client never materialised was silently dropped (now
re-dealt at its mouth, bounded); the economy shipped *broken* twice (extractor suppression alone
triggered vanilla's `UpdateMinResTick` free trickle; the kill bounty leaned on a Shine
`Gamerules:OnEntityKilled` hook that `NS2Gamerules` overrides and never fires — both now wrapped
correctly via `Shine.ReplaceClassMethod` / the real class); and `ResolveHordeTarget` used
`for Ent in ientitylist(...)` — binding a number, throwing, and being swallowed by its own `pcall`,
so bots steered to a stale anchor and never reached the base (facts 21–23). The starting infantry
portal is gone. **Higher lifeforms now actually spawn** (`ForceLifeForm` — the factory had been
silently skulk-only; fact 24), and **Q18 hive nests are prebuilt invincible at every TechPoint**
(fact 25; the spec required it, we'd never built it). **Q38 TTK telemetry** measures time-to-kill by
polling health (the damage pipeline can't be hooked from Lua; fact 22). And **Q37 per-alien HP/armor
scaling was wired then reverted the same day** — this is a marine *training* mode, so a skulk must be
a vanilla 75-HP skulk or the marine learns the wrong time-to-kill (rule 7,
`decisions/td-training-mode-no-stat-scaling`); difficulty is count + species only.

State: **M0–M5 + M7 shipped, M8 partial** (`7x3` — real-alien-join and seed-max loss triggers remain).
Suite 82/0/1, `--handback` 2/0 (a real round prebuilds 4 hives, tears them down, 0 leaked). Repo
`main` pushed and clean at `3254809`; dev server live on 27025. **Next**: the chair gate + a TTK
calibration playtest (turn the power estimates into measured numbers), then the parked **sub-wave
pacing** design (distribute a wave over time; mouths as lanes/windows; a clock/pressure wave-end) —
the biggest gameplay-feel win left — then i8a's remaining exits. The WALK itself is still PLAYTEST
step 14's verdict.
