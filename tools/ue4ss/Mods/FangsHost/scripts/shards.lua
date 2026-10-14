-- FangsHost: the old Shard system on the arena maps (docs/recon/shards.md), loaded by main.lua.
-- Switched by the backend's game record CEOldShards (make_seed.py OLD_SHARDS):
--   on:  Shards are carried and turned in at a Capture Zone (own zone: your team gets the Shard's buff; enemy zone:
--        you steal theirs), Health Shrines are channeled, as in Aug 2022;
--   off: the Feb 2023 game as shipped (a destructible Prismatic Shard, walk-over health pickups). This file does nothing.
-- How: the arena game mode (BP_GM_MOBA_GameMode_Garden2, all four arena maps) creates its Shard rule state after its
-- BeginPlay from BP_GR_Relic_Garden2.RuleStateClasss. Feb 2023 set that to BP_RS_Relic_Destructible; Aug 2022 and
-- Dec 2023 use BP_RS_Relic (carry), which is still in the build with everything it needs. Maps that lost their Shard
-- (Embersong, Stormheart, Crownwatch) get one; their walk-over health pickups (BP_PickupActor: the Aug Health Shrine
-- actors with a new class) are replaced by Health Shrines (BP_HealingOrb) at the Aug spots. Payload II still has its
-- Shard and Health Shrines. Without its rule state the destructible Shard (BP_BuffActor) never shows; turrets and
-- berserker pickups stay. All of it runs on the game server; players need nothing new.
return function(env)
    local log, every, readRecord = env.log, env.every, env.readRecord
    local RS_RELIC = "/Game/BluePrints/Gameplay/GameRules/Relic/BP_RS_Relic.BP_RS_Relic_C"
    local SHARD = "/Game/BluePrints/MapObjectives/BP_ShrineOrb_BUff.BP_ShrineOrb_BUff_C"
    local HEALTH_SHRINE = "/Game/BluePrints/MapObjectives/HealthOrb/BP_HealingOrb.BP_HealingOrb_C"
    local ARENA_GM = "BP_GM_MOBA_GameMode_Garden2_C"
    -- Health Shrines of the Aug 2022 maps: x, y, z, yaw. Feb 2023 kept the actors (same names, same x/y) as walk-over
    -- pickups; on a map not listed here the shrines go where its pickups are, 44 higher (the Aug/Feb offset).
    local AUG_SHRINES = {
        LE_Arena02_Map = { { 1823, 1695, -2.67, 50 }, { 1823, -1695, -2.67, 50 }, { -2450, -1150, -2.67, 50 }, { -2450, 1150, -2.67, 50 } },
        LE_Arena06_Map = { { -1500, -2500, 100, 180 }, { -1500, 2500, 100, 180 }, { 1600, -1300, 100, 180 }, { 1600, 1300, 100, 180 } },
        LE_Payload03_Map = { { -3000, -1050, 109.31, 180 }, { 2200, 2100, 89.25, 180 }, { 2200, -2100, 89.25, 180 }, { -3000, 1050, 109.31, 180 } },
    }

    local function config()
        local json = readRecord("game/CEOldShards")
        if not json then return { enabled = true, speedup = "off", source = "default" } end
        return { enabled = json:find('"Enabled"%s*:%s*true') ~= nil,
                 speedup = json:match('"AspectSpeedup"%s*:%s*"([%w_]+)"') or "off", source = "CEOldShards" }
    end

    local function valid(o) return o ~= nil and type(o) ~= "number" and o.IsValid ~= nil and o:IsValid() end
    local GS, KSL = nil, nil
    local function loadClass(path)
        local c = StaticFindObject(path)
        if valid(c) then return c end
        KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
        c = StaticFindObject(path)
        return valid(c) and c or nil
    end
    local function xform(x, y, z, yaw, scale)
        local h, s = math.rad(yaw or 0) / 2, scale or 1
        return { Translation = { X = x, Y = y, Z = z }, Rotation = { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) },
                 Scale3D = { X = s, Y = s, Z = s } }
    end
    local function spawn(context, class, xf)
        GS = GS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local a = GS:BeginDeferredActorSpawnFromClass(context, class, xf, 1, nil)   -- 1: always spawn
        if not valid(a) then return nil end
        GS:FinishSpawningActor(a, xf)
        return a
    end
    local function actors(className)   -- placed and spawned actors of exactly this class
        local out = {}
        for _, o in ipairs(FindAllOf(className) or {}) do
            if o:IsValid() and not o:GetFullName():find("Default__", 1, true)
                and o:GetClass():GetFName():ToString() == className then out[#out + 1] = o end
        end
        return out
    end

    -- Shard and Health Shrines for the map, before the game initialises (the Shard registers itself with the game
    -- mode and the rule state then).
    local function setup(gm)
        local map = gm:GetFullName():match("Maps/([%w_]+)%.") or "?"
        local shard = actors("BP_ShrineOrb_BUff_C")[1]
        if not shard then
            local class, west = loadClass(SHARD), actors("BP_WestShrine_C")[1]
            local l = valid(west) and west:K2_GetActorLocation() or { X = 0, Y = 0, Z = 0 }
            shard = class and spawn(gm, class, xform(l.X, l.Y, l.Z, 0, 0.9))
            log("old shards: " .. map .. ": Shard " .. (valid(shard) and "spawned" or "NOT spawned"))
        end
        if valid(shard) then   -- the Capture Zones look the Shard up once, at their BeginPlay
            for _, zone in ipairs(actors("BP_TeamGoalChannel_Buff_C")) do
                if not valid(zone.RelicRef_0) then zone.RelicRef_0 = shard end
            end
        end
        local pickups = actors("BP_PickupActor_C")
        if #pickups > 0 then
            local class, spots = loadClass(HEALTH_SHRINE), AUG_SHRINES[map]
            if not spots then
                spots = {}
                for _, p in ipairs(pickups) do local l = p:K2_GetActorLocation(); spots[#spots + 1] = { l.X, l.Y, l.Z + 44, 0 } end
            end
            local n = 0
            for _, s in ipairs(spots) do
                if class and valid(spawn(gm, class, xform(s[1], s[2], s[3], s[4]))) then n = n + 1 end
            end
            if n > 0 then for _, p in ipairs(pickups) do p:K2_DestroyActor() end end
            log(string.format("old shards: %s: %d Health Shrines instead of %d health pickups", map, n, #pickups))
        end
    end

    -- Aspect speed-up per Shard capture (sub-switch AspectSpeedup): the Aspect's speed already multiplies by
    -- 1.5 ^ (captures of the pushing team) (BP_Payload "Relic Boost"; the game mode resets the count every round), but
    -- Feb 2023 never raises the count. Captures show up as the rule state's team counters going up; the carrier seen
    -- just before is the one who turned the Shard in.
    local function hasMaskOfSpeed(char)
        local found = false
        pcall(function()
            char.PlayerState.HeroEquipment:ForEach(function(_, e)
                local it = e:get()
                if valid(it) and it.ItemTag.TagName:ToString() == "Items.Generic.RocketFuel" then found = true end
            end)
        end)
        return found
    end
    -- Also a safety net the game lacks: a carrier whose hero goes away without dying (a player who leaves) would keep
    -- the Shard "taken" until the round ends; after 2 s the Shard goes back to a shrine, as when a carrier dies.
    local track = nil   -- this match: { gm, mode, rs, phoenix, a, b, carrier, lost }
    every(250, function()
        if not track then return end
        if not valid(track.gm) then track = nil; return end
        if not valid(track.rs) then track.rs = FindFirstOf("BP_RS_Relic_C"); if not valid(track.rs) then return end end
        local rs = track.rs
        if rs.IsOrbTaken and not valid(rs.ShrineOrbCarrier) then
            track.lost = (track.lost or 0) + 1
            if track.lost == 8 then
                rs:ResetOrb(true)
                log("old shards: the carrier is gone - Shard back to a shrine")
            end
        else
            track.lost = nil
        end
        if track.mode == "off" then return end
        if not valid(track.phoenix) then track.phoenix = FindFirstOf("BP_RS_Phoenix_C"); if not valid(track.phoenix) then return end end
        if rs.IsOrbTaken and valid(rs.ShrineOrbCarrier) then track.carrier = rs.ShrineOrbCarrier end
        local a, b = rs.TeamARelics, rs.TeamBRelics
        for team, now in pairs({ [1] = a, [2] = b }) do
            local before = team == 1 and track.a or track.b
            if now > before then
                local carrier = track.carrier
                if track.mode == "every_capture" or (valid(carrier) and hasMaskOfSpeed(carrier)) then
                    local ph = track.phoenix
                    if team == 1 then ph.RelicsCapturedByTeamA = ph.RelicsCapturedByTeamA + 1
                    else ph.RelicsCapturedByTeamB = ph.RelicsCapturedByTeamB + 1 end
                    log(string.format("old shards: Aspect speed-up for team %d (A %d, B %d)", team,
                        ph.RelicsCapturedByTeamA, ph.RelicsCapturedByTeamB))
                end
            end
        end
        track.a, track.b = a, b   -- a new round resets them
        if not rs.IsOrbTaken then track.carrier = nil end
    end)

    RegisterBeginPlayPreHook(function(ctx)
        local gm = ctx:get()
        if not (gm and gm:IsValid()) or gm:GetClass():GetFName():ToString() ~= ARENA_GM then return end
        local cfg = config()
        if not cfg.enabled then return log("old shards: off (" .. cfg.source .. "): Feb 2023 Shards") end
        local rs = StaticFindObject(RS_RELIC)
        if not valid(rs) then return log("old shards: BP_RS_Relic not loaded - Feb 2023 Shards stay") end
        gm.BP_GR_Relic_Garden2.RuleStateClasss = rs   -- property only: no game functions inside a hook
        log("old shards: on (" .. cfg.source .. ", Aspect speed-up " .. cfg.speedup .. ")")
        track = { gm = gm, mode = cfg.speedup, a = 0, b = 0 }
        ExecuteInGameThreadWithDelay(200, function()
            local ok, err = pcall(setup, gm)
            if not ok then log("old shards: setup error: " .. tostring(err)) end
        end)
    end)
end
