-- Helpers for tools/run/test_shards.sh, loaded by FangsCtl (dofile) into the test client and the game server.
-- Server side: watch() logs every change of the Shard / Health Shrine / hero state to shardwatch.log; tp(), vanish(),
-- endRound() move the game along. Client side: equip(), channel() (the F key's own handler), texts().
FCE_SHARDS = FCE_SHARDS or {}
local T = FCE_SHARDS

local function valid(o) return o ~= nil and type(o) ~= "number" and type(o) ~= "string" and o.IsValid ~= nil and o:IsValid() end
local function name(o) return valid(o) and o:GetClass():GetFName():ToString() or "nil" end
local function all(className, exact)
    local out = {}
    for _, o in ipairs(FindAllOf(className) or {}) do
        if o:IsValid() and not o:GetFullName():find("Default__", 1, true)
            and (not exact or o:GetClass():GetFName():ToString() == className) then out[#out + 1] = o end
    end
    return out
end
local function first(className, exact) return all(className, exact)[1] end
local function at(a) local l = a:K2_GetActorLocation(); return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
local function statics() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local logf = nil
local function log(file, msg)
    logf = logf or {}
    logf[file] = logf[file] or io.open(file, "a")
    logf[file]:write(os.date("!%H:%M:%S ") .. msg .. "\n"); logf[file]:flush()
end

local function effects(char)
    local ge = {}
    pcall(function()
        char.AbilitySystemComponent.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, e)
            local d = e:get().Spec.Def
            if valid(d) then ge[#ge + 1] = d:GetClass():GetFName():ToString():gsub("_C$", "") end
        end)
    end)
    table.sort(ge)
    return ge
end
local function attrs(char)
    local ok, s = pcall(function()
        local set = char.AbilitySystemComponent.SpawnedAttributes[1]
        return string.format("hp %d/%d mana %d/%d speed %d", math.floor(set.Health.CurrentValue / 10) * 10,
            math.floor(set.MaxHealth.CurrentValue), math.floor(set.Mana.CurrentValue / 10) * 10,
            math.floor(set.MaxMana.CurrentValue), math.floor(set.MoveSpeed.CurrentValue))
    end)
    return ok and s or "attrs ?"
end
local function hero() return first("BP_PlayerChar_C") end

-- ---------------------------------------------------------------------------------------------- server
-- Objects are looked up (object scans: 10+ ms each in an arena, a hitch for everyone) only when the cache misses
-- one, at most every 5 s; the watch loop itself only reads properties. Rule states come from the game mode.
local C = { t = -100 }
local function refresh(force)
    if not force and os.clock() - C.t < 5 then return end
    C.t = os.clock()
    C.gm = first("BP_GM_MOBA_GameMode_C")
    C.gs = first("GS_MOBA_Battle_C")
    C.hero = hero()
    C.shrines = all("BP_HealingOrb_C", true)
    C.pickups = #all("BP_PickupActor_C", true)
    C.prismatic = first("BP_BuffActor_C", true)
    C.turrets = all("BP_Turret_C", true)
    C.zones = all("BP_TeamGoalChannel_Buff_C", true)
    C.ga = {}
    for _, c in ipairs({ "BP_GA_RelicRunner_C", "BP_GA_BubbleBobble_C" }) do C.ga[c] = all(c, true) end
end
local function cached()
    if not (valid(C.gm) and valid(C.gs) and valid(C.hero)) then refresh(false) end
    return C
end
local function rules()
    local rs, ph
    pcall(function() rs = C.gm.BP_GR_Relic_Garden2.RuleStateComp end)
    pcall(function() ph = C.gm.BP_GR_Phoenix.RuleStateComp end)
    return valid(rs) and rs or nil, valid(ph) and ph or nil
end

function T.state()
    local c, out = cached(), {}
    local p = c.hero
    if valid(c.gs) then out[#out + 1] = string.format("rounds %d-%d", c.gs.TeamARoundsWon, c.gs.TeamBRoundsWon) end
    local rs, ph = rules()
    local kind = valid(rs) and rs:GetClass():GetFName():ToString() or ""
    local carry = kind == "BP_RS_Relic_C"
    out[#out + 1] = "rule " .. (carry and "carry" or kind:find("Destructible") and "destructible" or "none")
    if carry then
        out[#out + 1] = string.format("A %d B %d taken %s atShrine %s dropped %s carrier %s", rs.TeamARelics, rs.TeamBRelics,
            tostring(rs.IsOrbTaken), tostring(rs.OrbPlacedAtShrine), tostring(rs.OrbHasBeenDropped), name(rs.ShrineOrbCarrier))
        local o = rs.BP_ShrineOrbRef
        if valid(o) then
            out[#out + 1] = string.format("shard %s %s buff %s channeled %s", o.Location:ToString(), at(o), tostring(o.RandomBuff), tostring(o.bBeingChanneled))
        end
    end
    if #(c.shrines or {}) > 0 then
        local ch = {}
        for _, h in ipairs(c.shrines) do if valid(h) and h.bBeingChanneled then ch[#ch + 1] = at(h) end end
        out[#out + 1] = string.format("health shrines %d (channeled: %s)", #c.shrines, table.concat(ch, " "))
    end
    out[#out + 1] = "pickups " .. tostring(c.pickups)
    if valid(c.prismatic) then out[#out + 1] = string.format("prismatic dead %s at %s", tostring(c.prismatic.Dead), at(c.prismatic)) end
    if valid(ph) then out[#out + 1] = string.format("aspect boost A %d B %d", ph.RelicsCapturedByTeamA, ph.RelicsCapturedByTeamB) end
    if valid(p) then
        local ga = {}   -- item abilities that react to carrying: instances and whether they are active
        for cls, list in pairs(c.ga or {}) do
            local n, act = 0, 0
            for _, a in ipairs(list) do if valid(a) then n = n + 1; local ok, v = pcall(function() return a:IsActive() end); if ok and v then act = act + 1 end end end
            if n > 0 then ga[#ga + 1] = string.format("%s %d/%d", cls:sub(7, -3), act, n) end
        end
        table.sort(ga)
        local holding = false
        pcall(function() holding = p.AbilitySystemComponent:HasMatchingGameplayTag({ TagName = FName("HoldingOrb") }) end)
        out[#out + 1] = string.format("items active [%s] holding %s", table.concat(ga, ", "), tostring(holding))
        out[#out + 1] = string.format("hero %s %s %s GEs [%s]", name(p), at(p), attrs(p), table.concat(effects(p), ","))
    end
    return table.concat(out, "; ")
end

function T.watch(file)   -- log every change, every 400 ms, until the server ends
    if T.watching then return "already watching" end
    T.watching, T.t0 = true, os.clock()
    refresh(true)
    local last = ""
    LoopInGameThreadWithDelay(400, function()
        local ok, s = pcall(T.state)
        if not ok then s = "error " .. tostring(s) end
        -- position and hp change constantly; log them only with another change
        local key = s:gsub("hero (%S+) [-%d.,]+ hp %d+", "hero %1"):gsub(" %-?%d+,%-?%d+,%-?%d+", "")
        if key ~= last then last = key; log(file or "shardwatch.log", string.format("%7.1f %s", os.clock() - T.t0, s)) end
    end)
    return "watching"
end

local function enemyTurret(p)   -- the turrets have a team
    for _, t in ipairs(C.turrets or {}) do if valid(t) and t.Team ~= p.PlayerState.Team then return t end end
end

function T.tp(what)   -- move the hero next to: shard | own | enemy (Capture Zone) | shrine | prismatic | turret
    local c = cached()
    local p = c.hero
    if not valid(p) then return "no hero" end
    local target
    if what == "shard" then local rs = rules(); target = rs and rs.BP_ShrineOrbRef
    elseif what == "shrine" then target = (c.shrines or {})[1]
    elseif what == "prismatic" then target = c.prismatic
    elseif what == "turret" then target = enemyTurret(p)   -- it shoots the hero (150 damage/s and more): a real death
    else
        for _, z in ipairs(c.zones or {}) do
            if valid(z) and (what == "own") == (z.Team == p.PlayerState.Team) then target = z end
        end
    end
    if not valid(target) then return "tp: no " .. what end
    local l = target:K2_GetActorLocation()
    local dy = what == "turret" and (l.Y > 0 and -500 or 500) or 0   -- in front of the turret, towards the middle
    p:K2_SetActorLocation({ X = l.X + (dy == 0 and 120 or 0), Y = l.Y + dy, Z = l.Z + 100 }, false, {}, true)
    return "tp " .. what .. " " .. at(target)
end

function T.hitPrismatic()   -- the Feb 2023 destructible Shard: what its damage handler does on a killing blow by the hero
    local c = cached()
    if not valid(c.prismatic) then return "no prismatic shard" end
    c.prismatic:Damaged(c.hero, true)
    return "prismatic shard hit: dead " .. tostring(c.prismatic.Dead)
end

function T.vanish()   -- the hero goes away without dying (as when a player leaves)
    local p = cached().hero
    if not valid(p) then return "no hero" end
    p:K2_DestroyActor()
    return "hero removed"
end

function T.endRound(team)
    local gs = cached().gs
    gs:FlushNetDormancy(); gs.WinningTeam = team
    gs:DoRoundEndCelebration(0, team, { X = 0, Y = 0, Z = 0 })
    return "round ended, winner " .. team
end

function T.equipment()
    local p, eq, ab = cached().hero, {}, {}
    local ps = valid(p) and p.PlayerState
    if valid(ps) then ps.HeroEquipment:ForEach(function(i, e) local it = e:get(); if valid(it) then eq[#eq + 1] = i .. "=" .. it:GetFName():ToString() end end) end
    if valid(p) then
        p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e)
            local a = e:get().Ability
            if valid(a) and a:GetFullName():find("/Items/", 1, true) then ab[#ab + 1] = a:GetClass():GetFName():ToString() end
        end)
    end
    return "equipped [" .. table.concat(eq, ", ") .. "] item abilities [" .. table.concat(ab, ", ") .. "]"
end

-- ---------------------------------------------------------------------------------------------- client
local function me()
    local gi = FindFirstOf("BP_MOBAInstance_C")
    local pc = statics():GetPlayerController(gi, 0)
    return pc, pc.Pawn, pc.PlayerState
end

function T.channel()   -- what pressing F does (BP_PC_MOBA_PlayerController's Channel input action)
    local pc = me()
    pc:InpActEvt_Channel_K2Node_InputActionEvent_30({ KeyName = FName("F") })
    return "pressed F"
end

function T.equip(paths)   -- artifacts into slots 1, 4, 7, 8 (the Captain's extra flex slots), then lock in
    local pc, pawn, ps = me()
    local hud = pc.WB_HUDGamplayRef
    local pre, out, free = hud.PreRoundSelection, {}, { 1, 4, 7, 8 }
    for _, path in ipairs(paths) do
        local it, s = StaticFindObject(path), table.remove(free, 1)
        local short = path:match("([^.]+)$")
        if not valid(it) then out[#out + 1] = short .. ": not loaded"
        elseif not s then out[#out + 1] = short .. ": no slot"
        else
            local slot = pre["PlayerItem" .. s]
            hud.SelectedSlot = slot; hud.CurrentTierFilter = it.ItemTier
            pcall(function() hud:RefreshItemStash() end)
            local ok, err = pcall(function() slot:SetItem(it, true) end)
            out[#out + 1] = short .. " -> slot " .. s .. (ok and "" or (" failed: " .. tostring(err)))
        end
    end
    ps:ReportetFinishedItemSelectOnServer(false); pc:PlayerLockedIn()
    return "equip: " .. table.concat(out, "; ")
end

function T.pool(paths)   -- which of these items the hero's in-match pool offers (FangsBoot adds restored ones)
    local _, pawn = me()
    local have, n = {}, 0
    pawn.GenericItems:ForEach(function(_, e) local it = e:get(); if valid(it) then have[it:GetFullName():match(" (.*)$")] = true end end)
    local out = {}
    for _, path in ipairs(paths) do if have[path] then n = n + 1 else out[#out + 1] = path:match("([^.]+)$") end end
    return string.format("pool: %d of %d offered; not offered: [%s]", n, #paths, table.concat(out, ", "))
end

function T.texts(file)   -- name and description of every restored item, as the client has them
    local f, n, bad = io.open("fangsboot_restored.txt", "r"), 0, {}
    if not f then return "texts: no fangsboot_restored.txt" end
    for line in f:lines() do
        local path = line:match("\t([^\t]+)$")
        local it = path and StaticFindObject(path)
        if valid(it) then
            n = n + 1
            local nm, ds = it.ItemName:ToString(), it.ItemDescription:ToString()
            log(file or "shardtexts.log", string.format("%-34s | %-28s | %s", path:match("([^.]+)$"), nm, ds:sub(1, 90)))
            if nm == "" or ds == "" or nm:find("MISSING") or ds:find("MISSING") then bad[#bad + 1] = path:match("([^.]+)$") end
        elseif path then
            log(file or "shardtexts.log", path .. " | not loaded")
        end
    end
    f:close()
    return string.format("texts: %d items, empty/missing: [%s]", n, table.concat(bad, ", "))
end

return "test_shards helpers loaded"
