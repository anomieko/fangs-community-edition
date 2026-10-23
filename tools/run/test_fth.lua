-- Helpers for tools/run/test_fth.sh: Wylde's ammo through the start of a match, as the game server and his own client
-- see it. Loaded by FangsCtl (dofile).
--   watch(name, seconds)  every 50 ms, when any of them changes, to fth.log in the process's Win64 folder (on a client,
--                         name "local" is its own hero, as that client sees it):
--                         loaded bullets (BP_GE_Gunslinger_P_Bullets stacks, and each such effect as stacks@level),
--                         Modified/Base MaxBullets, bullets per LMB shot, Fan the Hammers and the reload running,
--                         Bounty's Reward stacks / bonus, the round state; and the Fan the Hammers bullets spawned
--                         (counted per cast).
FCE_FTH = FCE_FTH or {}
local F = FCE_FTH

local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local GPS
local function now(ctx)
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return GPS:GetTimeSeconds(ctx)
end
local function gameState()
    local gi = FindFirstOf("BP_MOBAInstance_C")
    local gs = gi and gi:GetWorld().GameState
    return valid(gs) and gs or nil
end
local function hero(name)   -- "local": this client's own hero
    if name == "local" then
        GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local ok, p = pcall(function() return GPS:GetPlayerController(FindFirstOf("BP_MOBAInstance_C"), 0).Pawn end)
        return ok and valid(p) and p or nil
    end
    local gs, found = gameState(), nil
    if not gs then return nil end
    gs.PlayerArray:ForEach(function(_, e)
        local ps = e:get()
        if valid(ps) and ps:GetPlayerName():ToString() == name and valid(ps.PawnPrivate) then found = ps.PawnPrivate end
    end)
    return found
end

local logf
local function log(msg)
    logf = logf or io.open("fth.log", "a")
    logf:write(msg .. "\n"); logf:flush()
end

local function stacks(p, cls)   -- summed stack count of the active effects of one class
    local n = 0
    p.AbilitySystemComponent.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, e)
        local ge = e:get()
        local d = ge.Spec.Def
        if valid(d) and d:GetClass():GetFName():ToString() == cls then n = n + math.max(ge.Spec.StackCount, 1) end
    end)
    return n
end
local function each(p, cls)   -- every active effect of one class: stacks@level (a stacking effect should be one)
    local t = {}
    p.AbilitySystemComponent.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, e)
        local ge = e:get()
        local d = ge.Spec.Def
        if valid(d) and d:GetClass():GetFName():ToString() == cls then
            local okL, lv = pcall(function() return ge.Spec.Level end)
            t[#t + 1] = string.format("%d@%s", ge.Spec.StackCount, okL and tostring(lv) or "?")
        end
    end)
    return #t > 0 and table.concat(t, ",") or "none"
end
local function running(p, cls)   -- ActiveCount of an ability, "-" when the hero doesn't have it
    local r = "-"
    p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e)
        local s = e:get()
        if valid(s.Ability) and s.Ability:GetClass():GetFName():ToString() == cls then r = tostring(s.ActiveCount) end
    end)
    return r
end
local function roundState()
    local gs = gameState()
    if not gs then return "?" end
    local s = "?"
    pcall(function() s = string.format("round %d+%d", gs.TeamARoundsWon, gs.TeamBRoundsWon) end)
    pcall(function() if gs:IsAtItemSelection() then s = s .. " items" end end)
    pcall(function() if gs:IsAtKingSelection() then s = s .. " captain" end end)
    return s
end

local PROJ = "/Game/Gameplay/Abilities/Player/Gunslinger/E/BP_MOBA_Gunslinger_Skill2_Projectile.BP_MOBA_Gunslinger_Skill2_Projectile_C"
F.shots, F.cast = 0, 0

