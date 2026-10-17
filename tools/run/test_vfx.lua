-- VFX lab for tools/run/test_vfx.sh (client, FangsCtl): spawns Niagara systems next to the local hero, so that
-- screenshots show whether a system is visible and what a colour parameter does. Loaded with dofile; V is global.
V = { spawned = {} }
local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local NFL = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
local GPS = StaticFindObject("/Script/Engine.Default__GameplayStatics")

local function valid(o) return o ~= nil and o:IsValid() end
local function load(path)
    local o = StaticFindObject(path)
    if valid(o) then return o end
    pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
    o = StaticFindObject(path)
    return valid(o) and o or nil
end
local function pawn() return GPS:GetPlayerController(FindFirstOf("BP_MOBAInstance_C"), 0).Pawn end

-- spawn a system `side` units to the right of the hero as the camera sees it (negative: left), on the floor;
-- color = {r, g, b[, a]} sets the "Color" user parameter
local KML = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
function V.spawn(path, side, _, color)
    local sys = load(path)
    if not sys then return "no " .. path end
    local p = pawn()
    local l = p:K2_GetActorLocation()
    local cm = GPS:GetPlayerController(FindFirstOf("BP_MOBAInstance_C"), 0).PlayerCameraManager
    local r = KML:GetRightVector(cm:GetCameraRotation())
    local c = NFL:SpawnSystemAtLocation(p, sys, { X = l.X + r.X * side, Y = l.Y + r.Y * side, Z = l.Z - 85 }, { Pitch = 0, Yaw = 0, Roll = 0 },
        { X = 1, Y = 1, Z = 1 }, false, true, 0, false)
    if not valid(c) then return "spawn failed: " .. path end
    if color then c:SetColorParameter(FName("Color"), { R = color[1], G = color[2], B = color[3], A = color[4] or 1 }) end
    V.spawned[#V.spawned + 1] = c
    return "spawned " .. path:match("([^/.]+)$") .. (color and string.format(" color %g,%g,%g", color[1], color[2], color[3]) or "")
end

function V.clear()
    for _, c in ipairs(V.spawned) do pcall(function() if valid(c) then c:K2_DestroyComponent(c) end end) end
    V.spawned = {}
    return "cleared"
end

local Z = "/Game/HiddenLeafVFX/Champions/ZoeyandBoo/Skill3/"
function V.zoey()
    return V.spawn(Z .. "NS_CatSupp_Skill3_ULT.NS_CatSupp_Skill3_ULT", -300) .. "; "
        .. V.spawn(Z .. "Hellhound/NS_Hellhound_CatSupp_Skill3_ULT.NS_Hellhound_CatSupp_Skill3_ULT", 300)
end

-- the hero's VFX pack as a skin would set it (DT_VFXPacks row), on this client
function V.pack(row)
    local p = pawn()
    p["Current VFXPack"] = row
    p["Load VFXPack"](p)
    local ref = p.VFXPackRef
    return "pack " .. row .. " -> " .. (valid(ref) and ref:GetFName():ToString() or "none")
end

-- the mouse dx, dy pixels from the hero on screen, so that targeted abilities land in view
function V.aimNear(dx, dy)
    local pc = GPS:GetPlayerController(FindFirstOf("BP_MOBAInstance_C"), 0)
    local v = {}
    pc:ProjectWorldLocationToScreen(pawn():K2_GetActorLocation(), v, false)
    pc:SetMouseLocation(math.floor(v.X + dx), math.floor(v.Y + dy))
    return string.format("mouse at %d,%d", math.floor(v.X + dx), math.floor(v.Y + dy))
end

-- activate the hero's ability whose class name contains `part`
function V.fire(part)
    local p = pawn()
    local hit
    p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e)
        local a = e:get().Ability
        if not hit and valid(a) and a:GetClass():GetFName():ToString():find(part, 1, true) then hit = a:GetClass() end
    end)
    if not hit then return "no ability " .. part end
    return "fire " .. hit:GetFName():ToString() .. " -> " .. tostring(p.AbilitySystemComponent:TryActivateAbilityByClass(hit, true))
end

local A = "/Game/HiddenLeafVFX/Champions/Astrada/"
function V.cage(ally, enemy)
    local function find(name)
        for _, dir in ipairs({ A .. "Skills/Shift/" }) do
            local o = load(dir .. name .. "." .. name)
            if o then return dir .. name .. "." .. name end
        end
    end
    local pa, pe = find("NS_Astrada_Shift_System_Ally"), find("NS_Astrada_Shift_System_Enemy")
    if not (pa and pe) then return "cage systems not found" end
    return V.spawn(pa, -320, nil, ally) .. "; " .. V.spawn(pe, 320, nil, enemy)
end

-- server: full mana for every hero (ults cost mana)
function V.fill()
    local gs = FindFirstOf("GameStateBase")
    local n = 0
    for i = 1, gs.PlayerArray:GetArrayNum() do
        local ps = gs.PlayerArray[i]
        local p = valid(ps) and ps.PawnPrivate or nil
        if valid(p) and p.AbilitySystemComponent then
            local set = p.AbilitySystemComponent.SpawnedAttributes[1]
            set.Mana.BaseValue = set.MaxMana.CurrentValue; set.Mana.CurrentValue = set.MaxMana.CurrentValue
            n = n + 1
        end
    end
    return "mana filled for " .. n .. " heroes"
end

-- Ethryn's shield effect, facing the camera: as spawned today (left) and scaled like the patch does (right)
function V.shield()
    local sys = load("/Game/Gameplay/Abilities/Player/ShieldGirl/Skill4/VFX/NS_ShieldGirl_Mesh_2.NS_ShieldGirl_Mesh_2")
    if not sys then return "no shield system" end
    local p = pawn()
    local l = p:K2_GetActorLocation()
    local cm = GPS:GetPlayerController(FindFirstOf("BP_MOBAInstance_C"), 0).PlayerCameraManager
    local rot = cm:GetCameraRotation()
    local r = KML:GetRightVector(rot)
    local out = {}
    for i, sc in ipairs({ { 1, 1, 1 }, { 1, 0.85, 0.9 } }) do
        local side = i == 1 and -300 or 300
        local c = NFL:SpawnSystemAtLocation(p, sys, { X = l.X + r.X * side, Y = l.Y + r.Y * side, Z = l.Z - 85 },
            { Pitch = 0, Yaw = rot.Yaw + 180, Roll = 0 }, { X = sc[1], Y = sc[2], Z = sc[3] }, false, true, 0, false)
        if valid(c) then V.spawned[#V.spawned + 1] = c; out[#out + 1] = string.format("shield scale %g,%g,%g", sc[1], sc[2], sc[3]) end
    end
    return table.concat(out, "; ")
end

return "test_vfx helpers"
