--[[ Horde TEST harness — server runner (i0d). Executes registered scenarios
     sequentially after world-ready + settle delay; logs
     [TEST] <name> PASS|FAIL <detail>; final [TEST] ALL-DONE pass=N fail=M
     for dev/test.sh to parse. STUB (i0a). ]]
local Shine = Shine
local Plugin = ...

function Plugin:Initialise()
	self.Enabled = true
	return true
end

return Plugin
