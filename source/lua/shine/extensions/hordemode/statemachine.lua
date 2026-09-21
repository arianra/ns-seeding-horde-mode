--[[ Horde Mode — state machine (i2a).

     Implements the DESIGN.md section 2 lifecycle: INACTIVE -> WAVE(n) ->
     INTERMISSION -> WAVE(n+1) ... and Teardown reachable from any live state,
     returning to INACTIVE when complete.

     Deliberately pure: no game APIs, no Shine singletons, no shared mutable
     state. Everything time- or world-related is passed in, which is what lets
     hordetest unit-test every transition legally and illegally in one tick —
     and what keeps i2b/i6a/i7a from each inventing their own idea of "are we
     running?".

     Side effects hang off OnEnter hooks rather than being embedded here, so the
     machine stays testable and the phases stay the only source of truth. ]]

local Plugin = ...

local StateMachine = {}
StateMachine.__index = StateMachine

local Phase = Plugin.Phase

-- Legal edges. Self-transitions are absent on purpose: re-entering Teardown must
-- not run its destroy pass twice (DESIGN: "idempotent; blocks re-entry").
local LEGAL = {
	[Phase.Inactive] = { [Phase.Wave] = true },
	[Phase.Wave] = { [Phase.Intermission] = true, [Phase.Teardown] = true },
	[Phase.Intermission] = { [Phase.Wave] = true, [Phase.Teardown] = true },
	[Phase.Teardown] = { [Phase.Inactive] = true },
}

StateMachine.Phase = Phase
StateMachine.Legal = LEGAL

function StateMachine.New(Now, Logger)
	local Self = setmetatable({}, StateMachine)

	Self.Current = Phase.Inactive
	Self.WaveNumber = 0
	Self.ChangedAt = Now or 0
	Self.EndedAt = nil          -- set when a teardown completes; i2b's cooldown gate reads it
	Self.EnterHooks = {}
	Self.Log = Logger or function(Message)
		print(("[HORDE] %s"):format(Message))
	end

	return Self
end

function StateMachine:GetState()
	return self.Current
end

function StateMachine:GetWave()
	return self.WaveNumber
end

function StateMachine:Is(StateName)
	return self.Current == StateName
end

function StateMachine:IsActive()
	return self.Current == Phase.Wave or self.Current == Phase.Intermission
end

--- (ok, reason) — never raises, because i2b has to put `reason` in a player's chat.
function StateMachine:CanTransition(Target)
	if type(Target) ~= "string" then
		return false, "target state is not a name"
	end

	if Target == self.Current then
		return false, "already in " .. Target
	end

	if not (LEGAL[self.Current] and LEGAL[self.Current][Target]) then
		return false, string.format("%s -> %s is not a legal transition", self.Current, Target)
	end

	return true, nil
end

--- Run an OnEnter callback without letting a broken one corrupt the state:
--- a hook that throws must not leave the machine claiming a state it never entered.
function StateMachine:FireEnter(Target, Now)
	local Hooks = self.EnterHooks[Target]

	if not Hooks then
		return
	end

	for Index = 1, #Hooks do
		local Ok, Err = pcall(Hooks[Index], self, Target, Now)

		if not Ok then
			self.Log(string.format("on-enter hook for %s failed: %s", Target, tostring(Err)))
		end
	end
end

function StateMachine:OnEnter(Target, Callback)
	if not LEGAL[Target] and Target ~= Phase.Inactive then
		return false, "unknown state " .. tostring(Target)
	end

	if type(Callback) ~= "function" then
		return false, "OnEnter needs a function"
	end

	local Hooks = self.EnterHooks[Target]

	if Hooks then
		Hooks[#Hooks + 1] = Callback
	else
		self.EnterHooks[Target] = { Callback }
	end

	return true, nil
end

function StateMachine:Transition(Target, Now)
	local Allowed, Reason = self:CanTransition(Target)

	if not Allowed then
		self.Log(string.format("rejected %s", Reason))
		return false, Reason
	end

	local Previous = self.Current
	self.Current = Target
	self.ChangedAt = Now or self.ChangedAt

	if Target == Phase.Wave then
		self.WaveNumber = self.WaveNumber + 1
	end

	if Target == Phase.Teardown then
		self.TeardownReason = self.PendingReason
		self.PendingReason = nil
	end

	self:FireEnter(Target, self.ChangedAt)
	self.Log(string.format("state %s->%s%s", Previous, Target, self.WaveNumber > 0 and (" wave " .. self.WaveNumber) or ""))

	return true, nil
end

--- /horde entry: only from Inactive, and it starts wave 1 (DESIGN: no intermission first).
function StateMachine:Start(Now)
	if self.Current ~= Phase.Inactive then
		self.Log("start rejected: horde is not idle")
		return false, "already running"
	end

	self.WaveNumber = 0
	local Ok, Reason = self:Transition(Phase.Wave, Now)

	if Ok then
		self.EndedAt = nil
	end

	return Ok, Reason
end

--- Wave cleared -> build phase.
function StateMachine:EndWave(Now)
	if self.Current ~= Phase.Wave then
		self.Log("end-wave rejected: not in a wave")
		return false, "no wave to end"
	end

	return self:Transition(Phase.Intermission, Now)
end

--- Intermission timer elapsed or paid skip -> next wave.
--- Pinned to its source state: Inactive -> Wave is a legal edge (Start uses it),
--- so the edge alone would let a caller reach wave 1 through BeginWave and skip
--- Start's reset of the wave counter and the cooldown clock. Found by i2a's own
--- guard scenario.
function StateMachine:BeginWave(Now)
	if self.Current ~= Phase.Intermission then
		self.Log("begin-wave rejected: not in intermission")
		return false, "no intermission to leave"
	end

	return self:Transition(Phase.Wave, Now)
end

--- Loss / admin stop / seeding breach. Reason is recorded for teardown messaging and logs.
function StateMachine:Stop(Reason, Now)
	local Allowed, Rejection = self:CanTransition(Phase.Teardown)

	if not Allowed then
		-- Set the reason only once we know the move will happen, otherwise a rejected
		-- stop leaves a stale reason for whichever teardown comes later.
		self.Log(string.format("stop rejected: %s", Rejection))
		return false, Rejection
	end

	self.PendingReason = Reason or "stopped"

	return self:Transition(Phase.Teardown, Now)
end

--- Teardown finished: back to idle, and the post-teardown cooldown starts here.
function StateMachine:CompleteTeardown(Now)
	local Ok, Reason = self:Transition(Phase.Inactive, Now)

	if Ok then
		self.EndedAt = Now or self.ChangedAt
		self.WaveNumber = 0
	end

	return Ok, Reason
end

--- Seconds since the last teardown finished; nil means never ran.
function StateMachine:TimeSinceEnd(Now)
	if not self.EndedAt then
		return nil
	end

	return (Now or 0) - self.EndedAt
end

Plugin.StateMachine = StateMachine

return StateMachine
