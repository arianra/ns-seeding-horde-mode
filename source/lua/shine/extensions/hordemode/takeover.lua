--[[ Horde Mode — Takeover (i3b).
     Engage/Release vanilla BotTeamController: DisableUpdate + SetMaxBots(0)
     on start; restore snapshot on teardown ('/horde IS the horde warmup',
     Q7q7). Attaches as Plugin.Takeover.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i3b. ]]
local Plugin = ...

local Takeover = {}
Takeover.__index = Takeover

-- Attach to the Plugin so other modules reach it as Plugin.Takeover.
Plugin.Takeover = Takeover

return Takeover
