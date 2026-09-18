# NS2 Seeding Horde Mode

Tower-defense-like seeding minigame for Natural Selection 2 (Spark engine),
integrated with the [Shine](https://github.com/Person8880/Shine) admin framework.

Marines-only seeding servers can opt in (`/horde`) to fight orchestrated bot
alien waves between real rounds. Full design lives in the Obsidian vault:
`Atlas/Projects/ns2-tower-defense/`.

Status: **brainstorm/design phase — no game code yet.**

## Design pillars (locked decisions)
1. Seeding-gated: runs only while marines-only and seed max not met; ends
   instantly on alien join / seed max / loss. Opt-in via `/horde` chat command,
   min 1 player, late joiners notified.
2. **No win condition** — endless waves; stat = waves survived. Loss = all
   marines dead simultaneously OR CC destroyed.
3. Complete teardown: "as if it never existed" — no horde state survives;
   players stay on chosen team, reset to normal seeding.
4. Hybrid hordes: cheap bulk grunts + recycled virtual-client elites,
   spawning from tunnel-mouth props (may exceed vanilla tunnel max).
   Per-type AI governance: default hunts players, some siege CC, all chew
   obstructing structures.
5. Last Stand map frame: action around marine main base; **all authored hive
   spots prebuilt with invincible hives** + all alien RTs prebuilt; marines
   keep only their main-base RT (gathers nothing — team income = wave
   payouts); single CC, weldable but never rebuildable; IPs rebuildable
   during intermission. Destroyed alien buildings pay one-time team-res
   bounties (refineries extra). No pre-wave-1 intermission — action starts
   immediately after /horde.
6. Layer on ALL existing maps: marine CC at team spawn = the base;
   per-map placement configs + automated alien-comm infrastructure.
7. Dual economy: team res at wave end (chair, intermission only, auto-eject
   at wave start) + personal res from kills (NS2Combat-style buys).
   Building-kill bounties → team pool, one-time.
   Intermission fixed length + skippable for time-proportional team-res bonus.
8. Wave orchestration is the core: timings, composition, difficulty.
9. **Bezier difficulty methodology:** all scaling is mathematically computed
   (bot HP/armor/damage vs marine DPS/health/reload); piecewise flow =
   warmup (skulks, easy-but-fun) → ease-in/ease-out ramp → late plateau →
   post-threshold linear endless (variation > raw numbers). Admin-tunable
   control points.
10. v1 = vanilla upgrades only; extended tiers deferred.

## Research workspace
Clones under `/mnt/d/projects/ns2-td/research/`:
- `shine` + `shine-wiki` — admin framework + 665-page wiki
- `laststand` — NS2 game Lua snapshot (incl. old Bot.lua / Bot_Player.lua)
- `combat` — GhoulofGSG9/ns2combat (FileHooks pattern, CombatUpgrade buys)

## Planned layout (when code starts)
```
lua/shine/extensions/hordeseeding/   # Shine extension (config, commands, hooks)
lua/horde/                           # gameplay: waves, bots, economy, teardown
FileHooks/{Pre,Post,Replace}/        # vanilla file hooks (NS2Combat pattern)
config/                              # default + per-map configs
spike/                               # spike #1: virtual client verification
```
