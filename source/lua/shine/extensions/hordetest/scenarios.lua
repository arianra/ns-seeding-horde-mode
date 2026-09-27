--[[ Horde TEST harness — scenario registry.

     Each scenario is a function that raises through Plugin.Assert.*. Add new ones
     here as beads land them; the runner executes them in registration order and
     defers frame-resolved checks with Plugin:Defer.

     'negative_control' is flagged Expected and therefore MUST fail: it proves the
     asserts fire, the runner detects the raise, and test.sh parses a FAIL. If it
     ever passes, the harness is lying about green.

     Cross-extension state is read through Shine.Plugins[Name] (verified accessor,
     core/shared/extensions.lua:1040 + :1121) — never a test-only global. ]]

local Shine = Shine
local Plugin = ...
local Assert = Plugin.Assert

--- Anchors the ENGINE accepts as buildable surface, for scenarios that just need somewhere to
--- put a mouth. Going through hordemode's own snap keeps these tests on the same gate
--- production uses: a raw `Location` origin is a volume marker, often in rock or in mid air,
--- and now that SpawnMouth fails closed on such a point, a test that handed it one raw would
--- be asserting the refusal instead of the lifecycle it means to cover.
local function SurfaceAnchors(Count)
	local horde = Shine.Plugins.hordemode
	local Out = {}

	for _, Ent in ientitylist(Shared.GetEntitiesWithClassname("Location")) do
		local Snapped = horde.Placement.SnapToSurface(Ent:GetOrigin())

		if Snapped then
			Out[#Out + 1] = Snapped

			if #Out >= (Count or 1) then
				break
			end
		end
	end

	return Out
end

function Plugin:InitialiseScenarios()
	self:RegisterScenario( "assert_helpers_fire", false, function()
		Assert.Equal( 1 + 1, 2, "arithmetic sanity" )
		Assert.NotNil( {}, "table literal" )
		Assert.True( true, "truthiness" )
	end )

	self:RegisterScenario( "world_ready", false, function()
		-- Reached only after the runner's gate, so this asserts the gate itself:
		-- gamerules exist and the world is addressable before any hordemode test runs.
		Assert.NotNil( GetGamerules(), "gamerules after world-ready gate" )
	end )

	-- i1a: hordemode must have loaded and its world-ready gate must have armed it.
	self:RegisterScenario( "hordemode_armed", false, function()
		local horde = Shine.Plugins.hordemode
		Assert.NotNil( horde, "hordemode extension instance" )
		Assert.True( horde.Enabled, "hordemode enabled" )
		Assert.Equal( true, horde.HordeArmed, "world-ready gate armed the plugin" )
		Assert.Equal( horde.Phase.Inactive, horde.HordePhase, "starts in the inactive phase" )
		Assert.NotNil( horde.Phase.Wave, "phase vocabulary is shared, not server-only" )
		Assert.Nil( horde.Phase.Building, "no state outside the DESIGN section 2 set" )
	end )

	-- The gate retires its own poll on arming; a lingering timer means world-ready
	-- code re-runs every second, which i2b and later would trip over.
	self:RegisterScenario( "hordemode_arms_once", false, function()
		local horde = Shine.Plugins.hordemode
		Assert.NotNil( horde, "hordemode extension instance" )
		Assert.True( not horde:TimerExists( "HordeModeWorldReady" ), "world-ready poll was retired" )
	end )

	--[[
	  i0f (RD5) + i2a0 (RD7) probed together, and now kept as standing regressions:
	  can hordetest drive bot "players" headless, and does the marine command chair
	  work during WarmUp? Both answered YES on build 344, live, 2026-09-21.

	  Facts this probe leans on, all read from build 344 source:
	    Bot_Server.lua:63          bot.client = Server.AddVirtualClient()
	    BotTeamController:19-23    CountHumanPlayers skips GetIsVirtual() clients
	    BotTeamController:169-172  humanCount == 0 wipes every bot
	    CommanderBot:119-127       chair entry is CommandStructure:LoginPlayer(player, true)
	    PlayerBot_Server:131       PlayerBot:Initialize(forceTeam, active, tablePosition)
	]]
	self:RegisterScenario( "spike_bot_players", false, function()
		local gamerules = GetGamerules()
		local controller = gamerules.botTeamController
		Assert.NotNil( controller, "botTeamController exists during WarmUp" )

		local function HumanTotal()
			return controller:GetPlayerNumbersForTeam( kTeam1Index, true )
				+ controller:GetPlayerNumbersForTeam( kTeam2Index, true )
		end

		local humansBefore = HumanTotal()

		-- Lock the controller first: with zero real humans an unlocked BTC wipes every
		-- bot as soon as it updates, which would make the result meaningless.
		controller:DisableUpdate()
		controller:SetMaxBots( 0 )

		local Ok, BotOrErr = pcall( function()
			local bot = Server.CreateEntity( PlayerBot.kMapName )
			bot:Initialize( kTeam1Index, true )
			return bot
		end )

		if not Ok then
			-- A spawn failure is an answer, but it must not be able to green-light: a
			-- harness that cannot create its own test actors has no business testing bots.
			error( { Detail = "marine bot spawn raised: " .. tostring( BotOrErr ) } )
		end

		local bot = BotOrErr
		print( string.format( "[SPIKE] bot id=%s team=%s humans_before=%s",
			tostring( bot:GetId() ), tostring( bot.team ), tostring( humansBefore ) ) )

		self:Defer( "spike_bot_resolves", 6, false, function()
			local player = bot:GetPlayer()
			print( string.format( "[SPIKE] t+6s player=%s marine=%s alive=%s",
				tostring( player ~= nil ),
				tostring( player ~= nil and player:isa( "Marine" ) or false ),
				tostring( player ~= nil and player:GetIsAlive() or false ) ) )

			Assert.NotNil( player, "bot has a player entity 6s after spawn" )
			Assert.True( player:isa( "Marine" ), "forceTeam 1 yields a Marine, not a spectator" )
			Assert.True( player:GetIsAlive(), "bot marine is alive" )

			-- RD7, standing regression: the vanilla command chair is usable during
			-- WarmUp, so the marine build phase needs no custom gate. If a future
			-- change breaks this, the slice's economy design is invalid and the suite
			-- has to say so out loud.
			local team = gamerules:GetTeam( kTeam1Index )
			local loggedIn = false

			for _, station in ipairs( GetEntitiesForTeam( "CommandStructure", kTeam1Index ) ) do
				if station:GetIsBuilt() and station:GetIsAlive() then
					loggedIn = station:LoginPlayer( player, true ) ~= nil
					break
				end
			end

			print( string.format( "[SPIKE] LoginPlayer in WarmUp -> %s ; team has commander: %s",
				tostring( loggedIn ), tostring( team:GetHasCommander() ) ) )
			Assert.True( loggedIn, "vanilla command chair accepts a player during WarmUp (RD7)" )
			Assert.True( team:GetHasCommander(), "taking the chair leaves the team commanded (RD7)" )

			-- RD5's load-bearing fact: a bot client must not read as a human, or the
			-- horde min-players gate and the loss trigger would both lie.
			Assert.Equal( humansBefore, HumanTotal(), "virtual bot clients are not counted as humans" )

			bot:Disconnect()
			controller:EnableUpdate()
		end )
	end )

	-- i1b: the config module is pure data, so it is unit-testable without any world
	-- contact — the only part of the slice that is.
	self:RegisterScenario( "config_defaults_are_clean", false, function()
		local horde = Shine.Plugins.hordemode
		local Config = horde.HordeConfig
		Assert.NotNil( Config, "hordemode exposes its config module" )

		local Copy = Config.Copy(horde.DefaultConfig)
		Assert.True( not Config.Sanitize(Copy), "shipped defaults need no correction" )
		Assert.True( Copy.Waves.BandMin >= 56, "mouth band respects the spike measurement (tby: 56-80m)" )
		Assert.Equal( 1, Copy.Start.MinPlayers, "MinPlayers default" )
	end )

	self:RegisterScenario( "config_sanitizer_fixes_bad_values", false, function()
		local horde = Shine.Plugins.hordemode
		local Config = horde.HordeConfig
		local Copy = Config.Copy(horde.DefaultConfig)

		Copy.Start.Cooldown = -5
		Copy.Waves.PoolSize = 99
		Copy.Waves.BandMin = 300
		Copy.Waves.BandMax = 10
		Copy.Waves.Health = "not a curve"
		Copy.Difficulty.Accuracy.Bezier = { 5, 0, 0.5, 0 }
		Copy.Debug.RevealMouths = "false"

		-- Keys newer than the config file on disk. A file written before `BandLineFactor`
		-- existed arrives without it, and the sanitizer filled it from the CLAMP FLOOR (0)
		-- instead of the shipped default (0.5) - which silently disarmed the base-room floor,
		-- reported the config as clean, and got written back to disk as if chosen. PoolSize is
		-- the same trap with a visible number: its floor is 1, its default is 6.
		local Missing = Config.Copy(horde.DefaultConfig)

		Missing.Waves.BandLineFactor = nil
		Missing.Waves.PoolSize = nil

		Assert.True( Config.Sanitize(Copy), "dirty config reports that it was corrected" )
		Assert.Equal( 0, Copy.Start.Cooldown, "negative cooldown clamps to zero" )
		Assert.Equal( 12, Copy.Waves.PoolSize, "absurd pool size clamps to the ceiling" )
		Assert.True( Copy.Waves.BandMin < Copy.Waves.BandMax, "inverted band is repaired, not clamped flat" )
		Assert.Equal( "table", type(Copy.Waves.Health), "clobbered curve is replaced by a curve" )
		Assert.True( Copy.Waves.Health.Enabled == false, "replacement curve is flat" )
		Assert.True( Copy.Difficulty.Accuracy.Bezier[1] <= 1, "x control point kept inside [0,1] so difficulty stays monotonic" )
		Assert.Equal( false, Copy.Debug.RevealMouths,
			'a switch reads as a boolean: "false" in JSON must not become a truthy string' )

		Assert.True( Config.Sanitize(Missing), "a config missing new keys reports the repair" )
		Assert.Equal( 0.5, Missing.Waves.BandLineFactor, "a missing key takes the shipped default, not the clamp floor" )
		Assert.Equal( 6, Missing.Waves.PoolSize, "and that holds for every number, not just the new one" )
	end )

	self:RegisterScenario( "config_copy_is_deep", false, function()
		-- If Copy were shallow, sanitising a copy would rewrite the real defaults.
		local horde = Shine.Plugins.hordemode
		local Config = horde.HordeConfig
		local Before = horde.DefaultConfig.Waves.PoolSize
		local Copy = Config.Copy(horde.DefaultConfig)

		Copy.Waves.PoolSize = 1
		Assert.Equal( Before, horde.DefaultConfig.Waves.PoolSize, "mutating a copy left the defaults alone" )
	end )

	self:RegisterScenario( "config_map_override_wins", false, function()
		local horde = Shine.Plugins.hordemode
		local Config = horde.HordeConfig
		local SavedConfig = horde.Config

		horde.Config = Config.Copy(horde.DefaultConfig)
		horde.Config.Maps.ns2_summit = { Waves = { PoolSize = 2 } }

		local Resolved = Config.Resolve("ns2_summit")
		local Other = Config.Resolve("ns2_vega")

		Assert.Equal( 2, Resolved.Waves.PoolSize, "map override wins" )
		Assert.Equal( horde.DefaultConfig.Waves.ActivePerWave, Resolved.Waves.ActivePerWave, "untouched siblings survive the merge" )
		Assert.Equal( horde.DefaultConfig.Waves.PoolSize, Other.Waves.PoolSize, "another map is unaffected" )

		horde.Config = SavedConfig
	end )

	self:RegisterScenario( "config_curves_behave", false, function()
		local horde = Shine.Plugins.hordemode
		local Config = horde.HordeConfig
		local Flat = { Enabled = false, Start = 7, End = 99, Bezier = { 0.25, 0.1, 0.25, 1 } }

		Assert.Equal( 7, Config.EvaluateCurve(Flat, 0), "disabled curve is flat at t=0" )
		Assert.Equal( 7, Config.EvaluateCurve(Flat, 1), "disabled curve is flat at t=1" )

		local Rising = { Enabled = true, Start = 4, End = 24, Bezier = { 0.25, 0.1, 0.25, 1 } }
		Assert.Equal( 4, Config.EvaluateCurve(Rising, 0), "curve starts at Start" )
		Assert.True( math.abs(Config.EvaluateCurve(Rising, 1) - 24) < 0.01, "curve ends at End" )

		local Previous = -1
		for Step = 0, 20 do
			local Value = Config.EvaluateCurve(Rising, Step / 20)
			Assert.True(Value >= Previous - 0.0001, "curve is non-decreasing at t=" .. tostring(Step / 20))
			Previous = Value
		end

		Assert.Equal( 0, Config.WaveProgress(1, 30), "wave 1 is progress 0" )
		Assert.Equal( 1, Config.WaveProgress(30, 30), "reference wave is progress 1" )
		Assert.Equal( 1, Config.WaveProgress(500, 30), "past the reference wave clamps" )
	end )

	-- i1c: what Shine actually put in Plugin.Config after the real load path -
	-- JSON round trip, PreValidateConfig, and the file on disk.
	self:RegisterScenario( "config_loaded_is_valid", false, function()
		local horde = Shine.Plugins.hordemode
		local Loaded = horde.Config
		local Config = horde.HordeConfig

		Assert.NotNil( Config, "config module attached" )
		Assert.Equal( "HordeMode.json", horde.ConfigName, "config file name is declared" )
		Assert.Equal( true, horde.HasConfig, "plugin opts into config loading" )
		Assert.NotNil( Loaded, "Shine supplied a loaded config table" )
		Assert.True( Loaded.Waves.BandMin >= 40, "loaded band floor is reachable on vanilla maps" )
		Assert.True( Loaded.Waves.BandMin < Loaded.Waves.BandMax, "loaded band is ordered" )
		Assert.Equal( "table", type( Loaded.Waves.Composition ), "curve survived the JSON round trip" )
		Assert.NotNil( Loaded.Waves.Composition.Bezier, "bezier control points survived" )
		Assert.Equal( 4, #Loaded.Waves.Composition.Bezier, "all four control points survived" )
		Assert.NotNil( Config.Resolve( "ns2_summit" ).Waves, "map resolution works on the loaded table" )
	end )

	-- i2a: the state machine is pure, so every transition - legal and illegal -
	-- is checkable in a single tick with a fake clock.
	self:RegisterScenario( "statemachine_happy_path", false, function()
		local SM = Shine.Plugins.hordemode.StateMachine
		local Machine = SM.New(0, function() end)

		Assert.Equal( "inactive", Machine:GetState(), "begins idle" )
		Assert.True( Machine:Start(1), "/horde from idle starts wave 1" )
		Assert.Equal( "wave", Machine:GetState(), "entered wave" )
		Assert.Equal( 1, Machine:GetWave(), "no intermission before wave 1" )
		Assert.True( Machine:IsActive(), "wave counts as active" )

		Assert.True( Machine:EndWave(10), "wave clear -> intermission" )
		Assert.Equal( "intermission", Machine:GetState(), "build phase entered" )
		Assert.True( Machine:BeginWave(70), "timer elapsed -> next wave" )
		Assert.Equal( 2, Machine:GetWave(), "wave counter advances on entry, not on start" )

		Assert.True( Machine:Stop("all marines dead", 80), "loss reaches teardown from wave" )
		Assert.Equal( "teardown", Machine:GetState(), "tearing down" )
		Assert.Equal( "all marines dead", Machine.TeardownReason, "trigger reason is kept for messaging" )
		Assert.False( Machine:IsActive(), "teardown is not active" )

		Assert.True( Machine:CompleteTeardown(81), "teardown finishes back to idle" )
		Assert.Equal( "inactive", Machine:GetState(), "idle again" )
		Assert.Equal( 4, Machine:TimeSinceEnd(85), "post-teardown cooldown clock starts here" )
	end )

	self:RegisterScenario( "statemachine_guards", false, function()
		local SM = Shine.Plugins.hordemode.StateMachine
		local Machine = SM.New(0, function() end)
		local Logs = {}
		Machine.Log = function(Message) Logs[#Logs + 1] = Message end

		Assert.False( Machine:EndWave(2), "cannot end a wave that never started" )
		Assert.False( Machine:BeginWave(3), "cannot begin a wave from idle" )
		Assert.False( Machine:CompleteTeardown(4), "nothing to complete from idle" )
		Assert.True( Machine:Start(5), "start still available after rejected transitions" )
		Assert.False( Machine:Start(6), "double start rejected" )
		Assert.Equal( "wave", Machine:GetState(), "rejection did not move state" )
		Assert.False( Machine:Transition("nonsense", 7) )
		Assert.False( Machine:Transition("wave", 8), "self-transition rejected" )
		Assert.Equal( 1, Machine:GetWave(), "rejected second start did not bump the wave counter" )
	end )

	self:RegisterScenario( "statemachine_teardown_is_idempotent", false, function()
		local SM = Shine.Plugins.hordemode.StateMachine
		local Machine = SM.New(0, function() end)
		Machine:Start(1)

		Assert.True( Machine:Stop("admin", 2), "first stop enters teardown" )
		local Reached = 0
		Machine:OnEnter("teardown", function() Reached = Reached + 1 end)
		Machine:Stop("admin again", 3)

		Assert.Equal( 0, Reached, "re-entering teardown does not fire its destroy pass again" )
		Assert.Equal( "teardown", Machine:GetState(), "still tearing down, once" )

		-- A rejected Stop must not leave its reason behind for a later teardown to claim.
		local Idle = SM.New(0, function() end)
		Assert.False( Idle:Stop("ghost", 1), "cannot stop what never started" )
		Assert.True( Idle:Start(2), "start still works after a rejected stop" )
		Assert.True( Idle:Stop("real", 3), "stop from wave" )
		Assert.Equal( "real", Idle.TeardownReason, "teardown reports the reason that actually triggered it" )
	end )

	self:RegisterScenario( "statemachine_hook_failure_is_contained", false, function()
		local SM = Shine.Plugins.hordemode.StateMachine
		local Machine = SM.New(0, function() end)
		local Reached = 0

		local Added, AddErr = Machine:OnEnter("wave", function() error("hook blew up") end)
		Assert.True( Added, "hook registration succeeds" )
		Assert.False( Machine:OnEnter("nowhere", function() end), "unknown state rejected for hooks" )
		Machine:OnEnter("wave", function() Reached = Reached + 1 end)

		Assert.True( Machine:Start(1), "transition proceeds despite a throwing hook" )
		Assert.Equal( "wave", Machine:GetState(), "state is not left mid-transition" )
		Assert.Equal( 1, Reached, "later hooks still run after a failing one" )
	end )

	-- i2b: the gates are pure over a snapshot, so every rejection reason is
	-- reachable here - including ones a headless server can never produce.
	local function Snapshot(Overrides)
		local Base = {
			GameState = kGameState.WarmUp,
			RealMarineCount = 1,
			RealAlienCount = 0,
			PlayerCount = 4,
			MaxPlayers = 16,
		}

		for Key, Value in pairs(Overrides or {}) do
			Base[Key] = Value
		end

		return Base
	end

	local function GateHarness()
		local horde = Shine.Plugins.hordemode
		return horde.Triggers, horde.StateMachine.New(0, function() end), { Start = { Cooldown = 60, MinPlayers = 1 } }
	end

	self:RegisterScenario( "gates_headless_server_rejects", false, function()
		local Triggers, Machine, Config = GateHarness()
		local Ok, Gate, Reason = Triggers.Check(Snapshot({ RealMarineCount = 0 }), Machine, Config, 10)

		Assert.False( Ok, "a server with no humans must not start a horde" )
		Assert.Equal( "HasMarinePlayers", Gate, "reason is the marine count, not a misfiring gate" )
		Assert.True( Reason:find("need 1 marine") ~= nil, "chat text names the requirement: " .. tostring(Reason) )
	end )

	self:RegisterScenario( "gates_accept_a_seeding_marine", false, function()
		local Triggers, Machine, Config = GateHarness()
		Assert.True( Triggers.Check(Snapshot(), Machine, Config, 10) )
	end )

	self:RegisterScenario( "gates_reject_each_condition", false, function()
		local Triggers, Machine, Config = GateHarness()

		local _, AlienGate = Triggers.Check(Snapshot({ RealAlienCount = 2 }), Machine, Config, 10)
		Assert.Equal( "NoRealAliens", AlienGate, "a real player on aliens blocks the horde" )

		local _, StartedGate = Triggers.Check(Snapshot({ GameState = kGameState.Started }), Machine, Config, 10)
		Assert.Equal( "InSeedingState", StartedGate, "a started game is not seeding" )

		local _, FullGate = Triggers.Check(Snapshot({ PlayerCount = 16, MaxPlayers = 16 }), Machine, Config, 10)
		Assert.Equal( "SeedMaxNotMet", FullGate, "seed max reached blocks the horde" )

		-- DESIGN section 2 entry check 2, missing from i2b as written: the caller
		-- himself must be a marine, not merely some marine being present.
		local _, CallerGate = Triggers.Check(
			Snapshot({ CallerPlayer = {}, CallerTeamNumber = kTeam2Index }), Machine, Config, 10)
		Assert.Equal( "CallerIsMarine", CallerGate, "a caller on the alien team cannot start a horde" )

		local _, SpecGate = Triggers.Check(
			Snapshot({ CallerPlayer = {}, CallerTeamNumber = kSpectatorIndex }), Machine, Config, 10)
		Assert.Equal( "CallerIsMarine", SpecGate, "a spectator caller cannot start a horde either" )

	end )

	self:RegisterScenario( "gates_state_and_cooldown", false, function()
		local Triggers, Machine, Config = GateHarness()

		Assert.True( Machine:Start(100), "start for the running-gate case" )
		local _, RunningGate, RunningReason = Triggers.Check(Snapshot(), Machine, Config, 110)
		Assert.Equal( "IsNotRunning", RunningGate, "already running is reported first" )
		Assert.True( RunningReason:find("wave 1") ~= nil, "rejection names the wave: " .. tostring(RunningReason) )

		Machine:Stop("test", 120)
		Machine:CompleteTeardown(130)

		local _, CoolGate, CoolReason = Triggers.Check(Snapshot(), Machine, Config, 160)
		Assert.Equal( "CooldownOk", CoolGate, "post-teardown cooldown applies" )
		Assert.True( CoolReason:find("cooldown remaining") ~= nil, "cooldown text shows time left: " .. tostring(CoolReason) )

		Assert.True( Triggers.Check(Snapshot(), Machine, Config, 200), "cooldown expires" )
	end )

	self:RegisterScenario( "horde_command_is_bound", false, function()
		local horde = Shine.Plugins.hordemode
		Assert.NotNil( horde.Commands, "plugin registered commands at world-ready" )
		Assert.NotNil( horde.Commands.sh_horde, "/horde is bound" )
		-- Only existence is asserted: the Command object is Shine-internal and its
		-- fields are not something this suite should depend on.
	end )

	-- i2c: status is a test surface (RD6), so assert its fields in each phase with
	-- an injected machine rather than trying to fake a live horde.
	local function StatusCase()
		local horde = Shine.Plugins.hordemode
		local Machine = horde.StateMachine.New(0, function() end)
		local Config = { Start = { Cooldown = 60, MinPlayers = 1 } }
		local Snap = {
			GameState = kGameState.WarmUp, RealMarineCount = 3, RealAlienCount = 0,
			PlayerCount = 4, MaxPlayers = 16, BotCount = 0,
		}

		return horde, Machine, Config, Snap
	end

	self:RegisterScenario( "status_reports_idle_state", false, function()
		local horde, Machine, Config, Snap = StatusCase()
		local Line = horde:BuildStatusLine(Snap, Machine, Config, 10)

		Assert.True( Line:find("state=inactive") ~= nil, "state field: " .. Line )
		Assert.True( Line:find("wave=0") ~= nil, "wave field: " .. Line )
		Assert.True( Line:find("marines=3") ~= nil, "human marine count is visible: " .. Line )
		Assert.True( Line:find("players=4/16") ~= nil, "seeding occupancy is visible: " .. Line )
		Assert.True( Line:find("bots=") ~= nil, "bot roster count is present: " .. Line )
		Assert.True( Line:find("ours=0") ~= nil, "registry bot count starts at zero: " .. Line )
		Assert.True( Line:find("mouths=-/-") ~= nil, "unbuilt subsystems report as unknown, not zero: " .. Line )
		Assert.True( Line:find("cooldown=none") ~= nil, "no cooldown before a horde has run: " .. Line )
	end )

	self:RegisterScenario( "status_tracks_wave_and_cooldown", false, function()
		local horde, Machine, Config, Snap = StatusCase()

		Machine:Start(10)
		Assert.True( horde:BuildStatusLine(Snap, Machine, Config, 20):find("state=wave wave=1") ~= nil,
			"running horde shows state and wave" )

		Machine:EndWave(30)
		Assert.True( horde:BuildStatusLine(Snap, Machine, Config, 31):find("state=intermission") ~= nil,
			"intermission is distinguishable from wave" )

		Machine:Stop("test loss", 40)
		Machine:CompleteTeardown(50)
		local After = horde:BuildStatusLine(Snap, Machine, Config, 60)
		Assert.True( After:find("state=inactive") ~= nil, "back to idle after teardown" )
		Assert.True( After:find("cooldown=50s") ~= nil, "remaining cooldown is shown with units: " .. After )

		local Expired = horde:BuildStatusLine(Snap, Machine, Config, 200)
		Assert.True( Expired:find("cooldown=none") ~= nil, "cooldown clears itself once elapsed" )
	end )

	self:RegisterScenario( "admin_stop_moves_state_only", false, function()
		local horde, Machine = StatusCase()

		-- Deliberately a local machine: these cases need phases no headless
		-- server can reach on its own.
		Assert.False( Machine:Stop("nothing running", 1), "stop on an idle horde is refused" )
		Assert.True( Machine:Start(2), "start" )
		Assert.True( Machine:Stop("admin sh_horde_stop", 3), "stop from wave" )
		Assert.Equal( "teardown", Machine:GetState(), "state flipped, nothing destroyed yet (M7 owns that)" )
		Assert.Equal( "admin sh_horde_stop", Machine.TeardownReason, "reason recorded for status and teardown messaging" )
	end )

	self:RegisterScenario( "admin_commands_are_bound", false, function()
		local horde = Shine.Plugins.hordemode
		Assert.NotNil( horde.Commands.sh_horde_stop, "sh_horde_stop registered" )
		Assert.NotNil( horde.Commands.sh_horde_status, "sh_horde_status registered" )
		Assert.NotNil( horde.Machine, "a live machine exists after world-ready" )
	end )

	-- Commands exist the moment they are bound, so every handler must survive being
	-- called before the world is ready. Nil client is the headless case.
	self:RegisterScenario( "commands_survive_pre_arm", false, function()
		local horde = Shine.Plugins.hordemode
		local Saved = horde.Machine

		horde.Machine = nil

		local OkStop = pcall( function() horde:OnHordeStop(nil) end )
		local StillUnarmed = horde.Machine == nil
		local OkStatus = pcall( function() horde:OnHordeStatus(nil) end )
		local OkStart = pcall( function() horde:OnHordeCommand(nil) end )

		horde.Machine = Saved

		Assert.True( OkStop, "sh_horde_stop does not throw while unarmed" )
		Assert.True( StillUnarmed, "a refused command did not quietly create a machine" )
		Assert.True( OkStatus, "sh_horde_status does not throw while unarmed" )
		Assert.True( OkStart, "/horde does not throw while unarmed" )
		Assert.True( horde.Machine == Saved, "machine restored for the rest of the suite" )
	end )

	-- Chat can only ever reach sh_horde (i2c bound status/stop console-only), so any
	-- word after /horde fell through to "start": the first thing typed on a live server
	-- was `/horde status` and it began wave 1. Routing is asserted by stubbing the three
	-- destinations - the contract under test is *which handler runs*, not what each one
	-- does, and those have their own scenarios.
	self:RegisterScenario( "horde_command_routing", false, function()
		local horde = Shine.Plugins.hordemode
		local SavedMachine = horde.Machine
		local SavedCheck = horde.Triggers.Check
		local SavedSnapshot = horde.Triggers.TakeSnapshot
		local SavedStatus = horde.OnHordeStatus
		local SavedStop = horde.OnHordeStop
		local SavedStartWave = horde.StartWave
		local Hits = { status = 0, stop = 0, wave = 0 }

		horde.Triggers.Check = function() return true end
		horde.Triggers.TakeSnapshot = function() return {} end
		horde.OnHordeStatus = function() Hits.status = Hits.status + 1 end
		horde.OnHordeStop = function() Hits.stop = Hits.stop + 1 end
		-- Every start route now funnels through StartWave (bare, `start`, `restart`),
		-- so counting it is the assertion that matters; Machine:Start is reached only
		-- from inside StartWave, which its own scenarios cover.
		horde.StartWave = function() Hits.wave = Hits.wave + 1 end
		horde.Machine = { IsActive = function() return false end }

		-- Driven through Shine:RunCommand, NOT by calling the handler directly.
		-- The first version of this scenario called OnHordeCommand(nil, {"status"})
		-- and passed while the feature was dead: Shine only forwards arguments that
		-- match a declared parameter, so the real chat path delivered nothing and
		-- "/horde status" started a horde. Testing the handler bypasses the exact
		-- layer that broke.
		Shine:RunCommand(nil, "sh_horde", true, "status")
		Shine:RunCommand(nil, "sh_horde", true, "stop")
		Shine:RunCommand(nil, "sh_horde", true, "bogus")
		Shine:RunCommand(nil, "sh_horde", true, "restart")
		Shine:RunCommand(nil, "sh_horde", true, "start")
		Shine:RunCommand(nil, "sh_horde", true)
		Shine:RunCommand(nil, "sh_horde", true)

		horde.Triggers.Check = SavedCheck
		horde.Triggers.TakeSnapshot = SavedSnapshot
		horde.OnHordeStatus = SavedStatus
		horde.OnHordeStop = SavedStop
		horde.StartWave = SavedStartWave
		horde.Machine = SavedMachine

		Assert.Equal( 1, Hits.status, "'/horde status' reports status" )
		Assert.Equal( 1, Hits.stop, "'/horde stop' stops without a permission check" )
		-- bare x2 + `start` alias + `restart` = 4; `bogus` must contribute nothing.
		Assert.Equal( 4, Hits.wave, "bare, start and restart all reach the gated start" )
	end )

	-- i3a: the registry is accounting truth for teardown, so its bookkeeping is
	-- asserted directly - with fake refs, since it deliberately touches no engine API.
	local function FakeRef(Id)
		return { id = Id, GetId = function(Self) return Self.id end }
	end

	self:RegisterScenario( "registry_tracks_kinds", false, function()
		local R = Shine.Plugins.hordemode.Registry
		local Reg = R.New()

		local BotId, BotErr = Reg:Register(FakeRef(101), R.Kind.Bot)
		Assert.NotNil( BotId, "bot registered" )
		Assert.Nil( BotErr, "no error on a clean register" )
		Reg:Register(FakeRef(102), R.Kind.Mouth)
		Reg:Register(FakeRef(103), R.Kind.Mouth)
		Assert.Nil( Reg:Register(nil, R.Kind.Bot), "nil ref is refused" )
		Assert.Nil( Reg:Register(FakeRef(104), nil), "missing kind is refused" )

		Assert.Equal( 3, Reg:Count(), "three entries" )
		Assert.Equal( 1, Reg:CountByKind(R.Kind.Bot), "one bot" )
		Assert.Equal( 2, Reg:CountByKind(R.Kind.Mouth), "two mouths" )
		Assert.Equal( 0, Reg:CountByKind(R.Kind.Entity), "kind with none registered counts zero" )
		Assert.Equal( 1, Reg:GetBotCount(), "bot count is the horde's own, not the server's" )
		Assert.Equal( 101, Reg:Get(101) and Reg:Get(101).id, "get returns the ref" )
		Assert.Equal( "mouth", Reg:GetKind(102), "kind is recoverable" )
		Assert.Equal( 3, #Reg:GetAllIds(), "all ids listed" )
		Assert.Equal( 101, Reg:GetAllIds()[1], "ids come back sorted" )
	end )

	self:RegisterScenario( "registry_is_idempotent", false, function()
		local R = Shine.Plugins.hordemode.Registry
		local Reg = R.New()
		local Ref = FakeRef(201)

		local First = Reg:Register(Ref, R.Kind.Bot)
		local Second = Reg:Register(Ref, R.Kind.Bot)
		Assert.Equal( First, Second, "re-registering the same ref is not a second entry" )
		Assert.Equal( 1, Reg:Count(), "count stays at one" )

		local ConflictId, ConflictErr = Reg:Register(Ref, R.Kind.Mouth)
		Assert.Nil( ConflictId, "same id under two kinds is refused" )
		Assert.True( ConflictErr:find("already registered as bot") ~= nil, "conflict names the existing kind" )

		Assert.True( Reg:Unregister(201), "first unregister removes it" )
		Assert.False( Reg:Unregister(201), "second unregister is a no-op, not an error" )
		Assert.Equal( 0, Reg:CountByKind(R.Kind.Bot), "kind index dropped with the entry" )
		Assert.Equal( 0, Reg:Count(), "empty" )
	end )

	self:RegisterScenario( "registry_survives_mutation_during_iteration", false, function()
		local R = Shine.Plugins.hordemode.Registry
		local Reg = R.New()

		for Id = 301, 305 do
			Reg:Register(FakeRef(Id), R.Kind.Mouth)
		end

		local Seen = 0
		local Visited = {}
		Reg:IterateByKind(R.Kind.Mouth, function(Ref, Id)
			Seen = Seen + 1
			Visited[Id] = true
			Reg:Unregister(Id)
		end)

		Assert.Equal( 5, Seen, "every mouth was visited even though each unregistered itself" )
		Assert.True( Visited[305], "the last one was not skipped" )
		Assert.Equal( 0, Reg:Count(), "and they are all gone" )
	end )

	self:RegisterScenario( "registry_prune_and_drain", false, function()
		local R = Shine.Plugins.hordemode.Registry
		local Reg = R.New()
		Reg:Register(FakeRef(401), R.Kind.Bot)
		Reg:Register(FakeRef(402), R.Kind.Bot)
		Reg:Register(FakeRef(403), R.Kind.Entity)

		local Pruned = Reg:Prune(function(Ref, Id) return Id == 402 end )
		Assert.Equal( 1, Pruned, "prune reports what was already vanished" )
		Assert.Equal( 2, Reg:Count(), "the vanished one is gone from the books" )

		-- Drain is what teardown uses: it hands back the entries so the caller can
		-- destroy them, and only then is the registry empty.
		local Drained = Reg:Drain()
		Assert.Equal( 2, #Drained, "drain hands back everything still tracked" )
		Assert.Equal( "bot", Drained[1].kind, "entries carry their kind for ordered teardown" )
		Assert.Equal( 0, Reg:Count(), "draining empties it" )
		Assert.Equal( 0, Reg:Clear(), "clearing an already-empty registry reports zero, not a stale count" )

		-- Clear on a populated registry is the count it dropped.
		Reg:Register(FakeRef(450), R.Kind.Mouth)
		Reg:Register(FakeRef(451), R.Kind.Mouth)
		Assert.Equal( 2, Reg:Clear(), "clear reports what it removed" )
		Assert.Equal( 0, Reg:CountByKind(R.Kind.Mouth), "kind index cleared with the entries" )
	end )

	self:RegisterScenario( "status_counts_our_bots_separately", false, function()
		local horde = Shine.Plugins.hordemode
		local R = horde.Registry
		local Reg = R.New()
		Reg:Register({ GetId = function(Self) return 900 end }, R.Kind.Bot)
		Reg:Register({ GetId = function(Self) return 901 end }, R.Kind.Bot)

		local Machine = horde.StateMachine.New(0, function() end)
		local Snap = { GameState = kGameState.WarmUp, RealMarineCount = 2, RealAlienCount = 0,
			PlayerCount = 5, MaxPlayers = 16, BotCount = 9 }
		local Line = horde:BuildStatusLine(Snap, Machine, { Start = { Cooldown = 60, MinPlayers = 1 } },
			10, Reg)

		Assert.True( Line:find("bots=9") ~= nil, "server-wide bot roster: " .. Line )
		Assert.True( Line:find("ours=2") ~= nil, "horde-owned bots counted apart from vanilla fill: " .. Line )
		-- The live instance must not be polluted by the test's own registry.
		Assert.Equal( 0, horde.HordeRegistry:GetBotCount(), "live registry untouched by the test instance" )
	end )

	self:RegisterScenario( "bot_controller_lock_is_balanced", false, function()
		local R = Shine.Plugins.hordemode.Registry
		local Controller = {
			MaxBots = 12, addCommander1 = true, addCommander2 = false, updateLock = 0,
			DisableUpdate = function(Self) Self.updateLock = Self.updateLock + 1 end,
			EnableUpdate = function(Self) Self.updateLock = Self.updateLock - 1 end,
			SetMaxBots = function(Self, Value, Com)
				Self.MaxBots = Value
				-- The engine setter assigns both teams from one argument; that is the
				-- trap the snapshot has to work around (BotTeamController.lua:185-193).
				Self.addCommander1, Self.addCommander2 = Com, Com
			end,
		}

		local Snap = R.SnapshotBTCState(Controller)
		Assert.NotNil( Snap, "snapshot taken" )
		Assert.Equal( 12, Snap.MaxBots, "cap recorded" )
		Assert.Equal( false, Snap.addCommander2, "per-team commander flags recorded separately" )

		Assert.True( R.EngageBTC(Controller, Snap), "lock acquired" )
		Assert.False( R.EngageBTC(Controller, Snap), "second engage is a no-op, not a double lock" )
		Assert.Equal( 1, Controller.updateLock, "engine assert at :145 forbids an unbalanced release" )

		R.LockBotCap(Controller, Snap)
		Assert.Equal( 0, Controller.MaxBots, "fill loop capped while we hold the lock" )

		Assert.True( R.ReleaseBTC(Controller, Snap), "release" )
		Assert.False( R.ReleaseBTC(Controller, Snap), "double release refused" )
		Assert.Equal( 0, Controller.updateLock, "lock depth returned to where we found it" )
		Assert.Equal( 12, Controller.MaxBots, "cap restored" )
		Assert.Equal( true, Controller.addCommander1, "commander flag 1 restored exactly" )
		Assert.Equal( false, Controller.addCommander2, "flag 2 restored independently of the setter" )
	end )

	-- i3b: the live cycle. Checks are recorded, not asserted inline, because an
	-- assert that threw here would leave the engine's bot controller locked for every
	-- later scenario - release must be unreachable-by-failure.
	-- i3b: the live cycle. Two disciplines here: every check is *recorded* rather than
	-- asserted inline, and setup runs under pcall with a cleanup, because a scenario
	-- that throws between Engage and Release leaves the engine's bot controller locked
	-- for everything that follows - which is precisely what the first version of this
	-- test did when it called Defer on the wrong plugin.
	-- i3b: the live cycle on the real controller. Two disciplines, both learned the
	-- hard way here: setup runs under pcall with a cleanup, because a scenario that
	-- throws between Engage and Release leaves the engine locked for everything after
	-- it; and every lock assertion is a DELTA, because spike_bot_players locks and
	-- unlocks this same global controller from its own deferred check.
	self:RegisterScenario( "takeover_live_cycle", false, function()
		local horde = Shine.Plugins.hordemode
		local controller = horde.BotController
		Assert.NotNil( controller, "world-ready resolved the bot controller" )

		local Before = {
			MaxBots = controller.MaxBots, commander1 = controller.addCommander1,
			commander2 = controller.addCommander2,
		}

		local Takeover = horde.Takeover.New(controller, horde.HordeRegistry)
		local Problems = {}
		local Bot, BotId, Engaged, LockBaseline = nil, nil, false, 0

		local function Cleanup()
			if Bot then pcall(function() Bot:Disconnect() end) end
			if Engaged then pcall(function() Takeover:Release() end) end
			if BotId then horde.HordeRegistry:Unregister(BotId) end
		end

		local OkSetup, SetupErr = pcall( function()
			LockBaseline = controller.updateLock

			if not Takeover:Engage() then Problems[#Problems + 1] = "engage refused" end
			Engaged = true

			if controller.MaxBots ~= 0 then Problems[#Problems + 1] = "cap not lowered" end

			if (controller.updateLock - LockBaseline) ~= 1 then
				Problems[#Problems + 1] = string.format("our engage moved the lock by %s, not 1",
					tostring(controller.updateLock - LockBaseline))
			end

			Bot = Server.CreateEntity(PlayerBot.kMapName)
			Bot:Initialize(kTeam2Index, true)
			Bot.lifeformEvolution = kTechId.Skulk
			BotId = horde.HordeRegistry:Register(Bot, horde.Registry.Kind.Bot)

			if BotId == nil then Problems[#Problems + 1] = "bot not registered" end

			self:Defer( "takeover_bot_survives_and_releases", 8, false, function()
				BotId = horde.HordeRegistry:Register(Bot, horde.Registry.Kind.Bot)

				if BotId == nil then
					Problems[#Problems + 1] = "bot could not be registered even after 8s"
				elseif BotId <= 0 then
					Problems[#Problems + 1] = "registry invented a local id for a real entity"
				end

				-- The question worth asking, now with a genuine entity id: does the
				-- PlayerBot entity survive while its player lives?
				local RawId = Bot:GetId()
				local EntityAlive = RawId ~= nil and Shared.GetEntity(RawId) ~= nil

				if not EntityAlive then
					Problems[#Problems + 1] = "PlayerBot entity vanished while holding the lock: " .. tostring(RawId)
				end
				local AlienPlayer = Bot:GetPlayer()
				local PlayerAlive = AlienPlayer ~= nil and AlienPlayer:GetIsAlive() == true

				-- Evidence first: the entity handle and the live player are different
				-- questions, and the first version of this test conflated them.
				print(string.format(
					"[TEST-DIAG] t+8 rawId=%s entity=%s registryId=%s player=%s alive=%s maxBots=%s lock=%s roster=%s",
					tostring(RawId), tostring(EntityAlive), tostring(BotId),
					tostring(AlienPlayer ~= nil), tostring(PlayerAlive),
					tostring(controller.MaxBots), tostring(controller.updateLock),
					tostring(gServerBots and #gServerBots or -1)))

				if not PlayerAlive then
					Problems[#Problems + 1] = string.format(
						"bot has no live player at t+8 (entity=%s, hasPlayer=%s)",
						tostring(EntityAlive), tostring(AlienPlayer ~= nil))
				end

				if AlienPlayer and not AlienPlayer:GetIsVirtual() then
					Problems[#Problems + 1] = "a bot client read as a real player"
				end

				-- Measured immediately around the call: another scenario (spike_bot_players)
				-- releases ITS lock on this same global controller at t+6, so no absolute
				-- baseline here is stable. What we can claim precisely is that our own
				-- release removes exactly one lock.
				local LockBeforeRelease = controller.updateLock
				if not Takeover:Release() then Problems[#Problems + 1] = "release refused" end
				Engaged = false

				if (LockBeforeRelease - controller.updateLock) ~= 1 then
					Problems[#Problems + 1] = string.format("our release moved the lock by %s, not -1",
						tostring(controller.updateLock - LockBeforeRelease))
				end

				Bot:Disconnect()
				horde.HordeRegistry:Unregister(BotId)
				BotId = nil

				if controller.MaxBots ~= Before.MaxBots then
					Problems[#Problems + 1] = string.format("cap not restored (%s vs %s)",
						tostring(controller.MaxBots), tostring(Before.MaxBots))
				end

				if tostring(controller.addCommander1) ~= tostring(Before.commander1)
					or tostring(controller.addCommander2) ~= tostring(Before.commander2) then
					Problems[#Problems + 1] = "commander flags not restored independently"
				end

				Assert.Equal( 0, horde.HordeRegistry:GetBotCount(), "registry emptied after the cycle" )

				if #Problems > 0 then
					error( { Detail = "live takeover cycle: " .. table.concat(Problems, "; ") } )
				end
			end )
		end )

		if not OkSetup then
			Cleanup()
			error( { Detail = "setup failed and was cleaned up: " .. tostring(SetupErr) } )
		end
	end )

	-- i3c: registry + takeover together, against real entities. Runs as a CHAINED
	-- deferred cycle starting at t+20, deliberately after takeover_live_cycle has
	-- released the controller at t+15: two scenarios holding the one global
	-- botTeamController at once made each other's cap and registry assertions lie
	-- (dev/REVIEW-CHECKLIST.md, "Test honesty").
	-- i3c: registry + takeover against real entities, in ONE deferred callback.
	-- Two-stage chaining is deliberately not used: the runner's repeating timer stops
	-- firing a few ticks into the pending queue (observed twice - checks scheduled at
	-- t+6 and t+8 landed, t+9 and t+14 never did, with nothing in the log and no
	-- ALL-DONE), so a chain would hang the suite rather than test anything. "does
	-- nothing destroy it over time" is already answered by spike tby (mouths survive
	-- unpaired indefinitely) and by takeover_live_cycle's 8s window.
	-- i3c: registry + takeover against real entities, in ONE deferred callback.
	-- Chaining defers is deliberately not used: the runner's timer stops firing a few
	-- ticks into the pending queue (measured: t+6/t+8 land, t+9/t+14 never do, with
	-- nothing in the log and no ALL-DONE), so a chain would hang the suite.
	self:RegisterScenario( "registry_takeover_integration", false, function()
		local horde = Shine.Plugins.hordemode
		local R = horde.Registry
		local controller = horde.BotController
		local Reg = R.New()

		Assert.NotNil( controller, "bot controller resolved at world-ready" )

		local Bots, Mouths = {}, {}
		local Problems = {}

		-- Created NOW (sync pass) so that by the deferred check a tick has passed and
		-- each entity has a real id. Registering in the same tick as creation is
		-- refused by the registry, which is the point of this scenario.
		local Anchors = {}

		for _, Ent in ientitylist(Shared.GetEntitiesWithClassname("Location")) do
			Anchors[#Anchors + 1] = Ent:GetOrigin()

			if #Anchors >= 2 then break end
		end

		if #Anchors > 0 then
			for Index = 1, 2 do
				-- Global CreateEntity: Server.CreateEntity takes only (mapName) or
				-- (mapName, fields) (AlienTunnelManager.lua:191).
				local Mouth = CreateEntity(TunnelEntrance.kMapName,
					Anchors[((Index - 1) % #Anchors) + 1], 2)

				if Mouth then
					if Mouth.SetConstructionComplete then Mouth:SetConstructionComplete() end
					Mouths[#Mouths + 1] = Mouth
				end

				local Bot = Server.CreateEntity(PlayerBot.kMapName)

				if Bot then
					Bot:Initialize(kTeam2Index, true)
					Bot.lifeformEvolution = kTechId.Skulk
					Bots[#Bots + 1] = Bot
				end
			end
		end

		local function Cleanup()
			for _, Bot in ipairs(Bots) do pcall(function() Bot:Disconnect() end) end
			for _, Mouth in ipairs(Mouths) do pcall(function() Mouth:Kill() end) end
			Reg:Clear()
		end

		self:Defer( "integration_cycle", 6, false, function()
			local Takeover = horde.Takeover.New(controller, Reg)
			local Ids, MouthIds, BotIds = {}, {}, {}
			local Engaged = false
			local CapBefore = controller.MaxBots
			local LockBase = controller.updateLock
			local LiveBefore = horde.HordeRegistry:Count()

			local Ok, Err = pcall( function()
				if #Mouths == 0 or #Bots == 0 then
					Problems[#Problems + 1] = "could not create real entities for this map"
					return
				end

				if not Takeover:Engage() then Problems[#Problems + 1] = "engage refused" end
				Engaged = true

				-- Registration now works, and must yield the engine's own id.
				for _, Mouth in ipairs(Mouths) do
					local Id, RegErr = Reg:Register(Mouth, R.Kind.Mouth)

					if Id then
						Ids[#Ids + 1] = Id
						MouthIds[#MouthIds + 1] = Id
					else
						Problems[#Problems + 1] = "mouth: " .. tostring(RegErr)
					end
				end

				for _, Bot in ipairs(Bots) do
					local Id, RegErr = Reg:Register(Bot, R.Kind.Bot)

					if Id then
						Ids[#Ids + 1] = Id
						BotIds[#BotIds + 1] = Id
					else
						Problems[#Problems + 1] = "bot: " .. tostring(RegErr)
					end
				end

				for _, Id in ipairs(Ids) do
					if Id <= 0 then Problems[#Problems + 1] = "registry invented a local id for a real entity: " .. tostring(Id) end
				end

				if Reg:Count() ~= #Ids then Problems[#Problems + 1] = "registry count disagrees with what it holds" end

				for _, Mouth in ipairs(Mouths) do
					if Shared.GetEntity(Mouth:GetId()) == nil then
						Problems[#Problems + 1] = "a mouth vanished before we destroyed it"
					end
				end

				for _, Bot in ipairs(Bots) do
					local Player = Bot:GetPlayer()

					if not (Player and Player:GetIsAlive()) then
						Problems[#Problems + 1] = "a bot lost its player while the lock was held"
					end

					-- Re-measured with a genuine id: the PlayerBot entity is ALIVE. The
					-- earlier claim that its id disappears was an artifact of the registry's
					-- invented negative ids, and is retracted.
					if Shared.GetEntity(Bot:GetId()) == nil then
						Problems[#Problems + 1] = "PlayerBot entity gone while player lives: " .. tostring(Bot:GetId())
					end
				end

				-- Destroy everything we made, the way i7a will, and hand the registry
				-- back empty. Two measured engine facts shape this:
				--   * Kill() and Disconnect() do NOT take effect within the same tick -
				--     across two runs of this scenario the same Kill() was seen to clear 0
				--     of 2 ids and then 2 of 2 - so same-tick destruction is not merely
				--     delayed, it is nondeterministic. Nothing may assert on it. What i7a
				--     can rely on is polling on later ticks, which is what it is designed
				--     to do.
				--   * Because of that, the registry's contract is explicit: whoever created
				--     an entry unregisters it. Prune is for noticing destruction we did NOT
				--     perform, not for confirming our own.
				for _, Mouth in ipairs(Mouths) do pcall(function() Mouth:Kill() end) end
				for _, Bot in ipairs(Bots) do pcall(function() Bot:Disconnect() end) end

				local SameTick = Reg:Prune(function(Ref, Id) return Shared.GetEntity(Id) == nil end)

				print(string.format("[TEST-DIAG] same-tick pruned=%s of %s destroyed (expected 0)",
					tostring(SameTick), tostring(#Ids)))

				-- Prune already dropped what the engine had finished destroying, so only
				-- the survivors need unregistering. Requiring every id to still be present
				-- here would encode a timing assumption the engine does not guarantee.
				local Survivors = {}

				for _, Id in ipairs(Ids) do
					if Reg:GetKind(Id) then Survivors[#Survivors + 1] = Id end
				end

				for _, Id in ipairs(Survivors) do
					Reg:Unregister(Id)
				end

				if SameTick + #Survivors ~= #Ids then
					Problems[#Problems + 1] = string.format("accounting lost entries: pruned %s + survivors %s != %s",
						tostring(SameTick), tostring(#Survivors), tostring(#Ids))
				end

				if Reg:Count() ~= 0 then
					Problems[#Problems + 1] = string.format("registry holds %s after destroy + unregister", Reg:Count())
				end

				if Reg:CountByKind(R.Kind.Mouth) ~= 0 or Reg:CountByKind(R.Kind.Bot) ~= 0 then
					Problems[#Problems + 1] = "kind indexes survived Clear-equivalent"
				end

								local BeforeRelease = controller.updateLock

				if not Takeover:Release() then Problems[#Problems + 1] = "release refused" end
				Engaged = false

				if (BeforeRelease - controller.updateLock) ~= 1 then Problems[#Problems + 1] = "release did not remove exactly our lock" end
				if controller.MaxBots ~= CapBefore then Problems[#Problems + 1] = "cap not restored" end
				if controller.updateLock ~= LockBase then Problems[#Problems + 1] = "lock depth not returned" end
				if horde.HordeRegistry:Count() ~= LiveBefore then Problems[#Problems + 1] = "live registry touched by an isolated scenario" end
				if not horde.Enabled then Problems[#Problems + 1] = "extension unloaded by the cycle" end
				if not horde.Commands.sh_horde then Problems[#Problems + 1] = "commands lost after the cycle" end
			end )

			if not Ok then Problems[#Problems + 1] = "cycle threw: " .. tostring(Err) end

			Bots, Mouths = {}, {}
			Cleanup()

			if #Problems > 0 then
				error( { Detail = "registry+takeover integration: " .. table.concat(Problems, "; ") } )
			end
		end )
	end )

	-- i4a: the band, the dedupe and the sector rules ARE the design decisions (Q28,
	-- spike tby), so they are asserted as pure geometry over injected tables. No map,
	-- no entities, no engine - which is the only reason these are cheap to keep honest.
	self:RegisterScenario( "placement_rules_are_pure", false, function()
		local Placement = Shine.Plugins.hordemode.Placement
		local Base = { x = 0, y = 0, z = 0 }

		local function At(Distance)
			return { x = Distance, y = 0, z = 0 }
		end

		local Ring = {
			{ point = At(10) }, { point = At(60) }, { point = At(70) }, { point = At(200) }
		}

		local InBand = Placement.FilterBand(Ring, Base, 56, 90, 6)
		Assert.Equal( 2, #InBand, "only 60m and 70m fall inside the 56-90m band" )

		-- Adaptive path: a map whose anchors all sit outside the ring must still field
		-- a horde, but never closer than BandMin - "inside the base room" is the one
		-- thing the band exists to forbid.
		local None = Placement.FilterBand({ { point = At(10) }, { point = At(120) }, { point = At(150) } }, Base, 56, 90, 6)
		Assert.Equal( 2, #None, "empty band falls back to the nearest beyond BandMin" )
		Assert.Equal( 120, None[1] and None[1].distance or -1, "fallback orders by distance" )

		local RejectNear = Placement.FilterBand({ { point = At(5) }, { point = At(30) } }, Base, 56, 90, 6)
		Assert.Equal( 0, #RejectNear, "fallback never reaches inside BandMin" )

		local Dupes = Placement.GatherCandidates({ { At(0), At(1), At(200) } }, 5)
		Assert.Equal( 2, #Dupes, "points within 5m collapse to one site" )

		local Spread = {
			{ point = { x = 70, y = 0, z = 0 }, distance = 70 },
			{ point = { x = -35, y = 0, z = 60 }, distance = 70 },
			{ point = { x = -35, y = 0, z = -60 }, distance = 70 }
		}
		Assert.Equal( 3, #Placement.SelectSectorSpread(Spread, Base, 3), "one mouth per sector, three sectors" )
		Assert.Equal( 1, #Placement.SelectSectorSpread({ Spread[1], Spread[2] }, Base, 1), "count 1 keeps a single sector" )

		-- Sector membership comes from a normalised angle, and with three mouths per wave a
		-- sector is 120 degrees wide. This case discriminates on both facts: the candidate
		-- at 250 degrees (atan2 reports it as -110) must claim sector 2 even though it is the
		-- FARTHEST thing on the map. Un-normalised, sector 2 looks empty, the nearest-first
		-- fallback runs instead, and a second mouth lands 10 degrees from the first - the
		-- exact failure the rule exists to prevent, and invisible to a count-only assertion.
		local function AtDeg(Deg, Dist)
			local Rad = math.rad(Deg)

			return { point = { x = math.cos(Rad), y = 0, z = math.sin(Rad) }, distance = Dist }
		end

		local Ring = { AtDeg(10, 60), AtDeg(20, 70), AtDeg(130, 70), AtDeg(250, 80) }
		local Sectors = Placement.SelectSectorSpread(Ring, Base, 3)

		Assert.Equal( 3, #Sectors, "three sectors claim three of four candidates" )
		Assert.True( Sectors[1] == Ring[1], "sector 0 takes its nearest candidate" )
		Assert.True( Sectors[2] == Ring[3], "sector 1 is filled from its own side of the map" )
		Assert.True( Sectors[3] == Ring[4], "the -110-degree candidate is sector 2, not a leftover" )
		-- The fallback may under-fill, but it cannot manufacture coverage: two candidates
		-- in one sector are two places, not three mouths.
		Assert.Equal( 2, #Placement.SelectSectorSpread({ Ring[1], Ring[2] }, Base, 3),
			"one populated sector yields the candidates it has, no more" )

		--- The same rule drawn at random. Two claims, and the second is the one that matters:
		--- the sector must still yield exactly one candidate, AND the draw must be able to
		--- disagree with nearest-first. Without that, "randomised" could describe a seed that
		--- changes nothing - which is what the fixed grid effectively was: legal, deterministic,
		--- and the same three rooms every single wave.
		local Reached, Picks = {}, 0

		for Seed = 1, 40 do
			local Chosen = Placement.SelectSectorSpread(Ring, Base, 3, Placement.NewRandom(Seed))
			local Seen = {}

			Assert.Equal( 3, #Chosen, string.format("seed %s still fills three sectors", tostring(Seed)) )

			for _, Candidate in ipairs(Chosen) do
				if Seen[Candidate] then
					error( { Detail = "one candidate was chosen twice by the same draw" } )
				end

				Seen[Candidate] = true
				Reached[Candidate] = true
			end
		end

		for _ in pairs(Reached) do
			Picks = Picks + 1
		end

		Assert.True( Picks > 1, "across 40 seeds the sectors do not always yield the same candidates" )
		Assert.True( Reached[Ring[2]] ~= nil,
			"and the farther candidate in a sector is reachable by the draw - distance still ranks, it no longer dictates" )

		--- The leftover fill, which is where "one mouth per sector" stops covering what Arian
		--- actually saw: two mouths 11 m apart in the same corridor. A sector is a BEARING from the
		--- chair, so on a ring populated on one side the sectors under-fill and the fallback decides
		--- the rest - and a fallback that sorts by nearness picks the leftover nearest to a mouth it
		--- has already placed. Spread is the whole point of the rule, so the fill has to serve it.
		local Cluster = { AtDeg(10, 60), AtDeg(12, 61), AtDeg(20, 500) }
		local Filled = Placement.SelectSectorSpread(Cluster, Base, 2)

		Assert.Equal( 2, #Filled, "an empty sector is filled from what is left" )
		Assert.True( Filled[1] == Cluster[1], "the populated sector takes its own candidate" )
		Assert.True( Filled[2] == Cluster[3],
			string.format("and the fill reaches the distant leftover, not the one 1m from a mouth already placed (took %sm)",
				tostring(Filled[2] and Filled[2].distance or -1)) )

		--- The seed derivation, which is where "randomised" almost silently meant "the same every
		--- time". The first version seeded from `Shared.GetTime()` alone - seconds since BOOT - and
		--- two runs of this suite then produced `seed=1056` and identical coordinates, because the
		--- server reaches wave 1 at the same elapsed second on every boot. Measured before this
		--- assertion existed, in the fix rather than in the playtest.
		local Wave1 = Placement.SeedFor(1, 1700000000, 10.56)

		Assert.Equal( Wave1, Placement.SeedFor(1, 1700000000, 10.56), "a seed is reproducible" )
		Assert.True( Wave1 ~= Placement.SeedFor(1, 1700000001, 10.56),
			"and two boots a second apart do not draw the same wave - the bug this pins" )
		Assert.True( Placement.SeedFor(2, 1700000000, 10.56) ~= Wave1, "each wave draws differently" )

		--- And the generator's first output must not be a function of the seed. Un-warmed MINSTD
		--- gave 200 consecutive seeds that ALL drew into one decile (0.898-0.900) - technically
		--- deterministic, practically the same rotation every time. This is the assertion that
		--- catches a "random" stream that isn't.
		local Deciles, Values = {}, 0

		for Offset = 1, 200 do
			local Value = Placement.NewRandom(Placement.SeedFor(1, 1700000000 + Offset, 10.56))()

			Assert.True( Value >= 0 and Value < 1, "draws stay inside [0,1)" )
			Deciles[math.floor(Value * 10)] = true
		end

		for _ in pairs(Deciles) do
			Values = Values + 1
		end

		Assert.Equal( 10, Values, "seeds a second apart spread across the whole range, not clustered by their own value" )
	end )

	-- i4c: the engine-facing half, on the real map. What the pure scenario cannot say is
	-- whether this map's anchors actually field a wave, whether the band floor really
	-- holds against live geometry (a mouth inside the base room looks like working code
	-- in-game and is unwinnable), and whether a placed point survives a trip through the
	-- entity system. So this spawns the selected mouths and destroys them for real.
	self:RegisterScenario( "placement_collects_on_live_map", false, function()
		local horde = Shine.Plugins.hordemode
		local Config = horde.HordeConfig.Resolve(Shared.GetMapName())
		local Chosen, Base, RawCount, BandedCount = horde.Placement.Collect(Config)
		local Waves = Config.Waves or {}
		local BandMin = Waves.BandMin or 56
		local PerWave = Waves.ActivePerWave or 3

		print( string.format( "[TEST] placement on %s: raw=%s banded=%s chosen=%s base=%s band=%s-%sm",
			tostring(Shared.GetMapName()), tostring(RawCount), tostring(BandedCount), tostring(#Chosen),
			tostring(Base ~= nil), tostring(BandMin), tostring(Waves.BandMax) ) )

		Assert.True( RawCount > 0, "the live map exposes anchor entities to placement" )
		Assert.True( BandedCount > 0, "the configured band selects at least one candidate" )
		Assert.True( #Chosen <= (Waves.PoolSize or 6), "pool never exceeds PoolSize" )
		-- A wave must get its full sector count unless the map simply does not have that
		-- many banded candidates - comparing against BandedCount keeps this honest on a
		-- sparse map without turning the assertion into "whatever we got is fine".
		Assert.True( #Chosen >= math.min(PerWave, BandedCount),
			string.format("the wave gets %s mouths from %s banded candidates", tostring(PerWave), tostring(BandedCount)) )

		local Nearest
		local Occupied = {}

		if Base then
			local SectorWidth = (math.pi * 2) / PerWave

			for _, Candidate in ipairs(Chosen) do
				--- Two different claims, conflated by the first version of this loop: the ring
				--- selects on WALKING metres (the stored field), while the straight line is the
				--- base-room floor. Checking the line against BandMin is what failed once the
				--- ring moved to the measure a horde actually travels - a mouth 46.8 m away in a
				--- straight line and 56 m of walking is the intended outcome, not a regression,
				--- and the two bounds have to be asserted separately to say so.
				local Line = horde.Placement.Distance2D(Candidate.point, Base)

				Assert.True( Candidate.distance and Candidate.distance >= BandMin,
					string.format("a chosen mouth is only %sm of walking, inside the %sm ring",
						tostring(Candidate.distance), tostring(BandMin)) )
				Assert.True( Line >= BandMin * 0.5,
					string.format("a chosen mouth sits %.1fm from the chair in a straight line, inside the base room",
						Line) )

				Nearest = Nearest and math.min(Nearest, Line) or Line

				local Angle = math.atan2(Candidate.point.z or Candidate.point[3],
					Candidate.point.x or Candidate.point[1])

				if Angle < 0 then
					Angle = Angle + math.pi * 2
				end

				Occupied[math.floor(Angle / SectorWidth) + 1] = true
			end

			-- Distinct mouths, not one site counted twice. GatherCandidates collapses
			-- anything within 5 m, so two chosen points closer than that means the pool and
			-- the selection disagree about what "a place" is - and the wave would arrive down
			-- one corridor while every sector assertion still passed.
			for A = 1, #Chosen do
				for B = A + 1, #Chosen do
					local Apart = horde.Placement.Distance2D(Chosen[A].point, Chosen[B].point)
					Assert.True( Apart > 5,
						string.format("mouths %s and %s are the same site (%sm apart)",
							tostring(A), tostring(B), tostring(Apart)) )
				end
			end
		end

		local SectorCount = 0

		for _ in pairs(Occupied) do
			SectorCount = SectorCount + 1
		end

		-- Reported, not asserted: this is the bead's "document the actual band" deliverable.
		-- One-per-sector is a promise the selector can only keep where the map has candidates
		-- in that sector, and summit fields three mouths out of two sectors - the third comes
		-- from the nearest-first fallback. A repeated sector is a fact about the map; an
		-- occupied sector producing no mouth would be a bug in the code, and that is what the
		-- pure scenario pins.
		print( string.format( "[TEST] %s/%s mouths in %s of %s sectors, nearest %sm from base (band %s-%sm)",
			tostring(#Chosen), tostring(BandedCount), tostring(SectorCount), tostring(PerWave),
			tostring(Nearest), tostring(BandMin), tostring(Waves.BandMax) ) )

		local Reg = horde.Registry.New(horde.Registry.EngineStateOf)
		local Spawn = horde.Spawner.New(Reg, function(Message) print("[TEST] " .. Message) end)
		local Queued = 0

		for _, Candidate in ipairs(Chosen) do
			local Mouth, Reason = Spawn:SpawnMouth(Candidate.point)

			if Mouth then
				Queued = Queued + 1
			else
				print( string.format("[TEST] chosen point rejected by the engine: %s", tostring(Reason)) )
			end
		end

		Assert.True( Queued > 0, "a selected point accepts a tunnel entrance" )

		self:Defer( "placement_collects_on_live_map_settles", 6, false, function()
			Spawn:Pump()

			local Ids = Reg:GetAllIds()
			Assert.Equal( Queued, #Ids, "every queued mouth registered once its id was real" )

			local _, Failed, Total = horde.DestroyAll(Reg, {}, nil)
			Assert.Equal( Queued, Total, "teardown drained everything that was placed" )
			Assert.Equal( 0, #Failed, "no destroy failures: " .. table.concat(Failed, "; ") )
			Assert.Equal( 0, Reg:Count(), "nothing left on the books" )

			for _, Id in ipairs(Ids) do
				Assert.Nil( Shared.GetEntity(Id), string.format("mouth %s still resolves after destroy", tostring(Id)) )
			end
		end )
	end )

	-- i4b: a mouth really appears, is registered once its id is valid, and really goes
	-- away. Same-tick registration is reported rather than asserted: whether the engine
	-- has an id for a global CreateEntity result immediately is its business, and a
	-- brittle assertion here would only prove we cannot read the engine.
	self:RegisterScenario( "mouth_lifecycle", false, function()
		local horde = Shine.Plugins.hordemode
		local Reg = horde.Registry.New(horde.Registry.EngineStateOf)
		local Spawn = horde.Spawner.New(Reg, function(Message) print("[TEST] " .. Message) end)

		-- Through the surface gate: SpawnMouth refuses a point the engine would not build on,
		-- so a raw Location origin here would test the refusal rather than the lifecycle.
		local Anchor = SurfaceAnchors(1)[1]

		Assert.NotNil( Anchor, "the live map has a buildable surface to place a mouth at" )

		local Mouth, Reason = Spawn:SpawnMouth(Anchor)
		Assert.NotNil( Mouth, "SpawnMouth returns an entity" )

		local SameTickId = Reg:Register(Mouth, "mouth")
		print( string.format( "[TEST] mouth same-tick register: id=%s", tostring(SameTickId) ) )
		Reg:Clear()

		self:Defer( "mouth_lifecycle_settles", 6, false, function()
			local Registered = Spawn:Pump()
			Assert.True( Registered >= 1, "the queued mouth registers once its id is valid" )

			local Ids = Reg:GetAllIds()
			Assert.Equal( 1, #Ids, "exactly one mouth on the books" )

			local Id = Ids[1]
			Assert.NotNil( Shared.GetEntity(Id), "the registered id resolves to a live entity" )

			Assert.True( Spawn:DestroyMouth(Id), "DestroyMouth reports the entity it removed" )
			Assert.Equal( 0, Reg:Count(), "registry is empty after destroy" )
			Assert.Nil( Shared.GetEntity(Id), "the mouth is really gone from the world" )
		end )
	end )

	-- i7b: RD6's bar - our created set is destroyed, the registry ends empty, and the
	-- ids stop resolving. Asserted against real mouths: a diff that only passes against
	-- doubles proves nothing about the engine's destroy order, and an entity that keeps
	-- resolving after DestroyEntity would leak a mouth on every stop.
	self:RegisterScenario( "teardown_destroys_what_we_made", false, function()
		local horde = Shine.Plugins.hordemode
		local Reg = horde.Registry.New(horde.Registry.EngineStateOf)
		local Spawn = horde.Spawner.New(Reg, function(Message) print("[TEST] " .. Message) end)

		local Anchors = SurfaceAnchors(2)

		Assert.True( #Anchors >= 2, "two buildable surfaces available for the created set" )

		for _, Anchor in ipairs(Anchors) do
			Spawn:SpawnMouth(Anchor)
		end

		self:Defer( "teardown_destroys_what_we_made_settled", 6, false, function()
			Spawn:Pump()

			local Ids = Reg:GetAllIds()
			local Problems = {}

			if #Ids < 2 then
				Problems[#Problems + 1] = string.format("expected at least 2 registered mouths, got %s", tostring(#Ids))
			end

			local Destroyed, Failed, Total = horde.DestroyAll(Reg, {}, nil)

			if #Failed > 0 then
				Problems[#Problems + 1] = "destroy failures: " .. table.concat(Failed, "; ")
			end

			if Total < 2 then
				Problems[#Problems + 1] = "drained fewer entries than were registered"
			end

			if Reg:Count() ~= 0 then
				Problems[#Problems + 1] = "registry not empty after teardown"
			end

			for _, Id in ipairs(Ids) do
				if Shared.GetEntity(Id) ~= nil then
					Problems[#Problems + 1] = "entity " .. tostring(Id) .. " still resolves after destroy"
				end
			end

			print( string.format( "[TEST] teardown diff: %s entries destroyed=%s, still registered=%s",
				tostring(Total), tostring(Destroyed.mouth or 0), tostring(Reg:Count()) ) )

			if #Problems > 0 then
				error( { Detail = "teardown integrity: " .. table.concat(Problems, "; ") } )
			end
		end )
	end )

	-- The M4+M7 slice as Arian will hit it in-game: start the machine, place a wave's
	-- mouths through the real plugin, let the tick pump register them, then stop and
	-- tear down. This is the only scenario that exercises the *wiring* - BeginWave
	-- reaching Placement and the Spawner, HordeTick registering what was queued,
	-- Teardown emptying the registry and handing the controller back.
	--
	-- It swaps in private registry + spawner instances for the duration. That is not
	-- shyness about destroying: the first version tore down the plugin's real registry
	-- and correctly killed takeover_live_cycle's bot, which registers there at :732 and
	-- checks it at t+8 - after this scenario's t+6 teardown. Teardown is a global
	-- operation by design, so anything that calls it must own the state it covers.
	self:RegisterScenario( "wave_slice_end_to_end", false, function()
		local horde = Shine.Plugins.hordemode
		local Config = horde.HordeConfig.Resolve(Shared.GetMapName())

		Assert.NotNil( horde.Machine, "plugin is armed by test time" )

		local SavedRegistry, SavedSpawner = horde.HordeRegistry, horde.HordeSpawner

		horde.HordeRegistry = horde.Registry.New(horde.Registry.EngineStateOf)
		horde.HordeSpawner = horde.Spawner.New(horde.HordeRegistry, function(Message) print("[TEST] " .. Message) end)

		horde.Machine:Start(Shared.GetTime())

		-- A successful start that says nothing is the exact complaint from the field,
		-- so the broadcast is part of the contract, not decoration. Notify with a nil
		-- target is Shine's broadcast path (ApplyNetworkMessage -> SendNetworkMessage
		-- with no client), so the assertion is on the target, not on a log line.
		local SavedNotify = horde.Notify
		local Broadcasts = {}

		horde.Notify = function(self, Target, Message, Format, ...)
			if Target == nil then
				Broadcasts[#Broadcasts + 1] = Message
			end
		end

		local Placed = horde:BeginWave(Config)

		horde.Notify = SavedNotify

		Assert.True( Placed >= 1, "wave 1 places at least one mouth on the live map" )
		Assert.Equal( 1, #Broadcasts, "a successful wave announces itself to everyone" )

		if Broadcasts[1] and not Broadcasts[1]:find("WAVE 1") then
			error( { Detail = "start broadcast does not name the wave: " .. tostring(Broadcasts[1]) } )
		end

		self:Defer( "wave_slice_settles", 6, false, function()
			local Problems = {}
			local Registered = horde.HordeRegistry:CountByKind("mouth")

			if Registered < 1 then
				Problems[#Problems + 1] = "the tick pump registered no mouths"
			end

			-- The status line reads these off the machine. BeginWave used to place
			-- three real mouths and leave both fields nil, so BuildStatusLine printed
			-- "mouths=-/-" and told the player the wave was empty. Asserting on the
			-- REAL machine is the point: the older status scenarios inject their own
			-- machine and can never see this class of bug.
			if horde.Machine.MouthsPool ~= Registered then
				Problems[#Problems + 1] = string.format("MouthsPool=%s but %s mouths registered",
					tostring(horde.Machine.MouthsPool), tostring(Registered))
			end

			if horde.Machine.MouthsActive ~= Registered then
				Problems[#Problems + 1] = "MouthsActive not refreshed by the tick"
			end

			if horde:BuildStatusLine(horde.Triggers.TakeSnapshot(nil), horde.Machine,
				horde.HordeConfig.Resolve(Shared.GetMapName()), Shared.GetTime(),
				horde.HordeRegistry, horde.HordeTakeover):find("%-/%-") then
				Problems[#Problems + 1] = "status still renders mouths as -/- while mouths exist"
			end

			local Ids = horde.HordeRegistry:GetAllIds()

			horde.Machine:Stop("test slice", Shared.GetTime())
			horde:Teardown(Shared.GetTime())

			if horde.HordeRegistry:Count() ~= 0 then
				Problems[#Problems + 1] = "plugin registry not empty after teardown"
			end

			if horde.Machine.MouthsActive ~= 0 then
				Problems[#Problems + 1] = "MouthsActive still counts mouths after teardown"
			end

			if horde.HordeTakeover:IsEngaged() then
				Problems[#Problems + 1] = "bot controller still held after teardown"
			end

			for _, Id in ipairs(Ids) do
				if Shared.GetEntity(Id) ~= nil then
					Problems[#Problems + 1] = "mouth " .. tostring(Id) .. " survived teardown"
				end
			end

			if not horde.Machine:Is(horde.Phase.Inactive) then
				Problems[#Problems + 1] = "machine did not return to inactive"
			end

			-- Hand the plugin's real bookkeeping back before anything can fail. A
			-- scenario that leaves swapped state behind would poison every later run,
			-- and the failure would surface as someone else's assertion.
			horde.HordeRegistry, horde.HordeSpawner = SavedRegistry, SavedSpawner

			if #Problems > 0 then
				error( { Detail = "wave slice: " .. table.concat(Problems, "; ") } )
			end
		end )
	end )

	-- The victory screen a joining marine saw on frame one was not a wave bug: with no
	-- hive and no aliens, vanilla's own loss check fires immediately
	-- (ns2/lua/PlayingTeam.lua:536-546). What matters for the clean-slate promise is that
	-- we suppress exactly one engine field, keep it suppressed against resets, and give it
	-- back - so this asserts the round trip on the live gamerules object.
	self:RegisterScenario( "game_end_suppression_is_isolated", false, function()
		local horde = Shine.Plugins.hordemode
		local Gamerules = GetGamerules()

		Assert.NotNil( Gamerules, "the suite runs against a live gamerules object" )
		Assert.NotNil( horde.SuppressGameEnd, "hordemode exposes game-end suppression" )
		Assert.NotNil( horde.RestoreGameEnd, "hordemode exposes the release" )

		horde:RestoreGameEnd("scenario entry")

		Assert.True( horde:SuppressGameEnd(), "suppression engages on the engine's own switch" )
		Assert.Equal( true, Gamerules.preventGameEnd, "preventGameEnd is set on the gamerules object itself" )
		Assert.True( not horde:SuppressGameEnd(), "engaging twice is a no-op, not a second claim of credit" )

		-- ResetGame clears the flag (NS2Gamerules.lua:702). The tick is what notices, so
		-- simulate the surprise clear rather than paying for a whole round reset.
		Gamerules.preventGameEnd = nil

		local RealMachine = horde.Machine

		horde.Machine = { IsActive = function() return true end }
		horde:HordeTick()
		horde.Machine = RealMachine

		Assert.Equal( true, Gamerules.preventGameEnd, "the tick re-engages after a vanilla reset cleared it" )

		-- A stopped horde must not keep re-engaging it, or the suppression outlives the
		-- mode and the server silently stops awarding wins.
		horde.Machine = { IsActive = function() return false end }
		Gamerules.preventGameEnd = nil
		horde:HordeTick()
		horde.Machine = RealMachine

		Assert.True( Gamerules.preventGameEnd == nil, "an inactive horde leaves game end alone" )

		horde.Machine = { IsActive = function() return true end }
		horde:SuppressGameEnd()
		horde.Machine = RealMachine

		Assert.True( horde:RestoreGameEnd("scenario exit"), "release reports that it changed the field" )
		Assert.True( Gamerules.preventGameEnd == nil, "vanilla win/loss is back exactly where we found it" )
		Assert.True( not horde:RestoreGameEnd("scenario exit twice"), "releasing an already-released field is a no-op" )
	end )

	-- (a) "Is there an easier way than putting a player on the aliens?" Yes: preventGameEnd,
	-- shipped in f369898. This probe supplies the measurement that settles the alternative
	-- instead of another argument about it.
	--
	-- GetHasTeamLost (PlayingTeam.lua:533) ORs four branches: nothing alive that can respawn,
	-- zero alive command structures, zero players, and concession. A lone commander answers
	-- the two that count people and none of the ones that count structures - and a hive IS the
	-- alien structure (Hive.lua:28: class 'Hive' (CommandStructure)). So "just put an alien
	-- commander on the team" holds only while some alien command structure is standing, which
	-- is not a condition our mode creates: ResetWorldForHorde destroys live entities before it
	-- places anything (server.lua:382, NS2Gamerules.lua:496-516).
	--
	-- Order is load-bearing for a reason the first run taught: the probe RESTORES BEFORE IT
	-- ASSERTS. The version that asserted first raised mid-block, left the recorder installed
	-- and the world in Started, and three later bot scenarios failed with symptoms pointing
	-- nowhere near here.
	self:RegisterScenario( "vanilla_ends_the_round_unless_suppressed", false, function()
		local horde = Shine.Plugins.hordemode
		local Gamerules = GetGamerules()
		local Aliens, Marines = Gamerules.team2, Gamerules.team1

		Assert.NotNil( Aliens, "gamerules carries the alien team" )
		Assert.NotNil( Marines, "gamerules carries the marine team" )

		local Result = {}
		local Calls = {}

		local SavedState = Gamerules.gameState
		local SavedEndGame, SavedDraw = Gamerules.EndGame, Gamerules.DrawGame
		local SavedLatch1, SavedLatch2 = Gamerules.team1Lost, Gamerules.team2Lost
		local SavedWindow = Gamerules.timeDrawWindowEnds

		local function Restore()
			Gamerules.EndGame = SavedEndGame
			Gamerules.DrawGame = SavedDraw
			Gamerules.team1Lost, Gamerules.team2Lost = SavedLatch1, SavedLatch2
			Gamerules.timeDrawWindowEnds = SavedWindow

			if Gamerules.gameState ~= SavedState then
				Gamerules:SetGameState(SavedState)
			end

			-- Released, not left on. An inactive horde has no business holding win/loss, and
			-- both directions are idempotent so this cannot double-release.
			horde:RestoreGameEnd("probe restore")
		end

		--- Ask the engine's own predicate what it decides for a trio of inputs. Only what the
		--- question is about is replaced: GetHasConceded and GetHasAbilityToRespawn stay real,
		--- so the verdict is still the engine's and not one we handed back.
		local function Verdict(Players, Alive, Structures)
			local RealPlayers, RealAlive = Aliens.GetNumPlayers, Aliens.GetHasActivePlayers
			local RealStructures = Aliens.GetNumAliveCommandStructures

			Aliens.GetNumPlayers = function() return Players end
			Aliens.GetHasActivePlayers = function() return Alive end
			Aliens.GetNumAliveCommandStructures = function() return Structures end

			local Lost = Aliens:GetHasTeamLost()

			Aliens.GetNumPlayers = RealPlayers
			Aliens.GetHasActivePlayers = RealAlive
			Aliens.GetNumAliveCommandStructures = RealStructures

			return Lost
		end

		local function Measure()
			if Shared.GetCheatsEnabled() then
				error( { Detail = "cheats are on: CheckGameEnd returns early for a reason unrelated to us" } )
			end

			if Aliens:GetHasConceded() then
				error( { Detail = "the alien team had already conceded - every branch below measures the wrong thing" } )
			end

			-- Both the predicate and the check require a STARTED game (PlayingTeam.lua:536,
			-- NS2Gamerules.lua:1788). A horde round gets there through vanilla's own 6 s
			-- countdown, which this harness cannot wait out, so the state is set by hand and
			-- put back by Restore().
			Gamerules:SetGameState(kGameState.Started)

			Result.AlienPlayers = Aliens:GetNumPlayers()
			Result.AlienAlive = Aliens:GetHasActivePlayers()
			Result.AlienStructures = Aliens:GetNumAliveCommandStructures()
			Result.AlienRespawn = Aliens:GetHasAbilityToRespawn()
			Result.AlienLost = Aliens:GetHasTeamLost()
			Result.MarineLost = Marines:GetHasTeamLost()
			Result.MarineStructures = Marines:GetNumAliveCommandStructures()
			Result.MarinePlayers = Marines:GetNumPlayers()

			-- The commander counterfactual, both worlds: one alive alien player, with and
			-- without an alien command structure standing.
			Result.CommanderWithStructure = Verdict(1, true, 1)
			Result.CommanderNoStructure = Verdict(1, true, 0)
			Result.NobodyNoStructure = Verdict(0, false, 0)

			-- Both ways an engine ends a round are recorded (NS2Gamerules.lua:1826-1840): zero
			-- alive command structures on BOTH sides is a draw, and on a headless WarmUp server
			-- that is a live possibility rather than a hypothetical. The first version of this
			-- probe assumed the outcome was a marine award and was wrong about this world.
			Gamerules.EndGame = function(self, WinningTeam)
				Calls[#Calls + 1] = { Kind = "end", Winner = WinningTeam }
			end

			Gamerules.DrawGame = function(self)
				Calls[#Calls + 1] = { Kind = "draw" }
			end

			-- Unsuppressed: vanilla decides on its own code path. The decision is the engine's;
			-- only its consequence is withheld, so the world survives to run the next scenario.
			horde:RestoreGameEnd("probe")
			Gamerules:CheckGameEnd()

			Result.Latched = Gamerules.team2Lost
			Result.WindowOpened = Gamerules.timeDrawWindowEnds ~= nil
			Result.CallsAfterLatch = #Calls

			-- The decision lands one kDrawGameWindow (0.75 s) after the latch. Closing the
			-- window by hand keeps the whole probe inside one synchronous block, where the
			-- plugin's own 1 s tick cannot arrive and re-engage suppression mid-measurement.
			Gamerules.timeDrawWindowEnds = Shared.GetTime() - 1
			Gamerules:CheckGameEnd()

			Result.Decision = Calls[1] and Calls[1].Kind
			Result.WinnerIsMarines = Calls[1] ~= nil and Calls[1].Winner == Marines
			Result.CallsAfterWindow = #Calls

			-- Same world, same standing loss, suppression back on: inert. This is the whole
			-- difference between a round that ends on frame one and one that runs.
			Gamerules.team1Lost, Gamerules.team2Lost = nil, nil
			Gamerules.timeDrawWindowEnds = nil
			horde:SuppressGameEnd()
			Gamerules:CheckGameEnd()

			Result.CallsAfterSuppression = #Calls
			Result.EvaluatedWhileSuppressed = Gamerules.team2Lost
		end

		local Ok, Err = pcall(Measure)

		Restore()

		if not Ok then
			error( { Detail = "probe raised before it could restore: " .. tostring(Err) } )
		end

		print( string.format(
			"[TEST] aliens as vanilla scores them now: players=%s alive=%s structures=%s canRespawn=%s -> hasLost=%s",
			tostring(Result.AlienPlayers), tostring(Result.AlienAlive), tostring(Result.AlienStructures),
			tostring(Result.AlienRespawn), tostring(Result.AlienLost) ) )
		print( string.format(
			"[TEST] marines: players=%s structures=%s -> hasLost=%s (a draw needs both sides beaten)",
			tostring(Result.MarinePlayers), tostring(Result.MarineStructures), tostring(Result.MarineLost) ) )
		print( string.format(
			"[TEST] one alien commander decides nothing: with a structure=%s without=%s nobody=%s",
			tostring(Result.CommanderWithStructure), tostring(Result.CommanderNoStructure),
			tostring(Result.NobodyNoStructure) ) )
		print( string.format(
			"[TEST] unsuppressed: latched=%s calls=%s/%s decision=%s toMarines=%s | suppressed: calls=%s evaluated=%s",
			tostring(Result.Latched), tostring(Result.CallsAfterLatch), tostring(Result.CallsAfterWindow),
			tostring(Result.Decision), tostring(Result.WinnerIsMarines),
			tostring(Result.CallsAfterSuppression), tostring(Result.EvaluatedWhileSuppressed) ) )

		-- The dangerous state is measured, not assumed.
		Assert.Equal( 0, Result.AlienPlayers, "the measured world really has no alien players" )
		Assert.True( Result.AlienLost, "and the engine already considers the alien side beaten" )

		-- The answer to the proposal, measured: a living alien clears the loss ONLY while an
		-- alien command structure is standing. A horde round builds no hive, so the branch that
		-- stays true is the one presence cannot answer.
		Assert.False( Result.CommanderWithStructure, "with a structure standing, one alive alien does clear the loss" )
		Assert.True( Result.CommanderNoStructure, "with none standing the same alien loses anyway: that branch counts structures, not people" )
		Assert.True( Result.NobodyNoStructure, "and of course so does nobody" )

		Assert.True( Result.Latched == true, "unsuppressed, CheckGameEnd latches the alien loss itself" )
		Assert.True( Result.WindowOpened, "and opens the draw window" )
		Assert.Equal( 0, Result.CallsAfterLatch, "inside the window nothing has been called yet" )
		Assert.Equal( 1, Result.CallsAfterWindow, "once the window closes, vanilla ends this round on its own path" )

		if Result.MarineLost then
			-- Both sides beaten inside the window is a draw, by the engine's own rule.
			Assert.Equal( "draw", Result.Decision,
				string.format("the marines read as beaten too (players=%s structures=%s), so the call is a draw",
					tostring(Result.MarinePlayers), tostring(Result.MarineStructures)) )
		else
			Assert.Equal( "end", Result.Decision, "with the marine side intact the call is an award, not a draw" )
			Assert.True( Result.WinnerIsMarines, "awarded to the marines" )
		end

		Assert.Equal( 1, Result.CallsAfterSuppression, "suppressed, nothing further was called" )
		Assert.Nil( Result.EvaluatedWhileSuppressed, "suppressed, the loss is never even evaluated" )

		Assert.Equal( SavedState, Gamerules.gameState, "the game state was left where it was found" )
		Assert.True( Gamerules.EndGame == SavedEndGame and Gamerules.DrawGame == SavedDraw,
			"both recorders were taken off the engine object" )
		Assert.True( Gamerules.preventGameEnd == nil, "the probe left win/loss with vanilla" )
	end )

	-- (b) Debug.RevealMouths, the placement aid, tested through the production path.
	--
	-- Why a marine sees nothing today: every TunnelEntrance is given a MapBlip of its OWN
	-- team during OnInitialized (TunnelEntrance.lua:152-158, MapBlipMixin.lua:217+232), and
	-- that blip's relevancy is team 2 (MapBlip.lua:82-96). The fix therefore does not touch
	-- that blip. It marks the mouth DETECTED, and the engine then builds its own marine-side
	-- marker, SensorBlip, whose relevancy is the constant team 1 (SensorBlip.lua:32-49):
	-- drawn through walls on every marine screen (Marine_Client.lua:42-100 - the occlusion
	-- trace there is commented out) and as a minimap icon (SensorBlip.lua:54-64). We create
	-- no entity and fake no gameplay object, and DetectableMixin destroys the marker with the
	-- entity it tracks (DetectableMixin.lua:117-126), so a stopped horde cannot leak one.
	--
	-- Detection expires 1.5 s after it was last asserted (DetectableMixin.lua:98-105), so
	-- this drives the REAL 1 s plugin tick rather than calling RefreshReveal by hand: a
	-- marker that only survives one second is not an aid. Two earlier versions of this
	-- scenario failed honestly - one looked 6 s after a single reveal (nothing left to find),
	-- and one revealed both mouths because the flag lived in two places at once.
	self:RegisterScenario( "revealed_mouths_stay_visible_to_marines", false, function()
		local horde = Shine.Plugins.hordemode
		local Anchors = SurfaceAnchors(2)

		Assert.True( #Anchors >= 2, "two buildable surfaces for the paired comparison" )

		local function Log(Message) print("[TEST] " .. Message) end

		local function MarkerOf(Id)
			for _, Marker in ientitylist(Shared.GetEntitiesWithClassname("SensorBlip")) do
				if Marker.entId == Id then
					return Marker
				end
			end
		end

		-- The control: a spawner of our own that nobody ticks. It never registers with the
		-- plugin and its Reveal is off, so nothing can reveal its mouth by accident.
		local Quiet = horde.Registry.New(horde.Registry.EngineStateOf)
		local SpawnQuiet = horde.Spawner.New(Quiet, Log, false)

		-- The subject: installed as the plugin's own spawner so the production tick pumps
		-- and re-asserts it. Swapped, saved and handed back by the settle block below, with
		-- the same discipline wave_slice_end_to_end documents - the tick is global, so
		-- anything that runs it must own the bookkeeping it writes.
		local SavedRegistry, SavedSpawner, SavedCount = horde.HordeRegistry, horde.HordeSpawner, horde.HordeRegistry:Count()
		local Loud = horde.Registry.New(horde.Registry.EngineStateOf)
		local SpawnLoud = horde.Spawner.New(Loud, Log, true)

		horde.HordeRegistry, horde.HordeSpawner = Loud, SpawnLoud

		local Hidden = SpawnQuiet:SpawnMouth(Anchors[1])
		local Visible = SpawnLoud:SpawnMouth(Anchors[2])

		Assert.NotNil( Hidden, "the control mouth exists" )
		Assert.NotNil( Visible, "the revealed mouth exists" )
		Assert.False( Hidden:GetIsDetected(), "a spawner built without the flag leaves its mouth undetected" )
		Assert.True( Visible:GetIsDetected(), "a spawner built with it reveals at creation" )

		-- 5 s: five expiries deep, so "still detected" can only be the tick's doing. It also
		-- lands BEFORE wave_slice_end_to_end's 6 s settle, which restores the real spawner -
		-- ordering the two settle blocks this way keeps either of them from reading the
		-- other's bookkeeping as its own.
		self:Defer( "revealed_mouths_stay_visible_to_marines_settles", 5, false, function()
			SpawnQuiet:Pump()

			local Problems = {}
			local HiddenId, VisibleId = Hidden:GetId(), Visible:GetId()

			if Loud:Count() ~= 1 then
				Problems[#Problems + 1] = string.format("the production tick registered %s of 1 mouth", tostring(Loud:Count()))
			end

			if Visible:GetIsDetected() ~= true then
				Problems[#Problems + 1] = "the revealed mouth stopped being detected - HordeTick is not re-asserting it"
			end

			if Hidden:GetIsDetected() then
				Problems[#Problems + 1] = "the control mouth became detected anyway"
			end

			local Marker = MarkerOf(VisibleId)

			if not Marker then
				Problems[#Problems + 1] = string.format("no SensorBlip for %s - a marine would still see nothing", tostring(VisibleId))
			elseif bit.band(Marker:GetExcludeRelevancyMask(), kRelevantToTeam1) == 0 then
				Problems[#Problems + 1] = string.format("the marker's relevancy excludes marines (mask %s)",
					tostring(Marker:GetExcludeRelevancyMask()))
			end

			if MarkerOf(HiddenId) then
				Problems[#Problems + 1] = "a marker exists for the mouth that was never revealed"
			end

			-- Turning the flag off must stop the re-assertion. Detection itself then lapses on
			-- the engine's clock, which is the honest contract: we do not revoke, we stop
			-- insisting - and destroying the mouth takes the marker with it either way.
			SpawnLoud.Reveal = false

			if SpawnLoud:RefreshReveal() ~= 0 then
				Problems[#Problems + 1] = "RefreshReveal still revealed mouths after the flag went off"
			end

			print( string.format(
				"[TEST] reveal at t+5s: loud=%s quiet=%s marker=%s mask=%s registered=%s/%s",
				tostring(Visible:GetIsDetected()), tostring(Hidden:GetIsDetected()),
				tostring(Marker ~= nil), tostring(Marker and Marker:GetExcludeRelevancyMask() or "-"),
				tostring(Loud:Count()), tostring(Quiet:Count()) ) )

			SpawnLoud:DestroyMouth(VisibleId)
			SpawnQuiet:DestroyMouth(HiddenId)

			local LeftMarker = MarkerOf(VisibleId)

			horde.HordeRegistry, horde.HordeSpawner = SavedRegistry, SavedSpawner

			if SavedRegistry:Count() ~= SavedCount then
				Problems[#Problems + 1] = string.format("the plugin's real registry changed under the probe: %s -> %s",
					tostring(SavedCount), tostring(SavedRegistry:Count()))
			end

			if LeftMarker then
				Problems[#Problems + 1] = "destroying the mouth left its marine marker in the world"
			end

			if #Problems > 0 then
				error( { Detail = "reveal: " .. table.concat(Problems, "; ") } )
			end
		end )
	end )

	-- The engine's build gate, tested by injecting answers. This is the mechanic that was
	-- missing: a marine walked summit and found three mouths "nowhere near the surface", and
	-- the cause was that SpawnMouth was handed raw anchor origins - volume markers - with
	-- nothing ever asking the level whether anything stood there. Each branch below is a way
	-- the engine can say no, and each has to be reported rather than quietly producing a mouth
	-- in rock.
	self:RegisterScenario( "placement_surface_gate_is_pure", false, function()
		local Placement = Shine.Plugins.hordemode.Placement

		local function At(Y)
			return { x = 60, y = Y, z = 0 }
		end

		-- No ground beneath the anchor at all: unbuildable, whatever the anchor looked like.
		local NoGround = { Ground = function() return nil end, Flags = function() return { walk = true } end, Collide = function() return false end }

		local Point, Reason = Placement.SnapToSurface(At(0), NoGround)

		Assert.Nil( Point, "an anchor with no ground under it is refused" )
		Assert.Equal( "no ground under anchor", Reason, "and says why" )

		-- Ground exists, but the nav mesh says no-build: the vent case Arian described.
		local NoBuild = { Ground = function(P) return P end, Flags = function() return { walk = true, nobuild = true } end, Collide = function() return false end }

		Point, Reason = Placement.SnapToSurface(At(0), NoBuild)

		Assert.Nil( Point, "a no-build zone is refused even with floor under it" )
		Assert.Equal( "no-build zone", Reason, "and says why" )

		-- Floor, no no-build flag, but nothing walkable either: mid-air, or outside the mesh.
		local OffMesh = { Ground = function(P) return P end, Flags = function() return { walk = false } end, Collide = function() return false end }

		Point, Reason = Placement.SnapToSurface(At(0), OffMesh)

		Assert.Nil( Point, "off the walk mesh is refused" )
		Assert.Equal( "not on walk mesh", Reason, "and says why" )

		-- Floor, walkable, but the mouth's own capsule overlaps the world: inside the geometry.
		local Obstructed = { Ground = function(P) return P end, Flags = function() return { walk = true } end, Collide = function() return true end }

		Point, Reason = Placement.SnapToSurface(At(0), Obstructed)

		Assert.Nil( Point, "a spot whose capsule overlaps the world is refused" )
		Assert.Equal( "overlaps world", Reason, "and says why" )

		-- An engine call that throws is a rejection, not a crash: one odd brush on one level
		-- must not take wave placement down with it.
		local Throwing = { Ground = function() error("nav mesh unavailable") end }

		Point, Reason = Placement.SnapToSurface(At(0), Throwing)

		Assert.Nil( Point, "a throwing engine query rejects the point" )
		Assert.Equal( "no ground under anchor", Reason, "with the reason of the step that failed" )

		-- The accepted case, and the one that matters downstream: the anchor is 40 m up in the
		-- air, the ground query returns a floor elsewhere, and everything after this (band,
		-- dedupe, sector) must measure the SNAPPED point, not the anchor.
		local Landed = {
			Ground = function() return { x = 60, y = 0, z = 0 } end,
			Flags = function() return { walk = true } end,
			Collide = function() return false end
		}

		Point, Reason = Placement.SnapToSurface(At(40), Landed)

		Assert.NotNil( Point, "a valid surface is accepted" )
		Assert.Nil( Reason, "and carries no refusal" )
		Assert.Equal( 0, Placement.Axis(Point, "y", 2), "the usable point is the floor, not the anchor's height" )

		-- Two anchors that snap to the same floor point must become one site. Before the gate
		-- this was impossible to hit; now it is the common case (a portal and a cyst in one
		-- room), and two mouths on one point is the corridor bug back again by another road.
		local Same = {
			Ground = function() return { x = 60, y = 0, z = 0 } end,
			Flags = function() return { walk = true } end,
			Collide = function() return false end
		}

		local Validated, Stats = Placement.ValidateCandidates({ At(0), At(12), At(24) }, Same)

		Assert.Equal( 3, Stats.raw, "three anchors were offered" )
		Assert.Equal( 3, Stats.usable, "all three snapped to ground" )
		Assert.Equal( 1, #Placement.GatherCandidates({ Validated }, 5), "and they collapse to the one place they actually are" )

		-- The tally the log prints. "usable 0 of 48, no ground=48" is an anchor-source bug;
		-- "in band 0" is a ring that misses this map. From the chair they look identical.
		local Partly = {
			Ground = function(P)
				-- Deliberately an if/else and not `cond and nil or P`: with `and nil`, the
				-- whole expression falls through to P and the case "passes" by accepting
				-- everything. The first version of this test did exactly that and reported
				-- three usable where one was intended.
				if Placement.Axis(P, "y", 2) > 10 then
					return nil
				end

				return P
			end,
			Flags = function() return { walk = true } end,
			Collide = function() return false end
		}

		local _, Mixed = Placement.ValidateCandidates({ At(0), At(40), At(60) }, Partly)
		local Summary = Placement.ReasonCounts(Mixed)

		Assert.Equal( 1, Mixed.usable, "one of three anchors is on ground" )
		Assert.True( Summary:find("no ground under anchor=2") ~= nil, "the tally names the rejected two: " .. Summary )
	end )

	-- The candidate source, tested on its own. Anchors alone left exactly one buildable point
	-- inside the ring on the shipped map and zero mouths placed, so the sweep is what carries
	-- placement - and the property worth asserting is not "it found points" but that it found
	-- them where the band could use them.
	self:RegisterScenario( "placement_samples_the_ring_not_the_anchors", false, function()
		local Placement = Shine.Plugins.hordemode.Placement

		-- A real Vector, because so is every sample the engine hands back: a plain-table base
		-- next to Vector samples would exercise the fallback path, not the shipped one.
		local Base = Vector(0, 0, 0)

		-- The mesh agrees with every request, so each sample lands at its own radius and the
		-- geometry of the sweep can be read straight off the result.
		local Identity = {
			Mesh = function(Point) return Point end,
			Ground = function(Point) return Point end,
			Flags = function() return { walk = true } end,
			Collide = function() return false end
		}

		local Sampled = Placement.SampleRing(Base, 56, 90, Identity)

		Assert.Equal( 192, #Sampled, "8 rings x 24 bearings, none dropped by an agreeing mesh" )

		--- The same sweep, seeded. Both halves matter: the grid has to actually move - a fixed
		--- 6x16 grid handed every wave the same handful of sites, which is what looked from the
		--- chair like "surprisingly in the exact same positions" - and the envelope it moves
		--- inside must not. The jitter is bounded, so no draw can probe past the reach the band
		--- was measured against or inside the sweep's own near floor.
		local DrawA = Placement.SampleRing(Base, 56, 90, Identity, Placement.NewRandom(11))
		local DrawB = Placement.SampleRing(Base, 56, 90, Identity, Placement.NewRandom(12))
		local Replay = Placement.SampleRing(Base, 56, 90, Identity, Placement.NewRandom(11))

		Assert.Equal( #Sampled, #DrawA, "a seeded sweep probes just as many points" )
		Assert.True( Placement.Distance2D(DrawA[1], DrawB[1]) > 1, "and different seeds probe different places" )

		local Reproduced = true

		for Index = 1, #DrawA do
			if Placement.Distance2D(DrawA[Index], Replay[Index]) > 0 then
				Reproduced = false
			end
		end

		Assert.True( Reproduced, "the same seed replays the sweep exactly - a logged seed is a reproducible wave" )

		local JitterNear, JitterFar

		for _, Point in ipairs(DrawA) do
			local Distance = Placement.Distance2D(Point, Base)

			JitterNear = JitterNear and math.min(JitterNear, Distance) or Distance
			JitterFar = JitterFar and math.max(JitterFar, Distance) or Distance
		end

		Assert.True( JitterNear >= 16.5,
			string.format("the jitter cannot pull the sweep onto the base (%.1fm; 20m x 0.85)", JitterNear) )
		Assert.True( JitterFar <= 166,
			string.format("nor push it past the swept envelope (%.1fm; 144m x 1.15)", JitterFar) )

		local Inside, Outside, Distinct, Closest, Furthest = 0, 0, {}, nil, nil

		for _, Point in ipairs(Sampled) do
			local Distance = Placement.Distance2D(Point, Base)

			Closest = Closest and math.min(Closest, Distance) or Distance
			Furthest = Furthest and math.max(Furthest, Distance) or Distance

			if Distance < 56 then
				Inside = Inside + 1
			end

			if Distance > 90 then
				Outside = Outside + 1
			end

			Distinct[string.format("%.1f,%.1f", Placement.Axis(Point, "x", 1), Placement.Axis(Point, "z", 3))] = true
		end

		-- Deliberate, and the reason the sweep exists at all: the band is measured in WALKING
		-- metres, so candidates have to be generated nearer than 56 in a straight line and
		-- further than 90, or a map whose routes bend could never fill the ring.
		Assert.True( Inside > 0, "samples start inside the ring on purpose, nearer than BandMin" )
		Assert.True( Outside > 0, "and reach past it, because a route is longer than the line to it" )

		-- 19.5 and 144.5, not 20 and 144: the sweep's own float arithmetic lands 20 m at
		-- 19.9999998 and 90 x 1.6 at 144.0000002, and an assertion that fails on the last bit
		-- of a mantissa hides whatever real failure it was standing next to.
		Assert.True( Closest >= 19.5, string.format("the sweep does not start on top of the base (%.1fm)", Closest) )
		Assert.True( Furthest > 90 and Furthest <= 144.5,
			string.format("the sweep reaches past the band without wandering off the map (%.1fm)", Furthest) )

		local Count = 0

		for _ in pairs(Distinct) do
			Count = Count + 1
		end

		Assert.Equal( #Sampled, Count, "and no two samples are the same place" )

		-- The failure mode that produced the empty pool: a mesh that answers nothing must yield
		-- no candidates, rather than quietly falling back to raw anchors behind our back.
		Assert.Equal( 0, #Placement.SampleRing(Base, 56, 90, { Mesh = function() return nil end }),
			"a map with no mesh under the ring contributes nothing" )

		-- A throwing engine query is a missing sample, not a failed wave.
		Assert.Equal( 0, #Placement.SampleRing(Base, 56, 90, { Mesh = function() error("no nav mesh loaded") end }),
			"a throwing mesh query yields nothing and does not propagate" )

		Assert.Equal( 0, #Placement.SampleRing(nil, 56, 90, Identity), "no base anchor means no ring to sweep")

		-- Whatever the mesh answers with is the point that gets handed on, including its height:
		-- the surface gate judges that point, so a snap applied before validation would make
		-- every assertion downstream invisible to the real placement.
		local Offset = {
			Mesh = function(Point) return { x = Placement.Axis(Point, "x", 1) + 1, y = 3, z = Placement.Axis(Point, "z", 3) } end,
			Ground = function(Point) return Point end,
			Flags = function() return { walk = true } end,
			Collide = function() return false end
		}

		local Shifted = Placement.SampleRing(Base, 56, 90, Offset)

		Assert.True( #Shifted > 0, "samples survive a mesh that answers with its own point" )
		Assert.Equal( 3, Placement.Axis(Shifted[1], "y", 2), "and the mesh's height is the one kept" )
	end )

	-- The ring on the real map, end to end: measured numbers in the log, and the two bounds a
	-- placed mouth must satisfy. This is the test whose absence let three mouths into rock.
	self:RegisterScenario( "placement_ring_survives_validation_on_a_real_map", false, function()
		local horde = Shine.Plugins.hordemode
		local Placement = horde.Placement
		local Config = horde.HordeConfig.Resolve(Shared.GetMapName())
		local Waves = Config.Waves or {}

		local Chosen, Base, RawCount, BandedCount, Stats = Placement.Collect(Config)

		print(string.format("[TEST] ring placement on %s: %s -> in band=%s chosen=%s base=%s",
			tostring(Shared.GetMapName()), Placement.ReasonCounts(Stats), tostring(BandedCount),
			tostring(#Chosen), tostring(Base ~= nil)))

		Assert.True(Stats.sampled > 0, "the sweep generated candidates to judge on this map")
		Assert.True(Stats.usable > 0, string.format("and the engine accepts at least one as buildable [%s]",
			Placement.ReasonCounts(Stats)))

		if Base then
			Assert.True(#Chosen > 0, string.format(
				"so a wave can place mouths in the %s-%sm ring [%s]",
				tostring(Waves.BandMin), tostring(Waves.BandMax), Placement.ReasonCounts(Stats)))
		end
	end )

	-- The points production actually picks, re-asked of the engine rather than trusted from
	-- the pipeline above: if a candidate survives filtering, the level still agrees at that
	-- moment that it is walkable, buildable, clear of geometry, and standing on its own floor.
	self:RegisterScenario( "every_chosen_mouth_sits_on_buildable_surface", false, function()
		local horde = Shine.Plugins.hordemode
		local Placement = horde.Placement
		local Config = horde.HordeConfig.Resolve(Shared.GetMapName())
		local Hooks = Placement.DefaultHooks()
		local Extents = Placement.Extents()
		local Chosen, Base = Placement.Collect(Config)

		Assert.True( #Chosen > 0, "there is something to check on this map" )

		for Index, Candidate in ipairs(Chosen) do
			local Point = Candidate.point
			local Flags = Hooks.Flags(Point, Extents)

			Assert.True( Flags.walk,
				string.format("mouth %s is on walkable nav mesh at (%.1f, %.1f, %.1f)", tostring(Index),
					Placement.Axis(Point, "x", 1), Placement.Axis(Point, "y", 2), Placement.Axis(Point, "z", 3)) )
			Assert.True( not Flags.nobuild, string.format("mouth %s is not in a no-build zone", tostring(Index)) )
			Assert.False( Hooks.Collide(Point, Extents),
				string.format("mouth %s overlaps the world - it would be buried in geometry", tostring(Index)) )

			-- Idempotence is the cheap proof the snap landed somewhere real: asking the ground
			-- again must return the same point, not a further fall.
			local Again = Hooks.Ground(Point, Extents)

			Assert.NotNil( Again, string.format("mouth %s has ground under it", tostring(Index)) )

			if Again then
				Assert.True( Placement.Distance2D(Again, Point) < 0.5, string.format(
					"mouth %s is not already on its surface (%.2fm from the ground query)",
					tostring(Index), Placement.Distance2D(Again, Point)) )
			end

			print(string.format("[TEST] mouth %s at (%.1f, %.1f, %.1f) %sm of walking from base",
				tostring(Index), Placement.Axis(Point, "x", 1), Placement.Axis(Point, "y", 2),
				Placement.Axis(Point, "z", 3), string.format("%.1f", Candidate.distance or -1)))
		end
	end )

	--- The registry's three-state contract, with the resolver injected. Every one of the field
	--- symptoms came from collapsing these states into a single question: mouths vanishing from
	--- the minimap after a different mouth was killed, status reporting 3/3 and then 1/3 on an
	--- empty map, and teardown calling two player-killed corpses a failure. The engine draws the
	--- distinction itself - `Team:GetNumAliveCommandStructures` (Team.lua:502-510) asks
	--- `GetIsAlive()`, not "does the id still resolve" - so a two-valued answer was always going
	--- to be wrong about one of them.
	self:RegisterScenario( "registry_liveness_is_the_engines_answer", false, function()
		local horde = Shine.Plugins.hordemode
		local R = horde.Registry
		local States = {}
		local Reg = R.New(function(Entry)
			return States[Entry.id] or R.Alive
		end)

		local function Double(Id)
			return {
				GetId = function() return Id end,
				--- Kill is legal exactly once. Re-killing a husk is the dereference that used to
				--- throw inside the tick, so the double reports it loudly instead of failing
				--- somewhere downstream as someone else's assertion.
				Kill = function()
					if States[Id] == R.Dead then
						error("a dead structure was killed again")
					end

					States[Id] = R.Dead
				end,
			}
		end

		Reg:Register(Double(10), R.Kind.Mouth)

		local B = Reg:Register(Double(11), R.Kind.Mouth)
		local C = Reg:Register(Double(12), R.Kind.Mouth)

		Assert.Equal( 3, Reg:CountByKind(R.Kind.Mouth), "three standing mouths are three mouths" )

		States[B] = R.Dead      -- shot; still in the world as a husk
		States[C] = R.Gone      -- the engine has finished with it

		Assert.Equal( 1, Reg:CountByKind(R.Kind.Mouth),
			"a husk is not a mouth - this is the number /horde status kept printing as 1/3" )

		local Visited = 0

		Reg:IterateByKind(R.Kind.Mouth, function()
			Visited = Visited + 1
		end)

		Assert.Equal( 1, Visited,
			"iteration hands out only what is standing; a husk dereferenced is the throw that killed the tick" )

		--- Prune removes only what the engine has fully removed. A husk stays on the books because
		--- the registry is the only record that the thing was OURS: forget it here and teardown
		--- leaves it standing in the map behind a logged PASS.
		Assert.Equal( 1, Reg:PruneDead(), "prune drops the gone one" )
		Assert.Equal( 2, Reg:Count(), "and keeps the husk, which is still ours to clean up" )
		Assert.Equal( 3, #Reg:GetEverIds(), "the history survives both" )

		Reg:Clear()
		Assert.Equal( 0, #Reg:GetEverIds(), "a new round starts with a clean history" )
	end )

	--- The other half of the same playtest, on the real engine: he shot the last mouth and status
	--- still said 1/3, and teardown logged "1 destroyed ... of 1 tracked" for a mouth that was
	--- already dead. A killed structure is NOT gone - it stays in the entity list through its death
	--- sequence, reporting `GetIsAlive() == false`. Doubles cannot say that; only the level can.
	self:RegisterScenario( "a_killed_mouth_is_a_husk_not_a_mouth", false, function()
		local horde = Shine.Plugins.hordemode
		local SavedReg, SavedSpawn = horde.HordeRegistry, horde.HordeSpawner
		local SavedPool = horde.Machine.MouthsPool
		local Reg, Id

		local function Run()
			Reg = horde.Registry.New(horde.Registry.EngineStateOf)
			horde.HordeRegistry = Reg
			horde.HordeSpawner = horde.Spawner.New(Reg, function(Message) print("[TEST] " .. Message) end, false)

			local Anchor = SurfaceAnchors(1)[1]

			Assert.NotNil( Anchor, "a buildable surface to place a mouth on" )

			local Mouth = horde.HordeSpawner:SpawnMouth(Anchor)

			Assert.NotNil( Mouth, "the mouth was created" )

			horde.HordeSpawner:Pump()

			local Registered = Reg:GetAllIds()

			Assert.Equal( 1, #Registered, "and registered" )

			Id = Registered[1]
			horde.Machine.MouthsPool = 1

			Mouth:Kill()

			local State = horde.Registry.EngineStateOf({ id = Id, ref = Shared.GetEntity(Id), kind = "mouth" })

			--- Printed, not asserted: the claim is "not alive", and whether the husk still occupies
			--- an id at this instant is the engine's timing, not our invariant. Both branches are
			--- covered by the deferred teardown check below, which must classify whichever it was.
			print(string.format("[TEST] killed mouth state: %s", tostring(State)))

			Assert.True( State ~= horde.Registry.Alive,
				string.format("a killed mouth stops being alive to the engine (state %s)", tostring(State)) )
			Assert.Equal( 0, Reg:CountByKind("mouth"),
				"and the status count follows the engine rather than the ledger" )

			-- Teardown's obligation is the other direction: whatever the state, nothing of ours may
			-- survive it, and a husk must be classified rather than reported as a failure.
			self:Defer( "husk_cleaned_by_teardown", 2, false, function()
				local Destroyed, Failed, Total, Ids, Gone, Husks = horde.DestroyAll(Reg, nil, nil)

				Assert.Equal( 1, Total, "the husk was still on the books to be accounted for" )
				Assert.Equal( 0, #Failed, "and its teardown reported no failure" )
				Assert.Equal( 1, Gone + Husks, "classified as gone or husk, never skipped" )
				Assert.Equal( 1, #Ids, "its id went to the leak check" )
				Assert.Nil( Shared.GetEntity(Id), "nothing of ours is left standing in the world" )

				print(string.format("[TEST] husk teardown: destroyed=%s gone=%s husks=%s",
					tostring(Destroyed.mouth or 0), tostring(Gone), tostring(Husks)))
			end )
		end

		local Ok, Err = pcall(Run)

		horde.HordeRegistry, horde.HordeSpawner = SavedReg, SavedSpawn
		horde.Machine.MouthsPool = SavedPool

		if not Ok then
			error(Err)
		end
	end )

	--- The playtest itself, headless: two real mouths, a player's bullet in one of them, and
	--- everything the tick does afterwards has to survive it. Before the fix the reveal pass
	--- threw on the corpse (spawner.lua:76), which killed the tick - so the two living mouths
	--- lost their markers when detection expired 1.5 s later and the prune that would have
	--- corrected the status never ran.
	self:RegisterScenario( "killing_a_mouth_keeps_the_tick_and_the_map_healthy", false, function()
		local horde = Shine.Plugins.hordemode
		local SavedReg, SavedSpawn = horde.HordeRegistry, horde.HordeSpawner
		local SavedPool, SavedActive = horde.Machine.MouthsPool, horde.Machine.MouthsActive
		local Reg, Spawn

		local function Run()
			Reg = horde.Registry.New(horde.Registry.EngineStateOf)
			Spawn = horde.Spawner.New(Reg, function(Message) print("[TEST] " .. Message) end, true)

			horde.HordeRegistry, horde.HordeSpawner = Reg, Spawn

			local Anchors = SurfaceAnchors(2)

			Assert.True( #Anchors >= 2, "two buildable surfaces for the paired test" )

			--- Two mouths, both registered by the pump, and their ids. Reused because the claims
			--- below need the same starting world twice: once with a corpse on the books (what
			--- teardown sees) and once after the tick has pruned (what the status line sees).
			local function MakePair()
				local A = Spawn:SpawnMouth(Anchors[1])
				local B = Spawn:SpawnMouth(Anchors[2])

				Assert.NotNil( A, "mouth A created" )
				Assert.NotNil( B, "mouth B created" )

				Spawn:Pump()

				local Pair = Reg:GetAllIds()

				Assert.Equal( 2, #Pair, "both registered by the pump" )

				return Pair
			end

			--- Phase A - teardown's accounting with the corpse still on the books. This is the
			--- line Arian's run logged as "teardown FAILED for 2 entries": a mouth the player
			--- killed is not a failure to destroy, it is the outcome we asked for.
			local Ids = MakePair()

			horde.Machine.MouthsPool = 2

			DestroyEntity(Shared.GetEntity(Ids[1]))

			--- The reveal pass, corpse included in the registry. Before the fix this threw at
			--- spawner.lua:76 and took the whole world tick with it, so the mouth he did NOT shoot
			--- lost its marker 1.5 s later and the status kept saying 2/2.
			local OkReveal, Revealed = pcall(function()
				return Spawn:RefreshReveal()
			end)

			Assert.True( OkReveal, "re-asserting the reveal must not throw on a mouth that is gone: " ..
				tostring(Revealed) )
			Assert.Equal( 1, Revealed, "and the surviving mouth keeps its marker - the minimap claim" )

			local Destroyed, Failed, Total, IdsOut, Gone = horde.DestroyAll(Reg, nil, nil)

			Assert.Equal( 2, Total, "both were on the books to be accounted for" )
			Assert.Equal( 1, Gone, "the killed one is reported as already gone" )
			Assert.Equal( 0, #Failed, "not as a failure, on a round that went right" )
			Assert.Equal( 1, Destroyed.mouth or 0, "the survivor was destroyed by us" )
			Assert.Nil( Shared.GetEntity(Ids[2]), "and the world agrees it is gone" )
			Assert.Equal( 2, #IdsOut, "both ids handed to the leak check" )
			Assert.Equal( 2, #Reg:GetEverIds(), "the history keeps the corpse: we did make it" )

			--- Phase B - the tick, which is what holds the markers up through a live round.
			local Pair = MakePair()

			horde.Machine.MouthsPool = 2

			DestroyEntity(Shared.GetEntity(Pair[1]))

			local OkTick, TickErr = pcall(function()
				horde:HordeTick()
			end)

			Assert.True( OkTick, "the world tick survives it: " .. tostring(TickErr) )
			Assert.Equal( 1, Reg:CountByKind("mouth"), "the tick pruned the corpse it was told about" )
			Assert.Equal( 1, horde.Machine.MouthsActive, "and refreshed the count the status reads" )

			local Line = horde:BuildStatusLine(horde.Triggers.TakeSnapshot(nil), horde.Machine,
				horde.HordeConfig.Resolve(Shared.GetMapName()), Shared.GetTime(), Reg, horde.HordeTakeover)

			Assert.True( Line:find("mouths=1/2") ~= nil, "status says one of two is left, not 2/2: " .. Line )

			horde.DestroyAll(Reg, nil, nil)

			Assert.Equal( 0, Reg:Count(), "and the scenario leaves nothing behind" )
			Assert.Nil( Shared.GetEntity(Pair[2]), "the second survivor is out of the world too" )
		end

		-- Restore before anything can fail: a scenario that leaves the plugin pointing at its
		-- private registry would make every later teardown check someone else's bookkeeping.
		local Ok, Err = pcall(Run)

		horde.HordeRegistry, horde.HordeSpawner = SavedReg, SavedSpawn
		horde.Machine.MouthsPool, horde.Machine.MouthsActive = SavedPool, SavedActive

		if not Ok then
			error(Err)
		end
	end )

	--- The order of the handback, which is the whole of the "marines won" bug: releasing the
	--- win check into a Started round with no aliens leaves vanilla exactly one end to reach.
	--- Gamerules is faked here - a real ResetGame mid-suite would take the world out from under
	--- every later scenario, and the claim under test is the ORDER, not the engine's arithmetic.
	self:RegisterScenario( "teardown_resets_the_world_before_releasing_the_win_check", false, function()
		local horde = Shine.Plugins.hordemode
		local Order = {}

		local function FakeRules()
			return {
				preventGameEnd = true,
				gameState = kGameState.Started,
				ResetGame = function(Self)
					Order[#Order + 1] = "reset"
					Self.gameState = kGameState.NotStarted
				end,
				JoinTeam = function(Self, Player, Team, Force)
					Order[#Order + 1] = "spectate"

					return true
				end,
				SetPreventGameEnd = function(Self, State)
					Order[#Order + 1] = "switch:" .. tostring(State)
					Self.preventGameEnd = State
				end,
			}
		end

		--- Every piece of shared state is swapped for a private copy and handed back BEFORE any
		--- assertion. Teardown reaches into the plugin's registry, spawner and machine, and two
		--- earlier scenarios still have deferred checks outstanding at this point in the run.
		--- That is not hypothetical: the first version of this scenario destroyed another
		--- scenario's live mouth and zeroed its wave counters, and both failures read as bugs in
		--- the code under test rather than as interference. See restore-before-you-assert.
		local SavedRules, SavedStarted = GetGamerules, horde.HordeRoundStarted
		local SavedMachine, SavedReg, SavedSpawn = horde.Machine, horde.HordeRegistry, horde.HordeSpawner
		local Rules = FakeRules()

		horde.Machine = horde.StateMachine.New(Shared.GetTime(), function() end)
		horde.HordeRegistry = horde.Registry.New(horde.Registry.EngineStateOf)
		horde.HordeSpawner = horde.Spawner.New(horde.HordeRegistry, function() end, false)

		horde.HordeRoundStarted = true
		GetGamerules = function() return Rules end

		horde.Machine:Stop("test handback", Shared.GetTime())

		--- The claim here is the CALL ORDER, not who gets moved - `stop_moves_humans_to_spectator`
		--- owns that. So the move is stubbed to record itself rather than observed through real
		--- player entities: on a headless server an entity created this tick is not guaranteed to
		--- be enumerable in it, and an ordering test whose premise depends on engine timing would
		--- fail for reasons that have nothing to do with the code under test.
		local SavedMove = horde.MovePlayersToSpectator

		horde.MovePlayersToSpectator = function(Self)
			Order[#Order + 1] = "spectate"

			return 1, 0, nil
		end

		local Machine = horde.Machine

		local Ok, Err = pcall(function()
			horde:Teardown(Shared.GetTime())
		end)

		horde.MovePlayersToSpectator = SavedMove
		GetGamerules = SavedRules
		horde.HordeRoundStarted = SavedStarted
		horde.Machine, horde.HordeRegistry, horde.HordeSpawner = SavedMachine, SavedReg, SavedSpawn

		local SpectateAt, SwitchAt

		for Index, Item in ipairs(Order) do
			if Item == "spectate" and not SpectateAt then
				SpectateAt = Index
			end

			if Item:find("^switch") then
				SwitchAt = Index
			end
		end

		Assert.True( Ok, "teardown survived the handback: " .. tostring(Err) )
		Assert.Equal( "reset", Order[1], "the world goes back to vanilla first" )
		Assert.NotNil( SpectateAt, "players were moved while we still held the win check" )
		Assert.True( SpectateAt < SwitchAt,
			string.format("and before it came off (spectate at %s, switch at %s)",
				tostring(SpectateAt), tostring(SwitchAt)) )
		Assert.Equal( "switch:nil", Order[#Order], "the switch is the last thing handed back" )
		Assert.Equal( kGameState.NotStarted, Rules.gameState, "so the switch comes off on a round that cannot end" )
		Assert.True( Machine:Is(horde.Phase.Inactive), "and the machine is idle again" )

		--- The gate on the other side: a horde that never took a round over must not reset a game
		--- it did not start - `/horde stop` in a lobby is not a server-wide reset.
		local Untouched, UntouchedOrder = FakeRules(), {}

		Untouched.ResetGame = function()
			UntouchedOrder[#UntouchedOrder + 1] = "reset"
		end

		Untouched.SetPreventGameEnd = function()
			UntouchedOrder[#UntouchedOrder + 1] = "switch"
		end

		horde.HordeRoundStarted = false
		GetGamerules = function() return Untouched end

		local Handed, Reason = horde:HandBackWorld()

		GetGamerules = SavedRules
		horde.HordeRoundStarted = SavedStarted

		Assert.False( Handed, "nothing to hand back" )
		Assert.Equal( 0, #UntouchedOrder, "no ResetGame and no switch on a round we never owned" )
		Assert.Equal( kGameState.Started, Untouched.gameState, "a live round we never owned is left alone" )
		Assert.True( Reason:find("never took the round over") ~= nil, "saying why: " .. tostring(Reason) )
	end )

	--- Who gets moved, with the roster and the player list injected: the claim is a rule about
	--- humans versus bots versus the already-spectating, and a headless server cannot be asked to
	--- supply all three.
	self:RegisterScenario( "stop_moves_humans_to_spectator", false, function()
		local horde = Shine.Plugins.hordemode
		local Calls = {}

		local function FakePlayer(Id, Team)
			return {
				GetId = function() return Id end,
				GetTeamNumber = function() return Team end,
			}
		end

		local BotPlayer = FakePlayer(3, kTeam1Index)
		local Roster = { { GetPlayer = function() return BotPlayer end } }
		local Players = {
			FakePlayer(1, kTeam1Index),        -- human marine
			FakePlayer(2, kTeam2Index),        -- human alien
			BotPlayer,                         -- a bot, which vanilla owns
			FakePlayer(4, kSpectatorIndex),    -- already out of the round
			FakePlayer(5, kTeam1Index),        -- a human whose move will be refused
		}

		local Rules = {
			JoinTeam = function(Self, Player, Team, Force)
				if Player:GetId() == 5 then
					error("team logic threw mid-reset")
				end

				Calls[#Calls + 1] = { id = Player:GetId(), team = Team, force = Force }

				return true
			end,
		}

		local Moved, Refused = horde:MovePlayersToSpectator(Rules, Players, Roster)

		Assert.Equal( 2, Moved, "both humans went to spectator" )
		Assert.Equal( 1, Refused, "and the one that threw is reported, not swallowed" )
		Assert.Equal( 2, #Calls, "the bot and the spectator were never asked" )
		Assert.Equal( kSpectatorIndex, Calls[1].team, "to the spectator team" )
		Assert.Equal( kSpectatorIndex, Calls[2].team, "both of them" )
		Assert.True( Calls[1].force == true and Calls[2].force == true,
			"forced - the round is over whether or not the team logic would have let them choose" )
		Assert.Equal( 1, Calls[1].id, "marine first" )
		Assert.Equal( 2, Calls[2].id, "then alien - neither is a bot" )

		local Nothing = horde:MovePlayersToSpectator({}, {}, {})

		Assert.Equal( 0, Nothing, "no gamerules to move anyone with is zero, not an error" )
	end )

	--- The real handback, run alone by `./dev/test.sh --handback`. The faked-order scenario above
	--- can prove WHICH call happens first; it cannot prove that vanilla, left holding the switch
	--- again, does not end the round. That needs the live gamerules object, and a live ResetGame
	--- anywhere in the normal run would invalidate every deferred check still outstanding - so
	--- this probe is the only scenario in its run.
	---
	--- It asserts the three things the playtest said were broken: the round comes back to a state
	--- where no winner can be declared, the mouths really leave the world, and the server's own
	--- bot configuration returns.
	self:RegisterScenario( "handback_returns_the_world_to_vanilla", false, function()
		local horde = Shine.Plugins.hordemode
		local gamerules = GetGamerules()

		Assert.NotNil( gamerules, "the world is up" )

		local Controller = gamerules.botTeamController

		Assert.NotNil( Controller, "and it has a bot controller to hand back" )

		--- A server that fills with bots, which is what Arian's does. Left at 0 the restore
		--- assertion below would pass without proving anything, so the precondition is created
		--- deliberately rather than read from a config that happens to be empty.
		local BotCap, BotLock = 4, Controller.updateLock or 0

		Controller.MaxBots = BotCap

		local Ok, Err = horde:ResetWorldForHorde()

		Assert.True( Ok, "the horde took the world over: " .. tostring(Err) )
		Assert.True( horde.HordeRoundStarted, "and recorded that it owns the round" )
		Assert.True( horde.HordeTakeover:IsEngaged(), "the takeover is what holds the vanilla fill" )
		Assert.Equal( 0, Controller.MaxBots, "capped to zero for the duration" )

		horde.Machine:Start(Shared.GetTime())

		local Placed = horde:BeginWave(horde.HordeConfig.Resolve(Shared.GetMapName()))

		Assert.True( Placed >= 1, "a wave placed mouths to tear down" )

		--- The dangerous state, created on purpose. `CheckGameEnd` only exists at Started, and an
		--- emptied Started round has exactly one end vanilla can reach: the aliens lose, the
		--- marines are declared winners, the map rotates. This is the frame /horde stop used to
		--- hand the switch back on.
		gamerules:SetGameState(kGameState.Started)

		horde:HordeTick()

		local Ids = horde.HordeRegistry:GetEverIds()

		Assert.True( #Ids >= 1, "the registry knows what it made: " .. tostring(#Ids) )

		horde.Machine:Stop("handback probe", Shared.GetTime())
		horde:Teardown(Shared.GetTime())

		self:Defer( "handback_settles", 4, false, function()
			local Problems = {}
			local State = gamerules:GetGameState()

			--- Not "this frame reads nicely" but "four seconds of vanilla running its own update
			--- loop with the switch back produced no end". A win that fires on the next tick is
			--- exactly what the playtest saw.
			if State >= kGameState.Started then
				Problems[#Problems + 1] = string.format("the round never came back below Started (state %s)",
					tostring(State))
			end

			if gamerules.timeGameEnded ~= nil then
				Problems[#Problems + 1] = "vanilla recorded a game end across the handback"
			end

			if gamerules.preventGameEnd ~= nil then
				Problems[#Problems + 1] = "suppression outlived the horde - this server would now never award a win"
			end

			if not horde.Machine:Is(horde.Phase.Inactive) then
				Problems[#Problems + 1] = "the machine is still " .. horde.Machine:GetState()
			end

			for _, Id in ipairs(Ids) do
				if Shared.GetEntity(Id) ~= nil then
					Problems[#Problems + 1] = "mouth " .. tostring(Id) .. " survived the handback"
				end
			end

			if Controller.MaxBots ~= BotCap then
				Problems[#Problems + 1] = string.format("bot cap not restored (%s, was %s) - this is why no bot came back",
					tostring(Controller.MaxBots), tostring(BotCap))
			end

			if (Controller.updateLock or 0) ~= BotLock then
				Problems[#Problems + 1] = string.format("update lock not returned to %s (now %s) - someone else's fill is now stuck",
					tostring(BotLock), tostring(Controller.updateLock))
			end

			print(string.format("[TEST] handback settled: state=%s maxBots=%s lock=%s ids=%s suppression=%s",
				tostring(State), tostring(Controller.MaxBots), tostring(Controller.updateLock),
				tostring(#Ids), tostring(gamerules.preventGameEnd)))

			if #Problems > 0 then
				error( { Detail = "handback: " .. table.concat(Problems, "; ") } )
			end
		end )
	end )

	self:RegisterScenario( "negative_control", true, function()
		Assert.True( false, "deliberate failure — proves FAIL detection works" )
	end )
end

Plugin:InitialiseScenarios()

return Plugin
