-- Base blocker test helpers (docs/recon/base-blockers.md), loaded on the game server by tools/run/test_base.steps:
--   state(name)    the hero against its nearest blocker: inside or out (and how far from its centre, with the blocker's
--                  radius), spawn protection (Effect.SpawnBlocker, Systems.Input.LockAbilities, BP_GE_Immunity_All),
--                  its capsule's answer to the blockers' channel (25: 1 overlap = can walk in, 2 block), dead or alive.
--   protect(name)  the component's own ApplyImmunity() on that hero now, wherever it stands (Feb's version asks the
--                  first player's hero; the patch asks the hero itself).
--   walkout(name)  the hero walks out of its base towards the middle of the map: 40 swept steps of 60 units, so the
--                  game sees it leave the blocker as it does when a player walks.
--   tpout(name)    the hero is teleported out of its base (no sweep), as a respawn or a script would.
--   back(name)     the hero walks back towards its base's centre (swept): where it stops, and what stopped it.
--   free(name)     back() with the blockers' channel ignored for that walk (then the hero and its collision are put
--                  back): if the hero gets in this way, the blocker stopped it, not the base's walls or floor.
--   die(name)      a real death out in the lane: the enemy turret shoots the hero at the nearest spot in its range
--                  that is clear of both bases' blockers (a death inside the enemy blocker can't happen in play: see
--                  base-blockers.md).
--   info()         each blocker: its mesh and scale, its Sphere's radius (where spawn protection is given).
--   fire(name, a)  is ability class a (e.g. "WoodenSword_LMB") on the hero blocked, as an activation attempt now.
-- Everything is logged to base.log in the game server's Win64 folder too.
local B = {}
FCE_BASE = B

local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local function log(s) local f = io.open("base.log", "a"); f:write(os.date("%H:%M:%S ") .. s .. "\n"); f:close() end
local function now(o) local ok, t = pcall(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(o) end); return ok and t or 0 end

local function gs() local gi = FindFirstOf("BP_MOBAInstance_C"); return gi and gi:GetWorld().GameState end
local function hero(name)
    local s = gs()
    local found
    pcall(function()
        s.PlayerArray:ForEach(function(_, e)
            local ps = e:get()
            if valid(ps) and ps:GetPlayerName():ToString() == name and valid(ps.PawnPrivate) then found = ps.PawnPrivate end
        end)
    end)
    return found
