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
	self.HordeRegistry = Plugin.Registry.New(Plugin.Registry.EngineStateOf)

	-- Q7q7: /horde IS the horde warmup, so the vanilla fill is held off for the
	-- duration and handed back intact. Engaged by ResetWorldForHorde, released by Teardown -
	-- the pair has to be symmetric or the server's bot configuration stays at our zero.
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
		"state=%s wave=%s cooldown=%s marines=%s aliens=%s bots=%s ours=%s takeover=%s players=%s/%s mouths=%s/%s reveal=%s",
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
		tostring(Machine.MouthsPool or 0),
		-- `reveal=` is the direct answer to "why can't I see the mouths". on/off is what the
		-- config says; `-` means the loaded config has no Debug section at all (a file from
		-- before the flag existed), which is a different fact and must not read as "off".
		(Config and Config.Debug and Config.Debug.RevealMouths ~= nil)
			and (Config.Debug.RevealMouths and "on" or "off") or "-")
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

		-- A restart is asked for; a cooldown is a brake on spam. Applying the second to the
		-- first is what made `/horde restart` feel broken from the chair (2026-09-28): the
		-- teardown the restart itself ran started the clock, and the start the restart then
		-- asked for was refused by it. The wait still disciplines a bare `/horde` after a
		-- stop; it can never gate a command whose entire meaning is "start again".
		self.Machine:ClearCooldown()

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

	-- Order matters to the person reading chat. The first version announced "WAVE 1 - 3
	-- tunnel mouths opened" from inside BeginWave and only then said the round was being
	-- reset, which reads as a mode that started, stopped and started again.
	self:Announce("HORDE: round reset - vanilla bots cleared. You spawn when the count reaches zero (%s s).", Seconds)

	self:BeginWave(Config)

	-- 61a: the loss latches are round state. A station that only existed in the
	-- previous horde round must not make THIS one lose on its first tick, and a
	-- wipe clock from an old round is not a head start on this one.
	self.HordeLoss = nil
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

	-- The vanilla fill is taken over, not overwritten. Engaging snapshots the server's real bot
	-- configuration, holds the fill loop off, and caps it to zero; releasing at teardown is what
	-- puts the bots back. The direct SetMaxBots(0) this replaces left the cap at zero for the rest
	-- of the map's life - measured 2026-09-26, when /horde stop reported a clean teardown and no
	-- bot ever returned. It also collapsed both commander flags into one value on the way down
	-- (BotTeamController.lua:185-193), so a restore without a snapshot could not have put them
	-- back even if it had remembered to try.
	if self.HordeTakeover then
		local Engaged, EngageReason = self.HordeTakeover:Engage()

		if not Engaged then
			self:Log("bot takeover refused: " .. tostring(EngageReason))
		end
	end

	-- Whoever is still standing goes now; the cap only stops the NEXT one arriving.
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

	-- After ResetGame, never before: ResetGame clears preventGameEnd
	-- (NS2Gamerules.lua:702), so engaging it first would be undone by the very
	-- call that starts the round.
	self:SuppressGameEnd()

	-- We own the round now, and only we can give it back. Teardown's world handback is gated on
	-- this flag: stopping a horde that never took a round over must not reset a game it did not
	-- start.
	self.HordeRoundStarted = true

	return true, nil
end

--- Switch vanilla's automatic win/loss off for the duration of a horde round, and only
--- for its duration.
---
--- Why this is load-bearing, not cosmetic: `PlayingTeam:GetHasTeamLost`
--- (ns2/lua/PlayingTeam.lua:536-546) reports a loss when a team has no alive command
--- structure, OR no players, OR nothing alive that can respawn. A horde round has no alien
--- hive and - until the bot spawner (i5a) exists - no aliens at all, so both the hive and
--- the player-count conditions are true on the first frame and `CheckGameEnd` hands the
--- marines the win the moment the round starts. Observed: the marine joined and was shown
--- the victory screen immediately.
---
--- `preventGameEnd` is the engine's own switch and the only field `CheckGameEnd` consults
--- (ns2/lua/NS2Gamerules.lua:1788), so one assignment suppresses the whole family - team
--- wipe, missing hive, auto-concede, draw. Nothing is replaced and no world entity is
--- faked, which is what keeps the isolation promise honest: the mode touches one field on
--- one object, and the field is the engine's, so the engine's own reset semantics apply.
---
--- Those semantics are the trap: `ResetGame` clears it (NS2Gamerules.lua:702). So the flag
--- is read from the gamerules object rather than mirrored on ourselves, and the tick
--- re-asserts it - a voteresetgame or map change mid-round cannot bring the vanilla win
--- back unnoticed.
function Plugin:SuppressGameEnd()
	local gamerules = GetGamerules()

	if not gamerules or not gamerules.SetPreventGameEnd then
		return false
	end

	if gamerules.preventGameEnd then
		return false
	end

	gamerules:SetPreventGameEnd(true)
	self:Log("game-end suppression engaged - vanilla win/loss cannot fire while a horde round is live")

	return true
end

