# DESIGN.md — Seeding Horde Mode

Canonical design specification for the NS2 seeding-minigame "Horde Mode".
Status: **design phase complete, pre-implementation** (2026-09-17).

Decision history lives in the Obsidian vault (ADR-style notes, Q1–Q25):
`Atlas/Projects/ns2-tower-defense/` (decisions/, design/, discussions/,
research/, reference/). This document consolidates; the vault remains the
record of *why*. Beads (`.beads/`, epic f6x) track work.

---

## 1. Concept

**One paragraph:** While an NS2 server is seeding (marines only, below seed
max), any marine can type `/horde` to start an endless alien-bot siege of
the marine main base. Waves scale along a piecewise bezier difficulty curve
until either all marines die simultaneously, the Command Center is
destroyed, an alien player joins, or seed max is reached — at which point
the mode is **completely torn down, as if it never existed**, and the
server resumes normal seeding. The score is waves survived. There is no win
condition. It is a Last Stand fantasy: one marine base, the whole map
alien, hold as long as you can.

**Design pillars** (locked, see vault `decisions/`):
1. Seeding-gated: runs only while marines-only and seed max not met.
2. Complete teardown: "as if it never existed" — entity-list diff against
   pre-`/horde` state must be empty (testable invariant).
3. Endless waves, no win condition; loss = all marines dead simultaneously
   OR CC destroyed. Score = waves survived.
4. Bot hordes spawn from tunnel mouths; eggs are not a design feature.
5. Per-type AI governance: default hunts players, some types siege the CC,
   all chew obstructing structures.
6. All vanilla maps; marine CC at team spawn is the base.
7. Dual economy: team res (chair, intermission) + personal res (kills).
8. Wave orchestration is the core product: timings, composition, difficulty.
9. Bezier difficulty methodology: all scaling is mathematically computed
   from config data — curves as data, never hardcoded.
10. Player creativity is a pillar: ban-list, not allow-list. Only forbid
    what breaks invariants; difficulty assumes optimized play.

## 2. Lifecycle state machine

```
                    (any marine types /horde,
                     seeding-gate checks pass)
        ┌──────────────┐          ┌──────────────┐
        │   INACTIVE   │─────────▶│  WAVE (n)    │◀──────────┐
        │ (normal seed)│          │ bots active  │           │
        └──────────────┘          └──────┬───────┘           │
               ▲                         │ all bots dead     │
               │                         ▼                   │
               │                  ┌──────────────┐  timer/   │
               │   full teardown  │ INTERMISSION │  paid     │
               └──────────────────│ (chair open, │  skip ────┘
                 (instant, any    │  build phase)│   (+bonus ∝ time skipped)
                  trigger below)  └──────────────┘
```

**Entry (`/horde`)** — gate checks, in order:
1. Seeding state: no alien players, seed max not reached.
2. Caller is on marine team (any marine; min players = **1** — solo-playable
   while waiting for others).
3. Not already running; not in post-teardown cooldown (config, default ~60s).

**No intermission before wave 1** — waves are the warm-up; action starts
immediately (Q20). First intermission follows wave 1 clear.

**Teardown triggers** (instant, complete):
- A real (non-virtual) client joins the alien team — the core seeding
  contract. Distinguish via `player:GetClient():GetIsVirtual()`; our own
  bots are virtual clients and must NOT self-trigger.
- Seed max reached server-wide.
- Loss: all marines dead at the same instant, OR CC destroyed.
- Admin `sh_horde_stop`.

**Teardown procedure** (Last Stand lesson: single choke point + central
registry):
1. Set state = TEARDOWN (idempotent; blocks re-entry).
2. Destroy every entity in the HordeRegistry (bots, tunnel mouths, prebuilt
   hives/RTs/cysts, horde-placed structures).
3. Restore marine-side state: team res, personal res, loadouts, IPs, RT
   income, power — snapshot taken at `/horde` time; respawn players on their
   pre-horde teams as vanilla seeding would.