end
local function blockers(p)
    local out = {}
    pcall(function() p.BP_AC_SpawnBlocker.SpawnBlockers:ForEach(function(_, e) local b = e:get(); if valid(b) then out[#out + 1] = b end end) end)
    return out
end
local function nearest(p)
    local l, best, bd = p:K2_GetActorLocation(), nil, 1e18
    for _, b in ipairs(blockers(p)) do
        local c = b:K2_GetActorLocation()
        local d = (c.X - l.X) ^ 2 + (c.Y - l.Y) ^ 2
        if d < bd then best, bd = b, d end
    end
    return best, math.sqrt(bd)
end
local function radius(b)   -- half the blocker's footprint (its components' bounds)
    local o, e = {}, {}
    pcall(function() b:GetActorBounds(true, o, e, false) end)
    local x, y = (e.X or 0), (e.Y or 0)
    return math.max(x, y)
end
local function tag(p, t)
    local ok, r = pcall(function() return p.AbilitySystemComponent:HasMatchingGameplayTag({ TagName = FName(t) }) end)
    return ok and r
end
local IMM = "/Game/Gameplay/Effects/Shared/BP_GE_Immunity_All.BP_GE_Immunity_All_C"
local function immune(p)
    local cls = StaticFindObject(IMM)
    if not valid(cls) then return -1 end
    local ok, n = pcall(function() return p.AbilitySystemComponent:GetGameplayEffectCount(cls, nil, true) end)
    return ok and n or -1
end

function B.state(name)
    local p = hero(name)
    if not valid(p) then return "state: no hero " .. name end
    local b, d = nearest(p)
    local inside = false
    for _, x in ipairs(blockers(p)) do if p:IsOverlappingActor(x) then inside = true end end
    local ch = -1
    pcall(function() ch = p.CapsuleComponent:GetCollisionResponseToChannel(25) end)
    local l = p:K2_GetActorLocation()
    local sphere = false
    pcall(function() sphere = b.Sphere:IsOverlappingActor(p) end)
    local s = string.format("%s at (%.0f,%.0f,%.0f): %s%s, %.0f from the nearest blocker's centre (radius %.0f); protection=%s lock=%s immune=%d; channel25=%d%s",
        name, l.X, l.Y, l.Z, inside and "INSIDE a blocker" or "outside", sphere and " (in its Sphere)" or "", d or -1, b and radius(b) or -1,
        tostring(tag(p, "Effect.SpawnBlocker")), tostring(tag(p, "Systems.Input.LockAbilities")), immune(p), ch,
        tag(p, "State.Dead") and " DEAD" or "")
    log(string.format("%8.2f  %s", now(p), s))
    return s
end

function B.protect(name)
    local p = hero(name)
    if not valid(p) then return "protect: no hero " .. name end
    local ok, err = pcall(function() p.BP_AC_SpawnBlocker:ApplyImmunity() end)
    log(string.format("%8.2f  %s: ApplyImmunity() %s", now(p), name, ok and "called" or tostring(err)))
    return "protect: " .. (ok and "called" or tostring(err)) .. " | " .. B.state(name)
end

local spawnAt = {}
local function outward(p)
    local b = nearest(p)
    local c = b:K2_GetActorLocation()
    return b, c, (c.Y > 0 and -1 or 1)   -- towards the middle of the map (y = 0)
end
function B.walkout(name)
    local p = hero(name)
    if not valid(p) then return "walkout: no hero " .. name end
    local b, c, dir = outward(p)
    local l = p:K2_GetActorLocation()
    spawnAt[name] = { X = l.X, Y = l.Y, Z = l.Z }
    for i = 1, 40 do
        local cur = p:K2_GetActorLocation()
        p:K2_SetActorLocation({ X = cur.X, Y = cur.Y + dir * 60, Z = cur.Z }, true, {}, false)
    end
    local e = p:K2_GetActorLocation()
    log(string.format("%8.2f  %s walked out: (%.0f,%.0f) -> (%.0f,%.0f)", now(p), name, l.X, l.Y, e.X, e.Y))
    return string.format("walkout: (%.0f,%.0f) -> (%.0f,%.0f) | %s", l.X, l.Y, e.X, e.Y, B.state(name))
end
function B.tpout(name)
    local p = hero(name)
    if not valid(p) then return "tpout: no hero " .. name end
    local b, c, dir = outward(p)
    local l = p:K2_GetActorLocation()
    spawnAt[name] = spawnAt[name] or { X = l.X, Y = l.Y, Z = l.Z }
    local dest = { X = c.X, Y = c.Y + dir * (radius(b) + 600), Z = l.Z }
    p:K2_SetActorLocation(dest, false, {}, true)
    log(string.format("%8.2f  %s teleported out: (%.0f,%.0f) -> (%.0f,%.0f)", now(p), name, l.X, l.Y, dest.X, dest.Y))
    return string.format("tpout: -> (%.0f,%.0f) | %s", dest.X, dest.Y, B.state(name))
end
function B.back(name)
    local p = hero(name)
    if not valid(p) then return "back: no hero " .. name end
    local b = nearest(p)
    local c = b:K2_GetActorLocation()
    local target = spawnAt[name] or c
    local from = p:K2_GetActorLocation()
    for i = 1, 60 do   -- swept steps of 50 units towards the spawn
        local cur = p:K2_GetActorLocation()
        local dx, dy = target.X - cur.X, target.Y - cur.Y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 50 then break end
        p:K2_SetActorLocation({ X = cur.X + dx / len * 50, Y = cur.Y + dy / len * 50, Z = cur.Z }, true, {}, false)
    end
    local e = p:K2_GetActorLocation()
    local left = math.sqrt((e.X - target.X) ^ 2 + (e.Y - target.Y) ^ 2)
    local dc = math.sqrt((e.X - c.X) ^ 2 + (e.Y - c.Y) ^ 2)
    local s = string.format("back: from (%.0f,%.0f) to (%.0f,%.0f): %.0f short of the spawn, %.0f from the blocker's centre (radius %.0f): %s",
        from.X, from.Y, e.X, e.Y, left, dc, radius(b), left < 100 and "GOT BACK IN" or "stopped")
    log(string.format("%8.2f  %s %s", now(p), name, s))
    return s
end
function B.free(name)
    local p = hero(name)
    if not valid(p) then return "free: no hero " .. name end
    local cap = p.CapsuleComponent
    local ch = cap:GetCollisionResponseToChannel(25)
    local from = p:K2_GetActorLocation()
    cap:SetCollisionResponseToChannel(25, 0)   -- ignore: no overlap events either
    local s = B.back(name)
    p:K2_SetActorLocation(from, false, {}, true)
    cap:SetCollisionResponseToChannel(25, ch)
    log(string.format("%8.2f  %s put back at (%.0f,%.0f), channel25 %d again", now(p), name, from.X, from.Y, ch))
    return "free (blockers ignored): " .. s
end

local function meshRadius(b)   -- the blocker's collision, widest across (SM_Sphere: radius 100; the class's sphere: 50)
    local r = -1
    pcall(function()
        local m = b.StaticMeshComponent
        local s = m:K2_GetComponentScale()
        local base = m.StaticMesh:GetFName():ToString() == "SM_Sphere" and 100 or 50
        r = math.max(s.X, s.Y) * base
    end)
    return r
end
function B.die(name)
    local p = hero(name)
    if not valid(p) then return "die: no hero " .. name end
    local turret
    for _, t in ipairs(FindAllOf("BP_Turret_C") or {}) do   -- test only: an object scan, once per call
        if valid(t) and t.Team ~= p.PlayerState.Team then turret = t end
    end
    if not valid(turret) then return "die: no enemy turret" end
    local c = turret.AttackRangeCapsule:K2_GetComponentLocation()   -- the turret measures its range from here (2D)
    local range, z = turret.AttackRange, p:K2_GetActorLocation().Z + 50
    local spot, best = nil, 1e18
    for f = 0.3, 0.9, 0.05 do                                         -- rings around it, 15 degrees apart
        for k = 0, 23 do
            local a = k * math.pi / 12
            local s = { X = c.X + math.cos(a) * range * f, Y = c.Y + math.sin(a) * range * f, Z = z }
            local clear = true
            for _, b in ipairs(blockers(p)) do
                local bc = b:K2_GetActorLocation()
                if math.sqrt((s.X - bc.X) ^ 2 + (s.Y - bc.Y) ^ 2) < meshRadius(b) + 150 then clear = false end
            end
            if clear and range * f < best then spot, best = s, range * f end
        end
    end
    if not spot then return "die: no spot in the turret's range outside both blockers" end
    p:K2_SetActorLocation(spot, false, {}, true)
    log(string.format("%8.2f  %s sent into the enemy turret's range at (%.0f,%.0f), outside both blockers", now(p), name, spot.X, spot.Y))
    return string.format("die: %s at (%.0f,%.0f) | %s", name, spot.X, spot.Y, B.state(name))
end

function B.info()
    local p = hero("alice") or hero("bob")
    if not valid(p) then return "info: no hero" end
    local out = {}
    for i, b in ipairs(blockers(p)) do
        local c = b:K2_GetActorLocation()
        local mn, s, r = "?", { X = 0, Y = 0, Z = 0 }, -1
        pcall(function() mn = b.StaticMeshComponent.StaticMesh:GetFName():ToString() end)
        pcall(function() s = b.StaticMeshComponent:K2_GetComponentScale() end)
        pcall(function() r = b.Sphere:GetScaledSphereRadius() end)
        out[#out + 1] = string.format("blocker %d at (%.0f,%.0f,%.0f): mesh %s, scale (%.2f,%.2f,%.2f), collision up to %.0f across, Sphere radius %.0f",
            i, c.X, c.Y, c.Z, mn, s.X, s.Y, s.Z, meshRadius(b), r)
    end
    local cr = -1
    pcall(function() cr = p.CapsuleComponent:GetScaledCapsuleRadius() end)
    out[#out + 1] = string.format("hero capsule radius %.0f", cr)
    local str = table.concat(out, " | ")
    log(string.format("%8.2f  info: %s", now(p), str))
    return "info: " .. str
end

function B.fire(name, ability)
    local p = hero(name)
    if not valid(p) then return "fire: no hero " .. name end
    local asc, spec = p.AbilitySystemComponent, nil
    local ok, r = pcall(function()
        local cls
        asc.ActivatableAbilities.Items:ForEach(function(_, e)
            local s = e:get()
            local a = s.Ability
            if valid(a) and a:GetClass():GetFName():ToString():find(ability, 1, true) then cls = a:GetClass() end
        end)
        if not cls then return "not granted" end
        return asc:TryActivateAbilityByClass(cls, true) and "activated" or "refused"
    end)
    local s = string.format("%s %s: %s", name, ability, ok and tostring(r) or tostring(r))
    log(string.format("%8.2f  fire %s", now(p), s))
    return "fire: " .. s
end
return "test_base helpers"
