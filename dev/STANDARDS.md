# Standards: what dev tooling may and may not touch

Binding on every script in `dev/` and every agent session working on this project.
Written 2026-09-21 after an agent broke Arian's ability to play the game.

## The rule

**Never write inside content another tool owns.** Dev tooling may write to exactly three
places: the repo, the dev server's own config/mod tree, and NS2's per-user mod storage
(`%APPDATA%\Natural Selection 2\...`), which the dedicated server populates for itself.

The dev tree is **defined in one place — `dev/paths.sh`** (currently
`D:\games\horde\server\{cfg,mods}`, port 27025/27026). Scripts take it from there; do not
hard-code a dev path in prose or in a script, because this document carried a stale one
(`D:\games\ns2hordetest\cfg`) long after that tree stopped being used.

Everything below is **read-only to us**, no matter how it makes a local test pass:

| Path | Owner | Why writing it is forbidden |
|---|---|---|
| `C:\Program Files (x86)\Steam\steamapps\workshop\content\**` | Steam | This is the **client's** copy of subscribed mods. Extra/edited files fail Workshop consistency, so *every* server rejects the client: "your files are out of sync with the server". Not just ours — every server on earth. |
| `C:\Program Files (x86)\Steam\steamapps\common\**` | Steam | The game install. Same failure mode, plus `Verify integrity` churn. |
| `D:\games\ns2-server\ns2\**`, `...\x64\**` | steamcmd / the engine | Server binaries and shipped Lua. steamcmd re-applies depot builds over them. |
| `%APPDATA%\Natural Selection 2\cfg` (the client's own config) | the game | Client settings; never a dev surface. |
| `D:\games\ns2srv\cfg\**` | **Arian's live server** | Write only on explicit request. `deploy.sh` may force `hordetest` off there (a harness that spawns bots and takes the chair must never run on a live server) but must not otherwise edit it, and must never flip `hordemode` — that flag is his. |

## What happened

To fix "clients can't join our dev server", an agent mirrored its dev extensions into
**both** copies of the Shine mod — the server's, and the client's under `steamapps`. Joins
to the dev server worked. Every other server then refused the client, because the client's
Shine files no longer matched the published Workshop item. The dev-loop fix converted a
local test failure into damage to the user's actual game.

The reasoning error: treating the two copies as "mirrors to keep in sync". They are not
mirrors. One is ours to run a server, the other is Steam's to play the game.

## The supported way to ship dev plugins

From Shine's own *Developing a Shine plugin*:

> If you want to add new plugins to Shine, you need to make your own Steam Workshop mod,
> with the folder `lua/shine/extensions`. In this folder, place all the plugins you want
> to add. Run your mod alongside the main Shine mod and your plugins will be loaded.

So: **our plugins live in our own mod, loaded alongside Shine** — never inside Shine's files.
That is also the only path that lets a human client join with our features, because the client
then receives our mod through Steam's normal subscription, not through a hand-edit — and nothing
"solves" a join problem by touching the client's copy.

That is the shipped shape today: **the mod is published** (Workshop `3807461324`, `seedinghorde`),
`dev/deploy.sh` installs the packaged artifact into the DEV mod storage (`$DEV_MODS` —
`-modstorage`, isolated from Steam's trees), and a joining client gets the same files through
Steam's normal subscription. Verified from a real client, no launch options.

Two consequences this tree enforces:
- **A republish only reaches running servers on their next boot** (the engine fetches the mapcycle's
  `mods` at startup). Republish ⇒ restart the dev server before a human joins, or the joiner's
  newer copy is rejected with "server mod out of date" (measured 2026-09-29).
- The client's `steamapps\workshop\content\**` stays **untouched in every direction** — dev files
  go to the dev tree; the client's copy is Steam's to manage.

And the scope rule above it all: **development runs on the dev server only** (27025). Arian's
community-server era is over — this is mod development; the live tree exists for a hypothetical
future boot **only he can ask for by name** (HANDOFF §2 rule 0).

## Enforcement

1. `dev/deploy.sh` refuses at parse time if any write target matches `*/steamapps/*` or
   the Steam program dir (exit 3), and lists the Steam path **only** as a repair target so
   `--clean` can undo earlier damage.
2. `./dev/deploy.sh --check` asserts the client copy is pristine; `dev/test.sh` runs it
   after every suite, so a regression fails the loop rather than shipping.
3. Every deploy prints the state it left behind, including
   `NOTE - while this state holds, vanilla clients cannot join this server.`

## If it regresses

```bash
./dev/deploy.sh --clean          # removes dev files from server AND Steam copies
./dev/deploy.sh --check          # must print "client copy pristine", exit 0
```

Then confirm against the untouched copy and restart the game client (it caches mounted
mods). If the client is still rejected anywhere, Steam → NS2 → Properties → Installed
Files → **Verify integrity of game files**, or unsubscribe/re-subscribe Shine
(published id `117887554`), which re-downloads the authoritative files.

## Review checklist

Add to every review of a `dev/` change: *does this write anywhere Steam or the engine
owns?* A test that only passes by editing managed content is not a passing test.
