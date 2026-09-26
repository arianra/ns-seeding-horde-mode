--[[ Horde Mode — Spawner (i4b).

 Mouth creation and destruction. Attaches as Plugin.Spawner and is owned by the
 plugin instance, so the registry it writes to is the same one teardown walks.

 The one non-obvious rule: a freshly created entity has no usable id until the next
 tick, and Registry:Register refuses it (registry.lua:93 - "registered in the same
 tick as creation?"). Inventing a key instead is not an option: a made-up negative id
 fed back to Shared.GetEntity returns nil, which previously produced a false
 "destroyed" finding in this project. So SpawnMouth queues, and Pump() - called from
 the plugin's tick - registers once the id is real.

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

--- `Reveal` is Debug.RevealMouths, resolved by the owner and stored here - ONE place.
--- The first version took it per SpawnMouth call while the plugin tick re-asserted every
--- mouth in the registry from a different field, so a mouth explicitly built unrevealed
--- was revealed anyway one second later. The suite caught it; the design was wrong.
function Spawner.New(Registry, Log, Reveal)
	return setmetatable({
		Registry = Registry,
		Log = Log or print,
		Pending = {},
		MouthCount = 0,
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
	if not Mouth or not Mouth.SetDetected then
		return false
	end

	Mouth:SetDetected(true)

	return true
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

	self.Registry:IterateByKind("mouth", function(Ref)
		if self:RevealMouth(Ref) then
			Revealed = Revealed + 1
		end
	end)

	return Revealed
end

--- Create an unpaired tunnel entrance at Point. Unpaired is intentional: spike tby
--- established mouths survive indefinitely without a partner, which is what lets a
--- wave place them one at a time.
function Spawner:SpawnMouth(Point, HealthMultiplier)
	if not Point then
		return nil, "no point given"
	end

	local Ok, Mouth = pcall(function()
		local Entity = CreateEntity(TunnelEntrance.kMapName, Point, kAlienTeam)

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

--- Register everything created on a previous tick. Returns how many were registered.
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

	return Registered
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
function Spawner:TakePending()
	local Out = self.Pending

	self.Pending = {}

	return Out
end

function Spawner:PendingCount()
	return #self.Pending
end

Plugin.Spawner = Spawner

return Spawner
