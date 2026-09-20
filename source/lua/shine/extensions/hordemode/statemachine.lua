--[[ Horde Mode — StateMachine (i2a).
     States Inactive/Wave/Intermission/Teardown; guarded transitions;
     logging. Pure logic, unit-testable. Attaches as Plugin.StateMachine.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i2a. ]]
local Plugin = ...

local StateMachine = {}
StateMachine.__index = StateMachine

-- Attach to the Plugin so other modules reach it as Plugin.StateMachine.
Plugin.StateMachine = StateMachine

return StateMachine
