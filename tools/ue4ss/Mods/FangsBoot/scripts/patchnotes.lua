-- PATCH NOTES in the main menu (FangsBoot, Feb 2023 build): what each update changed, as written for players.
-- The notes come from our backend (backend/patchnotes.py): GET /fangsapi/prod/patch-notes lists the updates, one
-- "<tag>\t<date>\t<title>" line each, newest first; ?tag=<tag> is that update's notes as rich text. Each deploy that
-- reaches players adds a notes file in backend/patchnotes/ (docs/CHANGELOG.md, "How it works").
--  * The tab is a WB_MainMenuTab like PLAY or LEADERBOARD, appended to the tab row (the menu finds its own tabs by
--    position: ours comes last and is never one of them).
--  * It opens a panel over the menu: the updates on the left (date and title, each a WB_MainMenuTab too, so it
--    hovers, clicks and highlights like the tab row), the chosen update's notes on the right in a scrollable
--    RichTextBlock with the privacy-policy screen's styles (DT_LoginRichTypes). CLOSE or another tab closes it.
--  * On the first start after a new update it opens once by itself with the newest notes. The newest update shown
--    is kept in patchnotes_seen.txt, next to fangsboot.log.
--  * Requests never wait: without an answer the menu works as before and the panel says the notes can't be loaded.
return function(env)
    local log, every, gameInstance, backendBase = env.log, env.every, env.gameInstance, env.backendBase
    local TAB = "/Game/UI/MainMenu/WB_MainMenuTab.WB_MainMenuTab_C"
    local BUTTON = "/Game/UI/MainMenu/WB_IconButton_Secondary.WB_IconButton_Secondary_C"
    local TAB_CLICK = TAB .. ":BndEvt__TabBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
    local BUTTON_CLICK = BUTTON .. ":BndEvt__WB_BattlePassBtn_Secondary_SecondaryBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
    local STYLES = "/Game/DataContent/DataTables/DT_LoginRichTypes.DT_LoginRichTypes"
    local PATH, SEEN = "/fangsapi/prod/patch-notes", "patchnotes_seen.txt"
    local PANEL_W, PANEL_H, LIST_W = 1500.0, 800.0, 430.0   -- design units (1920 x 1080 screen)
    local VISIBLE, COLLAPSED = 0, 1
    local MUTED = { R = 0.78, G = 0.82, B = 0.86, A = 0.75 }
    local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local KSL = nil
    local function loadAsset(path)
        local c = StaticFindObject(path)
        if c and c:IsValid() then return c end
        KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
        c = StaticFindObject(path)
        return c and c:IsValid() and c or nil
    end

    local seen = nil   -- the newest update this install has shown
    do
        local f = io.open(SEEN, "r")
        if f then seen = (f:read("l") or ""):match("^%s*(.-)%s*$"); f:close() end
    end
    local list, listAt, listFailed = nil, 0, false   -- the updates { tag, date, title }, newest first
    local pages, pageFailed = {}, {}                 -- tag -> rich text; tag -> time of the failed request
    local req, vr = nil, nil                          -- the one request in flight: { r, kind, tag, at }; VaRest
    local ui = nil         -- this main menu's tab and panel (a new main menu after every game)
    local autoDone = false

    local function request(kind, tag)
        local base = backendBase()
        if not base then return end
        if not (vr and vr:IsValid()) then vr = FindFirstOf("VaRestSubsystem") end   -- once (an object scan)
        if not (vr and vr:IsValid()) then return end
        local r = vr:ConstructVaRestRequestExt(0, 0)   -- GET, no body
        r:ProcessURL(base .. PATH .. (tag and ("?tag=" .. tag) or ""))
        req = { r = r, kind = kind, tag = tag, at = os.time() }
    end
    local function poll()
        if not req then return end
        local status = req.r:IsValid() and req.r:GetStatus() or 2   -- 0 not started, 1 processing, 2/3 failed, 4 ok
        if status < 2 and os.time() - req.at < 20 then return end
        local text = status == 4 and req.r:GetResponseCode() == 200 and req.r:GetResponseContentAsString(true):ToString()
        local done = req
        req = nil
        if done.kind == "list" then
            listAt = os.time()
            if not text then
                listFailed = true
                return log("patch notes: no list from the backend (status " .. status .. ")")
            end
            local l = {}
            for line in text:gmatch("[^\n]+") do
                local tag, date, title = line:match("^([^\t]+)\t([^\t]*)\t(.*)$")
                if tag then l[#l + 1] = { tag = tag, date = date, title = title } end
            end
            list, listFailed = l, false
            log("patch notes: " .. #l .. " updates, newest " .. (l[1] and l[1].tag or "none") .. ", seen " .. tostring(seen))
        elseif text then
            pages[done.tag], pageFailed[done.tag] = text, nil
        else
            pageFailed[done.tag] = os.time()
            log("patch notes: no notes for " .. done.tag .. " (status " .. status .. ")")
        end
    end

    local made = 0
    local function make(class, name)
        made = made + 1
        return StaticConstructObject(StaticFindObject("/Script/UMG." .. class), ui.menu.WidgetTree, FName(name .. made))
    end
    local function label(font, size, text, colour)
        local t = make("TextBlock", "FCE_PatchNotesLabel")
        t:SetFont(font); t.Font.Size = size
        if colour then t:SetColorAndOpacity({ SpecifiedColor = colour, ColorUseRule = 0 }) end
        t:SetText(FText(text))
        return t
    end
    local function prettyDate(d)
        local y, m, day = d:match("^(%d+)-(%d+)-(%d+)$")
        return y and (tonumber(day) .. " " .. (MONTHS[tonumber(m)] or m) .. " " .. y) or d
    end
    -- a WB_MainMenuTab_C with our label, styled like the menu's tabs
    local function newTab(text)
        local model = ui.menu.LeaderboardTab
        local t = WBL:Create(ui.menu, model:GetClass(), nil)
        t.SelectedImg = model.SelectedImg
        t.BtnOption = 0                       -- Play: harmless if the menu ever binds it (it never selects it)
        pcall(function() t.BtnLabel = FText(text) end)
        t.TabBtnLbl:SetText(FText(text))
        return t
    end

    local function build()
        local menu = ui.menu
        local font = menu.LeaderboardTab.TabBtnLbl.Font
        local border = make("Border", "FCE_PatchNotes")
        border:SetBrushColor({ R = 0.012, G = 0.02, B = 0.035, A = 0.94 })
        border:SetPadding({ Left = 36.0, Top = 24.0, Right = 36.0, Bottom = 28.0 })
        local box = make("VerticalBox", "FCE_PatchNotesBox")
        border:SetContent(box)

        local head = make("HorizontalBox", "FCE_PatchNotesHead")
        local title = label(font, 30, "PATCH NOTES")
        pcall(function()   -- the look of the PLAYERS ONLINE header (main.lua turned the missions header into it)
            local h = menu.WB_PlayMenu.WB_Missions.MissionsSizeBox:GetParent():GetParent():GetChildAt(0):GetChildAt(0)
            title:SetFont(h.Font); title.Font.Size = 30
            title:SetColorAndOpacity(h.ColorAndOpacity)
        end)
        local s = head:AddChild(title)
        s:SetSize({ Value = 1.0, SizeRule = 1 }); s:SetVerticalAlignment(2)
        local close = WBL:Create(menu, loadAsset(BUTTON), nil)
        close.PaddingOverride = { Left = 28.0, Top = 8.0, Right = 28.0, Bottom = 8.0 }
        local closeText = label(font, 20, "CLOSE")
        closeText:SetJustification(1)
        close.TextWrapper:SetContent(closeText)
        close:UpdateText(FText("CLOSE"))
        head:AddChild(close):SetVerticalAlignment(2)
        box:AddChild(head)
        local line = make("SizeBox", "FCE_PatchNotesLine")
        line:SetHeightOverride(2.0)
        local lineBrush = make("Border", "FCE_PatchNotesLineBrush")
        lineBrush:SetBrushColor({ R = 0.55, G = 0.62, B = 0.68, A = 0.35 })
        line:AddChild(lineBrush)
        box:AddChild(line):SetPadding({ Left = 0.0, Top = 12.0, Right = 0.0, Bottom = 18.0 })

        local body = make("HorizontalBox", "FCE_PatchNotesBody")
        local listSize = make("SizeBox", "FCE_PatchNotesListSize")
        listSize:SetWidthOverride(LIST_W)
        local listBox = make("ScrollBox", "FCE_PatchNotesList")
        listSize:AddChild(listBox)
        body:AddChild(listSize)
        local notes = make("ScrollBox", "FCE_PatchNotesScroll")
        local rt = make("RichTextBlock", "FCE_PatchNotesText")
        local styles = loadAsset(STYLES)
        if styles then rt.TextStyleSet = styles else log("patch notes: no " .. STYLES) end
        rt.AutoWrapText = true
        notes:AddChild(rt):SetPadding({ Left = 0.0, Top = 0.0, Right = 24.0, Bottom = 24.0 })
        s = body:AddChild(notes)
        s:SetSize({ Value = 1.0, SizeRule = 1 }); s:SetPadding({ Left = 36.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
        s = box:AddChild(body)
        s:SetSize({ Value = 1.0, SizeRule = 1 })

        local root = menu.WidgetTree.RootWidget
        local slot = root:AddChildToCanvas(border)
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
        slot:SetAlignment({ X = 0.5, Y = 0.5 })
        slot:SetPosition({ X = 0.0, Y = 30.0 })
        slot:SetSize({ X = PANEL_W, Y = PANEL_H })
        slot:SetZOrder(50)
        ui.panel = { border = border, list = listBox, notes = notes, text = rt, close = close, closeAddr = close:GetAddress(),
                     font = font, entries = {}, listShown = nil, shown = nil }
        log("patch notes: panel built (root " .. root:GetClass():GetFName():ToString() .. ")")
    end

    local function fill()   -- the list and the notes as they are now
        local p = ui.panel
        if p.listShown ~= list and list then
            p.listShown = list
            p.list:ClearChildren()
            p.entries = {}
            for _, item in ipairs(list) do
                local e = make("VerticalBox", "FCE_PatchNotesEntry")
                e:AddChild(label(p.font, 15, prettyDate(item.date), MUTED)):SetPadding({ Left = 12.0, Top = 10.0, Right = 0.0, Bottom = 0.0 })
                local t = newTab(item.title)
                e:AddChild(t)
                p.list:AddChild(e):SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 6.0 })
                p.entries[#p.entries + 1] = { tag = item.tag, tab = t, addr = t:GetAddress() }
            end
        end
        if not ui.selected and list and list[1] then ui.selected = list[1].tag end
        for _, e in ipairs(p.entries) do   -- a new tab looks selected until told otherwise
            local on = e.tag == ui.selected
            if e.on ~= on and e.tab:IsValid() then e.tab:SetSelected(on); e.on = on end
        end
        local key, text
        if ui.selected and pages[ui.selected] then
            key, text = "page " .. ui.selected, pages[ui.selected]
        elseif ui.selected and pageFailed[ui.selected] then
            key, text = "failed", "<RichText.Useragreetxt>These notes can't be loaded right now. Try again in a moment.</>"
        elseif list and not list[1] then
            key, text = "none", "<RichText.Useragreetxt>No patch notes yet.</>"
        elseif not list and listFailed then
            key, text = "offline", "<RichText.Useragreetxt>The patch notes can't be loaded right now. Try again in a moment.</>"
        else
            key, text = "loading", "<RichText.Useragreetxt>Loading...</>"
        end
        if p.shown == key then return end
        p.shown = key
        p.text:SetText(FText(text))
        p.notes:ScrollToStart()
        if not (ui.selected and key == "page " .. ui.selected) then return end
        log("patch notes: showing " .. ui.selected .. " (" .. #text .. " bytes)")
        if list and list[1] and ui.selected == list[1].tag and seen ~= ui.selected then
            seen = ui.selected
            local f = io.open(SEEN, "w")
            if f then f:write(seen .. "\n"); f:close() end
        end
    end

    local function open(why)
        if not ui.panel then build() end
        ui.panel.border:SetVisibility(VISIBLE)
        ui.open = true
        log("patch notes: opened (" .. why .. ")")
        fill()
    end
    local function close(why)
        if not (ui and ui.panel and ui.open) then return end
        ui.panel.border:SetVisibility(COLLAPSED)
        ui.open = false
        log("patch notes: closed (" .. why .. ")")
    end

    -- clicks (the hooks run after the widgets' own handlers: the click sound, another tab's page)
    local function onTab(ctx)
        local w = ctx:get()
        if not (ui and ui.menu:IsValid() and w:IsValid()) then return end
        local a = w:GetAddress()
        if a == ui.tabAddr then return open("tab") end
        for _, e in ipairs(ui.panel and ui.panel.entries or {}) do
            if e.addr == a then ui.selected = e.tag; return fill() end
        end
        local ok, parent = pcall(function() return w:GetParent() end)   -- PLAY, INVENTORY, ...: their page instead
        if ok and parent and parent:IsValid() and parent:GetAddress() == ui.tabRowAddr then close("another tab") end
    end
    local function onButton(ctx)
        local w = ctx:get()
        if ui and ui.panel and w:IsValid() and w:GetAddress() == ui.panel.closeAddr then close("CLOSE") end
    end
    local hooked = {}   -- function path -> address of the UFunction hooked (classes are reloaded)
    local function hook(path, fn)
        local f = StaticFindObject(path)
        if not (f and f:IsValid()) or hooked[path] == f:GetAddress() then return end
        hooked[path] = f:GetAddress()
        local ok, e = pcall(RegisterHook, path, function(...)
            local s, err = pcall(fn, ...)
            if not s then log("patch notes hook: " .. tostring(err)) end
        end)
        if not ok then log("patch notes: can't hook " .. path .. ": " .. tostring(e)) end
    end

    local function addTab(menu)
        ui = { menu = menu, addr = menu:GetAddress(), shownAt = os.time(), tabRowAddr = menu.MainMenuTabPanel:GetAddress() }
        local t = newTab("PATCH NOTES")
        local slot = menu.MainMenuTabPanel:AddChild(t)
        pcall(function()   -- spaced like the other tabs
            local m = menu.LeaderboardTab.Slot
            local p, size = m.Padding, m.Size
            slot:SetPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
            slot:SetSize({ Value = size.Value, SizeRule = size.SizeRule })
            slot:SetHorizontalAlignment(m.HorizontalAlignment); slot:SetVerticalAlignment(m.VerticalAlignment)
        end)
        t:SetSelected(false)   -- a new tab looks selected (the menu only resets its own)
        ui.tab, ui.tabAddr = t, t:GetAddress()
        hook(TAB_CLICK, onTab)
        if loadAsset(BUTTON) then hook(BUTTON_CLICK, onButton) end
        log("patch notes: tab added")
    end

    local broken = nil   -- a main menu the tab couldn't be added to (not tried again)
    every(200, function()
        local gi = gameInstance()
        local menu = gi and gi:IsValid() and gi.WB_MainMenuRef
        if not (menu and menu:IsValid() and menu:IsInViewport()) then return end
        if not (ui and ui.addr == menu:GetAddress()) then
            if broken == menu:GetAddress() then return end
            if not env.settled("patch notes", menu) then return end   -- not while the engine may still be building it
            local ok, e = pcall(addTab, menu)
            if not ok then
                broken, ui = menu:GetAddress(), nil
                return log("patch notes: no tab: " .. tostring(e))
            end
        end
        poll()
        local now = os.time()
        if not req then
            if (not list and now - listAt >= 10) or (list and ui.open and now - listAt >= 600) then request("list")
            elseif ui.open and ui.selected and not pages[ui.selected] and now - (pageFailed[ui.selected] or 0) >= 10 then
                request("page", ui.selected)
            end
        end
        if ui.open then fill() end
        if not autoDone and list and now - ui.shownAt >= 3 then   -- once per start, after the menu has settled
            autoDone = true
            if list[1] and list[1].tag ~= seen then ui.selected = list[1].tag; open("new update " .. list[1].tag) end
        end
    end)
    log("patch notes loaded (seen " .. tostring(seen) .. ")")
end
