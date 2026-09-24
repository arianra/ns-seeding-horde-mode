--[[ Horde Mode — Placement (i4a).

 Everything here is geometry over injected point sets: GetBaseAnchor,
 GatherCandidates, FilterBand (adaptive), Reachable, SelectSectorSpread. The one
 engine-facing function is Collect(), which reads entity origins and immediately
 hands them to the pure ones. That split is deliberate (RD1): the band, the
 dedupe and the sector rules are the parts that encode design decisions, and they
 have to be testable headless with fake candidate sets instead of requiring a
 loaded map.

 Replaces the i0a stub. ]]
local Plugin = ...

local Placement = {}
Placement.__index = Placement

local kTwoPi = math.pi * 2

--- NS2 Points and plain {x,y,z} tables both arrive here: the engine returns Points,
--- the scenarios inject tables. x/z is the ground plane, y is up.
local function Axis(Point, Name, Index)
	if Point == nil then
		return 0
	end

	local Value = Point[Name]

	if Value == nil then
		Value = Point[Index]
	end

	return Value or 0
end

function Placement.Distance2D(A, B)
	if A.GetDistance2D then
		return A:GetDistance2D(B)
	end

	local DeltaX = Axis(A, "x", 1) - Axis(B, "x", 1)
	local DeltaZ = Axis(A, "z", 3) - Axis(B, "z", 3)

	return math.sqrt(DeltaX * DeltaX + DeltaZ * DeltaZ)
end

--- The anchor mouths must stay away from. The marine command chair is ground truth;
--- maps without one fall back to the centroid of the infestation points. nil means
--- "this map gives me no base", which FilterBand treats as *no exclusion* rather
--- than "everything is at distance 0" - a silent all-rejected pool would look like
--- the horde being broken, which is the failure mode we are trying to avoid.
function Placement.GetBaseAnchor(CommandChair, InfestationPoints)
	if CommandChair then
		return CommandChair
	end

	local Count = InfestationPoints and #InfestationPoints or 0

	if Count == 0 then
		return nil
	end

	local SumX, SumZ = 0, 0

	for _, Point in ipairs(InfestationPoints) do
		SumX = SumX + Axis(Point, "x", 1)
		SumZ = SumZ + Axis(Point, "z", 3)
	end

	return { x = SumX / Count, y = 0, z = SumZ / Count }
end

