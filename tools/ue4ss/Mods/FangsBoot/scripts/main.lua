-- FangsBoot: get a FANGS client from boot to logged-in without the dead Epic/Steam services.
--  * skips the intro logo movie (it otherwise waits for a key press)
--  * with -TestUser=<name> -TestPass=<pw> on the command line, reports Epic login as successful so the
--    game falls through to its built-in AccelByte username login (served by our backend).
local UEHelpers = require("UEHelpers")
-- UE4SS.log is buffered (not readable live); also keep our own line-flushed log next to the exe
local logFile = io.open("fangsboot.log", "a")
local function log(msg)
    print("[fangsboot] " .. tostring(msg) .. "\n")
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

local function commandLine()
    local ok, cl = pcall(function() return UEHelpers.GetKismetSystemLibrary():GetCommandLine():ToString() end)
    return ok and cl or ""
end

-- FindFirstOf/FindAllOf scan every object (~3 ms each), on the game thread: the game instance never changes,
-- so it is looked up once (again only if it ever becomes invalid).
local cachedGI = nil
local function gameInstance()
    if not (cachedGI and cachedGI:IsValid()) then cachedGI = FindFirstOf("BP_MOBAInstance_C") end
    return cachedGI
end

-- Online, the game names players after their computer (Windows computer name + a random suffix), visible to
-- everyone in the lobby and match. Use the FangsCE player name instead (re-applied after every map change,
-- where the game sets the computer name again).
local playerName = commandLine():match("%-TestUser=([%w_%-]+)")
if playerName and not commandLine():find("-FangsKeepName", 1, true) then
    every(2000, function()
        local gi = gameInstance()
        if not (gi and gi:IsValid()) then return end
        local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0)
        if not (pc and pc:IsValid() and pc.PlayerState and pc.PlayerState:IsValid()) then return end
        if pc.PlayerState:GetPlayerName():ToString() ~= playerName then pc:ServerChangeName(playerName) end
    end)
end


-- Hero select is a draft: each round lets only certain team slots pick ("rounds": [{"clients": [0]}, ...]),
-- written for full lobbies. When the slot whose turn it is is empty, nobody gets a Lock In button, the timer
-- runs out and the lobby kicks everyone. One round with every slot instead: whoever is there picks at once
-- (the server moves on when all present players have locked in). Set on the lobby game state before its
-- BeginPlay, which is where the game reads it (server and every player).
local ALL_PICK = '{"rounds":[{"clients":[0,1,2,3,4,5,6,7]}]}'
local allPickHooked = pcall(RegisterBeginPlayPreHook, function(ctx)
    local actor = ctx:get()
    if not (actor and actor:IsValid()) or actor:GetClass():GetFName():ToString() ~= "GS_Lobby_GameState_C" then return end
    -- (the Feb 2023 build already ships this order and has no separate small-lobby order)
    pcall(function() actor.DraftOrderJSONStr = ALL_PICK end)
    pcall(function() actor.DraftOrderBJSONStr = ALL_PICK end)
    log("hero select: everyone picks at once")
end)
if not allPickHooked then log("hero select: BeginPlay hook unavailable - draft order unchanged") end

-- Why a connection to a game server ended, in fangsboot.log (players can send it along with a problem report)
local NET_FAILURES = { [0] = "NetDriverAlreadyExists", "NetDriverCreateFailure", "NetDriverListenFailure", "ConnectionLost",
    "ConnectionTimeout", "FailureReceived", "OutdatedClient", "OutdatedServer", "PendingConnectionFailure",
    "NetGuidMismatch", "NetChecksumMismatch" }
every(2000, function()
    local path = "/Game/BluePrints/BP_MOBAInstance.BP_MOBAInstance_C:HandleNetworkError"
    if not StaticFindObject(path) then return end
    local ok, err = pcall(RegisterHook, path, function(ctx, failure, isServer)
        local f = failure:get()
        log("network error: " .. (NET_FAILURES[f] or tostring(f)))
    end)
    log(ok and "logging network errors" or ("network error hook failed: " .. tostring(err)))
    return true
end)

-- Why this player leaves a lobby (Shipping builds log nothing): the reason ReturnToMainMenu shows, the
-- matchmade-lobby timeout, the owner ending the lobby. Re-hooked when the lobby classes are loaded again.
do
    local LOBBY_PC = "/Game/BluePrints/Lobby/BP_PC_Lobby_PlayerController.BP_PC_Lobby_PlayerController_C"
    local LOBBY_MENU = "/Game/UI/Lobby/WB_LobbyMenu.WB_LobbyMenu_C"
    local diag = {
        [LOBBY_PC .. ":ReturnToMainMenu"] = function(ctx, msg)
            local ok, text = pcall(function() return msg:get():ToString() end)
            log("lobby: back to the main menu (" .. (ok and text ~= "" and text or "no reason given") .. ")")
        end,
        [LOBBY_MENU .. ":TimedOutFromQueue"] = function() log("lobby: timed out waiting for the match") end,
        [LOBBY_PC .. ":EndLobbyOnServer"] = function() log("lobby: this player ended the lobby") end,
    }
    local hooked = {}   -- path -> address of the UFunction hooked
    every(2000, function()
        for path, fn in pairs(diag) do
            local f = StaticFindObject(path)
            if f and f:IsValid() and hooked[path] ~= f:GetAddress() then
                hooked[path] = f:GetAddress()
                local ok, e = pcall(RegisterHook, path, function(...) pcall(fn, ...) end)
                if not ok then log("lobby diagnostics hook failed: " .. tostring(e)) end
            end
        end
    end)
end

local logoDone, loginDone = false, false
every(500, function()
    local gi = gameInstance()
    if not gi or not gi:IsValid() then return end
    if not logoDone then
        pcall(function()
            local logo = gi.WB_LogoRef   -- Feb 2023 build
            if logo and logo:IsValid() and logo:IsInViewport() and logo.bCanSkip then
                logo:EndMovie(); logoDone = true; log("skipped logo movie")
            end
        end)
        pcall(function()               -- Aug 2022 build: no WB_LogoRef, WB_Logo_C:End()
            for _, w in ipairs(FindAllOf("WB_Logo_C") or {}) do
                if not logoDone and w:IsValid() and w:IsInViewport() and w.bCanSkip then
                    w:End(); logoDone = true; log("skipped logo")
                end
            end
        end)
    end
    if not loginDone then
        local menu = nil
        for _, w in ipairs(FindAllOf("WB_AccountMenu_C") or {}) do
            if w:IsValid() and not w:GetFullName():find("Default__", 1, true) then menu = w end
        end
        if menu then
            loginDone = true
            if commandLine():find("-TestUser=", 1, true) then
                menu:OnEOSLoginDone(true, ""); log("faked EOS login -> username login")
            else
                log("no -TestUser on command line; leaving login to the account menu")
            end
        end
    end
    return logoDone and loginDone
end)
log("loaded")

