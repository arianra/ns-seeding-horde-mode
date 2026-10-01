# Workflow

How work moves here: what is tracked where, where the environment lives, and how the loop runs.
**Current state and next actions are NOT in this doc** — they live in `HANDOFF.md` (§8, §10) and
`bd ready`, and this file deliberately does not restate them (restated status is how this doc rotted
once already; see the 2026-09-29 note below).

## Knowledge split
- **Obsidian vault** (durable design knowledge):
  `/mnt/c/Users/aria/iCloudDrive/Documents/obsidian/massiveboi/massiveboi/Atlas/Projects/ns2-tower-defense/`
  — `decisions/` (ADRs Q1–Q29 + amendments), `design/` (pillars), `discussions/`
  (deferred calls), `research/` (source dives, case studies, backlog), `reference/`
  (engine mechanics and the environment runbook).
- **This repo** (code + working docs): README (entry point), DESIGN.md (canonical spec),
  HANDOFF.md (orientation, rules, state, next actions), MODDING.md (cited engine facts),
  `.beads/` (task tracker).

## Task tracking — beads
`bd` with dependency graph; issues live in a local Dolt DB, `.beads/issues.jsonl` is a passive
export for the remote.

Flow: `bd ready` → `bd show <id>` → work → findings go to the VAULT (research/ or decisions/
notes) → `bd close <id> --reason "…"` → `./dev/beads-snapshot.sh` → commit the export. The vault
never holds task state; bd never holds design rationale (link only). Every finding from a human
playtest arrives as a bead (`dev/PLAYTEST.md`), and one commit per bead is the rhythm.

## Git remote
- `origin` = git@github.com:arianra/ns-seeding-horde-mode.git (PUBLIC, branch main).
- Auth: SSH (existing arianra key). `gh` CLI installed at ~/.local/bin/gh
  (device-flow login as arianra; token in plaintext ~/.config/gh/hosts.yml).
- Push normally via SSH: `git push`. `gh` only needed for repo/API ops.
- Never copy a host config directory into the repo — `ns2srv/cfg/ProgressionConfig.json`
  holds live tokens and this repo is public.

## Dev environment — source of truth for paths is `dev/paths.sh`
Single definition, verified here by pointer rather than by restating values:

- **NS2 game Lua = build 344 installed server:** `/mnt/d/games/ns2-server/ns2/lua` (~650 files
  incl. `bots/`). The `/mnt/d/projects/ns2-td/research/laststand` clone is **stale** (no
  `lua/bots/`, old balance values) — historical reference only.
- **Versioned snapshot + navigation:** `D:\projects\ns2-lua-workspace` (git repo) — a snapshot of
  the shipped tree (re-snapshot ritual in its README) and the vendored `lua-language-server`;
  the mod's `.luarc.json` adds the LIVE tree as `workspace.library`, so the `lsp` tool answers
  mod↔engine definition/reference. GitNexus has no Lua grammar — its index of either tree is
  files + full-text only (`HANDOFF.md` §9 landmine 7).
- Dev server config + mod storage: `D:\games\horde\server\{cfg,mods}`, port **27025/27026**
  (isolated `-modstorage`). Arian's live tree: `D:\games\ns2srv\cfg`, 27015/27016 — read-only,
  and **development never needs it**: a live boot happens only on Arian's explicit request
  (HANDOFF §2 rule 0).
- Dedicated-server binaries: `D:\games\ns2-server` (steamcmd app 4940, anonymous; steamcmd at
  `D:\games\steamcmd`). Launched/driven via `powershell.exe` from WSL — the scripts own it
  (§Running).
- Game client + mod tools: `C:\Program Files (x86)\Steam\steamapps\common\Natural Selection 2`,
  `x64/Editor.exe`, `x64/Builder.exe`, `x64/Decoda.exe`, `x64/LaunchPad.exe` (the real publisher).

