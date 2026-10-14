-- render_heroes.lua: reference renders of the FANGS hero models, run inside the game client by
-- tools/run/render_heroes.sh (UE4SS Lua through FangsCtl). See the header of render_heroes.sh for the method.
--   lua dofile("Z:<repo>/tools/run/render_heroes.lua") return FCE_ART.start({ out = "Z:<dir>", heroes = {...} })
-- Writes linear float EXR tiles (RGB = scene colour, A = inverse opacity) plus render.log (progress, META lines
-- with the framing the post-processing needs) into cfg.out; "ALL DONE" ends the log.
FCE_ART = FCE_ART or {}
local A = FCE_ART

local DEFAULTS = {
    out = "Z:/tmp/fce-art",
    heroes = { "Warlock", "Priest", "WaterBlade", "Scythe", "Sniper" },
    tile = 2048,            -- render target size of one tile (2048 keeps the GPU memory low)
    full_tiles = 3,         -- full body: 3x3 tiles = 6144 px square
    bust_tiles = 3,         -- bust: 3x3 tiles (a window of the same camera)
    full_fov = 25,          -- camera field of view (degrees)
    full_margin = 1.03,     -- room around the silhouette in the full-body window
    bust_size = 0.5,        -- bust square: this fraction of the head joint's height above the feet ...
    bust_head = 1.3,        -- ... but at least this times the silhouette's width at the head
    probe = 128,            -- probe capture size (read back pixel by pixel to find the silhouette)
    cam_az = 30,            -- camera azimuth from the hero's front (degrees, + = the hero's left side)
    face_body = true,       -- measure that front from the pose (hips and shoulders) instead of the mesh's +Y
    cam_override = {},      -- per hero cam_az, e.g. { Gunslinger = -30 }
    cam_el = 0,             -- camera elevation (degrees)
    key_az = -35, key_el = 40,  -- toon "sun" direction relative to the camera (the materials only use its direction)
    settle_ms = 4000,       -- wait after loading a hero (animation into idle, textures streaming in)
    origin = { 0, 0, 20000 },  -- where the stage is built (far above the menu map)
    game_art = nil,         -- list of texture paths to export as well (optional)
    -- heroes whose anim BP does not run on a bare mesh: play this animation asset instead
    anim_override = {
        -- no preview asset, the in-game anim BP leaves the mesh in the bind pose: the twin-sword pack's idle
        BladeMaster = "/Game/Heros/Shared/Prototype/Animations/TwinBladesBundle/TwinSwordAnimsetBase/Animation/Inplace/TwinSword_Idle.TwinSword_Idle",
        -- the preview anim BP holds her in the bind pose, weapon at her feet
        Sniper = "/Game/Characters/Sniper/Animation/ANI_SEQ_Sniper_Idle.ANI_SEQ_Sniper_Idle",
        -- the preview pose has the scythe floating beside him; the in-game idle holds it
        Scythe = "/Game/Characters/Scythe/Animations/ANI_SEQ_FireScythe_Idle_01.ANI_SEQ_FireScythe_Idle_01",
    },
    -- the same for companions (AdditionalSkinDetails): Boo's preview anim BP keeps him scaled to nothing
    extra_anim_override = {
        CatSupp = "/Game/Characters/CatSupp/PetAnimations/ANI_SEQ_CatSupp_Pet_Idle.ANI_SEQ_CatSupp_Pet_Idle",
    },
}

local GS, KSL, KRL, KML, MBL
local logf
local function log(msg)
    if not logf then logf = io.open(A.cfg.out .. "/render.log", "a") end
    if logf then logf:write(os.date("!%H:%M:%S ") .. tostring(msg) .. "\n"); logf:flush() end
end
local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local function fmt(v) return string.format("%.3f", v) end

local function loadPath(path)   -- UE4SS LoadAsset fails in this build; go through a soft object reference
    return KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path)))
end

