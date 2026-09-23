# PLAN.md — how we continue, and how we stop being sloppy

Written 2026-09-22 after Arian's verdict: *"this is very sloppy overall."* Accurate. This
document replaces ad-hoc patching with a ladder where **every rung is something you can see and
confirm in under a minute**, and it records the debt we're carrying.

Companion docs: `DESIGN.md` (product), `MODDING.md` (mod mechanics, cited), `dev/STANDARDS.md`
(ownership rules), `dev/SCAFFOLDING.md` (procedure).

---

## 1. What is on disk now

One dev root. Nothing is created anywhere else, and nothing we build writes into a mod we
don't own.

```
D:\games\ns2-server                 engine + dedicated server (steamcmd app 4940)
D:\games\steamcmd                   installer
D:\games\ns2srv\cfg                 LIVE server config — ARIAN'S, read-only to us
D:\games\ns2hordetest\              DEV root — ours, disposable
    cfg\                            dev server config (Shine state lives under here)
    mods\                           dev mod storage (-modstorage), isolated since G1d
    overlay\                        the -game overlay: our built mod, mounted by both sides
D:\games\.stale-20260922\           archived junk (see §6)
```

Everything else is in the repo (`~/projects/ns-seeding-horde-mode`), which is the source of
truth. **Rule: if it isn't reproducible from the repo, it doesn't exist.** No hand-editing files
under `D:\games` — `dev/deploy.sh` materialises them.

---

## 2. The gap, stated plainly

What you expect when you type `/horde`: *the server becomes a different game mode.*

What actually happens today: a state machine moves from `inactive` to `wave` mid-round, three
tunnel entrances are created somewhere on the map, **nothing tells you any of this happened**,
NS2's own WarmUp seeding keeps 24 vanilla bots fighting around you, and the only feedback you
get is a chat line when something *refuses*.

That is not a game mode. It is a data structure with a chat command attached. Everything below
exists to close that gap in order.

Three specific defects you caught, all confirmed in source:

| Symptom | Cause | Where |
|---|---|---|
| "why are there bots" | our own dev config pinned `filler_bots: 12, rookie_only_bots: 12` (copied from live, never reconsidered) | `dev/horde-test-cfg/ServerConfig.json` — now 0 |
| "no notice that it started" | success paths only `Log()`; every *rejection* notifies, so feedback is inverted | `hordemode/server.lua` `OnHordeCommand` |
| "killed by alien bots that shouldn't be there" | same as row 1; NS2 WarmUp seeding fills both teams | fixed in config, not yet verified in-game |

---

## 3. Definition of the mode (Arian's spec, written down)

`/horde` must, in order:

1. **Refuse or proceed loudly.** Every command answers; every refusal names its reason.
2. **Clean slate.** End the current round, remove **all** bots (vanilla seeding fill included),
   reset player state, and do it from a known starting condition — not layered on a live round.
3. **Announce it.** "HORDE MODE" on screen for every player, with a countdown, before anyone
   spawns.
4. **Then start the world.** Mouths created and **visible on the marine map/minimap**, timer
   running, wave 1 armed.
5. **Be stoppable and restartable** from chat, with the same clarity.

This **contradicts a prior decision** — Q7q7 recorded `/horde` as "the horde warmup", explicitly
*not* restarting the round, holding vanilla fill off via the bot-controller lock instead. Your
spec is the better product. Adopting it means superseding Q7q7, which is a decision I'm not
making silently — see §7 D1.

---

## 4. The step protocol

Rewritten 2026-09-22 after Arian's verdict that the collaboration isn't working. The failure
pattern is specific and repeatable: I build several things at once, report them as done because
the headless suite is green, and he then finds the feature is absent, wrong, or was never in the
spec. Two changes fix it. **One observable behaviour per step**, and **the step is not done until
he confirms it in game.**

### Rules I work under

1. **One step at a time.** A step changes exactly one thing a player can observe. If I cannot
   name the single thing he will see, the step is too big and gets split.
2. **No forward progress without confirmation.** If the reply is "not working", the step is
   **open**, not deferred. I do not stack the next feature on top of an unconfirmed one. That
   stacking is how four unverified layers ended up in the build.
3. **Suite-green is not evidence.** The suite proves the code does what I wrote, including when
   what I wrote is not the spec. It passed while `/horde status` lied, while routing was inert,
   and while the dev config violated the vanilla-game requirement.
4. **Nothing outside horde mode may change.** Vanilla behaviour is the baseline. Bots, team
   balance, votes, AFK kicks, seeding — all untouched until the horde starts, and restored when
   it stops. A config override that alters non-horde play is a spec violation, not a convenience.
   (This rule was broken today: `filler_bots: 0` sat in the dev config permanently. Reverted.)
5. **No claim without a measurement.** "3 mouths placed from 42 candidates" proves
   `CreateEntity` returned an object. It proves nothing about where the object is, whether it is
   on the surface, or whether a player can see it. Placement steps must log coordinates and be
   confirmed visually.
6. **I never restart the server while he is connected**, and I say so before booting anything.
   Killing a busy server is what produces the crash reports he keeps seeing.
