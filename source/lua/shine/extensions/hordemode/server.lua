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
HORDE_TICK_SECONDS = 1

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

	-- Handle retained: plugin timers sit in a weak-valued table, so a discarded
	-- repeating timer may be collected before the world ever arrives and the plugin
	-- would silently never arm.
	self.WorldReadyTimer = self:CreateTimer( "HordeModeWorldReady", WORLD_POLL_SECONDS, -1, function()
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
	self.WorldReadyTimer = nil

	print( string.format( "%s armed at game state %s", Plugin.LogPrefix, tostring( gamerules:GetGameState() ) ) )

	self:OnWorldReady( gamerules )
end

-- Seam for the beads that follow: i8a starts loss polling here, i7a owns teardown
-- from here. Everything world-facing stays behind this call.
function Plugin:OnWorldReady( gamerules )
	self.BotController = gamerules.botTeamController
	self.Machine = Plugin.StateMachine.New(Shared.GetTime(), function(Message)
		print(("%s %s"):format(Plugin.LogPrefix, Message))
	end)

	-- Accounting truth for everything we spawn; the engine's bot count cannot tell
	-- our bots from vanilla seeding ones (DESIGN.md:178,193).
	self.HordeRegistry = Plugin.Registry.New()

	-- Q7q7: /horde IS the horde warmup, so the vanilla fill is held off for the
	-- duration and handed back intact. Created here, engaged by i6a's wave loop.
	self.HordeTakeover = Plugin.Takeover.New(self.BotController, self.HordeRegistry)

	-- M4: mouths are created through the spawner, which queues them for registration
	-- on the next tick (a fresh entity has no usable id at creation time).
	self.HordeSpawner = Plugin.Spawner.New(self.HordeRegistry, function(Message)
		print(("%s %s"):format(Plugin.LogPrefix, Message))
	end)

	-- One pump per second while the world lives: register what was created last tick,
	-- and drop what has died, so the registry stays accounting truth for teardown (RD6).
	self.HordeTickTimer = self:CreateTimer( "HordeModeTick", HORDE_TICK_SECONDS, -1, function()
		self:HordeTick()
	end )

	-- NoPerm=true: /horde is a marine command, not an admin one (Q14 open access).
	-- Arguments are forwarded: the handler must be able to see them, or a stray word
	-- silently means "start".
	local HordeCommand = self:BindCommand( "sh_horde", "horde", function(Client, ...)
		self:OnHordeCommand(Client, { ... })
	end, true )

	-- Shine passes ONLY the arguments that match a declared parameter: with none
	-- declared, `/horde status` arrived at the handler as a bare `/horde`, which
	-- started a horde instead of reporting one. The audit line prints the raw text,
	-- so the log happily read "with arguments: status" while the handler saw nothing.
	HordeCommand:AddParam{ Type = "string", Optional = true }

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
function Plugin:BuildStatusLine(Snapshot, Machine, Config, Now, Reg, Not)
	local Remaining = Plugin.Triggers:CooldownRemaining(Snapshot, Machine, Config, Now)

	return string.format(
		"state=%s wave=%s cooldown=%s marines=%s aliens=%s bots=%s ours=%s takeover=%s players=%s/%s mouths=%s/%s",
		Machine:GetState(),
		Machine:GetWave(),
		-- Units on the face of the value: a bare 50 could be seconds, percent or waves.
		Remaining and string.format("%.0fs", Remaining) or "none",
		tostring(Snapshot.RealMarineCount or 0),
		tostring(Snapshot.RealAlienCount or 0),
		-- gServerBots is the engine's own bot roster (BotTeamController.lua:39,75-78).
		tostring(Snapshot.BotCount or 0),
		-- ours= is the registry's own bot count: the distinction vanilla cannot make.
		tostring(Reg and Reg:GetBotCount() or 0),
		(Not and Not:IsEngaged()) and "engaged" or "idle", 
		tostring(Snapshot.PlayerCount or 0),
		tostring(Snapshot.MaxPlayers or 0),
		-- Live count comes from the registry, not a cached field: a cached
		-- MouthsActive was stale by up to a tick and stayed non-zero after teardown,
		-- which is how "mouths=-/-" lied about a wave that had three real mouths.
		tostring(Reg and Reg:CountByKind("mouth") or 0),
		tostring(Machine.MouthsPool or 0))
end

--- A command callback receives the *client*; the player is reached through
--- Client:GetControllingPlayer() (Shine's own idiom, votesurrender/server.lua:296).
--- Server.GetOwner goes the other way: player -> client.
function Plugin:GetCommandPlayer(Client)
	if not Client or not Client.GetControllingPlayer then
		return nil
	end

	return Client:GetControllingPlayer()
end

--- All three command handlers are reachable the instant they are bound, and the
--- machine only exists once the world does. One guard, so the handlers cannot drift
--- apart the way they did between i2b and i2c.
function Plugin:RequireMachine(Name, Client)
	if self.Machine then
		return true
	end

	self:Log(Name .. " rejected: plugin is not armed yet")

	local Player = self:GetCommandPlayer(Client)

	if Player then
		self:Notify(Player, "Horde is not ready yet (%s)", true, Name)
	end

	return false
end

function Plugin:OnHordeStop(Client)
	if not self:RequireMachine("sh_horde_stop", Client) then
		return
	end

	local Player = self:GetCommandPlayer(Client)
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
	self:Teardown(Now)

	if Player then
		self:Notify(Player, "Horde stopping: %s", true, self.Machine.TeardownReason or "admin stop")
	end
end

function Plugin:OnHordeStatus(Client)
	if not self:RequireMachine("sh_horde_status", Client) then
		return
	end

	local Player = self:GetCommandPlayer(Client)
	local Line = self:BuildStatusLine(Plugin.Triggers.TakeSnapshot(Client), self.Machine,
		self.HordeConfig.Resolve(Shared.GetMapName()), Shared.GetTime(), self.HordeRegistry,
		self.HordeTakeover)

	self:Log("status " .. Line)

	if Player then
		self:Notify(Player, "Horde %s", true, Line)
	end
end

--- /horde entry: dispatch on the first word, then gates, then start. Every path
--- answers in chat (Notify(Player, Message) - messaging.lua:201); none is silent.
---
--- Before this, status/stop were console-only (i2c bound them with no chat alias), so
--- `/horde status` fell straight through to "start" and began wave 1 - and because
--- Shine's RunCommand writes its audit line AFTER the handler ran, the log showed a
--- start with no command above it. The first word a curious player types must never
--- be a state change.
function Plugin:OnHordeCommand(Client, Args)
	local Word = Args and Args[1]
	local Player = self:GetCommandPlayer(Client)
	local Now = Shared.GetTime()

	-- `/horde start` is the obvious thing to type, and silently starting on a bare
	-- `/horde` while rejecting `/horde start` would be a strange contract.
	if Word == "start" then
		Word = nil
	end

	if Word == "restart" then
		-- Restart is teardown-then-start, not start-over-start: the wave counter, the
		-- cooldown clock and any live mouths all have to go back to a known state, and
		-- BeginWave on top of a running wave would leave the old mouths orphaned.
		if not self:RequireMachine("sh_horde restart", Client) then
			return
		end

		if self.Machine:IsActive() then
			self.Machine:Stop("admin sh_horde restart", Now)
			self:Teardown(Now)
		end

		self:StartWave(Client, Now)
		return
	end

	if Word == "status" then
		self:OnHordeStatus(Client)
		return
	end

	if Word == "stop" then
		-- Open by request (2026-09-22): `/horde` is a marine command with NoPerm, so a
		-- stop that needs a Shine admin identity was unreachable in practice - and
		-- unreachable means a stuck wave nobody in the game can end. The console command
		-- sh_horde_stop keeps its permission check for anyone scripting the server.
		self:OnHordeStop(Client)
		return
	end

	if Word then
		self:Log(string.format("/horde rejected: unknown argument '%s'", tostring(Word)))

		if Player then
			self:Notify(Player, "HORDE: unknown argument '%s'. Commands: /horde | /horde status | /horde stop | /horde restart", true, tostring(Word))
		end

		return
	end

	return self:StartWave(Client, Now)
end

--- The gated start, shared by bare `/horde` and `/horde restart` so the two can never
--- drift apart on which checks apply.
function Plugin:StartWave(Client, Now)
	local Player = self:GetCommandPlayer(Client)
	local Snapshot = Plugin.Triggers.TakeSnapshot(Client)

	if not self:RequireMachine("sh_horde", Client) then
		return
	end

	local Config = self.HordeConfig.Resolve(Shared.GetMapName())
	local Allowed, Gate, Reason = Plugin.Triggers.Check(Snapshot, self.Machine, Config, Now)

	if not Allowed then
		self:Log(string.format("/horde rejected by %s: %s", Gate, Reason))

		if Player then
			self:Notify(Player, "HORDE: not started - %s. Use /horde status to see it, /horde stop to end it, /horde restart to reset.", true, Reason)
		end

		return
	end

	local Ok, StartReason = self.Machine:Start(Now)

	if not Ok then
		self:Log("/horde rejected by the state machine: " .. tostring(StartReason))
		return
	end

	self:Log("horde started - wave 1")

	-- Clean slate (D1). Reset before the machine starts so a failed reset cannot leave a
	-- half-initialised wave; the gates were already evaluated against the PRE-reset world,
	-- which is the only moment "no aliens, below seeding max" means anything.
	if Config.Start and Config.Start.ResetRound ~= false then
		local OkReset, ResetErr = self:ResetWorldForHorde()

		if not OkReset then
			self:Log("clean slate failed: " .. tostring(ResetErr))

			if Player then
				self:Notify(Player, "HORDE: could not reset the round - %s", true, tostring(ResetErr))
			end

			return
		end
	end

	local Seconds = self:BeginCountdown(Config.Start and Config.Start.CountdownSeconds)

	self:BeginWave(Config)

	self:Announce("HORDE: round reset, vanilla bots cleared. Wave 1 opens in %s seconds - you spawn when the count hits zero.", Seconds)
end

--- Clean slate: wipe what the previous session left, then hand the round to vanilla's
--- own countdown. Decided 2026-09-22 (D1): /horde does NOT layer onto a running round.
---
--- There is no engine restart API - Server.RestartRound and Server.ChangeLevel do not
--- exist in build 344. NS2Gamerules' own local StartCountdown (:1852) does exactly three
--- public things, replicated here because the local function is unreachable: ResetGame,
--- SetGameState(Countdown), countdownTime = kCountDownLength. UpdatePregame's Countdown
--- branch (:1893-1911) then drives it to Started on its own, with players input-locked
--- (Player.lua:1515-1518) and the client already showing "Game is starting"
--- (Player_Client.lua:2616-2619) - so the countdown needs no client code at all.
---
--- Order is load-bearing and stated here because getting it wrong is invisible:
--- ResetGame() calls DestroyLiveMapEntities (NS2Gamerules.lua:496-516), so anything we
--- create BEFORE it is deleted by it. Mouths therefore come after the reset and during
--- the countdown - which is exactly the "world state exists before you spawn" rule.
function Plugin:ResetWorldForHorde()
	local gamerules = GetGamerules()

	if not gamerules then
		return false, "no gamerules yet"
	end

	-- Our own leftovers first: the registry must not survive pointing at corpses.
	Plugin.DestroyAll(self.HordeRegistry,
		self.HordeSpawner and self.HordeSpawner:TakePending() or nil, nil)

	-- Vanilla fill: cap both teams to zero and update, then disconnect whoever is left.
	-- The config zeros committed in L2 are what stop it refilling on the next map; this
	-- is what clears THIS round.
	if gamerules.SetMaxBots then
		pcall(function() gamerules:SetMaxBots(0, false) end)
		pcall(function() gamerules:SetMaxBots(0, true) end)
	end

	if gServerBots then
		for Index = #gServerBots, 1, -1 do
			local Bot = gServerBots[Index]

			pcall(function()
				if Bot and Bot.Disconnect then Bot:Disconnect() end
			end)
		end
	end

	local Ok, Err = pcall(function() gamerules:ResetGame() end)

	if not Ok then
		return false, string.format("ResetGame failed: %s", tostring(Err))
	end

	return true, nil
end

--- Hand the round to vanilla's countdown. Returns the seconds the client will see.
function Plugin:BeginCountdown(Seconds)
	local gamerules = GetGamerules()

	if not gamerules or not gamerules.SetGameState then
		return 0
	end

	local Length = Seconds or kCountDownLength or 6

	gamerules:SetGameState(kGameState.Countdown)
	gamerules.countdownTime = Length
	gamerules.lastCountdownPlayed = nil

	return Length
end

--- Place and create this wave's mouths. Nothing walks out of them yet - that is i5a
--- (bot spawner) and i6a (wave loop) - but a horde with no mouths is invisible, and
--- this is the bead that makes /horde observable in-world.
function Plugin:BeginWave(Config)
	local Machine = self.Machine
	local Chosen, Base, RawCount, BandedCount = Plugin.Placement.Collect(Config)

	if not Base then
		self:Log("placement: no base anchor on this map, so the band exclusion is off")
	end

	local Spawned = 0

	for _, Candidate in ipairs(Chosen) do
		local Mouth, Reason = self.HordeSpawner:SpawnMouth(Candidate.point)

		if Mouth then
			Spawned = Spawned + 1
		else
			self:Log("mouth not spawned: " .. tostring(Reason))
		end
	end

	-- "Nothing appeared" must never be silent. The three counts separate a map with no
	-- anchor entities from a band that misses the map from a spawn call that failed.
	if Spawned == 0 then
		local Waves = (Config and Config.Waves) or {}

		self:Announce("HORDE: the wave could NOT be placed - %s candidates found, %s in the band, %s chosen. Check Waves.BandMin/BandMax for this map.",
			RawCount, BandedCount, #Chosen)

		self:Log(string.format(
			"wave 1 produced NO mouths: %s raw candidates, %s in band, %s chosen (band %s-%sm, pool %s, per wave %s)",
			tostring(RawCount), tostring(BandedCount), tostring(#Chosen),
			tostring(Waves.BandMin), tostring(Waves.BandMax), tostring(Waves.PoolSize), tostring(Waves.ActivePerWave)))
	else
		self:Log(string.format("wave 1: %s mouths placed from %s candidates", tostring(Spawned), tostring(RawCount)))
		self:Announce("HORDE: WAVE 1 - %s tunnel mouths opened (%s candidates on this map). /horde status | /horde stop | /horde restart",
			Spawned, RawCount)
	end

	-- The status surface reads these off the machine, and nothing used to write them:
	-- BuildStatusLine fell back to "-" while three real mouths sat in the world, so
	-- the command actively reported an empty wave. MouthsActive is kept current by
	-- HordeTick from the registry, which is the only accounting truth (RD6).
	Config.Waves = Config.Waves or {}
	Machine.MouthsPool = Spawned
	Machine.MouthsActive = Spawned

	return Spawned
end

--- Registry upkeep once per second. Kept separate from the wave logic so a wave can
--- never leave dead refs behind just because it stopped early.
function Plugin:HordeTick()
	if self.HordeSpawner then
		self.HordeSpawner:Pump()
	end

	local Reg = self.HordeRegistry

	if Reg and self.Machine then
		-- Prune below can drop dead refs, so the count is refreshed after it; keeping
		-- the two adjacent is what makes the status line a measurement rather than a
		-- number someone remembered to update.
		self.Machine.MouthsActive = Reg:CountByKind("mouth")
	end

	if Reg then
		Reg:Prune(function(Ref, Id)
			-- Bots are judged by their player: after Disconnect() the entity id still
			-- resolves for a tick (registry.lua:217). Mouths have no such alias.
			if Reg:GetKind(Id) == "bot" then
				local Player = Ref.GetPlayer and Ref:GetPlayer()

				return not Player or (Player.GetIsDestroyed and Player:GetIsDestroyed()) or false
			end

			return Shared.GetEntity(Id) == nil
		end)
	end
end

--- Total entities in the world. Used only for the teardown diff, so a failure to
--- ask the engine reports -1 rather than throwing through a stop.
function Plugin.EntityCount()
	local Ok, List = pcall(function() return Shared.GetEntitiesWithClassname("Entity") end)

	if Ok and List then
		return List:GetSize()
	end

	return -1
end

--- Destroy the created set: bots by player first (Disconnect releases the virtual
--- client, then the entity goes), mouths by Kill then DestroyEntity - Kill alone
--- leaves the entity in the world for a frame, which is enough to make the diff lie.
--- Injectable on purpose: i7b asserts integrity against real entities without
--- needing a live wave.
function Plugin.DestroyAll(Reg, Pending, Log)
	local Destroyed, Failed = {}, {}

	local Entries = Reg and Reg:Drain() or {}

	for _, Item in ipairs(Pending or {}) do
		Entries[#Entries + 1] = { ref = Item.ref, kind = Item.kind }
	end

	local Ids = {}

	for _, Item in ipairs(Entries) do
		local Ref = Item.ref
		local Kind = Item.kind or "other"

		if Item.id then
			Ids[#Ids + 1] = Item.id
		end

		local Ok, Err = pcall(function()
			if Kind == "bot" and Ref.Disconnect then
				Ref:Disconnect()
			elseif Kind == "mouth" and Ref.Kill then
				Ref:Kill()
			end

			DestroyEntity(Ref)
		end)

		if Ok then
			Destroyed[Kind] = (Destroyed[Kind] or 0) + 1
		else
			Failed[#Failed + 1] = string.format("%s: %s", Kind, tostring(Err))
		end
	end

	return Destroyed, Failed, #Entries, Ids
end

--- i7a: put the world back. RD6 sets the bar - destroy exactly our created set,
--- restore what we took over, and log a diff so a leak cannot pass silently.
--- Runs while the machine is in Teardown and finishes with CompleteTeardown, so the
--- cooldown clock starts only once the world is clean. ScreenText is not cleared
--- because nothing sets it yet; that belongs to the HUD in i9a.
function Plugin:Teardown(Now)
	local Machine = self.Machine

	if not Machine then
		return
	end

	local Destroyed, Failed, Total, Ids = Plugin.DestroyAll(self.HordeRegistry,
		self.HordeSpawner and self.HordeSpawner:TakePending() or nil, nil)

	-- v0 restore is the bot controller only. Team resources and any other engine state
	-- we later touch are logged rather than guessed at (DESIGN.md: full restore is Phase 2).
	local Took = false

	if self.HordeTakeover then
		Took = self.HordeTakeover:IsEngaged()

		self.HordeTakeover:Release()
	end

	Machine.MouthsPool = 0
	Machine.MouthsActive = 0

	local Ok, Reason = Machine:CompleteTeardown(Now or Shared.GetTime())

	local Parts = {}

	for Kind, Count in pairs(Destroyed) do
		Parts[#Parts + 1] = string.format("%s=%s", Kind, tostring(Count))
	end

	table.sort(Parts)

	-- Poll our own ids, not the global entity count. Measured: destroying 2 mouths
	-- while the count moved 245 -> 249, because unrelated engine churn dominates it.
	-- Only "does this id still resolve" can actually catch a leak.
	local Leaked = {}

	for _, Id in ipairs(Ids) do
		if Shared.GetEntity(Id) ~= nil then
			Leaked[#Leaked + 1] = Id
		end
	end

	self:Log(string.format("teardown %s: %s of %s destroyed (%s), controller released=%s, %s id(s) still live",
		#Leaked == 0 and "PASS" or "FAIL",
		tostring(Total - #Failed), tostring(Total),
		#Parts > 0 and table.concat(Parts, " ") or "nothing to destroy",
		tostring(Took), tostring(#Leaked)))

	if #Failed > 0 then
		self:Log(string.format("teardown FAILED for %s entries: %s", tostring(#Failed), table.concat(Failed, "; ")))
	end

	if not Ok then
		self:Log("teardown could not return to inactive: " .. tostring(Reason))
	end

	return Ok
end

--- Broadcast to every player, and mirror it to the log.
---
--- Shine's Notify takes a player; a nil target reaches ApplyNetworkMessage, which calls
--- SendNetworkMessage with no client - i.e. a broadcast (core/server/logging.lua:65-85).
--- Verified rather than assumed: "silence unless refused" was exactly the complaint, and
--- the fix is only real if the message actually reaches everyone.
function Plugin:Announce(Message, ...)
	self:Log(string.format("ANNOUNCE: %s", string.format(Message, ...)))
	self:Notify(nil, Message, true, ...)
end

function Plugin:Log(Message)
	print(("%s %s"):format(self.LogPrefix, Message))
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
