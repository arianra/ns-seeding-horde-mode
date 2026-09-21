--[[
	Horde Mode — shared extension definition.
	Seeding Horde Mode: a TD-like endless alien-wave minigame that runs while
	an NS2 server is seeding (marines only). Started via /horde; complete
	teardown on alien join / loss / seed max. See repo DESIGN.md + vault
	Atlas/Projects/ns2-tower-defense.

	This file is shared across server/client/predict VMs. Server logic lives in
	the flat sibling modules that server.lua loads (Shine resolves the entry as
	extensions/hordemode/server.lua — NOT server/init.lua; i0b layout finding);
	here we define the Plugin object plus anything both sides need.

	Networked state is only safe to declare at load time (SetupDataTable), never
	by touching the world — see the Initialise warning in server.lua (spike zpw).
]]

local Shine = Shine
local Plugin = Shine.Plugin( ... )

Plugin.Version = "0.1"
Plugin.PrintName = "Horde Mode"
Plugin.NotifyPrefixColour = { 200, 60, 60 }
Plugin.LogPrefix = "[HORDE]"

-- Phases the state machine moves through (i2a). Declared shared so the HUD (i9a)
-- and any client-side readout agree on the vocabulary.
Plugin.Phase =
{
	Inactive = "inactive",
	Building = "building",
	WaveActive = "wave-active",
	Intermission = "intermission",
	Teardown = "teardown",
	Lost = "lost",
}

-- Networked state for the HUD (populated in i9a). Declared here because the
-- data table must exist on both VMs before anything tries to read it.
function Plugin:SetupDataTable()
	self:AddDTVar( "integer", "HordePhase", 0 )
	self:AddDTVar( "integer", "HordeWave", 0 )
	self:AddDTVar( "integer", "HordeIntermissionEndsAt", 0 )
	self:AddDTVar( "integer", "HordeMouthsActive", 0 )
	self:AddDTVar( "integer", "HordeMouthsTotal", 0 )
end

return Plugin
