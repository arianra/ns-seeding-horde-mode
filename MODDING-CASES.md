# MODDING-CASES.md — how real NS2 mods are built, and what we're doing differently

Written 2026-09-23 after three research passes: Shine's shipped extension source, the live
ecosystem, and the 155 workshop items installed on this machine. The point of this file is that
**every open problem we have has shipped prior art on this disk**, and I was reasoning from
documentation instead of reading it.

Evidence classes: `[CODE]` read from shipped source on this machine · `[LIVE]` observed on this
machine · `[WEB]` external source with date.

---

## 1. The ecosystem today (this changes our assumptions)

- **The game is dead as a product and alive as a platform.** UWE ceased active development
  2023-02-14 `[WEB]`. Build 344 is current. But **post-EOL patching now happens through the
  Workshop, not depot builds**: the UWE-branded *UWE Hotfix 344* (item 3558697165) was updated
  2026-09-20 and runs on 57 of ~70 live servers `[LIVE][WEB]`.
- **~70 servers, 9–44 concurrent players** depending on hour; SteamCharts 2026 monthly average
  ~65–95 `[WEB: ns2servers.pw, 2026-09-23]`. Zero UWE-named servers; the communities are
  NSL/ENSL, BAD/Shounen/TWH, Eastern Hive, CN PvE BootCamp, RU smart-bot, Combat co-op, Siege++.
- **The dominant pattern is exactly what we are attempting**: Shine plugins plus additive
  server-side mods, auto-downloaded to connecting clients. Server-count adoption, same source:
  NSL Badges 61 · UWE Hotfix 344 57 · Shine Administration 41 · [Shine] Epsilon 34 · Devnull
  Enhanced ScoreBoard 29 · Interesting Score Screen 28 · Enhanced Spectator 26 · Shine Extras 26 ·
  Badges+ 25 · NS2Panel 20 · Wonitor 19 · InfantryPortal 17 · Quick Buy 18 · Fair Start 16 ·
  **Drey's Enhanced Hud 14** · BlueprintObstacleFix 12 · Drey's Blueprint Placement 10.
- **Nobody maintains a Last Stand successor** (item 635568146: last updated 2021-12-17, comments
  report it broken since ~build 330, 0 servers). *Community TD* and *TD Plus* are Thunderdome
  server-config tweaks, not tower defense. **The horde-mode niche is genuinely open** — we are not
  reimplementing something better-built.
- **On-screen information is a solved, popular category.** Drey's Enhanced Hud runs on 14 servers;
  minimap enhancers exist for our exact need — *Persistent Minimap Buildings*, *Highlight
  Structures On Map*, *Player Names on Minimap*, *Minimap Colored Players*, *BetterMarineMinimap*.
  The #1 trending workshop item this week is a HUD mod `[WEB: 2026-09-23]`.

### Operational facts we must engineer around

1. **Mods must be listed in `MapCycle.json` `mods` or they unload on map change** — current top
   gotcha, from the Shine author, 2025-08-30 `[WEB]`.
2. **Steam mod download fails ~1 in 4 normally, ~9 in 10 during sales**, and servers can serve a
   version that is no longer available after an update — documented in UWE's own bundled
   `utils/WorkshopBackup/README` `[CODE]`.
3. **Publish public.** Unlisted/private items are *not* documented as supported for client
   auto-download, and the backup-server path resolves items through the public `GetDetails` API
   `[WEB][CODE]`. This resolves the open question from `MODDING.md` §5: **a public item is the
   only reliable "client just connects" route.**

---

## 2. How shipped code actually does the things we're failing at

### 2a. On-screen text — I was wrong, and it's free

I told you "there is no `SetScreenText` in shipped Lua at all." **False.** Shine ships a complete
server-driven screen-text system:

```
shine/lib/screentext/sh_screentext.lua   registers Shine_ScreenText* network messages
shine/lib/screentext/sv_screentext.lua   Shine.ScreenText.Add(ID, Params, Player)   :7
                                         Shine.ScreenText.SetText(ID, Text, Player) :14
                                         Shine.ScreenText.End(ID, Player)           :23
                                         Shine.ScreenText.Remove(ID, Player)        :27
shine/lib/screentext/cl_screentext.lua   the client receiver
```
`[CODE]` — and it is used by shipped extensions: `adverts/server.lua`, `mapvote/client.lua`,
`pregame/server.lua`, `basecommands/*`. `[LIVE]`

**Consequence:** a persistent wave banner and a running timer need **no client code of ours** —
Shine already ships both halves. That deletes a whole dependency I had put on the critical path.

### 2b. Server→client state: two mechanisms, and we use neither correctly

Shine's plugin network layer (`core/shared/base_plugin/networking.lua`):

