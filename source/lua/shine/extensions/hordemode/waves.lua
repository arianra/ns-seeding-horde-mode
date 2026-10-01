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
