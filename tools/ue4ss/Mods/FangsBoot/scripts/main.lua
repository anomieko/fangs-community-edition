-- FangsBoot: get a FANGS client from boot to logged-in without the dead Epic/Steam services.
--  * skips the intro logo movie (it otherwise waits for a key press)
--  * with -TestUser=<name> -TestPass=<pw> on the command line, reports Epic login as successful so the
--    game falls through to its built-in AccelByte username login (served by our backend).
local UEHelpers = require("UEHelpers")
local function log(msg) print("[fangsboot] " .. tostring(msg) .. "\n") end

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
