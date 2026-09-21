--[[ Horde TEST harness — shared: scenario registry + assert helpers.

     Scenarios are registered by scenarios.lua (loaded from server.lua) and run
     by the server runner after world-ready + settle. Assertions signal by raising
     a table with a Detail field, which the runner turns into
     '[TEST] <name> FAIL <detail>'.

     A scenario flagged Expected = true is a NEGATIVE CONTROL: it must fail. If it
     passes, the harness is broken and the runner reports it as a real FAIL, so
     failure detection is proven on every run rather than only when someone flips
     a flag. ]]

local Shine = Shine
local Plugin = Shine.Plugin( ... )

Plugin.Version = "0.1"
Plugin.PrintName = "Horde Test Harness"

Plugin.Scenarios = {}

--[[
  Name     scenario label printed to the log
  Expected true => this scenario is required to fail (negative control)
  Func     body; raises via the Assert helpers below
]]
function Plugin:RegisterScenario( Name, Expected, Func )
	table.insert( self.Scenarios, { Name = Name, Expected = Expected, Func = Func } )
end

local function fail( Detail )
	error( { Detail = Detail, IsAssert = true } )
end

local Assert = {}

function Assert.True( Value, What )
	if not Value then
		fail( What or "expected truthy, got " .. tostring( Value ) )
	end
end

function Assert.Equal( Got, Want, What )
	if Got ~= Want then
		fail( string.format( "%s: expected [%s], got [%s]", What or "value", tostring( Want ), tostring( Got ) ) )
	end
end

function Assert.NotNil( Value, What )
	if Value == nil then
		fail( ( What or "value" ) .. " is nil" )
	end
end

-- Entity lifecycle: death/removal is observable as Shared.GetEntity(id) -> nil
-- (verified in spike tby; do not trust entity references to go stale on their own).
function Assert.Alive( EntityID, What )
	if not Shared.GetEntity( EntityID ) then
		fail( ( What or "entity" ) .. " #" .. tostring( EntityID ) .. " is gone, expected alive" )
	end
end

function Assert.Gone( EntityID, What )
	if Shared.GetEntity( EntityID ) then
		fail( ( What or "entity" ) .. " #" .. tostring( EntityID ) .. " still exists, expected gone" )
	end
end

-- Assert.NoErrors(ScenarioCount, Baseline) is intentionally absent: a global
-- "no lua errors since boot" check needs a hook we have not verified, so it is a
-- spike, not an assertion we pretend works.

Plugin.Assert = Assert

return Plugin
