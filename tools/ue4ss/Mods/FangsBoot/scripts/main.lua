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
-- the "Join our Discord" banner. The missions list (no missions any more) becomes the number of players online
-- (backend /fangsapi/prod/online-players, every 30 s while the menu is on screen). Tabs are collapsed, never
-- removed: SelectMainMenuTab picks the tab buttons by their position.
-- Pages other than Home (Leaderboard, Collection > Artifacts, ...) have no background of their own: they show
-- the 4K splash video (ClientBkg). Where it doesn't play (Wine without the codec) the image renders white;
-- then a dark static background replaces it.
if not gameVersion():find("^alpha7") then
    local SELECT_TAB = "/Game/UI/MainMenu/WB_MainMenu.WB_MainMenu_C:SelectMainMenuTab"
    local TAB_BATTLEPASS, TAB_STORE = 4, 5   -- ENUM_MainMenu
    local COLLAPSED = 1
    local STATIC_BKG = "/Game/UI/Textures/Client/HeroSelect/HeroMasteryBkg.HeroMasteryBkg"

    local cleaned, shownAt, bkgFixed, onlineText = nil, 0, false, nil
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
        -- WB_Missions: VerticalBox_1 > [HorizontalBox_0 > "MISSIONS" header, Image_106 line, ScaleBox_0 > cards]
        local ok, e = pcall(function()
            local cards = pm.WB_Missions.MissionsSizeBox:GetParent()
            cards:SetVisibility(COLLAPSED)
            onlineText = cards:GetParent():GetChildAt(0):GetChildAt(0)
            onlineText:SetText(FText("PLAYERS ONLINE"))
        end)
        if not ok then log("menu: missions list: " .. tostring(e)) end
        log("menu: cleaned up")
    end

    local vr, req, asked = nil, nil, 0
    local function updateOnline()
        if req then
            local status = req:IsValid() and req:GetStatus() or 2   -- 0 not started, 1 processing, 2/3 failed, 4 ok
            if status < 2 and os.time() - asked < 20 then return end
            local n = status == 4 and req:GetResponseCode() == 200
                and tonumber(req:GetResponseContentAsString(true):ToString())
            if n and onlineText and onlineText:IsValid() then
                onlineText:SetText(FText(n .. (n == 1 and " PLAYER ONLINE" or " PLAYERS ONLINE")))
            end
            req = nil
        elseif os.time() - asked >= 30 then
            asked = os.time()
            local base = backendBase()
            if not base then return end
            if not (vr and vr:IsValid()) then vr = FindFirstOf("VaRestSubsystem") end
            req = vr:ConstructVaRestRequestExt(0, 0)   -- GET, no body
            req:ProcessURL(base .. "/fangsapi/prod/online-players")
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

    -- The Store also opens from "unlock" buttons on items you don't own (none: everything is owned).
    every(1000, function()
        if not StaticFindObject(SELECT_TAB) then return end
        local ok, e = pcall(RegisterHook, SELECT_TAB, function(ctx, tab)   -- runs after the body
            local t = tab:get()
            if t == TAB_BATTLEPASS or t == TAB_STORE then ctx:get():SelectMainMenuTab(0) end
        end)
        if not ok then log("menu: tab hook failed: " .. tostring(e)) end
        return true
    end)
end
