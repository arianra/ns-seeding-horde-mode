# SCAFFOLDING.md — creating and packaging an NS2 mod

Procedure, not theory. Every claim here was executed on this machine on 2026-09-22; the
reasons live in `MODDING.md` and the boundaries in `dev/STANDARDS.md`.

Use `./dev/new-extension.sh <name>` to generate step 2 correctly instead of hand-writing it —
the vararg rules in §2b are the single most common way to break a plugin silently.

---

## 1. Where things live

| Role | Path | Owner |
|---|---|---|
| Extension source (truth) | `source/lua/shine/extensions/<name>/` | repo |
| Built overlay (a `-game` mod) | `D:\games\ns2hordetest\overlay` | disposable, gitignored |
| Dev server config | `D:\games\ns2hordetest\cfg` | disposable |
| Live server config | `D:\games\ns2srv\cfg` | **Arian — read-only to us** |
| Shine (third-party mod) | `...workshop\content\4920\117887554` | **never write** |
| Client's copy of Shine | `steamapps\workshop\content\4920\117887554` | **never write** |

The overlay **is** the mod. It is a plain directory that overlays the game content tree; the
engine mounts it with `-game <path>` and Shine then discovers `lua/shine/extensions/*` inside it.

---

## 2. Create the extension

```bash
./dev/new-extension.sh myfeature      # writes source/lua/shine/extensions/myfeature/
```

Layout produced (and required):

```
source/lua/shine/extensions/myfeature/
  shared.lua     # REQUIRED for a folder plugin. Receives the plugin NAME.
  server.lua     # server-side logic. Receives the plugin TABLE.
  config.lua     # optional: DefaultConfig + validators, loaded from shared/server
  hud.lua        # optional: extra module, loaded explicitly
```

Extra modules are **not** auto-loaded. Load siblings from the entry file:

```lua
Shine.LoadPluginFile("myfeature/config", Plugin, PluginName)   -- see hordemode/shared.lua
```

---

## 2b. The vararg rules — read this before writing a line

Measured by mounting three shapes in one boot (§2b of `MODDING.md`):

| File | `...` is | Correct first line |
|---|---|---|
| `shared.lua` | the plugin **name** (string) | `local Plugin = Shine.Plugin( ... )` |
| flat `extensions/<name>.lua` | the plugin **name** (string) | `local Plugin = Shine.Plugin( ... )` |
| `server.lua` / `client.lua` / `predict.lua` | the plugin **table** | `local Plugin = ...` |

Get this wrong and you get, at load time:

```
Plugin loading error: .../shared.lua:2: attempt to index local 'Plugin' (a string value)
```

and the plugin simply never appears in `sh_list`. Two more rules:

- **A folder with only `server.lua` is not a plugin.** At least one of `shared.lua` or
  `client.lua` must exist for the folder to be treated as one.
- **Return the table** from `shared.lua` (`return Plugin`) — that is how Shine registers it
  without a manual `Shine:RegisterExtension()`.

---

## 3. Server-only vs client-visible: decide deliberately

The game requires **identical network-message counts** on client and server. Therefore:

| Your plugin does | Vanilla clients can join |
|---|---|
| only `server.lua`-side logic, registers nothing networked | **yes** |
| any `shared.lua` (adds a `Shine_PluginSync` field) | **no** |
| `SetupDataTable` / `AddDTVar` / `AddNetworkMessage` | **no** — one message for the table plus one per key |

Restricting datatable access does **not** help: the messages still register; access only gates
who receives values. So if your plugin needs client state, the client must mount your mod —
which is exactly why we ship our own mod rather than editing Shine.

`hordetest` has a `shared.lua`, so it changes the message table **even when disabled**. Keep it
out of anything a human client joins unless you accept that coupling.

---

## 4. What a mod does NOT need

Verified by mounting the tree with none of these present:

- **No `lua/entry/<name>.entry`.** Entry files exist to run *your own* scripts through
  ModLoader. Shine is our host; it loads our extensions. (If you ever do need one, the format is
  a Lua file setting a global: `modEntry = { FileHooks = "...", Shared = "...", Priority = 40 }`;
  **higher Priority loads first**, default 10; the filename becomes the mod name.)
- **No `game_setup.xml`.** It overrides the Client/Server VM entry points for the whole game.
  We are not replacing the game, and a wrong file silently re-routes NS2's boot.

---

## 5. Build and mount

