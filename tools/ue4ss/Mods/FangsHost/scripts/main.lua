-- FangsHost: turn a headless FANGS instance into a dedicated lobby server.
-- Active only with -FangsHost on the command line. The Game-target exe can't run -server, so we
-- remove the local player (a dedicated server has none) and open the lobby map as a listen server.
-- Listen port comes from -port=<n>. Readiness is visible in the UE log ("IpNetDriver listening").
local UEHelpers = require("UEHelpers")
local function log(msg) print("[fangshost] " .. tostring(msg) .. "\n") end

local ok, cl = pcall(function() return UEHelpers.GetKismetSystemLibrary():GetCommandLine():ToString() end)
if not (ok and cl:find("-FangsHost", 1, true)) then return end
local lobbyMap = cl:match("-FangsLobbyMap=(%S+)") or "/Game/Environment/Maps/LE_Lobby_Map"

local started = false
LoopAsync(500, function()
    ExecuteInGameThread(function()
        if started then return end
        local pc = FindFirstOf("PlayerController")
        local gs = FindFirstOf("GameStateBase")
        if not (pc and pc:IsValid() and gs and gs:IsValid()) then return end
        started = true
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        statics:RemovePlayer(pc, true)
        log("removed local player; opening " .. lobbyMap .. " as listen server")
        statics:OpenLevel(gs, FName(lobbyMap), true, "listen")
    end)
    return started
end)
log("loaded (host mode)")

-- Status heartbeat for the backend's host manager: <Win64>/fangshost_status.json
LoopAsync(3000, function()
    ExecuteInGameThread(function()
        local map, players = "", 0
        local gs = FindFirstOf("GameStateBase")
        if gs and gs:IsValid() then map = gs:GetFullName():match("(/Game/[^%.]+)") or "" end
        for _, p in ipairs(FindAllOf("PlayerController") or {}) do
            if p:IsValid() and not p:GetFullName():find("Default__", 1, true) then players = players + 1 end
        end
        local f = io.open("fangshost_status.json.tmp", "w")
        if f then
            f:write(string.format('{"map": "%s", "players": %d, "time": %d}', map, players, os.time()))
            f:close(); os.remove("fangshost_status.json"); os.rename("fangshost_status.json.tmp", "fangshost_status.json")
        end
    end)
    return false
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
    ss:SetClientId("fangs-host"); ss:SetClientSecret("fangs-host")
    ss:SetNamespace("fangs"); ss:SetPublisherNamespace("hiddenleaf")
    ss:SetIamServerUrl(base .. "/iam"); ss:SetCloudSaveServerUrl(base .. "/cloudsave")
    ss:SetPlatformServerUrl(base .. "/platform"); ss:SetStatisticServerUrl(base .. "/social")
    ss:SetSessionBrowserServerUrl(base .. "/sessionbrowser"); ss:SetDSMControllerServerUrl(base .. "/dsmcontroller")
    ss:SetQosManagerServerUrl(base .. "/qosm"); ss:SetGameTelemetryServerUrl(base .. "/game-telemetry")
    ss:SetLobbyServerUrl(base .. "/lobby/"); ss:SetAchievementServerUrl(base .. "/achievement")
    ss:SetMatchmakingServerUrl(base .. "/matchmaking"); ss:SetSeasonPassServerUrl(base .. "/seasonpass")
    log("server SDK pointed at " .. base)
end

local lastLobbyGM = nil
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        local gm = FindFirstOf("BP_GM_Lobby_GameMode_C")
        if not (gm and gm:IsValid()) or gm == lastLobbyGM then return end
        local name = gm:GetFullName()
        if lastLobbyGM and lastLobbyGM:IsValid() and lastLobbyGM:GetFullName() == name then return end
        lastLobbyGM = gm
        local gi = FindFirstOf("BP_MOBAInstance_C")
        if gi and gi:IsValid() then gi.bUseAccelbyteBackend = true end
        configureServerSdk()
        gm:AccelByteServerLogin()
        log("lobby: server login requested")
        ExecuteWithDelay(4000, function()
            ExecuteInGameThread(function()
                local lvl = FindFirstOf("LE_Lobby_Map_C")
                if lvl and lvl:IsValid() then lvl:OnAccelByteLoginSuccess(); log("lobby: post-login init done") end
            end)
        end)
    end)
    return false
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

local function later(fn) ExecuteWithDelay(50, function() ExecuteInGameThread(fn) end) end
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
            if json then lvl:OnGetGameRecordSuccess(k, { JSONValue = json }); log("served game record " .. k)
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
local function startWithPresentPlayers(ctx)
    local gm, gs = FindFirstOf("BP_GM_Lobby_GameMode_C"), FindFirstOf("GS_Lobby_GameState_C")
    if not (gm and gm:IsValid() and gs and gs:IsValid()) then return end
    local n = gm.PlayerControllersRP:GetArrayNum()
    if n < 1 or n >= gm.MaxPlayers then return end
    log(string.format("lobby: owner launched with %d of %d players", n, gm.MaxPlayers))
    gm.MaxPlayers = n
    gs:FlushNetDormancy(); gs.MatchSize = n
    local push = StaticFindObject("/Script/NetCore.Default__NetPushModelHelpers")
    if push and push:IsValid() then push:MarkPropertyDirtyFromRepIndex(gs, 14, FName("MatchSize")) end
    local gi = FindFirstOf("BP_MOBAInstance_C")
    if gi and gi:IsValid() then gi.MapPlayerCount = n end
    -- the hook runs after the RPC body, which already gave up waiting for the missing players: run it again
    later(function() if gm:IsValid() then gm:ShowHeroSelectionMenu() end end)
end

local function installLaunchHook()
    return hook(LOBBY_PC .. ":StartHeroSelectionTimer", startWithPresentPlayers)
end

local shimDone = false
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        if shimDone then return end
        local s, all = pcall(function() return installShim() and installLaunchHook() end)
        if not s then log("shim install error: " .. tostring(all)) elseif all then
            shimDone = true; log("server CloudSave shim installed (data: " .. tostring(dataDir) .. ")")
        end
    end)
    return shimDone
end)
