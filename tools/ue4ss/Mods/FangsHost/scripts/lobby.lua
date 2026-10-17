-- Custom lobby settings and the Captain vote (FangsHost, game servers; the owner's buttons are FangsBoot's lobbyui.lua).
--
-- In a custom lobby the owner can change the map, the size (1v1 .. 6v6), the rounds to win (Bo3 .. Bo9) and the
-- Captain vote, shuffle the teams and launch with players waiting outside the seats (they are kicked first).
--   * Commands: the owner's client calls its lobby controller's RefreshPlayerInfoOnServer RPC with "fce:<cmd>" in place
--     of a user id (the RPC only acts on the caller's own id; main.lua's CloudSave shim passes these on to us).
--   * Settings to every player: the lobby game state's ServerPayload, a replicated string the game sets at lobby setup
--     and never reads. A joiner's InitLobbyState overwrites it; the 500 ms loop puts ours back.
--   * Map and size go through the lobby state the same way setLobbyMap/setLobbySize do for matchmade games, and to
--     the backend through the heartbeat (fangshost_status.json "lobby"), which updates the lobby list.
-- In the arena (every game on this server, custom or not):
--   * MaxRounds (rounds to win; native, not replicated) from the lobby setting; players' FangsBoot sets theirs too.
--   * Captain: the game's own vote (BP_RS_King) decides by teammates' votes (KingVoteCustomID) among those who weren't
--     Captain yet. Vote on: an 8 s window every round, unvoted players get a random vote at the end. Vote off (and
--     Casual/Ranked): no window, everyone gets a random vote, so the Captain is random and never twice in a row.
--     The game counts votes only from round 4 on: the community-lobby patch makes it round 1.
--     The window is MaxKingVotingTime: on a server it is always the one used, because the round check reads
--     WB_HUDGamplayRef.KingVoteRound of player controller 0, and a server has no HUD (the read gives 0).
return function(env)
    local log, every, later, hook = env.log, env.every, env.later, env.hook
    local CUSTOM = 4
    local VOTE_SECS = 8.0
    local S = { map = nil, mapName = nil, size = nil, rounds = 2, vote = false, maps = nil }
    local lastCaptain = {}       -- team (1/2) -> PlayerCustomID of that team's last Captain
    local push = nil
    local function dirty(obj, index, name)
        push = push or StaticFindObject("/Script/NetCore.Default__NetPushModelHelpers")
        if push and push:IsValid() then push:MarkPropertyDirtyFromRepIndex(obj, index, FName(name)) end
    end

    -- the custom maps players may pick: FANGSConfig's AvailableMaps ({"Name": ..., "Map": ..., "Custom": true})
    local function allowedMaps()
        if S.maps then return S.maps end
        local json = env.readRecord("game/FANGSConfig")
        if not json then return {} end
        local maps, seen = {}, {}
        for obj in json:gmatch('{[^{}]-"Map"%s*:%s*"[^"]+"[^{}]-}') do
            local name, level = obj:match('"Name"%s*:%s*"([^"]*)"'), obj:match('"Map"%s*:%s*"([^"]+)"')
            if level and not seen[level] and not obj:find('"Custom"%s*:%s*false') then
                seen[level] = true
                maps[#maps + 1] = { name = name or level, level = level }
            end
        end
        if #maps > 0 then S.maps = maps end
        return maps
    end

    local statics = nil
    local function lobby()
        local gs = env.gameState()
        if not (gs and gs:IsValid() and gs:GetClass():GetFName():ToString() == "GS_Lobby_GameState_C") then return nil end
        statics = statics or StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local gm = statics:GetGameMode(gs)
        if not (gm and gm:IsValid()) then return nil end
        return gm, gs
    end
    math.randomseed(os.time())

    local function payload()
        local list = {}
        for _, m in ipairs(allowedMaps()) do list[#list + 1] = m.name .. ":" .. m.level end
        return string.format("fce1|map=%s|size=%d|rounds=%d|vote=%d|maps=%s", S.map or "", S.size or 0, S.rounds,
            S.vote and 1 or 0, table.concat(list, ","))
    end

    local function publish(gs)
        local want = payload()
        if gs.ServerPayload:ToString() == want then return end
        gs:FlushNetDormancy(); gs.ServerPayload = want; dirty(gs, 20, "ServerPayload")
    end

    local function applyMap(gs)
        if not S.map or gs.Level:ToString() == S.map then return end
        gs:FlushNetDormancy()
        gs.Level = S.map; gs.MapName = FText(S.mapName or S.map)
        dirty(gs, 18, "Level"); dirty(gs, 15, "MapName")
        local gi = env.gameInstance()
        if gi and gi:IsValid() then gi.MapGameLevel = S.map; gi.MapName = S.mapName or S.map end
    end

    local function players(gs)   -- lobby player states with their controllers
        local out = {}
        gs.PlayerArray:ForEach(function(_, e)
            local ps = e:get()
            local pc = ps:IsValid() and ps.Owner
            if pc and pc:IsValid() and not env.isLocal(pc) then out[#out + 1] = { ps = ps, pc = pc } end
        end)
        return out
    end

    local function applySize(gm, gs)
        if not S.size then return end
        if gm.MaxPlayers ~= S.size or gs.MatchSize ~= S.size then
            gm.MaxPlayers = S.size
            gs:FlushNetDormancy(); gs.MatchSize = S.size; dirty(gs, 14, "MatchSize")
            local gi = env.gameInstance()
            if gi and gi:IsValid() then gi.MapPlayerCount = S.size end
        end
        -- seats that no longer exist: those players wait outside the seats ("users in lobby"), as with the (-) button
        for _, p in ipairs(players(gs)) do
            if p.ps.ChosenSlot >= S.size then
                log(string.format("lobby: seat %d is gone with %d seats: %s waits outside", p.ps.ChosenSlot, S.size,
                    p.ps:GetPlayerName():ToString()))
                p.pc:SelectTeamSlotOnServer(-1)
            end
        end
    end

    local function shuffle(gs)
        local seated = {}
        for _, p in ipairs(players(gs)) do if p.ps.ChosenSlot >= 0 then seated[#seated + 1] = p end end
        for i = #seated, 2, -1 do local j = math.random(i); seated[i], seated[j] = seated[j], seated[i] end
        for _, p in ipairs(seated) do p.pc:SelectTeamSlotOnServer(-1) end
        for i, p in ipairs(seated) do p.pc:SelectTeamSlotOnServer(i - 1) end   -- even seats team A, odd seats team B
        log("lobby: teams shuffled (" .. #seated .. " players)")
    end

    local function kickWaiting(gm, gs)
        local n = 0
        for _, p in ipairs(players(gs)) do
            if p.ps.ChosenSlot < 0 and not p.ps.IsLobbyOwner then
                gm:KickPlayer(p.ps.AccelyteId:ToString()); n = n + 1
            end
        end
        log("lobby: launching: " .. n .. " waiting player(s) kicked")
    end

    -- a command from a player's client ("fce:<name>=<value>"); only the lobby owner's count, before hero select
    function env.lobbyCommand(pc, text)
        local gm, gs = lobby()
        if not gm then return end
        local ps = pc.PlayerState
        if not (ps and ps:IsValid() and ps.IsLobbyOwner) then return log("lobby: command from a player who isn't the owner: " .. text) end
        if env.gameMode() ~= CUSTOM or gm.LobbyState ~= 0 then return log("lobby: command ignored now: " .. text) end
        local cmd, arg = text:match("^fce:(%w+)=?(.*)$")
        if cmd == "map" then
            for _, m in ipairs(allowedMaps()) do
                if m.level == arg then S.map, S.mapName = m.level, m.name; applyMap(gs); log("lobby: map " .. m.name) end
            end
        elseif cmd == "size" then
            local n = tonumber(arg)
            if n and n >= 2 and n <= 12 and n % 2 == 0 then S.size = n; applySize(gm, gs); log("lobby: size " .. n) end
        elseif cmd == "rounds" then
            local n = tonumber(arg)
            if n and n >= 2 and n <= 5 then S.rounds = n; log("lobby: first to " .. n .. " rounds") end
        elseif cmd == "vote" then
            S.vote = arg == "1"; log("lobby: Captain vote " .. (S.vote and "on" or "off"))
        elseif cmd == "shuffle" then
            shuffle(gs)
        elseif cmd == "kickwaiting" then
            kickWaiting(gm, gs)
        else
            return log("lobby: unknown command " .. text)
        end
        publish(gs)
    end

    -- keep the settings in the lobby state: joiners reset map, size and ServerPayload with their own InitLobbyState
    every(500, function()
        if env.notOnLobby() then return end
        local gm, gs = lobby()
        if not gm or env.gameMode() ~= CUSTOM or gm.LobbyState ~= 0 then return end
        if not S.size then S.size = gs.MatchSize end   -- the lobby's own size until the owner changes it
        if not S.map then
            S.map = gs.Level:ToString()
            for _, m in ipairs(allowedMaps()) do if m.level == S.map then S.mapName = m.name end end
        end
        applyMap(gs); applySize(gm, gs); publish(gs)
    end)

    -- for the backend's lobby list (main.lua's heartbeat): the custom lobby's current map and size
    function env.lobbyStatus()
        if env.gameMode() ~= CUSTOM or not S.map then return nil end
        return string.format('{"map_level": "%s", "map_name": "%s", "size": %d, "rounds": %d, "vote": %s}',
            S.map, (S.mapName or ""):gsub('"', ""), S.size or 0, S.rounds, tostring(S.vote))
    end

    local KING = "/Game/BluePrints/Gameplay/GameRules/King/BP_RS_King.BP_RS_King_C"

    -- the Captain vote, every round (see the top)
    local function teamPlayers(gs)
        local teams = { [1] = {}, [2] = {} }
        gs.PlayerArray:ForEach(function(_, e)
            local ps = e:get()
            if ps:IsValid() and teams[ps.Team] then teams[ps.Team][#teams[ps.Team] + 1] = ps end
        end)
        return teams
    end
    local function randomVotes(onlyEmpty)
        local gs = env.gameState()
        if not gs then return end
        for team, list in pairs(teamPlayers(gs)) do
            local eligible = {}
            for _, ps in ipairs(list) do if not ps.WasKing then eligible[#eligible + 1] = ps.PlayerCustomID:ToString() end end
            if #eligible > 0 then
                for _, ps in ipairs(list) do
                    local cur = ps.KingVoteCustomID:ToString()
                    if not onlyEmpty or cur == "" or cur == "-1" then
                        ps:FlushNetDormancy(); ps.KingVoteCustomID = eligible[math.random(#eligible)]
                    end
                end
            end
        end
    end
    local voteRound = 0
    local function onStartKingVoting(ctx)
        local rs = ctx:get()
        local vote = S.vote and env.gameMode() == CUSTOM
        local gs = env.gameState()
        -- the game resets "was Captain" once everyone on a team was: keep the last Captain out for one more round
        if gs then
            for team, list in pairs(teamPlayers(gs)) do
                local all, last = true, nil
                for _, ps in ipairs(list) do
                    if ps.WasKing then all = false end
                    if ps.PlayerCustomID:ToString() == lastCaptain[team] then last = ps end
                end
                if all and last and #list > 1 then last:FlushNetDormancy(); last.WasKing = true; dirty(last, 40, "WasKing") end
            end
        end
        rs.MaxKingVotingTime = vote and VOTE_SECS or 0.0
        if gs and env.gameMode() == CUSTOM and S.rounds ~= 2 and gs.MaxRounds ~= S.rounds then   -- in case BeginPlay was too early
            gs.MaxRounds = S.rounds; log("match: first to " .. S.rounds .. " rounds")
        end
        voteRound = voteRound + 1
        if vote then
            local round = voteRound
            ExecuteInGameThreadWithDelay(math.floor((VOTE_SECS - 0.5) * 1000), function()
                if round == voteRound then pcall(randomVotes, true) end
            end)
        else
            randomVotes(false)
        end
        log(string.format("captain: %s", vote and ("vote, " .. VOTE_SECS .. " s") or "random, no vote window"))
    end
    local function onDetermineKings(ctx)
        local rs = ctx:get()
        lastCaptain[1] = rs.TeamAKingPlayerID:ToString(); lastCaptain[2] = rs.TeamBKingPlayerID:ToString()
    end

    -- MaxRounds for the match (set on the arena's game state as it begins)
    pcall(RegisterBeginPlayPreHook, function(ctx)
        local actor = ctx:get()
        -- GS_MOBA_Battle_C or a map's own subclass (the arenas use GS_MOBA_Battle_Dragon_C)
        if not (actor and actor:IsValid()) or not actor:GetClass():GetFName():ToString():find("^GS_MOBA_Battle") then return end
        if env.gameMode() == CUSTOM and S.rounds ~= 2 then
            pcall(function() actor.MaxRounds = S.rounds end)
            log("match: first to " .. S.rounds .. " rounds")
        end
    end)

    every(1000, function()
        local done = true
        if not hook(KING .. ":StartKingVoting", function(ctx)
            local ok, e = pcall(onStartKingVoting, ctx); if not ok then log("captain: " .. tostring(e)) end
        end) then done = false end
        if not hook(KING .. ":DetermineKings", function(ctx) pcall(onDetermineKings, ctx) end) then done = false end
        return done
    end)
    log("lobby settings and Captain vote loaded")
end
