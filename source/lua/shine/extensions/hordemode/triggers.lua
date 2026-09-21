--[[ Horde Mode — entry gates (i2b).

     Pure predicates over a snapshot of the world, never over the world itself.
     The command handler takes the snapshot with engine calls; everything here is
     testable with a table literal, which is how hordetest exercises all six gates
     on a headless server with nobody connected.

     Gate order follows DESIGN.md section 2 with one deliberate change: our own
     state (not-running, cooldown) is checked first. It is local, free, and the
     most common reason a second /horde fails; answering "aliens present" while a
     horde is actually running would send a player chasing the wrong problem. ]]

local Plugin = ...

local Triggers = {}

Triggers.Order = { "IsNotRunning", "CooldownOk", "InSeedingState", "NoRealAliens", "SeedMaxNotMet",
	"CallerIsMarine", "HasMarinePlayers" }

--- 1. Our own state.
function Triggers.IsNotRunning(Snapshot, Machine)
	if Machine:IsActive() then
		return false, "horde is already running (wave " .. Machine:GetWave() .. ")"
	end

	if Machine:Is(Plugin.Phase.Teardown) then
		return false, "teardown in progress"
	end

	return true, nil
end

--- 2. Post-teardown cooldown, from the machine's own clock (i2a sets EndedAt).
--- Remaining cooldown seconds, or nil when there is nothing to wait for.
function Triggers:CooldownRemaining(Snapshot, Machine, Config, Now)
	local Cooldown = (Config.Start and Config.Start.Cooldown) or 0
	local SinceEnd = Machine:TimeSinceEnd(Now)

	if not SinceEnd or Cooldown <= 0 then
		return nil
	end

	if SinceEnd >= Cooldown then
		return nil
	end

	return Cooldown - SinceEnd
end

function Triggers.CooldownOk(Snapshot, Machine, Config, Now)
	local Remaining = Triggers:CooldownRemaining(Snapshot, Machine, Config, Now)

	if Remaining then
		return false, string.format("%.0fs cooldown remaining", Remaining)
	end

	return true, nil
end

--- 3. The horde lives in the seeding window only: NotStarted or WarmUp.
function Triggers.InSeedingState(Snapshot)
	local State = Snapshot.GameState

	if State == nil then
		return false, "no gamerules yet"
	end

	-- kGameState is a global enum (Globals.lua:265), so reading it here keeps the
	-- snapshot honest; threading the two values through Snapshot invited callers to
	-- forget a field and get "not seeding" for a server that was in WarmUp.
	if State == kGameState.WarmUp or State == kGameState.NotStarted then
		return true, nil
	end

	return false, "not seeding (game already started)"
end

--- 4. The seeding contract: a real player on aliens ends the horde, so it can
---    never start while one is there. Our own bots are virtual and must not count
---    (verified i0f: bot clients are always GetIsVirtual).
function Triggers.NoRealAliens(Snapshot)
	if (Snapshot.RealAlienCount or 0) > 0 then
		return false, "players are on the alien team"
	end

	return true, nil
end

--- 5. Seed max reached means the game should start properly, not horde.
function Triggers.SeedMaxNotMet(Snapshot)
	if Snapshot.MaxPlayers and Snapshot.PlayerCount and Snapshot.PlayerCount >= Snapshot.MaxPlayers then
		return false, "server is full"
	end

	return true, nil
end

--- 6. DESIGN section 2 entry check 2: the caller must be on the marine team.
--- A nil caller means the server console / RCON, which is a legitimate admin path and
--- must stay open - hordetest itself calls the handlers with no client at all.
function Triggers.CallerIsMarine(Snapshot)
	if Snapshot.CallerPlayer == nil then
		return true, nil
	end

	if Snapshot.CallerTeamNumber ~= kTeam1Index then
		return false, "you must be on the marine team"
	end

	return true, nil
end

--- 7. Solo-playable by design (Q14: min players 1), but zero humans means nobody
---    to defend, so a headless test server must reject.
function Triggers.HasMarinePlayers(Snapshot, Machine, Config)
	local Required = (Config.Start and Config.Start.MinPlayers) or 1

	if (Snapshot.RealMarineCount or 0) < Required then
		return false, string.format("need %d marine player(s), have %d", Required, Snapshot.RealMarineCount or 0)
	end

	return true, nil
end

--- First failure wins: (false, gateName, reason); all pass: (true).
function Triggers.Check(Snapshot, Machine, Config, Now)
	for _, Name in ipairs(Triggers.Order) do
		local Gate = Triggers[Name]
		local Ok, Reason = Gate(Snapshot, Machine, Config, Now)

		if not Ok then
			return false, Name, Reason
		end
	end

	return true, nil, nil
end

-- Server-side only: reads the world into the shape the predicates expect. Kept out
-- of Check so the gates stay pure.
function Triggers.TakeSnapshot(Client)
	local gamerules = GetGamerules()

	if not gamerules then
		return { GameState = nil }
	end

	local marineHumans, alienHumans = 0, 0
	local teams = { [kTeam1Index] = "marine", [kTeam2Index] = "alien" }

	for Index, Side in pairs(teams) do
		local Team = gamerules:GetTeam(Index)

		if Team and Team.ForEachPlayer then
			Team:ForEachPlayer(function(Player)
				-- Bots are virtual clients (Bot_Server.lua:63) and never count as humans.
				if not Player:GetIsVirtual() then
					if Side == "marine" then
						marineHumans = marineHumans + 1
					else
						alienHumans = alienHumans + 1
					end
				end
			end)
		end
	end

	local Caller = Client and Client.GetControllingPlayer and Client:GetControllingPlayer() or nil

	return {
		GameState = gamerules:GetGameState(),
		CallerPlayer = Caller,
		CallerTeamNumber = Caller and Caller:GetTeamNumber(),
		BotCount = gServerBots and #gServerBots or 0,
		RealMarineCount = marineHumans,
		RealAlienCount = alienHumans,
		PlayerCount = Server.GetNumClientsTotal() - Server.GetNumSpectators(),
		MaxPlayers = Server.GetMaxPlayers(),
	}
end

Plugin.Triggers = Triggers

return Triggers
