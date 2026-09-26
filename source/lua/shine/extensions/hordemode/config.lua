--[[ Horde Mode — config module (i1b).

     Declares Plugin.DefaultConfig (Shine type-checks the loaded file against it),
     sanitises the values we depend on, resolves per-map overrides, and evaluates the
     bezier curves that RD4 put in charge of every scaled quantity.

     Naming matters: `Plugin.Config` is Shine's own slot for the effective config
     table (core/shared/base_plugin/config.lua:43), so this module attaches as
     Plugin.HordeConfig and reads Plugin.Config as data.

     Requires Plugin.HasConfig (set in server.lua): Shine skips LoadConfig entirely without
     it, so neither the JSON nor PreValidateConfig would ever run.

     Uses only verified Shine surface: DefaultConfig plus the PreValidateConfig hook
     (:292), which may mutate the loaded table and returns "I changed something" —
     that return is also what raises Shine's admin warning (:296-309). A bad value
     therefore falls back AND tells the operator. Shine's Validator rule objects are
     not used: their internal contract is not something to guess at.

     RD8 (accepted 2026-09-21): WarmUp grants every tech, so there is no upgrade
     ladder in this schema — progression is cost and time only.

     PLACEHOLDER POLICY: every number below is untuned until Arian's balance session
     (RD3). Curves ship disabled, so an untuned curve can never silently change
     behaviour from vanilla. See dev/REVIEW-CHECKLIST.md. ]]

local Shine = Shine
local Plugin = ...

local Config = {}

local CURVE_KEYS = {
	{ Owner = "Waves", Key = "Composition" },
	{ Owner = "Waves", Key = "Health" },
	{ Owner = "Waves", Key = "Armor" },
	{ Owner = "Waves", Key = "Damage" },
	{ Owner = "Waves", Key = "MouthHealth" },
	{ Owner = "Economy", Key = "PayoutPerPlayer" },
	{ Owner = "Difficulty", Key = "Accuracy" },
	{ Owner = "Difficulty", Key = "Aggro" },
}

local function IsNumber(Value)
	return type(Value) == "number" and Value == Value
end

local function Clamp(Value, Low, High)
	if Value < Low then return Low end
	if Value > High then return High end
	return Value
end

local function RoundToInteger(Value)
	return math.floor(Value + 0.5)
end

-- Cubic bezier axis with implicit endpoints 0 and 1.
local function BezierAxis(First, Second, T)
	local U = 1 - T
	return 3 * U * U * T * First + 3 * U * T * T * Second + T * T * T
end

-- PLACEHOLDER: untuned, placeholder 2026-09-21. Endpoints are shapes, not values.
local function NewCurve(Start, End)
	return {
		Enabled = false,
		Start = Start,
		End = End,
		Bezier = { 0.25, 0.1, 0.25, 1 },
	}
end

Plugin.DefaultConfig = {
	Start = {
		-- 0, not 60: the only way a horde can end today is an explicit /horde stop, and a
		-- minute of lockout after doing exactly what the mode tells you to do is not a
		-- cooldown, it is friction nobody asked for. The knob stays (validated below) and
		-- gets a real default when loss triggers exist (i8a) - that is the case Q12's
		-- cooldown was written for: preventing instant re-start after a run ended badly.
		Cooldown = 0,
		MinPlayers = 1,          -- real humans only; bot clients never count (verified, i0f)
	},
	Intermission = {
		Seconds = 60,
		SkipCost = 0,            -- Q17 paid skip; 0 disables the charge
	},
	Waves = {
		PoolSize = 6,            -- Q28 pool, decision allows 5-8
		ActivePerWave = 3,
		BandMin = 56,            -- spike tby: summit's reachable near-base band is 56-80m
		BandMax = 90,            -- the pre-spike 20m guess selects nothing on vanilla maps
		Composition = NewCurve(4, 24),
		Health = NewCurve(1, 3),
		Armor = NewCurve(0, 2),
		Damage = NewCurve(1, 2),
		MouthHealth = NewCurve(1000, 4000),   -- Q29: wave-1 mouths near-indestructible
	},
	Economy = {
		WaveClearPayout = 10,
		PayoutPerPlayer = NewCurve(10, 2),    -- Q24: payout per head shrinks as players join
		StartingResources = 1000,
	},
	Difficulty = {
		Accuracy = NewCurve(0.1, 0.9),       -- RD2 -> PlayerBot.aimAbility, read live by BotAim
		Aggro = NewCurve(0.1, 0.9),          -- RD2 -> PlayerBot.aggroAbility
	},
	Teardown = {
		AssertRegistryEmpty = true,          -- RD6 gate
		LogEntityDelta = true,               -- RD6: reported, never asserted
	},
	Debug = {
		-- Dev aid, off by default. A marine cannot see a mouth that is in a room nobody
		-- visited, which makes "is the placement sane?" unanswerable from the chair. When
		-- on, each mouth is marked detected, so the ENGINE creates its vanilla SensorBlip
		-- for it: a through-wall marker on every marine screen and an icon on the minimap
		-- (SensorBlip.lua:32-49, Marine_Client.lua:42-100 - the occlusion trace there is
		-- commented out, which is what makes it visible through rock). We create no entity
		-- and fake nothing, and the blip dies with the mouth (DetectableMixin.lua:117-126).
		RevealMouths = false,
	},
	Maps = {},
}

