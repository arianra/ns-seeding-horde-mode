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

## Planned layout (Shine extension)
```
lua/shine/extensions/hordemode/
  shared.lua    -- Plugin def, SetupDataTable, network msgs
  server.lua    -- state machine, wave orchestrator, spawner, economy, teardown
  client.lua    -- HUD hooks (ScreenText is mostly server-driven)
config schema: HordeMode.json (validated, versioned, Maps.<name> overrides)
balance/        -- curve data + visualizer tooling (WS3 output)
```
