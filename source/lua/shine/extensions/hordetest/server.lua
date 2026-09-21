--[[ Horde TEST harness — server runner.

     Waits for world init, holds a settle window, then runs every registered
     scenario in registration order and reports:

       [TEST] <name> PASS
       [TEST] <name> FAIL <detail>
       [TEST] ALL-DONE pass=N fail=M expected_fail=K

     dev/test.sh polls for the ALL-DONE line and exits nonzero when fail > 0.

     Never call game APIs from Initialise: GetGamerules() is nil before the world
     exists and touching it crashes Gamerules_Global (spike zpw). Hence the poll. ]]

local Shine = Shine
local Plugin = ...
local PluginName = Plugin:GetName()

local SETTLE_SECONDS = 10

-- The suite spawns bots, takes the commander chair, caps and locks the vanilla bot
-- controller and destroys entities. That must never happen on a server people are
-- playing on, so it is opt-in via HordeTest.json (default off) rather than implied
-- by ActiveExtensions alone.
Plugin.HasConfig = true
Plugin.ConfigName = "HordeTest.json"
Plugin.DefaultConfig = { RunSuite = false }

Shine.LoadPluginFile( PluginName, "scenarios.lua", Plugin )

function Plugin:Initialise()
	self.State = { Ready = false, Settled = 0, Done = false, Waiting = false, Finished = false,
		Pass = 0, Fail = 0, ExpectedFail = 0, Pending = {} }

	-- Hold the handle. Plugin timers live in a weak-valued table
	-- (base_plugin/timers.lua:25), and a repeating timer whose returned object is
	-- discarded can be collected mid-run: this runner stopped firing ~10 ticks into
	-- its pending queue with nothing in the log. Keeping a strong reference is both
	-- the fix and the assumption the engine's own periodic timers rely on.
	self.RunnerTimer = self:CreateTimer( "HordeTestRunner", 1, -1, function()
		self:Tick()
	end )

	self.Enabled = true

	return true
end

function Plugin:Tick()
	local State = self.State

	-- Checked here rather than in Initialise so it cannot depend on config load order.
	if not State.GateChecked then
		State.GateChecked = true

		if not self.Config or self.Config.RunSuite ~= true then
			print("[TEST] suite not authorised for this config (RunSuite=false) - hordetest idling")
			self:DestroyTimer("HordeTestRunner")
			return
		end
	end

	if State.Waiting then
		self:TickPending()
		return
	end

	if State.Done or not GetGamerules() then
		return
	end

	if not State.Ready then
		State.Ready = true
		print( string.format( "[TEST] world ready, settling %ss", SETTLE_SECONDS ) )
	end

	State.Settled = State.Settled + 1

	if State.Settled < SETTLE_SECONDS then
		return
	end

	State.Done = true
	self:RunScenarios()
end

function Plugin:Report( Name, Failed, Detail, Expected )
	local State = self.State

	if Failed then
		if Expected then
			State.ExpectedFail = State.ExpectedFail + 1
			print( string.format( "[TEST] %s FAIL %s (expected: negative control)", Name, Detail ) )
		else
			State.Fail = State.Fail + 1
			print( string.format( "[TEST] %s FAIL %s", Name, Detail ) )
		end
	elseif Expected then
		-- A negative control that passes means the harness cannot see failures.
		State.Fail = State.Fail + 1
		print( string.format( "[TEST] %s FAIL negative control passed — asserts are not firing", Name ) )
	else
		State.Pass = State.Pass + 1
		print( string.format( "[TEST] %s PASS", Name ) )
	end
end

function Plugin:RunScenarios()
	local State = self.State

	for Index = 1, #self.Scenarios do
		local Scenario = self.Scenarios[Index]
		local Ok, Err = pcall( Scenario.Func )
		self:Report( Scenario.Name, not Ok, self:DetailOf( Err ), Scenario.Expected )
	end

	-- A scenario may defer checks (bot behaviour takes frames). Adopt whatever it
	-- queued, then only report ALL-DONE once every deferred item has landed —
	-- otherwise test.sh reads an incomplete run as a passing one.
	self:AdoptDeferred()

	if #State.Pending == 0 then
		self:Finish()
		return
	end

	print( string.format( "[TEST] %s deferred check(s) pending", #State.Pending ) )
	State.Waiting = true
end

function Plugin:DetailOf( Err )
	if type( Err ) == "table" then
		return tostring( Err.Detail or Err.message or "assertion failed" )
	end

	return tostring( Err )
end

--- Move queued defers into the live pending list. Called from RunScenarios AND from
--- every tick: a deferred check that schedules another deferred check (the i3c
--- engage→teardown chain does exactly that) was previously never seen, so ALL-DONE
--- never fired and the run hung until test.sh timed out instead of reporting.
function Plugin:AdoptDeferred()
	local Deferred = self.Deferred

	if type(Deferred) ~= "table" then
		return
	end

	local Pending = self.State and self.State.Pending

	if not Pending then
		return
	end

	for Index = 1, #Deferred do
		Pending[#Pending + 1] = Deferred[Index]
	end

	self.Deferred = {}
end

function Plugin:TickPending()
	local State = self.State
	local now = Shared.GetTime()
	local remaining = 0

	self:AdoptDeferred()

	for Index = #State.Pending, 1, -1 do
		local Item = State.Pending[Index]

		if now >= Item.At then
			table.remove( State.Pending, Index )
			local Ok, Err = pcall( Item.Func )
			self:Report( Item.Name, not Ok, self:DetailOf( Err ), Item.Expected )
		else
			remaining = remaining + 1
		end
	end

	-- #Pending, not just `remaining`: an item appended by a check we just ran is
	-- outside the loop we already bounded, and must hold ALL-DONE open.
	if remaining == 0 and #State.Pending == 0 then
		self:Finish()
	end
end

function Plugin:Finish()
	local State = self.State

	if State.Finished then
		return
	end

	State.Finished = true
	State.Waiting = false

	print( string.format( "[TEST] ALL-DONE pass=%s fail=%s expected_fail=%s",
		State.Pass, State.Fail, State.ExpectedFail ) )

	if self:TimerExists( "HordeTestRunner" ) then
		self:DestroyTimer( "HordeTestRunner" )
	end

	self.RunnerTimer = nil
end

return Plugin
