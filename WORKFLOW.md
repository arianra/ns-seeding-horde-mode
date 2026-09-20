# Workflow

## Knowledge split
- **Obsidian vault** (durable design knowledge):
  `/mnt/c/Users/aria/iCloudDrive/Documents/obsidian/massiveboi/massiveboi/Atlas/Projects/ns2-tower-defense/`
  — `decisions/` (ADRs Q1–Q25), `design/` (pillars), `discussions/`
  (deferred calls), `research/` (source dives, case studies, backlog).
- **This repo** (code + working docs): README (pillars summary), DESIGN.md
  (canonical spec, once consolidated), `.beads/` (task tracker).

## Task tracking — beads
`bd` (v1.2.1) with dependency graph. Epic: `ns-seeding-horde-mode-f6x`.

## Git remote
- `origin` = git@github.com:arianra/ns-seeding-horde-mode.git (PUBLIC, branch main).
- Auth: SSH (existing arianra key). `gh` CLI installed at ~/.local/bin/gh
  (device-flow login as arianra; token in plaintext ~/.config/gh/hosts.yml).
- Push normally via SSH: `git push`. `gh` only needed for repo/API ops.

Flow: `bd list` → `bd claim <id>` → work → findings go to the VAULT
(research/ or decisions/ notes) → `bd comment <id> "filed: <vault note>"`
→ `bd close <id>`. The vault never holds task state; bd never holds design
rationale (link only).

Current graph:
- o9x WS1 NS2 mod case studies ─┐
- 4t3 WS2 TD game case studies ─┴→ 865 WS3 difficulty levers → 407 DESIGN.md
- f9t §8 dev setup → spikes: zpw virtual clients, 43t cyst autonomy,
  8bw tunnel placement

## Dev environment (§8 — verified 2026-09-17)
- **SOURCE OF TRUTH for NS2 game lua = build 344 installed server:**
  `/mnt/d/games/ns2-server/ns2/lua` (650 files incl. `bots/` AI framework).
  The `/mnt/d/projects/ns2-td/research/laststand` clone is STALE (556 files,
  old balance values, no lua/bots/) — use for historical/mod reference only.
- Game: `C:\Program Files (x86)\Steam\steamapps\common\Natural Selection 2`
  → WSL: `/mnt/c/Program Files (x86)/Steam/steamapps/common/Natural Selection 2`
- Mod tools: `x64/Editor.exe`, `x64/Builder.exe`, `x64/Decoda.exe` (lua IDE/debugger)
- Dedicated server: `D:\games\ns2-server` (steamcmd app 4940, anonymous;
  steamcmd at `D:\games\steamcmd`). Launch/drive via powershell.exe from WSL.
- Reference mods NOT subscribed in-game (fine): sources live at
  `/mnt/d/projects/ns2-td/research/`; ded server fetches workshop mods on demand.
- Workshop dir (151 items): `steamapps/workshop/content/4920/`

## Layout (i0a, canonical — repo source/ is truth; dev/deploy.sh syncs to server)
```
source/lua/shine/extensions/hordemode/
  shared.lua         -- Plugin def, data table, constants
  server/
    init.lua         -- lifecycle, world-ready gate, commands, orchestration
    config.lua       -- DefaultConfig, validators, Maps deep-merge, migrations
    statemachine.lua -- Inactive/Wave/Intermission/Teardown
    registry.lua     -- HordeRegistry: everything we spawn (teardown truth)
    takeover.lua     -- BotTeamController lock/snapshot/restore
    placement.lua    -- procedural tunnel-mouth selection (pure fns)
    spawner.lua      -- mouths (TunnelEntrance) + bots (PlayerBot recipe)
    waves.lua        -- composition, clear detection, intermission
    triggers.lua     -- /horde gates + loss predicates
    economy.lua      -- v0 wave-clear payout
    hud.lua          -- ScreenText (server-driven)
source/lua/shine/extensions/hordetest/   -- headless scenario harness (dev cfg only)
dev/                   -- deploy.sh, server-start/stop.sh, test.sh, horde-test-cfg/
```
Deploy target (dev): `C:\Users\aria\AppData\Roaming\Natural Selection 2\workshop\content\4920\117887554\lua\shine\extensions\`

## Implementation tracking
Phase 1 plan: vault `plans/impl-phase1-vertical-slice.md` (validated).
Beads: epic chain IMPL-0..IMPL-10 (ect→…→ay0), strictly sequential;
`bd ready` shows the next bead. Workflow: claim → tests-first → implement →
harness green → one conventional commit → bd close w/ deviation notes.
