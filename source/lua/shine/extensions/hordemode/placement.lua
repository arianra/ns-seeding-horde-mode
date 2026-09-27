--[[ Horde Mode — Placement (i4a).

 Design decisions as geometry over injected point sets: GetBaseAnchor, GatherCandidates,
 FilterBand (adaptive, measured by whatever function you hand it), SelectSectorSpread - plus
 the two engine-facing halves: ValidateCandidates, which asks the ENGINE whether a point is
 somewhere a structure can actually stand, and SampleRing, which decides where to ask.

 The split is deliberate (RD1). The band, the dedupe and the sector rules encode design
 decisions and must be testable headless with fake candidate sets; the engine questions are
 asked through injectable hooks so the same code runs against a real map and against a fake
 one, and so a level with no nav mesh reports "rejected" instead of throwing mid-wave.

 Two facts came out of a marine walking summit with a debug marker on, and they shaped this
 file. Both are recorded in the comments where they now apply, because each was learned the
 expensive way:

   * An anchor's origin is a volume marker, not a floor. Spawning at raw
     `InfestationPortal`/`Cyst`/`Location` origins put three mouths in solid rock and in a
     vent nobody can stand in. The fix is the commander's own build check (BuildUtility), not
     a smaller step.
   * Distance must be measured the way a horde travels it. Crow-flight metres selected one
     "far" point on summit and it had no route to it at all. ]]
local Plugin = ...

local Placement = {}
Placement.__index = Placement

local kTwoPi = math.pi * 2

--- NS2 Points and plain {x,y,z} tables both arrive here: the engine returns Points, the
--- scenarios inject tables. x/z is the ground plane, y is up.
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

-- Exported: these points reach this module from both the server and the scenarios, and every
-- caller that logs or compares a coordinate needs the same tolerance for which of the two it
-- was handed.
Placement.Axis = Axis

function Placement.Distance2D(A, B)
	if A.GetDistance2D then
		return A:GetDistance2D(B)
	end

	local DeltaX = Axis(A, "x", 1) - Axis(B, "x", 1)
	local DeltaZ = Axis(A, "z", 3) - Axis(B, "z", 3)

	return math.sqrt(DeltaX * DeltaX + DeltaZ * DeltaZ)
end

--- Vector when the engine gives us one, plain table in a headless unit test.
local function At(X, Y, Z)
	if Vector then
		return Vector(X, Y, Z)
	end

	return { x = X, y = Y, z = Z }
end

--- The anchor mouths must stay away from. The marine command chair is ground truth; maps
--- without one fall back to the centroid of the infestation points. nil means "this map gives
--- me no base", which FilterBand treats as *no exclusion* rather than "everything is at
--- distance 0" - a silently all-rejected pool looks like a broken horde, which is the failure
--- mode this whole module is trying to make impossible.
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

--- Merge candidate lists and drop points on top of each other. Without the separation rule, a
--- cluster of three cysts in one corridor burns three of the six pool slots on what is
--- effectively one mouth site, and the sector spread then has nothing left to spread.
---
--- It runs AFTER surface validation for the same reason: two anchors in different rooms can
--- snap to the same floor point, and counting that as two mouths is the cluster bug by another
--- road.
function Placement.GatherCandidates(Sources, MinSeparation)
	local Out = {}

	MinSeparation = MinSeparation or 5

	for _, List in ipairs(Sources or {}) do
		for _, Item in ipairs(List or {}) do
			--- Accept both a point and a {point = ...} record. This is not generosity for its
			--own sake: a record read as a point has no x or z, so Axis() answers 0, every entry
			--lands at the origin, and the whole list collapses into one candidate inside
			--MinSeparation of itself. That is exactly what happened here - 24 buildable points
			--became 1, "in band" went to 0, and no mouth was placed - while every number in the
			--log looked self-consistent. Unwrapped, the collapse cannot happen silently.
			local Point = Item.point or Item
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

--- The engine's own footprint for a tunnel entrance: `kTechDataMaxExtents` of
--- `kTechId.Tunnel` is 1.2³ (TechData.lua:3035). Read at call time and defaulted, because
--- extents are the size the surface checks measure with - inventing our own would let a mouth
--- pass a test for a footprint the game never uses.
local kFallbackExtents = { x = 1.2, y = 1.2, z = 1.2 }

function Placement.Extents()
	if GetExtents and kTechId and kTechId.Tunnel then
		local Ok, Got = pcall(GetExtents, kTechId.Tunnel)

		if Ok and Got then
			return Got
		end
	end

	return kFallbackExtents
