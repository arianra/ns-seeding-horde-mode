--[[
	Horde Mode — server entrypoint / lifecycle.
	Responsibilities:
	  - world-ready gate (NO game APIs in Initialise; arm on first valid
	    GetGamerules() via OnFirstThink/SetGameState) — pitfall from spike zpw.
	  - bind commands (/horde, sh_horde_stop, sh_horde_status).
	  - drive the state machine; coordinate takeover, placement, spawner,
	    waves, triggers, economy, hud, teardown.

	Module loading order (filled in as each module lands):
	  config -> statemachine -> registry -> takeover -> placement ->
	  spawner -> waves -> triggers -> economy -> hud

	Status: STUB (i0a). Skeleton + world-ready gate in i1a; commands i2b/i2c;
	teardown i7a; triggers i8a.
]]

local Shine = Shine
local Plugin = ...

function Plugin:Initialise()
	-- NO game-state APIs here (runs before the world exists — see spike zpw).
	self.Enabled = true
	return true
end

function Plugin:Cleanup()
	-- Destroy timers (base class), teardown any live horde (i7a).
end

return Plugin
