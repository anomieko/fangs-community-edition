-- FangsHost: turn a headless FANGS instance into a dedicated lobby server.
-- Active only with -FangsHost on the command line. The Game-target exe can't run -server, so we
-- remove the local player (a dedicated server has none) and open the lobby map as a listen server.
-- Listen port comes from -port=<n>. Readiness is visible in the UE log ("IpNetDriver listening").
local UEHelpers = require("UEHelpers")
-- UE4SS.log is buffered (not readable live); also keep our own line-flushed log next to the exe
local logFile = io.open("fangshost.log", "a")
local function log(msg)
    print("[fangshost] " .. tostring(msg) .. "\n")
    if logFile then logFile:write(os.date("!%Y-%m-%d %H:%M:%S ") .. tostring(msg) .. "\n"); logFile:flush() end
end

-- Runs fn on the game thread every `ms` milliseconds until it returns true. (LoopAsync + ExecuteInGameThread
-- ran Lua on two threads at once, which now and then crashed the game inside UE4SS's Lua VM: exit code 3.)
local function every(ms, fn)
    local handle, failures = nil, 0
    handle = LoopInGameThreadWithDelay(ms, function()
        local ok, done = pcall(fn)   -- an error must not end the loop (objects vanish during map changes)
        if not ok then
            failures = failures + 1
            if failures <= 3 then log("loop error (" .. ms .. " ms loop): " .. tostring(done)) end
        elseif done == true and handle and IsValidDelayedActionHandle(handle) then
            CancelDelayedAction(handle)
        end
    end)
    return handle
end

local ok, cl = pcall(function() return UEHelpers.GetKismetSystemLibrary():GetCommandLine():ToString() end)
if not (ok and cl:find("-FangsHost", 1, true)) then return end
local lobbyMap = cl:match("-FangsLobbyMap=(%S+)") or "/Game/Environment/Maps/LE_Lobby_Map"

-- A dedicated server has no local player. Remove the controller(s) owned by the local player (not just any
-- PlayerController: a missed one joins the lobby as a ghost that takes a slot and blocks the match even
-- after it is removed there), then open the lobby map as listen server.
local LocalPlayerClass = nil
local function isLocal(pc)   -- owned by a LocalPlayer (IsLocalController() is also true for joining remote players)
    LocalPlayerClass = LocalPlayerClass or StaticFindObject("/Script/Engine.LocalPlayer")
    local ok, v = pcall(function() local p = pc.Player; return p:IsValid() and p:IsA(LocalPlayerClass) end)
    return ok and v
end
local function localControllers()
    local out = {}
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if pc:IsValid() and not pc:GetFullName():find("Default__", 1, true) and isLocal(pc) then out[#out + 1] = pc end
    end
    return out
end

-- Object lookups (FindFirstOf/FindAllOf) scan every object: ~3 ms each on a fast PC, several times that on
-- a small VPS, on the game thread. Loops below avoid them where they can: the game instance never changes,
-- and lobby-only work is skipped on other maps (currentMap comes from the 3 s heartbeat).
local cachedGI = nil
local function gameInstance()
    if not (cachedGI and cachedGI:IsValid()) then cachedGI = FindFirstOf("BP_MOBAInstance_C") end
    return cachedGI
end
currentMap = ""   -- "/Game/.../LE_Lobby_Map" etc., "" until the first heartbeat
local function notOnLobby() return currentMap ~= "" and not currentMap:find("LE_Lobby_Map", 1, true) end

local started, removedAt = false, nil
every(500, function()
    if started then return end
    local gs = FindFirstOf("GameStateBase")
    if not (gs and gs:IsValid()) then return end
    local statics, locals = StaticFindObject("/Script/Engine.Default__GameplayStatics"), localControllers()
    if not removedAt then   -- 1. remove the local player
        if #locals == 0 then return end
        for _, pc in ipairs(locals) do statics:RemovePlayer(pc, true) end
        removedAt = os.time(); log("removed the local player (" .. #locals .. ")")
        return
    end
    if os.time() - removedAt < 2 then return end   -- 2. a moment later (same frame crashed some VPS starts)
    started = true
    log("opening " .. lobbyMap .. " as listen server")
    statics:OpenLevel(gs, FName(lobbyMap), true, "listen")
    return started
end)
log("loaded (host mode)")

-- Safety net: a local player that still shows up on a loaded lobby/arena is removed (never during a level
-- change, which can leave the server stuck between levels).
local removedLocal = {}   -- a destroyed controller stays findable until garbage collection
every(2000, function()
    if not started then return end
    local gs = FindFirstOf("GameStateBase")
    local map = gs and gs:IsValid() and gs:GetFullName():match("Maps/([%w_]+)") or ""
    if map == "" or map == "LE_Loading_Map" or map == "LE_MainMenu_Map" then return end
    for _, pc in ipairs(localControllers()) do
        local name = pc:GetFullName()
        if not removedLocal[name] then
            removedLocal[name] = true
            StaticFindObject("/Script/Engine.Default__GameplayStatics"):RemovePlayer(pc, true)
            log("removed a local player that was still there: " .. pc:GetFName():ToString() .. " on " .. map)
        end
    end
end)

-- Status heartbeat for the backend's host manager: <Win64>/fangshost_status.json. "ready" once the lobby
-- has its server config (FANGSConfig): the lobby picks a matchmade game's random map when the first player
-- joins, from that config, so players must not be sent here before it is loaded.
configLoaded = false
launched = false   -- the lobby started its match (LaunchGame); the backend stops abandoned lobbies quickly

-- Server frame rate and hitches for the heartbeat, in real time (world time stops while a match is paused):
-- frames counted per real second; a hitch shows up as a long gap between runs of this 100 ms sampler.
-- No object lookups here (each FindFirstOf scans every object, ~3 ms): os.clock() is wall time in this
-- (MSVC) Lua, the frame counter is global.
local lastSample, worstGap = nil, 0
every(100, function()
    local t = os.clock()
    if lastSample and t > lastSample then worstGap = math.max(worstGap, t - lastSample) end
    lastSample = t
end)
local frameMark = nil   -- {frames, wall time} at the last heartbeat
local function frameStats()
    local frames = UEHelpers.GetKismetSystemLibrary():GetFrameCount()
    local t = os.clock()
    local fps = nil
    if frameMark and t > frameMark.t then fps = (frames - frameMark.frames) / (t - frameMark.t) end
    frameMark = { frames = frames, t = t }
    local hitch = math.max(0, worstGap - 0.1) * 1000   -- the sampler's own 100 ms isn't a hitch
    worstGap = 0
    return fps, hitch
end

-- Frame-rate cap by what the server is doing: a full tick (FANGS_TICKRATE, 60) only in matches. An empty
-- server ticking at 60 used most of a CPU core for nothing, taken from the matches on the same machine.
local MATCH_FPS = tonumber(os.getenv("FANGS_TICKRATE") or "") or 60
local fpsCap = nil
local function capFps(gs, map, players)
    local want = (map ~= "" and not map:find("LE_Lobby_Map", 1, true)) and MATCH_FPS or (players > 0 and 30 or 15)
    if want == fpsCap then return end
    if not (gs and gs:IsValid()) then return end
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(gs, "t.MaxFPS " .. want, nil)
    fpsCap = want
    log("tick: " .. want .. " fps (" .. (map:match("[^/]+$") or "?") .. ", " .. players .. " players)")
end

every(3000, function()
    local map, players = "", 0
    local gs = FindFirstOf("GameStateBase")
    if gs and gs:IsValid() then map = gs:GetFullName():match("(/Game/[^%.]+)") or "" end
    currentMap = map
    for _, p in ipairs(FindAllOf("PlayerController") or {}) do
        if p:IsValid() and not p:GetFullName():find("Default__", 1, true) and not isLocal(p) then players = players + 1 end
    end
    pcall(capFps, gs, map, players)
    local ok, fps, hitch = pcall(frameStats)
    if not ok then fps, hitch = nil, 0 end
    local f = io.open("fangshost_status.json.tmp", "w")
    if f then
        f:write(string.format('{"map": "%s", "players": %d, "ready": %s, "launched": %s, "fps_cap": %d, '
            .. '"fps": %.1f, "hitch_ms": %.0f, "time": %d}', map, players, tostring(configLoaded),
            tostring(launched), fpsCap or 0, fps or 0, hitch or 0, os.time()))
        f:close(); os.remove("fangshost_status.json"); os.rename("fangshost_status.json.tmp", "fangshost_status.json")
    end
end)

-- Dedicated-server init the lobby level normally runs only when IsDedicatedServer() is true
-- (LE_Lobby_Map BeginPlay): enable the AccelByte backend, log the server in (client credentials),
-- then let the level load server-side config. Without it the lobby can't fetch player profiles.
-- The SDK only loads AccelByteServerSettings from config in real Server builds; set them at runtime.
local backend = cl:match("-FangsBackend=(%S+)")
local function configureServerSdk()
    if not backend then return end
    local ss = StaticFindObject("/Script/AccelByteUe4Sdk.Default__AccelByteBlueprintsServerSettings")
    if not (ss and ss:IsValid()) then return log("AccelByteBlueprintsServerSettings not found") end
    local base = "http://" .. backend
    local settings = {   -- setter -> value; called one by one (the set differs a little between builds)
        SetClientId = "fangs-host", SetClientSecret = "fangs-host", SetNamespace = "fangs", SetPublisherNamespace = "hiddenleaf",
        SetIamServerUrl = base .. "/iam", SetCloudSaveServerUrl = base .. "/cloudsave", SetPlatformServerUrl = base .. "/platform",
        SetStatisticServerUrl = base .. "/social", SetSessionBrowserServerUrl = base .. "/sessionbrowser",
        SetDSMControllerServerUrl = base .. "/dsmcontroller", SetQosManagerServerUrl = base .. "/qosm",
        SetGameTelemetryServerUrl = base .. "/game-telemetry", SetLobbyServerUrl = base .. "/lobby/",
        SetAchievementServerUrl = base .. "/achievement", SetMatchmakingServerUrl = base .. "/matchmaking",
        SetSeasonPassServerUrl = base .. "/seasonpass",
    }
    for setter, value in pairs(settings) do
        local ok = pcall(function() ss[setter](ss, value) end)
        if not ok then log("server SDK: " .. setter .. " not available") end
    end
    log("server SDK pointed at " .. base)
end

local lastLobbyGM = nil
every(1000, function()
    if notOnLobby() or (lastLobbyGM and lastLobbyGM:IsValid()) then return end   -- nothing to do: no lookup
    local gm = FindFirstOf("BP_GM_Lobby_GameMode_C")
    if not (gm and gm:IsValid()) or gm == lastLobbyGM then return end
    local name = gm:GetFullName()
    if lastLobbyGM and lastLobbyGM:IsValid() and lastLobbyGM:GetFullName() == name then return end
    lastLobbyGM = gm
    local gi = gameInstance()
    if gi and gi:IsValid() then gi.bUseAccelbyteBackend = true end
    configureServerSdk()
    gm:AccelByteServerLogin()
    log("lobby: server login requested")
    ExecuteInGameThreadWithDelay(4000, function()
        local lvl = FindFirstOf("LE_Lobby_Map_C")
        if lvl and lvl:IsValid() then lvl:OnAccelByteLoginSuccess(); log("lobby: post-login init done") end
    end)
end)

-- ---------------------------------------------------------------------------------------------
-- Server CloudSave shim. In this client build UAccelByte::ServerRetrievePlayerInfoRecord,
-- ServerRetrievePlayerRecord and ServerRetrieveGameRecord are compiled-out stubs (#if UE_SERVER),
-- so their callbacks never fire and the lobby waits forever. We hook the Blueprint callers and
-- invoke the success/failure handlers ourselves, reading records the backend exports to
-- <FangsData>/records/{game,players/<uid>}/<key>.json.
local dataDir = cl:match("-FangsData=(%S+)")

local function readRecord(rel)
    if not dataDir then return nil end
    local f = io.open(dataDir .. "/records/" .. rel .. ".json", "r")
    if not f then return nil end
    local s = f:read("a"); f:close()
    return s
end

local function later(fn) ExecuteInGameThreadWithDelay(50, fn) end
local function str(p) local ok, v = pcall(function() return p:get():ToString() end); return ok and v or "" end

local LOBBY_PC = "/Game/BluePrints/Lobby/BP_PC_Lobby_PlayerController.BP_PC_Lobby_PlayerController_C"
local LOBBY_MAP = "/Game/Environment/Maps/LE_Lobby_Map.LE_Lobby_Map_C"
local hooks = {}  -- name -> true once registered
local function hook(path, fn)
    if hooks[path] then return true end
    if not StaticFindObject(path) then return false end
    local ok, err = pcall(RegisterHook, path, fn)
    if ok then hooks[path] = true; log("hooked " .. path:match(":(.*)$")) else log("hook failed " .. path .. ": " .. tostring(err)) end
    return ok
end

local function installShim()
    local all = true
    all = hook(LOBBY_MAP .. ":RetrieveGameRecord", function(ctx, key)
        local lvl, k = ctx:get(), str(key)
        later(function()
            local json = readRecord("game/" .. k)
            if json then
                lvl:OnGetGameRecordSuccess(k, { JSONValue = json }); log("served game record " .. k)
                if k == "FANGSConfig" then configLoaded = true end
            else lvl:OnGetGameRecordFailure(18003, "not found"); log("game record missing " .. k) end
        end)
    end) and all
    all = hook(LOBBY_PC .. ":UpdateCloudPlayerInfo", function(ctx, playfabId)
        local pc, uid = ctx:get(), str(playfabId)
        later(function()
            local json = readRecord("players/" .. uid .. "/PROFILE_INFO_KEY") or "{}"
            pc:OnRetrievePlayerInfoRecordSuccess(true, {}, json); log("served profile " .. uid)
        end)
    end) and all
    all = hook(LOBBY_PC .. ":RefreshPlayerInfoOnServer", function(ctx, userId)
        local pc, uid = ctx:get(), str(userId)
        later(function()
            local json = readRecord("players/" .. uid .. "/PROFILE_INFO_KEY") or "{}"
            pc:OnRefreshPlayerInfoOnServerSuccess(true, {}, json); log("refreshed profile " .. uid)
        end)
    end) and all
    all = hook(LOBBY_PC .. ":GetServerPlayerMastery", function(ctx)
        local pc = ctx:get()
        later(function() pc:OnServerRetrieveMasteryFailure(18022, "no mastery record") end)
    end) and all
    all = hook(LOBBY_PC .. ":GetServerPlayerRatings", function(ctx)
        local pc = ctx:get()
        later(function() pc:OnServerRetrieveRatingsFailure(18022, "no ratings record") end)
    end) and all
    return all
end

-- ---------------------------------------------------------------------------------------------
-- Custom lobbies start when the owner wants. The stock lobby only lets the owner launch once every
-- slot is filled (MatchSize players). FangsBoot shows the Launch button as soon as everyone present
-- has picked a side; here, when Launch arrives (StartHeroSelectionTimer, a server RPC), the match is
-- shrunk to the players actually present so the server's "all present / all slots chosen" checks pass.
local function setLobbySize(gm, gs, n)
    gm.MaxPlayers = n
    gs:FlushNetDormancy(); gs.MatchSize = n
    local push = StaticFindObject("/Script/NetCore.Default__NetPushModelHelpers")
    if push and push:IsValid() then push:MarkPropertyDirtyFromRepIndex(gs, 14, FName("MatchSize")) end
    local gi = gameInstance()
    if gi and gi:IsValid() then gi.MapPlayerCount = n end
end

local function gameMode()   -- ENUM_MapGameMode of this server's lobby (the game instance has it in every build)
    local gi = gameInstance()
    return gi and gi:IsValid() and gi.MapGameMode or -1
end

local function startWithPresentPlayers(ctx)
    local gm, gs = FindFirstOf("BP_GM_Lobby_GameMode_C"), FindFirstOf("GS_Lobby_GameState_C")
    if not (gm and gm:IsValid() and gs and gs:IsValid()) then return end
    if gameMode() ~= 4 then return end   -- custom lobbies only (Aug 2022 matchmade clients call this on join)
    local n = gm.PlayerControllersRP:GetArrayNum()
    if n < 1 or n >= gm.MaxPlayers then return end
    log(string.format("lobby: owner launched with %d of %d players", n, gm.MaxPlayers))
    setLobbySize(gm, gs, n)
    -- the hook runs after the RPC body, which already gave up waiting for the missing players: run it again
    later(function() if gm:IsValid() then gm:ShowHeroSelectionMenu() end end)
end

-- Matchmade games (Play -> Casual/Ranked, MapGameMode 2/3): every joining client sets the lobby to 8
-- players and it only starts when full. The backend's matchmaker passes the real size: keep the lobby at
-- it (clients then start hero select by themselves); if not everyone shows up, start with those present.
local matchSize = tonumber(cl:match("-FangsMatchSize=(%d+)"))
local matchMap = cl:match("-FangsMatchMap=(%S+)")
local matchMapName = matchMap
local NO_SHOW_SECS = 45
local function readMatchFile()   -- written by the backend when it hands a standby server to a match
    local f = io.open("fangshost_match.json", "r")
    if not f then return end
    local text = f:read("a"); f:close()
    matchSize = tonumber(text:match('"size"%s*:%s*(%d+)'))
    matchMap = text:match('"map"%s*:%s*"([^"]+)"')
    matchMapName = text:match('"map_name"%s*:%s*"([^"]*)"') or matchMap
    if matchSize then log("matchmade game for " .. matchSize .. " players" .. (matchMap and (" on " .. matchMap) or "")) end
end
local function setLobbyMap(gs)   -- the lobby's own random pick (GetRandomMap from CasualMaps) comes up empty
    local push = StaticFindObject("/Script/NetCore.Default__NetPushModelHelpers")
    gs:FlushNetDormancy()
    gs.Level = matchMap; gs.MapName = FText(matchMapName)
    if push and push:IsValid() then
        push:MarkPropertyDirtyFromRepIndex(gs, 18, FName("Level")); push:MarkPropertyDirtyFromRepIndex(gs, 15, FName("MapName"))
    end
    local gi = gameInstance()
    if gi and gi:IsValid() then gi.MapGameLevel = matchMap; gi.MapName = matchMapName end
    log("lobby: map " .. matchMap .. " (" .. matchMapName .. ")")
end
do
    local firstJoin, size, lastKick = nil, nil, 0
    local gm, gs = nil, nil
    every(500, function()
        if not matchSize then readMatchFile() end
        if not matchSize or notOnLobby() then return end
        size = size or matchSize
        if not (gm and gm:IsValid() and gs and gs:IsValid()) then
            gm, gs = FindFirstOf("BP_GM_Lobby_GameMode_C"), FindFirstOf("GS_Lobby_GameState_C")
        end
        if not (gm and gm:IsValid() and gs and gs:IsValid()) then return end
        if gameMode() ~= 2 and gameMode() ~= 3 then return end
        local present = gm.PlayerControllersRP:GetArrayNum()
        if present > 0 and not firstJoin then firstJoin = os.time() end
        if gm.LobbyState == 0 and firstJoin and present > 0 and present < size and os.time() - firstJoin > NO_SHOW_SECS then
            log(string.format("lobby: starting with %d of %d matched players", present, size)); size = present
        end
        if gm.MaxPlayers ~= size or gs.MatchSize ~= size then setLobbySize(gm, gs, size) end
        if matchMap and gs.Level:ToString() ~= matchMap then setLobbyMap(gs) end
        -- Aug 2022 clients ask for hero select once, right on joining - before the lobby has its real
        -- size - and never again. Start it from here once everyone is in (retried until it takes).
        if gm.LobbyState == 0 and present >= size and gm.MaxPlayers == size and os.time() - lastKick >= 3 then
            if lastKick == 0 then log("lobby: all " .. present .. " matched players are in - starting hero select") end
            lastKick = os.time()
            gm:ShowHeroSelectionMenu()
        end
    end)
end

-- Lobby -> arena: LaunchGame runs "servertravel" through GetPlayerController(0). Here that can be the
-- removed local player's controller (still around until garbage collection); the command then goes
-- nowhere and everyone hangs on "Waiting for players". Travel through a connected player instead.
local LOBBY_GM = "/Game/BluePrints/Lobby/BP_GM_Lobby_GameMode.BP_GM_Lobby_GameMode_C"
local function ensureTravel(ctx)
    launched = true
    local gm = ctx:get()
    local first = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gm, 0)
    if first and first:IsValid() and not isLocal(first) then return end   -- the game's own travel went through
    local gs = FindFirstOf("GS_Lobby_GameState_C")
    local level = gs and gs:IsValid() and gs.Level:ToString() or ""
    local remote = nil
    gm.PlayerControllersRP:ForEach(function(_, e)
        local pc = e:get()
        if not remote and pc:IsValid() and not isLocal(pc) then remote = pc end
    end)
    if level == "" or not remote then return log("lobby: can't start the match (level '" .. level .. "')") end
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(gm, "servertravel /Game/Environment/Maps/" .. level, remote)
    log("lobby: travelling to " .. level)
end

local function installLaunchHook()
    return hook(LOBBY_PC .. ":StartHeroSelectionTimer", startWithPresentPlayers)
        and hook(LOBBY_GM .. ":LaunchGame", ensureTravel)
end

local shimDone = false
every(1000, function()
    if shimDone then return end
    local s, all = pcall(function() return installShim() and installLaunchHook() end)
    if not s then log("shim install error: " .. tostring(all)) elseif all then
        shimDone = true; log("server CloudSave shim installed (data: " .. tostring(dataDir) .. ")")
    end
    return shimDone
end)
