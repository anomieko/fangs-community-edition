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
--   stats(name)      server: the hero's health, Bunny Stacks and stack cooldowns (Fiorne), also to patchwatch.log.
--   track(name, s)   server: the hero's speed and Bunny Stacks every 50 ms for s seconds, to track.log.
--   regrant(name)    server: Fiorne's stack system removed and granted again mid-round, as the passive's safety net does.
--   chain(p, n, ms)  client: fire(p) n times, ms apart (game thread), results to chain.log.
--   health(name)     server: the hero's health, also to patchwatch.log.
--   hurt(n, f, by)   server: the hero hit by hero by, down to about f of its maximum health.
--   place(n, cls, d) server: the hero onto the newest actor of class path cls (e.g. a Sourblossom), d units ahead of it.
--   hptrack(n, s, l) server: the hero's health and heal effects every 0.25 s for s seconds, labelled l, to hp.log.
--   caltrops(name)   server: the Dourling Caltrops boxes: where they lie from the hero (ahead/behind), drawn or not.
--   stun(name, s, by) server: a stun of s seconds on the hero from hero by, as an enemy's ability applies it.
--   equip(path...)   client: once the augment phase is on, the own hero equips these items by tier, then locks in.
--   key(n)           client: presses and releases ability key n (BP_AC_InputManager.QueueInput: 3 = Space).
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
             BP_GE_LockAbilities = "ABILITY-LOCK", BP_GE_LockCastDebuff = "CAST-LOCK",
             BP_GE_AntiDisplacement_Duration = "ANTI-CC", BP_GE_AntiRoot_Duration = "ANTI-ROOT",
             BP_GE_AntiDisplacementandCC_Duration = "ANTI-CC+DISPLACEMENT" }
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

-- Server, for one hero: active effects by class (without _C) with their stack counts.
local function effectsOf(p)
    local t = {}
    pcall(function()
        p.AbilitySystemComponent.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, e)
            local s = e:get().Spec
            local d = s.Def
            if valid(d) then
                local n = d:GetClass():GetFName():ToString():gsub("_C$", "")
                t[n] = (t[n] or 0) + math.max(s.StackCount, 1)
            end
        end)
    end)
    return t
end
local function stacksOf(p)   -- Fiorne's Bunny Stacks (either stack effect), and the running stack cooldowns
    local e = effectsOf(p)
    return (e.BP_GE_Lancer_BunnyStacks or 0) + (e.BP_GE_Lancer_MoreBunnyStacks or 0), e.BP_GE_Ammo_Q_CD or 0
end

function T.stats(name)   -- health, Bunny Stacks, stack cooldowns running
    local p = hero(name)
    if not valid(p) then return "stats: no hero " .. name end
    local set = p.AbilitySystemComponent.SpawnedAttributes[1]
    local st, cd = stacksOf(p)
    local s = string.format("%s: health %.0f/%.0f, Bunny Stacks %d, stack cooldowns %d", name, set.Health.CurrentValue,
        set.MaxHealth.CurrentValue, st, cd)
    log("        " .. s)
    return "stats: " .. s
end

function T.track(name, seconds)   -- every 50 ms for a while: the hero's speed and Bunny Stacks, to track.log
    local p = hero(name)
    if not valid(p) then return "track: no hero " .. name end
    local f = io.open("track.log", "a")
    local t0, n = now(p), 0
    f:write(string.format("== %s from %.2f\n", name, t0))
    LoopInGameThreadWithDelay(50, function()
        n = n + 1
        if n > seconds * 20 then
            if n == seconds * 20 + 1 then f:close() end
            return
        end
        if not valid(p) then return end
        local v = p:GetVelocity()
        f:write(string.format("%6.2f speed %5.0f stacks %d\n", now(p) - t0, math.sqrt(v.X * v.X + v.Y * v.Y), (stacksOf(p))))
        f:flush()
    end)
    return "tracking " .. name
end

-- What the passive's safety net does when it can't find the stack system (GA_Lancer_P.CheckAmmoSystemIsInit): the
-- grant effect is removed (the ability with it) and applied again, here in the middle of a round.
function T.regrant(name)
    local p = hero(name)
    if not valid(p) then return "regrant: no hero " .. name end
    local asc = p.AbilitySystemComponent
    local grant = loadClass("/Game/Gameplay/Abilities/Player/Lancer/Skill1/BP_GE_GrantLancerAmmoSystem.BP_GE_GrantLancerAmmoSystem_C")
    local passiveCls = loadClass("/Game/Gameplay/Abilities/Player/Lancer/P/GA_Lancer_P.GA_Lancer_P_C")
    local lib = StaticFindObject("/Script/MOBA.Default__MOBAAbilityLibrary")
    local passive = lib:GetAbilityInstanceFromAbilityClass(asc, passiveCls)
    if not valid(passive) then return "regrant: no passive instance" end
    asc:RemoveActiveGameplayEffectBySourceEffect(grant, nil, -1)
    passive["Init Ammo"](passive)
    local st, cd = stacksOf(p)
    log(string.format("        %s: stack system granted again (Bunny Stacks %d, stack cooldowns %d)", name, st, cd))
    return string.format("regrant: %s, Bunny Stacks %d", name, st)
