#!/usr/bin/env bash
# new-extension.sh — scaffold a Shine extension with the correct file shapes.
#
#   ./dev/new-extension.sh <name> [--client]
#
# Why this exists rather than a paragraph in a doc: the vararg rules are invisible and
# unforgiving. `shared.lua` receives the plugin NAME (so it must call Shine.Plugin(...)),
# while `server.lua`/`client.lua` receive the injected TABLE. Getting it wrong produces
# "attempt to index local 'Plugin' (a string value)" at load and the plugin silently never
# registers. Both forms were measured on 2026-09-22 by mounting three variants in one boot;
# see dev/SCAFFOLDING.md §2b.
#
# --client also emits client.lua, i.e. it opts into the shared/client path that REQUIRES
# every connecting client to mount this mod. Without it the plugin is server-side only and
# vanilla clients can still join (SCAFFOLDING.md §3).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${1:-}"
CLIENT="${2:-}"

[[ "$NAME" =~ ^[a-z][a-z0-9]*$ ]] || {
  echo "[new] name must be lowercase alnum, e.g. ./dev/new-extension.sh myfeature" >&2
  exit 2
}
# Shine globs lua/shine/extensions/*.lua recursively and keys plugins by path segment, so a
# name with a dot or slash would be discovered under something other than what you typed.
DIR="$REPO/source/lua/shine/extensions/$NAME"
[[ -e "$DIR" ]] && { echo "[new] already exists: $DIR" >&2; exit 1; }

mkdir -p "$DIR"

cat > "$DIR/shared.lua" <<EOF
--[[ ${NAME} — shared extension definition.

 Loaded on every VM that has this plugin enabled. Declares the plugin object and the
 constants both sides must agree on. Keep behaviour out of here: server logic belongs in
 server.lua, and anything that must not change the network message table must not be
 declared at all (see dev/SCAFFOLDING.md §3). ]]

local Shine = Shine
local Plugin = Shine.Plugin( ... )

Plugin.Version = "0.1"
Plugin.PrintName = "${NAME}"

-- Nothing networked is declared here. Adding Plugin:SetupDataTable(), AddDTVar() or
-- AddNetworkMessage() means every connecting client must mount this mod.

return Plugin
EOF

cat > "$DIR/server.lua" <<EOF
--[[ ${NAME} — server entrypoint / lifecycle.

 NOTE the asymmetry: shared.lua received the plugin NAME and built the table, so the file
 loaded after it receives the TABLE itself. ]]

local Plugin = ...
local PluginName = Plugin:GetName()

-- Load sibling modules explicitly; Shine does not pick them up on its own.
-- Shine.LoadPluginFile( PluginName, "config.lua", Plugin )

function Plugin:Initialise()
	self.Enabled = true
	return true
end

function Plugin:Cleanup()
	self.BaseClass.Cleanup( self )
end

return Plugin
EOF

if [[ "$CLIENT" == "--client" ]]; then
  cat > "$DIR/client.lua" <<EOF
--[[ ${NAME} — client entrypoint. Present means clients MUST have this mod mounted. ]]

local Plugin = ...

function Plugin:Initialise()
	self.Enabled = true
	return true
end

function Plugin:Cleanup()
	self.BaseClass.Cleanup( self )
end
EOF
fi

# A placeholder scenario so the new plugin is covered by the suite from its first commit:
# an unasserted plugin is an untested plugin.
SCEN="$REPO/source/lua/shine/extensions/hordetest/scenarios.lua"
if [[ -f "$SCEN" ]]; then
  echo "[new] add a scenario to $SCEN:"
  echo "      self:RegisterScenario( \"${NAME}_loads\", false, function()"
  echo "          Assert.NotNil( Shine.Plugins.${NAME}, \"plugin instance exists\" )"
  echo "      end )"
fi

echo "[new] created $DIR"
[[ "$CLIENT" == "--client" ]] && echo "[new] --client: this mod must be mounted by connecting clients" \
  || echo "[new] server-side only: vanilla clients can still join"
echo "[new] next: ./dev/deploy.sh && ./dev/server-start.sh"
