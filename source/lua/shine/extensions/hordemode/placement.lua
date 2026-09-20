--[[ Horde Mode — Placement (i4a).
     Pure functions: GetBaseAnchor, GatherCandidates (IP/cyst/Location),
     FilterBand (adaptive), ValidateReachable (GetPathPoints+PointArray),
     SelectSectorSpread. Procedural mouth selection, all vanilla maps.
     Attaches as Plugin.Placement.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i4a. ]]
local Plugin = ...

local Placement = {}
Placement.__index = Placement

-- Attach to the Plugin so other modules reach it as Plugin.Placement.
Plugin.Placement = Placement

return Placement
