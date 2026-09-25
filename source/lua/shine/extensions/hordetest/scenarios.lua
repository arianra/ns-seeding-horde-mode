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

		Assert.True( Config.Sanitize(Copy), "dirty config reports that it was corrected" )
		Assert.Equal( 0, Copy.Start.Cooldown, "negative cooldown clamps to zero" )
		Assert.Equal( 12, Copy.Waves.PoolSize, "absurd pool size clamps to the ceiling" )
		Assert.True( Copy.Waves.BandMin < Copy.Waves.BandMax, "inverted band is repaired, not clamped flat" )
		Assert.Equal( "table", type(Copy.Waves.Health), "clobbered curve is replaced by a curve" )
		Assert.True( Copy.Waves.Health.Enabled == false, "replacement curve is flat" )
		Assert.True( Copy.Difficulty.Accuracy.Bezier[1] <= 1, "x control point kept inside [0,1] so difficulty stays monotonic" )
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
				-- Measured with the module's own 2D distance, not the stored field: the ring
				-- is the rule, and it has to hold against real map geometry, not injected.
				local Distance = horde.Placement.Distance2D(Candidate.point, Base)
				Assert.True( Distance >= BandMin,
					string.format("a chosen mouth sits %sm from base, inside the %sm exclusion ring",
						tostring(Distance), tostring(BandMin)) )

				Nearest = Nearest and math.min(Nearest, Distance) or Distance

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

		local Reg = horde.Registry.New()
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
		local Reg = horde.Registry.New()
		local Spawn = horde.Spawner.New(Reg, function(Message) print("[TEST] " .. Message) end)

		local Anchor

		for _, Ent in ientitylist(Shared.GetEntitiesWithClassname("Location")) do
			Anchor = Ent:GetOrigin()
			break
		end

		Assert.NotNil( Anchor, "the live map has a Location to place a mouth at" )

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
		local Reg = horde.Registry.New()
		local Spawn = horde.Spawner.New(Reg, function(Message) print("[TEST] " .. Message) end)

		local Anchors = {}

		for _, Ent in ientitylist(Shared.GetEntitiesWithClassname("Location")) do
			Anchors[#Anchors + 1] = Ent:GetOrigin()

			if #Anchors >= 2 then
				break
			end
		end

		Assert.True( #Anchors >= 2, "two anchors available for the created set" )

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

		horde.HordeRegistry = horde.Registry.New()
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

	self:RegisterScenario( "negative_control", true, function()
		Assert.True( false, "deliberate failure — proves FAIL detection works" )
	end )
end

Plugin:InitialiseScenarios()

return Plugin
