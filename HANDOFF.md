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
| `spawner.lua` | creates `TunnelEntrance` mouths and bot players, pending→registered across a tick, the bot join→place stage, the reveal | A fresh entity has no usable id in its creation tick, and a fresh bot has no *joined* player for several more; a reveal must be re-asserted every second or it lapses |
| `statemachine.lua` | Inactive → Wave → Intermission → Teardown, cooldown | Legal transitions only; `Stop` while inactive is refused, not ignored |
| `triggers.lua` | the gate (seeding state, marine caller, MinPlayers, cooldown) + snapshots | `/horde` must be answerable from one status line |
| `takeover.lua` | hold/release of `botTeamController` | Snapshot → lock → cap 0 on the way in; restore on the way out. Release only what you took (the engine asserts on a negative lock counter) |
| `server.lua` | commands, the 1 s tick (wave phases, loss latches, grace, the t28 motion-waypoint steer, the Q30 death reaper), `BeginWave` (cull → place → deal the curve), `EndWavePhase`, `ResetWorldForHorde`, `Teardown`, `HandBackWorld`, `ReportHumansKept`, game-end suppression | The order of the handback: destroy → release takeover → reset world → count (touch) no players → release the win switch. Every wave starts from a cleared board — the end drain keeps intermission peaceful; the start cull is the guarantee. Skulks neither roam nor take orders, so the tick writes their move target directly; and death is release (Q30) — no bot client outlives its corpse by more than a tick |
| `waves.lua` | the wave math: `Composition.HordeSize` curve evaluation (bezier, `Enabled` normalised at the sanitizer), `WaveClearPayout`, `HordeSizeAt` | Pure functions; the machine owns timing, the registry owns counts — the three separations that let the loop be tested without a server |
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

- **Milestones**: M0 harness + static gate · M1 config + curves · M2 commands/gate · M3 registry +
  takeover + live integration · M4 placement (surface-gated, seeded) · M7 teardown + handback ·
  **M5 landed: i5a bot factory 2026-09-28** (`Spawner:SpawnBot` + the join/place stage);
  **the wave loop shipped 2026-09-30** (`61a`): `BeginWave` culls the carry-over, places the
  mouth set, and DEALS the `Composition` curve (ships ENABLED, placeholder 3→15/w20 — RD3
  tunes); waves clear by bot-wipe or mouth-kill (Q29), pay the flat `WaveClear` curve (Q17),
  intermission, next wave. **M8 partly (`cwo`)**: marines-wipe (3 s grace, D4) and
  station-destroyed (must-have-stood) end the horde; real alien joins + seed-max remain (`7x3`).
  t28 ANSWERED the same day: bots stood at the mouths — skulk brains have no roam action and
  never read the order queue — so the tick writes a standing motion-waypoint to the base
  (`SteerHordeBots`); step 14 re-verifies the walk.
- **Gates**: G1 (`-game` mounts) and G1d (dev owns `-modstorage`) passed; the loop now needs **no
  overlay at all** — it runs from the published artifact. G1b, G1c (overlay-era questions, largely
  superseded by publishing), G2 (graceful stop) and S4 (`-instance_id`; engine log and `dumps/` are
  still shared with the live server) remain open.
- **Suite**: 72 pass / 0 fail / 1 expected (the negative control) — 73 scenarios, plus `--handback` 2/0.
- **Playable today**: `/horde` places 3 mouths on buildable surfaces, revealed to marines;
  `/horde status` reports live counts; killing mouths updates them; `/horde stop` destroys our set,
  hands the bot controller back, resets the world to NotStarted, **leaves every human on the team
  they chose** (amended 2026-09-28; it used to move them to spectator), and does **not** declare a
  winner or change the map.
- **Still not true**: composition is all-skulks (per-type counts are RD3), a REAL alien joining
  and seed-max still do not end the horde (`7x3`), and the score is logged, not persisted (i16).
  Vanilla win/loss stays suppressed for the whole round by one engine field - the two live
  triggers are ours now, and every remaining exit (alien join, seed max, `7x3`) must go through them.
- Tracker: 46 closed / 22 open beads (71c closed on suite-green; chair acceptance = steps 13-16).

## 9. Known gaps and risks

1. **Harness ceiling (`0k3`)**: deferred checks past ~8 s never fire. i5b's pathing-QUALITY
   claims (15–60 s walks) and i6c (3-wave) cannot be written headless as specced; the waypoint
   itself is proven at `steer_pins_the_base_waypoint`, the walking is chair physics. Either fix
   the runner or make those human-watched playtests.