| Use | Mechanism | Shipped example |
|---|---|---|
| small persistent state | `Plugin:SetupDataTable()` + `AddDTVar`, written as `self.dt.X = v`, read client-side via `NetworkUpdate` | `pregame/shared.lua` — a complete `AllowAttack` round trip |
| discrete events | `AddNetworkMessage` → `Shine:SendNetworkMessage(target, Name, data, reliable)`; **nil target broadcasts** | `adverts`, `mapvote` |
| translated chat | `AddTranslatedNotify` / `CommandNotify` → `Shine_ChatCol` → injected into the game's ChatUI | `core/client/chat.lua:50-100` |

`[CODE]`

**Our divergence, measured:** `hordemode` declares five datatable vars — `HordePhase`, `HordeWave`,
`HordeIntermissionEndsAt`, `HordeMouthsActive`, `HordeMouthsTotal` — and **writes none of them**.
We have **no `client.lua`** and **no `AddNetworkMessage` anywhere**. So we declared a client
contract and never implemented it. That is the structural reason nothing is visible in game: the
client has our code but no data from it.

### 2c. Chat commands: why `/horde status` silently started a horde

`Shine:RunCommand` parses **only up to `#Command.Arguments`** — undeclared arguments are dropped
silently (`core/server/commands.lua:884, 912-937`). `[CODE]` Multi-word arguments need
`TakeRestOfLine`. Openness is `NoPerm`; imperative checks use `Shine:HasAccess`
(`permissions.lua:1243`).

We hit this exactly, and shipped practice avoids it: mature extensions declare one command per
sub-action rather than hand-rolling a subcommand parser inside one handler. Our
`OnHordeCommand` dispatch-on-first-word is a divergence from convention — it works now that the
parameter is declared, but per-subcommand `BindCommand` is the pattern the ecosystem uses.

### 2d. Minimap reveal: no Shine plugin does it; game-code mods do

Searched all shipped Shine extensions: **nothing touches `MapBlip` or relevancy.** The gating is
in the game: `MapBlip:UpdateRelevancy` (`MapBlip.lua:84-100`) includes enemy-team categories only
when `MapBlip:GetIsSighted()` (`:135-149`), which delegates to the owner's LOS
(`LOSMixin.lua:47-58`), set server-side by `LOSMixin:SetIsSighted(sighted, viewer)`
(`:408-413`). `[CODE]`

Precedent exists in real mods: Last Stand calls `SetExcludeRelevancyMask` and `SetIsSighted`
directly (`laststand/source/lua/Babbler.lua:227`, `Blip.lua:37`, `LOSMixin.lua:51`), and the
installed **NS2_GorgeTunnel** mod ships its own `TunnelEntrance.lua` override. `[LIVE]`

So the minimap problem is solvable, but **it is not a Shine-plugin-shaped problem** — it means
touching entity relevancy on structures we own. That's a deliberate call, not a hack to reach for
before S3 proves the mouths are even in the right place.

### 2e. Overriding game classes needs an entry file — my scaffolding doc said otherwise

From the installed `NS2_GorgeTunnel` mod `[LIVE]`:

```lua
-- lua/entry/NS2_GorgeTunnel.entry
modEntry = {
    FileHooks = "lua/NS2_GorgeTunnel/Filehooks.lua",
    Priority  = 84   -- "make sure this is higher than any UWE extension"
}
```

Three lessons in four lines:
- **Higher `Priority` loads first** — which settles the question `MODDING.md` §2b left
  deliberately unresolved. Shine is 50; a mod that must beat it uses 84.
- One mod folder can register **multiple** mods via multiple entry files.
- `FileHooks` with `pre`/`post`/`halt`/`replace` is how shipped mods override game classes.
  `dev/SCAFFOLDING.md` §4 says a mod needs no entry file. **That is true only for adding Shine
  extensions, and false for overriding game code** — the doc needs that distinction, and I wrote
  the absolute version.

---

## 3. What this means for our open problems

| Problem | Before this research | After |
|---|---|---|
| Client gets our mod | "publishing may be mandatory, visibility unknown" | **Publish public.** Unlisted/private unsupported for auto-download. Backup servers are a resilience layer, not a Workshop substitute. |
| Wave timer / on-screen identity | blocked on client Lua + delivery | **Unblocked.** `Shine.ScreenText.*` ships both halves. |
| Mouths on minimap | "no graceful mechanism found" | Mechanism known (`SetIsSighted` / blip mask) with shipped precedent; **deferred until placement is proven on the surface** |
| Mouths on the map at all | claimed "3 placed" | **Still unproven.** `CreateEntity` returning an object says nothing about position or visibility. |
| Our client contract | not noticed | We declare 5 datatables and write none, and ship no `client.lua`. The client literally cannot know anything about the horde. |
| Command routing | patched | Convention is per-subcommand `BindCommand`; ours is a hand-rolled parser |

## 4. What I got wrong that this file corrects

1. "No `SetScreenText` exists in shipped Lua" — false; Shine ships it and four extensions use it.
2. "A mod needs no entry file" — true only for adding Shine extensions, false for overriding game
   classes, which is exactly the category the minimap problem falls into.
