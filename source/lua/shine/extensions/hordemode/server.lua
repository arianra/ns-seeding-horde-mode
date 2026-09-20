--[[
	Horde Mode — server entrypoint / lifecycle.

	Shine loads THIS file (extensions/hordemode/server.lua) and passes the
	Plugin object as `...`. Sibling modules are loaded explicitly via
	Shine.LoadPluginFile(PluginName, "file.lua", Plugin) — the proven
	voterandom/mapvote pattern (Shine does NOT auto-load a server/ subdir;
	see spike i0b layout finding).

	Responsibilities:
	  - world-ready gate (NO game APIs in Initialise; arm on first valid
	    GetGamerules() via OnFirstThink/SetGameState) — pitfall from spike zpw.
	  - bind commands (/horde, sh_horde_stop, sh_horde_status).
	  - drive the state machine; coordinate takeover, placement, spawner,
	    waves, triggers, economy, hud, teardown.

	Status: STUB (i0a). Loads sibling module stubs to prove wiring.
	Skeleton + world-ready gate in i1a; commands i2b/i2c; teardown i7a.
]]

local Shine = Shine
local Plugin = ...
local PluginName = Plugin:GetName()

-- Module load order matters: leaf modules (no deps) first, orchestrators last.
-- Each sibling receives Plugin as `...` and attaches itself as Plugin.<Name>.
Shine.LoadPluginFile( PluginName, "config.lua", Plugin )        -- i1b
Shine.LoadPluginFile( PluginName, "statemachine.lua", Plugin )  -- i2a
Shine.LoadPluginFile( PluginName, "registry.lua", Plugin )      -- i3a
Shine.LoadPluginFile( PluginName, "takeover.lua", Plugin )      -- i3b
Shine.LoadPluginFile( PluginName, "placement.lua", Plugin )     -- i4a
Shine.LoadPluginFile( PluginName, "spawner.lua", Plugin )       -- i4b/i5a
Shine.LoadPluginFile( PluginName, "triggers.lua", Plugin )      -- i2b/i8a
Shine.LoadPluginFile( PluginName, "economy.lua", Plugin )       -- i6a
Shine.LoadPluginFile( PluginName, "waves.lua", Plugin )         -- i6a/i6b
Shine.LoadPluginFile( PluginName, "hud.lua", Plugin )           -- i9a

function Plugin:Initialise()
	-- NO game-state APIs here (runs before the world exists — see spike zpw).
	-- Real world-ready arming lands in i1a (OnFirstThink + GetGamerules poll).
	self.Enabled = true
	return true
end

function Plugin:Cleanup()
	-- Destroy timers (base class handles), teardown any live horde (i7a).
end

return Plugin