## Layout (i0b canonical; delivery reworked 2026-09-22 — repo `source/` is truth)
Shine resolves the server entry as `extensions/<name>/server.lua`, NOT `server/init.lua`
(extensions.lua:257) — multi-file extensions are FLAT and load siblings via
`Shine.LoadPluginFile`. The i0a scaffold used a `server/` subdir; i0b flattened it.
```
source/lua/shine/extensions/hordemode/
  shared.lua         -- Plugin def, data table, constants
  server.lua         -- ENTRY: lifecycle, world-ready gate, commands, orchestration
  config.lua         -- DefaultConfig, validators, Maps deep-merge, migrations
  statemachine.lua   -- Inactive/Wave/Intermission/Teardown
  registry.lua       -- HordeRegistry: everything we spawn (teardown truth)
  takeover.lua       -- BotTeamController lock/snapshot/restore + the refill nudge
  placement.lua      -- procedural tunnel-mouth selection (pure fns)
  spawner.lua        -- mouths (TunnelEntrance) + bots (PlayerBot recipe)
  waves.lua          -- composition, clear detection, intermission (STUB - i6a)
  triggers.lua       -- /horde gates + loss predicates
  economy.lua        -- payouts, bounties (STUB - i6a)
  hud.lua            -- ScreenText (STUB - i9a)
source/lua/shine/extensions/hordetest/   -- headless scenario harness (never armed on a joinable boot)
dev/                   -- lint/test/deploy/package/publish/server-start/stop/guard/state scripts
```
Deploy target (dev): `./dev/package.sh` builds the artifact zip; `./dev/deploy.sh` installs it
into **DEV mod storage** (`$DEV_MODS/content/4920/e2f13fcc`) and `server-start.sh` boots with
`-modstorage`. It is a published Workshop mod (`3807461324`), so the client side is fetched by
Steam normally — a republish only reaches running servers on their next boot, so **republish ⇒
restart dev before humans join**. **Never** write dev files into a workshop copy of Shine
(`...\workshop\content\4920\117887554\...`) — that is what broke Arian's client against every
server on earth; the full story and the enforcement live in `dev/STANDARDS.md`.

## Running the loop
```bash
./dev/lint.sh                   # static gate alone: Lua 5.1 parse + advisories (~3 s)
./dev/test.sh [map] [timeout]   # full headless suite on the artifact
./dev/test.sh --handback        # the probe-only run: the ONLY run allowed a real ResetGame
./dev/test.sh --bad-config      # sanitizer round trip against a planted corrupt HordeMode.json
./dev/server-start.sh [map]     # joinable DEV boot (hordetest disarmed, RevealMouths on)
./dev/server-stop.sh            # PID-identity-checked stop, never by name
./dev/guard-server.sh           # refuses destructive action while a client session is open;
                                # a stale ledger cannot block a boot when no tracked process runs
```
`test.sh` prints an eight-step loop (`0/8` environment parity … `8/8` state ledger and managed
content): materialise the dev config from the live cfg + repo overlay (never point `-config_path`
at the repo copy — token safety), deploy, boot armed, fence the log *after* boot so a stale
`ALL-DONE` cannot fake a pass, poll for `ALL-DONE` (default 300 s), stop, then assert the client's
Steam copy is pristine. **Exit 0** only when `fail=0`. The baseline IS the `ALL-DONE` line of the
current run — never hard-code a scenario count into a doc; read it.

`Assert.NoErrors` is deliberately absent: a global "no lua errors since boot" check needs an
unverified hook, so it stays a spike rather than a fake assertion.

## Writing scenarios
`source/lua/shine/extensions/hordetest/scenarios.lua` — register with
`Plugin:RegisterScenario(Name, Expected, Func)` and raise through `Plugin.Assert.*`
(`True`, `False`, `Equal`, `Nil`, `NotNil`, `Alive`, `Gone`). The runner waits for
`GetGamerules()` (never touch game APIs in `Initialise` — spike zpw) plus a settle window,
runs bodies in registration order in one synchronous pass, then lands deferred checks
(`self:Defer(Name, Seconds, Expected, Func)` — on **hordetest**, not the plugin under test)
and withholds `ALL-DONE` until every one resolves. Deferred checks fire reliably only within
the first ~8 s of the queue (bead `0k3`) — one callback, no chains, which is what gates i5b
and i6c as specced.

`Expected = true` marks a **negative control**: it must fail, counted separately as
`expected_fail`. If it passes, the runner reports a real FAIL — the suite's own honesty check.
Add one per new assert helper, not per feature. The full authoring rules — including the ones
paid for (demonstrate a new check failing before letting it pass; restore shared state before
asserting; doubles model transitions, not errors) — are `dev/SCAFFOLDING.md` §8 and
`dev/REVIEW-CHECKLIST.md`.

---
*Note (2026-09-29): this file previously carried a "Current graph" of design-era beads and a
"Baseline today: pass=2". Both were dead weight within weeks; status now lives only in HANDOFF
and the tracker, and this doc keeps procedure.*
