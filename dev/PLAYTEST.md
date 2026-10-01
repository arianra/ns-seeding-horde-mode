# Playtest protocol (i10a) — the checks only a human can do

Bead `ns-seeding-horde-mode-0kd`. The headless suite proves mechanics; this file proves **what the
player sees**, which is where every serious defect in this project has actually come from.

## 0. Get a server to join

```bash
cd /mnt/d/projects/ns-seeding-horde-mode
./dev/guard-server.sh            # 0 open sessions before you touch anything
./dev/server-start.sh ns2_summit # joinable boot: hordetest disarmed, RevealMouths on
```

Client: Steam → NS2 → Properties → Launch Options → `+connect 127.0.0.1:27025`
(or `connect 127.0.0.1:27025` in the console). No other launch options — the mod is the published
Workshop item and auto-downloads. **Never** edit anything under `steamapps/**` to make a join work
(`dev/STANDARDS.md`).

## 1. The checklist

Start with a fresh `/horde` and work down. Every line is something the suite cannot see.

| # | Do | Expect | If not |
|---|---|---|---|
| 1 | `/horde` | Announcement names the wave and the mouth count; you spawn after the countdown | `./dev/test.sh` first — the gate is `triggers.lua` |
| 2 | Look at the minimap and the screen | **Every** mouth shows a marine-side blip (`reveal=on` on this boot) | `Debug.RevealMouths`, or the reveal tick is dead — see §3 |
| 3 | Walk to a mouth | It is **on the ground**, reachable, not buried in rock or floating | placement regression → [[td-ns2-structure-placement-rules]] |
| 4 | `/horde status` | `mouths=N/M`, `takeover=engaged`, `reveal=on`, `bots`/`ours` sane | status is a measurement, so a wrong number is a real bug |
| 5 | Kill **one** mouth, wait 3 s | The **other** mouths stay visible; status drops by exactly one | the three-state registry — [[never-dereference-a-stored-handle]] |
| 6 | Kill the **last** mouth | status reads `mouths=0/M`, not `1/M` | the husk state (`GetIsAlive()`), fact 33 in `MODDING.md` |
| 7 | `/horde stop` | No victory/defeat screen. **Same map.** No errors in chat | handback order — [[td-ns2-round-lifecycle-and-handback]] |
| 8 | Look around after the stop | You are **still on your team**, back in warmup | the handback order — [[td-ns2-round-lifecycle-and-handback]]; moving you was the bug (2026-09-28) |
| 8b | After that stop, **wait ~10 s** without joining, leaving, or touching config | Warmup filler bots **return on their own, on both teams**; a later `/horde` still starts | a stop fires none of vanilla's three refill events (join/leave/`SetMaxBots`) — the post-reset `UpdateBots()` nudge (`RefillVanillaBots`, 5m5 chair finding 2026-09-29) is the only thing that refills; empty warmup = the nudge is dead — [[td-ns2-round-lifecycle-and-handback]] |
| 9 | `/horde` again, twice more | Mouth positions **differ** between runs; the log prints a different `seed=` each time | the seeded draw — [[assert-the-guarantee-not-the-hope]] |
| 10 | `/horde restart` right after a stop, then `/horde status` | Restart starts **immediately** — no cooldown wait, no move to spectator; you stay on your team; status reflects the new wave | restart clears the pending wait — `restart_clears_the_pending_cooldown` |
| 11 | `/horde stop` twice in a row | Second is **rejected** (`inactive -> teardown is not a legal transition`), not ignored silently | `statemachine.lua` |
| 12 | `/horde stop`, then bare `/horde` within 5 s | Refused with a counting-down `cooldown remaining`; a later `/horde` starts clean and nothing leaks from the last round | the 5 s brake is a spam guard only (2026-09-28) — teardown completeness (RD6) |
| 13 | `/horde`, sit through the countdown | Chat announces **WAVE 1 - 3 tunnel mouths, 3 aliens incoming (Skulk x3)**; `ours=` climbs from 0 as the tick places them; you see them AT THE ENTRANCE of the mouths, not inside the rock | wave loop v0 — `BeginWave` culls, draws mouths, deals the curve + the Q31 ladder (`wave_math_is_pure`); capsule-fit emergence (`bot_factory_settles` proves walkable ground) |
| 14 | **Watch them move — the tick now pins a standing waypoint to the marine base every second** (t28 answer: skulk brains have no roam action; the chair showed them standing at the mouths) | Bots **walk out of the mouths toward the marine base** and engage marines/structures on the way. NOT: milling at the mouth (steer broken or the tunnel traps them), NOT: map-edge wander | if they still stand AT a mouth: that is geometry, not objective — report which mouth and whether ANY bot left it; if they wander elsewhere: report direction. `steer_pins_the_base_waypoint` proves the target is written; only your eyes prove the walk |
| 15 | Kill a few bots, watch `/horde status` (and the scoreboard) | `ours=` drops live; the bots you kill stay dead and leave no "husk" count; **dead alien names must NOT pile up on the scoreboard/roster** — each kill releases its client within a second (Q30) | registry is the accounting truth (RD6); `reap_frees_the_corpse_only` pins the release; a growing corpse roster means the reaper stopped running |
| 16 | `/horde stop` **immediately after a new `/horde restart`** (bots still queueing), then a second stop→start | No leaked ghost clients: server stays joinable, log shows no orphan bot chatter, `ours=` hits 0 | the early-stop window tests `BornUnregistered`/`BotStillReal` disconnect paths in `DestroyAll` (fixed while writing 71c — this row is its chair twin) |
| 17 | **Finish wave 1 twice, two different ways.** (a) kill every alien; (b) next wave, kill every MOUTH instead | (a) announce: wave 1 cleared, **+25 team res**, intermission 30 s, then WAVE 2 arrives — 4 aliens `(Skulk x4)`, **fresh positions, fresh seed**; (b) mouth-kill ends the wave EARLY with the same intermission chain even while bots still live | the wave loop end-to-end; payout curve + ladder pinned by `wave_math_is_pure` |
| 18 | **Let the swarm destroy the marine command station** (and/or die yourself, staying dead) | Chat: `HORDE OVER - the marine command station was destroyed. Survived N wave(s); back to seeding.` — teardown identical to a stop: same map, you keep your team, bots refill. If every marine stays dead ~3 s, the same happens with "every marine died" | the two loss latches — station must have STOOD first (`wave_math_is_pure` refuses the never-had false positive); grace window is D4's |
| 19 | **Instant build (Q32), both directions.** Start a horde; place a structure and queue an upgrade (arms lab, L1 armor). Then `/horde stop` and build one more thing | During the horde: everything completes in ~1 s while **resources are still deducted**. After the stop: the NEXT build takes its normal vanilla time (the autobuild flag was given back, not left on) | `SetHordeBuildSpeed` snapshot/restore; the engine's own cheat path (`ConstructMixin.lua:133-183`, `ResearchMixin.lua:67-69`) — no custom timer code to rot |