function F.watch(name, seconds)
    if F.watching then return "already watching" end
    local p = hero(name)
    if not valid(p) then return "watch: no hero " .. name end
    F.watching = true
    local okN, errN = pcall(NotifyOnNewObject, PROJ, function() F.shots = F.shots + 1 end)
    local t0, last, done, fthWas = now(p), nil, false, "0"
    LoopInGameThreadWithDelay(50, function()
        if done then return end
        if not valid(p) then p = hero(name) end
        if not valid(p) then return end
        local t = now(p) - t0
        if t > seconds then done = true; return end
        local ok, s = pcall(function()
            local fth = running(p, "BP_GA_Gunslinger_E_C")
            if fth ~= "0" and fth ~= "-" and fthWas == "0" then F.cast = F.cast + 1; F.shots = 0 end
            fthWas = fth
            return string.format("ammo=%d [%s] max=%d base=%d perLMB=%d fth=%s(cast %d, %d bullets spawned) reload=%s bounty=%d/%d   [%s]",
                stacks(p, "BP_GE_Gunslinger_P_Bullets_C"), each(p, "BP_GE_Gunslinger_P_Bullets_C"), p["Modified MaxBullets"], p["Base Max Bullets"], p.BulletsToFire,
                fth, F.cast, F.shots, running(p, "BP_GA_Gunslinger_Reload_C"),
                stacks(p, "BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack_C"), stacks(p, "BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseApplied_C"),
                roundState())
        end)
        s = ok and s or ("error: " .. tostring(s):match("[^\n]*"))
        if s ~= last then last = s; log(string.format("%8.2f %s", now(p), s)) end
    end)
    return "watch: " .. name .. (okN and "" or (" (no bullet counter: " .. tostring(errN) .. ")"))
end

-- Server: every call that loads Wylde's gun, with its argument and the hero's bullets at that moment (fth.log): the
-- passive's round-start refill and its countdown reload, the reload ability's Do Reload / Start Reload / Check Reload,
-- the hero's Add Loaded Bullets, and any ability applying the bullet effect (BP_ApplyGameplayEffectToOwner).
local G = "/Game/Gameplay/Abilities/Player/Gunslinger/Passive/"
local HOOKS = {
    { "/Game/BluePrints/Character/BP_Gunslinger_Char.BP_Gunslinger_Char_C:Add Loaded Bullets", true },
    { G .. "BP_GA_Gunslinger_Reload.BP_GA_Gunslinger_Reload_C:Do Reload", true },
    { G .. "BP_GA_Gunslinger_Reload.BP_GA_Gunslinger_Reload_C:Start Reload" },
    { G .. "BP_GA_Gunslinger_Reload.BP_GA_Gunslinger_Reload_C:Check Reload" },
    { G .. "BP_GA_Gunslinger_Reload.BP_GA_Gunslinger_Reload_C:On Round Start" },
    { G .. "BP_GA_Gunslinger_P.BP_GA_Gunslinger_P_C:Reset Bullets to Modified Max" },
    { G .. "BP_GA_Gunslinger_P.BP_GA_Gunslinger_P_C:ForceReloadRoundStart" },
    { G .. "BP_GA_Gunslinger_P.BP_GA_Gunslinger_P_C:OnRoundStart" },
}
function F.hooks(name)
    if F.hooked then return "already hooked" end
    F.hooked = true
    local function ammo() local p = hero(name); return valid(p) and stacks(p, "BP_GE_Gunslinger_P_Bullets_C") or -1 end
    local out = {}
    for _, h in ipairs(HOOKS) do
        local fn = h[1]:match(":(.+)$")
        local ok, err = pcall(RegisterHook, h[1], function(ctx, a)
            local arg = ""
            if h[2] then local okA, v = pcall(function() return a:get() end); arg = okA and tostring(v) or "?" end
            log(string.format("%8.2f   call %s(%s) on %s, ammo %d", now(ctx:get()), fn, arg, ctx:get():GetFName():ToString(), ammo()))
        end)
        out[#out + 1] = fn .. (ok and "" or (" NOT hooked: " .. tostring(err)))
    end
    local ok, err = pcall(RegisterHook, "/Script/GameplayAbilities.GameplayAbility:BP_ApplyGameplayEffectToOwner", function(ctx, cls, lv, st)
        local okC, c = pcall(function() return cls:get():GetFName():ToString() end)
        if okC and c:find("Bullets", 1, true) then
            log(string.format("%8.2f   call BP_ApplyGameplayEffectToOwner(%s, level %s, stacks %s) from %s, ammo %d", now(ctx:get()), c,
                tostring(lv:get()), tostring(st:get()), ctx:get():GetClass():GetFName():ToString(), ammo()))
        end
    end)
    out[#out + 1] = "BP_ApplyGameplayEffectToOwner" .. (ok and "" or (" NOT hooked: " .. tostring(err)))
    return "hooks: " .. table.concat(out, ", ")
end

function F.mark(text)   -- a line in fth.log, e.g. which key the test pressed
    log("-- " .. text)
    return "mark: " .. text
end

return "test_fth helpers"
