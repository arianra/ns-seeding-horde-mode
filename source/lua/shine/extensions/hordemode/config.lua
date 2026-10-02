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
	{ Owner = "Economy", Key = "WaveClearPayout" },
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
-- ENABLED is per-curve now (61a): the composition curve ships ON with deliberately weak
-- numbers per Arian 2026-09-30 ("first wave is 3 aliens, move from there per wave");
-- every other curve ships OFF until RD3, and a disabled curve evaluates to its Start -
-- a flat value, not a broken one.
local function NewCurve(Start, End, Enabled)
	return {
		Enabled = Enabled == true,
		Start = Start,
		End = End,
		Bezier = { 0.25, 0.1, 0.25, 1 },
	}
end

Plugin.DefaultConfig = {
	Start = {
		-- 5, per Arian 2026-09-28 (live playtest): "the cooldown is useless during testing".
		-- It amends the 09-21 zero and the pre-bake 60. What actually bit the chair was the
		-- 60 PERSISTED in the server's own `shine/plugins/HordeMode.json` - Shine keeps the
		-- table it loaded (fact 15), so lowering the default alone never reaches a server
		-- that has booted once; the live and dev files were set to 5 alongside this change.
		-- A short value disciplines repeated bare `/horde` spam only: `/horde restart`
		-- clears the wait outright (server.lua's restart branch, `ClearCooldown`).
		-- i8a's loss triggers are the case Q12's cooldown was written for - revisit then.
		Cooldown = 5,
		MinPlayers = 1,          -- real humans only; bot clients never count (verified, i0f)
	},
	Intermission = {
		--- Chair 2026-10-01: "reduce intermission to 15 seconds for now." Flat 15 for
		--- both first and later while the loop is being tested; the first/later split
		--- (Q33) stays as a knob — set Seconds back above 15 to re-enable a longer
		--- steady-state gap. EndWavePhase stores the chosen wait on the machine so the
		--- clock and the announcement can never disagree.
		Seconds = 15,
		FirstSeconds = 15,
		SkipCost = 0,            -- Q17 paid skip; 0 disables the charge
	},
	Waves = {
		PoolSize = 6,            -- Q28 pool, decision allows 5-8
		ActivePerWave = 3,
		BandMin = 56,            -- spike tby: summit's reachable near-base band is 56-80m
		BandMax = 90,            -- the pre-spike 20m guess selects nothing on vanilla maps
		--- The band is measured in WALKING metres, so a route could still leave a mouth 5 m
		--- from the chair behind a wall. This is the straight-line floor as a fraction of
		--- BandMin: a guard on "not inside the base room", not a difficulty number, so it is
		--- derived instead of tuned. 0.5 keeps it well clear of any base room while never
		--- rejecting a point the walking ring would want.
		BandLineFactor = 0.5,
		--- STEP A's flat knob is superseded by the wave loop (61a): the per-wave bot count
		--- is `Composition` evaluated at Waves.Progress(wave, ReferenceWave). Wave 1 sits at
		--- the curve's Start = 3 aliens; the End is reached at ReferenceWave and clamped
		--- after. Health/Armor/Damage/MouthHealth stay DISABLED until RD3 - disabled means
		--- "evaluate to Start", which for those is multiplier 1 / flat HP: honest nothing.
		ReferenceWave = 20,          -- untuned, placeholder 2026-09-30
		WipeGraceSeconds = 3,        -- D4: every real marine dead CONTINUOUSLY this long is the wipe
		Composition = NewCurve(3, 15, true),   -- the only curve that ships ENABLED: weak but REAL
		Health = NewCurve(1, 3),
		Armor = NewCurve(0, 2),
		Damage = NewCurve(1, 2),
		MouthHealth = NewCurve(1000, 4000),   -- Q29: wave-1 mouths near-indestructible
		--- The composition ladder (Q31, Arian 2026-09-30): a type joins at Unlock and
		--- ramps to full Weight over Ramp waves; Waves.Deal splits the curve's wave size
		--- across whatever is unlocked. The ladder follows the marine power curve
		--- (DESIGN §wave model, built on measured damage/armor numbers): gorge when
		--- armour L1 is affordable, lerk when spores punish clustering, fade against L2,
		--- onos only once exosuit territory. Weights are share units (Skulk 6 = the
		--- chaff floor). Untuned endpoints, same RD3 status as every other curve.
		Types = {
			Skulk = { Unlock = 1,  Ramp = 1,  Weight = 6 },
			Gorge = { Unlock = 3,  Ramp = 4,  Weight = 1 },
			Lerk  = { Unlock = 5,  Ramp = 4,  Weight = 1 },
			Fade  = { Unlock = 7,  Ramp = 5,  Weight = 1 },
			Onos  = { Unlock = 10, Ramp = 6,  Weight = 2 },
		},
	},
	Economy = {
		--- Q34 (chair 2026-10-01): the horde owns its economy. Team resources come from
		--- exactly TWO dials — a fixed start and the per-wave payout — and NOT from the
		--- resource tower. `ExtractorIncome=false` makes the horde suppress the extractor's
		--- team income for its duration (restored on teardown, like autobuild). These two
		--- dials (StartingResources, WaveClearPayout) are deliberately SEPARATE from the
		--- difficulty curve — the user flagged they may need different logic later.
		StartingResources = 100,       -- applied to the marine team at horde start (was a dead knob)
		ExtractorIncome = false,       -- false: extractors add nothing to team res while a horde runs
		WaveClearPayout = NewCurve(5, 40, true),   -- per-wave team res; 5→40 by PayoutReferenceWave
		PayoutReferenceWave = 10,
		PayoutPerPlayer = NewCurve(10, 2),    -- Q24: payout per head shrinks as players join
		--- Personal resources to the marine who lands the killing blow, by victim lifeform
		--- (Q34: "2 for a skulk or gorge, 3 for lerk, 4 for fade, 5 for onos, last kill gets
		--- the money"). Vanilla build 344 has NO Lua kill→resource path (AwardPersonalResources
		--- is uncalled), so the horde awards this itself via the OnEntityKilled hook.
		KillBounty = {
			Skulk = 2, Gorge = 2, Lerk = 3, Fade = 4, Onos = 5,
		},
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

function Config.SanitizeCurve(CurveTable, Shipped)
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

	--- `Enabled` is a switch and switches get the same normalisation as top-level flags:
	--- the STRING "false" is truthy in Lua, so a hand-edited curve could silently turn
	--- difficulty on (or off) in a way the file's text denies. A missing Enabled takes the
	--- SHIPPED default for THIS curve - same rule Section applies to numbers: absent means
	--- no opinion, and no opinion is the default, not the floor. Any other non-boolean is
	--- normalised to `== true`.
	local EnabledType = type(CurveTable.Enabled)

	if EnabledType ~= "boolean" then
		local NewEnabled

		if EnabledType == "nil" then
			NewEnabled = Shipped ~= nil and Shipped.Enabled == true or false
		else
			NewEnabled = CurveTable.Enabled == true
		end

		if CurveTable.Enabled ~= NewEnabled then
			CurveTable.Enabled = NewEnabled
			Changed = true
		end
	end

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

	--- A missing or malformed number is replaced by the SHIPPED DEFAULT, read back out of
	--- DefaultConfig, not by the clamp floor. Those were the same argument until they
	--- weren't: `BandLineFactor` (clamp 0-1, default 0.5) arrived as 0 the moment it was
	--- added to a config file written before it existed - which silently disarmed the
	--- base-room floor, sanitised as "clean", and was then written back to disk by Shine as
	--- if it had been chosen. `Low` is the smallest LEGAL value, not what we want when nobody
	--- has expressed an opinion, so the default is derived rather than passed per call.
	local function ShippedDefault(OwnerName, Key, Fallback)
		local Owner = Plugin.DefaultConfig and Plugin.DefaultConfig[OwnerName]
		local Value = Owner and Owner[Key]

		if IsNumber(Value) then
			return Value
		end

		return Fallback
	end

	local function Section(OwnerName, Key, Low, High, AsInteger)
		local Owner = In and In[OwnerName]

		if type(Owner) ~= "table" then
			return
		end

		if not IsNumber(Owner[Key]) then
			Owner[Key] = ShippedDefault(OwnerName, Key, Low)
			Changed = true
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
	Section("Intermission", "FirstSeconds", 0, 600, true)
	Section("Intermission", "SkipCost", 0, 10000, true)
	Section("Waves", "PoolSize", 1, 12, true)
	Section("Waves", "ActivePerWave", 1, 12, true)
	Section("Waves", "ReferenceWave", 2, 200, true)
	Section("Waves", "WipeGraceSeconds", 0, 60, false)
	Section("Waves", "BandMin", Config.BandFloor, Config.BandCeiling)
	Section("Waves", "BandMax", Config.BandFloor, Config.BandCeiling)
	Section("Economy", "PayoutReferenceWave", 2, 200, true)
	Section("Economy", "StartingResources", 0, 100000, true)
	Flag("Economy", "ExtractorIncome")

	--- KillBounty is a fixed set of lifeform keys; clamp each to a sane personal-resource
	--- reward and drop anything that is not a number (a typo'd bounty must not silently
	--- award 0 or a string). Unknown keys are left alone - the lookup ignores them.
	local Bounty = In and In.Economy and In.Economy.KillBounty

	if type(Bounty) == "table" then
		for _, Name in ipairs({ "Skulk", "Gorge", "Lerk", "Fade", "Onos" }) do
			if not IsNumber(Bounty[Name]) then
				Bounty[Name] = 0
				Changed = true
			else
				local Fixed = Clamp(math.floor(Bounty[Name] + 0.5), 0, 100)

				if Fixed ~= Bounty[Name] then
					Bounty[Name] = Fixed
					Changed = true
				end
			end
		end
	end

	Flag("Debug", "RevealMouths")

	Section("Waves", "BandLineFactor", 0, 1)


	--- Waves.Types is a table of small scalar records, not a Section() path: clamp each
	--- field, and drop entries that cannot describe a type at all. An Unlock of 0 would
	--- put an onos in wave 1; a Weight of 0 silently removes a type - both are typos,
	--- and the sanitizer's job is to fix typos loudly rather than play them.
	local Types = In and In.Waves and In.Waves.Types

	if type(Types) == "table" then
		for Name, Entry in pairs(Types) do
			if type(Entry) ~= "table" then
				Types[Name] = nil
			else
				for _, Spec in ipairs({ { "Unlock", 1, 200 }, { "Ramp", 1, 50 }, { "Weight", 0, 100 } }) do
					local Key, Low, High = Spec[1], Spec[2], Spec[3]

					if not IsNumber(Entry[Key]) then
						Entry[Key] = nil
						Changed = true
					else
						local Fixed = Clamp(math.floor(Entry[Key] + 0.5), Low, High)

						if Fixed ~= Entry[Key] then
							Entry[Key] = Fixed
							Changed = true
						end
					end
				end
			end
		end
	end
	local Waves = In and In.Waves

	if type(Waves) == "table" and IsNumber(Waves.BandMin) and IsNumber(Waves.BandMax)
		and Waves.BandMin > Waves.BandMax then
		-- An inverted band selects nothing and fails silently, so swap instead of clamping.
		Waves.BandMin, Waves.BandMax = Waves.BandMax, Waves.BandMin
		Changed = true
	end

	for _, Entry in ipairs(CURVE_KEYS) do
		local Owner = In and In[Entry.Owner]
		local ShipOwner = Plugin.DefaultConfig and Plugin.DefaultConfig[Entry.Owner]
		local Shipped = ShipOwner and ShipOwner[Entry.Key]

		if type(Owner) == "table" then
			if type(Owner[Entry.Key]) ~= "table" then
				-- A missing or clobbered curve is replaced by the SHIPPED curve, not by a
				-- flat NewCurve(1,1): for Composition the shipped default is 3-aliens
				-- ENABLED; a 1,1 replacement would be a horde with one skulk per wave that
				-- the sanitizer itself wrote into the file as if it had been chosen.
				Owner[Entry.Key] = (Config.Copy and Shipped and Config.Copy(Shipped)) or NewCurve(1, 1)
				Changed = true
			elseif Config.SanitizeCurve(Owner[Entry.Key], Shipped) then
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

--- Effective config for a map. `DefaultConfig` is the BASE and the loaded file is the
--- OVERRIDE — the file only needs to say what differs. This is load-bearing, not cosmetic:
--- Shine does not merge the file under the defaults (the file's table replaces), and our
--- `Sanitize` fills a missing KEY only inside a section that already EXISTS — `Section()`
--- early-returns when the parent table is absent. So a minimal file used to resolve to a
--- config with NO Waves/Economy/Intermission section at all. A regenerated dev boot writes
--- just `{Debug.RevealMouths}` to disk, which meant: the horde ran with 1 alien (nil curve
--- -> floor), 0 res (nil payout), the hardcoded 30 s, and — no `Start` section — SKIPPED
--- the world reset, the exact state trap that bricked the server. Base-equals-defaults makes
--- the file a real override layer and a partial section file safe (only the keys it names
--- differ; the rest come from the shipped defaults).
function Config.Resolve(MapName)
	local Loaded = Plugin.Config or {}
	local Merged = Config.DeepMerge(Config.Copy(Plugin.DefaultConfig), Loaded)

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
