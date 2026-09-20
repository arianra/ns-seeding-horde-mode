--[[ Horde Mode — Spawner (i4b/i5a).
     SpawnMouth(point,wave): unpaired TunnelEntrance + SetConstructionComplete
     + HP scale + registry. SpawnBot(mouthPoint,techId): PlayerBot recipe
     (Initialize + lifeformEvolution + SetOrigin), materialization retry.
     DestroyMouth / bot teardown. Attaches as Plugin.Spawner.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i4b/i5a. ]]
local Plugin = ...

local Spawner = {}
Spawner.__index = Spawner

-- Attach to the Plugin so other modules reach it as Plugin.Spawner.
Plugin.Spawner = Spawner

return Spawner
