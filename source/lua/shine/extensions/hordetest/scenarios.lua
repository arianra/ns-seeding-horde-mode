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
		Assert.NotNil( horde.Phase.WaveActive, "phase vocabulary is shared, not server-only" )
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

	self:RegisterScenario( "negative_control", true, function()
		Assert.True( false, "deliberate failure — proves FAIL detection works" )
	end )
end

Plugin:InitialiseScenarios()

return Plugin
