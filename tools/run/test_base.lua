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
--                  base-blockers.md). Needs the turret: with the patch base-turrets loaded there is none (it says so).
--                  Through Lua, neither a damage spec (MakeDamageEffectSpec + ApplyEffectSpecToTarget: no damage) nor
--                  health 0 plus HandleDeath gave a real death (walls-e3, walls-s2).
--   info()         each blocker: its mesh and scale, its Sphere's radius (where spawn protection is given).
--   fire(name, a)  is ability class a (e.g. "WoodenSword_LMB") on the hero blocked, as an activation attempt now.
-- The base walls and the turrets (docs/recon/base-blockers.md, "Walls" and "No base laser"):
--   edge(name, d)  the hero walks out of its base (swept steps of 30) until it touches no blocker, then d units more:
--                  it stands just outside its base, looking at the wall (for screenshots).
--   turrets()      every BP_Turret_C that is still there (server or client): team, place, hidden, collision, target.
--   walls()        the base walls blockers.lua placed (NiagaraComponents of NS_PheonixWall) and the Feb 2023
--                  "Baseline" systems of the map: where, active, visible.
--   lane(name)     the hero goes into the enemy turret's range (where it stood in Feb 2023), at the nearest spot
--                  clear of both blockers; at(name) onto the enemy turret's own spot. Both note the hero's health.
--   hp(name)       the hero's health now, and what it lost since lane() or at().
--   aim()          client: the mouse pointer towards the local hero's base, so the camera shows its border.
-- Everything is logged to base.log in the game server's Win64 folder too (in the client's on a client).
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
-- Feb 2023's base turrets (BP_Turret_C, two per arena map; the patch base-turrets removes them), by team (1 = A,
-- 2 = B): where each stood and the centre its range (AttackRange 1175, 2D) was measured from (its AttackRangeCapsule).
-- From the Feb maps, so the tests still know the spots once the turrets are gone.
local TURRETS = {
    LE_Arena02_Map = { { root = { -45, -4874, -1 }, range = { -45, -4327 } }, { root = { -45, 4874, -1 }, range = { -45, 4327 } } },
    LE_Arena06_Map = { { root = { -157, -5752, 0 }, range = { -226, -4708 } }, { root = { -157, 5752, 0 }, range = { -88, 4708 } } },
    LE_Payload03_Map = { { root = { -2574, -3759, 84 }, range = { -2214, -3791 } }, { root = { -2363, 3818, 84 }, range = { -2183, 3504 } } },
}
local TURRET_RANGE = 1175
local function mapName() local s = gs(); return s and s:GetFullName():match("Maps/([%w_]+)%.") or "?" end
local function liveTurrets()   -- test only: an object scan, once per call
    local out = {}
    for _, t in ipairs(FindAllOf("BP_Turret_C") or {}) do
        if valid(t) and not t:GetFullName():find("Default__", 1, true) and not t:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then
            out[#out + 1] = t
        end
    end
    return out
end
-- the enemy turret of hero p: the live one if there is one, else its Feb spot; returns range centre, root, live turret
local function enemyTurret(p)
    for _, t in ipairs(liveTurrets()) do
        if t.Team ~= p.PlayerState.Team then
            local c, r = t.AttackRangeCapsule:K2_GetComponentLocation(), t:K2_GetActorLocation()
            return { X = c.X, Y = c.Y }, { X = r.X, Y = r.Y, Z = r.Z }, t
        end
    end
    local m = TURRETS[mapName()]
    local e = m and m[p.PlayerState.Team == 1 and 2 or 1]
    if not e then return nil end
    return { X = e.range[1], Y = e.range[2] }, { X = e.root[1], Y = e.root[2], Z = e.root[3] }, nil
end
-- the nearest spot in the enemy turret's range that is clear of both blockers
local function laneSpot(p)
    local c = enemyTurret(p)
    if not c then return nil end
    local z = p:K2_GetActorLocation().Z + 50
    local spot, best = nil, 1e18
    for f = 0.3, 0.9, 0.05 do                                         -- rings around it, 15 degrees apart
        for k = 0, 23 do
            local a = k * math.pi / 12
            local s = { X = c.X + math.cos(a) * TURRET_RANGE * f, Y = c.Y + math.sin(a) * TURRET_RANGE * f, Z = z }
            local clear = true
            for _, b in ipairs(blockers(p)) do
                local bc = b:K2_GetActorLocation()
                if math.sqrt((s.X - bc.X) ^ 2 + (s.Y - bc.Y) ^ 2) < meshRadius(b) + 150 then clear = false end
            end
            if clear and TURRET_RANGE * f < best then spot, best = s, TURRET_RANGE * f end
        end
    end
    return spot
end
local function health(p)
    local set = p.AbilitySystemComponent.SpawnedAttributes[1]
    return set.Health.CurrentValue, set.MaxHealth.CurrentValue
end
function B.die(name)
    local p = hero(name)
    if not valid(p) then return "die: no hero " .. name end
    local _, _, turret = enemyTurret(p)
    if not valid(turret) then return "die: no enemy turret (patch base-turrets loaded: run the death steps without it)" end
    local spot = laneSpot(p)
    if not spot then return "die: no spot in the turret's range outside both blockers" end
    p:K2_SetActorLocation(spot, false, {}, true)
    log(string.format("%8.2f  %s sent into the enemy turret's range at (%.0f,%.0f), outside both blockers", now(p), name, spot.X, spot.Y))
    return string.format("die: %s at (%.0f,%.0f) | %s", name, spot.X, spot.Y, B.state(name))
end

function B.edge(name, d)
    local p = hero(name)
    if not valid(p) then return "edge: no hero " .. name end
    local _, _, dir = outward(p)
    local l = p:K2_GetActorLocation()
    spawnAt[name] = { X = l.X, Y = l.Y, Z = l.Z }
    local function inside()
        for _, x in ipairs(blockers(p)) do if p:IsOverlappingActor(x) then return true end end
        return false
    end
    local n = 0
    while inside() and n < 120 do
        local cur = p:K2_GetActorLocation()
        p:K2_SetActorLocation({ X = cur.X, Y = cur.Y + dir * 30, Z = cur.Z }, true, {}, false)
        n = n + 1
    end
    for i = 1, math.floor((d or 300) / 30) do
        local cur = p:K2_GetActorLocation()
        p:K2_SetActorLocation({ X = cur.X, Y = cur.Y + dir * 30, Z = cur.Z }, true, {}, false)
    end
    local e = p:K2_GetActorLocation()
    log(string.format("%8.2f  %s at the edge: (%.0f,%.0f) -> (%.0f,%.0f), out of its blocker after %d steps", now(p), name, l.X, l.Y, e.X, e.Y, n))
    return string.format("edge: (%.0f,%.0f) -> (%.0f,%.0f), out after %d steps | %s", l.X, l.Y, e.X, e.Y, n, B.state(name))
end

function B.turrets()
    local out = {}
    for _, t in ipairs(liveTurrets()) do
        local l = t:K2_GetActorLocation()
        local hidden, coll, attacking, target = "?", "?", "?", "none"
        pcall(function() hidden = tostring(t.bHidden) end)
        pcall(function() coll = tostring(t:GetActorEnableCollision()) end)
        pcall(function() attacking = tostring(t.IsAttacking) end)
        pcall(function() if valid(t.Target) then target = t.Target:GetFName():ToString() end end)
        out[#out + 1] = string.format("%s team %d at (%.0f,%.0f,%.0f) hidden=%s collision=%s attacking=%s target=%s",
            t:GetFName():ToString(), t.Team, l.X, l.Y, l.Z, hidden, coll, attacking, target)
    end
    local s = string.format("turrets on %s: %d%s%s", mapName(), #out, #out > 0 and ": " or "", table.concat(out, " | "))
    pcall(log, s)
    return s
end

function B.walls()
    -- NiagaraActors only, and only their properties: calling functions on every NiagaraComponent (component templates
    -- among them) crashed the game (17 Oct, walls-e0: an access violation in all three processes), and so did
    -- GetActorBounds on the NiagaraActors in walls-e2 (on both players)
    local out, base = {}, {}
    for _, a in ipairs(FindAllOf("NiagaraActor") or {}) do   -- test only: an object scan, once per call
        if valid(a) and not a:GetFullName():find("Default__", 1, true) then
            local c, asset = a.NiagaraComponent, "?"
            pcall(function() asset = c.Asset:GetFName():ToString() end)
            if asset:find("PheonixWall", 1, true) or asset:find("Baseline", 1, true) then
                local l, s, r = a:K2_GetActorLocation(), a:GetActorScale3D(), a:K2_GetActorRotation()
                local line = string.format("%s at (%.0f,%.0f,%.0f) yaw %.0f scale (%.2f,%.2f,%.2f) active=%s visible=%s hidden=%s",
                    asset, l.X, l.Y, l.Z, r.Yaw, s.X, s.Y, s.Z, tostring(c.bIsActive), tostring(c.bVisible), tostring(a.bHidden))
                if asset:find("Baseline", 1, true) then base[#base + 1] = line else out[#out + 1] = line end
            end
        end
    end
    local s = string.format("walls on %s: %d: %s; Feb baselines: %d: %s", mapName(), #out, table.concat(out, " | "), #base, table.concat(base, " | "))
    pcall(log, s)
    return s
end

local mark = {}
local function noteHp(name, p, what)
    local h, m = health(p)
    mark[name] = h
    log(string.format("%8.2f  %s %s, health %.0f/%.0f", now(p), name, what, h, m))
    return string.format("%s, health %.0f/%.0f", what, h, m)
end
function B.lane(name)
    local p = hero(name)
    if not valid(p) then return "lane: no hero " .. name end
    local spot = laneSpot(p)
    if not spot then return "lane: no spot" end
    p:K2_SetActorLocation(spot, false, {}, true)
    return "lane: " .. noteHp(name, p, string.format("in the enemy turret's range at (%.0f,%.0f)", spot.X, spot.Y)) .. " | " .. B.state(name)
end
function B.at(name)
    local p = hero(name)
    if not valid(p) then return "at: no hero " .. name end
    local _, root = enemyTurret(p)
    if not root then return "at: no turret spot" end
    local z = p:K2_GetActorLocation().Z + 20   -- the hero's own height (root.Z + 100 can put the capsule into a floor)
    p:K2_SetActorLocation({ X = root.X, Y = root.Y, Z = z }, false, {}, true)
    return "at: " .. noteHp(name, p, string.format("on the enemy turret's spot (%.0f,%.0f)", root.X, root.Y)) .. " | " .. B.state(name)
end
function B.hp(name)
    local p = hero(name)
    if not valid(p) then return "hp: no hero " .. name end
    local h, m = health(p)
    local s = string.format("%s health %.0f/%.0f (%+.0f since lane/at)%s", name, h, m, h - (mark[name] or h), tag(p, "State.Dead") and " DEAD" or "")
    log(string.format("%8.2f  %s", now(p), s))
    return "hp: " .. s
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
-- Client: the camera leads towards the mouse pointer (BP_AC_CameraComponent, up to its max offset); a headless
-- client's pointer sits in a corner. This puts the pointer near the screen's edge in the direction of the local hero's
-- base, so a screenshot shows the base's border next to the hero.
function B.aim()
    local gps = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local gi = FindFirstOf("BP_MOBAInstance_C")
    local pc = gps:GetPlayerController(gi, 0)
    local p = valid(pc) and pc.Pawn
    if not valid(p) then return "aim: no local hero" end
    local l, b = p:K2_GetActorLocation(), nearest(p)
    if not b then   -- the component's list is empty: the blockers themselves (test only: an object scan)
        local bd = 1e18
        for _, x in ipairs(FindAllOf("BP_SpawnBlocker_C") or {}) do
            if valid(x) and not x:GetFullName():find("Default__", 1, true) then
                local c = x:K2_GetActorLocation()
                local d = (c.X - l.X) ^ 2 + (c.Y - l.Y) ^ 2
                if d < bd then b, bd = x, d end
            end
        end
    end
    if not b then return "aim: no blockers here" end
    local c = b:K2_GetActorLocation()
    local s = {}
    pc:ProjectWorldLocationToScreen({ X = c.X, Y = c.Y, Z = l.Z }, s, false)
    local W, H = 1280, 720
    local dx, dy = (s.X or W / 2) - W / 2, (s.Y or H / 2) - H / 2
    local k = math.min((W / 2 - 40) / math.max(math.abs(dx), 1), (H / 2 - 40) / math.max(math.abs(dy), 1))
    local mx, my = math.floor(W / 2 + dx * k), math.floor(H / 2 + dy * k)
    pc:SetMouseLocation(mx, my)
    local r = string.format("aim: hero at (%.0f,%.0f), its base's blocker at (%.0f,%.0f) on screen (%.0f,%.0f): pointer at (%d,%d)",
        l.X, l.Y, c.X, c.Y, s.X or -1, s.Y or -1, mx, my)
    pcall(log, r)
    return r
end

return "test_base helpers"
