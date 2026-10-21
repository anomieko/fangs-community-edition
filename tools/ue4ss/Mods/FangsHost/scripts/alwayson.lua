-- Abilities that run all match from a single start (FangsHost, game servers; docs/recon/fiorne.md and
-- docs/recon/community-build-passives.md). The game starts each once, when the hero spawns, and never again. Their
-- start gives up when the hero's player state isn't there yet or the commit fails (BP_GA_Template_Ammo L630-L2181,
-- BP_GA_Passive_Base, BP_GA_Gunslinger_Reload): it ends itself at once. On the live server that is a race at spawn,
-- so Fiorne played about every second match without Bunny Stacks (21 Oct), and Wylde had "0 ammo entire game".
-- Every 2 s, on arena maps, for each living hero, one of these seen not running on two passes in a row (a normal start
-- is immediate):
--   * Fiorne's stack system (BP_GA_Lancer_Ammo) and Wylde's reload (BP_GA_Gunslinger_Reload) are started again. Both are
--     listeners that a new start sets up from scratch (fiorne.json makes the stack system's setup clear the old one).
--   * Fiorne's passive (GA_Lancer_P) is started again only if she has no stack system at all: its start grants one,
--     and a second grant would give her two stack systems that fight. Otherwise (and Wylde's passive) it is only logged.
-- Every action is logged ("always-on: ..."). Off switch: ENABLED = false.
local ENABLED = true

return function(env)
    local log, every, gameState = env.log, env.every, env.gameState
    local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
    local WATCH = {   -- ability class -> { what players call it, how to recover }
        BP_GA_Lancer_Ammo_C = { "Fiorne's Bunny Stacks", "restart" },
        BP_GA_Gunslinger_Reload_C = { "Wylde's reload", "restart" },
        GA_Lancer_P_C = { "Fiorne's passive", "restart without stacks" },
        BP_GA_Gunslinger_P_C = { "Wylde's passive", "log" },
    }
    local DEAD = nil
    local idle = {}    -- "<pawn address> <class>" -> passes in a row seen not running
    local logged = 0
    local told = {}    -- "<pawn address> <class>" already logged as left alone
    local function note(msg)
        logged = logged + 1
        if logged <= 60 then log("always-on: " .. msg) end
    end
    every(2000, function()
        if not ENABLED then return true end   -- the loop idles (never cancelled: docs/recon/server-performance.md)
        local gs = gameState()
        if not gs then return end
        if not gs:GetClass():GetFName():ToString():find("^GS_MOBA_Battle") then idle, told = {}, {}; return end   -- and its per-map subclasses
        DEAD = DEAD or { TagName = FName("State.Dead") }
        gs.PlayerArray:ForEach(function(_, e)
            pcall(function()
                local ps = e:get()
                local p = valid(ps) and ps.PawnPrivate
                if not valid(p) then return end
                local asc = p.AbilitySystemComponent
                if not valid(asc) or asc:HasMatchingGameplayTag(DEAD) then return end
                local who = ps:GetPlayerName():ToString()
                local stopped, hasStacks = {}, false
                asc.ActivatableAbilities.Items:ForEach(function(_, s)
                    local spec = s:get()
                    local ab = spec.Ability
                    if not valid(ab) then return end
                    local cls = ab:GetClass()
                    local name = cls:GetFName():ToString()
                    if name == "BP_GA_Lancer_Ammo_C" then hasStacks = true end
                    if not WATCH[name] then return end
                    local key = string.format("%x %s", p:GetAddress(), name)
                    if spec.ActiveCount > 0 then idle[key] = nil; return end
                    idle[key] = (idle[key] or 0) + 1
                    if idle[key] >= 2 then idle[key] = nil; stopped[#stopped + 1] = { name = name, cls = cls } end
                end)
                for _, st in ipairs(stopped) do
                    local what, how = WATCH[st.name][1], WATCH[st.name][2]
                    if how == "restart" or (how == "restart without stacks" and not hasStacks) then
                        local ok, started = pcall(function() return asc:TryActivateAbilityByClass(st.cls, true) end)
                        note(string.format("%s of %s wasn't running: started again (%s)", what, who,
                            ok and tostring(started) or ("error: " .. tostring(started))))
                    else
                        local key = string.format("%x %s", p:GetAddress(), st.name)
                        if not told[key] then told[key] = true; note(string.format("%s of %s isn't running (left alone)", what, who)) end
                    end
                end
            end)
        end)
    end)
    log("always-on abilities watched (" .. (ENABLED and "on" or "off") .. ")")
end
