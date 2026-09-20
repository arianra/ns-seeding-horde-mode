--[[ Horde Mode — Config (i1b).
     DefaultConfig, Shine.Validator rules, Maps.<name> deep-merge,
     ConfigMigrationSteps. Attaches as Plugin.Config.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i1b. ]]
local Plugin = ...

local Config = {}
Config.__index = Config

-- Attach to the Plugin so other modules reach it as Plugin.Config.
Plugin.Config = Config

return Config
