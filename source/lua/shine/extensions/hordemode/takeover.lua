--[[ Horde Mode — takeover of the vanilla bot controller (i3b).

     Q7q7 settled that "/horde IS the horde warmup": we do not run beside the vanilla
     seeding bot fill, we replace it. So the controller has to be held for the length
     of a horde and handed back exactly as it was found.

     Two verified engine facts drive the design (lua/bots/BotTeamController.lua):
       :140-147  DisableUpdate/EnableUpdate move a *counter*, and EnableUpdate asserts
                 it stays >= 0. Releasing what we never took throws inside the engine.
       :169-172  UpdateBots wipes every bot when no humans remain - our own bots and
                 vanilla ones alike. Locked, that pass never runs.
       :185-193  SetMaxBots(0, com) immediately RemoveBots over the whole server and
                 assigns one com value to BOTH commander fields, so restore writes the
                 flags directly rather than going back through the setter.

     Depth discipline: we record how many locks *we* hold (0 or 1) and only ever
     release our own. Any unrelated lock the engine was holding at snapshot time is
     left alone - our net is zero, so the count returns to where we found it. ]]

local Plugin = ...

local Takeover = {}
Takeover.__index = Takeover

function Takeover.New(Controller, RegistryInstance)
	if not Controller then
		return nil, "takeover needs a bot controller"
	end

	local Self = setmetatable({}, Takeover)

	Self.Controller = Controller
	Self.RegistryInstance = RegistryInstance
	Self.Snapshot = nil
	Self.MyLocks = 0

	return Self, nil
end

function Takeover:IsEngaged()
	return self.MyLocks > 0
end

--- What the engine's counter looks like right now, for status and for tests that
--- need to prove we did not disturb anyone else's lock.
function Takeover:LockCount()
	return self.Controller.updateLock or 0
end

function Takeover:Engage()
	if self:IsEngaged() then
		return false, "already engaged"
	end

	if self.Snapshot then
		self.Snapshot = nil
	end

	local Registry = Plugin.Registry
	local Snapshot = Registry.SnapshotBTCState(self.Controller)

	if not Snapshot then
		return false, "no controller to snapshot"
	end

	self.Snapshot = Snapshot

	if not Registry.EngageBTC(self.Controller, Snapshot) then
		return false, "could not acquire the update lock"
	end

	self.MyLocks = 1

	-- Cap is lowered separately: this is the step that drops vanilla seeding bots,
	-- so it must stay visible as a decision rather than hide inside "lock".
	Registry.LockBotCap(self.Controller, Snapshot)

	self.Snapshot.LockedAt = Shared.GetTime()

	return true, nil
end

function Takeover:Release()
	local Registry = Plugin.Registry

	if not self:IsEngaged() then
		return false, "not engaged"
	end

	if not Registry.ReleaseBTC(self.Controller, self.Snapshot) then
		return false, "release refused"
	end

	self.MyLocks = 0

	return true, nil
end

--- The nudge vanilla never gets after OUR kind of stop. `BotTeamController:UpdateBots` is
--- the ONLY code that adds bots, and it runs from exactly three event sites -
--- `OnClientConnect`, `NS2Gamerules:SetMaxBots` and `OnClientDisconnect`
--- (NS2Gamerules.lua:322, 1436, 1575). There is no periodic call. A horde stop produces no
--- join, no leave, and - because the setter would collapse both commander flags
--- (BotTeamController.lua:185-193) - not even a SetMaxBots: our release restores the cap by
--- writing the fields directly, which is correct for state and silent for refill. So without
--- this, the controller sits ready-to-fill and does nothing until the next real client joins.
--- Chair-measured 2026-09-29: warmup bots never returned after `/horde stop`.
---
--- This is the same call vanilla's own wrapper makes after setting the cap - nothing custom.
--- Note what it does with ZERO humans: `UpdateBots` WIPES every bot (:169-172, the rule that
--- keeps idle servers bot-free); with humans it fills to the cap. That asymmetry is why the
--- nudge lives HERE as its own injectable step: the headless suite has no humans and several
--- scenarios keep live bots across deferred windows, so only the product path may fire it, and
--- only AFTER the world reset (a pre-reset refill is destroyed by `ResetGame`).
function Takeover.RefillVanillaBots(Controller)
	if not Controller or not Controller.UpdateBots then
		return false, "no controller to refill"
	end

	local Ok, Err = pcall(function()
		Controller:UpdateBots()
	end)

	if Ok then
		return true, nil
	end

	return false, tostring(Err)
end

--- Snapshot values as a flat string - status surface (RD6) and test evidence.
function Takeover:Describe()
	local Snap = self.Snapshot

	if not Snap then
		return "takeover: never engaged"
	end

	return string.format("takeover: engaged=%s locks=%s held=%s maxBots=%s now=%s updateLock=%s/%s",
		tostring(self:IsEngaged()), tostring(self.MyLocks),
		tostring(Snap.LockedAt and (Shared.GetTime() - Snap.LockedAt) or "-"),
		tostring(Snap.MaxBots), tostring(self.Controller.MaxBots), tostring(self.Controller.updateLock),
		tostring(Snap.updateLock))
end

Plugin.Takeover = Takeover

return Takeover