4. Cancel all Shine timers; eject chair occupants.
5. Assert: server entity list diff vs snapshot == empty (logged; test hook).
6. Announce in chat; apply start cooldown.

**Late joiners** while horde runs: chat notification + ScreenText banner
("Marines are in HORDE MODE — wave N"); they spawn as marines into the
defense (Q14).

## 3. Map frame (Last Stand setup)

At `/horde`, the server sculpts the map (all tracked in HordeRegistry):
- **Marine main base:** CC + command chair at team spawn; main-base RT
  present but **harvests nothing** (team income = wave payouts only);
  powered (RT provides power; power-node extent configurable — base node
  prebuilt at minimum). Single CC: weldable, **never rebuildable**. IPs
  rebuildable during intermission with team res.
- **Alien side:** ALL authored hive spots (except marine base) prebuilt with
  **invincible hives**; all alien RTs (refineries) prebuilt. Count of spots
  per map is irrelevant — prebuild whatever exists (Q18).
- **Infestation:** natural vanilla behavior — hives auto-grow their initial
  cyst rings at start (verified in source: `AlienTeam.lua:222-244`, no comm
  needed); ongoing cyst chaining is a support-comm action = difficulty lever
  (Q21↔Q25 tie-in; full analysis in vault `discussions/td-infestation-behavior`).
- **Tunnel mouths (DECIDED Q26–Q29, see vault
  decisions/td-tunnel-mouth-system.md):** real destructible spawn portals
  near the base — unpaired vanilla `TunnelEntrance` entities (1000 HP/100
  armor baseline, mouth model, no teleport pairing). Placed procedurally at
  `/horde`: pool of 5–8 validated points (pathing-sampled around CC in band
  ~[56m,90m] + cyst points + adjacent-room Location origins; never inside base
  room; sector-spread; GetPathPoints-validated to CC). Active subset
  ~3 per wave, **re-drawn every wave**; destroyed mouths rebuilt at
  intermission. Killing all active mouths mid-wave = marine bonus + early
  wave end; mouth HP rides difficulty curve (wave-1 near-indestructible
  mandate). Bots **stream to base immediately** — no guards, no loitering;
  constant base pressure is the difficulty instrument. Wave-preview HUD
  telegraphs next wave's active mouths. Per-map overrides for stubborn maps.
- **Building bounties:** destroying any alien building pays a **one-time
  team-res bounty** (refinery = large bonus). No respawn farming. Deep pushes
  are allowed but naturally low-value (creativity pillar: don't wall players
  in).

## 4. Waves & difficulty model

Full spec: vault `research/td-ns2-difficulty-levers.md` (54 levers, 30 with
source-cited vanilla values). Summary:

**Piecewise bezier flow** (Q12): four segments joined at configurable wave
thresholds; each scaled quantity = cubic bezier over normalized wave
progress t=(wave−1)/(N_ref−1) between configured endpoints:
1. **Warmup:** skulks only; count/composition carry mild challenge; fun to
   shoot.
2. **Ramp:** ease-in-ease-out; new lifeforms/abilities unlock on a fixed
   cadence (BTD6 precedent: new archetype every ~20 rounds) — *composition*
   carries difficulty here, not raw stats.
3. **Plateau:** near-endgame; slow build; magnitude roughly flat, variation
   high (composition shuffles, ability mixes, comm pressure, pacing changes).
   This is our differentiator — no studied TD has a true plateau.
4. **Linear tail:** endless; stats (HP/armor/damage multipliers) climb
   linearly with headroom to keep "slightly difficult" honest; variation
   remains the primary interest axis (OMD3 precedent: +8%/wave → +20% @w30
   → +40% @w40 stepped linear growth).

