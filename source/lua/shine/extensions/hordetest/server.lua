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

Shine.LoadPluginFile( PluginName, "scenarios.lua", Plugin )

function Plugin:Initialise()
	self.State = { Ready = false, Settled = 0, Done = false, Pass = 0, Fail = 0, ExpectedFail = 0 }

	self:CreateTimer( "HordeTestRunner", 1, -1, function()
		self:Tick()
	end )

	self.Enabled = true

	return true
end

function Plugin:Tick()
	local State = self.State

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
		local Detail

		if not Ok then
			if type( Err ) == "table" then
				Detail = tostring( Err.Detail or Err.message or "assertion failed" )
			else
				Detail = tostring( Err )
			end
		end

		self:Report( Scenario.Name, not Ok, Detail, Scenario.Expected )
	end

	print( string.format( "[TEST] ALL-DONE pass=%s fail=%s expected_fail=%s",
		State.Pass, State.Fail, State.ExpectedFail ) )

	self:DestroyTimer( "HordeTestRunner" )
end

return Plugin
