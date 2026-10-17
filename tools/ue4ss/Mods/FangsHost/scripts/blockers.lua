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

    -- Places this map's blockers (once per map, from the arena's game state BeginPlay). Returns how many.
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
        local n = 0
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
            end
        end
        log(string.format("base blockers: %s: %d placed (class scale %.2f %.2f %.2f divided out)", map, n, t.X, t.Y, t.Z))
        return n
    end
end
