--[[ Horde Mode — Spawner (i4b + i5a).

 Mouth and bot creation and destruction. Attaches as Plugin.Spawner and is owned by the
 plugin instance, so the registry it writes to is the same one teardown walks.

 The one non-obvious rule: a freshly created entity has no usable id until the next
 tick, and Registry:Register refuses it (registry.lua:93 - "registered in the same
 tick as creation?"). Inventing a key instead is not an option: a made-up negative id
 fed back to Shared.GetEntity returns nil, which previously produced a false
 "destroyed" finding in this project. So SpawnMouth queues, and Pump() - called from
 the plugin's tick - registers once the id is real.

 i5a applies that rule TWICE over: a PlayerBot queues exactly like a mouth, and its
 PLAYER is a second delay on top of the id - the engine joins the team and spawns the
 player over ~6 s (spike i0f). So Pump() registers whatever has an id, and PlaceBots()
 - run by the same pump - teleports a registered bot to its mouth only once the player
 is live AND already on the alien team.

 Replaces the i0a stub. ]]
local Plugin = ...

local Spawner = {}
Spawner.__index = Spawner

-- Alien tunnels belong to team 2; kAlienTeamIndex is the engine constant, with the
-- literal as a fallback so a headless boot without Globals ordering cannot nil it.
local kAlienTeam = kAlienTeamIndex or 2

-- A mouth that still has no id after this many ticks is not coming; report it rather
-- than queueing it forever.
local kMaxPendingTicks = 10

-- The emergence jitter, in metres. Spike tby teleported a PlayerBot to a mouth point
-- with ±1 m of jitter and the bot stood AT the mouth, so this number is measured, not
-- tuned. It is mechanics, not balance: no RD3 owed number lives here.
local kBotJitter = 1

--- `Reveal` is Debug.RevealMouths, resolved by the owner and stored here - ONE place.
--- The first version took it per SpawnMouth call while the plugin tick re-asserted every
--- mouth in the registry from a different field, so a mouth explicitly built unrevealed
--- was revealed anyway one second later. The suite caught it; the design was wrong.
function Spawner.New(Registry, Log, Reveal)
	return setmetatable({
		Registry = Registry,
		Log = Log or print,
		Pending = {},
		Placing = {},
		MouthCount = 0,
		BotCount = 0,
		PlacedCount = 0,
		FailedCount = 0,
		Reveal = Reveal == true
	}, Spawner)
end

--- HP scaling hook. v0 ships curves disabled (RD3: balance numbers are Arian's and
--- still owed), so the multiplier is 1.0 and this must not touch the entity at all -
--- calling SetHealth with a placeholder would silently bake fake balance into a
--- "working" slice.
function Spawner:ApplyMouthHealth(Mouth, Multiplier)
	if not Multiplier or Multiplier == 1 then
		return false
	end

	if not Mouth or not Mouth.SetHealth then
		return false
	end

	local Base = Mouth.GetMaxHealth and Mouth:GetMaxHealth() or nil

	if not Base then
		return false
	end

	Mouth:SetHealth(Base * Multiplier)

	return true
end

--- Reveal a mouth to the enemy team. `DetectableMixin:SetDetected(true)` is the engine's own
--- "someone can see this" switch, and the only thing it changes for us is that
--- `UpdateSensorBlip` creates a `SensorBlip` for the entity (DetectableMixin.lua:20-51):
--- a marine-team-relevant marker (SensorBlip.lua:35) that every marine client draws as a
--- through-wall screen blip (Marine_Client.lua:42-100 - its occlusion trace is commented
--- out) and as a minimap icon (SensorBlip.lua:54-64). So we add no entity, no message type
--- and no client Lua, and the marker is not shootable, not a Structure and not counted by
--- any team logic. Detection expires after 1.5 s on its own, so this must be re-asserted -
--- see RefreshReveal.
function Spawner:RevealMouth(Mouth)
	if not Mouth then
		return false
	end

	--- pcall rather than a bare field test, because `Mouth.SetDetected` IS the access that
	--- throws on a destroyed entity - the exact line (spawner.lua:76) that took the world tick
	--- down on 2026-09-26 and cost two living mouths their minimap markers. The registry now
	--- refuses to hand a corpse to this loop, so what is left is the engine destroying one
	--- between that check and this call, and the price of that must be one marker, not the
	--- timer that holds every marker up.
	local Ok, Revealed = pcall(function()
		if not Mouth.SetDetected then
			return false
		end

		Mouth:SetDetected(true)

		return true
	end)

	return Ok and Revealed and true or false
end

--- Re-assert the reveal on every live mouth this spawner owns. The plugin's 1 s tick is
--- the caller in production, and the interval is the point: detection expires 1.5 s after
--- it was last asserted (DetectableMixin.lua:98-105), so a reveal set once at spawn would
--- vanish between waves. Returns the count it re-asserted - a number the suite can assert
--- on rather than a line in a log.
function Spawner:RefreshReveal()
	if not self.Reveal or not self.Registry then
		return 0
	end

	local Revealed = 0

	-- IterateByKind only visits what the engine still has, so a mouth the player killed stops
	-- being re-asserted the moment it stops existing - and no longer takes the tick with it.
	self.Registry:IterateByKind("mouth", function(Ref)
		if self:RevealMouth(Ref) then
			Revealed = Revealed + 1
		end
	end)

	return Revealed
end

--- Create an unpaired tunnel entrance at Point. Unpaired is intentional: spike tby
--- established mouths survive indefinitely without a partner, which is what lets a wave
--- place them one at a time.
---
--- The point is snapped HERE as well as in placement.Collect, because SpawnMouth is a public
--- seam: the wave loop, the scenarios and any per-map override all call it directly, and a
--- mouth that materialises in solid rock reads to a player as "the mode is broken". The snap is
--- the engine's own build check (ground capsule, nav-mesh walk flag, obstacle capsule), so
--- "a gorge could not have built it there" is the standard - which is what a marine judges by.
--- Fails CLOSED: no placement module means no mouth, not an unvalidated one.
function Spawner:SpawnMouth(Point, HealthMultiplier)
	if not Point then
		return nil, "no point given"
	end

	local Placement = Plugin.Placement

	if not Placement or not Placement.SnapToSurface then
		self.FailedCount = self.FailedCount + 1
		self.Log("[HORDE] mouth NOT placed: placement module is unavailable to validate the surface")

		return nil, "no surface validation available"
	end

	local Snapped, Reason = Placement.SnapToSurface(Point)

	if not Snapped then
		self.FailedCount = self.FailedCount + 1
		self.Log(string.format("[HORDE] mouth NOT placed at (%.1f, %.1f, %.1f): %s",
			Placement.Axis(Point, "x", 1), Placement.Axis(Point, "y", 2), Placement.Axis(Point, "z", 3),
			tostring(Reason)))

		return nil, Reason
	end

	local Ok, Mouth = pcall(function()
		local Entity = CreateEntity(TunnelEntrance.kMapName, Snapped, kAlienTeam)

		if Entity and Entity.SetConstructionComplete then
			Entity:SetConstructionComplete()
		end

		return Entity
	end)

	if not Ok or not Mouth then
		self.FailedCount = self.FailedCount + 1
		self.Log(string.format("[HORDE] mouth spawn failed: %s", tostring(Mouth)))

		return nil, "spawn failed"
	end

	self:ApplyMouthHealth(Mouth, HealthMultiplier)

	self.Pending[#self.Pending + 1] = { ref = Mouth, kind = "mouth", Ticks = 0 }
	self.MouthCount = self.MouthCount + 1

	-- Revealed at creation, not after registration, so the marker exists for the first frame
	-- a marine could plausibly look this way; RefreshReveal keeps it alive from then on.
	if self.Reveal then
		self:RevealMouth(Mouth)
	end

	return Mouth
end

--- An emergence point: the mouth's own (already surface-validated) point plus up to
--- kBotJitter metres of jitter on each horizontal axis. y is quartered because the
--- anchor is a snapped surface and gravity settles the rest. Now the FALLBACK branch
--- only - see EmergenceSpot for why the arithmetic lost.
local function EmergencePoint(Point)
	local function Off(Scale)
		return (math.random() * 2 - 1) * Scale
	end

	return Vector(Point.x + Off(kBotJitter), Point.y + Off(kBotJitter * 0.25), Point.z + Off(kBotJitter))
end

--- Where a bot actually stands: the engine's own egg recipe (Hive_Server.lua:505-511) -
--- a point within the ring where a capsule of the creature's size FITS, asked of the
--- physics and nav mesh, not of our arithmetic. The chair (2026-09-30) proved the old
--- ±1 m jitter wrong in a way no headless assert could see: the tunnel's ORIGIN is
--- inside its own shell (entrances sit at local (3, 0.5, ±11) - Tunnel.lua:49-50), so
--- bots materialised embedded in geometry, pathing found no valid start, and they
--- stood at the mouth forever while the registry - correctly - counted them ALIVE.
--- That is also the "count does not match what I see" report: the bots WERE there,
--- inside the shell, invisible. If the engine's fit search fails (no room in the
--- ring), the jitter fallback keeps the bot VISIBLE at the mouth and the log says
--- which branch ran - the chair can then tell us which map and mouth produced it.
local kEmergenceMin, kEmergenceMax = 1, 10

local function EmergenceSpot(Point)
	-- Rebuild the anchor as a fresh native Vector from its components: the entrance
	-- position is a COMPUTED vector (origin + coords:TransformVector(...)), and the
	-- pathing bind refused exactly that userdata ("cannot convert 'userdata' to
	-- 'const struct Vector &'", seen 2026-09-30). Components are numbers either way.
	local Base = Vector(Point.x, Point.y, Point.z)

	local function WalkableSpot(Spot)
		-- The SAME validation the mouths pass (Placement.SnapToSurface: ground snap,
		-- walk flag, no-build, obstacle capsule at 1.2 extents) - the first bot-side
		-- query invented its own convention (a 0.3 box at +0.5) and rejected every
		-- point the engine itself had certified, because GetIsFlagSet is only proven
		-- at the extents and heights this module measured it at. One convention, the
		-- working one. Returns the SNAPPED point (where a capsule actually stands).
		local Ok, Snapped = pcall(function()
			return Plugin.Placement.SnapToSurface(Spot, Plugin.Placement.DefaultHooks())
		end)

		if Ok and Snapped then
			return Snapped
		end
	end

	-- The EGG's capsule, deliberately: it is the size the engine itself clears
	-- around hive and tunnel for aliens to pop out of, and lifeform techs do not
	-- carry reliable extents. EVERY engine call inside the pcall - the first version
	-- left the fit search outside, and one bind rejection threw through the whole
	-- placement and dropped all four bots unplaced.
	local Ok, Height, Radius = pcall(function()
		local Extents = LookupTechData(kTechId.Egg, kTechDataMaxExtents, nil)

		if not Extents then
			return nil
		end

		return GetTraceCapsuleFromExtents(Extents)
	end)

	if Ok and Height then
		-- CAPSULE-FIT ALONE IS NOT ENOUGH: the egg search certifies physics room, not
		-- the nav mesh (eggs are structures; a skulk off-mesh cannot path anywhere -
		-- measured 2026-09-30, every egg-fit point failed the walk check the mouths
		-- pass). So each candidate must also clear the placement validation, and the
		-- bot is placed at the SNAPPED point, not the raw candidate.
		for _ = 1, 8 do
			local FitOk, Fit = pcall(GetRandomSpawnForCapsule, Height, Radius, Base,
				kEmergenceMin, kEmergenceMax, EntityFilterAll())

			if not FitOk or not Fit then
				break
			end

			local Standing = WalkableSpot(Fit)

			if Standing then
				return Standing, "fit"
			end
		end
	end

	-- Jitter around the ENTRANCE anchor, which sits on the mouth's own validated
	-- (walk-flagged) build surface - the fallback is more on-mesh than it looks.
	return EmergencePoint(Base), "jitter"
end

--- Resolve a mouth's ENTRANCE at the moment of use. The tunnel's origin sits inside
--- its own shell (entrances are local (3, 0.5, ±11) - Tunnel.lua:49-50) and the interior
--- is HOLLOW, so both older designs failed in measured ways: jitter around the origin
--- embedded the bots (the chair's "stuck at the mouth"), and resolving the entrance on
--- the SPAWN tick threw out of `GetEntranceAPosition` (orientation is not settled yet -
--- seen 2026-09-30) and silently downgraded every anchor to the raw entity. So: ask at
--- placement time, several ticks after the mouth exists, and keep the spawn-time origin
--- as the named fallback rather than pretending the question cannot fail.
local function MouthAnchor(Mouth, Fallback)
	if Mouth then
		local Ok, Entrance = pcall(function()
			return Mouth:GetEntranceAPosition()
		end)

		if Ok and Entrance then
			return Entrance
		end
	end

	return Fallback
end

--- Create an alien bot that will emerge at a mouth (i5a). The recipe is spike e8o's,
--- re-verified against the shipped Lua before anything was written down here:
---   * `Server.CreateEntity(PlayerBot.kMapName)` - the no-origin overload; the
---     positional 3-arg global CreateEntity is for entities that have one, and a
---     fresh Bot has no place in the world yet.
---   * `Initialize(kAlienTeam, true)` - active, because a passive bot never thinks.
---   * `lifeformEvolution` set AFTER Initialize: Initialize nils the field for an
---     alien team (Bot_Server.lua:70-72), and the brain overwrites it only while it
---     is nil (CommonAlienActions.lua:659), so a value set here survives and forces
---     the type.
---
--- Like a mouth, a fresh PlayerBot has no usable id in its creation tick, so it
--- queues and Pump() registers it. The mouth rides along because placement needs it
--- one delay LATER again: GetPlayer() answers only after the engine's own UpdateTeam
--- has joined and spawned the bot - and the ENTRANCE anchor is only trustworthy at
--- that later moment either (see MouthAnchor). This returns before the bot is in the
--- world on purpose - the pump is what finishes the job.
function Spawner:SpawnBot(MouthOrPoint, TechId)
	if not MouthOrPoint then
		self.FailedCount = self.FailedCount + 1

		return nil, "no point given"
	end

	-- Entity or raw point: keep both readings. The origin answers on the creation
	-- tick (position exists before orientation does); the entrance is asked later.
	local Mouth, Point

	local OkOrigin, Origin = pcall(function()
		if MouthOrPoint.GetOrigin then
			return MouthOrPoint:GetOrigin()
		end
	end)

	if OkOrigin and Origin then
		Mouth, Point = MouthOrPoint, Origin
	else
		Point = MouthOrPoint
	end

	local Ok, Bot = pcall(function()
		local Entity = Server.CreateEntity(PlayerBot.kMapName)

		if not Entity then
			error("Server.CreateEntity returned no PlayerBot")
		end

		Entity:Initialize(kAlienTeam, true)
		Entity.lifeformEvolution = TechId or kTechId.Skulk

		return Entity
	end)

	if not Ok or not Bot then
		self.FailedCount = self.FailedCount + 1
		self.Log(string.format("[HORDE] bot spawn failed: %s", tostring(Bot)))

		return nil, "bot spawn failed"
	end

	self.Pending[#self.Pending + 1] = { ref = Bot, kind = "bot", mouth = Mouth, point = Point, Ticks = 0 }
	self.BotCount = self.BotCount + 1

	return Bot
end

--- Teleport every registered-but-unpositioned bot to its mouth. The gate is FOUR
--- conditions, not one: GetPlayer() may answer nil at all (the player materialises on
--- a later frame), a team-0 player means vanilla's join gate has not landed the bot -
--- which we force here, because the horde is unbalanced by design (see the measured
--- note below), a player that exists but has not finished spawning is not alive, and
--- a bot that never reached team 2 must not be placed as a spectator ghost. Moving
--- only a LIVE TEAM-2 alien also keeps the engine's own spawn move from undoing the
--- teleport afterwards. Every handle read is inside pcall: the bot can die between the
--- registry saying "alive" and this asking it, and one throw in the tick would take
--- the reveal and the prune down with it - that exact incident is
--- Shared/lessons/never-dereference-a-stored-handle.
---
--- Returns the number placed this pass. Entries that never materialise are reported
--- and dropped after kMaxPendingTicks pumps - never retried forever, never silently.
function Spawner:PlaceBots()
	local Still = {}
	local Placed = 0

	for _, Item in ipairs(self.Placing) do
		local Ok, Landed, Spot, How = pcall(function()
			local Player = Item.ref.GetPlayer and Item.ref:GetPlayer()

			if not Player then
				return false
			end

			-- Measured 2026-09-28, and the reason this block is four gates, not one: with
			-- `force_even_teams_on_join` on (it is, in this server's own ServerConfig.json),
			-- NS2Gamerules:GetCanJoinTeamNumber (:1385-1423) REFUSES any join that would
			-- unbalance the teams - so on a headless boot with one marine bot and four alien
			-- bots, vanilla's own Bot:UpdateTeam retries forever and the surplus aliens sit
			-- at team=0, alive=true, FOREVER ("alive" includes the spectator a virtual
			-- client controls; it has never implied "joined"). The horde is deliberately
			-- unbalanced - that is what the bot takeover means - so the factory joins the
			-- way the takeover already implies: forcing past the balance gate. Spike v4 had
			-- already shown an explicit gamerules:JoinTeam lands a bot on team 2.
			if Player.GetTeamNumber and Player:GetTeamNumber() == 0 then
				local Rules = GetGamerules()

				if Rules and Rules.JoinTeam then
					Rules:JoinTeam(Player, kAlienTeam, true)

					-- force-join REPLACES the player entity (ReplaceRespawnPlayer ->
					-- player:Replace, and for aliens respawnEntity = Skulk,
					-- AlienTeam.lua:48 - the lifeform class is real in the same tick, no
					-- evolve race), so the old handle is not what controls the client now.
					Player = Item.ref:GetPlayer()
				end
			end

			if not Player or (Player.GetIsAlive and not Player:GetIsAlive()) then
				return false
			end

			-- A refused join (slots full, gamerules mid-reset) leaves the bot spectator:
			-- placing a team-0 player at a mouth would be a marine-visible ghost. Wait.
			if Player.GetTeamNumber and Player:GetTeamNumber() ~= kAlienTeam then
				return false
			end

			-- Anchor asked NOW, not at spawn: the entrance is trustworthy ticks after
			-- the tunnel exists; the spawn-time origin is the named fallback.
			local Placed, Method = EmergenceSpot(MouthAnchor(Item.mouth, Item.point))
			Player:SetOrigin(Placed)

			return true, Placed, Method
		end)

		if Ok and Landed then
			Placed = Placed + 1
			self.PlacedCount = self.PlacedCount + 1

			-- The spot the bot ACTUALLY landed on, not the anchor it was asked for,
			-- and WHICH branch placed it: "(capsule-fit)" or the loud "(JITTER
			-- FALLBACK)" is the difference between "stuck in the shell" and
			-- "stuck beside it" - the chair can read it without opening the log.
			self.Log(string.format("[HORDE] bot emerged at (%.1f, %.1f, %.1f) id=%s %s",
				Plugin.Placement.Axis(Spot, "x", 1), Plugin.Placement.Axis(Spot, "y", 2),
				Plugin.Placement.Axis(Spot, "z", 3), tostring(Item.id),
				How == "fit" and "(capsule-fit)" or "(JITTER FALLBACK - no fit in the ring)"))
		elseif not Ok then
			self.FailedCount = self.FailedCount + 1
			self.Log(string.format("[HORDE] a bot went away before it could emerge: %s", tostring(Landed)))
		else
			Item.Ticks = Item.Ticks + 1

			if Item.Ticks >= kMaxPendingTicks then
				self.FailedCount = self.FailedCount + 1
				self.Log(string.format("[HORDE] gave up placing bot id=%s: no live alien player after %s pumps",
					tostring(Item.id), tostring(kMaxPendingTicks)))
			else
				Still[#Still + 1] = Item
			end
		end
	end

	self.Placing = Still

	return Placed
end

--- Register everything created on a previous tick, then position the bots that got
--- registered. Returns how many were registered.
function Spawner:Pump()
	local Registered = 0
	local Still = {}

	for _, Item in ipairs(self.Pending) do
		local Id, Reason

		if self.Registry then
			Id, Reason = self.Registry:Register(Item.ref, Item.kind)
		end

		if Id then
			Registered = Registered + 1

			-- A registered bot may still have no player: it moves to the placement
			-- queue, which every later pump walks until the engine has a live alien
			-- for it. Mouths are positioned by their own creation; only bots need
			-- this second stage.
			if Item.kind == "bot" then
				self.Placing[#self.Placing + 1] = { id = Id, ref = Item.ref, mouth = Item.mouth, point = Item.point, Ticks = 0 }
			end
		else
			Item.Ticks = Item.Ticks + 1

			if Item.Ticks >= kMaxPendingTicks then
				self.FailedCount = self.FailedCount + 1
				self.Log(string.format("[HORDE] gave up registering a %s after %s ticks: %s",
					Item.kind, tostring(kMaxPendingTicks), tostring(Reason)))
			else
				Still[#Still + 1] = Item
			end
		end
	end

	self.Pending = Still

	self:PlaceBots()

	return Registered
end

function Spawner:PendingCount()
	return #self.Pending
end

--- Spawns the factory still owns: queued for registration or waiting on their
--- player. The wave-clear predicate needs this - a bot that has not materialised
--- is neither alive nor dead, and a wave counting zero alive while spawns are
--- outstanding would clear itself before its first alien existed.
function Spawner:Outstanding()
	return #self.Pending + #self.Placing
end

--- Kill + destroy by registry id. Kill() alone leaves the entity in the world for the
--- frame, which is enough to make an entity-count diff lie, so both are called.
function Spawner:DestroyMouth(Id)
	local Ref = self.Registry and self.Registry:Get(Id)

	if not Ref then
		return false
	end

	pcall(function()
		if Ref.Kill then Ref:Kill() end

		DestroyEntity(Ref)
	end)

	if self.Registry then
		self.Registry:Unregister(Id)
	end

	return true
end

--- Queued-but-unregistered refs are still ours: they exist in the world and no book
--- keeps them. Teardown must destroy them or the slice leaks a mouth per stop.
---
--- Placing (registered, not yet positioned) bots are deliberately NOT returned here:
--- they hold genuine ids the registry already tracks, so teardown drains them from
--- there - returning them too would make DestroyAll disconnect the same bot twice.
--- The queue is dropped so a later tick cannot try to teleport a bot that teardown
--- has already destroyed.
function Spawner:TakePending()
	local Out = self.Pending

	self.Pending = {}
	self.Placing = {}

	return Out
end

function Spawner:PendingCount()
	return #self.Pending
end

Plugin.Spawner = Spawner

return Spawner
