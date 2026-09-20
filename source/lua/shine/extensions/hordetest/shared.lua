--[[ Horde TEST harness — shared. Scenario registry + assert helpers, used by
     server runner. Headless integration testing for hordemode (no human
     needed). Enabled ONLY in dev/horde-test-cfg. STUB (i0a); framework i0d. ]]
local Shine = Shine
local Plugin = Shine.Plugin( ... )
Plugin.Version = "0.1"
Plugin.PrintName = "Horde Test Harness"
return Plugin
