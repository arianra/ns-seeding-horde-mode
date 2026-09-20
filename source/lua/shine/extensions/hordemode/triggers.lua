--[[ Horde Mode — Triggers (i2b/i8a).
     Gate predicates for /horde (IsNotRunning/CooldownOk/NoRealAliens/
     SeedMaxNotMet/MarineExists) + loss predicates (AllMarinesDeadGrace/
     CCDestroyed/RealAlienJoined/SeedMaxMet). Pure-ish, 1s poll while running.
     GetIsVirtual filters our own bots. Attaches as Plugin.Triggers.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i2b/i8a. ]]
local Plugin = ...

local Triggers = {}
Triggers.__index = Triggers

-- Attach to the Plugin so other modules reach it as Plugin.Triggers.
Plugin.Triggers = Triggers

return Triggers