7. **Revert rather than ship half.** If a change makes the observable state worse, it comes back
   out (the minimap reveal was pulled for exactly this reason).

### The steps

Deliberately starts below where the code currently is, because "the state and commands need to
work correctly for starters" and they do not yet.

| Step | The one observable thing | Pass condition (Arian, in game) |
|---|---|---|
| **S0** | State is truthful | `/horde status` reports exactly what the server log says, before and after a start. No world changes at all. |
| **S1** | Starting is announced | `/horde` produces one unambiguous message that the mode has begun; `/horde stop` the same; no lockout between them |
| **S2** | Clean slate | `/horde` gives a genuinely new round: he respawns in the base, prior structures gone, vanilla bots removed **as part of starting** |
| **S3** | One mouth, provably on the surface | Exactly one mouth, its coordinates logged, and he can walk up to it and see it |
| **S4** | Mouths on the minimap | Red blips visible to every marine, matching where the mouths actually are |
| **S5** | Wave timer / HUD | A running timer he can read without opening a console (needs the client-delivery gate, L0) |
| **S6** | Aliens emerge | Something walks out of a mouth toward him (i5a) |

S0 and S1 are the current priority: they are the claim that everything else rests on, and they
are the two he says are not even true yet.

### What each step ships with

- the change, and **nothing else**
- a one-line test instruction for him
- the log lines that should appear if it worked
- an explicit statement of what is still broken or unverified

## 5. Messaging contract (L1)

No state change happens silently, to anyone. Exact strings, chosen so a player can act on them:

| Event | Audience | Message |
|---|---|---|
| `/horde` accepted | everyone | `HORDE: wave 1 starting in 10s — 3 tunnel mouths will open` |
| `/horde` refused by a gate | caller | `HORDE: not started — <reason>` (reason from the gate, already implemented) |
| `/horde` refused, already running | caller | `HORDE: already running — wave N, M mouths active. Use /horde stop` |
| unknown argument | caller | `HORDE: unknown argument 'x'. Try /horde, /horde status, /horde stop, /horde restart` |
| countdown tick | everyone | `HORDE: wave 1 in 5…4…3…2…1` |
| wave begins | everyone | `HORDE: WAVE 1 — mouths at <sectors>` |
| wave cleared | everyone | `HORDE: wave N cleared. +X resources. next wave in Ys` |
| `/horde stop` | everyone | `HORDE: stopping — tore down N mouths, M bots. vanilla fill restored` |
| teardown diff mismatch | everyone + log | `HORDE: teardown left N entities behind — report this` |
| `/horde status` | caller | the existing structured line, plus a plain-language first sentence |

Two rules that come with it:

- **Broadcast needs a verified mechanism.** Shine's `MessageModule:Notify(Player, Message,
  Format, ...)` (`core/shared/base_plugin/messaging.lua:201`) takes a player; whether `nil` or a
  table broadcasts is *not* documented in what I've read, so L1 starts by establishing it from
  source instead of assuming. Iterating marine players is the fallback.
- **A refusal that doesn't say why is a bug**, same class as the ones you just found.

---

## 6. Tech debt register

| Item | Status | Action |
|---|---|---|
| `D:\games\ns2\*.json` — abandoned bare config dump, **contains live `ProgressionConfig.json` tokens** | archived to `D:\games\.stale-20260922\abandoned-config-dump` | delete for real after you confirm; tokens should be considered dead |
| `D:\games\ns2-server\horde-dev` — hyphenated path that broke `-config_path` | archived | delete |
| `dev/g1-probe.sh` — one-off experiment harness | kept, useful | fold into `dev/verify.sh` at L4 or delete |
| Bots pinned to 12/12 in dev config | **fixed** (0/0, `auto_vote_add_commander_bots: false`) | verify in game at L2 |
| Datatable vars declared, never written (`HordePhase`, `HordeWave`, `HordeMouthsActive/Total`, `HordeIntermissionEndsAt`) | open | decide at L5 — see §7 D3 |
| `Machine.MouthsActive`/`MouthsPool` written only by us, read by status | fixed | — |
| Beads tracker: `i4a`/`i4b`/`i7a` still open though shipped | open | close with commit refs (L1 commit) |
| `WORKFLOW.md` still describes the old deploy model in places | partially fixed | rewrite at L2 |
| Minimap reveal: blip created inside `CreateEntity`, before any ownership marker exists → team read as 0 | **reverted, unsolved** | L4, with the ordering fixed |
| Commander 3D view hides unsighted enemy models client-side (`TeamMixin.lua:29-38`) | open | needs client Lua ⇒ published mod |

---

## 7. Decisions — answered by Arian 2026-09-22

Recorded properly in the Atlas as `decisions/td-clean-slate-session`, superseding Q7q7 rather
than quietly editing it.

- **D1 — `/horde` resets everything.** Clean slate: end the round, reposition players, countdown,
  visible mode identity, horde world state established **before** anyone spawns. This supersedes
  Q7q7 ("`/horde` IS the horde warmup", do not restart) and the bot-controller-takeover design
  built on it.
- **D2 — any marine can start it, under the gates** (no real aliens, marines present, below seeding
  max). Open access retained; the gates are the restriction. Stop is open too.
- **D3 — client changes are in scope, with a hard constraint:** *"server has the mod, client only
  connects."* No subscribing, no downloading, no launch flags by the user.
- **D4 — stop restores the prior state**, vanilla fill included.

### The gate D3 creates — and it comes before L3

**No client-side feature is built until the delivery path is proven on this machine.** The
requirement is that a vanilla client ends up running our mod purely by connecting. Two candidates:

1. **Workshop auto-download.** `Dedicated_Server_Usage.txt:180` states a connecting client
   automatically downloads the mods the server is actively using. Unknown: whether that works for a
   **Private / Friends-Only / Unlisted** item, and whether a server can fetch non-public content
   while anonymous.
2. **Self-hosted backup servers.** `ServerConfig.lua` exposes `mod_backup_servers` and
   `mod_backup_before_steam`, consumed by UWE's bundled `utils/WorkshopBackup` — a mechanism for
   serving mod archives from somewhere other than Steam. Unknown: whether it can deliver a mod that
   has **no published id at all**.

If neither works for a non-public item, the honest consequence is that **publishing is mandatory**,
and the first release is public or unlisted. That is a product decision, not something to discover
halfway through building a HUD. Research is in flight; the cheapest proving experiment will be run
before any of it is trusted.

### Ladder, reordered for the gate

| Rung | Deliverable | Status |
|---|---|---|
| **L0** | **Prove mod delivery**: vanilla client connects to a server running our mod and ends up running it | **blocks L3+** |
| L1 | Command + state messaging | **done** `d685ae9` |
| L2 | No vanilla bots in dev | **done** (0 bot activity verified on boot) |
| **L3** | Round restart, reposition, countdown, "this is HORDE" identity | **mechanism found, not gated by L0** — see §9 |
| L4 | Mouths exist and appear on the marine minimap | open — blip ordering unsolved |
| L5 | Wave timer / HUD | needs L0 |
| L6 | Aliens emerge (i5a) | — |
| L7 | Wave loop, intermission, loss (i6a, i8a) | — |

---

## 9. L3 mechanism — settled from source, and mostly free

The important discovery: **there is no engine round-restart API.** `Server.RestartRound` and
`Server.ChangeLevel` do not exist in build 344. What does exist, and what **Shine's own
`pregame`/`tournamentmode`/`basecommands` extensions already use**, is a Lua-reachable sequence:

```lua
Gamerules:ResetGame()                        -- ns2/lua/NS2Gamerules.lua:496  in-place entity/team/bot reset
Gamerules:SetGameState(kGameState.Countdown) -- :132
Gamerules.countdownTime = N                  -- vanilla UpdatePregame (:1878) then drives it to Started
```

That buys us, with no client code at all:

- **a real countdown** — `kGameState.Countdown` is replicated to every client through the
  `GameInfo.state` networkVar (`GameInfo.lua:17-18`), and the client already renders
  *"Game is starting"* during it (`Player_Client.lua:2616-2619`);
- **input lock** — players are frozen during countdown (`Player.lua:1515-1518`, `GetCanControl`
  `:2505`), which is precisely "the mode is set up before you can act";
- **repositioning** — reset returns players to the Ready Room (`Gamerules:UpdateToReadyRoom`
  `:904`), and spawn selection runs through `PlayingTeam:ReplaceRespawnAllPlayers` (`:681`);
- **bot removal** — `Gamerules:SetMaxBots(0, false)` (`:1434`) plus `Bot:Disconnect()` loops
  (`bots/Bot_Server.lua:131-136`), kept gone by the `filler_bots`/`rookie_only_bots`/
  `auto_vote_add_commander_bots` zeros already committed in L2.

`kCountDownLength = 6` (`Globals.lua:114`) is the vanilla length; ours can be longer.

### What this changes about the plan

1. **L3 is not blocked by L0.** The countdown, the reset and the lock are vanilla behaviour.
   Only a *custom numeric on-screen timer with our own text* needs client datatables — Last
   Stand's did — and that is L5, not L3.
2. **A conflict to resolve inside L3:** our gates (`Triggers.Check`) were written for
   `WarmUp`/seeding state. After `ResetGame()` the state is `NotStarted` → `Countdown`, so the
   gates must be evaluated **at command time, before the reset**, and the start must not
   re-check them afterwards. Sequencing bug waiting to happen; it goes in the L3 acceptance test.
3. **Order matters for the mouths:** `ResetGame()` destroys entities, so mouths must be created
   *after* the reset and *during* the countdown — which is exactly the "world state before you
   spawn" requirement, and it is achievable.
4. **Follow Shine's own pattern, don't invent one.** `pregame`/`tournamentmode` already do
   reset → countdown → start. Read that code before writing ours.

### Server-side feedback ceiling (for L5)

Without client Lua we have: chat box, `SendTeamMessage` banners (enum-typed, playing teams only,
`TeamMessenger.lua:111`), team sounds, and the vanilla countdown text. **There is no
`SetScreenText`/`GetHudMessage` in shipped Lua at all.** So a persistent horde HUD is L5 and
needs the L0 delivery path proven first.