Config.BandFloor = 40
Config.BandCeiling = 400
Config.NewCurve = NewCurve

function Config.SanitizeCurve(CurveTable)
	local Changed = false

	local function FixNumber(Key, Low, High)
		local Current = CurveTable[Key]

		if not IsNumber(Current) then
			CurveTable[Key] = Low
			return true
		end

		local Fixed = Clamp(Current, Low, High)
		CurveTable[Key] = Fixed

		return Fixed ~= Current
	end

	if FixNumber("Start", 0, 100000) then Changed = true end
	if FixNumber("End", 0, 100000) then Changed = true end

	if type(CurveTable.Bezier) ~= "table" or #CurveTable.Bezier ~= 4 then
		CurveTable.Bezier = { 0.25, 0.1, 0.25, 1 }
		return true
	end

	-- x controls stay inside [0,1] or the easing stops being monotonic, which would
	-- let difficulty fall as waves rise. y controls may overshoot, so they get a
	-- wider bound.
	for Index, High in ipairs({ 1, 4, 1, 4 }) do
		local Control = CurveTable.Bezier[Index]

		if not IsNumber(Control) then
			Control = 0
		end

		local Fixed = Clamp(Control, 0, High)

		if Fixed ~= CurveTable.Bezier[Index] then
			CurveTable.Bezier[Index] = Fixed
			Changed = true
		end
	end

	return Changed
end

--- Clamp/correct a loaded config in place. Returns true when anything changed.
function Config.Sanitize(In)
	local Changed = false

	local function Section(OwnerName, Key, Low, High, AsInteger)
		local Owner = In and In[OwnerName]

		if type(Owner) ~= "table" or not IsNumber(Owner[Key]) then
			if type(Owner) == "table" then
				Owner[Key] = Low
				Changed = true
			end
			return
		end

		local Fixed = Clamp(Owner[Key], Low, High)

		if AsInteger then
			Fixed = RoundToInteger(Fixed)
		end

		if Fixed ~= Owner[Key] then
			Owner[Key] = Fixed
			Changed = true
		end
	end

	--- Switches are compared with `== true` at every read site, but a JSON string or 1 is
	--- truthy in Lua: `"RevealMouths": "false"` would turn a dev-only reveal on in a public
	--- build and read as off in the config file. Normalise to a real boolean here so the
	--- file, the log and the behaviour cannot disagree.
	local function Flag(OwnerName, Key)
		local Owner = In and In[OwnerName]

		if type(Owner) ~= "table" or type(Owner[Key]) == "boolean" then
			return
		end

		Owner[Key] = Owner[Key] ~= nil and Owner[Key] ~= false and Owner[Key] ~= "false" and Owner[Key] ~= 0
		Changed = true
	end

	Section("Start", "Cooldown", 0, 600, true)
	Section("Start", "MinPlayers", 0, 16, true)
	Section("Intermission", "Seconds", 0, 600, true)
	Section("Intermission", "SkipCost", 0, 10000, true)
	Section("Waves", "PoolSize", 1, 12, true)
	Section("Waves", "ActivePerWave", 1, 12, true)
	Section("Waves", "BandMin", Config.BandFloor, Config.BandCeiling)
	Section("Waves", "BandMax", Config.BandFloor, Config.BandCeiling)
	Section("Economy", "WaveClearPayout", 0, 10000, true)
	Section("Economy", "StartingResources", 0, 100000, true)

	Flag("Debug", "RevealMouths")

	local Waves = In and In.Waves

	if type(Waves) == "table" and IsNumber(Waves.BandMin) and IsNumber(Waves.BandMax)
		and Waves.BandMin > Waves.BandMax then
		-- An inverted band selects nothing and fails silently, so swap instead of clamping.
		Waves.BandMin, Waves.BandMax = Waves.BandMax, Waves.BandMin
		Changed = true
	end

	for _, Entry in ipairs(CURVE_KEYS) do
		local Owner = In and In[Entry.Owner]

		if type(Owner) == "table" then
			if type(Owner[Entry.Key]) ~= "table" then
				Owner[Entry.Key] = NewCurve(1, 1)
				Changed = true
			elseif Config.SanitizeCurve(Owner[Entry.Key]) then
				Changed = true
			end
		end
	end

	return Changed
