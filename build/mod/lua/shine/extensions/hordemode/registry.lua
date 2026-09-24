--[[ Horde Mode — HordeRegistry (i3a).

     Accounting truth. Two reasons this exists at all:
       1. Teardown has to destroy everything we made and nothing we did not
          (DESIGN.md section 2, "as if it never existed").
       2. Server.GetBotPlayerCount() is unreliable, and our bots must be told apart
          from vanilla seeding bots - both are virtual clients (DESIGN.md:178, :193).

     Pure data structure on purpose: no engine calls inside the primitives, so every
     method is unit-testable on a headless server. Liveness is injected - Prune takes a
     resolver (teardown passes Shared.GetEntity), which keeps "is this still there?" out
     of the registry's own knowledge.

     Verified against build 344 (lua/bots/BotTeamController.lua):
       :15  MaxBots            bot cap; SetMaxBots(newMaxBots, com) sets it
       :16  updateLock         DisableUpdate = +1, EnableUpdate = -1 with
                               assert(updateLock >= 0)  (:140-147) - an unbalanced
                               release throws inside the engine, so release is counted
       :35  addCommander1/2    per-team commander flags
     Two traps the API itself hides: SetMaxBots(_, com) assigns com to BOTH commander
     fields, so a snapshot with addCommander1 ~= addCommander2 cannot be restored
     through the setter; and SetMaxBots(0, ...) immediately RemoveBots every bot on
     the server, vanilla ones included - which is why the lock, not the cap, is the
     thing we hold during a horde. ]]

local Plugin = ...

local Registry = {}
Registry.__index = Registry

Registry.Kind = { Bot = "bot", Mouth = "mouth", Entity = "entity" }

function Registry.New()
	local Self = setmetatable({}, Registry)

	Self.Entries = {}        -- id -> { id, ref, kind }
	Self.ByKind = {}         -- kind -> { id, ... } in insertion order
	Self.NextLocalId = -1    -- negative: never collides with an entity id

	return Self
end

local function KindList(Self, Kind)
	local List = Self.ByKind[Kind]

	if not List then
		List = {}
		Self.ByKind[Kind] = List
	end

	return List
end

local function KindIndex(List, Id)
	for Index = 1, #List do
		if List[Index] == Id then
			return Index
		end
	end

	return nil
end