-- Custom lobbies: the owner's Launch button normally appears only when the lobby is full
-- (WB_LobbyMenu.Tick -> GS_Lobby_GameState.IsMatchReady: players == MatchSize and everyone picked a side).
-- After each Tick, show it as soon as everyone present has picked a side; on Launch, FangsHost shrinks
-- the match to the players present.
local LOBBY_MENU_TICK = "/Game/UI/Lobby/WB_LobbyMenu.WB_LobbyMenu_C:Tick"
local function everyonePickedASide(gs)
    local n, picked = 0, true
    gs.PlayerArray:ForEach(function(_, e)
        local ps = e:get()
        if ps:IsValid() then
            n = n + 1
            local ok, slot = pcall(function() return ps.ChosenSlot end)
            if not ok or type(slot) ~= "number" or slot < 0 then picked = false end
        end
    end)
    return n > 0 and picked
end
local lobbyGS = nil
local function offerLaunch(menu)
    local gi, pc = gameInstance(), menu.BP_LobbyPlayerControllerRef
    if not (gi and gi:IsValid() and gi.MapGameMode == 4 and pc:IsValid()) then return end   -- custom lobbies only
    local ps = pc.PlayerState
    if not (ps:IsValid() and ps.IsLobbyOwner) then return end
    local sw = menu.LobbyStatusSwitch
    if sw:GetActiveWidgetIndex() == 1 then return end
    -- this runs on every lobby-menu tick: look the lobby state up only when it isn't known (or gone)
    if not (lobbyGS and lobbyGS:IsValid()) then lobbyGS = FindFirstOf("GS_Lobby_GameState_C") end
    if lobbyGS and lobbyGS:IsValid() and everyonePickedASide(lobbyGS) then sw:SetActiveWidgetIndex(1) end
end
local launchHooked = false
every(1000, function()
    if launchHooked or not StaticFindObject(LOBBY_MENU_TICK) then return end
    -- (with this UE4SS build a Blueprint-function hook runs after the function body)
    local ok, err = pcall(RegisterHook, LOBBY_MENU_TICK, function(ctx)
        local s, e = pcall(offerLaunch, ctx:get())
        if not s then log("offerLaunch: " .. tostring(e)) end
    end)
    launchHooked = true
    log(ok and "lobby: launch allowed before the lobby is full" or ("lobby menu hook failed: " .. tostring(err)))
    return launchHooked
end)

