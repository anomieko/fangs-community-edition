-- Abilities that run all match from a single start (FangsHost, game servers; docs/recon/fiorne.md and
-- docs/recon/community-build-passives.md): Fiorne's Bunny Stacks system (BP_GA_Lancer_Ammo) and the passive that
-- grants it (GA_Lancer_P), Wylde's passive (BP_GA_Gunslinger_P) and his reload (BP_GA_Gunslinger_Reload, which fills
-- his gun). Measured: each starts once, when the hero spawns, and stays running all match (active count 1). Nothing
-- in the game starts one again, so a start that is refused (Fiorne's stacks inside a protected base: the input lock,
-- tools/patch/patches/fiorne-stacks.json) or a later stop leaves the hero without stacks or ammo for the rest of the
-- match. The safety net: every 2 s, one of these seen not running on two passes in a row (a normal start is
-- immediate) is started again, and logged ("always-on: ..."). Dead heroes are left alone. Arena maps only.
-- Off switch: ENABLED = false.
local ENABLED = true

return function(env)
    local log, every, gameState = env.log, env.every, env.gameState
    local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
    local WATCH = {   -- ability class -> what players call it
        BP_GA_Lancer_Ammo_C = "Fiorne's Bunny Stacks",
        GA_Lancer_P_C = "Fiorne's passive",
        BP_GA_Gunslinger_P_C = "Wylde's passive",
        BP_GA_Gunslinger_Reload_C = "Wylde's reload",
    }
    local DEAD = nil
    local idle = {}    -- "<pawn address> <class>" -> passes in a row seen not running
    local logged = 0
    every(2000, function()
        if not ENABLED then return true end   -- the loop idles (never cancelled: docs/recon/server-performance.md)
        local gs = gameState()
        if not gs then return end
        if not gs:GetClass():GetFName():ToString():find("^GS_MOBA_Battle") then idle = {}; return end   -- and its per-map subclasses
        DEAD = DEAD or { TagName = FName("State.Dead") }
        gs.PlayerArray:ForEach(function(_, e)
            pcall(function()
                local ps = e:get()
                local p = valid(ps) and ps.PawnPrivate
                if not valid(p) then return end
                local asc = p.AbilitySystemComponent
                if not valid(asc) or asc:HasMatchingGameplayTag(DEAD) then return end
                asc.ActivatableAbilities.Items:ForEach(function(_, s)
                    local spec = s:get()
                    local ab = spec.Ability
                    if not valid(ab) then return end
                    local cls = ab:GetClass()
                    local name = cls:GetFName():ToString()
                    if not WATCH[name] then return end
                    local key = string.format("%x %s", p:GetAddress(), name)
                    if spec.ActiveCount > 0 then idle[key] = nil; return end
                    idle[key] = (idle[key] or 0) + 1
                    if idle[key] < 2 then return end
                    idle[key] = nil
                    local ok, started = pcall(function() return asc:TryActivateAbilityByClass(cls, true) end)
                    logged = logged + 1
                    if logged <= 40 then
                        log(string.format("always-on: %s of %s wasn't running: started again (%s)", WATCH[name],
                            ps:GetPlayerName():ToString(), ok and tostring(started) or ("error: " .. tostring(started))))
                    end
                end)
            end)
        end)
    end)
    log("always-on abilities watched (" .. (ENABLED and "on" or "off") .. ")")
end
