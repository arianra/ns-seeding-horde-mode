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
| 14 | **Watch them move — the tick pins a standing waypoint to the base every second AND rescues bots that stop.** A bot that has not moved 1.5 m within 6 s out of combat is teleported to a fresh capsule-fit point beside where it stood (log: `re-placed a stuck bot`) | Bots **walk out of the mouths toward the marine base** and engage on the way. Occasional mid-walk re-placements are the watch working, not a bug. NOT: the whole wave standing at a mouth through TWO rescue windows (12+ s) — that means the fit itself is trapped | if ALL stay put: report whether the log shows `re-placed` lines and `(capsule-fit)` vs `(JITTER FALLBACK)` at emergence — the two failure kinds need different fixes. `stuck_bots_get_rescued` proves the watch arithmetic; `steer_pins_the_base_waypoint` the waypoint |
| 15 | Kill a few bots, watch `/horde status` (and the scoreboard) | `ours=` drops live; the bots you kill stay dead and leave no "husk" count; **dead alien names must NOT pile up on the scoreboard/roster** — each kill releases its client within a second (Q30) | registry is the accounting truth (RD6); `reap_frees_the_corpse_only` pins the release; a growing corpse roster means the reaper stopped running |
| 16 | `/horde stop` **immediately after a new `/horde restart`** (bots still queueing), then a second stop→start | No leaked ghost clients: server stays joinable, log shows no orphan bot chatter, `ours=` hits 0 | the early-stop window tests `BornUnregistered`/`BotStillReal` disconnect paths in `DestroyAll` (fixed while writing 71c — this row is its chair twin) |
| 17 | **Finish wave 1 twice, two different ways.** (a) kill every alien; (b) next wave, kill every MOUTH instead | (a) announce: wave 1 cleared, **+5 team res**, **intermission 15 s** (the first gap is short by design, Q33), then WAVE 2 arrives — 4 aliens `(Skulk x4)`, **fresh positions, fresh seed**; later intermissions are 30 s; (b) mouth-kill ends the wave EARLY with the same chain even while bots still live | the wave loop end-to-end; payout curve + ladder pinned by `wave_math_is_pure`; first-vs-later wait by `stuck_bots_get_rescued` neighbours + `wave_loop_edges_with_fakes` |
| 18 | **Let the swarm destroy the marine command station** (and/or die yourself, staying dead) | Chat: `HORDE OVER - the marine command station was destroyed. Survived N wave(s); back to seeding.` — teardown identical to a stop: same map, you keep your team, bots refill. If every marine stays dead ~3 s, the same happens with "every marine died" | the two loss latches — station must have STOOD first (`wave_math_is_pure` refuses the never-had false positive); grace window is D4's |
| 19 | **Instant build (Q32), both directions.** Start a horde; place a structure and queue an upgrade (arms lab, L1 armor). Then `/horde stop` and build one more thing | During the horde: everything completes in ~1 s while **resources are still deducted**. After the stop: the NEXT build takes its normal vanilla time (the autobuild flag was given back, not left on) | `SetHordeBuildSpeed` snapshot/restore; the engine's own cheat path (`ConstructMixin.lua:133-183`, `ResearchMixin.lua:67-69`) — no custom timer code to rot |
| 20 | `/horde`, watch **team** res between waves | Resources are **flat** between waves — no passive creep. The only rises are the wave-clear payout and the fixed start. An extractor you build gives the marine team nothing | the closed economy (Q34/Q35): extractor AND vanilla's `UpdateMinResTick` free trickle both suppressed via `ReplaceClassMethod`; a creep means one borrow didn't engage — grep `horde economy: closed` |
| 21 | Kill an alien, watch your **personal** res (armory counter) | It rises by the victim's bounty (skulk/gorge 2, lerk 3, fade 4, onos 5). No personal gain from extractors | the `NS2Gamerules:OnEntityKilled` bounty; if it never moves, the wrapper isn't installed — grep `kill bounty armed` |
| 22 | Get to wave 3+ | Gorges (then lerk/fade/onos at 5/7/10) actually **appear** — not all skulks — with **vanilla HP** (gorge 160, onos 700) | `ForceLifeForm`; if still all-skulk, grep `bot emerged ... (morphed)`; a gorge that dies instantly is the room-at-emergence case (fact 24) |
| 23 | Look across the map for alien hives | An **invincible** hive sits at every tech point except the marine base; you cannot kill it; bots do **not** emerge from hives (only from the mouths) | Q18 frame; grep `horde map frame: N invincible hive(s) prebuilt`; unkillable = the `Hive:GetCanTakeDamageOverride` borrow |
| 24 | At wave 1, look at the marine base | **No infantry portal** at the start (build one if you want it) | the starting-IP clear; grep `removed N starting infantry portal` |
| 25 | (balance work) set `Debug.CombatTelemetry=true`, play, read the log | `[TELEMETRY] first-hit ... / death ... ttk=Ns` lines give **real time-to-kill** per alien — feed them back to tune the curve | health-poll (the damage pipeline can't be hooked, fact 22); `ttk=n/a` = died faster than the 1 s poll caught |

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
  size curve ships ENABLED 4→20 by wave 20 (Q36 first-cut bump from 3→15); payout 5→40 by wave 10
  (Q33: deliberately mean — the first useful upgrades should land around wave 3-4, and vanilla's
  60-start plus extractor income are not ours); types unlock gorge w3 / lerk w5 / fade w7 / onos
  w10 with ramp shares (Q31, DESIGN §4 has the power-vs-damage reasoning). Mouth HP scaling is still
  off. Intermission: 15 s after wave 1, 30 s after (Q33).
- **There is NO per-alien HP/armor/damage scaling, and that is deliberate.** This is a marine
  aiming-training mode: a skulk is always a vanilla 75-HP skulk, or the marine learns the wrong
  time-to-kill (rule 7 / HANDOFF §2, `decisions/td-training-mode-no-stat-scaling`). Difficulty is
  count + which lifeforms ONLY. If you are tempted to buff a bot's stats — don't; use carapace.
- **Wave loop v0 is in; i8a is only partly in.** Marines-wipe and station-destroyed end the horde
  now; a REAL alien joining, seed-max, and the `votesurrender` bypass still do not (i8a's
  remainder, bead `7x3`) — so still don't leave it running where aliens can join.
- **Mouths cluster in one sector on summit** — open judgement (`5ss`), not a regression.
- **A `minidump` when the server is stopped** after a suite ran: that is our shutdown, not a game
  crash (`upload-dumps=false` so nothing leaves the box).
- **`Ranking disabled: server has non-whitelisted mods mounted`** in the log: expected on any
  server running our mod.
