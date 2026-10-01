# DESIGN.md — Seeding Horde Mode

Canonical design specification for the NS2 seeding-minigame "Horde Mode".
Status: **design COMPLETE and largely SHIPPED** (M0–M5 + M7; the wave loop, the type ladder,
two loss triggers, instant builds — 2026-09-30). This is the
spec; `HANDOFF.md` §8 records what is built vs still planned (i5b walk-verdict, i8a remainder
`7x3`, i9a, i16), and drift is reconciled
toward the code, not the reverse.

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
3. Not already running; not in post-teardown cooldown (config, default **5 s** since 2026-09-28 — a spam brake only; `/horde restart` clears the wait outright, it being the command whose meaning is "start again").

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
3. **Touch no player** (amended 2026-09-28 from Arian's live playtest): `ResetGame` resets every
   player that has a client **in place** and touches no team number, so humans wake in warmup on
   the team they chose — the pre-2026-09-27 "respawn players on their pre-horde teams" step (and
   the day-long spectator-move amendment) are both retired. Full restore of team res / personal res
   / loadouts / IPs / RT income / power from a `/horde`-time snapshot is Phase 2 (logged, not
   guessed, in v0). See §4's ordered teardown.
4. Nudge the vanilla bot refill: fire `UpdateBots()` **once, after the reset** (5m5, 2026-09-29) —
   a stop produces none of the join/leave/SetMaxBots events vanilla fills on, so without the nudge
   the restored cap sits unfilled and warmup bots never return.
5. Cancel all Shine timers; eject chair occupants.
6. Assert: every id we ever registered stops resolving (logged leak poll; test hook).
7. Announce in chat; apply the 5 s start cooldown (which a `restart`, not a bare `/horde`, clears).

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
  cyst rings at start (verified in source: `AlienTeam.lua` ~497-534 — cyst loop, no comm
  needed); ongoing cyst chaining is a support-comm action = difficulty lever
  (Q21↔Q25 tie-in; full analysis in vault `discussions/td-infestation-behavior`).
- **Tunnel mouths (DECIDED Q26–Q29, see vault
  decisions/td-tunnel-mouth-system.md):** real destructible spawn portals
  near the base — unpaired vanilla `TunnelEntrance` entities (1000 HP/100
  armor baseline, mouth model, no teleport pairing). Placed procedurally at
  `/horde`: a pool of 5–8 points that pass **the engine's own build validation** — the same
  three questions a commander's cursor asks (`BuildUtility.GetIsBuildLegal`): snap to ground
  with `GetGroundAtPointWithCapsule`, require nav-mesh `PolyFlag_Walk` and not
  `PolyFlag_NoBuild`, then reject if the structure capsule overlaps the world. Anchor sources
  are infestation portals, cyst points and adjacent-room Location origins, in band
  ~[56m,90m] from CC, never inside the base room, sector-spread, pathed to CC.
  **A raw anchor origin is a volume marker, not a floor** — before the gate existed a marine
  found all three mouths in solid rock and in an unreachable vent, while every geometric
  check we had passed. Active subset ~3 per wave, **re-drawn every wave**; destroyed mouths
  rebuilt at intermission. Killing all active mouths mid-wave = marine bonus + early
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

**Wave model v1 — SHIPPED 2026-09-30 (Q31 composition ladder, Q32 instant build).**
The three curves the loop actually loads, all keyed to `t = Progress(wave, ReferenceWave)`:

| knob | shape | ships | semantics |
|---|---|---|---|
| `Waves.Composition` | bezier Start→End | ENABLED 3→15 @ `ReferenceWave` 20 | aliens dealt this wave (rounded, ≥1) |
| `Economy.WaveClearPayout` | bezier Start→End | ENABLED **5→40** @ `PayoutReferenceWave` 10 (Q33: 25→100 was "too much res" from the chair) | team res paid at wave end; the cap is the "sensible max", the meanness is the point — useful upgrades should land wave 3-4 |
| `Waves.Types.<T>` | `Unlock` + `Ramp` + `Weight` | skulk 1/1/6 · gorge 3/4/1 · lerk 5/4/1 · fade 7/5/1 · onos 10/6/2 | `Waves.Deal`: share(T) = Weight × min(1,(w−Unlock+1)/Ramp), normalised, largest-remainder split of the wave size, **every unlocked type gets ≥1** (an unlock that rounds to 0 is not an unlock), interleaved so round-robin dealing cannot cluster a type behind one mouth |

**Power vs damage — why those unlock waves** (all values from shipped Balance/BalanceHealth/
DamageTypes, build 344). Marines under Q32 (autobuild: builds force-complete on the construct
tick, research clamps to 0.5 s — costs still paid) convert resources into power with no clock;
the only gate is cumulative team res. Cumulative at wave start ≈ 60 (vanilla) + Σ payout(5→40):
w3 ≈ 74, w5 ≈ 108, w7 ≈ 165, w10 ≈ 277 — extractor income on top, not modelled. Marine EHP =
100 hp + 2×armor vs Normal: **L0 160 → L1 200 (20 res) → L2 240 (30) → L3 280 (40)**; exosuit
is a 320+ armor pool (20 tech + 40 personal buy). The first real power spike (arms lab + L1 +
weapons1 ≈ 60) lands wave 4-5 — the Q33 intent, "get through a few waves before useful
upgrades". Alien pressure per rung: skulk bite **75** (2.1 L0-hits → the wave-1 chuff);
gorge spit **30** at range + bile **55/s Corrode** (eats the armor pool itself: 0.12 marine
scalar) → arrives w3, before L1 is routine — early armour pressure is deliberate; lerk bite
**60**+poison and spores **15/s Gas that ignores armor entirely** → w5, punishing the
clustering that L1+shotgun produce; fade swipe **75 effective** (Puncture ×2 vs players) and
stab **120 Structural** (two L3-hits) → w7, as L3+weapons2 (~90 more) arrive; onos gore **90
Structural** + stomp **40 Heavy at half armor efficiency** + charge-latch → w10, the wave
exosuits become affordable (~277 cumulative). Mouths stay near-indestructible wave-1 (Q29
`MouthHealth` 1000→4000, still disabled until RD3).

**Balance target stays** (§4 above): wave effective HP vs sustained marine DPS in the
1.0–1.25 band; the ladder sets WHO, the curve sets HOW MANY, RD3 tunes endpoints against
playtest telemetry — every number in this block is a placeholder with a shape we trust.

**Q32, instant build (Arian 2026-09-30):** during a horde the vanilla `autobuild` gamerule is
engaged (snapshot → `SetAutobuild(true)`), restored at teardown by the same
release-only-what-you-took discipline as the controller and the win switch. Chosen over
per-structure `SetConstructionComplete` sweeps (the engine's own tick already force-completes
under the flag — one lever, zero polling of other people's entities) and over `SetAllTech`
(that deletes the resource sink the payout curve feeds).

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
**Death is release (Q30, 2026-09-30):** a killed bot's client is disconnected by the next
tick — the reaper takes every NON-alive bot entry (`Disconnect` + unregister, pcall-guarded
for Gone refs) — and bots are never reused or respawned; every wave spawns fresh entities.
Corpses left on the roster inflate the headcounts `force_even_teams_on_join` balances
against and could revive if a real alien ever built a spawn structure; the id history keeps
the record for teardown's leak poll. Suppression + our own loss triggers make the empty
alien team harmless to win/loss (vanilla would DRAW, measured). The same chair session
amended line 186: "brains run autonomously" is true of COMBAT only — the skulk brain has no
roam action and ignores the order queue, so the objective is ours to write
(`GetMotion():SetDesiredMoveTarget`, the t28 steer).
**Bot-killer gotcha:** `BotTeamController.lua:172` wipes ALL bots when
humanCount==0 — lock it with `DisableUpdate()` on takeover (already our
7q7 decision). GameState stays WarmUp while our bots live; horde operates
inside WarmUp. `Server.GetBotPlayerCount()` unreliable — HordeRegistry is
the accounting source of truth. Per-lifeform brains (SkulkBrain etc.),
`AlienCommanderBrain`, aim/accuracy systems available for governance +
difficulty tuning; objective-forcing (GiveOrder / horde-brain override for
Q16 hunt-players vs siege-CC) is implementation work. Full findings:
vault `research/td-vanilla-warmup-and-bot-framework.md` §7.

**Build-344 correction (2026-09-28, i5a / `bot_factory_settles`):** the recipe above lands bots on
team 2 only while vanilla's balance gate permits the join. With `force_even_teams_on_join` set in
`ServerConfig.json` — it is set on the dev tree — `NS2Gamerules:GetCanJoinTeamNumber`
(`:1385-1423`) refuses any join that would unbalance the teams, `Bot:UpdateTeam` retries forever,
and the surplus aliens sit at team 0 *reporting alive* (the bot's pre-join player waits in the
ready room — team 0 is `kTeamReadyRoom`, `Globals.lua:119` — and it answers `GetIsAlive() == true`;
"alive" never implied "joined"). The horde is deliberately
unbalanced — that is what the 7q7 takeover means — so the factory forces its own join:
`JoinTeam(player, 2, true)`. A forced join replaces the player with `AlienTeam.respawnEntity =
Skulk` (`AlienTeam.lua:48`) in the same tick — the lifeform class is real immediately, no evolve
race. Full fact: HANDOFF §5.16.

**Vanilla WarmUp interaction (DECIDED 2026-09-18):** build 344 has a WarmUp
game state — below 12 humans, `BotTeamController` fills both teams with
filler bots (config `filler_bots`). **`/horde` IS the horde warmup — full
takeover:** on start, suppress vanilla bot controller (`SetMaxBots(0)` +
`DisableUpdate`, snapshotting prior state), spawn only horde bots. On
teardown: restore whatever came before (vanilla WarmUp/filler behavior
returns untouched) — the "as if it never existed" invariant extended to
bot-management state. Teardown trigger distinguishes OUR bots
(HordeRegistry) from any other virtual client. Bead 7q7 CLOSED.

**Teardown order (DECIDED 2026-09-27; AMENDED 2026-09-28 from Arian's live playtest, restoring
Q7's "players stay on chosen team"):** the handback is an ordered sequence, because two of its
steps can end the game if they happen in the wrong order —
`destroy our created set` → `release the bot takeover` → `reset the world (ResetGame → NotStarted)`
→ **touch no player** → `release the win switch (preventGameEnd)`.
Releasing the switch into a `Started` round with no aliens is precisely a marine win plus a map
rotation (fact: `GetGameStarted()` is `kGameState.Started` and nothing else), which is what
`/horde stop` did in the first playtest. Humans stay where they are: `ResetGame` resets players
that have clients **in place** (`NS2Gamerules.lua:530`) and touches no team number, so after a
stop everyone is back in warmup on the team they chose — the phase the server was in before
`/horde`. The 2026-09-27 step that moved humans to spectator was wrong (the team a player chose
is theirs); if warmup landing ever proves broken the sanctioned fallback is the ready room
(`kTeamReadyRoom`), never spectator. **Bots are left to vanilla** — but *not* to the controller's
own devices: it fills only when `UpdateBots` runs (join/leave/SetMaxBots events), and a stop fires
none, so teardown sends the one nudge (§4 step 4 / 5m5). Moving a bot would make it stop counting,
get replaced, and strand — but nothing moves anyone now.

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

| Command | Perm | Status | Function |
|---|---|---|---|
| `/horde` (bare) / `/horde start` | any marine (handler-gated) | **shipped** | gated start (seeding checks; 5 s cooldown on bare starts) |
| `/horde status` / `sh_horde_status` | marine / admin | **shipped** | the one-line truth (state, mouths, humans, takeover, reveal) |
| `/horde stop` / `sh_horde_stop` | marine / admin | **shipped** | instant ordered teardown |
| `/horde restart` | any marine | **shipped** | teardown → clear the pending wait → start again from a clean slate |
| `sh_horde_skip` | admin/chair | planned (i6b) | skip intermission (paid bonus applies) |
| `sh_horde_setwave` | admin | planned (i6a tuning) | jump to wave N |
| `sh_horde_reload` | admin | planned | hot-reload balance config (spike: verify path) |

HUD (zero custom client lua for v1): Shine ScreenText (wave counter,
intermission countdown, "HORDE ACTIVE" banner for joiners) + data-table
broadcast (WaveNumber, WaveState, IntermissionEndsAt). Adopted from WS2:
wave-preview line ("next: 12 skulks / 2 lerks") and milestone broadcasts
every 5 waves (join-hooks for seeders: "wave 12 reached!").

## 8. Config (configurability is the product)

Shine extension `hordemode`, config `HordeMode.json`. Validation is **ours, not Shine's**:
`config.lua`'s `PreValidateConfig`→`Sanitize` clamps and defaults every knob (the `Shine.Validator`
rule objects are deliberately *not* used — see `config.lua` header), and there are no
`ConfigMigrationSteps` in the shipped path. Per-map overrides via our own `Maps.<mapname>`
deep-merge (Shine has no per-map layer; we own ~30 lines).

**Curves as data:** every bezier = endpoints {Start, End} + control points
[x1,y1,x2,y2] + segment wave range. The offline visualizer reads the same
JSON the server loads.

**Proposed** starter schema — the **normative** shape is `Plugin.DefaultConfig` in
`config.lua` (keys there differ: tunnels live under `Waves.*`, payout under `Economy.*`, the
segments model above is M6 design, not loaded config; drift below is historical):

*Shipped since this draft (2026-09-30):* `Waves.Types` (the Q31 ladder), `Economy.WaveClearPayout`
as a curve with `Economy.PayoutReferenceWave`, and `Intermission` **15 s first / 30 s later** (Q33;
Arian's pacing call). `DefaultConfig` remains the only normative shape.
```jsonc
{
  "__Version": "1.0",
  "Start": { "Cooldown": 5, "MinPlayers": 1 },   // key is Start.Cooldown (the schema draft's "CooldownSeconds" never shipped); 5 s since 2026-09-28, was a 60 draft / 0 interim
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
               // Both bounds are WALKING metres from the chair (Pathing.GetPathDistance), because
               // that is the distance a horde actually travels, and every candidate is first asked
               // of the engine's own build gate (walk mesh, no-build, ground snap at the tunnel's
               // extents, capsule overlap) - a Location marker's origin is a volume, not a surface.
               // The "never in base" rule is therefore a SEPARATE straight-line bound, since a
               // route can leave the room, loop, and return: BandLineFactor 0.5 x BandMin.
               // "Procedural" means per-wave, not per-map: the sweep is rotated and its rings
               // jittered from a seed (Placement.SeedFor = wall clock + uptime + wave, logged as
               // seed= so a reported wave can be replayed), and the sector fill takes the leftover
               // FURTHEST from what is already chosen. Bearing sectors alone were satisfied by two
               // mouths 11 m apart in one corridor, and an unseeded grid gave every boot the same
               // three rooms - both reported from the chair, both invisible to assertions that
               // looked at one draw at a time.
               "HPCurve": {"Start": 4, "End": 1, "Bezier": [0.25,0.1,0.25,1]},
               "KillAllBonus": 30, "RebuildOnIntermission": true },
  "Teardown": { "AssertEntityDiff": true },
  // Dev-only. A mouth is a team-2 entity, so its own map blip is relevancy-gated to
  // aliens (MapBlip.lua:82-96) and a marine cannot see where a wave actually landed —
  // which makes placement undiagnosable from the chair. When on, each mouth is marked
  // detected so the ENGINE adds its marine-side SensorBlip: a through-wall screen marker
  // and a minimap icon, no client Lua, no extra entity of ours, and it dies with the
  // mouth (DetectableMixin:OnDestroy). Detection expires 1.5 s after it is asserted, so
  // the 1 s plugin tick re-asserts it. Never a gameplay default: it hands the enemy x-ray
  // information our design does not intend to give them.
  "Debug": { "RevealMouths": false },
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
2. **Teardown integrity:** post-teardown leak poll over every ever-registered id is empty;
   timers destroyed; bot controller released **and nudged to refill**; players untouched (§2.3);
   full economy/teams/loadouts restore is Phase 2 (v0 logs what it does not restore).
3. **No-win, no-loss-loop:** endless until loss/trigger; loss = simultaneous
   marine wipe OR CC death. CC weldable, never rebuildable.
4. **Server-authoritative:** all economy, wave state, spawn decisions.
5. **Config-validated:** bad JSON degrades to defaults, never crashes.
6. **Perf floor:** bot counts/pacing must hold server framerate on a
   24–32 slot machine (measure in spikes).

## 11. Implementation plan

The shipped layout is a repository fact, not a spec decision — it lives in
`WORKFLOW.md §Layout` and `HANDOFF.md §4`, kept in sync with the code. Shape, for the record:
one flat `hordemode/` extension (Shine loads `extensions/<name>/server.lua` as the entry —
no `server/` subdir, no `init.lua`, no client Lua at all: v1 is zero-client-code by §7),
plus the `hordetest/` headless harness and `dev/` loop. The original block here listed
`server/init.lua`, `support.lua` and `client.lua`; none exists, and `support.lua`'s job
moved into §6's AlienCommanderBrain evaluation.

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
