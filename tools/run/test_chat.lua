-- Helpers for tools/run/test_chat.sh, loaded by FangsCtl (dofile) into the test clients.
-- say(kind, text): what pressing Enter in the chat box does (Prepare<kind>, then the chat window's own input handler,
-- which calls UChat::ExecuteChatCommand("<command> <text>")); users(): the chat's lobby list (who all/team chat goes
-- to); history(): every chat line this client has shown.
FCE_CHAT = FCE_CHAT or {}
local T = FCE_CHAT

local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local function chat() return FindFirstOf("Chat") end

-- the chat window on screen now: custom lobby, hero select or match HUD
local function window()
    local pc = FindFirstOf("BP_PC_MOBA_PlayerController_C")
    if valid(pc) and valid(pc.WB_ChatGamplayRef) then
        return pc.WB_ChatGamplayRef.WB_ChatSocial_Accelbyte.WB_ChatWindow_Accelbyte, "match"
    end
    local lpc = FindFirstOf("BP_PC_Lobby_PlayerController_C")
    if valid(lpc) then
        local h = lpc.WB_LobbyHeroSelectRef
        if valid(h) and h:IsInViewport() then return h.WB_ChatSocial_Accelbyte.WB_ChatWindow_Accelbyte, "hero select" end
        local m = lpc.WB_LobbyMenuRef
        if valid(m) and m:IsInViewport() then return m.WB_ChatSocial_Accelbyte.WB_ChatWindow_Accelbyte, "lobby" end
    end
    return nil, "none"
end

function T.users()
    local c = chat()
    local t = {}
    c.LobbyUsers:ForEach(function(_, e)
        local u = e:get()
        t[#t + 1] = string.format("%s/%s/%s", u.DisplayName:ToString(), u.UserId:ToString(), u.bTeammate and "team" or "enemy")
    end)
    local _, where = window()
    return string.format("chat users: location=%d window=%s command=%q users=[%s]", c.ChatLocation, where,
        c.CurrentCommand:ToString(), table.concat(t, ", "))
end

function T.say(kind, text)
    local c = chat()
    if kind == "all" then c:PrepareAll() elseif kind == "team" then c:PrepareTeam() else c:PrepareParty() end
    local w, where = window()
    if not valid(w) then
        c:ExecuteChatCommand(c.CurrentCommand:ToString() .. " " .. text)
        return string.format("said (no window, %s) %s: %s", where, c.CurrentCommand:ToString(), text)
    end
    w:HandleInputTrimming(FText(text), 1)   -- ETextCommit::OnEnter
    return string.format("said in %s window, %s: %s", where, c.CurrentCommand:ToString(), text)
end

local FLAGS = { [0] = "none", "whisper", "party", "team", "surrender", "system", "all" }
function T.history()
    local t = {}
    chat().ChatHistory:ForEach(function(_, e)
        local x = e:get()
        t[#t + 1] = string.format("%s<%s> %s", FLAGS[x.MessageFlag] or tostring(x.MessageFlag), x.From:ToString(), x.Message:ToString())
    end)
    return "chat history: " .. table.concat(t, " | ")
end

-- the match's chat window stays hidden until Enter: open it for screenshots
function T.open()
    local pc = FindFirstOf("BP_PC_MOBA_PlayerController_C")
    if valid(pc) and valid(pc.WB_ChatGamplayRef) then pc.WB_ChatGamplayRef:OpenChatWindow() return "chat window opened" end
    return "no match chat window"
end
