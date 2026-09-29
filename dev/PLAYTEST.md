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
| 8 | Look around after the stop | You are **still on your team**, back in warmup; vanilla filler bots are back on both teams | the handback order — [[td-ns2-round-lifecycle-and-handback]]; moving you was the bug (2026-09-28) |
| 9 | `/horde` again, twice more | Mouth positions **differ** between runs; the log prints a different `seed=` each time | the seeded draw — [[assert-the-guarantee-not-the-hope]] |
| 10 | `/horde restart` right after a stop, then `/horde status` | Restart starts **immediately** — no cooldown wait, no move to spectator; you stay on your team; status reflects the new wave | restart clears the pending wait — `restart_clears_the_pending_cooldown` |
| 11 | `/horde stop` twice in a row | Second is **rejected** (`inactive -> teardown is not a legal transition`), not ignored silently | `statemachine.lua` |
| 12 | `/horde stop`, then bare `/horde` within 5 s | Refused with a counting-down `cooldown remaining`; a later `/horde` starts clean and nothing leaks from the last round | the 5 s brake is a spam guard only (2026-09-28) — teardown completeness (RD6) |

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

- **Nothing walks out of a mouth.** i5a (bot spawner) does not exist yet.
- **There is no wave 2.** i6a (wave loop) does not exist yet.
- **A horde that "ends" cannot end** — i8a (loss triggers) does not exist. Until then, stop it with
  `/horde stop`.
- **Mouths cluster in one sector on summit** — open judgement (`5ss`), not a regression.
- **A `minidump` when the server is stopped** after a suite ran: that is our shutdown, not a game
  crash (`upload-dumps=false` so nothing leaves the box).
- **`Ranking disabled: server has non-whitelisted mods mounted`** in the log: expected on any
  server running our mod.
