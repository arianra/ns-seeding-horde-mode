--[[ Horde Mode — Registry (i3a).
     HordeRegistry: track every entity/bot we spawn (id->ref + kind index);
     BTC snapshot/restore. Teardown + accounting truth (GetBotPlayerCount
     unreliable per spike tby). Attaches as Plugin.Registry.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i3a. ]]
local Plugin = ...

local Registry = {}
Registry.__index = Registry

-- Attach to the Plugin so other modules reach it as Plugin.Registry.
Plugin.Registry = Registry

return Registry