-- In-match HUD (WB_Round; WB_HUD in the Aug 2022 build): replace the "EARLY DEVELOPMENT" tag (an image, EarlyDevTag) with a
-- "COMMUNITY EDITION" label in the same place, using the font of one of the HUD's own texts.
local TAG_TEXT = "COMMUNITY EDITION"
local function child(round, class, name)   -- widget of round's WidgetTree (GetWidgetFromName isn't a UFunction here)
    local tag = round:GetFName():ToString() .. ".WidgetTree." .. (name or "")
    for _, w in ipairs(FindAllOf(class) or {}) do
        local ok, full = pcall(function() return w:IsValid() and w:GetFullName() end)
        if ok and type(full) == "string" and ((name and string.sub(full, -#tag) == tag) or (not name and string.find(full, tag, 1, true))) then
            return w
        end
    end
end
local function retag(round)
    if child(round, "TextBlock", "CommunityEditionTag") then return true end
    local img = child(round, "Image", "EarlyDevTag")
    if not (img and img:IsValid()) then return nil end              -- not there (yet)
    local panel = img:GetParent()
    if not (panel and panel:IsValid()) then return false end
    local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), round.WidgetTree, FName("CommunityEditionTag"))
    local ref = child(round, "TextBlock")
    if ref then tb:SetFont(ref.Font) end
    tb.Font.Size = 26
    tb:SetText(FText(TAG_TEXT))
    tb:SetShadowOffset({ X = 2.0, Y = 2.0 })
    tb:SetShadowColorAndOpacity({ R = 0.0, G = 0.0, B = 0.0, A = 0.6 })
    tb:SetRenderOpacity(0.8)
    tb:SetVisibility(4)                                              -- SelfHitTestInvisible, like the image
    local slot = panel:AddChildToCanvas(tb)
    slot:SetAutoSize(true)
    slot:SetPosition({ X = 24.0, Y = 32.0 })
    slot:SetZOrder(10)
    img:SetVisibility(1)                                             -- Collapsed
    return true
end
local retagged = {}   -- HUD full name -> true when done, or number of attempts so far
every(5000, function()   -- two object scans per run: not every second
    local huds = FindAllOf("WB_Round_C") or {}             -- Feb 2023 build
    for _, h in ipairs(FindAllOf("WB_HUD_C") or {}) do huds[#huds + 1] = h end   -- Aug 2022 build
    for _, round in ipairs(huds) do
        local key = round:IsValid() and round:GetFullName() or nil
        if key and not key:find("Default__", 1, true) and retagged[key] ~= true then
            local ok, done = pcall(retag, round)
            if ok and done then retagged[key] = true; log("HUD tag: " .. TAG_TEXT)
            else                                                 -- not there yet, or failed: retry for a while
                retagged[key] = (retagged[key] or 0) + 1
                if retagged[key] >= 15 then
                    retagged[key] = true
                    log(ok and "HUD tag: EarlyDevTag not found" or ("retag failed: " .. tostring(done)))
                end
            end
        end
    end
end)

-- Custom lobbies: "Battle" is 4v4 (8 players). This build's create-lobby screen makes it 6 (3v3).
local SELECT_GAME_MODE = "/Game/UI/MainMenu/WB_CreateLobby.WB_CreateLobby_C:SelectGameMode"
local BATTLE_PLAYERS = 8
local battleHooked = false
every(1000, function()
    if battleHooked or not StaticFindObject(SELECT_GAME_MODE) then return end
    local ok, err = pcall(RegisterHook, SELECT_GAME_MODE, function(ctx, selection)   -- runs after the body
        local s, e = pcall(function()
            if selection:get():ToString():lower() == "battle" then ctx:get().PlayerCount = BATTLE_PLAYERS end
        end)
        if not s then log("battle size: " .. tostring(e)) end
    end)
    battleHooked = true
    log(ok and ("custom lobbies: Battle is " .. BATTLE_PLAYERS .. " players") or ("create-lobby hook failed: " .. tostring(err)))
    return battleHooked
end)

-- ---------------------------------------------------------------------------------------------
-- Aug 2022 build (alpha7): custom lobbies. The client creates and lists them at a hard-coded Improbable
-- "Zeuz" URL (long gone). Keep the game in LAN mode, which skips those calls, and make them to our
-- backend instead (POST /zeuz/sessions, GET /zeuz/sessions.txt); the results go back into the game's own
-- lobby code. The PLAY button's "previous game" check also asks Zeuz: answer it at once so PLAY goes on.
local function gameVersion()
    local f = io.open("../../Content/Data/version.txt", "r")
    if not f then return "" end
    local v = f:read("l") or ""; f:close()
    return v
end

local function backendBase()   -- from the connection settings the launcher writes (AccelByte BaseUrl)
    for _, dir in ipairs({ (os.getenv("LOCALAPPDATA") or "") .. "\\MOBA\\Saved\\Config\\WindowsNoEditor",
                           "..\\..\\Saved\\Config\\WindowsNoEditor" }) do
        local f = io.open(dir .. "\\Engine.ini", "r")
        if f then
            local text = f:read("a"); f:close()
            local base = text:match('BaseUrl="(http[^"]-)"')
            if base then return base end
        end
    end
end

-- A plain-text list from our backend (one line per entry, tab-separated fields). Returns a function to call from
-- a game-thread loop: it returns the list, or nil while there is none yet. The last list received is kept in
-- <cache> next to the game and returned at once on the next start, until the backend answers again. The request
-- needs the game instance (VaRest is one of its subsystems); a failed one is retried after 5 s.
local function backendList(path, cache)
    local req, asked, rows, fresh = nil, 0, nil, false
    local function parse(text)
        local list = {}
        for line in text:gmatch("[^\n]+") do
            local fields = {}
            for f in line:gmatch("[^\t]+") do fields[#fields + 1] = f end
            list[#list + 1] = fields
        end
        return list
    end
    local f = cache and io.open(cache, "r")
    if f then rows = parse(f:read("a")); f:close() end
    return function()
        if fresh then return rows end
        if req then
            local status = req:IsValid() and req:GetStatus() or 2   -- 0 not started, 1 processing, 2/3 failed, 4 ok
            if status < 2 and os.time() - asked < 20 then return rows end
            if status == 4 and req:GetResponseCode() == 200 then
                local text = req:GetResponseContentAsString(true):ToString()
                rows, fresh = parse(text), true
                local out = cache and io.open(cache, "w")
                if out then out:write(text); out:close() end
            end
            req = nil
        elseif os.time() - asked >= 5 then
            local gi, base = gameInstance(), backendBase()
            if not (gi and gi:IsValid() and base) then return rows end
            local vr = FindFirstOf("VaRestSubsystem")
            if not (vr and vr:IsValid()) then return rows end
            asked = os.time()
            req = vr:ConstructVaRestRequestExt(0, 0)   -- GET, no body
            req:ProcessURL(base .. path)
        end
        return rows
    end
end

if gameVersion():find("^alpha7") then
    local PLAY_MENU = "/Game/UI/MainMenu/WB_PlayMenu.WB_PlayMenu_C"

    local pending = nil   -- the one lobby request in flight: {req, kind = "create"|"list", pm, started}
    local lastCreate = 0
    local function liveMenu()   -- the play menu on screen right now (none while loading or in a game)
        local gi = gameInstance()
        local menu = gi and gi:IsValid() and gi.WB_MainMenuRef
        if not (menu and menu:IsValid() and menu:IsInViewport()) then return nil end
        local pm = menu.WB_PlayMenu
        return pm and pm:IsValid() and pm or nil
    end
    local function request(kind, pm, verb, path, body)
        if kind == "create" then lastCreate = os.time() end
        local base = backendBase()
        if not base then return log("lobby: no backend address (Engine.ini)") end
        local vr = FindFirstOf("VaRestSubsystem")
        -- verb 0 GET / 1 POST. Content type: JSON (2) for POSTs; a GET must have none (0 = URL parameters): with a
        -- JSON body the GET never went out and sat "processing" until the request object was garbage-collected
        local req = vr:ConstructVaRestRequestExt(verb, verb == 0 and 0 or 2)
        req:SetHeader("Authorization", "Bearer accelbyte/" .. FindFirstOf("AccelByte"):GetUserClientToken():ToString())
        if body then
            local obj = vr:ConstructVaRestJsonObject()
            for k, v in pairs(body) do obj:SetStringField(k, v) end
            req:SetRequestObject(obj)
        end
        req:ProcessURL(base .. path)
        pending = { req = req, kind = kind, pm = pm, started = os.time() }
        log("lobby: " .. kind .. " request sent")
    end

    local function showLobbies(pm, text)
        pm:ResetLobbyList()
        local cls = StaticFindObject("/Game/UI/MainMenu/WB_GameSession.WB_GameSession_C")
        local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local n = 0
        for line in text:gmatch("[^\n]+") do
            local id, addr, name, owner, mapName, mapLevel, players, maxp =
                line:match("^(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.-)$")
            if id then   -- the same fields the game's own list code sets (WB_PlayMenu UpdateUIServers)
                local w = wbl:Create(pm, cls, nil)
                w.LobbyName = FText(name); w.OwnerName = FText(owner)
                w.MapName = mapLevel; w.ServerLevel = mapName
                w.Capacity = tonumber(players) or 0; w.MaxPlayers = tonumber(maxp) or 8
                w.PayloadId = id; w.ServerId = id; w.ServerAddress = addr
                pm.LobbyList:AddChild(w)
                n = n + 1
            end
        end
        pm:FinishedSearching()
        log("lobby: " .. n .. " lobbies listed")
    end

    local function finishRequest()
        local p = pending
        if not p.req:IsValid() then pending = nil; return log("lobby: " .. p.kind .. " request lost") end
        local status = p.req:GetStatus()      -- 0 not started, 1 processing, 2/3 failed, 4 succeeded
        if status < 2 then
            if os.time() - p.started > 30 then status = 2 else return end
        end
        pending = nil
        local code = p.req:GetResponseCode()
        if status == 4 and code == 200 then
            if p.kind == "create" then
                p.pm:OnComplete_8D51ACCE4F51DE2218C3C9BCE91C5034(p.req)   -- the game's own "lobby reserved" handler
                log("lobby: created, joining")
            else
                local pm = liveMenu()   -- the player may have left the menu meanwhile (joined, started a game)
                if pm and pm:GetAddress() == p.pm:GetAddress() then
                    showLobbies(pm, p.req:GetResponseContentAsString(true):ToString())
                end
            end
        else
            log("lobby: " .. p.kind .. " request failed (status " .. status .. ", HTTP " .. code .. ")")
            local pm = liveMenu()
            if pm and pm:GetAddress() == p.pm:GetAddress() then   -- not an endless spinner
                if p.kind == "list" then showLobbies(pm, "") else pm:FinishedSearching() end
            end
        end
    end

    every(200, function()
        local gi = gameInstance()
        if not (gi and gi:IsValid()) then return end
        if not gi.UseLAN then gi.UseLAN = true end
        if pending then
            local ok, e = pcall(finishRequest)
            if not ok then pending = nil; log("lobby: " .. tostring(e)) end
        end
    end)

    -- The Join view searches through an internal Blueprint call (the mode button runs FindLobbies on itself),
    -- which the hooks below never see: answer every search the menu shows (LobbyJoinSwitcher page 1 =
    -- "searching") with our list. Also hide the replay button: there are no replays and it crashed the game.
    local lastList = 0
    every(500, function()
        local pm = liveMenu()
        if not pm then return end
        local replay = pm.Button_477
        if replay and replay:IsValid() and replay:GetVisibility() ~= 1 then replay:SetVisibility(1) end   -- Collapsed
        -- GetSessions: set by a lobby search, cleared by "create lobby" (whose spinner is the same page)
        if not pending and pm.GetSessions and pm.LobbyJoinSwitcher:GetActiveWidgetIndex() == 1
                and os.time() - lastList >= 2 and os.time() - lastCreate > 30 then
            lastList = os.time()
            request("list", pm, 0, "/zeuz/sessions.txt")
        end
    end)

    local function onCreate(ctx)
        local pm = ctx:get()
        local cfg = table.concat({ "max_players", tostring(pm.PlayerSize), "lobby_name", pm.LobbyName:ToString(),
            "player_count", "1", "map_name", pm.LobbyMap:ToString(), "map_level", pm.FindMapLevel:ToString() }, ",")
        request("create", pm, 1, "/zeuz/sessions", { session_config = cfg })
    end
    local function onFind(ctx) request("list", ctx:get(), 0, "/zeuz/sessions.txt") end
    local function onPreviousGameCheck(ctx)   -- PLAY: the reconnect check listed Zeuz sessions; there are none
        local pm = ctx:get()
        if pm.CheckingReconnect then pm:CheckingPreviousGame(true); log("lobby: no previous game") end
    end

    -- PLAY should form games: if the mode card is on Tutorial/Training (fresh installs), switch it to Casual
    -- the way the mode chooser does (saved in the player's settings; CHANGE still works). Once per start.
    local casualDone = false
    every(1000, function()
        local gi = gameInstance()
        local menu = gi and gi:IsValid() and gi.WB_MainMenuRef
        if casualDone or not (menu and menu:IsValid() and menu:IsInViewport()) then return end
        casualDone = true
        if gi.MapGameMode ~= 0 and gi.MapGameMode ~= 1 then return end
        local ok, e = pcall(function()
            gi:ShowChoseGameMode()
            gi.WB_ChoseGameModeRef:SetCasualMode()
        end)
        log(ok and "PLAY mode set to Casual" or ("couldn't set Casual: " .. tostring(e)))
        return casualDone
    end)

    local hooked = {}
    local wanted = {
        CreateLobbyAndJoin = onCreate,
        FindLobbies = onFind,
        BndEvt__FindLobbyBtn_K2Node_ComponentBoundEvent_18_OnButtonClickedEvent__DelegateSignature = onFind,
        BndEvt__SearchInput_K2Node_ComponentBoundEvent_10_OnEditableTextBoxCommittedEvent__DelegateSignature = onFind,
        ZeuzIMSGetServerList = onPreviousGameCheck,
    }
    every(1000, function()
        for fn, cb in pairs(wanted) do
            local path = PLAY_MENU .. ":" .. fn
            if not hooked[fn] and StaticFindObject(path) then
                local ok, err = pcall(RegisterHook, path, function(ctx, ...)   -- runs after the event body
                    local s, e = pcall(cb, ctx, ...)
                    if not s then log("lobby (" .. fn .. "): " .. tostring(e)) end
                end)
                hooked[fn] = true
                if not ok then log("lobby hook failed " .. fn .. ": " .. tostring(err)) end
            end
        end
        local n = 0
        for _ in pairs(hooked) do n = n + 1 end
        if n == 5 then log("custom lobbies via our backend (Aug 2022 build)") end
        return n == 5
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Main menu (Feb 2023 build). Dead services off: the Battle Pass and Store tabs, the battle-pass currency and
-- the "Join our Discord" banner, the currencies (realm gold, soul cores: nothing to spend them on). The missions
-- list (no missions any more) becomes "PLAYERS ONLINE" with the online players' names and the number of free game
-- servers below (backend /fangsapi/prod/server-status, every 15 s while the menu is on screen). Tabs are
-- collapsed, never removed: SelectMainMenuTab picks the tab buttons by their position.
-- Pages other than Home (Leaderboard, Collection > Artifacts, ...) have no background of their own: they show
-- the 4K splash video (ClientBkg). Where it doesn't play (Wine without the codec) the image renders white;
-- then a dark static background replaces it.
if not gameVersion():find("^alpha7") then
    local SELECT_TAB = "/Game/UI/MainMenu/WB_MainMenu.WB_MainMenu_C:SelectMainMenuTab"
    local TAB_BATTLEPASS, TAB_STORE = 4, 5   -- ENUM_MainMenu
    local COLLAPSED = 1
    local STATIC_BKG = "/Game/UI/Textures/Client/HeroSelect/HeroMasteryBkg.HeroMasteryBkg"

    local cleaned, shownAt, bkgFixed, onlineText, namesBox, tree = nil, 0, false, nil, nil, nil
    local MAX_NAMES, MUTED = 15, { R = 0.78, G = 0.82, B = 0.86, A = 0.85 }
    local rainbow, made = {}, 0   -- letters of names with the "rainbow" style (animated below); widgets made
    local function fixBackground(menu)
        local player = menu.BkgMediaPlayer
        if player and player:IsValid() and player:IsPlaying() then return true end
        if os.time() - shownAt < 5 then return false end   -- the video opens asynchronously
        local tex = StaticFindObject(STATIC_BKG)
        if tex and tex:IsValid() then
            menu.ClientBkg:SetBrushFromTexture(tex, false)
        else   -- the unplayed video texture is white: tint it dark
            menu.ClientBkg:SetColorAndOpacity({ R = 0.015, G = 0.03, B = 0.06, A = 1 })
        end
        if player and player:IsValid() then player:Close() end
        log("menu: background video not playing, static background instead")
        return true
    end
    local function hide(what, widget)
        local ok, e = pcall(function() widget:SetVisibility(COLLAPSED) end)
        if not ok then log("menu: can't hide " .. what .. ": " .. tostring(e)) end
    end
    local function cleanMenu(menu)
        local pm = menu.WB_PlayMenu
        hide("battle pass tab", menu.BattlePassTab); hide("store tab", menu.ShopTab)
        hide("battle pass currency", menu.BpcTipBtn); hide("missions button", menu.MissionBtn)
        hide("discord banner", pm.PromoButton)
        hide("realm gold", menu.HardCurrencyTipBtn); hide("soul cores", menu.SoftCurrencyTipBtn)
        -- WB_Missions: VerticalBox_1 > [HorizontalBox_0 > "MISSIONS" header, Image_106 line, ScaleBox_0 > cards]
        local ok, e = pcall(function()
            local cards = pm.WB_Missions.MissionsSizeBox:GetParent()
            cards:SetVisibility(COLLAPSED)
            local column = cards:GetParent()
            onlineText = column:GetChildAt(0):GetChildAt(0)
            onlineText:SetText(FText("PLAYERS ONLINE"))
            -- the names: small, muted lines below the header's line (the free game servers last)
            tree = pm.WB_Missions.WidgetTree
            namesBox = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"), tree, FName("FCE_OnlineNames"))
            column:AddChild(namesBox):SetPadding({ Left = 2.0, Top = 6.0, Right = 0.0, Bottom = 0.0 })
        end)
        if not ok then log("menu: missions list: " .. tostring(e)) end
        log("menu: cleaned up")
    end

    local function label(text)
        made = made + 1
        local t = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName("FCE_Online" .. made))
        t:SetFont(onlineText.Font); t.Font.Size = 13
        pcall(function() t:SetColorAndOpacity({ SpecifiedColor = MUTED, ColorUseRule = 0 }) end)
        t:SetText(FText(text))
        return t
    end
    local function showNames(names, servers)   -- names: {name, style}
        namesBox:ClearChildren()
        rainbow = {}
        for _, n in ipairs(names) do
            if n.style == "rainbow" then   -- one block per letter, coloured by the loop below
                made = made + 1
                local row = StaticConstructObject(StaticFindObject("/Script/UMG.HorizontalBox"), tree, FName("FCE_Online" .. made))
                for i = 1, #n.name do
                    local l = label(n.name:sub(i, i))
                    row:AddChild(l); rainbow[#rainbow + 1] = l
                end
                namesBox:AddChild(row)
            else
                namesBox:AddChild(label(n.name))
            end
        end
        namesBox:AddChild(label(servers)):SetPadding({ Left = 0.0, Top = 10.0, Right = 0.0, Bottom = 0.0 })
    end
    local function hsv(h)   -- hue 0..1 at full saturation and value
        local i, f = math.floor(h * 6), h * 6 - math.floor(h * 6)
        local q, t = 1 - f, f
        local rgb = ({ { 1, t, 0 }, { q, 1, 0 }, { 0, 1, t }, { 0, q, 1 }, { t, 0, 1 }, { 1, 0, q } })[i % 6 + 1]
        return { R = rgb[1], G = rgb[2], B = rgb[3], A = 1.0 }
    end
    local phase = 0
    every(100, function()
        if #rainbow == 0 then return end
        phase = (phase + 0.02) % 1
        for i, l in ipairs(rainbow) do
            if l:IsValid() then pcall(function() l:SetColorAndOpacity({ SpecifiedColor = hsv((phase + i * 0.11) % 1), ColorUseRule = 0 }) end) end
        end
    end)

    local vr, req, asked = nil, nil, 0
    local function updateOnline()
        if req then
            local status = req:IsValid() and req:GetStatus() or 2   -- 0 not started, 1 processing, 2/3 failed, 4 ok
            if status < 2 and os.time() - asked < 20 then return end
            local text = status == 4 and req:GetResponseCode() == 200 and req:GetResponseContentAsString(true):ToString()
            local first, rest = (text or ""):match("^([^\n]*)\n?(.*)$")
            local n, free, total = (first or ""):match("^(%d+)\t(%d+)\t(%d+)")
            n, free, total = tonumber(n), tonumber(free), tonumber(total)
            if n and namesBox and namesBox:IsValid() then
                local names = {}
                for line in rest:gmatch("[^\n]+") do
                    local name, style = line:match("^([^\t]+)\t?(.*)$")
                    if #names < MAX_NAMES then names[#names + 1] = { name = name, style = style } end
                end
                if n > #names and #names > 0 then names[#names + 1] = { name = "+" .. (n - #names) .. " more" } end
                if #names == 0 then names[1] = { name = n .. (n == 1 and " player" or " players") } end
                showNames(names, free == 0 and ("all " .. total .. " game servers busy")
                    or (free .. " of " .. total .. " game servers free"))
            end
            req = nil
        elseif os.time() - asked >= 15 then
            asked = os.time()
            local base = backendBase()
            if not base then return end
            if not (vr and vr:IsValid()) then vr = FindFirstOf("VaRestSubsystem") end
            req = vr:ConstructVaRestRequestExt(0, 0)   -- GET, no body
            -- logged in: the names are only sent to players (the counts to anyone)
            pcall(function() req:SetHeader("Authorization", "Bearer " .. FindFirstOf("AccelByte"):GetUserClientToken():ToString()) end)
            req:ProcessURL(base .. "/fangsapi/prod/server-status?v=2")
        end
    end

    every(1000, function()
        local gi = gameInstance()
        local menu = gi and gi:IsValid() and gi.WB_MainMenuRef
        if not (menu and menu:IsValid() and menu:IsInViewport()) then return end
        if cleaned ~= menu:GetAddress() then   -- a new main menu after every game
            cleaned, asked, shownAt, bkgFixed = menu:GetAddress(), 0, os.time(), false
            cleanMenu(menu)
        end
        if not bkgFixed then
            local ok, done = pcall(fixBackground, menu)
            bkgFixed = done or not ok
            if not ok then log("menu: background: " .. tostring(done)) end
        end
        updateOnline()
    end)

    -- Joining a custom lobby from the lobby list: the PLAY button sets the game mode to Casual (anything but
    -- Ranked becomes Casual, "Join a lobby" too), and the clicked lobby is saved and joined with it. In the lobby
    -- that player then counts as matchmade: the lobby screen's 45 s "Failed to Connect to Match" timeout runs
    -- (the owner launching later sends them back to the menu, which ends the lobby for everyone), and the lobby
    -- server is told it is a Casual lobby. While the list is searching, keep the mode at Custom.
    local CASUAL, CUSTOM = 2, 4
    every(250, function()
        local gi = gameInstance()
        local menu = gi and gi:IsValid() and gi.WB_MainMenuRef
        if not (menu and menu:IsValid() and menu:IsInViewport()) then return end
        if menu.WB_PlayMenu.GetSessions and gi.MapGameMode == CASUAL then   -- only PLAY's Casual: not Training etc.
            log("lobby list: game mode " .. gi.MapGameMode .. " -> Custom")
            gi.MapGameMode = CUSTOM
        end
    end)

    -- The Store also opens from "unlock" buttons on items you don't own (none: everything is owned).
    every(1000, function()
        if not StaticFindObject(SELECT_TAB) then return end
        local ok, e = pcall(RegisterHook, SELECT_TAB, function(ctx, tab)   -- runs after the body
            local t, menu = tab:get(), ctx:get()
            -- calling a Blueprint function from inside a Blueprint hook can hang the game thread: defer it
            if t == TAB_BATTLEPASS or t == TAB_STORE then
                ExecuteInGameThreadWithDelay(1, function() if menu:IsValid() then menu:SelectMainMenuTab(0) end end)
            end
        end)
        if not ok then log("menu: tab hook failed: " .. tostring(e)) end
        return true
    end)
end

-- ---------------------------------------------------------------------------------------------
-- End of match: the victory/defeat screen plays a video in an image (WB_GameResult.BattleEndMovie). Where it
-- doesn't play (Wine without the codec) that image is a big white panel over the screen: hide it then.
do
    local GAME_RESULT = "/Game/UI/Hud/InRound/NewFolder/WB_GameResult.WB_GameResult_C"
    local function checkMovie(ctx)
        local w = ctx:get()
        ExecuteInGameThreadWithDelay(3000, function()
            local ok, e = pcall(function()
                if not w:IsValid() or (w.MediaPlayer:IsValid() and w.MediaPlayer:IsPlaying()) then return end
                w.BattleEndMovie:SetVisibility(1)
                log("end of match: video not playing, hidden")
            end)
            if not ok then log("end of match: " .. tostring(e)) end
        end)
    end
    local hooked = {}   -- function -> address of the UFunction hooked (the class is reloaded for every match)
    every(1000, function()
        for _, fn in ipairs({ "PlayEndMatchVictoryMovie", "PlayEndMatchDefeatMovie" }) do
            local path = GAME_RESULT .. ":" .. fn
            local f = StaticFindObject(path)
            if f and f:IsValid() and hooked[fn] ~= f:GetAddress() then
                local ok, e = pcall(RegisterHook, path, checkMovie)   -- runs after the event body
                hooked[fn] = f:GetAddress()
                if not ok then log("end of match hook failed: " .. tostring(e)) end
            end
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Friends (Feb 2023 build). The game connects to the lobby while logging in, so when the main menu's social
-- panel is built the connection is already up and it takes its "reconnected" path, which skips fetching the
-- friend list, friend requests, presence and the party (WB_Social_Accelbyte: Construct -> bConnectedBefore).
-- Once per session, run its first-connection path instead. Later menus (after a game) reuse the lists.
if not gameVersion():find("^alpha7") then
    every(1000, function()
        local gi = gameInstance()
        local menu = gi and gi:IsValid() and gi.WB_MainMenuRef
        if not (menu and menu:IsValid() and menu:IsInViewport()) then return end
        local social = menu.WB_Social_Accelbyte
        if not (social and social:IsValid()) then return end
        if social.bConnectedBefore then
            social.bConnectedBefore = false
            social:OnConnectedToLobbySocket()
            log("friends: fetching friends, requests, presence and party")
        end
        return true
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Cut content back in play: items the developers took out of the in-match pick lists although they still
-- work (boons, artifacts, hero augments). The item picker offers the player's own hero's PossibleItems and
-- GenericItems (the server doesn't check equipped items against them), so the backend's list for this build
-- (/fangsapi/prod/restored-items) is added to each new hero this player controls.
do
    local fetch = backendList("/fangsapi/prod/restored-items?build=" .. gameVersion(), "fangsboot_restored.txt")
    local restore, rowsSeen, patched = nil, nil, nil
    local function patch(pawn, cls)
        local added, missing = 0, 0
        for _, r in ipairs(restore) do
            if r.cls == "*" or r.cls == cls then
                local item, list = StaticFindObject(r.path), pawn[r.list]
                if item and item:IsValid() then
                    local have = false
                    list:ForEach(function(_, e) if e:get():GetAddress() == item:GetAddress() then have = true end end)
                    if not have then list[list:GetArrayNum() + 1] = item; added = added + 1 end
                else
                    missing = missing + 1
                end
            end
        end
        log(string.format("restored items: %d added to %s%s", added, cls, missing > 0 and (" (" .. missing .. " not loaded)") or ""))
    end
    every(1000, function()
        local rows = fetch()
        if not rows then return end
        if rows ~= rowsSeen then
            rowsSeen, restore = rows, {}
            for _, r in ipairs(rows) do restore[#restore + 1] = { cls = r[1], list = r[2], path = r[3] } end
            log("restored items: " .. #restore .. " for this build")
        end
        if #restore == 0 then return end
        local gi = gameInstance()
        if not (gi and gi:IsValid()) then return end
        local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0)
        local pawn = pc and pc:IsValid() and pc.Pawn
        if not (pawn and pawn:IsValid()) then return end
        local name = pawn:GetFullName()
        if patched == name then return end
        local cls = pawn:GetClass():GetFName():ToString()
        if not cls:find("_Char%d*_C$") then return end   -- heroes only (BP_<Hero>_Char_C; Somnia is BP_BookMage_Char2_C)
        patched = name
        patch(pawn, cls)
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Restored items whose name or description points to a string-table entry this build doesn't have: Mask of Mana and
-- Allseer (their texts exist under other keys) and Mikado's Power Gong (no text in Feb 2023; Aug 2022's, in the Feb
-- style). The item assets are patched in memory each time they are (re)loaded.
do
    local POSITIONAL = "/Game/UI/Localization/LOC_EN_AUGMENTS_POSITIONAL.LOC_EN_AUGMENTS_POSITIONAL"
    local FIX = {
        { "/Game/Items/Characters/Generic/Garden/EnergyDrink/ITEM_Generic_EnergyDrink.ITEM_Generic_EnergyDrink",
          desc = { POSITIONAL, "position_energydrink_desc" } },
        { "/Game/Items/Characters/Generic/Garden/Prescience/ITEM_Generic_Prescience.ITEM_Generic_Prescience",
          desc = { POSITIONAL, "position_prescience_desc" } },
        { "/Game/Gameplay/Abilities/Player/SideKick/Skill3/Items/ITEM_Sidekick_Skill3_AOECC.ITEM_Sidekick_Skill3_AOECC",
          name = "Mikado's Power Gong",
          desc = "<RichText.TooltipKeyWords>#LOC_EN_ABILITIES_SIDEKICK|sidekick_ult_title# [ULT]</><br><br>Activating "
              .. "<RichText.TooltipKeyWords>#LOC_EN_ABILITIES_SIDEKICK|sidekick_ult_title#</> knocks nearby enemies into the "
              .. "air, and enemies near you are continually <RichText.TooltipEffects>slowed by 25%</>." },
    }
    local patched, KTL = {}, nil
    local function text(v)   -- {string table, key} or plain text
        if type(v) == "table" then return KTL:TextFromStringTable(FName(v[1]), v[2]) end
        return FText(v)
    end
    every(2000, function()
        KTL = KTL or StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        for _, f in ipairs(FIX) do
            local item = StaticFindObject(f[1])
            if item and item:IsValid() and patched[f[1]] ~= item:GetAddress() then
                patched[f[1]] = item:GetAddress()
                if f.name then item.ItemName = text(f.name) end
                if f.desc then item.ItemDescription = text(f.desc) end
                log("item texts: " .. f[1]:match("([^.]+)$") .. ": " .. item.ItemDescription:ToString():sub(1, 40))
            end
        end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Unreleased heroes (Feb 2023 build): heroes the developers never released (the backend's list for this build,
-- /fangsapi/prod/unreleased-heroes) are owned like the others but kept apart: an "UNRELEASED HEROES" section in
-- Inventory > Heroes, a toggle in custom lobbies' hero select (released heroes are the default; matchmade lobbies
-- only show released ones) and a notice the first time one is picked in a lobby.
-- Calling a Blueprint function inside a Blueprint hook can hang the game thread: the hooks note what happened
-- and the work runs deferred (later()).
if not gameVersion():find("^alpha7") then
    local fetch = backendList("/fangsapi/prod/unreleased-heroes?build=" .. gameVersion(), "fangsboot_unreleased.txt")
    local UNREL, rowsSeen, ORANGE, CUSTOM = nil, nil, { R = 1.0, G = 0.62, B = 0.18, A = 1.0 }, 4
    -- the game's own pictures standing in for card art these heroes lack
    local ICONS = { Warlock = "/Game/UI/Thumbnails/Warlock_Thumb.Warlock_Thumb",
        Priest = "/Game/UI/Textures/HeroSelectPortraits/PriestPortrait.PriestPortrait",
        Scythe = "/Game/UI/Textures/Hero3DRenders/Scythe3DFace.Scythe3DFace",
        Sniper = "/Game/UI/Thumbnails/Sniper_Thumb.Sniper_Thumb",
        BladeMaster = "/Game/UI/Textures/HeroSelectPortraits/RowanPortrait.RowanPortrait" }
    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local own = {}           -- address of a card we made -> hero (its clicks are ours to handle)
    local mode, toggle, lobby, warned, menuChecked = "released", nil, nil, {}, nil

    local function later(what, fn)
        ExecuteInGameThreadWithDelay(1, function()
            local ok, e = pcall(fn)
            if not ok then log("unreleased heroes (" .. what .. "): " .. tostring(e)) end
        end)
    end
    local function children(panel)
        local t = {}
        for i = 0, panel:GetChildrenCount() - 1 do t[#t + 1] = panel:GetChildAt(i) end
        return t
    end
    local function heroOf(w)
        local ok, s = pcall(function() return w.HeroType:ToString() end)
        return ok and s or nil
    end

    local function notice(owner, hero)
        local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gameInstance(), 0)
        -- our own dialog: the game's shared one keeps other callers' OK handlers
        local w = WBL:Create(owner, StaticFindObject("/Game/UI/MainMenu/WB_Confirm.WB_Confirm_C"), pc)
        w.Message = FText(UNREL[hero] .. " was never released by the developers.<br>Unfinished: art, sounds, "
            .. "balance and texts may be missing or broken.")
        w.Title = FText("UNRELEASED HERO"); w.OkLabel = FText("GOT IT"); w.CancelLabel = FText("")
        w:SetIcon(nil); w:RefreshUI()
        pcall(function() w.HeaderTxt:SetColorAndOpacity({ SpecifiedColor = ORANGE, ColorUseRule = 0 }) end)
        w:AddToViewport(210); w:FocusOnButton()
    end

    -- Inventory > Heroes: the Blueprint lists every owned hero with card art; move the unreleased ones into an
    -- own section below and add cards for those it skipped (no card art).
    local function inventory(h)
        local list = h.HeroButtonList
        local scroll = list:GetParent()
        local wrap
        for _, w in ipairs(children(scroll)) do if w:GetFName():ToString() == "FCE_UnreleasedHeroes" then wrap = w end end
        if not wrap then
            local tbc = StaticFindObject("/Script/UMG.TextBlock")
            local title = StaticConstructObject(tbc, h.WidgetTree, FName("FCE_UnreleasedTitle"))
            title:SetFont(h.ChampionNameTxt.Font); title.Font.Size = 34
            title:SetText(FText("UNRELEASED HEROES"))
            pcall(function() title:SetColorAndOpacity({ SpecifiedColor = ORANGE, ColorUseRule = 0 }) end)
            local note = StaticConstructObject(tbc, h.WidgetTree, FName("FCE_UnreleasedNote"))
            note:SetFont(h.OwnedHeroesTxt.Font); note.Font.Size = 18
            note:SetText(FText("Never finished or released by the developers: expect missing art, bugs and odd balance."))
            pcall(function() note:SetAutoWrapText(true) end)
            wrap = StaticConstructObject(StaticFindObject("/Script/UMG.WrapBox"), h.WidgetTree, FName("FCE_UnreleasedHeroes"))
            wrap:SetInnerSlotPadding({ X = -24.0, Y = 0.0 })   -- as the released heroes' list
            wrap:SetRenderTranslation({ X = 0.0, Y = -20.0 })
            scroll:AddChild(title):SetPadding({ Left = 48.0, Top = 16.0, Right = 32.0, Bottom = 0.0 })
            scroll:AddChild(note):SetPadding({ Left = 48.0, Top = 4.0, Right = 32.0, Bottom = 0.0 })
            scroll:AddChild(wrap):SetPadding({ Left = 32.0, Top = 32.0, Right = 32.0, Bottom = 32.0 })
        end
        wrap:ClearChildren()
        local have, owned = {}, 0
        for _, w in ipairs(children(list)) do
            local hero = heroOf(w)
            if hero and UNREL[hero] then
                list:RemoveChild(w); wrap:AddChild(w)
                w.HeroNameTxt:SetText(FText(UNREL[hero]:upper()))
                have[hero] = true
            elseif w.Owned then
                owned = owned + 1
            end
        end
        local cls = StaticFindObject("/Game/UI/MainMenu/WB_HeroButton.WB_HeroButton_C")
        for hero, name in pairs(UNREL) do
            if not have[hero] then
                local b = WBL:Create(h, cls, nil)
                b.HeroType = hero; b.Owned = true; b.HeroLevel = 0
                local tex = ICONS[hero] and StaticFindObject(ICONS[hero])
                if tex and tex:IsValid() then b.HeroIcon = tex end
                wrap:AddChild(b)
                b.HeroNameTxt:SetText(FText(name:upper()))
                own[b:GetAddress()] = hero
            end
        end
        h.OwnedHeroesTxt:SetText(FText(tostring(owned)))
        h.TotalHeroesTxt:SetText(FText("/" .. list:GetChildrenCount()))
    end

    -- Hero select: show either the released or the unreleased heroes (BladeMaster has no preview asset, so the
    -- Blueprint never lists it: added here), fill the buttons from the start and re-centre the rows.
    local function regroup(hs)
        local entries, seen = {}, {}
        hs.HeroButtonList:ForEach(function(_, e)
            local b = e:get()
            local hero = heroOf(b)
            if b:GetVisibility() == 0 and hero and (mode == "unreleased") == (UNREL[hero] ~= nil) then
                entries[#entries + 1] = { hero = hero, icon = b.HeroIcon, owned = b.Owned }; seen[hero] = true
            end
        end)
        if mode == "unreleased" then
            for hero in pairs(UNREL) do
                local tex = not seen[hero] and ICONS[hero] and StaticFindObject(ICONS[hero])
                if tex and tex:IsValid() then entries[#entries + 1] = { hero = hero, icon = tex, owned = true } end
            end
        end
        hs:HideAllHeroButtons()
        local i = 0
        hs.HeroButtonList:ForEach(function(_, e)
            i = i + 1
            local en, b = entries[i], e:get()
            if en then
                b.HeroType = en.hero; b.HeroIndex = 0; b.HeroIcon = en.icon; b.Owned = en.owned
                b.LobbyHeroSelectRef = hs; b:SetVisibility(0); b:UpdateToolTip()
            end
        end)
        hs:CorrectHeroButtonRowCenter()
        if toggle and toggle:IsValid() then   -- the class filters reset every filter button's look
            toggle.FilterSelected:SetVisibility(mode == "unreleased" and 4 or 2)
            toggle.FilterIcon:SetColorAndOpacity(mode == "unreleased" and ORANGE or { R = 1.0, G = 1.0, B = 1.0, A = 1.0 })
        end
    end

    local hooked = {}   -- function path -> address of the UFunction hooked (classes are reloaded)
    local function hook(path, fn)
        local f = StaticFindObject(path)
        if not (f and f:IsValid()) or hooked[path] == f:GetAddress() then return end
        hooked[path] = f:GetAddress()
        local ok, e = pcall(RegisterHook, path, function(ctx, ...)
            local s, err = pcall(fn, ctx, ...)
            if not s then log("unreleased heroes hook: " .. tostring(err)) end
        end)
        if not ok then log("unreleased heroes: can't hook " .. path .. ": " .. tostring(e)) end
    end

    every(1000, function()
        local rows = fetch()
        if not rows then return end
        if rows ~= rowsSeen then
            rowsSeen, UNREL = rows, {}
            for _, r in ipairs(rows) do UNREL[r[1]] = r[2] or r[1] end
            log("unreleased heroes: " .. #rows)
        end
        if not next(UNREL) then return end
        hook("/Game/UI/MainMenu/WB_Heroes.WB_Heroes_C:InitHeroSelection", function(ctx)
            local h = ctx:get()
            later("inventory", function() if h:IsValid() then inventory(h) end end)
        end)
        hook("/Game/UI/MainMenu/WB_HeroButton.WB_HeroButton_C:BndEvt__WB_HeroButton_CharacterBtn_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature", function(ctx)
            local b = ctx:get()
            local hero = own[b:GetAddress()]
            if not hero then return end
            later("hero page", function()
                local h = gameInstance().WB_MainMenuRef.WB_Collection.WB_Heroes
                local preview = h.HeroCollection:GetPreviewHeroByName(hero)
                if preview and preview:IsValid() then h:SetupHeroInfo(hero, false, false); h:ShowMoreDetails(hero)
                else notice(b, hero) end
            end)
        end)
        local LOBBY = "/Game/UI/Lobby/"
        hook(LOBBY .. "WB_FilterClassButton.WB_FilterClassButton_C:BndEvt__WB_FilterClassButton_FilterButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature", function(ctx)
            if not (toggle and toggle:IsValid() and ctx:get():GetAddress() == toggle:GetAddress()) then return end
            mode = mode == "released" and "unreleased" or "released"
            local hs = lobby
            later("toggle", function() if hs and hs:IsValid() then hs:SetupHeroSelect(hs.SearchInput:GetText()) end end)
        end)
        hook(LOBBY .. "WB_LobbyHeroSelect.WB_LobbyHeroSelect_C:SetupHeroSelect", function(ctx)
            local hs = ctx:get()
            later("hero select", function() if hs:IsValid() then regroup(hs) end end)
        end)
        hook(LOBBY .. "WB_LobbyHeroButton.WB_LobbyHeroButton_C:BndEvt__CharacterBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature", function(ctx)
            local b = ctx:get()
            local hero = heroOf(b)
            if hero and UNREL[hero] and not warned[hero] then
                warned[hero] = true
                later("notice", function() notice(b, hero) end)
            end
        end)

        local gi = gameInstance()
        if not (gi and gi:IsValid()) then return end
        -- a lobby's hero select: the toggle (custom lobbies only), released heroes first
        local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0)
        local ok, hs = pcall(function() return pc.WB_LobbyHeroSelectRef end)
        if ok and hs and hs:IsValid() and not (lobby and lobby:IsValid() and lobby:GetAddress() == hs:GetAddress()) then
            lobby, mode, warned, toggle = hs, "released", {}, nil
            if gi.MapGameMode == CUSTOM then
                local b = WBL:Create(hs, StaticFindObject(LOBBY .. "WB_FilterClassButton.WB_FilterClassButton_C"), nil)
                b.ClassFilter = 4                          -- Tank: no hero has it, no other button uses it
                b.ClassIcon = hs.FilterSupportBtn.ClassIcon
                hs.FilterBtnPanel:AddChild(b)
                b:SetToolTipText(FText("Unreleased heroes"))
                toggle = b
            end
            regroup(hs)
        end
        -- a hero without a preview asset can't be the main menu's hero (picked in a lobby): back to a released one
        local menu = gi.WB_MainMenuRef
        if menu and menu:IsValid() and menu:IsInViewport() and menuChecked ~= menu:GetAddress() then
            menuChecked = menu:GetAddress()
            local okh, saved = pcall(function() return gi.SavedPlayerInfo.Hero:ToString() end)
            if okh and UNREL[saved] then
                local preview = menu.WB_Collection.WB_Heroes.HeroCollection:GetPreviewHeroByName(saved)
                if not (preview and preview:IsValid()) then
                    menu:UpdatePlayerHero("Berserker", false)
                    log("unreleased heroes: menu hero " .. saved .. " has no preview, back to Berserker")
                end
            end
        end
    end)
end

-- Rowan's Propagator (Sourblossom charges faster on Overgrowth) shortens the charge timer every 0.25 s on the game
-- server with SetGameplayEffectDurationHandle, which restarts the timer effect with the remaining time as its full
-- length. The ability icon draws 1 - remaining / length, so the charge bar sat near empty, then jumped when the charge
-- came. After the icon has drawn its bar: draw it against the length the timer had when it started
-- (docs/recon/community-build-rowan.md).
do
    local ICON = "/Game/UI/Hud/WB_AbilityIcon.WB_AbilityIcon_C:UpdateStacksProgress"
    local TAG = "Effect.WoodenSword.Skill4.Cooldown"
    local timers = {}   -- icon address -> { full = the timer's length when it started, left = remaining last time }
    local lib, tagLib, hookedAt, logged = nil, nil, nil, 0
    local function redraw(w)
        local info = w["UIStack Info"]
        if info.ChargeType ~= 1 or info.EffectTag.TagName:ToString() ~= TAG then return end
        local box = w.StackPanel:GetChildAt(w.CurrStacks)
        if not (box and box:IsValid()) then return end
        local bar = box:GetChildAt(0)
        if not (bar and bar:IsValid()) then return end
        local rem, tot = {}, {}
        lib:GetEffectRemainingTime(w:GetOwningASC(), tagLib:MakeGameplayTagContainerFromTag(info.EffectTag), rem, tot)
        local left, full = rem.RemainingTime, tot.TotalTime
        if type(left) ~= "number" or type(full) ~= "number" or full <= 0 then return end
        local key = w:GetAddress()
        local t = timers[key]
        if not t or left > t.left + 0.05 then t = { full = full }; timers[key] = t end   -- a new charge timer
        t.left = left
        local game = bar.Percent
        bar:SetPercent(math.max(0, math.min(1, 1 - left / t.full)))
        if logged < 40 and math.abs(game - bar.Percent) > 0.05 then
            logged = logged + 1
            log(string.format("Propagator bar: game %.2f -> %.2f (%.2f s left of %.2f)", game, bar.Percent, left, t.full))
        end
    end
    every(2000, function()
        local f = StaticFindObject(ICON)
        if not (f and f:IsValid()) or hookedAt == f:GetAddress() then return end
        hookedAt = f:GetAddress()
        lib = StaticFindObject("/Script/MOBA.Default__MOBAAbilityLibrary")
        tagLib = StaticFindObject("/Script/GameplayTags.Default__BlueprintGameplayTagLibrary")
        local ok, e = pcall(RegisterHook, ICON, function(ctx)   -- runs after the body
            local s, err = pcall(redraw, ctx:get())
            if not s and logged < 40 then logged = logged + 1; log("Propagator bar: " .. tostring(err)) end
        end)
        log(ok and "Propagator bar: hooked" or ("Propagator bar: can't hook: " .. tostring(e)))
    end)
end
