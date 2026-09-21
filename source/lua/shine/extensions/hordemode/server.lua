--[[
	Horde Mode — server entrypoint / lifecycle.

	Shine loads THIS file (extensions/hordemode/server.lua) and passes the
	Plugin object as `...`. Sibling modules are loaded explicitly via
	Shine.LoadPluginFile(PluginName, "file.lua", Plugin) — the proven
	voterandom/mapvote pattern (Shine does NOT auto-load a server/ subdir;
	see spike i0b layout finding).

	Responsibilities:
	  - world-ready gate (NO game APIs in Initialise; arm on first valid
	    GetGamerules() via OnFirstThink/SetGameState) — pitfall from spike zpw.
	  - bind commands (/horde, sh_horde_stop, sh_horde_status).
	  - drive the state machine; coordinate takeover, placement, spawner,
	    waves, triggers, economy, hud, teardown.

	Status: i1a — real Plugin definition (shared.lua) + this world-ready gate.
	Sibling modules are still stubs and each declares the bead that fills it.
]]

local Shine = Shine
local Plugin = ...
local PluginName = Plugin:GetName()

-- Shine only calls LoadConfig for extensions that opt in (extensions.lua:656 checks
-- Plugin.HasConfig), and LoadConfig concatenates ConfigName immediately - without both,
-- DefaultConfig never reaches disk and PreValidateConfig never runs on a real load.
-- Omitting ConfigName is not a silent miss: base_plugin/config.lua:32 throws and the
-- whole extension fails to enable, which hordemode_armed caught the first run.
Plugin.HasConfig = true
Plugin.ConfigName = "HordeMode.json"

-- How often the world-ready gate polls for gamerules.
local WORLD_POLL_SECONDS = 1

-- Module load order matters: leaf modules (no deps) first, orchestrators last.
-- Each sibling receives Plugin as `...` and attaches itself as Plugin.<Name>.
Shine.LoadPluginFile( PluginName, "config.lua", Plugin )        -- i1b
Shine.LoadPluginFile( PluginName, "statemachine.lua", Plugin )  -- i2a
Shine.LoadPluginFile( PluginName, "registry.lua", Plugin )      -- i3a
Shine.LoadPluginFile( PluginName, "takeover.lua", Plugin )      -- i3b
Shine.LoadPluginFile( PluginName, "placement.lua", Plugin )     -- i4a
Shine.LoadPluginFile( PluginName, "spawner.lua", Plugin )       -- i4b/i5a
Shine.LoadPluginFile( PluginName, "triggers.lua", Plugin )      -- i2b/i8a
Shine.LoadPluginFile( PluginName, "economy.lua", Plugin )       -- i6a
Shine.LoadPluginFile( PluginName, "waves.lua", Plugin )         -- i6a/i6b
Shine.LoadPluginFile( PluginName, "hud.lua", Plugin )           -- i9a

function Plugin:Initialise()
	-- Initialise runs BEFORE the world exists. GetGamerules() is nil here, and
	-- reaching into it (or any game API) crashes Gamerules_Global — the exact
	-- failure that cost spike zpw a boot cycle. So this function may touch flags
	-- and timers only; everything else waits for the gate below.
	self.HordeArmed = false
	self.HordePhase = Plugin.Phase.Inactive

	self:CreateTimer( "HordeModeWorldReady", WORLD_POLL_SECONDS, -1, function()
		self:TryArm()
	end )

	self.Enabled = true

	return true
end

--[[
  World-ready gate: poll until a real gamerules object exists, then arm once.
  Accessors verified on build 344 — NS2Gamerules:GetGameState() (:171) returns a
  kGameState (Globals.lua:265), and WarmUp is where the horde is meant to run.
]]
function Plugin:TryArm()
	if self.HordeArmed then
		return
	end

	local gamerules = GetGamerules()
	if not gamerules then
		return
	end

	self.HordeArmed = true
	self:DestroyTimer( "HordeModeWorldReady" )

	print( string.format( "%s armed at game state %s", Plugin.LogPrefix, tostring( gamerules:GetGameState() ) ) )

	self:OnWorldReady( gamerules )
end

-- Seam for the beads that follow: i8a starts loss polling here, i7a owns teardown
-- from here. Everything world-facing stays behind this call.
function Plugin:OnWorldReady( gamerules )
	self.Machine = Plugin.StateMachine.New(Shared.GetTime(), function(Message)
		print(("%s %s"):format(Plugin.LogPrefix, Message))
	end)

	-- NoPerm=true: /horde is a marine command, not an admin one (Q14 open access).
	self:BindCommand( "sh_horde", "horde", function(Client)
		self:OnHordeCommand(Client)
	end, true )

	-- Admin pair: no NoPerm, so Shine's permission check applies (i2c).
	self:BindCommand( "sh_horde_stop", nil, function(Client)
		self:OnHordeStop(Client)
	end )

	self:BindCommand( "sh_horde_status", nil, function(Client)
		self:OnHordeStatus(Client)
	end )
end

