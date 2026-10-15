-- Helpers for tools/run/test_patch.sh (docs/PATCHING.md), loaded by FangsCtl (dofile) into both clients and the game
-- server, after FCE_PATCH_WANT (the patched class defaults the test expects, generated from the patch files).
--   check()          every process: the patched defaults as this game process loaded them. All as patched = the patch
--                    pak is mounted and its files win over the game's own pak.
--   watch()          server: logs the CC and ability-lock effects on every hero whenever they change (100 ms steps,
--                    game time) to patchwatch.log in the game server's Win64 folder.
--   face(a, b, d)    server: hero b stands d units from hero a, towards a's mouse pointer: a's skill shots go through b.
--   aim(a, b, range) server: hero b where a's targeted abilities land (a's pointer, clamped to the ability's range).
--   fill(name)       server: the hero's mana to full (ults cost mana).
--   fire(pattern)    client: activates the own hero's ability whose class name contains pattern.
--   count(class)     client: how many live objects of a class exist (e.g. a gameplay cue's actor: the visual played).
FCE_PATCH = FCE_PATCH or {}
local T = FCE_PATCH

local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local KSL, GPS
local function loadClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
    c = StaticFindObject(path)
    return valid(c) and c or nil
end
local function show(v)
    if type(v) == "number" then return string.format("%.4g", v) end
    if valid(v) then return v:GetFName():ToString() end
    return tostring(v)
end

function T.check()
    local want, ok, bad = FCE_PATCH_WANT or {}, 0, {}
    for _, w in ipairs(want) do   -- { "/Game/.../<asset>", "<class without _C>", "Property", expected }
        loadClass(w[1] .. "." .. w[2] .. "_C")
        local cdo = StaticFindObject(w[1] .. ".Default__" .. w[2] .. "_C")
        local got = "class not loaded"
        if valid(cdo) then local okv, v = pcall(function() return cdo[w[3]] end); got = okv and show(v) or "no property" end
        if got == show(w[4]) then ok = ok + 1 else bad[#bad + 1] = w[2] .. "." .. w[3] .. "=" .. got end
    end
    return string.format("patched defaults: %d/%d as patched%s", ok, #want, #bad > 0 and ("; not: " .. table.concat(bad, ", ")) or "")
end

-- ---------------------------------------------------------------------------------------------- server
local CC = { BP_GE_Stun = "STUN", BP_GE_Root = "ROOT", BP_GE_Charm = "CHARM", BP_GE_BookMage_Skill3_Charm = "CHARM",
             BP_GE_Fear = "FEAR", BP_GE_KnockUp = "KNOCKUP", BP_GE_Incapacitate = "INCAP",
             BP_GE_LockAbilities = "ABILITY-LOCK", BP_GE_LockCastDebuff = "CAST-LOCK" }
local heroes, lookedUp = {}, -1

local function pname(p) local ok, n = pcall(function() return p.PlayerState:GetPlayerName():ToString() end); return ok and n or "?" end
local function hero(name)
    for _, p in ipairs(heroes) do if valid(p) and pname(p) == name then return p end end
end
local function now(ctx)
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return GPS:GetTimeSeconds(ctx)
end
local function ccOf(p)
    local t = {}
    pcall(function()
        p.AbilitySystemComponent.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, e)
            local d = e:get().Spec.Def
            local n = valid(d) and CC[d:GetClass():GetFName():ToString():gsub("_C$", "")]
            if n then t[#t + 1] = n end
        end)
    end)
    table.sort(t)
    return #t > 0 and table.concat(t, "+") or "-"
end
local logf
local function log(msg)
    logf = logf or io.open("patchwatch.log", "a")
    logf:write(msg .. "\n"); logf:flush()
end

function T.watch()
    if T.watching then return "already watching" end
    T.watching = true
    local last, t0 = "", nil
    LoopInGameThreadWithDelay(100, function()
        if #heroes < 2 and os.time() - lookedUp >= 2 then   -- an object scan: only until both heroes are there
            lookedUp = os.time(); heroes = {}
            for _, p in ipairs(FindAllOf("BP_PlayerChar_C") or {}) do
                if valid(p) and not p:GetFullName():find("Default__", 1, true) then heroes[#heroes + 1] = p end
            end
        end
        if #heroes == 0 then return end
        local parts = {}
        for _, p in ipairs(heroes) do
            if valid(p) then parts[#parts + 1] = string.format("%s(%s) %s", pname(p), p:GetClass():GetFName():ToString():gsub("^BP_", ""):gsub("_Char%d*_C$", ""), ccOf(p)) end
        end
        local s = table.concat(parts, " | ")
        if s ~= last then
            last = s; t0 = t0 or now(heroes[1])
            log(string.format("%7.2f %s", now(heroes[1]) - t0, s))
        end
    end)
    return "watching"
end

function T.face(a, b, d)
    local pa, pb = hero(a), hero(b)
    if not (valid(pa) and valid(pb)) then return "face: no hero " .. (valid(pa) and b or a) end
    local la, pt = pa:K2_GetActorLocation(), pa.UpdatedPointerLocation
    local dx, dy = pt.X - la.X, pt.Y - la.Y
    local n = math.sqrt(dx * dx + dy * dy)
    if n < 1 then local yaw = math.rad(pa:K2_GetActorRotation().Yaw); dx, dy, n = math.cos(yaw), math.sin(yaw), 1 end
    pb:K2_SetActorLocation({ X = la.X + dx / n * d, Y = la.Y + dy / n * d, Z = la.Z }, false, {}, true)
    log(string.format("        %s placed %d from %s, towards %s's pointer (%.0f away)", b, d, a, a, n))
    return string.format("face: %s %d in front of %s (pointer %.0f away)", b, d, a, n)
end

function T.aim(a, b, range)   -- hero b where a's targeted abilities land: a's pointer, at most range units away
    local pa, pb = hero(a), hero(b)
    if not (valid(pa) and valid(pb)) then return "aim: no hero " .. (valid(pa) and b or a) end
    local la, pt = pa:K2_GetActorLocation(), pa.UpdatedPointerLocation
    local dx, dy = pt.X - la.X, pt.Y - la.Y
    local n = math.max(math.sqrt(dx * dx + dy * dy), 1)
    local d = math.min(n, range)
    pb:K2_SetActorLocation({ X = la.X + dx / n * d, Y = la.Y + dy / n * d, Z = la.Z }, false, {}, true)
    log(string.format("        %s placed where %s aims: %.0f away (pointer %.0f, range %d)", b, a, d, n, range))
    return string.format("aim: %s %.0f from %s", b, d, a)
end

function T.fill(name)   -- full mana (ults cost mana), on the server: replicated to the hero's client
    local p = hero(name)
    if not valid(p) then return "fill: no hero " .. name end
    local set = p.AbilitySystemComponent.SpawnedAttributes[1]
    local max = set.MaxMana.CurrentValue
    set.Mana.BaseValue = max; set.Mana.CurrentValue = max
    log(string.format("        %s's mana set to %.0f", name, max))
    return string.format("fill: %s mana %.0f/%.0f", name, set.Mana.CurrentValue, max)
end

-- ---------------------------------------------------------------------------------------------- client
function T.count(className)   -- live objects of a class, e.g. a gameplay cue's actor (an object scan)
    local n = 0
    for _, o in ipairs(FindAllOf(className) or {}) do
        if valid(o) and not o:GetFullName():find("Default__", 1, true) then n = n + 1 end
    end
    return string.format("count %s: %d", className, n)
end

function T.fire(pattern)
    local gi = FindFirstOf("BP_MOBAInstance_C")
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local p = GPS:GetPlayerController(gi, 0).Pawn
    if not valid(p) then return "fire: no pawn" end
    local cls
    p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e)
        local ab = e:get().Ability
        if valid(ab) and ab:GetClass():GetFName():ToString():find(pattern, 1, true) then cls = ab:GetClass() end
    end)
    if not cls then return "fire: no ability like " .. pattern end
    return "fire " .. cls:GetFName():ToString() .. " -> " .. tostring(p.AbilitySystemComponent:TryActivateAbilityByClass(cls, true))
end

return "test_patch helpers"
