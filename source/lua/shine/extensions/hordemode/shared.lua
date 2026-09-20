--[[
	Horde Mode — shared extension definition.
	Seeding Horde Mode: a TD-like endless alien-wave minigame that runs while
	an NS2 server is seeding (marines only). Started via /horde; complete
	teardown on alien join / loss / seed max. See repo DESIGN.md + vault
	Atlas/Projects/ns2-tower-defense.

	This file is shared across server/client/predict VMs. Server logic lives
	in server/*.lua; this defines the Plugin object + networked data table.

	Status: STUB (i0a). Real definition lands in i1a.
]]

local Shine = Shine
local Plugin = Shine.Plugin( ... )

Plugin.Version = "0.1"
Plugin.PrintName = "Horde Mode"
Plugin.NotifyPrefixColour = { 200, 60, 60 }

-- Networked state for HUD (populated in i9a). Placeholder schema.
function Plugin:SetupDataTable()
	-- self:AddDTVar( "integer", "WaveNumber", 0 )
	-- self:AddDTVar( "integer", "IntermissionEndsAt", 0 )
end

return Plugin