```bash
./dev/deploy.sh            # builds the overlay + enables every extension in source/
./dev/server-start.sh      # DEV instance: -game overlay, port 27025, refuses LIVE unless --live
./dev/server-stop.sh       # PID-scoped; never kill by process name
```

`deploy.sh` sets `ActiveExtensions` for **every extension present in `source/`** in the TEST
config. That is deliberate: hard-coding the original two names meant a freshly scaffolded
extension was discovered by Shine but never enabled, so it did nothing and the loop looked
broken when all that was stale was the config.

`build.sh` rebuilds the overlay **from empty** — a renamed-away extension must not survive and
green the suite against code that no longer exists — and **fails if dev extensions also exist in
any workshop copy**, because mount precedence against the overlay has never been measured and an
ambiguous run proves nothing.

---

## 6. Verify it actually loaded

Three independent checks, cheapest first:

```bash
./dev/deploy.sh --check          # overlay matches repo; no workshop copy polluted
grep -a "Extension 'myfeature' loaded" "$LOG"   # boot log marker
./dev/test.sh                    # full headless suite
```

For a runtime assertion from inside Lua, the engine exposes:

```lua
ModLoader.GetLoadedModNames()    -- array of loaded mod names
ModLoader.GetModInfo(name)       -- that mod's entry table
```

### 6b. Client-side mount (G1c) — needs a human at the keyboard

The dedicated server only runs the **Server** VM, so every green run above proves nothing about
the client VM. This one cannot be automated from here: it launches the game on your desktop.

```powershell
# 1. DEV server up (agent side)
#    ./dev/server-start.sh            -> DEV on port 27025, overlay mounted
# 2. Client with the SAME overlay (your side, Steam running):
& "C:\Program Files (x86)\Steam\steamapps\common\Natural Selection 2\NS2.exe" `
   -game "D:\games\ns2hordetest\overlay" -hotload
# 3. Join 127.0.0.1:27025, then:
Select-String -Path "$env:APPDATA\Natural Selection 2\log.txt" -Pattern "Extension 'hordemode' loaded|Plugin loading error|network messages"
```

Expected on success: `Extension 'hordemode' loaded` in the **client** log and a clean join.
Expected if the overlay is not mounted client-side: either no such line, or
`Different number of network messages on the Client from the Server` — which is the same
mismatch that produced the original "Invalid data" kick, and would tell us `-game` is
server-side only. Either answer is useful; neither requires writing anything you own.

Caveat when grepping the boot log: **the engine log is rotated at boot, not appended.** A
byte-offset fence points past the end of the smaller new file and an occurrence-count delta can
read `1 before, 1 after`. `server-start.sh` accepts a count increase *or* a size shrink.

---

## 7. Adding a test for the new extension

Register scenarios in `source/lua/shine/extensions/hordetest/scenarios.lua`:

```lua
self:RegisterScenario( "myfeature_behaviour", false, function()
    local mine = Shine.Plugins.myfeature
    Assert.NotNil( mine, "plugin instance exists" )
end )
```

Rules this project learned the hard way:

- Assert **routing and behaviour**, not wiring. Stub collaborators and count calls when the
  contract is "which handler ran".
- Never let a check read a log line that a previous run could have written.
- A scenario that mutates shared plugin state must swap it back — `Teardown` is global by
  design, so a caller must own the state it covers.
- Deferred checks fire reliably only within ~8 s of being queued; beyond that they silently stop.

---

## 8. Shipping to a human client (later)

1. `x64` implementation, **root** entry point: start `LaunchPad.exe` from the install root —
   the wiki is explicit that you must never start the `x64` copy.
2. New → set path/name → paste non-built files into **Output** → Builder for anything that needs
   building → Configure → Publish.
3. Store the returned `PublishedFileId` in the repo; it is an identifier, not a secret, and
   updates are addressed by it forever.
4. Visibility: sources disagree on whether LaunchPad can set it before publishing (UWE tutorial
   says Friends Only/Private, the wiki says public-then-edit). Resolve by looking at the dialog.
5. A connecting client auto-downloads the mods the server runs, so a playtest partner needs
   nothing installed manually once the item exists.

---

## 9. Never do these

- Write into any `workshop\content\4920\<someone-else's-id>` directory, on either side.
- Delete or truncate the shared engine log, `dumps/`, or any `%APPDATA%` file you did not create.
- Kill processes by name.
- Point a dev tool at the live config, or default to it.
- Ship an extension that registers networked state and expect vanilla clients to cope.
