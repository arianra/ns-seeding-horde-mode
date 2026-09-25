# Review checklist (i0e)

`dev/lint.sh` enforces what a parser can see — valid Lua 5.1, plus advisory notes for
file-scope world API calls, missing `return <module>`, and functions over 60 lines.
Everything below is a **judgment** check: run it against your own diff before the
commit, because no static rule catches it. `dev/test.sh` proves the harness runs,
not that the behaviour is right.

## Managed content (hard rule - dev/STANDARDS.md)

- [ ] Nothing writes under `steamapps\workshop\content`, `steamapps\common`, the server's
      `ns2\` tree, or the client's own config. Those belong to Steam/the engine/the user, and
      extra files in the client's mod copy make **every** server reject Arian with "files are
      out of sync" - a local test win that breaks the game.
- [ ] Dev plugins go in the server's `%APPDATA%` mod storage only. The supported long-term
      shape is our own mod loaded alongside Shine, not files inside Shine's copy.
- [ ] `./dev/deploy.sh --check` prints `client copy pristine` and exits 0.
- [ ] A change that only passes by editing managed content is a failing change, not a fix.

## Engine contact

- [ ] Nothing touches game APIs in `Initialise` — `GetGamerules()` is nil before world
      init and reaching into it crashes `Gamerules_Global` (spike zpw). Arm a timer instead.
- [ ] Every engine call that can fail at runtime is guarded (`pcall` or an explicit nil
      check) — and the guard reports, it does not swallow.
- [ ] `Pathing.GetPathPoints(src, dst, PointArray())` gets a real `PointArray()`; a plain
      `{}` crashes the binding.
- [ ] Never `Pathing.FindRandomPointAroundCircle` from extension context — it returns
      zero-vectors on build 344 (spike tby). Use authored point pools.
- [ ] Entity death is proven by `Shared.GetEntity(id) == nil` polling, not by a stale
      reference going falsy.
- [ ] Bot teardown: `bot:Disconnect()`, and `BotTeamController` restored
      (`EnableUpdate` + `SetMaxBots(snapshot)`), never left locked.

## State and registry discipline

- [ ] Anything spawned is registered in `registry.lua` **before** the spawn call returns,
      so teardown can never miss it. Teardown completeness is the product requirement
      ("as if it never existed"), not a cleanup detail.
- [ ] No module reads another module's internals; cross-module contact goes through the
      `Plugin.<Attr>` tables that siblings attach.
- [ ] Config values are read from `self.Config`, never hardcoded — curves are data.
- [ ] Any placeholder/derived balance constant is commented `untuned, placeholder <date>`
      so nobody reads it as a decision.

## Test honesty
- **Two scenarios must not mutate the same global engine object across deferred
  checks.** `spike_bot_players` and `takeover_live_cycle` both lock the one
  `botTeamController`, and their deferred halves resolve at t+6 and t+15. Any
  *absolute* assertion about `updateLock` is therefore unstable - a baseline read
  before the other scenario releases will never match. Assert the delta measured
  immediately around your own call, or take the global out of play.
- **Deferred checks only reliably fire in the first ~8 seconds of the pending queue.**
  Observed three times: checks scheduled at t+6 and t+8 landed; t+9 and t+14 never did, with
  nothing in the log and no `ALL-DONE` (the run then times out in `dev/test.sh`). Retaining the
  `CreateTimer` handle made no difference, so plugin-timer lifetime is not the cause. Until this
  is diagnosed, keep every deferred check at <=8s and put the whole assertion in ONE callback -
  chaining defers hangs the suite. This constrains i5b (stream-to-base) and i6c (3-wave), which
  need 15-60s windows: they cannot use this mechanism as-is.
- `Defer` is a method on **hordetest**, not on the plugin under test. Writing `horde:Defer(...)` instead of `self:Defer(...)` fails at runtime, not load time - it happened twice while building i3b/i3c.
- Deferred checks are the price of testing bots: nothing about a spawned bot is
  true in the tick after `CreateEntity`. `Plugin:Defer` exists so that is not faked.
- A setup path that engages shared engine state must run under `pcall` with a
  cleanup: the first version of the takeover test threw between `Engage` and
  `Release` and left the controller locked for every later scenario.


- [ ] A new assert helper ships with a negative control that must fail.
- [ ] A PASS means the thing happened, not that nothing errored: assert on the observed
      state (entity gone, count changed, payout landed), not on absence of failure.
- [ ] Loss/win scenarios assert the **trigger reason**, not only that a loss fired.
- [ ] If a scenario passes on the first try with no engine contact at all, it is testing
      the test.

## Dev environment
- **Never point a dev-only extension at the live server config.** `dev/deploy.sh` used to set
  `ActiveExtensions.hordetest = true` in `D:\games\ns2srv\cfg`, the config an ordinary boot reads.
  Result: every live server ran the scenario suite (spawning bots, capping the bot controller,
  logging a bot into the commander chair, destroying entities) and the server kept crashing.
  Now: deploy targets `D:\games\ns2hordetest\cfg` only, forces the live config off if it finds
  those flags on, and `hordetest` additionally requires `HordeTest.json RunSuite=true` — being
  *enabled* is not authorisation to run.
- **Process control is by PID *and* verified identity, never by name.** `Stop-Process -Name
  Server -Force` killed every `Server.exe` on the box, including any real one. So
  `dev/.server.pid` is written at launch and only that PID is stopped; a missing pid file means
  "nothing to stop", and other Server processes are reported, never touched.
- **A PID is not an identity — check the command line before killing.** Windows reuses numbers,
  so a stale pidfile is a loaded gun pointed at whatever occupies that PID next. Found
  2026-09-24 while fixing something else: `server-stop.sh` referenced an undefined `$REPO_DIR`
  under `set -u`, so it died at its guard call on *every* run — which meant the pidfile was
  never removed, and `server-start.sh`'s own inline `Stop-Process` (no identity check, no guard)
  was the only thing ever stopping a server. Now the stop is one script: it reads
  `Win32_Process.CommandLine` for the tracked PID, refuses unless it carries the expected
  `-config_path`, releases the claim instead of killing a stranger, and the start script calls
  it rather than duplicating the kill. Proven in both directions: a dead PID reports
  "not running", an unrelated live PID reports REFUSED and survives.
- **`dumps/dumplog.txt` is written asynchronously, ~7s after the dump job, so measure it
  after a delay.** Measuring immediately after a stop made two "no dump" results look real
  when the entries appeared seconds later, and I briefly concluded the scenario suite caused
  a shutdown crash. Re-measured with the lag respected: an isolated live-config boot + graceful
  stop produces **no dump at all**.
- **Never overlap runs of the dev loop.** Two `dev/test.sh` invocations in flight mean two
  `Server.exe` on port 27015 and one run's stop killing another's process - which produces
  exactly the crash dumps we are trying to count. Serialise, and confirm `Get-Process Server`
  is empty before starting a measurement.
- **A forced kill is indistinguishable from a crash to NS2's crash handler.** It writes a dump
  and uploads it (`options.xml: upload-dumps=true`), so a dev loop that terminates by force
  manufactures a false incident report - 21 "server" dumps appeared during one afternoon of
  legitimate test cycles. Stop gracefully (plain `Stop-Process -Id`), escalate to `-Force`
  only with a loud warning, and never kill by image name.
- **Destruction is not observable in the calling tick, and not consistently.** Measured across
  runs of one scenario: `Kill()` cleared 0 of 2 entity ids, then 2 of 2. `Disconnect()` leaves
  both the player and the entity id resolvable in the same tick. Confirm on a later poll.
- **An entity's id is not available in its creation tick.** `GetId()` returns nothing until a
  tick has passed, which is why `Registry:Register` refuses such refs instead of inventing a
  key — and why i5a's spawner must register on the following tick, not immediately.


- [ ] `-config_path` is hyphen-free (`D:\games\ns2hordetest\cfg`); the arg parser breaks on hyphens.
- [ ] `tags` in `ServerConfig.json` stays an array — a string crashes `ConfigFileUtility.lua:53`
      and the world never initialises.
- [ ] After a run: `dev/server-stop.sh` **and** verify zero `Server` processes, or the next
      boot dies on port 27015.
- [ ] Never copy a host config directory into the repo to make a test easier —
      `ns2srv/cfg/ProgressionConfig.json` holds live tokens and this repo is public.
- [ ] Game lua source of truth is `D:\games\ns2-server\ns2\lua` (build 344); the
      `/mnt/d/projects/ns2-td/research` snapshots are stale.
