-- Custom lobby settings in the lobby screen, and the Captain vote in matches (FangsBoot; the server side is FangsHost's
-- lobby.lua, which has the details).
--
-- The lobby screen gets a "LOBBY SETTINGS" panel made of the game's own settings-menu widgets: map, size and rounds
-- (WB_SettingComboBoxOption), Captain vote (WB_SettingToggleButton) and "shuffle teams" (WB_IconButton_Secondary).
-- The owner changes them; everyone else sees them greyed out. A change goes to the game server as a command
-- (RefreshPlayerInfoOnServer("fce:<cmd>=<value>"), the lobby controller's own RPC); the panel shows what the server
-- publishes in the lobby game state's ServerPayload.
-- Launch with players waiting outside the seats: their seats are gone (smaller size) or they chose to wait. The
-- owner gets a LAUNCH button that has the server kick them first; then the game's own launch runs.
-- In a match: the HUD shows the vote every round (Captain vote on) or never (off; also Casual and Ranked), and the
-- match's rounds to win (MaxRounds) are the lobby's.
return function(env)
    local log, every, gameInstance = env.log, env.every, env.gameInstance
    local CUSTOM = 4
    -- design units (1920 x 1080 screen): the panel at the top right, the two team columns moved left to make room
    local PANEL_X, PANEL_Y, PANEL_W, TEAMS_SHIFT = -32.0, 140.0, 500.0, -200.0
    local COMBO = "/Game/UI/Settings/WB_SettingComboBoxOption.WB_SettingComboBoxOption_C"
    local TOGGLE = "/Game/UI/Settings/WB_SettingToggleButton.WB_SettingToggleButton_C"
    local BUTTON = "/Game/UI/MainMenu/WB_IconButton_Secondary.WB_IconButton_Secondary_C"
    local SIZES = { { "1 vs 1", 2 }, { "2 vs 2", 4 }, { "3 vs 3", 6 }, { "4 vs 4", 8 }, { "5 vs 5", 10 }, { "6 vs 6", 12 } }
    local ROUNDS = { { "Best of 3", 2 }, { "Best of 5", 3 }, { "Best of 7", 4 }, { "Best of 9", 5 } }
    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local KSL = nil
    local function loadClass(path)
        local c = StaticFindObject(path)
        if c and c:IsValid() then return c end
        KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
        c = StaticFindObject(path)
        return c and c:IsValid() and c or nil
    end
    local function later(what, fn)
        ExecuteInGameThreadWithDelay(1, function()
            local ok, e = pcall(fn)
            if not ok then log("lobby settings (" .. what .. "): " .. tostring(e)) end
        end)
    end

    local ui = nil        -- the panel of the lobby menu it was built for: { menu, map, size, rounds, vote, shuffle, launch, ... }
    local last = nil      -- the settings last seen in a lobby: { map, size, rounds, vote, maps = { {name, level} } }
    local pending = nil   -- the owner's launch, waiting for the waiting players to be gone: { until_ }

    local function parse(s)
        if type(s) ~= "string" or s:sub(1, 5) ~= "fce1|" then return nil end
        local t = {}
        for k, v in s:gmatch("|(%w+)=([^|]*)") do t[k] = v end
        local list = {}
        for name, level in (t.maps or ""):gmatch("([^:,]+):([^,]+)") do list[#list + 1] = { name = name, level = level } end
        t.maps = list
        t.size, t.rounds, t.vote = tonumber(t.size) or 0, tonumber(t.rounds) or 2, t.vote == "1"
        return t
    end

    local function lobbyPC()
        local gi = gameInstance()
        if not (gi and gi:IsValid()) then return nil end
        local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0)
        if not (pc and pc:IsValid() and pc:GetClass():GetFName():ToString() == "BP_PC_Lobby_PlayerController_C") then return nil end
        return pc, gi
    end
    local function send(cmd)
        local pc = lobbyPC()
        if pc then pc:RefreshPlayerInfoOnServer("fce:" .. cmd); log("lobby settings: sent " .. cmd) end
    end

    local function seats(gs)   -- players in a seat, players waiting outside the seats
        local seated, waiting = 0, 0
        gs.PlayerArray:ForEach(function(_, e)
            local ps = e:get()
            if ps:IsValid() then
                local ok, slot = pcall(function() return ps.ChosenSlot end)
                if ok and type(slot) == "number" then if slot >= 0 then seated = seated + 1 else waiting = waiting + 1 end end
            end
        end)
        return seated, waiting
    end

    -- a row of the panel: the widget in a size box of the panel's width
    local function row(menu, box, widget, height)
        local sb = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), menu.WidgetTree, FName("FCE_Row"))
        sb:SetWidthOverride(PANEL_W)
        if height then sb:SetHeightOverride(height) end
        box:AddChild(sb):SetPadding({ Left = 0.0, Top = 4.0, Right = 0.0, Bottom = 4.0 })
        sb:AddChild(widget)
        return widget
    end
    -- a WB_IconButton_Secondary (the game's button look) with a label: its BtnText is shown nowhere, so a text block
    -- goes into its TextWrapper; BtnText is set too, to find it again (tests)
    local function button(menu, panel, text)
        local b = WBL:Create(menu, loadClass(BUTTON), nil)
        b.PaddingOverride = { Left = 32.0, Top = 10.0, Right = 32.0, Bottom = 10.0 }
        local slot = panel:AddChild(b)
        local tb = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), menu.WidgetTree, FName("FCE_ButtonText"))
        tb:SetFont(menu.LobbyNameTxt.Font); tb.Font.Size = 22
        tb:SetJustification(1)                                        -- centred
        b.TextWrapper:SetContent(tb)
        local function label(t) tb:SetText(FText(t)); b:UpdateText(FText(t)) end
        label(text)
        return b, label, slot
    end
    local function combo(menu, box, label, options)
        local w = WBL:Create(menu, loadClass(COMBO), nil)
        row(menu, box, w, 64.0)
        w.OptionLbl:SetText(FText(label))
        w.OptionDropDown:ClearOptions()
        for _, o in ipairs(options) do w.OptionDropDown:AddOption(o) end
        return w
    end

    local function build(menu, owner)
        local tree = menu.WidgetTree
        local canvas = tree.RootWidget
        local border = StaticConstructObject(StaticFindObject("/Script/UMG.Border"), tree, FName("FCE_LobbySettings"))
        border:SetBrushColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.55 })
        border:SetPadding({ Left = 24.0, Top = 16.0, Right = 24.0, Bottom = 20.0 })
        local slot = canvas:AddChildToCanvas(border)
        slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
        slot:SetAlignment({ X = 1.0, Y = 0.0 })
        slot:SetPosition({ X = PANEL_X, Y = PANEL_Y })
        slot:SetAutoSize(true)
        slot:SetZOrder(20)
        local box = StaticConstructObject(StaticFindObject("/Script/UMG.VerticalBox"), tree, FName("FCE_LobbySettingsBox"))
        border:SetContent(box)
        local title = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName("FCE_LobbySettingsTitle"))
        title:SetFont(menu.LobbyNameTxt.Font); title.Font.Size = 26
        title:SetText(FText("LOBBY SETTINGS"))
        box:AddChild(title):SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = owner and 8.0 or 0.0 })
        if not owner then
            local note = StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"), tree, FName("FCE_LobbySettingsNote"))
            note:SetFont(menu.LobbyNameTxt.Font); note.Font.Size = 16
            note:SetText(FText("Set by the lobby owner"))
            note:SetColorAndOpacity({ SpecifiedColor = { R = 0.7, G = 0.7, B = 0.7, A = 1.0 }, ColorUseRule = 0 })
            box:AddChild(note):SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 8.0 })
        end
        pcall(function() menu.TeamsPanel:SetRenderTranslation({ X = TEAMS_SHIFT, Y = 0.0 }) end)

        local u = { menu = menu, addr = menu:GetAddress(), owner = owner, mapLevels = {}, border = border }
        local mapNames = {}
        for _, m in ipairs(last and last.maps or {}) do mapNames[#mapNames + 1] = m.name; u.mapLevels[m.name] = m.level end
        u.map = combo(menu, box, "MAP", mapNames)
        local sizeNames, roundNames = {}, {}
        for _, s in ipairs(SIZES) do sizeNames[#sizeNames + 1] = s[1] end
        for _, r in ipairs(ROUNDS) do roundNames[#roundNames + 1] = r[1] end
        u.size = combo(menu, box, "TEAMS", sizeNames)
        u.rounds = combo(menu, box, "ROUNDS", roundNames)
        u.vote = WBL:Create(menu, loadClass(TOGGLE), nil)
        u.vote.FontSize = 12                                         -- "CAPTAIN VOTE" fits next to the toggle
        row(menu, box, u.vote, 64.0)
        u.vote.OptionLbl:SetText(FText("CAPTAIN VOTE"))
        local shuffleSlot
        u.shuffle, _, shuffleSlot = button(menu, box, "SHUFFLE TEAMS")
        shuffleSlot:SetPadding({ Left = 0.0, Top = 12.0, Right = 0.0, Bottom = 0.0 })
        shuffleSlot:SetHorizontalAlignment(2)                        -- centred
        if not owner then
            for _, w in ipairs({ u.map, u.size, u.rounds, u.vote }) do w:SetIsEnabled(false) end
            u.shuffle:SetVisibility(1)   -- Collapsed
        end
        -- the owner's launch when players wait outside the seats: a third page of the Launch switcher
        -- shown only while players wait outside the seats (a label set later didn't show in tests: a fixed one)
        if owner then u.launch = button(menu, menu.LobbyStatusSwitch, "START (WAITING PLAYERS LEAVE)") end
        u.mapNames = mapNames
        log("lobby settings: panel built (" .. (owner and "owner" or "player") .. ", " .. #mapNames .. " maps)")
        return u
    end

    local function select(w, text)
        if text and w.OptionDropDown:GetSelectedOption():ToString() ~= text then w.OptionDropDown:SetSelectedOption(text) end
    end
    local function show(u, t)   -- the server's settings in the panel
        for name, level in pairs(u.mapLevels) do if level == t.map then select(u.map, name) end end
        for _, s in ipairs(SIZES) do if s[2] == t.size then select(u.size, s[1]) end end
        for _, r in ipairs(ROUNDS) do if r[2] == t.rounds then select(u.rounds, r[1]) end end
        if u.vote.CurrentState ~= t.vote then u.vote:ToggleState(t.vote) end
    end

    -- clicks on our widgets (the hooks run after the widgets' own handlers)
    local function ours(w)
        return ui and ui.menu:IsValid() and w:IsValid() and w:GetAddress() or nil
    end
    local function onCombo(ctx, item, how)
        local w = ctx:get()
        local a = ours(w)
        if not a or not ui.owner then return end
        local kind = how:get()
        if kind ~= 0 and kind ~= 2 then return end   -- the player's choice (key or mouse), not ours (Direct)
        local text = item:get():ToString()
        if a == ui.map:GetAddress() and ui.mapLevels[text] then send("map=" .. ui.mapLevels[text])
        elseif a == ui.size:GetAddress() then
            for _, s in ipairs(SIZES) do if s[1] == text then send("size=" .. s[2]) end end
        elseif a == ui.rounds:GetAddress() then
            for _, r in ipairs(ROUNDS) do if r[1] == text then send("rounds=" .. r[2]) end end
        end
    end
    local function onToggle(ctx)
        local w = ctx:get()
        if ours(w) and ui.owner and w:GetAddress() == ui.vote:GetAddress() then send("vote=" .. (w.CurrentState and "1" or "0")) end
    end
    local function onButton(ctx)
        local w = ctx:get()
        local a = ours(w)
        if not a or not ui.owner then return end
        if a == ui.shuffle:GetAddress() then send("shuffle")
        elseif ui.launch and a == ui.launch:GetAddress() and not pending then
            send("kickwaiting"); pending = { until_ = os.clock() + 6 }
        end
    end

    -- after each lobby-menu Tick (main.lua's hook): the Launch page while players wait outside the seats, and the
    -- owner's launch once they are gone
    function env.afterLobbyTick(menu)
        if not (ui and ui.addr == menu:GetAddress() and ui.owner and ui.launch) then return end
        local gs = env.lobbyState()
        if not gs then return end
        local seated, waiting = seats(gs)
        local sw = menu.LobbyStatusSwitch
        if pending then
            if waiting == 0 then
                pending = nil
                later("launch", function() menu.WB_LaunchGame:BndEvt__LaunchGame_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() end)
                log("lobby settings: waiting players gone, launching")
            elseif os.clock() > pending.until_ then
                pending = nil; log("lobby settings: the waiting players are still here; launch again")
            end
            return
        end
        if waiting > 0 and seated > 0 and sw:GetActiveWidgetIndex() ~= 1 then
            sw:SetActiveWidgetIndex(2)
        end
    end

    local hooked = {}   -- function path -> address of the UFunction hooked (classes are reloaded)
    local function hook(path, fn)
        local f = StaticFindObject(path)
        if not (f and f:IsValid()) or hooked[path] == f:GetAddress() then return end
        hooked[path] = f:GetAddress()
        local ok, e = pcall(RegisterHook, path, function(...)
            local s, err = pcall(fn, ...)
            if not s then log("lobby settings hook: " .. tostring(err)) end
        end)
        if not ok then log("lobby settings: can't hook " .. path .. ": " .. tostring(e)) end
    end

    every(300, function()
        local pc, gi = lobbyPC()
        if not pc then ui = nil; return end
        local gs = env.lobbyState()
        if not gs then return end
        local t = parse(gs.ServerPayload:ToString())
        if t then last = t end
        local menu = pc.WB_LobbyMenuRef
        if gi.MapGameMode ~= CUSTOM or not (menu and menu:IsValid() and menu:IsInViewport()) or not t then return end
        local ps = pc.PlayerState
        local owner = ps and ps:IsValid() and ps.IsLobbyOwner == true
        if ui and ui.addr == menu:GetAddress() and ui.menu:IsValid() and ui.owner ~= owner then
            -- ownership arrives a moment after joining (replicated): build the panel again for the owner
            pcall(function() ui.border:RemoveFromParent() end)
            pcall(function() if ui.launch then ui.launch:RemoveFromParent() end end)
            ui = nil
        end
        if not (ui and ui.addr == menu:GetAddress() and ui.menu:IsValid()) then
            if not loadClass(COMBO) or not loadClass(TOGGLE) or not loadClass(BUTTON) then return end
            hook(COMBO .. ":BndEvt__OptionDropDown_K2Node_ComponentBoundEvent_0_OnSelectionChangedEvent__DelegateSignature", onCombo)
            hook(TOGGLE .. ":BndEvt__ToggleBtn_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature", onToggle)
            hook(BUTTON .. ":BndEvt__WB_BattlePassBtn_Secondary_SecondaryBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature", onButton)
            ui = build(menu, owner)
        end
        show(ui, t)
    end)

    -- In a match: the vote on the HUD every round or never, the Captain timing and the rounds to win as the server's.
    local applied = nil
    every(100, function()
        local gi = gameInstance()
        if not (gi and gi:IsValid()) then return end
        local ok, gs = pcall(function() return gi:GetWorld().GameState end)
        -- GS_MOBA_Battle_C or a map's own subclass (the arenas use GS_MOBA_Battle_Dragon_C)
        if not (ok and gs and gs:IsValid() and gs:GetClass():GetFName():ToString():find("^GS_MOBA_Battle")) then return end
        if applied == gs:GetAddress() then return end
        local pc = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0)
        local hud = pc and pc:IsValid() and pc.WB_HUDGamplayRef
        if not (hud and hud:IsValid()) then return end
        local custom = gi.MapGameMode == CUSTOM
        local vote = custom and last and last.vote or false
        hud.KingVoteRound = vote and 1 or 99
        local rs = nil                            -- the match's Captain rule (an object scan, once per match)
        for _, r in ipairs(FindAllOf("BP_RS_King_C") or {}) do
            if r:IsValid() and not r:GetFullName():find("Default__", 1, true) then rs = r end
        end
        if not rs then return end
        rs.MaxKingVotingTime = vote and 8.0 or 0.0
        rs.MinCaptainSelectTime = vote and 2.0 or 0.0
        if custom and last and last.rounds then pcall(function() gs.MaxRounds = last.rounds end) end
        applied = gs:GetAddress()
        log(string.format("match: Captain %s, first to %s rounds", vote and "vote every round" or "random (no vote)",
            tostring(custom and last and last.rounds or "the game's")))
    end)
    log("lobby settings loaded")
end