end


-- Every actor of one class (class path), through the world's actor list (tests only).
local function actorsOf(ctx, path)
    local cls = loadClass(path)
    if not valid(cls) then return {} end
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local res, out = {}, {}
    GPS:GetAllActorsOfClass(ctx, cls, res)
    local function add(o)
        if not valid(o) then pcall(function() o = o:get() end) end
        if valid(o) then out[#out + 1] = o end
    end
    local list = res.OutActors
    if list == nil and res[1] ~= nil then list = res end
    if type(list) == "table" then for _, o in pairs(list) do add(o) end
    elseif list ~= nil then pcall(function() list:ForEach(function(_, e) add(e) end) end) end
    return out
end

function T.health(name)
    local p = hero(name)
    if not valid(p) then return "health: no hero " .. name end
    local set = p.AbilitySystemComponent.SpawnedAttributes[1]
    local s = string.format("%s: health %.1f/%.0f", name, set.Health.CurrentValue, set.MaxHealth.CurrentValue)
    log("        " .. s)
    return "health: " .. s
end

-- The ability library's default object (its functions are called on it).
local function abilityLib()
    loadClass("/Game/BluePrints/Library/BP_FL_MOBA_AbilitySystemFunctionLibrary.BP_FL_MOBA_AbilitySystemFunctionLibrary_C")
    return StaticFindObject("/Game/BluePrints/Library/BP_FL_MOBA_AbilitySystemFunctionLibrary.Default__BP_FL_MOBA_AbilitySystemFunctionLibrary_C")
end

-- The hero's health down to about f of its maximum by a real damage hit from hero `by` (a written health value isn't
-- seen by the game's heal code). Armour can make the result a little different: see the logged health.
function T.hurt(name, f, by)
    local p, src = hero(name), hero(by or "")
    if not valid(p) then return "hurt: no hero " .. name end
    if not valid(src) then src = p end
    local set = p.AbilitySystemComponent.SpawnedAttributes[1]
    local dmg = set.Health.CurrentValue - set.MaxHealth.CurrentValue * f
    local lib = abilityLib()
    local ok, err = pcall(function()
        local spec = lib:MakeDamageEffectSpec(src, dmg, false, 0, true, src)
        lib:ApplyEffectSpecToTarget(src, p, spec, src)
    end)
    log(string.format("        %s hit for %.0f by %s: health %.0f%s", name, dmg, by or name, set.Health.CurrentValue, ok and "" or (" (" .. tostring(err) .. ")")))
    return string.format("hurt: %s health %.0f", name, set.Health.CurrentValue)
end

function T.place(name, path, ahead)   -- the hero onto the newest actor of a class (ahead: units along its facing)
    local p = hero(name)
    if not valid(p) then return "place: no hero " .. name end
    local list = actorsOf(p, path)
    local a = list[#list]
    if not valid(a) then return "place: no " .. path:match("([^.]+)$") end
    -- ahead > 0: along the actor's facing; < 0: along the hero's own facing (an Earth Rend arc lies ahead of Rowan)
    local face = (ahead or 0) < 0 and p or a
    local l, yaw, d = a:K2_GetActorLocation(), math.rad(face:K2_GetActorRotation().Yaw), math.abs(ahead or 0)
    p:K2_SetActorLocation({ X = l.X + math.cos(yaw) * d, Y = l.Y + math.sin(yaw) * d, Z = p:K2_GetActorLocation().Z }, false, {}, true)
    log(string.format("        %s placed on %s (%d of them)", name, a:GetClass():GetFName():ToString(), #list))
    return string.format("place: %s on %s", name, a:GetFName():ToString())
end

function T.hptrack(name, seconds, label)   -- health and heal effects every 0.25 s, to hp.log
    local p = hero(name)
    if not valid(p) then return "hptrack: no hero " .. name end
    local f = io.open("hp.log", "a")
    local set = p.AbilitySystemComponent.SpawnedAttributes[1]
    local t0, n, last = now(p), 0, set.Health.CurrentValue
    f:write(string.format("== %s %s from %.2f, health %.1f/%.0f\n", name, label or "", t0, last, set.MaxHealth.CurrentValue))
    LoopInGameThreadWithDelay(250, function()
        n = n + 1
        if n > seconds * 4 then
            if n == seconds * 4 + 1 then f:close() end
            return
        end
        if not valid(p) then return end
        local e = effectsOf(p)
        local hp = set.Health.CurrentValue
        f:write(string.format("%6.2f health %7.1f (%+5.1f)  passive-heal %d overgrowth %d arc-heal %d\n", now(p) - t0, hp, hp - last,
            e.BP_GE_DotHealFourPerSec or 0, e.BP_GE_WoodenSword_Skill4_Creep or 0, e.BP_GE_WoodenSword_HealingOverTime or 0))
        last = hp
        f:flush()
    end)
    return "hptrack " .. name .. " " .. (label or "")
end

function T.caltrops(name)   -- the Dourling Caltrops boxes, measured from the hero along its facing
    local p = hero(name)
    if not valid(p) then return "caltrops: no hero " .. name end
    local list = actorsOf(p, "/Game/Gameplay/Abilities/Player/WoodenSword/Skill1/Items/BP_TA_Woodensword_DourlingCaltrops.BP_TA_Woodensword_DourlingCaltrops_C")
    local l, yaw = p:K2_GetActorLocation(), math.rad(p:K2_GetActorRotation().Yaw)
    local out = {}
    for _, a in ipairs(list) do
        local c = a:K2_GetActorLocation()
        local ahead = (c.X - l.X) * math.cos(yaw) + (c.Y - l.Y) * math.sin(yaw)
        local hidden = "?"
        pcall(function() hidden = tostring(a.Box.bHiddenInGame) end)
        out[#out + 1] = string.format("%+.0f ahead, box hidden %s", ahead, hidden)
    end
    local s = string.format("%s: %d Dourling Caltrops [%s]", name, #list, table.concat(out, "; "))
    log("        " .. s)
    return "caltrops: " .. s
end

function T.stun(name, seconds, by)   -- a stun on the hero from hero `by`, made and applied the way abilities do it
    local p, src = hero(name), hero(by or "")
    if not valid(p) then return "stun: no hero " .. name end
    if not valid(src) then src = p end
    local lib = abilityLib()
    if not valid(lib) then return "stun: no ability library" end
    local ok, err = pcall(function()
        local spec = lib:MakeStunEffectSpec(src, seconds, src)
        lib:ApplyEffectSpecToTarget(src, p, spec, src)
    end)
    log(string.format("        %s stunned for %.2f s%s", name, seconds, ok and "" or (": " .. tostring(err))))
    return ok and string.format("stun: %s %.2f s", name, seconds) or ("stun failed: " .. tostring(err))
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

function T.chain(pattern, n, ms)   -- client: fire(pattern) n times, ms apart, each result to chain.log
    local f, i = io.open("chain.log", "a"), 0
    LoopInGameThreadWithDelay(ms, function()
        i = i + 1
        if i > n then
            if i == n + 1 then f:close() end
            return
        end
        f:write(string.format("%s %d: %s\n", os.date("%H:%M:%S"), i, T.fire(pattern))); f:flush()
    end)
    return string.format("chain: %s x%d, %d ms apart", pattern, n, ms)
end

function T.equip(...)   -- once the augment phase is on: the own hero equips these items by tier, then locks in
    local paths, done = { ... }, false
    local gi = FindFirstOf("BP_MOBAInstance_C")
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local f = io.open("equip.log", "a")
    LoopInGameThreadWithDelay(1000, function()
        if done then return end
        local pc = GPS:GetPlayerController(gi, 0)
        local gs = GPS:GetGameState(gi)
        if not (valid(pc) and valid(pc.Pawn) and valid(gs)) then return end
        local okAt, at = pcall(function() return gs:IsAtItemSelection() end)
        if not (okAt and at) then return end
        done = true
        local hud, ps = pc.WB_HUDGamplayRef, pc.PlayerState
        local pre, taken, out = hud.PreRoundSelection, {}, {}
        for _, path in ipairs(paths) do
            local it = loadClass(path) or StaticFindObject(path)
            local name = path:match("([^.]+)$")
            if not valid(it) then out[#out + 1] = name .. ": not loaded" else
                local tier = it.ItemTier
                local s
                for _, c in ipairs(({ [2] = { 1, 4 }, [0] = { 2, 4 }, [1] = { 3, 4 }, [4] = { 5 }, [5] = { 6 } })[tier] or {}) do
                    if not taken[c] then s = c break end
                end
                if not s then out[#out + 1] = name .. ": no free slot (tier " .. tier .. ")" else
                    taken[s] = true
                    local slot = pre["PlayerItem" .. s]
                    hud.SelectedSlot = slot; hud.CurrentTierFilter = tier
                    pcall(function() hud:RefreshItemStash() end)
                    local ok, err = pcall(function() slot:SetItem(it, true) end)
                    out[#out + 1] = name .. " -> slot " .. s .. (ok and "" or (" failed: " .. tostring(err)))
                end
            end
        end
        pcall(function() ps:ReportetFinishedItemSelectOnServer(false) end)
        pcall(function() pc:PlayerLockedIn() end)
        f:write(os.date("%H:%M:%S") .. " equipped: " .. table.concat(out, "; ") .. "\n"); f:close()
    end)
    return "equip: waiting for the augment phase"
end

function T.key(n)   -- press and release ability key n, as the player controller does for a key
    local gi = FindFirstOf("BP_MOBAInstance_C")
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local p = GPS:GetPlayerController(gi, 0).Pawn
    if not valid(p) then return "key: no pawn" end
    p.BP_AC_InputManager:QueueInput(n, true)
    ExecuteInGameThreadWithDelay(80, function() if valid(p) then p.BP_AC_InputManager:QueueInput(n, false) end end)
    return "key " .. n
end

return "test_patch helpers"