3. "`Priority` sort direction deliberately unresolved" — it was answerable from shipped mods on
   this machine, and the answer is higher-first.
4. Treating the horde niche as "Last Stand but ours" — Last Stand has been broken since ~build 330
   with 0 servers, so there is nothing to copy there and an open gap to fill.
5. The general method: I read documentation and reasoned, while 155 installed mods containing the
   answers sat on this disk. That is the specific thing you asked me to fix.

## 5. Sources

`[LIVE]` `/mnt/c/Program Files (x86)/Steam/steamapps/workshop/content/4920/` — 155 items, incl.
117887554 (Shine), 2899635443 (NSL Badges), 3558697165 (UWE Hotfix 344), 2073756005
(NS2_GorgeTunnel), 1132771326 (Enhanced Spectator), 2330337167 (NS2Combat).
`[CODE]` Shine `core/shared/base_plugin/networking.lua`, `core/server/commands.lua`,
`core/server/permissions.lua`, `lib/screentext/*`, `extensions/{pregame,adverts,mapvote,
tournamentmode,readyroom}`; game `MapBlip.lua`, `MapBlipMixin.lua`, `LOSMixin.lua`;
`D:\games\ns2-server\utils\WorkshopBackup\README.md`.
`[WEB]` ns2servers.pw (2026-09-23), Steam Workshop appid 4920, Steam news API (UWE EOL
2023-02-14), Shine repository (pushed 2026-02-07), SteamCharts 2026, Last Stand item page
(comments through 2024), Matched Play v1.0 notes (2022-12-09).

---

## 6. Delivery experiment — there is no Workshop-free path (2026-09-23)

Run because the `-game` overlay is not what an end user receives, so developing against it
validated nothing about packaging. Three states, same artifact, measured on this machine.

**Test 1 — mod folder on disk, unpublished id.** Built a real artifact (`lua/entry/
seedinghorde.entry` + `lua/shine/extensions/*`), installed it at
`mods/content/4920/999000001/`, listed `3b8b87c1` in `MapCycle.json`, booted with the overlay
disabled:

```
Adding mod 999000001 from MapCycle.json to active mod list
Error: Failed to fetch info for Mod 999000001, steam returned file not found
Mod 999000001 is unavailable because its has no cached versions to use.
Error: SteamVersionAvailable was false for mod [999000001] with version 0
Error: Mod [999000001] wasn't available
```
Shine, NSL Badges and UWE Hotfix mounted normally; **`hordemode` did not load.** A directory
that exists is not a mod.

**Test 2 — plus a backup server speaking the documented protocol.** Implemented
`dev/modserver.sh` against UWE's own contract (`WorkshopBackup` `check_path`/`make_key`:
`/m<hexId>_<version>.zip`, port 27020), served the artifact, and set
`mod_backup_servers: ["http://127.0.0.1:27020"]` with `mod_backup_before_steam: true`. Verified
retrievable: `HTTP 200, 144501 bytes`. Result:

```
Mod [999000001][999000001] is not whitelisted
```

**That is the gate.** The engine consults a mod whitelist — the same UWE list that produced
`Found 114 mods in whitelist` at boot — and an id that has never existed on the Workshop is not
on it. No backup server, protocol-correct or not, can substitute.

**Test 3 (the earlier one) — `-game` overlay.** Works, and is the only Workshop-free mount. It
is not a mod: no id, no delivery, no client download, no entry-file semantics.

### Consequences

1. **Publication is mandatory, and it is a one-time human action.** Publishing needs Steam
   running under an account that owns NS2, LaunchPad started **from the install root** (never
   `x64`), and acceptance of the Workshop legal agreement on first upload.
2. **The pipeline is built and is the only producer of mod files.** `dev/package.sh` emits
   `build/mod/`, a semver-named archive, the protocol-named `m<hex>_<version>.zip`, and a
   manifest with hashes; deterministic (fixed timestamps, sorted members) so a rebuild cannot
   silently change bytes. `mod/mod.json` is the single identity source. `dev/deploy.sh` installs
   the **artifact** (and verifies the install matches the artifact, not the source), refuses
   Steam-managed paths at parse time, and repairs the Workshop copies an earlier revision
   polluted. `dev/modserver.sh` stays — after publication it becomes the resilience layer
   WorkshopBackup's README recommends, not a workaround.
3. **What is still unproven, stated plainly:** that a *published* item mounts and auto-downloads
   to a client. That is the first thing to verify after publication — the pipeline's remaining
   assumption. The placeholder id in `mod/mod.json` exists only to exercise the build; it is
   replaced by the real `publishedFileId` and never changed afterwards.
4. **Nothing is hot-rigged.** The dev loop and the release path run the same scripts and produce
   the same artifact; the only difference after publication is which id is in `mod/mod.json`.
