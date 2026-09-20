--[[ Horde Mode — Economy (i6a).
     v0: flat wave-clear payout to marine team (AddTeamResources(1, payout)).
     Kill-pres + chair cycle + bounties = Phase 2. Attaches as Plugin.Economy.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i6a. ]]
local Plugin = ...

local Economy = {}
Economy.__index = Economy

-- Attach to the Plugin so other modules reach it as Plugin.Economy.
Plugin.Economy = Economy

return Economy