--- ref may be an entity (id from GetId) or any value we invented a key for.
--- Idempotent: registering the same thing twice is one entry, not two destroys.
function Registry:Register(ref, Kind)
	if ref == nil then
		return nil, "cannot register nil"
	end

	if not Kind then
		return nil, "cannot register without a kind"
	end

	-- Distinguish "not an entity" from "an entity with no id yet" by whether the
	-- call itself is possible: NS2 entities expose GetId through the class chain, and
	-- ids can arrive as FFI numbers, so type(x)=="number" alone is not enough.
	local Callable, IdValue = pcall(function() return ref:GetId() end)

	if not Callable then
		-- A plain value we invented a key for (test double, non-entity bookkeeping).
		Id = self.NextLocalId
		self.NextLocalId = self.NextLocalId - 1
	else
		local Number = tonumber(IdValue)

		if not Number or Number <= 0 then
			-- Never invent an id for a real entity: a made-up negative key fed back to
			-- Shared.GetEntity returns nil ("World::GetEntity(-3) but only 4094
			-- entities"), which would let a liveness check report "destroyed" for
			-- something that never had that id. That exact artifact produced a wrong
			-- finding in this project before i3c re-measured it.
			return nil, "entity has no usable id yet (registered in the same tick as creation?)"
		end

		Id = Number
	end

	local Existing = self.Entries[Id]

	if Existing then
		if Existing.kind ~= Kind then
			return nil, string.format("id %s already registered as %s, not %s", tostring(Id), Existing.kind, Kind)
		end

		return Id, nil
	end

	self.Entries[Id] = { id = Id, ref = ref, kind = Kind }

	local List = KindList(self, Kind)
	List[#List + 1] = Id

	return Id, nil
end

function Registry:Get(Id)
	local Entry = self.Entries[Id]

	return Entry and Entry.ref or nil
end

function Registry:GetKind(Id)
	local Entry = self.Entries[Id]

	return Entry and Entry.kind or nil
end

--- Missing ids and unknown kinds are not errors: teardown races entity destruction.
function Registry:Unregister(Id)
	local Entry = self.Entries[Id]

	if not Entry then
		return false
	end

	self.Entries[Id] = nil

	local List = self.ByKind[Entry.kind]

	if List then
		local Index = KindIndex(List, Id)

		if Index then
			table.remove(List, Index)
		end
	end

	return true
end

function Registry:IterateByKind(Kind, Callback)
	local List = self.ByKind[Kind]

	if not List then
		return 0
	end

	local Count = 0

	-- Snapshot the ids first: a callback that unregisters shrinks the very list we
	-- are reading, and iterating it by index would silently skip the shifted entry.
	-- (Found by re-reading the comment against the code - the comment promised more
	-- than the loop delivered.)
	local Ids = {}

	for Index = 1, #List do
		Ids[Index] = List[Index]
	end

	for _, Id in ipairs(Ids) do
		local Entry = self.Entries[Id]

		if Entry then
			Callback(Entry.ref, Entry.id, Entry.kind)
			Count = Count + 1
		end
	end

	return Count
end

function Registry:CountByKind(Kind)
	local List = self.ByKind[Kind]

	return List and #List or 0
end

function Registry:Count()
	local Total = 0

	for _ in pairs(self.Entries) do
		Total = Total + 1
	end

	return Total
end

function Registry:GetAllIds()
	local Ids = {}

	for Id in pairs(self.Entries) do
		Ids[#Ids + 1] = Id
	end

	table.sort(Ids)

	return Ids
end

function Registry:GetBotCount()
	return self:CountByKind(Registry.Kind.Bot)
end

--- Drop entries the resolver says are gone; returns how many were already vanished.
--- Teardown needs this to tell "we destroyed it" from "something else destroyed it".
--- The resolver MUST be kind-aware, and for the opposite reason to the one first
--- recorded here: measured 2026-09-21 with genuine ids, after Bot:Disconnect() the
--- player is gone while the PlayerBot entity id still resolves in the same tick. An
--- entity-only check therefore leaves dead bots on the books forever. Judge bots by
--- their player, mouths/entities by Shared.GetEntity(id).
--- (An earlier version of this note claimed the reverse - entity id vanishing while the
--- player lived. That was measured with registry-invented negative ids and is retracted;
--- see Register's comment on why inventing ids is forbidden.) See also Server.CreateEntity's two overloads: the
--- positional 3-arg create is the global CreateEntity (AlienTunnelManager.lua:191).
function Registry:Prune(IsGone)
	local Pruned = 0

	for _, Id in ipairs(self:GetAllIds()) do
		local Entry = self.Entries[Id]

		if Entry and IsGone(Entry.ref, Id) then
			self:Unregister(Id)
			Pruned = Pruned + 1
		end
	end

	return Pruned
end

--- Hands back everything still tracked, so the caller can destroy it in order and
--- only then empty the registry. Clearing before destroying would lose the evidence.
function Registry:Drain()
	local Entries = {}

	for _, Id in ipairs(self:GetAllIds()) do
		local Entry = self.Entries[Id]

		if Entry then
			Entries[#Entries + 1] = Entry
		end
	end

	self.Entries = {}
	self.ByKind = {}

	return Entries
end

function Registry:Clear()
	local Count = self:Count()

	self.Entries = {}
	self.ByKind = {}

	return Count
end

--- Vanilla controller state to hold across a horde. Read, not written.
function Registry.SnapshotBTCState(Controller)
	if not Controller then
		return nil, "no botTeamController"
	end

	return {
		MaxBots = Controller.MaxBots,
		addCommander1 = Controller.addCommander1,
		addCommander2 = Controller.addCommander2,
		updateLock = Controller.updateLock or 0,
		WeHoldLock = false,
	}, nil
end

--- Lock the fill loop exactly once. Double-locking would need a double release the
--- engine asserts against (:145), so a second Engage is a no-op by design.
function Registry.EngageBTC(Controller, Snapshot)
	if not Controller or not Snapshot or Snapshot.WeHoldLock then
		return false
	end

	Controller:DisableUpdate()
	Snapshot.WeHoldLock = true

	return true
end

--- Cap to zero only when we actually hold the lock, and restore both commander fields
--- directly - SetMaxBots would collapse them into one value (see header).
function Registry.LockBotCap(Controller, Snapshot)
	if not Controller or not Snapshot or not Snapshot.WeHoldLock then
		return false
	end

	Controller:SetMaxBots(0)

	return true
end

function Registry.ReleaseBTC(Controller, Snapshot)
	if not Controller or not Snapshot or not Snapshot.WeHoldLock then
		return false
	end

	Controller.addCommander1 = Snapshot.addCommander1
	Controller.addCommander2 = Snapshot.addCommander2
	Controller.MaxBots = Snapshot.MaxBots
	Controller:EnableUpdate()
	Snapshot.WeHoldLock = false

	return true
end

Plugin.Registry = Registry

return Registry
