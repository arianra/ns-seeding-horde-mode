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

-- A bot whose virtual client never materialised is re-dealt at its mouth this many
-- times before the wave accepts the loss and says so. Bounded so a map that reliably
-- fails to spawn cannot loop forever.
local kMaxBotRetries = 3

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

--- Where a bot actually stands. The mouth's own BUILD POINT is the only position we
--- know is good — `SpawnMouth` snapped it through the engine's build gate (walk mesh,
--- ground, no obstacle), so the ground under it is walkable by construction. Two earlier
--- anchors failed in measured ways: jitter around the raw origin embedded bots in the
--- shell (2nd chair pass), and the tunnel's ENTRANCE — 11 m away at local (3, 0.5, -11),
--- `Tunnel.lua:49` — is reliable only for a PAIRED tunnel whose far end also reaches the
--- surface. Our mouths are UNPAIRED, so the entrance is in rock, the capsule-fit ring
--- around it found no spot ("no fit in the ring" on nearly every bot, 3rd chair pass),
--- and the ±0.25 m y-jitter fallback then dropped them BELOW the floor (y going -0.2,
--- -0.7). So: a small horizontal fan around the build point, dropped onto the surface by
--- the engine's own downward capsule trace — it can land on the tunnel floor or the
--- surrounding mesh, but never underground, because it traces DOWN to a surface.
local function EmergenceSpot(Point)
	local dx = (math.random() * 2 - 1) * kBotJitter
	local dz = (math.random() * 2 - 1) * kBotJitter

	local above = Vector(Point.x + dx, Point.y + 2, Point.z + dz)
	local Ok, Ground = pcall(function()
		return GetGroundAtPointWithCapsule(above, Vector(0.5, 0.5, 0.5),
			PhysicsMask.CommanderBuild, CreateFilter(nil))
	end)

	if Ok and Ground then
		return Ground, "ground"
	end

	-- No ground found (should not happen at a validated point): place AT the point,
	-- never below it. A bot at the mouth is recoverable; one under the map is not.
	return Vector(Point.x + dx, Point.y, Point.z + dz), "raw"
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
--- Like a mouth, a fresh PlayerBot has no usable id in its creation tick, so it queues
--- and Pump() registers it. Placement needs the bot one delay LATER still: GetPlayer()
--- answers only after the engine's own UpdateTeam has joined and spawned it. The mouth
--- entity and the requested tech ride along so a bot that vanishes before it ever
--- materialised can be re-dealt at the SAME mouth as the SAME type. This returns before
--- the bot is in the world on purpose - the pump is what finishes the job.
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

	self.Pending[#self.Pending + 1] = { ref = Bot, kind = "bot", mouth = Mouth, point = Point, tech = TechId or kTechId.Skulk, Ticks = 0 }
	self.BotCount = self.BotCount + 1

	return Bot
end

--- Swap a live team-2 Skulk bot to its requested higher lifeform, in place. Returns the new
--- player, or nil to leave it a skulk.
---
--- Why not the vanilla morph: `Alien:ProcessBuyAction` routes through `AlienUpgradeManager:AddUpgrade`,
--- which requires `GetIsUpgradeAllowed` AND `GetCanAffordUpgrade` (AlienUpgradeManager.lua:236-239).
--- A horde alien has no hive (nothing researched) and no resources, so a gorge/lerk/fade/onos is
--- never "allowed" - the morph path is closed to us. (Gestation itself is a timer, not a hive -
--- Embryo.lua:143 - but you cannot START it without the tech being allowed.)
---
--- So we swap the entity class directly with `Player:Replace` - the same primitive the forced join
--- and the gestation completion both use. The caller has ALREADY set the skulk onto the mouth's
--- validated emergence ground, and no higher lifeform's capsule exceeds the skulk's ground probe
--- (gorge 0.50x0.47x0.50 vs the 0.5x0.5x0.5 capsule `EmergenceSpot` clears), so the swap happens
--- where a skulk already fits - never embedded. Full health comes free: `CopyPlayerDataFrom` does
--- not carry health across a Replace, so the new entity is created at its lifeform max.
function Spawner:ForceLifeForm(Player, TechId)
	if not Player or not Player.Replace or not TechId or TechId == kTechId.Skulk then
		return nil
	end

	-- MapName from tech data (Egg.lua:343 idiom); Extents is a Vector (userdata, not a table) so
	-- never gate on type() - test the field or, here, just the mapName we actually use.
	local MapName = LookupTechData(TechId, kTechDataMapName)

	if not MapName then
		return nil
	end

	local Ok, NewPlayer = pcall(function()
		return Player:Replace(MapName, kAlienTeam)
	end)

	return (Ok and NewPlayer) or nil
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

			-- Anchor at the mouth's validated BUILD point (Item.point), NOT the 11 m
			-- entrance of an unpaired tunnel (rock). See EmergenceSpot. The skulk is placed
			-- FIRST so the higher-lifeform swap below happens on ground already cleared for a
			-- 0.5 capsule (no lifeform's capsule is larger), never inside the shell.
			local Placed, Method = EmergenceSpot(Item.point)
			Player:SetOrigin(Placed)

			--- Higher lifeform: swap the class in place (the vanilla morph is closed to a
			--- hive-less horde - see ForceLifeForm). On failure the bot stays a skulk at the
			--- mouth - recoverable, never embedded.
			if Item.tech and Item.tech ~= kTechId.Skulk then
				local Morphed = self:ForceLifeForm(Player, Item.tech)

				if Morphed then
					Player = Morphed
					Method = "morph"
				end
			end

			return true, Placed, Method
		end)

		if Ok and Landed then
			Placed = Placed + 1
			self.PlacedCount = self.PlacedCount + 1

			local How2 = How == "ground" and "(ground)"
				or (How == "morph" and "(morphed to higher lifeform)" or "(RAW - no ground at the mouth)")

			self.Log(string.format("[HORDE] bot emerged at (%.1f, %.1f, %.1f) id=%s %s",
				Plugin.Placement.Axis(Spot, "x", 1), Plugin.Placement.Axis(Spot, "y", 2),
				Plugin.Placement.Axis(Spot, "z", 3), tostring(Item.id), How2))
		elseif not Ok then
			--- The entity is gone: a raw PlayerBot whose virtual client never
			--- materialised and the engine destroyed. Re-deal a replacement at the SAME
			--- mouth so the wave's living count matches what it promised (the count-loss
			--- fix: "dealt 5, emerged 3" becomes "re-dealt, emerged 5"), bounded so a
			--- persistently-failing map cannot loop. A bot that never existed is not a
			--- combat loss, so this is distinct from the reaper releasing a killed one.
			self.FailedCount = self.FailedCount + 1

			if (Item.retries or 0) < kMaxBotRetries and Item.mouth then
				self:SpawnBot(Item.mouth, Item.tech)
				local newest = self.Pending[#self.Pending]

				if newest then
					newest.retries = (Item.retries or 0) + 1
				end

				self:Log(string.format("[HORDE] bot id=%s vanished before emerging; re-dealt at its mouth (attempt %s/%s): %s",
					tostring(Item.id), tostring((Item.retries or 0) + 1), tostring(kMaxBotRetries), tostring(Landed)))
			else
				self:Log(string.format("[HORDE] gave up on a vanished bot id=%s after %s re-deals: %s",
					tostring(Item.id), tostring(Item.retries or 0), tostring(Landed)))
			end
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
				self.Placing[#self.Placing + 1] = { id = Id, ref = Item.ref, mouth = Item.mouth, point = Item.point, tech = Item.tech, Ticks = 0 }
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

--- Exported for the stuck-watch rescue (server.lua SteerHordeBots): a re-placement is
--- the SAME emergence decision made from wherever the bot stands now, so it must come
--- from this module and no other.
Spawner.EmergenceSpot = EmergenceSpot

Plugin.Spawner = Spawner

return Spawner
