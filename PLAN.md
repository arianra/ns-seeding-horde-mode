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

## 4. The ladder

Each rung is one commit, one test, and one thing **you can see in game**. Nothing moves up the
ladder until the rung below is confirmed at the keyboard, because the failure mode this project
keeps hitting is "green suite, broken game."

| Rung | Deliverable | What you will see | How it's verified |
|---|---|---|---|
| **L1** | Command feedback contract | every command answers; every state transition broadcasts | suite asserts the message text; you type each command |
| **L2** | Bots gone in dev | a clean map, only you | server log bot count 0; you look around |
| **L3** | Round restart + countdown | screen says HORDE, counts down, you spawn fresh | you experience it; log shows the sequence |
| **L4** | Mouths exist *and* are on the minimap | 3 red blips, marine radar | blip relevancy assertion + your eyes |
| **L5** | Wave timer / HUD | a running timer on screen | client-visible state, needs the datatable decision (§7 D3) |
| **L6** | Aliens come out of the mouths (i5a) | a skulk walking toward you | live observation |
| **L7** | Wave clear / intermission / loss (i6a, i8a) | the loop actually plays | suite + you |

L1 and L2 are code-and-config only — no unknowns — so they ship first. L3 depends on the round
restart mechanism being researched (in flight). L4 depends on the minimap reveal ordering problem
in §5.

---

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
| L3 | Round restart, reposition, countdown, "this is HORDE" identity | needs D1 mechanics (research in flight) |
| L4 | Mouths exist and appear on the marine minimap | open — blip ordering unsolved |
| L5 | Wave timer / HUD | needs L0 |
| L6 | Aliens emerge (i5a) | — |
| L7 | Wave loop, intermission, loss (i6a, i8a) | — |