--- Status line, built from injected state so hordetest can assert every field in
--- every phase without faking a live horde. RD6 makes this a test surface, not
--- just a convenience: the teardown diff has to be readable somewhere.
function Plugin:BuildStatusLine(Snapshot, Machine, Config, Now)
	local Remaining = Plugin.Triggers:CooldownRemaining(Snapshot, Machine, Config, Now)

	return string.format(
		"state=%s wave=%s cooldown=%s marines=%s aliens=%s players=%s/%s mouths=%s/%s",
		Machine:GetState(),
		Machine:GetWave(),
		-- Units on the face of the value: a bare 50 could be seconds, percent or waves.
		Remaining and string.format("%.0fs", Remaining) or "none",
		tostring(Snapshot.RealMarineCount or 0),
		tostring(Snapshot.RealAlienCount or 0),
		tostring(Snapshot.PlayerCount or 0),
		tostring(Snapshot.MaxPlayers or 0),
		tostring(Machine.MouthsActive or "-"),
		tostring(Machine.MouthsPool or "-"))
end

--- All three command handlers are reachable the instant they are bound, and the
--- machine only exists once the world does. One guard, so the handlers cannot drift
--- apart the way they did between i2b and i2c.
function Plugin:RequireMachine(Name, Client)
	if self.Machine then
		return true
	end

	self:Log(Name .. " rejected: plugin is not armed yet")

	local Player = Client and Client:GetControllingPlayer() or nil

	if Player then
		self:Notify(Player, "Horde is not ready yet (%s)", true, Name)
	end

	return false
end

function Plugin:OnHordeStop(Client)
	if not self:RequireMachine("sh_horde_stop", Client) then
		return
	end

	local Player = Client and Client:GetControllingPlayer() or nil
	local Now = Shared.GetTime()

	local Ok, Reason = self.Machine:Stop("admin sh_horde_stop", Now)

	if not Ok then
		self:Log("stop rejected: " .. tostring(Reason))

		if Player then
			self:Notify(Player, "Horde stop rejected: %s", true, Reason)
		end

		return
	end

	self:Log("teardown requested by admin - state " .. self.Machine:GetState())

	-- Nothing destroyed here on purpose: i7a (M7) owns the registry walk, state
	-- restore and timer cancellation. Until then Stop() only moves the state, and
	-- this line is the seam it will hook into.

	if Player then
		self:Notify(Player, "Horde stopping: %s", true, self.Machine.TeardownReason or "admin stop")
	end
end

function Plugin:OnHordeStatus(Client)
	if not self:RequireMachine("sh_horde_status", Client) then
		return
	end

	local Player = Client and Client:GetControllingPlayer() or nil
	local Line = self:BuildStatusLine(Plugin.Triggers.TakeSnapshot(), self.Machine,
		self.HordeConfig.Resolve(Shared.GetMapName()), Shared.GetTime())

	self:Log("status " .. Line)

	if Player then
		self:Notify(Player, "Horde %s", true, Line)
	end
end

--- /horde entry: gates, then start. Rejection reason goes to the caller's chat
--- (Notify(Player, Message) - messaging.lua:201), never a silent no-op.
function Plugin:OnHordeCommand(Client)
	-- A command callback receives the *client*; the player is reached through
	-- Client:GetControllingPlayer() (Shine's own idiom, votesurrender/server.lua:296).
	-- Server.GetOwner goes the other way: player -> client.
	local Player = Client and Client:GetControllingPlayer() or nil
	local Now = Shared.GetTime()
	local Snapshot = Plugin.Triggers.TakeSnapshot()

	if not self:RequireMachine("sh_horde", Client) then
		return
	end

	local Config = self.HordeConfig.Resolve(Shared.GetMapName())
	local Allowed, Gate, Reason = Plugin.Triggers.Check(Snapshot, self.Machine, Config, Now)

	if not Allowed then
		self:Log(string.format("/horde rejected by %s: %s", Gate, Reason))

		if Player then
			self:Notify(Player, "Horde not started: %s", true, Reason)
		end

		return
	end

	local Ok, StartReason = self.Machine:Start(Now)

	if not Ok then
		self:Log("/horde rejected by the state machine: " .. tostring(StartReason))
		return
	end

	self:Log("horde started - wave 1")
end

function Plugin:Log(Message)
	print(("%s %s"):format(self.LogPrefix, Message))
end

--- Current effective config for this map, resolved once per read (deep merge is
--- cheap and this avoids stale copies after an admin edits the JSON).
function Plugin:HordeConfigResolve()
	return self.HordeConfig.Resolve(Shared.GetMapName())
end

function Plugin:Cleanup()
	if self:TimerExists( "HordeModeWorldReady" ) then
		self:DestroyTimer( "HordeModeWorldReady" )
	end

	if self.HordeArmed then
		print( string.format( "%s disarmed — extension unloaded", Plugin.LogPrefix ) )
		self.HordeArmed = false
		self.HordePhase = Plugin.Phase.Inactive
	end
end

return Plugin
