-- Rowan's passive on Overgrowth (tools/run/test_rowan_heal.sh, steps tools/run/test_rowan_heal.steps), loaded with
-- dofile on the game server after tools/run/test_patch.lua. Global R. Writes rowan.log in the server's Win64 folder.
--   R.rate(name)          the passive's heal rate as the server's passive instance holds it (Heal Sprite: x1.65),
--                         and the hero's heirlooms
--   R.aug(name)           what Heal Sprite does to the passive (SetupRegenAugment: rate = 2 x ItemRegenMultiplier)
--   R.near(name, d)       the hero d units from the newest Sourblossom: in its Overgrowth ring, off the plant itself
--   R.into(name, kind, d) the hero into the newest Earth Rend arc (kind "arc") or ult Overgrowth ("ult", The
--                         Bloomblade), where its collision really overlaps him; the newest Sourblossom moved d units
--                         from him, so he stands in both (the same frame: the plant never sees him leave)
--   R.track(name, s, l)   every 0.25 s for s seconds: health, the passive's heal and Overgrowth effects, the Earth Rend
--                         arc heal, the passive buff tag, the newest Sourblossom's IsPlayerInCreep and distance
R = R or {}
local GPS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local W = "/Game/Gameplay/Abilities/Player/WoodenSword/"
local PLANT = W .. "Skill4/Actors/BP_TA_WoodenSword_Skill4.BP_TA_WoodenSword_Skill4_C"
local AREA = { arc = { W .. "RMB/Actors/BP_TA_WoodenSword_RMB.BP_TA_WoodenSword_RMB_C", "ConeMesh" },
               ult = { W .. "Skill3/Actors/BP_TA_WoodenSword_Skill3Overgrowth.BP_TA_WoodenSword_Skill3Overgrowth_C", "Box" } }
local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local function now() return GPS:GetTimeSeconds(FindFirstOf("GameStateBase")) end
local logf
local function log(msg)
    logf = logf or io.open("rowan.log", "a")
    logf:write(string.format("%8.2f %s\n", now(), msg)); logf:flush()
end
local function loadClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
    c = StaticFindObject(path)
    return valid(c) and c or nil
end
local function hero(name)
    local gs = FindFirstOf("GameStateBase")
    for i = 1, gs.PlayerArray:GetArrayNum() do
        local ps = gs.PlayerArray[i]
        if valid(ps) and ps:GetPlayerName():ToString() == name and valid(ps.PawnPrivate) then return ps.PawnPrivate end
    end
end
-- the actor of a class created last (GetAllActorsOfClass, tests only)
local function newest(ctx, path)
    local cls = loadClass(path)
    if not cls then return nil end
    local res, best, age = {}, nil, math.huge
    GPS:GetAllActorsOfClass(ctx, cls, res)
    local list = res.OutActors
    if list == nil and res[1] ~= nil then list = res end
    local function consider(o)
        if not valid(o) then pcall(function() o = o:get() end) end
        if valid(o) then
            local t = o:GetGameTimeSinceCreation()
            if t < age then best, age = o, t end
        end
    end
    if type(list) == "table" then for _, o in pairs(list) do consider(o) end
    elseif list ~= nil then pcall(function() list:ForEach(function(_, e) consider(e) end) end) end
    return best
end
local function passive(p)
    local cls = loadClass(W .. "Passive/BP_GA_WoodenSword_P.BP_GA_WoodenSword_P_C")
    local lib = StaticFindObject("/Script/MOBA.Default__MOBAAbilityLibrary")
    return lib:GetAbilityInstanceFromAbilityClass(p.AbilitySystemComponent, cls)
end
local function effects(p)
    local t = {}
    pcall(function()
        p.AbilitySystemComponent.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, e)
            local d = e:get().Spec.Def
            if valid(d) then
                local n = d:GetClass():GetFName():ToString():gsub("_C$", "")
                t[n] = (t[n] or 0) + 1
            end
        end)
    end)
    return t
end
local function hasBuff(p)
    local ok, r = pcall(function()
        return p.AbilitySystemComponent:HasMatchingGameplayTag({ TagName = FName("Effect.WoodenSword.Passive.Buff") })
    end)
    return ok and r
end
local function dist(a, b)
    local x, y = a:K2_GetActorLocation(), b:K2_GetActorLocation()
    return math.sqrt((x.X - y.X) ^ 2 + (x.Y - y.Y) ^ 2)
end