--- Merge the origin lists (infestation portals, cysts, Locations) and drop points on
--- top of each other. Without the separation rule, a cluster of three cysts in one
--- corridor burns three of the six pool slots on what is effectively one mouth site,
--- and the sector spread then has nothing left to spread.
function Placement.GatherCandidates(Sources, MinSeparation)
	local Out = {}

	MinSeparation = MinSeparation or 5

	for _, List in ipairs(Sources or {}) do
		for _, Point in ipairs(List or {}) do
			local Keep = true

			for _, Have in ipairs(Out) do
				if Placement.Distance2D(Point, Have.point) < MinSeparation then
					Keep = false
					break
				end
			end

			if Keep then
				Out[#Out + 1] = { point = Point, distance = nil }
			end
		end
	end

	return Out
end

local function AngleFrom(Point, Origin)
	local Angle = math.atan2(Axis(Point, "z", 3) - Axis(Origin, "z", 3), Axis(Point, "x", 1) - Axis(Origin, "x", 1))

	if Angle < 0 then
		Angle = Angle + kTwoPi
	end

	return Angle
end

--- The band is the design decision (Q28; spike tby measured summit's reachable
--- near-base ring at 56-80 m, so the old 20 m guess selected nothing on any vanilla
--- map). The adaptive fallback exists because mapper placement is arbitrary: a strict
--- band that selects zero candidates would leave a horde with no mouths and no
--- explanation. When that happens we take the nearest PoolSize candidates that are
--- still at least BandMin away - never closer, because "inside the base room" is the
--- one thing the band exists to prevent.
function Placement.FilterBand(Candidates, Base, BandMin, BandMax, PoolSize)
	local InBand, Beyond = {}, {}

	for _, Candidate in ipairs(Candidates or {}) do
		local Distance = Base and Placement.Distance2D(Candidate.point, Base) or 0

		if Distance >= BandMin and Distance <= BandMax then
			InBand[#InBand + 1] = { point = Candidate.point, distance = Distance }
		elseif Distance >= BandMin then
			Beyond[#Beyond + 1] = { point = Candidate.point, distance = Distance }
		end
	end

	if #InBand > 0 then
		return InBand
	end

	table.sort(Beyond, function(A, B) return A.distance < B.distance end)

	local Out = {}

	for Index = 1, math.min(PoolSize or #Beyond, #Beyond) do
		Out[Index] = Beyond[Index]
	end

	return Out
end

--- Pathing.GetPathPoints(start, end, PointArray) -> boolean (Cyst.lua:171). Called
--- through an injected function so the pure tests never touch the engine and so a map
--- with no nav mesh reports "unreachable" instead of throwing through the wave.
function Placement.Reachable(From, To, PathingFn)
	if not PathingFn then
		return true
	end

	local Ok, Result = pcall(PathingFn, From, To)

	return Ok and Result == true
end

--- One mouth per sector, nearest first, so a wave cannot arrive down a single
--- corridor. With no base anchor the sector idea is meaningless, so fall back to the
--- first Count candidates rather than rejecting the wave.
function Placement.SelectSectorSpread(Candidates, Base, Count)
	Count = Count or 3
	Candidates = Candidates or {}

	local Out = {}

	if not Base or #Candidates == 0 then
		for Index = 1, math.min(Count, #Candidates) do
			Out[Index] = Candidates[Index]
		end

		return Out
	end

	local SectorWidth = kTwoPi / Count
	local Taken = {}

	for Sector = 0, Count - 1 do
		local Best, BestDistance

		for _, Candidate in ipairs(Candidates) do
			if not Taken[Candidate] and math.floor(AngleFrom(Candidate.point, Base) / SectorWidth) == Sector then
				if not Best or Candidate.distance < BestDistance then
					Best, BestDistance = Candidate, Candidate.distance
				end
			end
		end

		if Best then
			Taken[Best] = true
			Out[#Out + 1] = Best
		end
	end

	if #Out < Count then
		local Leftovers = {}

		for _, Candidate in ipairs(Candidates) do
			if not Taken[Candidate] then
				Leftovers[#Leftovers + 1] = Candidate
			end
		end

		table.sort(Leftovers, function(A, B) return A.distance < B.distance end)

		for _, Candidate in ipairs(Leftovers) do
			if #Out >= Count then
				break
			end

			Out[#Out + 1] = Candidate
		end
	end

	return Out
end

--- Engine-facing half: read the map, then hand everything to the pure functions.
--- Returns chosen candidates (each {point, distance}), the base anchor, the raw
--- candidate count and the post-band count. Those counts are what make "no mouths
--- appeared" diagnosable from the log alone: raw 0 means the map has no anchor
--- entities at all, raw > 0 with banded 0 means the configured ring misses this map.
function Placement.Collect(Config, PathingFn)
	local Waves = (Config and Config.Waves) or {}
	local BandMin = Waves.BandMin or 56
	local BandMax = Waves.BandMax or 90
	local PoolSize = Waves.PoolSize or 6
	local PerWave = Waves.ActivePerWave or 3

	local Chair, Infestations
	local Sources = {}

	local function AddByClassname(ClassName, Sink)
		local List = {}

		for _, Ent in ientitylist(Shared.GetEntitiesWithClassname(ClassName)) do
			local Ok, Origin = pcall(function() return Ent:GetOrigin() end)

			if Ok and Origin then
				List[#List + 1] = Origin
			end
		end

		return List
	end

	local Chairs = AddByClassname("CommandStructure")
	Chair = Chairs[1]

	Infestations = AddByClassname("InfestationPortal")
	Sources[#Sources + 1] = Infestations
	Sources[#Sources + 1] = AddByClassname("Cyst")
	Sources[#Sources + 1] = AddByClassname("Location")

	if not PathingFn then
		PathingFn = function(From, To)
			local Points = PointArray()

			return Pathing.GetPathPoints(From, To, Points)
		end
	end

	local Base = Placement.GetBaseAnchor(Chair, Infestations)
	local Candidates = Placement.GatherCandidates(Sources, 5)
	local Banded = Placement.FilterBand(Candidates, Base, BandMin, BandMax, PoolSize)

	local Reachable = {}

	for _, Candidate in ipairs(Banded) do
		if #Reachable >= PoolSize then
			break
		end

		if Placement.Reachable(Base or Candidate.point, Candidate.point, PathingFn) then
			Reachable[#Reachable + 1] = Candidate
		end
	end

	return Placement.SelectSectorSpread(Reachable, Base, PerWave), Base, #Candidates, #Banded
end

Plugin.Placement = Placement

return Placement