--- Hand game-end decisions back to vanilla. Idempotent, and it reports through the engine's
--- field, not our memory of it, so a teardown after a surprise reset still says the truth.
function Plugin:RestoreGameEnd(Reason)
	local gamerules = GetGamerules()

	if not gamerules or not gamerules.SetPreventGameEnd or not gamerules.preventGameEnd then
		return false
	end

	gamerules:SetPreventGameEnd(nil)
	self:Log(string.format("game-end suppression released (%s) - vanilla win/loss is active again",
		tostring(Reason)))

	return true
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

--- Every wave starts from a cleared board. Whatever mouths and bots outlived the last
--- wave - an exit path that skipped the wave-end drain, a feature not yet written that
--- forgets - are destroyed HERE, before this wave places or deals anything, so the wave
--- the marines see is exactly this wave's set. The end drain stays (bots must die when
--- the wave does, or intermission is a hunt, not a build phase); this is the belt AND
--- the braces: without a start cull, one stale bot alive forever keeps `CountByKind("bot")`
--- - which is not wave-scoped - nonzero and no later wave can ever clear.
--- The return is the drained-by-kind count: what the books promised, not what the engine
--- confirmed (a failed destroy is logged AND stays pollable via the ever-id history at
--- teardown, which owns the difference).
function Plugin:CullPreviousWave()
	local Reg = self.HordeRegistry

	if not Reg then
		return 0, 0
	end

	local Entries = {}

	for _, Item in ipairs(Reg:DrainKind("bot")) do
		Entries[#Entries + 1] = Item
	end

	for _, Item in ipairs(Reg:DrainKind("mouth")) do
		Entries[#Entries + 1] = Item
	end

	if #Entries == 0 then
		return 0, 0
	end

	local Destroyed, Failed = Plugin.DestroyEntries(Entries,
		Reg.StateOf or Plugin.Registry.EngineStateOf)

	local CulledBots, CulledMouths = 0, 0

	for _, Item in ipairs(Entries) do
		if Item.kind == "bot" then
			CulledBots = CulledBots + 1
		elseif Item.kind == "mouth" then
			CulledMouths = CulledMouths + 1
		end
	end

	self:Log(string.format("wave start culled carry-over: %s bots, %s mouths (%s destroyed cleanly)%s",
		tostring(CulledBots), tostring(CulledMouths),
		tostring((Destroyed.bot or 0) + (Destroyed.mouth or 0)),
		#Failed > 0 and (", FAILED: " .. table.concat(Failed, "; ")) or ""))

	return CulledBots, CulledMouths
end

--- Place and spawn this wave: the cleared board first (CullPreviousWave), then mouths
--- (only at engine-validated points), then the wave's bots dealt over the mouths that
--- actually exist. 61a turned the flat STEP A knob into the curve: wave size is
--- `Waves.HordeSize` at this wave's progress, and what BeginWave records on the machine
--- (`WaveMouths`, `WaveBots`) is what the clear predicates compare the living registry
--- counts against - PER WAVE on purpose, so a leftover can never hold a wave hostage.
--- The mouth set is this wave's full expectation (Arian 2026-09-30: "at every wave start
--- make sure we have the amount of mouths expected for that wave"): old ones are gone,
--- the draw is fresh and complete - or the deficit says so out loud. A per-wave MOUTH
--- count curve can ride here at RD3; ActivePerWave stays the static expectation for now.
function Plugin:BeginWave(Config)
	local Machine = self.Machine
	local WaveNumber = (Machine and Machine:GetWave()) or 1

	self:CullPreviousWave()

	--- A fresh draw per wave, seeded and logged. The first version swept a fixed grid and then took
	--- the nearest candidate per sector, so every wave on every boot landed in the same rooms -
	--- reported from the chair as "surprisingly in the exact same positions". The seed goes in the
	--- log because a placement someone reports has to be reproducible: the coordinates say where a
	--- mouth ended up, only the seed says why that one.
	local Seed = Plugin.Placement.SeedFor(WaveNumber, Shared.GetSystemTime(), Shared.GetTime())
	local Random = Plugin.Placement.NewRandom(Seed)

	local Chosen, Base, RawCount, BandedCount, Stats = Plugin.Placement.Collect(Config, nil, nil, Random)

	--- The ring's centre is also the horde's standing objective (t28's answer, chair
	--- 2026-09-30): the chair's origin when it stands, else the infestation centroid -
	--- the base room either way. Saved per wave because placement already computed it,
	--- and a bot needs a destination the moment it materialises.
	self.HordeBaseAnchor = Base

	if not Base then
		self:Log("placement: no base anchor on this map, so the band exclusion is off")
	end

	-- Debug.RevealMouths is resolved once per wave and handed to the spawner, which then
	-- owns it: the spawn reveals, and the tick re-asserts. Owning it in two places was the
	-- bug the suite caught - a mouth built unrevealed was revealed anyway a second later by
	-- the registry-wide refresh, so the per-call argument had no meaning left.
	local Reveal = (Config.Debug and Config.Debug.RevealMouths) == true
	self.HordeSpawner.Reveal = Reveal

	local Spawned = 0
	local Refused = {}
	local PlacedPoints = {}

	for Index, Candidate in ipairs(Chosen) do
		local Mouth, Reason = self.HordeSpawner:SpawnMouth(Candidate.point)

		if Mouth then
			Spawned = Spawned + 1
			PlacedPoints[#PlacedPoints + 1] = Candidate.point

			-- Every coordinate we put a structure at, in the log. "3 mouths placed from
			-- 46 candidates" is what we had when a marine reported all three inside the rock:
			-- the count was correct and useless, and the only way to find out where they went
			-- was to walk the map looking for them.
			self:Log(string.format("mouth %s at (%.1f, %.1f, %.1f) %sm from base id=%s",
				tostring(Index),
				Plugin.Placement.Axis(Candidate.point, "x", 1),
				Plugin.Placement.Axis(Candidate.point, "y", 2),
				Plugin.Placement.Axis(Candidate.point, "z", 3),
				string.format("%.1f", Candidate.distance or -1),
				tostring(Mouth:GetId())))
		else
			Refused[#Refused + 1] = tostring(Reason)
		end
	end

	-- 61a: the wave's size comes from the curve, dealt round-robin over the mouths that
	-- actually exist - a refused candidate takes no share, and the sum stays the wave's.
	-- Bots emerge AT their mouth's validated point through the queue the tick pumps;
	-- this call returns while they are still pending, and the clear predicate knows that
	-- because Outstanding() says so.
	local WaveSize = Plugin.Waves.HordeSize(Config.Waves, Plugin.HordeConfig.EvaluateCurve, WaveNumber)
	local Shares = Plugin.Waves.Distribute(WaveSize, Spawned)
	local BotsSpawned = 0

	for Index, Point in ipairs(PlacedPoints) do
		for _ = 1, Shares[Index] or 0 do
			if self.HordeSpawner:SpawnBot(Point, kTechId.Skulk) then
				BotsSpawned = BotsSpawned + 1
			end
		end
	end

	-- "Nothing appeared" must never be silent, and the counts separate the three ways it can
	-- happen: no anchor entities at all, anchors that the engine refuses as unbuildable, or a
	-- band that misses this map.
	if Spawned == 0 then
		local WaveKeys = (Config and Config.Waves) or {}

		self:Announce(string.format(
			"HORDE: the wave could NOT be placed - %s anchors, %s buildable, %s in the band, %s chosen. Check Waves.BandMin/BandMax for this map.",
			tostring(RawCount), Plugin.Placement.ReasonCounts(Stats), tostring(BandedCount), tostring(#Chosen)))

		self:Log(string.format(
			"wave %s produced NO mouths: anchors %s, buildable [%s], in band %s, chosen %s, refused [%s] (band %s-%sm, pool %s, per wave %s)",
			tostring(WaveNumber), tostring(RawCount), Plugin.Placement.ReasonCounts(Stats), tostring(BandedCount), tostring(#Chosen),
			table.concat(Refused, "; "), tostring(WaveKeys.BandMin), tostring(WaveKeys.BandMax),
			tostring(WaveKeys.PoolSize), tostring(WaveKeys.ActivePerWave)))
	else
		self:Log(string.format("wave %s: %s mouths placed from %s anchors [%s]%s seed=%s, %s bots dealt from curve size %s",
			tostring(WaveNumber), tostring(Spawned), tostring(RawCount), Plugin.Placement.ReasonCounts(Stats),
			#Refused > 0 and (", refused: " .. table.concat(Refused, "; ")) or "", tostring(Seed),
			tostring(BotsSpawned), tostring(WaveSize)))

		-- The wave-start promise is ACTIVEPERWAVE mouths (Arian 2026-09-30); a draw that came
		-- up short is still a wave, but the announcement says so - a silent 2-of-3 is how the
		-- 5ss summit judgement stayed invisible behind a green "3 mouths placed" line.
		local Expected = (Config.Waves and Config.Waves.ActivePerWave) or 0
		local Deficit = (Expected > 0 and Spawned < Expected)
			and string.format(" (only %s of %s this map can build in the band)", tostring(Spawned), tostring(Expected)) or ""

		-- Formatted HERE, not passed as Notify varargs: Shine would hand the template to the
		-- clients to format, but the announce contract is asserted server-side
		-- (wave_slice_end_to_end hooks Notify) - and a broadcast with %s in it is not an announcement.
		self:Announce(string.format("HORDE: WAVE %s - %s tunnel mouths, %s aliens incoming%s%s. /horde status | /horde stop | /horde restart",
			tostring(WaveNumber), tostring(Spawned), tostring(BotsSpawned),
			Reveal and " (revealed on your map)" or "", Deficit))
	end

	-- The status surface reads these off the machine, and nothing used to write them:
	-- BuildStatusLine fell back to "-" while three real mouths sat in the world, so
	-- the command actively reported an empty wave. MouthsActive is kept current by
	-- HordeTick from the registry, which is the only accounting truth (RD6).
	Config.Waves = Config.Waves or {}
	Machine.MouthsPool = Spawned
	Machine.MouthsActive = Spawned
	Machine.WaveMouths = Spawned
	Machine.WaveBots = BotsSpawned

	--- The wave's bookkeeping identity: the clear/loss predicates below compare LIVE
	--- counts against this wave's books, so they are only meaningful against the exact
	--- registry and spawner this wave was placed into. A harness swap (or any future
	--- mid-wave replacement) mounting foreign books on the plugin must not let the wave
	--- end against them - the 61a suite proved it destroys real entities: wave_slice's
	--- live machine read revealed_mouths' registry, `Cleared(3,0,0)` fired on a spawner
	--- that had never held a bot, and the EndWavePhase drain killed a mouth another
	--- scenario was watching.
	Machine.WaveReg, Machine.WaveSpawner = self.HordeRegistry, self.HordeSpawner

	return Spawned
end

--- Where the horde is going: the living marine command station if one stands (its origin
--- is exact), else this wave's base anchor, ground-snapped once (the infestation centroid
--- is a table at y=0 and the fallback of a fallback is no waypoint at all). Nil means
--- this map gave us nothing to walk to, said once per wave, not every tick.
function Plugin:ResolveHordeTarget()
	for Ent in ientitylist(Shared.GetEntitiesWithClassname("CommandStructure")) do
		local Ok, Origin = pcall(function()
			if Ent:GetTeamNumber() == kTeam1Index and Ent:GetIsAlive() then
				return Ent:GetOrigin()
			end
		end)

		if Ok and Origin then
			self.HordeNoTargetLogged = nil

			return Origin
		end
	end

	local Anchor = self.HordeBaseAnchor

	if not Anchor then
		if not self.HordeNoTargetLogged then
			self.HordeNoTargetLogged = true

			self:Log("steer: no base anchor and no marine station - the horde has nowhere to walk")
		end

		return nil
	end

	if not self.HordeBaseSnapped then
		local Point = Vector(Anchor.x, Anchor.y + 2, Anchor.z)
		local Snapped = GetGroundAtPointWithCapsule(Point, Vector(0.5, 0.5, 0.5),
			PhysicsMask.CommanderBuild, CreateFilter(nil))

		self.HordeBaseSnapped = Snapped or Vector(Anchor.x, Anchor.y, Anchor.z)
	end

	return self.HordeBaseSnapped
end

--- The t28 fallback, and the answer to "brain-native or order-driven": NEITHER for
--- skulks - their brain has no roam action and does not consume the player order queue
--- (SkulkBrain_Data has attack-within-50m-of-a-team-memory and an interrupt; only
--- Exo/marine-type brains read orders, ExoBrain_Data.lua:288). Left alone they stand at
--- the mouth, which is what the chair saw. So the tick writes the motion layer directly:
--- a standing move target toward the base. Combat still owns the bot while it fights
--- (the attack action's perform overwrites the target); this re-arms after, and
--- SetDesiredMoveTarget is a no-op when the target hasn't moved, so the refresh is free.
--- Returns how many bots were steered.
function Plugin:SteerHordeBots()
	local Reg = self.HordeRegistry

	if not Reg then
		return 0
	end

	local Target = self:ResolveHordeTarget()

	if not Target then
		return 0
	end

	local Steered = 0

	Reg:IterateByKind("bot", function(Ref)
		local Ok, Did = pcall(function()
			local Player = Ref.GetPlayer and Ref:GetPlayer()

			if not Player or not Player:GetIsAlive() then
				return false
			end

			if Player.GetIsInCombat and Player:GetIsInCombat() then
				return false
			end

			local Motion = Ref:GetMotion()

			if not Motion then
				return false
			end

			Motion:SetDesiredMoveTarget(Target)

			return true
		end)

		if Ok and Did then
			Steered = Steered + 1
		end
	end)

	return Steered
end

--- Registry upkeep once per second. Kept separate from the wave logic so a wave can
--- never leave dead refs behind just because it stopped early.
function Plugin:HordeTick()
	local Reg = self.HordeRegistry

	--- Corpses leave the books FIRST, and the order is the whole fix. Reveal used to run above
	--- the prune, threw on a mouth the player had just killed ("Attempt to access an object that
	--- no longer exists"), and the throw took the rest of the tick with it: nothing was
	--- re-asserted, so the two LIVING mouths blinked off the marine minimap when their 1.5 s
	--- detection lapsed, and nothing was pruned, so /horde status went on reporting 3/3 on an
	--- empty map. One dead handle, three symptoms, and a green suite because no scenario had ever
	--- killed a mouth mid-round.
	if Reg then
		Reg:PruneDead()
	end

	if self.HordeSpawner then
		self.HordeSpawner:Pump()

		-- Detection expires on its own 1.5 s after it was last asserted
		-- (DetectableMixin.lua:98-105), so a reveal set once at spawn blinks off between
		-- waves; this 1 s tick is what holds it up. A no-op while the spawner's Reveal is
		-- off, so there is no second flag that can fall out of step with the first.
		self.HordeSpawner:RefreshReveal()
	end

	-- One second is the worst case for a vanilla reset slipping the engine's win check
	-- back in under a live horde.
	if self.Machine and self.Machine:IsActive() then
		self:SuppressGameEnd()
	end

	-- Measured after the prune and the pump, so the status line reports what the engine has
	-- rather than what we remember creating.
	if Reg and self.Machine then
		self.Machine.MouthsActive = Reg:CountByKind("mouth")
	end

	-- t28: the standing waypoint, written every tick while the wave runs (a no-op when
	-- the target hasn't moved, so the refresh is free; combat overwrites it and this
	-- re-arms after).
	if self.Machine and self.Machine:GetState() == Plugin.Phase.Wave then
		self:SteerHordeBots()
	end

	-- 61a: the wave loop's pulse. Runs after the prune and the pump so it decides on
	-- the same counts the status line is about to report, never on a tick-old view.
	if self.Machine and self.Machine:IsActive() then
		self:EvaluateWaveState(Shared.GetTime())
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

--- The wave loop's pulse, run from the world tick. Everything it reads is injectable for
--- one reason: the harness cannot grow a real wave inside the ~8 s deferred ceiling
--- (`0k3`), so the DECISIONS get unit-tested with fakes while the entities keep their own
--- scenarios. Order inside a tick is deliberate: loss first (a destroyed station must not
--- wait for the wave to finish politely), then wave-end, then the intermission clock.
--- Returns the event handled, or nil; at most one per tick.
function Plugin:EvaluateWaveState(Now, Deps)
	local Machine = self.Machine

	if not Machine or not Machine:IsActive() then
		return nil
	end

	local Config = (Deps and Deps.Config) or self.HordeConfig.Resolve(Shared.GetMapName())
	local Reg = Deps and Deps.Reg or self.HordeRegistry
	local Spawner = Deps and Deps.Spawner or self.HordeSpawner
	local Snapshot = Deps and Deps.Snapshot or Plugin.Triggers.TakeSnapshot(nil)
	local Rules = Deps and Deps.Rules or GetGamerules()

	--- A wave owns its books, not the plugin's current mount: if the registry or spawner
	--- is not the pair this wave was placed with, the counts below describe someone
	--- else's world and every predicate is meaningless. Machines that never went through
	--- BeginWave (unit-driven fakes) carry no identity and are exempt.
	if Machine.WaveReg and (Reg ~= Machine.WaveReg or Spawner ~= Machine.WaveSpawner) then
		if not Machine.ForeignBooksLogged then
			Machine.ForeignBooksLogged = true

			self:Log("wave evaluation SKIPPED: mounted registry/spawner are not the books this wave was placed with")
		end

		return nil
	end

	if Machine:GetState() == Plugin.Phase.Wave then
		local Loss = self:EvaluateLoss(Snapshot, Rules, Now, Config)

		if Loss then
			self:EndHorde(Loss, Now)
			return "loss"
		end

		local MouthsGone = Plugin.Waves.MouthsFallen(Machine.WaveMouths,
			Reg and Reg:CountByKind("mouth") or 0)
		local Cleared = Plugin.Waves.Cleared(Machine.WaveBots,
			Reg and Reg:CountByKind("bot") or 0,
			Spawner and Spawner:Outstanding() or 0)

		if MouthsGone or Cleared then
			self:EndWavePhase(MouthsGone and "mouths" or "cleared", Now, Config, Reg, Rules)
			return MouthsGone and "mouths" or "cleared"
		end
	elseif Machine:GetState() == Plugin.Phase.Intermission then
		local Wait = (Config.Intermission and Config.Intermission.Seconds) or 60

		if Now - (Machine.ChangedAt or Now) >= Wait then
			if Machine:BeginWave(Now) then
				self:BeginWave(Config)
			end

			return "next-wave"
		end
	end

	return nil
end

--- The two ways the horde ends by itself, both latched against false positives: the
--- station must have BEEN standing to be lost (a warmup horde round starts without one,
--- and "never had" is not "just lost"), and the wipe must HOLD through the grace window
--- (respawns are seconds; D4's 3). The latch state lives on the plugin, cleared at
--- start and at teardown.
function Plugin:EvaluateLoss(Snapshot, Rules, Now, Config)
	if not Rules then
		return nil
	end

	self.HordeLoss = self.HordeLoss or {}

	local MarineTeam = Rules.GetTeam and Rules:GetTeam(kTeam1Index)

	if MarineTeam and MarineTeam.GetNumAliveCommandStructures then
		local Alive = MarineTeam:GetNumAliveCommandStructures()

		if (Alive or 0) > 0 then
			self.HordeLoss.HadStation = true
		elseif Plugin.Waves.StationsLost(self.HordeLoss.HadStation, Alive) then
			return "the marine command station was destroyed"
		end
	end

	local Grace = (Config.Waves and Config.Waves.WipeGraceSeconds) or 3
	local Since, Fired = Plugin.Waves.Wipe(Now, self.HordeLoss.WipeSince,
		Snapshot.RealMarinesAlive or Snapshot.RealMarineCount, Grace)

	self.HordeLoss.WipeSince = Since

	if Fired then
		return "every marine died"
	end

	return nil
end

--- A wave is over: its content leaves the world (the bots that survived a mouth-kill,
--- and the mouths the next draw re-places anyway), the flat payout lands on the marine
--- team, and the intermission clock starts on the machine's own ChangedAt. Draining is
--- BY KIND: a wave owns exactly its mouths and its bots - whatever else the registry
--- grows later (prebuilds, economy props) survives its waves.
function Plugin:EndWavePhase(Reason, Now, Config, Reg, Rules)
	local Machine = self.Machine

	if not Machine:EndWave(Now) then
		return false
	end

	local Entries = {}

	if Reg then
		for _, Item in ipairs(Reg:DrainKind("bot")) do
			Entries[#Entries + 1] = Item
		end

		for _, Item in ipairs(Reg:DrainKind("mouth")) do
			Entries[#Entries + 1] = Item
		end
	end

	local Destroyed = Plugin.DestroyEntries(Entries,
		(Reg and Reg.StateOf) or Plugin.Registry.EngineStateOf)

	local Payout = (Config.Economy and Config.Economy.WaveClearPayout) or 0
	local MarineTeam = Rules and Rules.GetTeam and Rules:GetTeam(kTeam1Index)

	if Payout > 0 and MarineTeam and MarineTeam.AddTeamResources then
		local OkPay, PayErr = pcall(function()
			MarineTeam:AddTeamResources(Payout)
		end)

		if not OkPay then
			self:Log("wave payout FAILED: " .. tostring(PayErr))
		end
	end

	local Survived = Machine:GetWave()
	local Wait = (Config.Intermission and Config.Intermission.Seconds) or 60

	Machine.MouthsPool = 0
	Machine.MouthsActive = 0
	Machine.WaveMouths = 0
	Machine.WaveBots = 0

	if Reason == "mouths" then
		self:Announce("HORDE: every tunnel mouth destroyed - wave %s is over, +%s team res. Intermission %ss, then wave %s.",
			tostring(Survived), tostring(Payout), tostring(Wait), tostring(Survived + 1))
	else
		self:Announce("HORDE: wave %s cleared, +%s team res. Intermission %ss, then wave %s.",
			tostring(Survived), tostring(Payout), tostring(Wait), tostring(Survived + 1))
	end

	self:Log(string.format("wave %s ended (%s): %s bots, %s mouths destroyed, payout %s",
		tostring(Survived), Reason, tostring(Destroyed.bot or 0),
		tostring(Destroyed.mouth or 0), tostring(Payout)))

	return true
end

--- A loss is an admin stop that someone told the truth to: the same machine edge, the
--- same ordered Teardown, plus the one announcement the mode owes - the score. Pillar
--- 3 has no win condition; this is the loss half landing, and with it the end of
--- "a horde that ends cannot end".
function Plugin:EndHorde(Reason, Now)
	local Machine = self.Machine
	local Survived = (Machine and Machine:GetWave()) or 0

	if not Machine:Stop("loss: " .. Reason, Now) then
		self:Log("loss teardown rejected while machine said " .. Machine:GetState())
		return false
	end

	self:Announce("HORDE OVER - %s. Survived %s wave(s); back to seeding.",
		Reason, tostring(Survived))
	self:Teardown(Now)

	return true
end

--- Destroy a given list of registry entries with the registry's own liveness answers.
--- Extracted from DestroyAll when the WAVE loop needed the same machinery for a SUBSET
--- (a wave ending drains its kinds, not the world). Both early-stop judgements from 71c
--- live here and apply to every caller: a bot is touched while its ENTITY is real even
--- if its player never materialised, and a ref that never registered at all is touched
--- regardless of what the player-based verdict says.
function Plugin.DestroyEntries(Entries, StateOf)
	local Destroyed, Failed, Husks, Gone = {}, {}, 0, 0
	local Ids = {}
	local Standing, Vanished = Plugin.Registry.Alive, Plugin.Registry.Gone

	for _, Item in ipairs(Entries) do
		local Ref = Item.ref
		local Kind = Item.kind or "other"
		local State = StateOf(Item)

		if Item.id then
			Ids[#Ids + 1] = Item.id
		end

		-- Bots are judged by their PLAYER (EngineStateOf), which answers "Gone" from two
		-- different worlds: a bot someone already disconnected (its entity id really is
		-- unresolvable), and a bot whose player has not materialised yet - entity alive,
		-- virtual client attached, no player, still ours to destroy. Trusting Gone there
		-- leaks a client that outlives the teardown, and 71c made that window reachable
		-- from the chair on purpose (stop right after a start, while bots are queueing).
		-- The same trap sits one layer down: EngineStateOf answers Gone for ANY entry
		-- without an id - exactly what TakePending hands over (refs born in the creation
		-- tick are refused registration by design). So: touch what is still real.
		local BornUnregistered = Item.id == nil and Ref ~= nil
		local BotStillReal = Kind == "bot" and (Item.id == nil or Shared.GetEntity(Item.id) ~= nil)

		if State == Vanished and not BotStillReal and not BornUnregistered then
			--- Fully gone - the engine finished it. That is the outcome we asked for, not a
			--- failure, and counting it as one made a clean round look broken: measured
			--- "teardown FAILED for 2 entries: ... Attempt to access an object that no longer
			--- exists" over two mouths the player had shot.
			Gone = Gone + 1
		else
			--- Two paths, one obligation. A husk (killed, still in the entity list through its
			--- death sequence) is not killed again - it is only removed, because "as if it never
			--- existed" is ours to deliver and the engine would otherwise leave it standing there
			--- behind a teardown that logged PASS. The kill and the removal are separate pcalls
			--- so that a refusal to die cannot skip the removal. A bot is ALWAYS disconnected
			--- while its entity is real - standing, husk, or player-not-yet-born - because
			--- Disconnect is what releases the virtual client; DestroyEntity alone strands it.
			if State == Standing or BotStillReal or BornUnregistered then
				pcall(function()
					if Kind == "bot" and Ref.Disconnect then
						Ref:Disconnect()
					elseif Ref.Kill then
						Ref:Kill()
					end
				end)
			else
				Husks = Husks + 1
			end

			local Ok, Err = pcall(DestroyEntity, Ref)

			if Ok then
				Destroyed[Kind] = (Destroyed[Kind] or 0) + 1
			else
				Failed[#Failed + 1] = string.format("%s: %s", Kind, tostring(Err))
			end
		end
	end

	return Destroyed, Failed, #Entries, Ids, Gone, Husks
end

--- Destroy the created set (see DestroyEntries for what touching each entry means):
--- drain the whole registry plus the caller's TakePending list, and account for all of
--- it. Injectable on purpose: i7b asserts integrity against real entities without
--- needing a live wave.
function Plugin.DestroyAll(Reg, Pending, Log)
	local Entries = Reg and Reg:Drain() or {}

	for _, Item in ipairs(Pending or {}) do
		Entries[#Entries + 1] = { ref = Item.ref, kind = Item.kind }
	end

	local Resolve = (Reg and Reg.StateOf) or Plugin.Registry.EngineStateOf

	return Plugin.DestroyEntries(Entries, Resolve)
end

--- Put the world back the way we found it, and only when we were the ones who changed it.
---
--- `GetGameStarted()` is `gameState == kGameState.Started` and nothing else, so a Started round
--- with no aliens left has exactly one end vanilla can reach: the aliens lose, the marines win,
--- the map rotates. That is what /horde stop was doing - announcing a winner in a mode that has
--- none and switching the map out from under the player who asked it to stop. ResetGame returns
--- the round to NotStarted, vanilla walks it to WarmUp, and a horde can be run again on the same
--- map. Same primitive the start used, so the two halves are symmetric instead of one of them
--- improvised.
function Plugin:HandBackWorld()
	if not self.HordeRoundStarted then
		return false, "horde never took the round over"
	end

	self.HordeRoundStarted = false

	local gamerules = GetGamerules()

	if not gamerules then
		return false, "no gamerules to hand back"
	end

	local Ok, Err = pcall(function() gamerules:ResetGame() end)

	if not Ok then
		return false, string.format("ResetGame failed: %s", tostring(Err))
	end

	return true, nil
end

--- The people stay where they are, and this step only COUNTS them (2026-09-28, Arian from
--- the live chair, reverting the 2026-09-27 decision): the team a player chose is theirs, and
--- a stop must not take it. The engine agrees - `ResetGame` calls `:Reset()` on every player
--- that has a client (`NS2Gamerules.lua:530`) and resets no team numbers
--- (`PlayingTeam:Reset` rebuilds the tech tree and brain, not rosters), so after the handback
--- every human is still on their team, landing in warm-up exactly as the server was before
--- `/horde`. If the chair finds that landing broken, the fallback is the ready room
--- (`kTeamReadyRoom`, team 0) - NOT spectator - and this function is the one place that
--- decision would live.
---
--- Bots are excluded from the census: vanilla owns them, and the takeover release has already
--- handed them back. The discriminator is the `gServerBots` roster, because a bot's virtual
--- client controls a real Player and "has a client" does not tell them apart (fact 11).
--- Every read is pcall'd per player: a player mid-reset can throw - measured, the move step
--- used to report exactly those - and a census that dies at one husk tells the admin nothing.
---
--- Players and the roster are injectable for the reason `DestroyAll`'s arguments are: the
--- claim is about WHO is counted and WHO is not touched, and a headless server has no humans.
function Plugin.ReportHumansKept(Players, Bots)
	local List = Players

	if not List then
		List = {}

		for _, Player in ientitylist(Shared.GetEntitiesWithClassname("Player")) do
			List[#List + 1] = Player
		end
	end

	local BotPlayers = {}

	for _, Bot in ipairs(Bots or gServerBots or {}) do
		local Ok, Player = pcall(function()
			return Bot.GetPlayer and Bot:GetPlayer()
		end)

		if Ok and Player then
			BotPlayers[Player:GetId()] = true
		end
	end

	local Marines, Aliens, Problems = 0, 0, {}

	for _, Player in ipairs(List) do
		local Ok, Team = pcall(function()
			if BotPlayers[Player:GetId()] then
				return nil
			end

			return Player:GetTeamNumber()
		end)

		if not Ok then
			Problems[#Problems + 1] = tostring(Team)
		elseif Team == kTeam1Index then
			Marines = Marines + 1
		elseif Team == kTeam2Index then
			Aliens = Aliens + 1
		end
	end

	return Marines, Aliens, Problems
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

	local Destroyed, Failed, Total, Ids, Gone, Husks = Plugin.DestroyAll(self.HordeRegistry,
		self.HordeSpawner and self.HordeSpawner:TakePending() or nil, nil)

	-- v0 restore is the bot controller only. Team resources and any other engine state
	-- we later touch are logged rather than guessed at (DESIGN.md: full restore is Phase 2).
	local Took, ReleasedNow = false, false

	if self.HordeTakeover then
		Took = self.HordeTakeover:IsEngaged()

		--- Releasing is what puts the server's bot configuration back, including the cap that
		--- decides whether vanilla bots ever return after a horde. A takeover that was never
		--- engaged used to read as "controller released=false" and nothing more, which is how
		--- "the bot never returned" arrived here with no trace of why.
		local Released, ReleaseReason = self.HordeTakeover:Release()
		ReleasedNow = Took and Released or false

		if Took and not Released then
			self:Log("bot controller NOT handed back: " .. tostring(ReleaseReason))
		end
	end

	Machine.MouthsPool = 0
	Machine.MouthsActive = 0

	-- The reveal is not "undone" here - it needs no undoing. The mouths are gone and each
	-- SensorBlip dies with its mouth (DetectableMixin.lua:117-126), so an abandoned flag has
	-- nothing left to re-assert. Clearing it keeps the flag honest between rounds: after a
	-- teardown the spawner says off, whatever the next wave's config decides.
	if self.HordeSpawner then
		self.HordeSpawner.Reveal = false
	end

	local Ok, Reason = Machine:CompleteTeardown(Now or Shared.GetTime())

	local Parts = {}

	for Kind, Count in pairs(Destroyed) do
		Parts[#Parts + 1] = string.format("%s=%s", Kind, tostring(Count))
	end

	table.sort(Parts)

	-- Poll our own ids, not the global entity count. Measured: destroying 2 mouths
	-- while the count moved 245 -> 249, because unrelated engine churn dominates it.
	-- Only "does this id still resolve" can catch a leak - and it has to be every id we ever
	-- registered, not just the ones still on the books: a corpse pruned mid-round must still be
	-- asked about, or pruning would erase the evidence that we made the thing at all.
	local Leaked = {}
	local Seen = {}

	for _, Id in ipairs(Ids) do
		Seen[Id] = true
	end

	if self.HordeRegistry then
		for _, Id in ipairs(self.HordeRegistry:GetEverIds()) do
			Seen[Id] = true
		end
	end

	for Id in pairs(Seen) do
		if Shared.GetEntity(Id) ~= nil then
			Leaked[#Leaked + 1] = Id
		end
	end

	--- The world goes back BEFORE suppression comes off. Releasing into a Started round with no
	--- aliens is precisely the win /horde stop was announcing: CheckGameEnd needs
	--- GetGameStarted(), and an emptied world has one end available - the aliens lose, the map
	--- rotates. After ResetGame the round is NotStarted, so there is nothing for vanilla to
	--- decide, and handing it the switch at that point is the honest reading of "as if it never
	--- existed" (Q7).
	local Handed, HandBackReason = self:HandBackWorld()

	--- The people are counted, not moved, and after the reset for the same reason the leak
	--- poll waits: the log line must describe the world we are handing back, not the round we
	--- tore down. No player is touched at any point in the handback - that is the contract
	--- `stop_leaves_humans_on_their_teams` pins.
	local KeptMarines, KeptAliens, CensusProblems = Plugin.ReportHumansKept()

	--- The refill nudge, AFTER the reset and while we still own the outcome: vanilla adds
	--- bots only on join/leave/SetMaxBots events (see Takeover.RefillVanillaBots - chair
	--- finding 2026-09-29: warmup bots never returned after a stop, because a stop produces
	--- none of those events and our release must restore the cap by direct field writes).
	--- A refill attempted BEFORE this reset would simply be destroyed by it. With humans
	--- this fills to the cap; headless it is vanilla's own zero-humans wipe rule - so
	--- scenarios that keep bots alive across deferred windows stub this step, exactly as
	--- they stub the census.
	local Refilled, RefillReason = false, nil

	if ReleasedNow then
		Refilled, RefillReason = Plugin.Takeover.RefillVanillaBots(self.BotController)

		if not Refilled then
			self:Log("bot refill nudge FAILED: " .. tostring(RefillReason))
		end
	end

	self:RestoreGameEnd("teardown")

	self:Log(string.format("teardown %s: %s destroyed (%s husks cleaned), %s already gone, %s failed of %s tracked (%s), controller released=%s, refill nudged=%s, world=%s, humans kept: %s marine(s) %s alien(s)%s, %s id(s) still live",
		(#Leaked == 0 and #Failed == 0) and "PASS" or "FAIL",
		tostring(Total - Gone - #Failed), tostring(Husks), tostring(Gone), tostring(#Failed),
		tostring(Total),
		#Parts > 0 and table.concat(Parts, " ") or "nothing to destroy",
		tostring(Took),
		tostring(Refilled),
		Handed and "reset to NotStarted" or ("left as-is: " .. tostring(HandBackReason)),
		tostring(KeptMarines),
		tostring(KeptAliens),
		#CensusProblems > 0 and string.format(" (read failures: %s)", table.concat(CensusProblems, "; ")) or "",
		tostring(#Leaked)))

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
	-- The choke point for chat broadcasts: format HERE, then send the FINAL text with the
	-- format flag off. Shine would have formatted the varargs downstream anyway, but the
	-- announce contract is asserted at the Notify hook (wave_slice_end_to_end) - a hook
	-- that sees "WAVE %s" is watching the template, not the announcement. Callers that
	-- pre-format pass no varargs and land on the raw branch.
	local Text = select("#", ...) > 0 and string.format(Message, ...) or Message

	self:Log("ANNOUNCE: " .. Text)
	self:Notify(nil, Text)
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
