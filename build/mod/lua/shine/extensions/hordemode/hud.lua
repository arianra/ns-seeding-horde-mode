--[[ Horde Mode — Hud (i9a).
     ScreenText (server-driven, zero client lua): wave counter + bots
     remaining, intermission countdown, joiner banner. Attaches as Plugin.Hud.
     STUB (i0a): loaded by server.lua via Shine.LoadPluginFile; receives Plugin
     as `...`. Real implementation lands in bead i9a. ]]
local Plugin = ...

local Hud = {}
Hud.__index = Hud

-- Attach to the Plugin so other modules reach it as Plugin.Hud.
Plugin.Hud = Hud

return Hud
