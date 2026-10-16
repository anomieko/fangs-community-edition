-- Ethryn's shield test (tools/run/test_shield.sh, steps tools/run/test_shield.steps), loaded with dofile on the
-- clients and the game server. Global S.
--   client: S.aimAt(name)  puts the mouse on that player's hero, so this hero's pointer (and aim) is on it
--   server: S.watch()      logs every projectile Ethryn's shield reflects to shield.log: how deep into the plate
--                          and how far to the side it was, where the reflected copy starts, the shooter's health
--           S.hp(name)     a hero's health, to shield.log
S = S or {}
local GPS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local logf
local function log(msg)
    logf = logf or io.open("shield.log", "a")
    logf:write(string.format("%8.2f %s\n", GPS:GetTimeSeconds(FindFirstOf("GameStateBase")), msg)); logf:flush()
end
local function heroes()
    local t, gs = {}, FindFirstOf("GameStateBase")
    for i = 1, gs.PlayerArray:GetArrayNum() do
        local ps = gs.PlayerArray[i]
        local p = valid(ps) and ps.PawnPrivate or nil
        if valid(p) then t[ps:GetPlayerName():ToString()] = p end
    end
    return t
end

function S.aimAt(name)
    local p = heroes()[name]
    if not valid(p) then return "aimAt: no hero " .. name end
    local pc = GPS:GetPlayerController(FindFirstOf("BP_MOBAInstance_C"), 0)
    local out = {}
    local ok = pc:ProjectWorldLocationToScreen(p:K2_GetActorLocation(), out, false)
    local x, y = out.ScreenLocation and out.ScreenLocation.X, out.ScreenLocation and out.ScreenLocation.Y
    if not x then
        local v = { X = 0, Y = 0 }
        pc:ProjectWorldLocationToScreen(p:K2_GetActorLocation(), v, false)
        x, y = v.X, v.Y
    end
    pc:SetMouseLocation(math.floor(x), math.floor(y))
    return string.format("aimAt %s: mouse %d,%d (%s)", name, math.floor(x), math.floor(y), tostring(ok))
end

function S.hp(name)
    local p = heroes()[name]
    if not valid(p) then return "hp: no hero " .. name end
    local set = p.AbilitySystemComponent.SpawnedAttributes[1]
    local s = string.format("%s health %.0f/%.0f", name, set.Health.CurrentValue, set.MaxHealth.CurrentValue)
    log(s)
    return s
end

local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function sub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end

function S.watch()
    if S.watching then return "already watching" end
    local path = "/Game/Gameplay/TargetTypes/ShieldGirl/BP_TA_ShieldGirl_Skill4.BP_TA_ShieldGirl_Skill4_C"
    if not valid(StaticFindObject(path)) then
        pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
    end
    if not valid(StaticFindObject(path)) then return "watch: shield class not loaded" end
    RegisterHook(path .. ":OnProjectileOverlap", function(ctx, projectile)
        local ok, err = pcall(function()
            local ta, pr = ctx:get(), projectile:get()
            local box = ta.wer
            local c, f, r = box:K2_GetComponentLocation(), box:GetForwardVector(), box:GetRightVector()
            local pl = pr:K2_GetActorLocation()
            local d = sub(pl, c)
            local name = pr:GetFName():ToString()
            local n, clone = ta.ToReflect:GetArrayNum(), nil
            if n > 0 then clone = ta.ToReflect[n] end
            local cl = valid(clone) and sub(clone:K2_GetActorLocation(), c) or nil
            log(string.format("reflect %s: depth %.0f side %.0f (radius %.0f/%.0f) -> copy at depth %s, applies effects %s, %d reflected so far",
                name, dot(d, f), dot(d, r), pr.ProjectileSphere:GetScaledSphereRadius(), pr.ProjectileInteractionsSphere:GetScaledSphereRadius(),
                cl and string.format("%.0f", dot(cl, f)) or "-", valid(clone) and tostring(clone.bShouldApplyEffects) or "-", n))
        end)
        if not ok then log("hook error: " .. tostring(err)) end
    end)
    S.watching = true
    return "watching the shield"
end

return "test_shield helpers"