end

--- The engine's questions about a point, as data. Overridable so the pure scenarios can drive
--- every branch without a map, and so one call that throws on a particular level is reported
--- as a rejection instead of killing wave placement.
function Placement.DefaultHooks()
	return {
		--- The nav mesh. This is how a bot commander turns an idea for a spot into a place it
		--- can build: AlienCommanderBrain_Data.lua:237 snaps a bone-wall offset onto the mesh
		--- before asking whether it is legal. Sampling through it means candidates are
		--- positions the game already treats as ground rather than our guess at one.
		Mesh = function(Point)
			return Pathing.GetClosestPoint(Point)
		end,

		--- Ground under a point, capsule-adjusted - the first thing BuildUtility does with a
		--- placement, before it will even consider it legal (BuildUtility.lua:277).
		Ground = function(Point, Extents)
			return GetGroundAtPointWithCapsule(Point, Extents, PhysicsMask.CommanderBuild, CreateFilter(nil))
		end,

		--- Walkable and buildable per the nav mesh flags a commander's cursor is gated by
		--- (BuildUtility.lua:20-26). This is the check that rejects the ledge and the vent.
		Flags = function(Point, Extents)
			return {
				walk = Pathing.GetIsFlagSet(Point, Extents, Pathing.PolyFlag_Walk),
				nobuild = Pathing.GetIsFlagSet(Point, Extents, Pathing.PolyFlag_NoBuild)
			}
		end,

		--- The obstacle test BuildUtility applies to tunnel entrances specifically
		--- (BuildUtility.lua:426-438): a capsule the size of the mouth must not overlap world.
		Collide = function(Point, Extents)
			local radius = math.max(Axis(Extents, "x", 1), Axis(Extents, "z", 3))
			local height = Axis(Extents, "y", 2)
			local center = At(Axis(Point, "x", 1),
				Axis(Point, "y", 2) + height * 0.5 + radius + 0.3,
				Axis(Point, "z", 3))

			return Shared.CollideCapsule(center, radius, height, CollisionRep.Default, PhysicsMask.AllButPCs, nil)
		end
	}
end

--- Is this point somewhere a structure could be built, and if not, what said so.
---
--- Returns the usable (surface-snapped) point, or nil plus the reason. The reason is the
--- product here as much as the verdict: "no mouths appeared" has to be answerable from the log,
--- because from the chair it looks exactly like the mode doing nothing.
function Placement.SnapToSurface(Point, Hooks)
	if not Point then
		return nil, "no point"
	end

	local Extents = Placement.Extents()

	Hooks = Hooks or Placement.DefaultHooks()

	local Snapped = Point
	local Reject

	if Hooks.Ground then
		local Ok, Got = pcall(Hooks.Ground, Point, Extents)

		if not Ok or not Got then
			return nil, "no ground under anchor"
		end

		Snapped = Got
	end

	if not Reject and Hooks.Flags then
		local Ok, Got = pcall(Hooks.Flags, Snapped, Extents)

		if not Ok or not Got then
			return nil, "nav mesh unreadable"
		end

		if Got.nobuild then
			Reject = "no-build zone"
		elseif not Got.walk then
			Reject = "not on walk mesh"
		end
	end

	if not Reject and Hooks.Collide then
		local Ok, Blocked = pcall(Hooks.Collide, Snapped, Extents)

		if not Ok then
			return nil, "obstacle check threw"
		end

		if Blocked then
			Reject = "overlaps world"
		end
	end

	if Reject then
		return nil, Reject
	end

	return Snapped
end

--- How far from a starting point to look for floor a commander could actually build on, and how
--- many bearings per ring. The start is where the search begins, never where the structure
--- goes: measured on ns2_summit, 42 of 48 anchors failed the engine's own check (34 of them for
--- not being on walkable nav mesh), while the floor a mouth needs was usually a few metres
--- away - which is exactly what a player's cursor finds by moving.
local kProbeRadii = { 2, 4, 6, 8 }
local kProbeDirections = 8

