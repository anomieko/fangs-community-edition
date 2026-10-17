-- Base blockers (the community's "Mickey Mouse fountain", docs/recon/community-build-modes.md): once a hero has left
-- their base they can't walk back in until they die or the round ends, as in Aug 2022.
-- The game still has all of it: every hero's BP_AC_SpawnBlocker component makes the hero's capsule block the blocker's
-- object channel (GameTraceChannel12) when the hero stops overlapping a BP_SpawnBlocker, and unblocks it on death,
-- revive and round end. Feb 2023 only removed the BP_SpawnBlocker actors from the maps. This puts them back at their Aug
-- 2022 places (world transforms from the Aug maps, attach parents resolved), on the game server (FangsHost) and on
-- every player (FangsBoot): the actor doesn't replicate, and a hero's movement is predicted on its player's machine, so
-- both must have the same collision. The same file is in both mods (tools/run/test_modes.sh checks they are equal).
-- On since the fix of 17 Oct (docs/recon/base-blockers.md): spawn protection (BP_AC_SpawnBlocker.ApplyImmunity: immune,
-- no abilities) went to every hero whenever the first player's hero stood in a base (Feb's HasRespawnedInsideBase asks
-- GetPlayerPawn(0)); the patch base-blockers asks the hero itself again, as Aug did, and FangsHost's modes.lua takes
-- the protection off any hero who still has it outside every blocker. Stormheart's and Crownwatch's blockers now get
-- their Aug mesh's collision and protection sphere too (below). Off switch: false here (both mods).
local ENABLED = true
-- How Aug 2022 showed the bases (docs/recon/base-blockers.md, "Walls"), on players' machines only (nothing renders on
-- the game server). ENABLED = false takes these off too.
--   WALLS: a fire wall across each base's exit (NS_PheonixWall, a Niagara system the Aug maps placed at the blocker's
--          edge; Feb 2023 took it out with the blockers). Off switch: false here (both mods).
--   SPHERES: the blocker itself, with SM_Sphere's own material (M_SphereHit: only a thin white rim of the sphere
--          shows, a ring that outlines the base's border). In Aug, Stormheart's and Crownwatch's blockers showed this
--          way (their mesh is SM_Sphere; the class's material is an invisible one); Embersong's was hidden and a phoenix
--          gate marked its bases, an effect Feb no longer has, so Embersong's blockers show the ring too. Off switch:
--          false here (both mods).
local WALLS = true
local SPHERES = true

return function(log)
    local CLASS = "/Game/BluePrints/BP_SpawnBlocker.BP_SpawnBlocker_C"
    local CDO = "/Game/BluePrints/BP_SpawnBlocker.Default__BP_SpawnBlocker_C"
    local SPHERE_100 = "/Game/VFX_Packs/Stylized_VFX_StPack/Meshes/SM_Sphere.SM_Sphere"   -- radius 100 (the class's own
    -- mesh, /Engine/BasicShapes/Sphere, has radius 50)
    -- map -> { x, y, z, yaw, scale x, y, z, mesh (nil: the class's), Sphere's relative scale (nil: the class's) } (Aug
    -- 2022 maps; every Feb 2023 player start of each base is inside its blocker and its Sphere). The Sphere component
    -- (overlap only) is where Feb's HasRespawnedInsideBase gives spawn protection: radius 32 x its smallest world scale.
    local BLOCKERS = {
        LE_Arena02_Map = {     -- Embersong
            { 0.0, 4220.0, 214.67, 0.0, 16.8125, 16.8125, 16.21875 },
            { 0.0, -4220.46, 68.66, -43.48, 16.8125, 16.8125, 16.21875 },
        },
        LE_Arena06_Map = {     -- Stormheart (Aug: attached to the bases' floor planes)
            { -85.0, 4637.5, 94.0, -180.0, 6.0156, 7.26, 4.9375, SPHERE_100, { 5.4375, 5.4375, 3.625 } },
            { -72.23, -4718.48, 96.0, -179.37, 6.0156, 7.2656, 4.9375, SPHERE_100, { 5.375, 5.375, 3.5625 } },
        },
        LE_Payload03_Map = {   -- Crownwatch (Aug: attached to the base meshes)
            { -1963.9, 3490.8, 115.8, -108.67, 8.478, 8.277, 5.955, SPHERE_100, { 5.4375, 5.4375, 3.625 } },
            { -2039.7, -3588.2, 145.7, 137.2, 8.99, 7.838, 4.976, SPHERE_100, { 5.375, 5.375, 3.5625 } },
        },
    }

    -- The walls: map -> { x, y, z, yaw, scale x, y, z } of each base's wall. NS_PheonixWall's mesh (M_MagicFire_v3) is
    -- a half ring of fire, radius ~456, 280 high, its centre 376 behind the system's origin. Stormheart and Crownwatch:
    -- the Aug 2022 world transforms (attached to the base floors there, resolved; Aug scaled Stormheart's ring to its
    -- blocker's width). Aug used this system on Crownwatch, and its GardenMap copy (gone in Feb) on Stormheart. Embersong
    -- had a phoenix gate (NS_PhoenixGate, gone in Feb with its meshes and materials): its ring here is centred on the
    -- blocker and scaled to its radius (840 / 456), so it runs along the border.
    local WALL = "/Game/HiddenLeafVFX/ObjectVFX/Base/NS_PheonixWall.NS_PheonixWall"
    local SPHERE_MAT = "/Game/VFX_Packs/Stylized_VFX_StPack/Materials/M_SphereHit.M_SphereHit"   -- SM_Sphere's own material
    local WALL_AT = {
        LE_Arena02_Map = {     -- Embersong (Aug: NS_PhoenixGate at (-101, 3475, 0) and (2, -3491, -17))
            { 0.0, 3527.4, 0.0, 180.0, 1.842, 1.842, 1.0 },
            { 0.0, -3527.9, -17.0, 0.0, 1.842, 1.842, 1.0 },
        },
        LE_Arena06_Map = {     -- Stormheart
            { -151.2, 4063.7, 67.0, 180.0, 1.3125, 1.0, 1.0 },
            { -151.0, -4139.0, 67.0, 0.0, 1.3125, 1.0, 1.0 },
        },
        LE_Payload03_Map = {   -- Crownwatch
            { -1397.3, 3119.2, 66.0, -123.99, 1.0, 1.0, 1.0 },
            { -1668.6, -3120.4, 87.8, -42.66, 1.4375, 1.0, 1.0 },
        },
    }

    local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
    local KSL, GPS = nil, nil
    local function load(path)
        local o = StaticFindObject(path)
        if valid(o) then return o end
        KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
        o = StaticFindObject(path)
        return valid(o) and o or nil
    end

    -- This map's looks, on a player's machine: the blockers get SM_Sphere's own material (the ring); each wall
    -- is a NiagaraActor (an actor: the level keeps it, and with it the effect, for the whole match), its system set and
    -- started. Returns how many walls, how many blockers shown.
    local function placeLooks(context, map, placed)
        local okS, server = pcall(function() return context:HasAuthority() end)   -- the game state: only the server's has it
        if not okS or server then return 0, 0 end
        local shown = 0
        if SPHERES then
            local mat = nil
            for _, a in ipairs(placed) do
                mat = mat or load(SPHERE_MAT)
                if mat and pcall(function() a.StaticMeshComponent:SetMaterial(0, mat) end) then shown = shown + 1 end
            end
        end
        local list = WALL_AT[map]
        if not (WALLS and list) then return 0, shown end
        local sys, cls = load(WALL), StaticFindObject("/Script/Niagara.NiagaraActor")
        if not (sys and valid(cls)) then log("base walls: NS_PheonixWall or NiagaraActor not loaded"); return 0, shown end
        local n = 0
        for _, w in ipairs(list) do
            local h = math.rad(w[4]) / 2
            local xf = { Translation = { X = w[1], Y = w[2], Z = w[3] }, Rotation = { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) },
                         Scale3D = { X = w[5], Y = w[6], Z = w[7] } }
            local ok, a = pcall(function() return GPS:BeginDeferredActorSpawnFromClass(context, cls, xf, 1, nil) end)
            if ok and valid(a) then
                -- the system before the spawn finishes: the component starts by itself then (bAutoActivate)
                local set, err = pcall(function() a.NiagaraComponent.Asset = sys end)
                GPS:FinishSpawningActor(a, xf)
                if set then
                    local okA, active = pcall(function()
                        if not a.NiagaraComponent:IsActive() then a.NiagaraComponent:Activate(true) end
                        return a.NiagaraComponent:IsActive()
                    end)
                    if okA and active then n = n + 1 else log("base walls: " .. map .. ": not started: " .. tostring(active)) end
                else
                    log("base walls: " .. map .. ": system not set: " .. tostring(err))
                    pcall(function() a:K2_DestroyActor() end)
                end
            end
        end
        return n, shown
    end

    -- Places this map's blockers (once per map, from the arena's game state BeginPlay), and on a player's machine its
    -- looks. Returns how many blockers.
    return function(context, map)
        if not ENABLED then log("base blockers: off"); return 0 end
        local list = BLOCKERS[map]
        if not list then return 0 end
        local class = load(CLASS)
        if not class then log("base blockers: BP_SpawnBlocker not loaded"); return 0 end
        GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
        -- A spawned actor's root gets the spawn scale times the class's own (BP_SpawnBlocker's mesh: 5): divide it out
        local t, tmpl = { X = 1, Y = 1, Z = 1 }, nil
        pcall(function()
            tmpl = StaticFindObject(CDO).StaticMeshComponent
            local r = tmpl.RelativeScale3D
            t = { X = r.X, Y = r.Y, Z = r.Z }
        end)
        local n, placed = 0, {}
        for _, b in ipairs(list) do
            local h = math.rad(b[4]) / 2
            local xf = { Translation = { X = b[1], Y = b[2], Z = b[3] }, Rotation = { X = 0, Y = 0, Z = math.sin(h), W = math.cos(h) },
                         Scale3D = { X = b[5] / t.X, Y = b[6] / t.Y, Z = b[7] / t.Z } }
            -- The root mesh registers (and takes its collision) as the actor is created, from the class's default
            -- component: a mesh set on the new actor afterwards changes its looks and bounds, not its collision (until
            -- 17 Oct Stormheart and Crownwatch blocked at the class sphere's radius, 50 x the smallest scale). So the
            -- default's mesh is swapped for the spawn and put back.
            local mesh, old = b[8] and load(b[8]), nil
            if mesh and valid(tmpl) then old = tmpl.StaticMesh; tmpl.StaticMesh = mesh
            elseif b[8] then log("base blockers: " .. b[8] .. " not used (mesh or class default missing)") end
            local ok, a = pcall(function() return GPS:BeginDeferredActorSpawnFromClass(context, class, xf, 1, nil) end)   -- 1: always spawn
            if old then tmpl.StaticMesh = old end
            if ok and valid(a) then
                GPS:FinishSpawningActor(a, xf)
                pcall(function() a.SpawnTrapperCylinder:SetVisibility(false, false) end)   -- Feb's addition: no collision
                if b[9] then pcall(function() a.Sphere:SetRelativeScale3D({ X = b[9][1], Y = b[9][2], Z = b[9][3] }) end) end
                n = n + 1
                placed[#placed + 1] = a
            end
        end
        local okL, walls, shown = pcall(placeLooks, context, map, placed)
        log(string.format("base blockers: %s: %d placed (class scale %.2f %.2f %.2f divided out), walls: %s, blockers shown: %s", map, n,
            t.X, t.Y, t.Z, okL and tostring(walls) or ("failed: " .. tostring(walls)), okL and tostring(shown) or "-"))
        return n
    end
end