**Balance target:** bot wave effective HP (count × HP × armor factor) vs
marine sustained DPS (damage × fire rate × reload uptime × players ×
calibrated accuracy factor) — ratio band ~1.0–1.25 ("always slightly
difficult"); exact bands per segment in the levers note §2.

**Key source facts** (from laststand snapshot):
- Carapace *replaces* armor with zero speed penalty → armor-tier unlocks are
  free stat steps; partial-carapace machinery exists for multi-tier scaling.
- Regen upgrade is combat-damped (×0.2) → healing bots can't become
  unkillable.
- Mucous membrane infestation speed bonus is zeroed in current build → free
  reactivatable lever.
- Res income 1/6s per RT, team cap 200; marine respawn 7s.

**Player-count normalization:** dynamic (option c) — re-read marine count at
each wave start; scale horde size via bezier-tuned f(n) primarily, HP
secondarily (~+0.15/extra player); no mid-wave rescale. Seeding rosters are
volatile; spawner just takes numbers, so this is cheap.

**Bot AI governance** (Q16): per-type config — `focus = players | cc`;
obstructing structures always attacked.

**Bot implementation (VERIFIED LIVE 2026-09-18, build 344, spike e8o):**
spawn recipe = `Server.CreateEntity(PlayerBot.kMapName)` +
`bot:Initialize(team, active)` + `bot.lifeformEvolution = kTechId.<type>` →
live Skulk (or forced lifeform) on team 2, no Location.lua crash, brains
run autonomously (vanilla pathing/combat active with zero orders given).
Teardown = `bot:Disconnect()` (DisconnectClient + DestroyEntity), clean.
**Bot-killer gotcha:** `BotTeamController.lua:172` wipes ALL bots when
humanCount==0 — lock it with `DisableUpdate()` on takeover (already our
7q7 decision). GameState stays WarmUp while our bots live; horde operates
inside WarmUp. `Server.GetBotPlayerCount()` unreliable — HordeRegistry is
the accounting source of truth. Per-lifeform brains (SkulkBrain etc.),
`AlienCommanderBrain`, aim/accuracy systems available for governance +
difficulty tuning; objective-forcing (GiveOrder / horde-brain override for
Q16 hunt-players vs siege-CC) is implementation work. Full findings:
vault `research/td-vanilla-warmup-and-bot-framework.md` §7.

**Vanilla WarmUp interaction (DECIDED 2026-09-18):** build 344 has a WarmUp
game state — below 12 humans, `BotTeamController` fills both teams with
filler bots (config `filler_bots`). **`/horde` IS the horde warmup — full
takeover:** on start, suppress vanilla bot controller (`SetMaxBots(0)` +
`DisableUpdate`, snapshotting prior state), spawn only horde bots. On
teardown: restore whatever came before (vanilla WarmUp/filler behavior
returns untouched) — the "as if it never existed" invariant extended to
bot-management state. Teardown trigger distinguishes OUR bots
(HordeRegistry) from any other virtual client. Bead 7q7 CLOSED.

## 5. Economy

**Team resources** (chair spending, intermission only):
- Wave-clear payout: climbs forever on a bezier with **soft natural ceiling**
  — always somewhat constrained; never infinite money (Q24). Payout curve is
  itself a difficulty parameter (tuned against bot power curve). Optional
  BTD6-style mild deflation in the tail (WS2 adopt-list).
- Skip-intermission bonus ∝ time skipped (Q17).
- Building bounties (one-time, team pool; refinery large).
- Marine main-base RT harvests nothing.
- Chair: usable during intermission only; auto-eject at wave start.

**Personal resources** (NS2Combat pattern, validated by WS1):
- Kill bounties per alien type → personal pres; spend at armory/prototypes
  (vanilla buys). Server-authoritative only.

**Anti-patterns rejected** (WS2): interest on reserves (DG2 removed it —
rewards hoarding), lives-based leak accounting, punishment of aggression.

## 6. Support comm (alien side)

The alien "commander" is a **server-orchestrated support unit**, not a
builder of record (Q25):
- Abilities: drifter hallucinations/heal, crag heals, shift speed — cast in
  support of waves.
- Resource income scales with the difficulty gradient → more/stronger
  support at higher waves; cyst-chain spreading (infestation growth) is one
  of its resource sinks.
- v1 implementation: easiest that works — scripted per-wave "support
  patterns" preferred over autonomous comm AI; configurable.
- **Build-344 update:** the game ships `AlienCommanderBrain` (+ _Data/
  _Senses/_TechPathData/_Utility) — a production alien commander bot AI.
  Candidate path: run an AlienCommanderBrain-driven comm bot with resource
  income as the difficulty dial, instead of hand-scripting patterns.
  Evaluate in bead e8o re-spike; scripted patterns remain the fallback.
- Caution (spike zpw): hallucinations vs our own bots' target selection —
  verify bots ignore them or gate the ability.

## 7. Commands & surface

| Command | Perm | Function |
|---|---|---|
| `/horde` | any marine (handler-gated) | start (seeding checks, cooldown) |
| `sh_horde_stop` | admin | instant teardown |
| `sh_horde_skip` | admin/chair | skip intermission (paid bonus applies) |
| `sh_horde_setwave` | admin | jump to wave N (tuning) |
| `sh_horde_reload` | admin | hot-reload balance config (spike: verify path) |

HUD (zero custom client lua for v1): Shine ScreenText (wave counter,
intermission countdown, "HORDE ACTIVE" banner for joiners) + data-table
broadcast (WaveNumber, WaveState, IntermissionEndsAt). Adopted from WS2:
wave-preview line ("next: 12 skulks / 2 lerks") and milestone broadcasts
every 5 waves (join-hooks for seeders: "wave 12 reached!").

## 8. Config (configurability is the product)

Shine extension `hordemode`, config `HordeMode.json` — validated JSON
(Shine.Validator clamps every knob), versioned (`ConfigMigrationSteps` from
1.0), per-map overrides via our `Maps.<mapname>` deep-merge convention
(Shine has no per-map layer; we own ~30 lines).

**Curves as data:** every bezier = endpoints {Start, End} + control points
[x1,y1,x2,y2] + segment wave range. The offline visualizer reads the same
JSON the server loads.

Starter schema (full proposal in levers note §6):
```jsonc
{
  "__Version": "1.0",
  "Start": { "CooldownSeconds": 60, "MinPlayers": 1 },
  "Intermission": { "Seconds": 60, "SkipBonusPerSecond": 0.5 },
  "Difficulty": {
    "Segments": {
      "Warmup":  { "Waves": [1, 5],   "HordeSize": {"Start":4,"End":10,"Bezier":[0.42,0,0.58,1]},
                   "Types": ["Skulk"] },
      "Ramp":    { "Waves": [6, 15],  "Unlocks": [ {"Wave":6,"Type":"Gorge"}, {"Wave":9,"Type":"Lerk"},
                   {"Wave":12,"Type":"Fade"}, {"Wave":15,"Type":"Onos"} ] },
      "Plateau": { "Waves": [16, 30], "Variation": true },
      "Tail":    { "Waves": [31, null], "HPMultPerWave": 0.08, "ArmorStepWaves": 10 }
    },
    "PlayerScaling": { "Mode": "dynamic", "SizeBezier": [0.42,0,0.58,1], "HPPerExtraPlayer": 0.15 }
  },
  "Payout": { "WaveClear": {"Start":10,"End":40,"Bezier":[0.25,0.1,0.25,1],"Ceiling":40},
              "Bounties": { "Refinery": 25, "Default": 5 } },
  "Governance": { "Skulk":"players", "Onos":"cc", "Default":"players" },
  "SupportComm": { "IncomePerWave": {"Start":5,"End":30}, "Patterns": "scripted" },
  "Tunnels": { "Placement": "procedural", "PoolSize": 6, "ActivePerWave": 3,
               "MinDistFromCC": 56, "MaxDistFromCC": 90,   // spike tby: summit's reachable near-base ring is 56-80 m; the pre-spike 20-25 m guess selects nothing on any vanilla map (see MODDING.md §7, §8.7)
               "HPCurve": {"Start": 4, "End": 1, "Bezier": [0.25,0.1,0.25,1]},
               "KillAllBonus": 30, "RebuildOnIntermission": true },
  "Teardown": { "AssertEntityDiff": true },
  "Maps": { "ns2_summit": { "Tunnels": { "Overrides": [] } } }
}
```
(Numbers are placeholders for the balance pass — the schema shape is the
decision.)

## 9. Telemetry & tuning loop

Collect per run: waves survived, per-wave TTK, leak rate (bots reaching
CC), marine deaths, bounty events, payout/spend totals. Loop: playtest →
telemetry → adjust bezier control points in JSON → re-run offline
visualizer → redeploy. Accuracy-factor in the DPS model is calibrated from
telemetry, not guessed. Durable stats only (voterandom discipline); never
persist transient horde state.

## 10. Invariants (the contract)

1. **Seeding contract:** horde never blocks a real round; alien join =
   instant teardown; virtual-client filtering must be airtight.
2. **Teardown integrity:** post-teardown entity diff = empty; timers all
   destroyed; economy/teams/loadouts restored to snapshot.
3. **No-win, no-loss-loop:** endless until loss/trigger; loss = simultaneous
   marine wipe OR CC death. CC weldable, never rebuildable.
4. **Server-authoritative:** all economy, wave state, spawn decisions.
5. **Config-validated:** bad JSON degrades to defaults, never crashes.
6. **Perf floor:** bot counts/pacing must hold server framerate on a
   24–32 slot machine (measure in spikes).

## 11. Implementation plan

Shine extension layout (repo):
```
lua/shine/extensions/hordemode/
  shared.lua     -- Plugin def, SetupDataTable, network msgs, ScreenText keys
  server/
    init.lua     -- state machine, command bindings, lifecycle
    registry.lua -- HordeRegistry: every spawned/modified entity (teardown)
    waves.lua    -- orchestrator: bezier evaluation, composition, pacing
    spawner.lua  -- tunnel mouths, virtual-client bots, governance
    economy.lua  -- payouts, bounties, kill pres, skip bonus
    support.lua  -- alien comm support patterns
    config.lua   -- schema, validators, Maps deep-merge, migrations
  client.lua     -- minimal (ScreenText is server-driven)
balance/         -- visualizer tool + curve JSON experiments
```

**Spike order** (beads): ~~zpw virtual clients~~ DONE (see §4 bot
implementation — revised: use vanilla PlayerBot framework, bead e8o
re-spike) → 8bw tunnel placement algorithm → then vertical slice: `/horde`
→ wave 1 skulks → intermission → teardown, on the local ded server
(runbook: vault `reference/td-dev-environment-runbook.md`). Headless bot
testing confirmed working (no human needed once config is valid).

**Definition of done (design epic f6x):** this document + vault corpus +
spike findings. Implementation gets its own epic/beads.

## 12. Open items

- Infestation final call (options A–D in vault discussion; A=natural is
  provisional and now precisely defined post-43t).
- Wave-payout scaling exact shape (flat vs bezier vs deflation tail) —
  balance pass with visualizer.
- Support comm autonomous vs scripted patterns (v1: scripted, easiest wins).
- Power-node prebuild extent (minor, configurable).
- Live config hot-reload path; chat prefix `!` vs `/`; recursive-merge
  helper (small implementation spikes).
- Notification surface beyond chat+ScreenText (post-v1).
- Balance spreadsheet artifact + accuracy-factor calibration (post-first-
  playtest).
- `ns2_tow_summit_defense` workshop TD map — examine as direct prior art.

## Sources

Vault: `Atlas/Projects/ns2-tower-defense/` — decisions (5 notes, Q1–Q25),
design/td-player-creativity-philosophy, discussions/td-infestation-behavior,
research/{td-shine-configurability-dive, td-mod-case-studies,
td-tower-defense-case-studies, td-ns2-difficulty-levers,
td-creativity-research-questions, td-research-backlog},
reference/td-dev-environment-runbook.
Research clones: `/mnt/d/projects/ns2-td/research/{shine,laststand,combat}`.
