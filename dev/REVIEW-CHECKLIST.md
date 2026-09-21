# Review checklist (i0e)

`dev/lint.sh` enforces what a parser can see — valid Lua 5.1, plus advisory notes for
file-scope world API calls, missing `return <module>`, and functions over 60 lines.
Everything below is a **judgment** check: run it against your own diff before the
commit, because no static rule catches it. `dev/test.sh` proves the harness runs,
not that the behaviour is right.

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

- [ ] `-config_path` is hyphen-free (`D:\games\ns2hordetest\cfg`); the arg parser breaks on hyphens.
- [ ] `tags` in `ServerConfig.json` stays an array — a string crashes `ConfigFileUtility.lua:53`
      and the world never initialises.
- [ ] After a run: `dev/server-stop.sh` **and** verify zero `Server` processes, or the next
      boot dies on port 27015.
- [ ] Never copy a host config directory into the repo to make a test easier —
      `ns2srv/cfg/ProgressionConfig.json` holds live tokens and this repo is public.
- [ ] Game lua source of truth is `D:\games\ns2-server\ns2\lua` (build 344); the
      `/mnt/d/projects/ns2-td/research` snapshots are stale.
