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
| Arian's live server | `D:\games\ns2srv\` — do not touch, do not restart, do not enable `hordetest` |
| Engine log | `C:\Users\aria\AppData\Roaming\Natural Selection 2\log-Server.txt` (Windows-side, shared with the live server's client — treat as read-only evidence) |
| Our published mod | Workshop item **`3807461324`** (`seedinghorde`, public). Client auto-download **verified** — a vanilla client joins with no launch options |
| Shine | published item `117887554`; our plugins load *alongside* it, never inside it |
| Join from the same box | client launch option `+connect 127.0.0.1:27025` (or `connect 127.0.0.1:27025` in the console) |
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
| `spawner.lua` | creates `TunnelEntrance` mouths, pending→registered across a tick, the reveal | A fresh entity has no usable id in its creation tick; a reveal must be re-asserted every second or it lapses |
| `statemachine.lua` | Inactive → Wave → Intermission → Teardown, cooldown | Legal transitions only; `Stop` while inactive is refused, not ignored |
| `triggers.lua` | the gate (seeding state, marine caller, MinPlayers, cooldown) + snapshots | `/horde` must be answerable from one status line |
| `takeover.lua` | hold/release of `botTeamController` | Snapshot → lock → cap 0 on the way in; restore on the way out. Release only what you took (the engine asserts on a negative lock counter) |
| `server.lua` | commands, the 1 s tick, `ResetWorldForHorde`, `Teardown`, `HandBackWorld`, `MovePlayersToSpectator`, game-end suppression | The order of the handback: destroy → release takeover → reset world → move humans to spectator → release the win switch |
| `economy.lua`, `hud.lua`, `waves.lua` | stubs (i6a/i9a territory) | Not yet load-bearing |

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
8. `Pathing.GetPathDistance` is walking length; `Vector:GetRangeTo` is the line. On `ns2_summit`
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

## 6. The dev loop

```bash
./dev/check-env.sh              # is this box sane (paths, steamcmd, live-vs-dev separation)
./dev/lint.sh                   # static gate: Lua 5.1 grammar via luaparser. Run before anything
./dev/test.sh [map] [timeout]   # full headless suite on the published artifact (~45 s + boot)
./dev/test.sh --bad-config      # plants a corrupt HordeMode.json and asserts the sanitizer repaired it
./dev/test.sh --handback        # PROBE ONLY: the real ResetGame handback (see §7)
./dev/server-start.sh [map]     # joinable DEV boot (hordetest disarmed, Debug.RevealMouths on)
./dev/server-start.sh --with-suite [map]   # armed boot (test.sh uses this)
./dev/guard-server.sh           # refuses destructive action while a client session is open
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
changes no map, humans landing in spectator with vanilla bots restored, and positions differing
across three consecutive `/horde` runs. Findings from it become beads. Every serious defect in this
project arrived through that door, not through the suite.

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
  takeover + live integration · M4 placement (surface-gated, seeded) · M7 teardown + handback.
  **M0–M4 + M7 implemented.** M5 (bots), M6 (wave loop), M8 (loss triggers) are not.
- **Gates**: G1 (`-game` mounts) and G1d (dev owns `-modstorage`) passed; the loop now needs **no
  overlay at all** — it runs from the published artifact. G1b, G1c (overlay-era questions, largely
  superseded by publishing), G2 (graceful stop) and S4 (`-instance_id`; engine log and `dumps/` are
  still shared with the live server) remain open.
- **Suite**: 60 scenarios, 0 failed, 1 expected (the negative control), plus `--handback` 2/0.
- **Playable today**: `/horde` places 3 mouths on buildable surfaces, revealed to marines;
  `/horde status` reports live counts; killing mouths updates them; `/horde stop` destroys our set,
  hands the bot controller back, resets the world to NotStarted, moves humans to spectator, and
  does **not** declare a winner or change the map.
- **Still not true**: no aliens come out of a mouth (i5a), no wave 2 (i6a), and a horde that "ends"
  cannot end (i8a). Vanilla win/loss stays suppressed for the round by one engine field, which is
  precisely why i8a has to exist.
- Tracker: 42 closed / 23 open beads.

## 9. Known gaps and risks

1. **Harness ceiling (`0k3`)**: deferred checks past ~8 s never fire. i5b (stream-to-base 15–60 s)
   and i6c (3-wave) cannot be written headless as specced. Either fix the runner or make those two
   human-watched playtests. Decide before M5.
2. **Balance numbers are placeholders** (RD3, Arian's). Curves ship disabled; `DESIGN.md` §8 marks
   them `untuned, placeholder 2026-09-21`.
3. **`votesurrender` bypasses suppression** — undecided: disable during a horde, or keep as an
   escape hatch.
4. **Vanilla draws a round when neither side has players** (measured), so i8a cannot be modelled as
   "marines win when the aliens are empty" (bead `cwo`).
5. **Full state restore is Phase 2**: teardown restores the bot controller and destroys our set;
   team resources or any other engine state we later touch is logged rather than guessed at.
6. Stopping a busy server writes a minidump (mitigated: `upload-dumps=false`, idle stops are
   clean). No graceful exit exists on this engine.
7. GitNexus has no Lua grammar — it is blind to this repo. Use `grep`/`read` on the shipped Lua.

## 10. Next actions, in order

1. **i5a bot factory** (bead `eav`): spawn `PlayerBot` at a mouth, register it on the registry as
   `bot`, retry until `GetPlayer()` exists (a bot's player is not available in the creation tick —
   the spike proved `LoginPlayer` works in WarmUp). Its ≤5 s window fits the harness ceiling, so it
   is headless-able. Acceptance: a bot exists, is on the alien team, and teardown's created-set
   destroys it and reports zero leaks.
2. **i8a loss triggers** (`cwo`, `7r3`, `qji`): all marines dead simultaneously, or the chair
   destroyed. Must answer the measured draw behaviour and decide the surrender-vote question.
3. **i6a wave loop** (`1fv`, `685`): needs RD3 numbers from Arian and the sector/placement decision
   (`5ss`: 3 mouths still land in 1 of 3 sectors at the `BandMin` edge on summit — decide eligible
   sources, per-map `ActivePerWave`, band, fallback).
4. Fix or route around the **harness ceiling** before committing to i5b/i6c as written.
5. Human-facing polish: intermission timer + skip, HUD/banner (i9a), retro + tag v0.1-slice (i10a).

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

Last updated: 2026-09-27 — `/horde stop` moves humans to spectator, and this document exists from
that change onward (`git log -1` for HEAD; a doc cannot carry its own commit hash and stay true).
Suite 60/0/1, handback 2/0, round trip verified end to end by a human.
