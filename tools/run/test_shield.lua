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

-- client: keep the mouse on that player's hero for a while (heroes turn toward the cursor gradually)
function S.aimLoop(name, seconds)
    local n = 0
    LoopInGameThreadWithDelay(50, function()
        n = n + 1
        if n <= seconds * 20 then pcall(S.aimAt, name) end
    end)
    return "aiming at " .. name .. " for " .. seconds .. " s"
end

-- server: give a hero a skin the way BP_AC_SkinHandler's "Accelbyte Get Owner Skin" does after reading the profile:
-- Current SkinID and Current VFXPack set (both replicate) and their OnReps run here; the clients run theirs
function S.skin(name, id)
    local p = heroes()[name]
    if not valid(p) then return "skin: no hero " .. name end
    p:FlushNetDormancy()
    p["Current SkinID"] = id; p["OnRep_Current SkinID"](p)
    p["Current VFXPack"] = id; p["OnRep_Current VFXPack"](p)
    local ref = p.VFXPackRef
    return "skin " .. name .. " " .. id .. " -> pack " .. (valid(ref) and ref:GetFName():ToString() or "none")
end

-- client: what this machine has for that hero: skin, VFX pack, and the ult systems spawned so far (live components)
function S.vfx(name)
    local p = heroes()[name]
    if not valid(p) then return "vfx: no hero " .. name end
    local ref = p.VFXPackRef
    local n, seen = 0, {}
    for _, c in ipairs(FindAllOf("NiagaraComponent") or {}) do
        local ok, a = pcall(function() return c:GetAsset() end)
        if ok and valid(a) then
            local an = a:GetFName():ToString()
            if an:find("Skill3_ULT") or an:find("Skill3_CastVFX") then n = n + 1; seen[an] = (seen[an] or 0) + 1 end
        end
    end
    local list = {}
    for k, v in pairs(seen) do list[#list + 1] = k .. " x" .. v end
    local function str(v) local ok, s = pcall(function() return v:ToString() end); return ok and s or tostring(v) end
    return string.format("vfx %s: skin %s, pack %s (%s); ult systems %d: %s", name, str(p["Current SkinID"]),
        str(p["Current VFXPack"]), valid(ref) and ref:GetFName():ToString() or "none", n, table.concat(list, ", "))
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

-- server: alice and bob to the middle of the map (the midpoint of all player starts), d apart along the line between
-- the two teams' starts, full health and mana; away from the bases (their lasers kill enemies)
function S.stage(d)
    local starts = FindAllOf("PlayerStart") or {}
    if #starts < 2 then return "stage: no player starts" end
    local sx, sy, sz, n = 0, 0, 0, 0
    local a0, b0
    for _, ps in ipairs(starts) do
        local l = ps:K2_GetActorLocation()
        sx, sy, sz, n = sx + l.X, sy + l.Y, sz + l.Z, n + 1
        if not a0 then a0 = l elseif not b0 or (l.X - a0.X) ^ 2 + (l.Y - a0.Y) ^ 2 > (b0.X - a0.X) ^ 2 + (b0.Y - a0.Y) ^ 2 then b0 = l end
    end
    local mx, my, mz = sx / n, sy / n, sz / n
    local ux, uy = b0.X - a0.X, b0.Y - a0.Y
    local un = math.sqrt(ux * ux + uy * uy); ux, uy = ux / un, uy / un
    local h = heroes()
    local pa, pb = h.alice, h.bob
    if not (valid(pa) and valid(pb)) then return "stage: no heroes" end
    pa:K2_SetActorLocation({ X = mx - ux * d / 2, Y = my - uy * d / 2, Z = pa:K2_GetActorLocation().Z }, false, {}, true)
    pb:K2_SetActorLocation({ X = mx + ux * d / 2, Y = my + uy * d / 2, Z = pb:K2_GetActorLocation().Z }, false, {}, true)
    for _, p in ipairs({ pa, pb }) do
        local set = p.AbilitySystemComponent.SpawnedAttributes[1]
        set.Health.BaseValue = set.MaxHealth.CurrentValue; set.Health.CurrentValue = set.MaxHealth.CurrentValue
        set.Mana.BaseValue = set.MaxMana.CurrentValue; set.Mana.CurrentValue = set.MaxMana.CurrentValue
    end
    log(string.format("staged %d apart around %.0f,%.0f (%d player starts)", d, mx, my, n))
    return "staged"
end

-- server, for `seconds`: every 20 ms, each projectile of class `cls` (no _C) relative to the raised shield's plate:
-- depth along its facing (negative: in front of it), side offset, distance to Ethryn; logged when it changes much
function S.track(cls, seconds)
    local t0, last = GPS:GetTimeSeconds(FindFirstOf("GameStateBase")), {}
    local n = 0
    LoopInGameThreadWithDelay(20, function()
        n = n + 1
        if n > seconds * 50 then return end
        local ta = FindFirstOf("BP_TA_ShieldGirl_Skill4_C")
        if not valid(ta) then return end
        local box = ta.wer
        local c, f, r = box:K2_GetComponentLocation(), box:GetForwardVector(), box:GetRightVector()
        local e = ta:GetOwner()
        for _, pr in ipairs(FindAllOf(cls .. "_C") or {}) do
            if valid(pr) then
                local d = sub(pr:K2_GetActorLocation(), c)
                local k = pr:GetFName():ToString()
                local depth = dot(d, f)
                if not last[k] or math.abs(last[k] - depth) > 15 then
                    last[k] = depth
                    local el = valid(e) and e:K2_GetActorLocation() or c
                    local de = sub(pr:K2_GetActorLocation(), el)
                    log(string.format("  %s depth %.0f side %.0f to Ethryn %.0f", k, depth, dot(d, r), math.sqrt(de.X * de.X + de.Y * de.Y)))
                end
            end
        end
    end)
    return "tracking " .. cls
end

-- server: Rayo's Stormlense formula (BP_GA_LightningArcher_E_ "Range Damage Amp Calculate Damage") run on his own
-- ability instance with the distance set to r x range and 100 base damage; logs the damage it leaves for each r
function S.storm()
    local inst
    for _, a in ipairs(FindAllOf("BP_GA_LightningArcher_E__C") or {}) do
        if valid(a) and valid(a.Player) then inst = a end
    end
    if not inst then return "storm: no Lightning Strike instance with a player" end
    local l, out = inst.Player:K2_GetActorLocation(), {}
    local keep, keepRange = inst.ModifiedAbilityDamage, inst.ModifiedRange
    local range = inst.ModifiedRange > 0 and inst.ModifiedRange or inst.Range   -- set at cast time; 0 before
    inst.ModifiedRange = range
    for _, r in ipairs({ 0, 0.2, 0.3333, 0.5, 0.8, 0.95, 1.0, 1.2 }) do
        inst.SpawnLocation = { X = l.X + r * range, Y = l.Y, Z = l.Z }
        inst.ModifiedAbilityDamage = 100
        inst["Range Damage Amp Calculate Damage"](inst)
        out[#out + 1] = string.format("r=%.2f: %.1f", r, inst.ModifiedAbilityDamage)
    end
    inst.ModifiedAbilityDamage, inst.ModifiedRange = keep, keepRange
    local s = string.format("stormlense (range %.0f): %s", range, table.concat(out, ", "))
    log(s)
    return s
end

return "test_shield helpers"
