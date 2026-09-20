--[[ Horde Mode — Waves (i6a/i6b).
     v0 hardcoded composition; StartWave re-draws active mouths + spawns;
     WaveClear polling; intermission timer; endless increment.
     Variation-over-magnitude in late waves (Phase 2). Attaches as Plugin.Waves.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i6a/i6b. ]]
local Plugin = ...

local Waves = {}
Waves.__index = Waves

-- Attach to the Plugin so other modules reach it as Plugin.Waves.
Plugin.Waves = Waves

return Waves
