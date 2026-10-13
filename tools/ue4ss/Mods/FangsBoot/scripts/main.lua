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
            local logo = gi.WB_LogoRef
            if logo and logo:IsValid() and logo:IsInViewport() and logo.bCanSkip then
                logo:EndMovie(); logoDone = true; log("skipped logo movie")
            end
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
    local gi, pc = menu.GameInstance, menu.BP_LobbyPlayerControllerRef
    if not (gi:IsValid() and gi.MapGameMode == 4 and pc:IsValid()) then return end   -- custom lobbies only
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

-- In-match HUD (WB_Round): replace the "EARLY DEVELOPMENT" tag (an image, EarlyDevTag, top left) with a
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
        for _, round in ipairs(FindAllOf("WB_Round_C") or {}) do
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