2. **Balance numbers are placeholders** (RD3, Arian's). The composition curve ships ENABLED at
   3→15/w20 (`untuned, placeholder 2026-09-30`); per-type counts are not read by anything yet.
3. **`votesurrender` bypasses suppression** — undecided: disable during a horde, or keep as an
   escape hatch.
4. **Vanilla draws a round when neither side has players** (measured), so i8a cannot be modelled as
   "marines win when the aliens are empty" (bead `cwo`).
5. **Full state restore is Phase 2**: teardown restores the bot controller and destroys our set;
   team resources or any other engine state we later touch is logged rather than guessed at.
6. Stopping a busy server writes a minidump (mitigated: `upload-dumps=false`, idle stops are
   clean). No graceful exit exists on this engine.
7. GitNexus has no Lua grammar — it is blind to this repo (re-verified 2026-09-28: a fresh index put
   262 nodes in the graph, and every one of them is a Python dev script; all game logic is invisible
   to it). Use `grep`/`read` on the shipped Lua.

## 10. Next actions, in order

1. **Chair gate — PLAYTEST 13-18** (the wave loop, the loss triggers, and the t28 walk
   re-verification at step 14) — Arian runs it; findings become beads. If bots still stand AT a
   mouth, that is tunnel geometry, not objective — the spawn point becomes the suspect.
2. **i8a remainder** (`7r3`, `qji`): a real alien joins, or seed max. Must answer the measured
   draw behaviour (vanilla DRAWS when neither side has players) and decide the surrender-vote
   question. (With bots real since 71c, the wipe branch has teeth.)
3. **i6a wave loop** (`1fv`, `685`): replaces the flat knob with curve-driven composition,
   clear detection, payout, intermission + skip. Needs RD3 numbers from Arian and the
   sector/placement decision (`5ss`: 3 mouths still land in 1 of 3 sectors at the `BandMin` edge
   on summit — decide eligible sources, per-map `ActivePerWave`, band, fallback) — judge `5ss`
   during the same chair sessions, reveal is on there.
4. Fix or route around the **harness ceiling** before committing i6c as written — i5b is now
   chair-shaped, so `0k3` mainly blocks the automated 3-wave test.
5. The forced alien join is a behavioural dependency of hosts running
   `force_even_teams_on_join` (fact 16) — keep the force (it is what 7q7 means).
6. Human-facing polish: HUD/banner (i9a), retro + tag v0.1-slice (i10a).

Before any of that: `./dev/lint.sh && ./dev/test.sh && ./dev/test.sh --handback` must be green on
an untouched tree, and `./dev/guard-server.sh` must show no open client session before you stop or
start anything.

## 11. What Arian owes

- **RD3 balance numbers** for i6a: endpoints per curve (composition, HP, armor, damage, mouth HP,
  payout, accuracy, aggro), horde size at w1/w10/w30, the plateau wave, cooldown/intermission/skip
  cost.
- **Placement judgement** (`5ss`): whether the current spread reads well from the chair, and the
  eligible-source decision. `Debug.RevealMouths` makes this judgeable in-game.
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

---

Last updated: 2026-09-30 (evening) — **the wave loop (`61a`) + the first two loss triggers
(`cwo`)**: `BeginWave` culls the carry-over, places the mouth set (deficit announced, not
swallowed), and deals the `Composition` curve — ships ENABLED at placeholder 3→15/w20; waves
end by wipe or mouth-kill (Q29), pay the flat `WaveClear` curve, intermit, escalate;
marines-wipe (3 s grace) and station-destroyed (must-have-stood latch) end the horde through
the same ordered teardown an admin stop runs. Writing the loop's tests found four real bugs,
all now pinned: an announce that passed its template to `Notify` (the chat contract is
asserted at the hook — `Announce` formats at the choke point now); a scenario abort that
skipped its cleanup defer and poisoned every later tick; the wave predicates acting on a
registry another scenario had mounted (`BeginWave` now records the wave's bookkeeping
identity and the tick refuses foreign books); and `Progress(1,1)` answering a mis-set
reference with the curve's CAP — a typo must never hand wave 1 the wave-20 horde.
`dev/test.sh --handback` also learned that its byte fence can land past the probe's own t+0
line: whole-file, because rotation already fences to the boot. Then the chair answered **t28**:
bots stood at the mouths — skulk brains have no roam action and do not read the order queue
(only Exo/marine-type brains do), so the tick now writes `GetMotion():SetDesiredMoveTarget()`
to the base every second for every live out-of-combat bot (`SteerHordeBots`; combat overwrites,
the tick re-arms). Suite 70/0/1, handback 2/0; the WALK itself is PLAYTEST step 14's verdict.