function R.rate(name)
    local p = hero(name)
    if not valid(p) then return "rate: no hero " .. name end
    local ab = passive(p)
    if not valid(ab) then return "rate: no passive" end
    local items = {}
    pcall(function()
        p.PlayerState.HeroEquipment:ForEach(function(_, e)
            local it = e:get()
            if valid(it) then items[#items + 1] = it.ItemTag.TagName:ToString():gsub("^Items%.", "") end
        end)
    end)
    local s = string.format("%s's passive: MissingHealthHPS %.3g, ModifiedMissingHealthHPS %.3g, ItemRegenMultiplier %.3g; heirlooms: %s",
        name, ab.MissingHealthHPS, ab.ModifiedMissingHealthHPS, ab.ItemRegenMultiplier, table.concat(items, ", "))
    log(s)
    return "rate: " .. s
end

function R.aug(name)
    local p = hero(name)
    if not valid(p) then return "aug: no hero " .. name end
    local ab = passive(p)
    if not valid(ab) then return "aug: no passive" end
    local before = ab.ModifiedMissingHealthHPS
    ab:SetupRegenAugment()
    local s = string.format("%s's passive: SetupRegenAugment (Heal Sprite's effect), rate %.3g -> %.3g", name, before,
        ab.ModifiedMissingHealthHPS)
    log(s)
    return "aug: " .. s
end

function R.near(name, d)
    local p = hero(name)
    if not valid(p) then return "near: no hero " .. name end
    local plant = newest(p, PLANT)
    if not valid(plant) then return "near: no Sourblossom" end
    local l = plant:K2_GetActorLocation()
    p:K2_SetActorLocation({ X = l.X + d, Y = l.Y, Z = p:K2_GetActorLocation().Z }, false, {}, true)
    local s = string.format("%s %.0f from the newest Sourblossom (its ring radius %.0f)", name, dist(p, plant), plant.CurrentCreepRadius)
    log(s)
    return "near: " .. s
end

function R.into(name, kind, d)
    local p = hero(name)
    if not valid(p) then return "into: no hero " .. name end
    local area = newest(p, AREA[kind][1])
    if not valid(area) then return "into: no " .. kind end
    local comp = area[AREA[kind][2]]
    local z = p:K2_GetActorLocation().Z
    -- candidates: the collision's bounds centre, the component's origin, points along the area's facing
    local cands = {}
    pcall(function()
        local o, e, r = {}, {}, {}
        KSL:GetComponentBounds(comp, o, e, r)
        local c = o.Origin or (o.X and o) or nil
        if c then cands[#cands + 1] = { c.X, c.Y, "bounds centre" } end
    end)
    local cl = comp:K2_GetComponentLocation()
    cands[#cands + 1] = { cl.X, cl.Y, "component origin" }
    local al, yaw = area:K2_GetActorLocation(), math.rad(area:K2_GetActorRotation().Yaw)
    for k = 100, 1000, 100 do cands[#cands + 1] = { al.X + math.cos(yaw) * k, al.Y + math.sin(yaw) * k, k .. " ahead" } end
    local at
    for _, c in ipairs(cands) do
        p:K2_SetActorLocation({ X = c[1], Y = c[2], Z = z }, false, {}, true)
        if comp:IsOverlappingActor(p) then at = c break end
    end
    local plant = newest(p, PLANT)
    local s
    if not at then s = string.format("%s: no spot inside the newest %s (%d tried)", name, kind, #cands)
    else
        if valid(plant) then
            local l = p:K2_GetActorLocation()
            plant:K2_SetActorLocation({ X = l.X + d, Y = l.Y, Z = plant:K2_GetActorLocation().Z }, false, {}, true)
        end
        s = string.format("%s inside the %s (%s), %.0f from the newest Sourblossom (ring %.0f, IsPlayerInCreep %s), buff %s",
            name, kind, at[3], valid(plant) and dist(p, plant) or -1, valid(plant) and plant.CurrentCreepRadius or -1,
            valid(plant) and tostring(plant.IsPlayerInCreep) or "-", tostring(hasBuff(p)))
    end
    log(s)
    return "into: " .. s
end

function R.track(name, seconds, label)
    local p = hero(name)
    if not valid(p) then return "track: no hero " .. name end
    local set = p.AbilitySystemComponent.SpawnedAttributes[1]
    local t0, n, last = now(), 0, set.Health.CurrentValue
    log(string.format("== %s %s, health %.1f/%.0f", name, label or "", last, set.MaxHealth.CurrentValue))
    LoopInGameThreadWithDelay(250, function()
        n = n + 1
        if n > seconds * 4 or not valid(p) then return end
        local e, hp = effects(p), set.Health.CurrentValue
        local plant = newest(p, PLANT)
        log(string.format("%6.2f health %6.1f (%+5.1f) passive-heal %d overgrowth %d arc-heal %d buff %s | plant %s",
            now() - t0, hp, hp - last, e.BP_GE_DotHealFourPerSec or 0, e.BP_GE_WoodenSword_Skill4_Creep or 0,
            e.BP_GE_WoodenSword_HealingOverTime or 0, hasBuff(p) and "y" or "n",
            valid(plant) and string.format("%.0f away, ring %.0f, in %s", dist(p, plant), plant.CurrentCreepRadius,
                plant.IsPlayerInCreep and "y" or "n") or "-"))
        last = hp
    end)
    return "track " .. name .. " " .. (label or "")
end

return "test_rowan.lua loaded"
