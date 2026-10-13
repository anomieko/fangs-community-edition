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

local function commandLine()
    local ok, cl = pcall(function() return UEHelpers.GetKismetSystemLibrary():GetCommandLine():ToString() end)
    return ok and cl or ""
end

local logoDone, loginDone = false, false
LoopAsync(500, function()
    ExecuteInGameThread(function()
        local gi = FindFirstOf("BP_MOBAInstance_C")
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
    end)
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
local function offerLaunch(menu)
    local gi, pc = FindFirstOf("BP_MOBAInstance_C"), menu.BP_LobbyPlayerControllerRef
    if not (gi and gi:IsValid() and gi.MapGameMode == 4 and pc:IsValid()) then return end   -- custom lobbies only
    local ps = pc.PlayerState
    if not (ps:IsValid() and ps.IsLobbyOwner) then return end
    local sw = menu.LobbyStatusSwitch
    if sw:GetActiveWidgetIndex() == 1 then return end
    local gs = FindFirstOf("GS_Lobby_GameState_C")
    if gs and gs:IsValid() and everyonePickedASide(gs) then sw:SetActiveWidgetIndex(1) end
end
local launchHooked = false
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        if launchHooked or not StaticFindObject(LOBBY_MENU_TICK) then return end
        -- (with this UE4SS build a Blueprint-function hook runs after the function body)
        local ok, err = pcall(RegisterHook, LOBBY_MENU_TICK, function(ctx)
            local s, e = pcall(offerLaunch, ctx:get())
            if not s then log("offerLaunch: " .. tostring(e)) end
        end)
        launchHooked = true
        log(ok and "lobby: launch allowed before the lobby is full" or ("lobby menu hook failed: " .. tostring(err)))
    end)
    return launchHooked
end)

-- In-match HUD (WB_Round; WB_HUD in the Aug 2022 build): replace the "EARLY DEVELOPMENT" tag (an image, EarlyDevTag) with a
-- "COMMUNITY EDITION" label in the same place, using the font of one of the HUD's own texts.
local TAG_TEXT = "COMMUNITY EDITION"
local function child(round, class, name)   -- widget of round's WidgetTree (GetWidgetFromName isn't a UFunction here)
    local tag = round:GetFName():ToString() .. ".WidgetTree." .. (name or "")
    for _, w in ipairs(FindAllOf(class) or {}) do
        local full = w:IsValid() and w:GetFullName() or ""
        if (name and full:sub(-#tag) == tag) or (not name and full:find(tag, 1, true)) then return w end
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
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        local huds = FindAllOf("WB_Round_C") or {}             -- Feb 2023 build
        for _, h in ipairs(FindAllOf("WB_HUD_C") or {}) do huds[#huds + 1] = h end   -- Aug 2022 build
        for _, round in ipairs(huds) do
            local key = round:IsValid() and round:GetFullName() or nil
            if key and not key:find("Default__", 1, true) and retagged[key] ~= true then
                local ok, done = pcall(retag, round)
                if not ok then retagged[key] = true; log("retag failed: " .. tostring(done))
                elseif done then retagged[key] = true; log("HUD tag: " .. TAG_TEXT)
                else
                    retagged[key] = (retagged[key] or 0) + 1
                    if retagged[key] >= 15 then retagged[key] = true; log("HUD tag: EarlyDevTag not found") end
                end
            end
        end
    end)
    return false
end)

-- Custom lobbies: "Battle" is 4v4 (8 players). This build's create-lobby screen makes it 6 (3v3).
local SELECT_GAME_MODE = "/Game/UI/MainMenu/WB_CreateLobby.WB_CreateLobby_C:SelectGameMode"
local BATTLE_PLAYERS = 8
local battleHooked = false
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        if battleHooked or not StaticFindObject(SELECT_GAME_MODE) then return end
        local ok, err = pcall(RegisterHook, SELECT_GAME_MODE, function(ctx, selection)   -- runs after the body
            local s, e = pcall(function()
                if selection:get():ToString():lower() == "battle" then ctx:get().PlayerCount = BATTLE_PLAYERS end
            end)
            if not s then log("battle size: " .. tostring(e)) end
        end)
        battleHooked = true
        log(ok and ("custom lobbies: Battle is " .. BATTLE_PLAYERS .. " players") or ("create-lobby hook failed: " .. tostring(err)))
    end)
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

if gameVersion():find("^alpha7") then
    local PLAY_MENU = "/Game/UI/MainMenu/WB_PlayMenu.WB_PlayMenu_C"

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

    local pending = nil   -- the one lobby request in flight: {req, kind = "create"|"list", pm, started}
    local function request(kind, pm, verb, path, body)
        local base = backendBase()
        if not base then return log("lobby: no backend address (Engine.ini)") end
        local vr = FindFirstOf("VaRestSubsystem")
        local req = vr:ConstructVaRestRequestExt(verb, 2)   -- verb 0 GET / 1 POST, content type 2 = JSON
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
        local status = p.req:GetStatus()      -- 0 not started, 1 processing, 2/3 failed, 4 succeeded
        if status < 2 then
            if os.time() - p.started > 150 then status = 2 else return end
        end
        pending = nil
        local code = p.req:GetResponseCode()
        if status == 4 and code == 200 then
            if p.kind == "create" then
                p.pm:OnComplete_8D51ACCE4F51DE2218C3C9BCE91C5034(p.req)   -- the game's own "lobby reserved" handler
                log("lobby: created, joining")
            else
                showLobbies(p.pm, p.req:GetResponseContentAsString(true):ToString())
            end
        else
            log("lobby: " .. p.kind .. " request failed (status " .. status .. ", HTTP " .. code .. ")")
            p.pm:FinishedSearching()
        end
    end

    LoopAsync(200, function()
        ExecuteInGameThread(function()
            local gi = FindFirstOf("BP_MOBAInstance_C")
            if not (gi and gi:IsValid()) then return end
            if not gi.UseLAN then gi.UseLAN = true end
            if pending then
                local ok, e = pcall(finishRequest)
                if not ok then pending = nil; log("lobby: " .. tostring(e)) end
            end
        end)
        return false
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

    local hooked = {}
    local wanted = {
        CreateLobbyAndJoin = onCreate,
        FindLobbies = onFind,
        BndEvt__FindLobbyBtn_K2Node_ComponentBoundEvent_18_OnButtonClickedEvent__DelegateSignature = onFind,
        BndEvt__SearchInput_K2Node_ComponentBoundEvent_10_OnEditableTextBoxCommittedEvent__DelegateSignature = onFind,
        ZeuzIMSGetServerList = onPreviousGameCheck,
    }
    LoopAsync(1000, function()
        ExecuteInGameThread(function()
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
        end)
        local n = 0
        for _ in pairs(hooked) do n = n + 1 end
        if n == 5 then log("custom lobbies via our backend (Aug 2022 build)") end
        return n == 5
    end)
end