--- Search outward from a point. Returns a buildable point and the ring radius that found it
--- (0 = the point itself), or nil and the first reason anything was refused - so the tally names
--- the real obstacle instead of "we gave up".
function Placement.SearchForSurface(Point, Hooks)
	local BaseX, BaseY, BaseZ = Axis(Point, "x", 1), Axis(Point, "y", 2), Axis(Point, "z", 3)
	local First = "no buildable surface within 8m"

	for _, Radius in ipairs(kProbeRadii) do
		for Step = 0, kProbeDirections - 1 do
			local Angle = (kTwoPi * Step) / kProbeDirections

			local Found, Reason = Placement.SnapToSurface(
				At(BaseX + math.cos(Angle) * Radius, BaseY, BaseZ + math.sin(Angle) * Radius), Hooks)

			if Found then
				return Found, Radius
			end

			-- Keep the first concrete reason; "no buildable surface within 8m" is ours and
			-- names nothing.
			if First == "no buildable surface within 8m" then
				First = Reason
			end
		end
	end

	return nil, First
end

--- Validate a list of raw points into candidates the engine accepts.
---
--- Returns the survivors and the tallies, and the tallies are the diagnosis: "63 examined, 24
--- usable, not on walk mesh=39" says the sources are volume markers sitting in rock; "in band
--- 0" says the ring is wrong for this map. Both were invisible before this existed, and both
--- looked like "the mode placed nothing".
---
--- `StopAfter` bounds the work: a wave needs PoolSize band-filtered points, so collecting four
--- times that many usable ones is more than the sector rule can use, and it keeps a level with
--- thousands of anchors from turning placement into tens of thousands of traces.
function Placement.ValidateCandidates(Points, Hooks, StopAfter)
	local Out, Stats = {}, { raw = 0, usable = 0, atPoint = 0, nearPoint = 0, probes = 0, rejected = {} }

	for _, Point in ipairs(Points or {}) do
		if not StopAfter or #Out < StopAfter then
			Stats.raw = Stats.raw + 1

			local Snapped, Reason = Placement.SnapToSurface(Point, Hooks)
			local Radius = 0

			if not Snapped then
				Snapped, Radius = Placement.SearchForSurface(Point, Hooks)

				Stats.probes = Stats.probes + #kProbeRadii * kProbeDirections
			end

			if Snapped then
				Stats.usable = Stats.usable + 1

				if Radius > 0 then
					Stats.nearPoint = Stats.nearPoint + 1
				else
					Stats.atPoint = Stats.atPoint + 1
				end

				Out[#Out + 1] = { point = Snapped, distance = nil }
			else
				Stats.rejected[Reason] = (Stats.rejected[Reason] or 0) + 1
			end
		end
	end

	return Out, Stats
end

--- Fold one validation's tallies into another, so a wave that drew from two candidate sources
--- still reports one honest sentence about it.
function Placement.MergeStats(Into, From)
	if not Into or not From then
		return Into
	end

	Into.raw = Into.raw + From.raw
	Into.usable = Into.usable + From.usable
	Into.atPoint = Into.atPoint + (From.atPoint or 0)
	Into.nearPoint = Into.nearPoint + (From.nearPoint or 0)
	Into.probes = Into.probes + From.probes

	for Reason, Count in pairs(From.rejected or {}) do
		Into.rejected[Reason] = (Into.rejected[Reason] or 0) + Count
	end

	return Into
end

--- One line for the log. Every number in it counts something that actually happened, and the
--- labels are chosen against the misreads they have to prevent:
---
---   * `examined`, not `raw` - a wave that found enough usable points stops early, so claiming
---     "48 raw" when it looked at 24 sends the next reader after a number that never existed.
---   * the walk spread and `selfPath=` printed even when nothing was reachable: on the shipped
---     map every candidate failed the path query, and a line that named walking distances only
---     when they existed made that read as "in band 0" with no reason attached. `selfPath=` is
---     the difference between "pathing does not work from this point" and "this base is smaller
---     than the band" - same empty pool, different bug.
---   * `-> N after 5m dedupe`, because a collapse in the dedupe is invisible anywhere else and
---     it silently costs a wave its mouths.
function Placement.ReasonCounts(Stats)
	if not Stats then
		return "-"
	end

	local Parts = {}

	for Reason, Count in pairs(Stats.rejected or {}) do
		Parts[#Parts + 1] = string.format("%s=%s", Reason, tostring(Count))
	end

	table.sort(Parts)

	local function Metres(Value)
		if not Value then
			return "-"
		end

		return string.format("%.0f", Value)
	end

	local Walk = string.format(", walk %s-%sm over %s, %s unreachable, %s under the %sm base-room floor, base=%s, selfPath=%s",
		Metres(Stats.walkMin), Metres(Stats.walkMax), tostring(Stats.walked or 0),
		tostring(Stats.unreachable or 0), tostring(Stats.tooClose or 0),
		tostring(Stats.lineFloor or "-"), tostring(Stats.base or "-"), tostring(Stats.selfPath or "-"))

	local How = string.format("%s usable (%s at point, %s nearby, mesh %s generated, %s anchor probes)%s",
		tostring(Stats.usable), tostring(Stats.atPoint or 0), tostring(Stats.nearPoint or 0),
		tostring(Stats.sampled or 0), tostring(Stats.probes or 0), Walk)

	if Stats.candidates then
		How = string.format("%s -> %s after %sm dedupe", How, tostring(Stats.candidates),
			tostring(Stats.separation or 5))
	end

	return string.format("%s examined, %s%s", tostring(Stats.raw), How,
		#Parts > 0 and (", " .. table.concat(Parts, ", ")) or "")
end

local function AngleFrom(Point, Origin)
	local Angle = math.atan2(Axis(Point, "z", 3) - Axis(Origin, "z", 3), Axis(Point, "x", 1) - Axis(Origin, "x", 1))

	if Angle < 0 then
		Angle = Angle + kTwoPi
	end

	return Angle
end

--- The band, adaptive.
---
--- A strict ring that selects nothing would leave a horde with no mouths and no explanation, so
--- when the ring is empty we take the nearest PoolSize candidates at least BandMin away by the
--- SAME measure the ring used - never closer, because "inside the base room" is the one thing
--- the band exists to prevent.
---
--- `DistanceFn` is a parameter because the measure IS the decision. Straight-line metres answer
--- "how far from the chair does it look"; a horde answers "how far does it walk", and on a cave
--- map those differ by multiples. Measured on ns2_summit in straight-line metres: 24 buildable
--- points, exactly one inside 56-90, and that one with no route to it.
function Placement.FilterBand(Candidates, Base, BandMin, BandMax, PoolSize, DistanceFn)
	local InBand, Beyond = {}, {}

	local Measure = DistanceFn or Placement.Distance2D

	for _, Candidate in ipairs(Candidates or {}) do
		local Distance = Base and Measure(Candidate.point, Base) or nil

		if Distance and Distance >= BandMin and Distance <= BandMax then
			InBand[#InBand + 1] = { point = Candidate.point, distance = Distance }
		elseif Distance and Distance >= BandMin then
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

--- Metres ALONG the nav mesh from one point to another, or nil when there is no route. This is
--- the engine's own answer to "can anything walk here" - the call bots steer by
--- (BotMotion.lua:137-140) - so a mouth we place is a mouth a horde can leave, and the number
--- the band filters on is the number a player experiences.
---
--- `PathFn` returns `reachable, points`, and the split matters: GetPathPoints hands back the
--- route WITHOUT its start point (Cyst.lua:176 prepends it by hand - "always include the
--- starting point in this path for convenience"), so a zero-length route is a successful query
--- with an empty array. Reading "no points" as "no route", which this file did, reported every
--- candidate on the map as unreachable and placed nothing while logging what looked like a map
--- problem.
function Placement.PathDistance(From, To, PathFn)
	if not PathFn then
		return nil
	end

	local Ok, Reachable, Points = pcall(PathFn, From, To)

	if not Ok or not Reachable then
		return nil
	end

	local Total, Previous = 0, From

	if Points then
		for Index = 1, #Points do
			local Next = Points[Index]

			Total = Total + Placement.Distance2D(Previous, Next)
			Previous = Next
		end
	end

	-- The tail from the last mesh point to the target itself: a path ends at the nearest
	-- position on the mesh, so leaving this out under-reads every candidate standing off-mesh.
	-- For a same-point query this is the entire distance, and it is correctly zero.
	return Total + Placement.Distance2D(Previous, To)
end

--- Pathing.GetPathPoints(start, end, PointArray) -> boolean (Cyst.lua:171). Called through an
--- injected function so the pure tests never touch the engine and a map with no nav mesh
--- reports "unreachable" instead of throwing through the wave.
---
--- The yes/no half of the same question, kept for callers that only need reachability and for
--- the tests that inject a boolean. Placement's own band goes through PathDistance above, which
--- measures the route instead of merely approving it.
function Placement.Reachable(From, To, PathingFn)
	if not PathingFn then
		return true
	end

	local Ok, Result = pcall(PathingFn, From, To)

	return Ok and Result == true
end

--- One mouth per sector, nearest first, so a wave cannot arrive down a single corridor. With no
--- base anchor the sector idea is meaningless, so fall back to the first Count candidates rather
--- than rejecting the wave.
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

--- Where candidates come from, before anyone asks whether the ground is real.
---
--- Anchors (infestation portals, cysts, Location volumes) were the wrong source on the shipped
--- map: their origins are volume markers, and on ns2_summit 42 of 48 failed the engine's build
--- check while the survivors left exactly one point inside the ring - so a wave placed nothing
--- and every geometric assertion we had stayed green.
---
--- So sweep the neighbourhood the way a commander sweeps a cursor: rings at fixed bearings, each
--- point pulled onto the nav mesh by Pathing.GetClosestPoint before anything asks whether it is
--- buildable. Whether it IS buildable remains the engine's answer; this only decides where to ask.
local kSampleRadii = 6
local kSampleDirections = 16

--- Near edge of the sweep, deliberately inside the band. The band is measured in WALKING metres,
--- and a point 30 m away in a straight line can easily be 60 m of walking, so a sweep starting at
--- BandMin would never generate the candidates the band exists to select.
local kSampleNearFloor = 20

--- Far edge, as a multiple of BandMax. Routes climb and detour, so the walk to a point can be
--- several times the line to it; a sweep stopping at BandMax would never reach the ground that
--- is BandMax of walking away.
local kSampleReachFactor = 1.6

function Placement.SampleRing(Base, BandMin, BandMax, Hooks)
	local Out = {}

	if not Base then
		return Out
	end

	Hooks = Hooks or Placement.DefaultHooks()

	if not Hooks.Mesh then
		return Out
	end

	local First = math.min(BandMin or 0, kSampleNearFloor)
	local Last = math.max(BandMax or First, (BandMax or 0) * kSampleReachFactor)
	local Steps = math.max(kSampleRadii - 1, 1)
	local BaseX, BaseY, BaseZ = Axis(Base, "x", 1), Axis(Base, "y", 2), Axis(Base, "z", 3)

	for Ring = 0, Steps do
		local Radius = First + ((Last - First) * Ring / Steps)

		for Step = 0, kSampleDirections - 1 do
			local Angle = (kTwoPi * Step) / kSampleDirections

			local Ok, OnMesh = pcall(Hooks.Mesh,
				At(BaseX + math.cos(Angle) * Radius, BaseY, BaseZ + math.sin(Angle) * Radius))

			if Ok and OnMesh then
				Out[#Out + 1] = OnMesh
			end
		end
	end

	return Out
end

--- Engine-facing half: gather anchors, sweep the mesh around the base, keep only the points the
--- engine says a structure could stand on, then hand the survivors to the pure functions.
---
--- Returns chosen (each {point, distance}), the base anchor, the total points offered, the
--- post-band count, and the tallies.
function Placement.Collect(Config, PathingFn, Hooks)
	local Waves = (Config and Config.Waves) or {}
	local BandMin = Waves.BandMin or 56
	local BandMax = Waves.BandMax or 90
	local PoolSize = Waves.PoolSize or 6
	local PerWave = Waves.ActivePerWave or 3

	local Raw = {}
	local ChairList = {}
	local Infestations = {}

	--- One anchor class at a time. The command chair is gathered for a different purpose (it is
	--- the distance origin) and is never offered as a mouth anchor: a mouth on top of the command
	--- station is the one thing the band exists to prevent. Infestation portals serve both roles -
	--- they are real floor points, and their centroid is the fallback anchor on a map with no
	--- chair.
	local function AddClass(ClassName, Sink, AsAnchor)
		for _, Ent in ientitylist(Shared.GetEntitiesWithClassname(ClassName)) do
			local Ok, Origin = pcall(function() return Ent:GetOrigin() end)

			if Ok and Origin then
				if Sink then
					Sink[#Sink + 1] = Origin
				end

				if AsAnchor then
					Raw[#Raw + 1] = Origin
				end
			end
		end
	end

	AddClass("CommandStructure", ChairList, false)
	AddClass("InfestationPortal", Infestations, true)
	AddClass("Cyst", nil, true)
	AddClass("Location", nil, true)

	local Base = Placement.GetBaseAnchor(ChairList[1], Infestations)

	Hooks = Hooks or Placement.DefaultHooks()

	--- Sweep the mesh first, take anchors only if it was not enough. A floor the nav mesh admits
	--- beats a cyst's origin every time, and the common case should not pay for the fallback.
	local Want = PoolSize * 4
	local MeshPoints = Placement.SampleRing(Base, BandMin, BandMax, Hooks)
	local Validated, Stats = Placement.ValidateCandidates(MeshPoints, Hooks, Want)

	Stats.sampled = #MeshPoints

	if #Validated < Want then
		local FromAnchors, AnchorStats = Placement.ValidateCandidates(Raw, Hooks, Want - #Validated)

		Placement.MergeStats(Stats, AnchorStats)

		for _, Item in ipairs(FromAnchors) do
			Validated[#Validated + 1] = Item
		end
	end

	--- Points, not records, handed to the dedupe. This is where 24 buildable points turned into
	--- one candidate: a record has no x or z, so every distance measured as zero, the whole list
	--collapsed inside MinSeparation of itself, and the log reported the resulting "in band 0" as
	--- if the map had nothing to offer. GatherCandidates now tolerates both shapes, and this
	--- passes the shape that was always meant to arrive.
	local CandidatePoints = {}

	for _, Item in ipairs(Validated) do
		CandidatePoints[#CandidatePoints + 1] = Item.point
	end

	local Candidates = Placement.GatherCandidates({ CandidatePoints }, 5)

	Stats.candidates = #Candidates

	--- `reachable, points`, never a bare array: an empty route is a success, and collapsing the
	--- two made every candidate look unreachable (see PathDistance).
	if not PathingFn then
		PathingFn = function(From, To)
			local Points = PointArray()
			local Reachable = Pathing.GetPathPoints(From, To, Points)

			return Reachable, Points
		end
	end

	--- Measure from wherever the nav mesh says the floor is rather than from the command
	--- station's origin. A structure's origin sits inside its own footprint and the mesh under it
	--- is carved out, so a route asked to START there has no polygon to leave from.
	local PathBase = Base

	if Base then
		local Ok, OnMesh = pcall(Hooks.Mesh, Base)

		if Ok and OnMesh then
			PathBase = OnMesh
		end
	end

	Stats.base = Base and "anchor" or "none"

	if Base and PathBase ~= Base then
		Stats.base = "anchor+mesh"
	end

	--- Recorded as the raw boolean rather than ok/nil: this is the line that distinguishes
	--- "pathing does not work from here" from "this base is smaller than the band", and the two
	--- need different fixes even though both produce an empty pool.
	do
		local Ok, Reachable = pcall(function()
			local Points = PointArray()

			return Pathing.GetPathPoints(PathBase, PathBase, Points)
		end)

		if not Ok then
			Stats.selfPath = "threw"
		else
			Stats.selfPath = tostring(Reachable)
		end
	end

	--- One path query per candidate doing both jobs: it is the band's measure and the
	--- reachability test at once, since "no route" is just an infinite distance. Querying twice -
	--- once to filter, once to confirm - would double the call BotUtils.lua:357 annotates as
	--- "Expensive !!!" to learn nothing new.
	--- Both measures, because the walking ring alone reopens the hole the ring exists to close:
	--- a route can leave the base, loop a room and come back, so "56 m of walking" is satisfied
	--- by a mouth standing 5 m from the chair behind a wall. The floor is a fraction of BandMin
	--- rather than a second number to tune - it says "not inside the base room", not "how hard is
	--- wave 3" - and it rejects at the measure, so the adaptive fallback cannot reach it either.
	local LineFloor = BandMin * (Waves.BandLineFactor or 0.5)
	Stats.lineFloor = string.format("%.0f", LineFloor)

	local function WalkDistance(Point, From)
		if Placement.Distance2D(Point, From) < LineFloor then
			Stats.tooClose = (Stats.tooClose or 0) + 1

			return nil
		end

		local Distance = Placement.PathDistance(PathBase, Point, PathingFn)

		if not Distance then
			Stats.unreachable = (Stats.unreachable or 0) + 1

			return nil
		end

		Stats.walked = (Stats.walked or 0) + 1
		Stats.walkMin = math.min(Stats.walkMin or Distance, Distance)
		Stats.walkMax = math.max(Stats.walkMax or Distance, Distance)

		return Distance
	end

	local Banded = Base
		and Placement.FilterBand(Candidates, Base, BandMin, BandMax, PoolSize, WalkDistance)
		or Candidates

	-- Both sources counted, because the caller's log line names the total it was offered.
	return Placement.SelectSectorSpread(Banded, Base, PerWave), Base, #MeshPoints + #Raw, #Banded, Stats
end

Plugin.Placement = Placement

return Placement