## 2. Capture findings

```bash
L="/mnt/c/Users/aria/AppData/Roaming/Natural Selection 2/log-Server.txt"
grep -a "HORDE\]\|Timer error\|Script error\|FAIL" "$L" | tail -40
```

The `wave 1:` line is the whole placement story — anchors examined, usable, refusal reasons,
walking range, dedupe count, chosen, and `seed=`. Paste it with any report; a seed reproduces the
exact placement.

**Every distinct finding becomes a bead** (`bd create`), not a comment. That is how the last three
rounds were tracked.

## 3. Known non-bugs (do not chase these)

- **Wave sizes, payout endpoints and the type ladder are placeholders, not tuning.** The
  size curve ships ENABLED 3→15 by wave 20; payout 25→100 by wave 10; types unlock gorge w3 /
  lerk w5 / fade w7 / onos w10 with ramp shares (Q31, DESIGN §4 has the power-vs-damage
  reasoning). RD3 tunes all three against playtest telemetry; mouth HP scaling is still off.
  Intermission is 30 s everywhere now (was 60; Arian's pacing call).
- **Wave loop v0 is in; i8a is only partly in.** Marines-wipe and station-destroyed end the horde
  now; a REAL alien joining, seed-max, and the `votesurrender` bypass still do not (i8a's
  remainder, bead `7x3`) — so still don't leave it running where aliens can join.
- **Mouths cluster in one sector on summit** — open judgement (`5ss`), not a regression.
- **A `minidump` when the server is stopped** after a suite ran: that is our shutdown, not a game
  crash (`upload-dumps=false` so nothing leaves the box).
- **`Ranking disabled: server has non-whitelisted mods mounted`** in the log: expected on any
  server running our mod.
