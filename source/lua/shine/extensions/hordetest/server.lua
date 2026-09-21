--[[ Horde TEST harness — server runner (i0d). Executes registered scenarios
     sequentially after world-ready + settle delay; logs
     [TEST] <name> PASS|FAIL <detail>; final [TEST] ALL-DONE pass=N fail=M
     for dev/test.sh to parse.

     i0c seam (this file today): no scenarios exist yet, so arm a poll that waits
     for world init, holds a settle window, then reports an empty suite. That gives
     dev/test.sh a real end-of-run signal to verify against. i0d replaces the body
     with the scenario registry + assert helpers and keeps this signal as its last
     line. ]]
local Shine = Shine
local Plugin = ...

local SETTLE_TICKS = 10

function Plugin:Initialise()
	-- Never touch game APIs here: GetGamerules() is nil before world init and
	-- calling into it crashes Gamerules_Global (spike zpw). Poll instead.
	self.ReadyTicks = 0
	self:CreateTimer( "HordeTestSuiteSignal", 1, -1, function()
		if not GetGamerules() then return end

		self.ReadyTicks = self.ReadyTicks + 1
		if self.ReadyTicks < SETTLE_TICKS then return end

		print( "[TEST] ALL-DONE pass=0 fail=0 (no scenarios registered — framework lands in i0d)" )
		self:DestroyTimer( "HordeTestSuiteSignal" )
	end )

	self.Enabled = true
	return true
end

return Plugin
