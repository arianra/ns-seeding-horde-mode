# Horde test config — overlay templates

`dev/test.sh` builds a runnable headless config from these files. **These are templates, not the
runtime config**: `test.sh` copies the live server config to `D:\games\ns2hordetest\cfg` and then
overlays the three files here.

Why not just copy the whole config into this folder — as the original bead wording suggested:
the live `D:\games\ns2srv\cfg\ProgressionConfig.json` carries NS2 progression **access and refresh
tokens**, and this repository is **public**. Anything under `dev/horde-test-cfg/` gets committed,
so only the credential-free files live here:

| file | why it is here |
|---|---|
| `ServerConfig.json` | pins `tags` to a valid array (`["horde"]`) — a *string* here crashes `ConfigFileUtility.lua:53`, the world never initialises, and clients get kicked with "Invalid data" |
| `MapCycle.json` | one map (`ns2_summit`) and the mod id `706d242`, which resolves to the workshop Shine copy the dev server loads |
| `shine/BaseConfig.json` | `ActiveExtensions.hordemode` + `.hordetest` on; `APIKeys.Steam` empty |

The runtime path is **hyphen-free on purpose** (`ns2hordetest`): the server argument parser breaks
on hyphens in `-config_path`. See `Atlas/Projects/ns2-tower-defense/reference/td-dev-environment-runbook.md`
for the full environment runbook.

Never add a file here that came from `ns2srv/cfg` without grepping it for tokens first.