end

--- Recursive table clone. Without it, "sanitising a copy" would reach through the
--- shared nested tables and mutate Plugin.DefaultConfig itself.
function Config.Copy(Table)
	if type(Table) ~= "table" then
		return Table
	end

	local Out = {}

	for Key, Value in pairs(Table) do
		Out[Key] = Config.Copy(Value)
	end

	return Out
end

--- Effective config for a map: everything loaded, deep-merged with Maps[map].
function Config.Resolve(MapName)
	local Loaded = Plugin.Config or Plugin.DefaultConfig
	local Merged = Config.Copy(Loaded)

	if MapName and type(Loaded.Maps) == "table" and type(Loaded.Maps[MapName]) == "table" then
		Merged = Config.DeepMerge(Merged, Loaded.Maps[MapName])
	end

	return Merged
end

function Plugin:PreValidateConfig(LoadedConfig)
	return Config.Sanitize(LoadedConfig)
end

--- Deep merge without mutating either input; tables recurse, scalars win.
function Config.DeepMerge(Base, Override)
	local Out = {}

	for Key, Value in pairs(Base or {}) do
		Out[Key] = Value
	end

	for Key, Value in pairs(Override or {}) do
		if type(Value) == "table" and type(Out[Key]) == "table" then
			Out[Key] = Config.DeepMerge(Out[Key], Value)
		else
			Out[Key] = Value
		end
	end

	return Out
end


--- Value of a curve at wave progress T in [0,1]. Disabled curves stay flat.
function Config.EvaluateCurve(CurveTable, T)
	if type(CurveTable) ~= "table" then
		return 0
	end

	if not CurveTable.Enabled then
		return CurveTable.Start or 0
	end

	local Control = CurveTable.Bezier or {}
	local X1, Y1 = Control[1] or 0.25, Control[2] or 0.1
	local X2, Y2 = Control[3] or 0.25, Control[4] or 1
	local Start = CurveTable.Start or 0
	local End = CurveTable.End or Start
	local Target = Clamp(T or 0, 0, 1)

	-- Exact endpoints: bisection converges towards 0 and 1 but never lands on them,
	-- which would make wave 1 spawn 4.000000179 bots and the reference wave overshoot.
	-- A curve is also read every wave, so this is a hot path worth short-circuiting.
	if Target <= 0 then
		return Start
	end

	if Target >= 1 then
		return End
	end

	local Low, High = 0, 1

	-- Bisection on x(t): 24 halvings is under 1e-7 and has no branches to get wrong.
	for _ = 1, 24 do
		local Middle = (Low + High) * 0.5

		if BezierAxis(X1, X2, Middle) < Target then
			Low = Middle
		else
			High = Middle
		end
	end

	local Eased = BezierAxis(Y1, Y2, (Low + High) * 0.5)

	return Start + (End - Start) * Eased
end

--- DESIGN.md progress model: t = (wave - 1) / (referenceWave - 1).
function Config.WaveProgress(WaveNumber, ReferenceWave)
	local Spread = math.max((ReferenceWave or 30) - 1, 1)

	return Clamp(((WaveNumber or 1) - 1) / Spread, 0, 1)
end

Plugin.HordeConfig = Config

return Config
