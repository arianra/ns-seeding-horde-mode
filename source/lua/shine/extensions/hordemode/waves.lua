--[[ Horde Mode — Waves (i6a/i6b, increment 61a).
     The wave LOOP's brain: how many bots a wave is worth, how they spread over
     the mouth set, and when a wave is OVER. Every function here is pure - state
     lives in the machine (wave number, per-wave placed counts, intermission
     clock) and the registry (what is alive) - which is what makes the loop
     testable without waiting on bot materialisation the harness cannot survive.

     Composition is curve-driven per RD4, with RD3's posture intact: the shipped
     curve is ENABLED but deliberately weak (wave 1 = 3 aliens per Arian
     2026-09-30, "start with a lower end wave and move from there per wave").
     The endpoints are placeholders until he tunes them; the SHAPE is the
     product. EvaluateCurve short-circuits a disabled curve to Start, so a host
     turning the curve off gets a flat wave size, not a broken one.

     Two ways a wave ends before the timer: every spawned bot of it is dead
     (clear), or every mouth that emitted it is destroyed (early end - DESIGN
     Q29: killing the mouths IS the marine objective). Two ways the HORDE ends:
     the marine command station is destroyed, or every real marine has been
     dead continuously past the grace window (D4). All loss predicates are
     transition-based on purpose - a horde round may legitimately have no
     station YET, and "never had one" must never read as "just lost one". ]]
local Plugin = ...

local Waves = {}