local function spawn(classPath, setup)
    local o = A.cfg.origin
    local xf = { Translation = { X = o[1], Y = o[2], Z = o[3] }, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local a = GS:BeginDeferredActorSpawnFromClass(A.pc, StaticFindObject(classPath), xf, 1, nil)
    if setup then setup(a) end
    return GS:FinishSpawningActor(a, xf)
end

-- vectors
local function v3(x, y, z) return { X = x, Y = y, Z = z } end
local function sub(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
local function add(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
local function mul(a, s) return v3(a.X * s, a.Y * s, a.Z * s) end
local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function dirFromAngles(azDeg, elDeg)   -- hero space: front = +Y, the hero's left = +X, up = +Z
    local az, el = math.rad(azDeg), math.rad(elDeg)
    return v3(math.sin(az) * math.cos(el), math.cos(az) * math.cos(el), math.sin(el))
end

function A.setup()
    GS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    KRL = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    MBL = StaticFindObject("/Script/MOBA.Default__MOBABlueprintLibrary")
    A.gi = FindFirstOf("BP_MOBAInstance_C")
    if not valid(A.gi) or not valid(A.gi.HeroCollection) then return false, "game instance / hero collection not ready" end
    A.pc = GS:GetPlayerController(A.gi, 0)
    if not valid(A.pc) then return false, "no player controller" end
    -- capture: own SceneCapture2D, linear scene colour with inverse opacity in alpha, only our actors
    if not valid(A.cap) then
        A.cap = spawn("/Script/Engine.SceneCapture2D", function(a)
            a.CaptureComponent2D.bCaptureEveryFrame = false
            a.CaptureComponent2D.bCaptureOnMovement = false
        end)
    end
    local c = A.cap.CaptureComponent2D
    c.bCaptureEveryFrame = false; c.bCaptureOnMovement = false
    c.CaptureSource = 0          -- SCS_SceneColorHDR: linear colour, inverse opacity in A
    c.PrimitiveRenderMode = 2    -- PRM_UseShowOnlyList
    if not valid(A.rt) or A.rt.SizeX ~= A.cfg.tile then
        A.rt = KRL:CreateRenderTarget2D(A.gi, A.cfg.tile, A.cfg.tile, 6, { R = 0, G = 0, B = 0, A = 0 }, false)  -- RTF_RGBA16f
    end
    c.TextureTarget = A.rt
    -- the character materials are unlit toon shaders that take their light direction from the atmosphere sun
    -- light: make ours the sun, switch off the menu map's
    if not valid(A.sun) then
        A.sun = spawn("/Script/Engine.DirectionalLight", function(a) a.LightComponent.Mobility = 2 end)
    end
    for _, l in ipairs(FindAllOf("DirectionalLight") or {}) do
        if l ~= A.sun and valid(l) then
            pcall(function() l.LightComponent:SetAtmosphereSunLight(false) end)
            l.LightComponent:SetVisibility(false, false)
        end
    end
    A.sun.LightComponent:SetAtmosphereSunLight(true)
    pcall(function() A.sun.LightComponent:SetAtmosphereSunLightIndex(0) end)
    if not valid(A.hero) then A.hero = spawn("/Script/Engine.SkeletalMeshActor") end
    A.extras = A.extras or {}
    return true
end

local function forceMips(comp)
    pcall(function() comp:PrestreamTextures(120, true, 0) end)
    for i = 0, comp:GetNumMaterials() - 1 do
        local m = comp:GetMaterial(i)
        if valid(m) then
            pcall(function() m:SetForceMipLevelsToBeResident(true, true, 120, 0, true) end)
            pcall(function()
                local tp = m.TextureParameterValues
                for j = 1, tp:GetArrayNum() do
                    local t = tp[j].ParameterValue
                    if valid(t) then t.bGlobalForceMipLevelsToBeResident = true end
                end
            end)
        end
    end
end

local function setupMesh(comp, mesh, animClass, materials, animAsset)
    comp.VisibilityBasedAnimTickOption = 0   -- always refresh bones (by default only when rendered in the main view)
    comp:SetForcedLOD(1)   -- LOD 0
    if valid(animClass) then comp:SetAnimationMode(0); comp:SetAnimClass(animClass) end
    comp:SetSkeletalMesh(mesh, true)
    for i, m in ipairs(materials) do if valid(m) then comp:SetMaterial(i - 1, m) end end
    if valid(animAsset) then comp:PlayAnimation(animAsset, true) end   -- single animation instead of the anim BP
    comp:SetVisibility(true, false)
    forceMips(comp)
end

local function clearExtras()
    for _, e in ipairs(A.extras) do if valid(e) then e:K2_DestroyActor() end end
    A.extras = {}
end

-- hero sources: the menu preview asset (DA_<Hero>_Preview: default skin mesh + materials, preview anim BP);
-- without one, the in-game character Blueprint's mesh
local function heroSource(name)
    local def = A.gi.HeroCollection:GetPreviewHeroByName(name)
    if valid(def) then
        local skin = def.SkinCollection:GetDefaultSkin()
        if not valid(skin) then return nil, "preview asset has no default skin" end
        local src = { kind = "preview " .. def:GetFName():ToString() .. " / " .. skin.SkinID:ToString(), materials = {}, extras = {} }
        src.mesh = KSL:LoadAsset_Blocking(skin.SkeletalMesh)
        src.anim = MBL:LoadClassSoftReferenceSynchronously(def.AnimationBlueprint)
        for i = 1, skin.Materials:GetArrayNum() do src.materials[i] = KSL:LoadAsset_Blocking(skin.Materials[i]) end
        for i = 1, skin.AdditionalSkinDetails:GetArrayNum() do
            local d = skin.AdditionalSkinDetails[i]
            local x = { mesh = KSL:LoadAsset_Blocking(d.ComponentMesh), anim = MBL:LoadClassSoftReferenceSynchronously(d.AnimationBlueprint),
                loc = v3(d.RelativeLocation.X, d.RelativeLocation.Y, d.RelativeLocation.Z),
                rot = { Pitch = d.RelativeRotation.Pitch, Yaw = d.RelativeRotation.Yaw, Roll = d.RelativeRotation.Roll }, materials = {} }
            for j = 1, d.ComponentMaterials:GetArrayNum() do x.materials[j] = d.ComponentMaterials[j] end
            src.extras[#src.extras + 1] = x
        end
        return src
    end
    local path = "/Game/BluePrints/Character/BP_" .. name .. "_Char.BP_" .. name .. "_Char_C"
    local cls = loadPath(path)
    if not valid(cls) then return nil, "no preview asset and no " .. path end
    local m = cls:GetCDO().Mesh
    local src = { kind = "character BP " .. path, mesh = m.SkeletalMesh, anim = m.AnimClass, materials = {}, extras = {} }
    pcall(function() for i = 1, m.OverrideMaterials:GetArrayNum() do src.materials[i] = m.OverrideMaterials[i] end end)
    return src
end

function A.loadHero(name)
    clearExtras()
    local src, err = heroSource(name)
    if not src then return nil, err end
    if not valid(src.mesh) then return nil, "mesh did not load (" .. src.kind .. ")" end
    -- a fresh actor per hero: material overrides of the previous hero must not stay
    if valid(A.hero) then A.hero:K2_DestroyActor() end
    A.hero = spawn("/Script/Engine.SkeletalMeshActor")
    local comp = A.hero.SkeletalMeshComponent
    local ov = A.cfg.anim_override[name]
    src.animAsset = ov and loadPath(ov) or nil
    if src.animAsset then src.anim = nil end
    setupMesh(comp, src.mesh, src.anim, src.materials, src.animAsset)
    -- companions (Zoey's cat): offset from the hero; the preview stage faces +X, ours +Y, so turn them by 90 degrees
    for _, x in ipairs(src.extras) do
        if valid(x.mesh) then
            local e = spawn("/Script/Engine.SkeletalMeshActor")
            local xov = A.cfg.extra_anim_override[name]
            local xa = xov and loadPath(xov) or nil
            setupMesh(e.SkeletalMeshComponent, x.mesh, (not xa) and x.anim or nil, x.materials, xa)
            local o = A.cfg.origin
            local loc = v3(o[1] - x.loc.Y, o[2] + x.loc.X, o[3] + x.loc.Z)
            e:K2_SetActorLocationAndRotation(loc, { Pitch = x.rot.Pitch, Yaw = x.rot.Yaw + 90, Roll = x.rot.Roll }, false, {}, true)
            A.extras[#A.extras + 1] = e
        end
    end
    A.src = src
    return src
end

-- skeleton: bone positions (for framing) and the head
local function measure()
    local comp = A.hero.SkeletalMeshComponent
    local pts, head, headScore, neck = {}, nil, 9, nil
    for i = 0, comp:GetNumBones() - 1 do
        local n = comp:GetBoneName(i):ToString()
        local l = n:lower()
        if not (l:find("^vb ") or l:find("^ik_")) then
            local p = comp:GetSocketLocation(FName(n))
            pts[#pts + 1] = p
            if l:find("head", 1, true) and not (l:find("end") or l:find("nub") or l:find("top") or l:find("twist") or l:find("target") or l:find("tip")) then
                local score = (l == "head") and 0 or ((l:find("^head[_ ]") or l:find("[_ ]head$") or l:find("[_ ]head[_ ]")) and 1 or 2)
                if score < headScore then head, headScore = { name = n, p = p }, score end
            end
            if not neck and l:find("neck", 1, true) then neck = { name = n, p = p } end
        end
    end
    local lo, hi = v3(1e9, 1e9, 1e9), v3(-1e9, -1e9, -1e9)
    for _, p in ipairs(pts) do
        lo = v3(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z))
        hi = v3(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z))
    end
    local base = math.min(lo.Z, A.cfg.origin[3])
    -- body facing in this pose (the preview poses are turned): horizontal left -> right vector across the hips and
    -- shoulders, front = that turned by 90 degrees (the meshes' rest pose faces +Y = azimuth 0)
    local v = { X = 0, Y = 0 }
    for _, pr in ipairs({ { "Hip_R", "Hip_L" }, { "Shoulder_R", "Shoulder_L" }, { "frontHip_R", "frontHip_L" },
        { "thigh_r", "thigh_l" }, { "upperarm_r", "upperarm_l" } }) do
        if comp:GetBoneIndex(FName(pr[1])) >= 0 and comp:GetBoneIndex(FName(pr[2])) >= 0 then
            local d = sub(comp:GetSocketLocation(FName(pr[1])), comp:GetSocketLocation(FName(pr[2])))
            local len = math.sqrt(d.X * d.X + d.Y * d.Y)
            if len > 0.01 then v.X = v.X + d.X / len; v.Y = v.Y + d.Y / len end
        end
    end
    local facing = (v.X ~= 0 or v.Y ~= 0) and math.deg(math.atan(v.Y, -v.X)) or 0
    if not head then
        if neck then head = { name = neck.name .. "+", p = add(neck.p, v3(0, 0, 0.06 * (hi.Z - base))) }
        else head = { name = "(top of skeleton)", p = v3((lo.X + hi.X) / 2, (lo.Y + hi.Y) / 2, hi.Z - 0.08 * (hi.Z - base)) } end
    end
    -- the mesh reaches beyond the bones (hair, weapons, robes): also take the skinned bounds, all actors
    local all = { A.hero }
    for _, e in ipairs(A.extras) do all[#all + 1] = e end
    for _, a in ipairs(all) do
        local o, ext = {}, {}
        KSL:GetComponentBounds(a.SkeletalMeshComponent, o, ext, {})
        for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
            pts[#pts + 1] = v3(o.X + sx * ext.X, o.Y + sy * ext.Y, o.Z + sz * ext.Z)
        end end end
    end
    return { pts = pts, lo = lo, hi = hi, base = base, head = head, bones = comp:GetNumBones(), facing = facing }
end

-- camera looking at target T from direction d (unit vector from T to the camera); returns the framing
local function frame(T, d, fov, points, margin)
    local t = math.tan(math.rad(fov / 2))
    local rot = KML:Conv_VectorToRotator(mul(d, -1))
    local r, u = KML:GetRightVector(rot), KML:GetUpVector(rot)
    local dist = 0
    for _, p in ipairs(points) do
        local q = sub(p, T)
        local need = (math.max(math.abs(dot(q, r)), math.abs(dot(q, u))) * margin) / t + dot(q, d)
        if need > dist then dist = need end
    end
    local C = add(T, mul(d, dist))
    return { C = C, rot = rot, r = r, u = u, f = mul(d, -1), t = t, fov = fov }
end

local function ndc(fr, p)   -- world point -> normalized device coordinates of the frame's camera, and depth
    local q = sub(p, fr.C)
    local z = dot(q, fr.f)
    return dot(q, fr.r) / (z * fr.t), dot(q, fr.u) / (z * fr.t), z
end

local function aim(fr)
    local c = A.cap.CaptureComponent2D
    c:ClearShowOnlyComponents()
    c:ShowOnlyActorComponents(A.hero, true)
    for _, e in ipairs(A.extras) do c:ShowOnlyActorComponents(e, true) end
    c:K2_SetWorldLocationAndRotation(fr.C, fr.rot, false, {}, true)
    c.FOVAngle = fr.fov
    return c
end

-- low-resolution capture of the frame, read back: the opaque pixels (grid[y][x], y down) and their bounding box
local function probe(fr)
    local P = A.cfg.probe
    if not valid(A.probeRT) or A.probeRT.SizeX ~= P then
        A.probeRT = KRL:CreateRenderTarget2D(A.gi, P, P, 6, { R = 0, G = 0, B = 0, A = 0 }, false)
    end
    local c = aim(fr)
    c.bUseCustomProjectionMatrix = false
    c.TextureTarget = A.probeRT
    c:CaptureScene()
    local g = { P = P, grid = {}, x0 = P, x1 = -1, y0 = P, y1 = -1 }
    for y = 0, P - 1 do
        local row = {}
        for x = 0, P - 1 do
            local o = KRL:ReadRenderTargetRawPixel(A.gi, A.probeRT, x, y).A < 0.95   -- alpha = inverse opacity
            row[x] = o
            if o then
                if x < g.x0 then g.x0 = x end
                if x > g.x1 then g.x1 = x end
                if y < g.y0 then g.y0 = y end
                if y > g.y1 then g.y1 = y end
            end
        end
        g.grid[y] = row
    end
    c.TextureTarget = A.rt
    if g.x1 < 0 then return nil end
    g.edge = g.x0 == 0 or g.y0 == 0 or g.x1 == P - 1 or g.y1 == P - 1
    return g
end

local function toPx(g, nx, ny) return (nx + 1) / 2 * g.P, (1 - ny) / 2 * g.P end
local function toWin(g, px0, py0, side)   -- square in probe pixels (top-left, side) -> NDC window
    return { cx = (px0 + side / 2) / g.P * 2 - 1, cy = 1 - (py0 + side / 2) / g.P * 2, hw = side / g.P }
end

-- full body: the silhouette's bounding square (plus a margin)
local function fullWindow(g)
    local w, h = g.x1 - g.x0 + 3, g.y1 - g.y0 + 3      -- one probe pixel of padding each side
    local side = math.max(w, h) * A.cfg.full_margin
    return toWin(g, (g.x0 + g.x1 + 1) / 2 - side / 2, (g.y0 + g.y1 + 1) / 2 - side / 2, side)
end

-- bust: head and shoulders. Size: half the head joint's height, but at least 1.3 x the silhouette's width at the
-- head (big heads, creatures), at most 3/4 of the figure; top: the top of the head (silhouette above the joint,
-- hats and horns included) but at most half the square above the joint
local function bustWindow(g, hx, hy, fy)
    local cfg, P = A.cfg, g.P
    local function opaque(x, y) return x >= 0 and x < P and y >= 0 and y < P and g.grid[y][x] end
    local widths = {}
    for dy = -1, 1 do
        local y = math.floor(hy + dy)
        local x = math.floor(hx)
        for k = 0, 3 do   -- nearest opaque pixel to the joint on that row
            if opaque(x + k, y) then x = x + k break elseif opaque(x - k, y) then x = x - k break end
        end
        if opaque(x, y) then
            local a, b = x, x
            while opaque(a - 1, y) do a = a - 1 end
            while opaque(b + 1, y) do b = b + 1 end
            widths[#widths + 1] = b - a + 1
        end
    end
    table.sort(widths)
    local width = widths[math.max(1, math.ceil(#widths / 2))] or 0
    local side = math.max(cfg.bust_size * (fy - hy), cfg.bust_head * width)
    side = math.min(side, 0.75 * (g.y1 - g.y0 + 1))
    local top = hy
    for y = g.y0, math.floor(hy) do
        local found = false
        for x = math.floor(hx - side / 4), math.ceil(hx + side / 4) do if opaque(x, y) then found = true break end end
        if found then top = y break end
    end
    top = math.max(top - 0.04 * side, hy - 0.5 * side)
    return toWin(g, hx - side / 2, top, side), width
end
-- n x n tiles of the NDC window (cx, cy, half size hw); tile (i, j): an off-axis projection, i.e. the
-- symmetric reversed-Z infinite projection scaled by n / hw and shifted
local function capture(name, kind, fr, n, win)
    local c = aim(fr)
    c.TextureTarget = A.rt
    c.bUseCustomProjectionMatrix = true
    local s = n / win.hw
    for j = 0, n - 1 do
        for i = 0, n - 1 do
            c.CustomProjectionMatrix = {
                XPlane = { X = s / fr.t, Y = 0, Z = 0, W = 0 },
                YPlane = { X = 0, Y = s / fr.t, Z = 0, W = 0 },
                ZPlane = { X = -s * win.cx + (n - 2 * i - 1), Y = -s * win.cy - (n - 2 * j - 1), Z = 0, W = 1 },
                WPlane = { X = 0, Y = 0, Z = 10, W = 0 },
            }
            c:CaptureScene()
            KRL:ExportRenderTarget(A.gi, A.rt, A.cfg.out, string.format("%s_%s_%d_%d.exr", name, kind, j, i))
        end
    end
    c.bUseCustomProjectionMatrix = false
end

local function pixel(fr, win, p, size)   -- world point -> pixel in the stitched window image, pixels per cm there
    local x, y, z = ndc(fr, p)
    return ((x - win.cx) / win.hw + 1) / 2 * size, (1 - (y - win.cy) / win.hw) / 2 * size, (size / 2) / (z * fr.t * win.hw)
end

function A.shoot(name)
    local cfg = A.cfg
    local m = measure()
    local az = (cfg.cam_override[name] or cfg.cam_az) + (cfg.face_body and m.facing or 0)
    local d = dirFromAngles(az, cfg.cam_el)
    -- sun: relative to the camera direction
    local k = dirFromAngles(az + cfg.key_az, cfg.key_el)
    A.sun.LightComponent:K2_SetWorldRotation(KML:Conv_VectorToRotator(mul(k, -1)), false, {}, true)
    -- a loose frame from the bones and skinned bounds; the probe finds the silhouette in it (if the loose frame
    -- cut something off, step back and probe again); full body and bust are tiled windows of that one camera
    local lo, hi = v3(1e9, 1e9, 1e9), v3(-1e9, -1e9, -1e9)
    for _, p in ipairs(m.pts) do
        lo = v3(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z))
        hi = v3(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z))
    end
    local T = mul(add(lo, hi), 0.5)
    local margin, fr, g = 1.1, nil, nil
    for _ = 1, 4 do
        fr = frame(T, d, cfg.full_fov, m.pts, margin)
        g = probe(fr)
        if not g then error("probe: nothing rendered") end
        if not g.edge then break end
        margin = margin * 1.6
    end
    local foot = v3(m.head.p.X, m.head.p.Y, m.base)
    local win = fullWindow(g)
    local size = cfg.tile * cfg.full_tiles
    local hx, hy = pixel(fr, win, m.head.p, size)
    local fx, fy, pxcm = pixel(fr, win, foot, size)
    capture(name, "full", fr, cfg.full_tiles, win)
    log(string.format('META {"hero":"%s","kind":"full","n":%d,"tile":%d,"head":[%s,%s],"feet":[%s,%s],"pxcm":%s,"edge":%s,"source":"%s","headbone":"%s","bones":%d,"height_cm":%s,"facing":%s,"cam_az":%s}',
        name, cfg.full_tiles, cfg.tile, fmt(hx), fmt(hy), fmt(fx), fmt(fy), fmt(pxcm), tostring(g.edge), A.src.kind, m.head.name, m.bones,
        fmt(m.hi.Z - m.base), fmt(m.facing), fmt(az)))
    local phx, phy = toPx(g, ndc(fr, m.head.p))
    local _, pfy = toPx(g, ndc(fr, foot))
    local wb, width = bustWindow(g, phx, phy, pfy)
    size = cfg.tile * cfg.bust_tiles
    hx, hy, pxcm = pixel(fr, wb, m.head.p, size)
    capture(name, "bust", fr, cfg.bust_tiles, wb)
    log(string.format('META {"hero":"%s","kind":"bust","n":%d,"tile":%d,"head":[%s,%s],"pxcm":%s,"head_width_probe_px":%d,"side_probe_px":%s}',
        name, cfg.bust_tiles, cfg.tile, fmt(hx), fmt(hy), fmt(pxcm), width, fmt(wb.hw * g.P)))
    return true
end

-- game textures (e.g. the official Hero3DRenders): canvas draw into a float target, then EXR
function A.exportTexture(path, pass)
    local tex = loadPath(path)
    if not valid(tex) then return false, "not found" end
    pcall(function() tex.bGlobalForceMipLevelsToBeResident = true end)
    local w, h = tex:Blueprint_GetSizeX(), tex:Blueprint_GetSizeY()
    local rt = KRL:CreateRenderTarget2D(A.gi, w, h, 6, { R = 0, G = 0, B = 0, A = 0 }, false)
    local canvas, size, ctx = {}, {}, {}
    KRL:BeginDrawCanvasToRenderTarget(A.gi, rt, canvas, size, ctx)
    canvas.Canvas:K2_DrawTexture(tex, { X = 0, Y = 0 }, { X = w, Y = h }, { X = 0, Y = 0 }, { X = 1, Y = 1 }, { R = 1, G = 1, B = 1, A = 1 }, 0, 0, { X = 0.5, Y = 0.5 })
    KRL:EndDrawCanvasToRenderTarget(A.gi, ctx)
    if pass == 2 then
        local name = path:match("([^/%.]+)%.[^/]+$") or path
        KRL:ExportRenderTarget(A.gi, rt, A.cfg.out .. "/game", name .. ".exr")
    end
    pcall(function() KRL:ReleaseRenderTarget2D(rt) end)
    return true, w .. "x" .. h
end

-- sequential steps on the game thread, each returns the delay (ms) before the next
local function runSteps(steps, i)
    i = i or 1
    if i > #steps then return end
    local ok, delay = pcall(steps[i].fn)
    if not ok then log("ERROR " .. steps[i].name .. ": " .. tostring(delay)); delay = 1 end
    ExecuteInGameThreadWithDelay(math.max(1, math.floor(delay or 1)), function() runSteps(steps, i + 1) end)
end

function A.start(opts)
    A.cfg = {}
    for k, v in pairs(DEFAULTS) do A.cfg[k] = v end
    for k, v in pairs(opts or {}) do A.cfg[k] = v end
    if logf then logf:close(); logf = nil end   -- the log lives in cfg.out
    local ok, err = A.setup()
    if not ok then return "not ready: " .. tostring(err) end
    log("start: " .. #A.cfg.heroes .. " heroes, tiles " .. A.cfg.tile .. " x " .. A.cfg.full_tiles .. "/" .. A.cfg.bust_tiles)
    local steps, failed = {}, {}
    for _, name in ipairs(A.cfg.heroes) do
        steps[#steps + 1] = { name = "load " .. name, fn = function()
            local src, e = A.loadHero(name)
            if not src then failed[name] = true; log("SKIP " .. name .. ": " .. tostring(e)); return 1 end
            log("loaded " .. name .. ": " .. src.kind .. ", mesh " .. src.mesh:GetFName():ToString() ..
                ", anim " .. (valid(src.anim) and src.anim:GetFName():ToString() or valid(src.animAsset) and src.animAsset:GetFName():ToString() or "none") ..
                ", extras " .. #src.extras)
            return A.cfg.settle_ms
        end }
        steps[#steps + 1] = { name = "shoot " .. name, fn = function()
            if failed[name] then return 1 end
            A.shoot(name)
            log("done " .. name)
            return 200
        end }
    end
    if A.cfg.game_art and #A.cfg.game_art > 0 then
        steps[#steps + 1] = { name = "game art load", fn = function()
            for _, p in ipairs(A.cfg.game_art) do
                local ok2, r = pcall(A.exportTexture, p, 1)
                if not ok2 or r == false then log("game art missing: " .. p) end
            end
            return 15000   -- let the streamer bring in the top mips
        end }
        steps[#steps + 1] = { name = "game art export", fn = function()
            for _, p in ipairs(A.cfg.game_art) do
                local ok2, r, info = pcall(A.exportTexture, p, 2)
                if ok2 and r then log("game art " .. p .. " " .. tostring(info)) end
            end
            return 1
        end }
    end
    steps[#steps + 1] = { name = "end", fn = function()
        A.hero.SkeletalMeshComponent:SetVisibility(false, false)
        clearExtras()
        log("ALL DONE")
        return 1
    end }
    runSteps(steps)
    return "started " .. #A.cfg.heroes .. " heroes"
end