--- Wave 1 sits at t=0 (the curve's Start), ReferenceWave at t=1 (its End),
--- clamped after. A reference of 1 or less is a misconfiguration, not a divide:
--- the answer is then the curve's FLOOR, not its cap - a typo in `ReferenceWave`
--- must never hand wave 1 the wave-20 horde. (The first version returned 1 here;
--- `wave_math_is_pure` refuses that direction of failure.)
function Waves.Progress(Wave, ReferenceWave)
	local Reference = ReferenceWave or 20

	if Reference <= 1 then
		return 0
	end

	local T = ((Wave or 1) - 1) / (Reference - 1)

	if T < 0 then
		return 0
	end

	if T > 1 then
		return 1
	end

	return T
end

--- How many bots this wave is worth: the curve, rounded, never zero. A wave
--- that spawns nothing would hang the clear predicate on `Spawned > 0` forever.
function Waves.HordeSize(WavesConfig, EvaluateFn, Wave)
	local Curve = WavesConfig and WavesConfig.Composition
	local Raw = EvaluateFn and EvaluateFn(Curve, Waves.Progress(Wave, WavesConfig and WavesConfig.ReferenceWave)) or 0
	local Size = math.floor(Raw + 0.5)

	if Size < 1 then
		Size = 1
	end

	return Size
end

--- Spread N bots over M mouths as evenly as round-robin gets: sums to exactly
--- N, and no mouth's share differs from another's by more than one. Counts, not
--- positions - the caller pairs each mouth's count with ITS validated point.
function Waves.Distribute(Total, Slots)
	local PerMouth = {}

	if not Slots or Slots < 1 then
		return PerMouth
	end

	local Index = 1

	for _ = 1, Total or 0 do
		PerMouth[Index] = (PerMouth[Index] or 0) + 1
		Index = Index % Slots + 1
	end

	return PerMouth
end

--- The wave-clear payout, same shape as HordeSize: the Economy.WaveClearPayout curve
--- evaluated at this wave's progress toward PayoutReferenceWave, rounded, never
--- negative. A disabled curve evaluates to Start (flat) - the same contract as every
--- other curve, so "off" means "the number you wrote", not zero.
function Waves.Payout(EconomyConfig, EvaluateFn, Wave)
	local Curve = EconomyConfig and EconomyConfig.WaveClearPayout
	local Reference = (EconomyConfig and EconomyConfig.PayoutReferenceWave) or 10
	local Raw = EvaluateFn and EvaluateFn(Curve, Waves.Progress(Wave, Reference)) or 0
	local Payout = math.floor(Raw + 0.5)

	if Payout < 0 then
		Payout = 0
	end

	return Payout
end

--- Wave clear: every bot THIS wave spawned is accounted dead, AND no spawn of
--- this wave is still climbing out of the factory queue (a never-materialised
--- bot is not alive by the registry's count, and calling that "cleared" would
--- end the wave before its first alien existed).
function Waves.Cleared(Spawned, AliveBots, OutstandingSpawns)
	return (Spawned or 0) > 0 and (AliveBots or 0) == 0 and (OutstandingSpawns or 0) == 0
end

--- The Q29 objective made real: placed mouths this wave, zero standing. The
--- alive count is the registry's three-state one - a husk does not count, and
--- a mouth the engine finished pruning does not either.
function Waves.MouthsFallen(Placed, AliveMouths)

	return (Placed or 0) > 0 and (AliveMouths or 0) == 0
end

--- The composition ladder (Arian 2026-09-30: "spawning not just skulks but a progression
--- based on damage curve"). A type joins at its Unlock wave and ramps to full Weight over
--- Ramp waves; shares are normalised against each other and split over the wave's size by
--- LARGEST REMAINDER, so the counts sum to exactly WaveSize - a wave that promised 15
--- aliens fields 15, not 14 and not 16. The result is interleaved (one of each available
--- type in rotation) so round-robin dealing over mouths cannot cluster every onos behind
--- one tunnel. Returns a list of type NAMES, length Total; empty when nothing is unlocked
--- or configured - the caller decides what "no mix" means.
function Waves.Deal(Wave, Total, Types)
	local Names, Sum = {}, 0

	for Name, Entry in pairs(Types or {}) do
		local Unlock = Entry.Unlock or 1

		if Wave >= Unlock and (Entry.Weight or 0) > 0 then
			local Ramp = math.max(Entry.Ramp or 1, 1)
			local Share = Entry.Weight * math.min(1, (Wave - Unlock + 1) / Ramp)

			if Share > 0 then
				Names[Name] = Share
				Sum = Sum + Share
			end
		end
	end

	if Sum <= 0 or not Total or Total < 1 then
		return {}
	end

	local Sorted, Counts, Assigned, Rem = {}, {}, 0, {}

	for Name, Share in pairs(Names) do
		Sorted[#Sorted + 1] = Name
	end

	table.sort(Sorted)

	for _, Name in ipairs(Sorted) do
		local Exact = Total * (Names[Name] / Sum)
		local Floor = math.floor(Exact)

		Counts[Name] = Floor
		Assigned = Assigned + Floor
		Rem[#Rem + 1] = { Name = Name, Rem = Exact - Floor }
	end

	table.sort(Rem, function(A, B)
		if A.Rem ~= B.Rem then
			return A.Rem > B.Rem
		end

		return A.Name < B.Name
	end)

	local Fill = 1

	while Assigned < Total and #Rem > 0 do
		Counts[Rem[Fill].Name] = Counts[Rem[Fill].Name] + 1
		Assigned = Assigned + 1
		Fill = Fill % #Rem + 1
	end

	--- An unlock that rounds to zero is not an unlock. A type whose fresh ramp share
	--- rounds below 1 (onos at wave 10 of a 15-alien wave did exactly that) would stay
	--- invisible for waves after its ladder entry - so every unlocked type gets ONE,
	--- taken from the current largest holder (the skulk chaff, which exists to absorb
	--- exactly this). Only when the wave can afford one per type at all.
	local Live = 0

	for Name in pairs(Counts) do
		if Counts[Name] > 0 then
			Live = Live + 1
		end
	end

	if Live < Total then
		local Guard = 0

		while Guard < 64 do
			local Missing, Biggest = nil, nil

			for Name, Count in pairs(Counts) do
				if Count == 0 then
					Missing = Name
				end
			end

			if not Missing then
				break
			end

			for Name, Count in pairs(Counts) do
				if Count > 1 and (not Biggest or Count > Counts[Biggest]) then
					Biggest = Name
				end
			end

			if not Biggest then
				break
			end

			Counts[Missing] = 1
			Counts[Biggest] = Counts[Biggest] - 1
			Guard = Guard + 1
		end
	end

	local Out, Left = {}, {}
	local Rounds, Remaining = {}, 0

	for _, Name in ipairs(Sorted) do
		if Counts[Name] > 0 then
			Rounds[#Rounds + 1] = Name
			Left[Name] = Counts[Name]
			Remaining = Remaining + Counts[Name]
		end
	end

	while Remaining > 0 do
		for _, Name in ipairs(Rounds) do
			if Left[Name] > 0 then
				Left[Name] = Left[Name] - 1
				Remaining = Remaining - 1
				Out[#Out + 1] = Name
			end
		end
	end

	return Out
end

--- D4's grace window as a pure step: while any real marine lives, the clock
--- stays nil; once none does, time starts counting; it FIRES once, at the
--- crossing. Returns the new Since and whether to end the horde now.
function Waves.Wipe(Now, Since, AliveMarines, GraceSeconds)
	if (AliveMarines or 0) > 0 then
		return nil, false
	end

	local Started = Since or Now
	local Grace = GraceSeconds or 3

	return Started, (Now - Started) >= Grace
end

--- The station is lost only if it was ever THERE: a warmup horde round may
--- have no command station at all at first, and that absence must not read as
--- destruction. hadStation is latch state the caller owns (reset per round).
function Waves.StationsLost(HadStation, AliveStructures)
	return HadStation == true and (AliveStructures or 1) == 0
end

Plugin.Waves = Waves

return Waves
