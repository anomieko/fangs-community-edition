-- Ishir's shotgun sound (tools/patch/patches/community-ishir.json), client side, to ishirsound.log in the client's
-- Win64 folder: the new SoundWave once it is loaded (its properties as the engine read them), the mark cue's actors
-- appearing and going (the "pop" is the cue's OnRemove), and every GameplayStatics.SpawnSoundAttached call with the
-- sound it plays (a hook on the native function). Test clients run with -nosound: the engine has no audio device, so
-- the call returns no AudioComponent; any that exists is logged too. Loaded by tools/run/test_ishir.steps.
FCE_ISHIR = FCE_ISHIR or {}
local I = FCE_ISHIR
local SOUND = "/Game/FangsCE/Audio/SFX_Ishir_ShotgunPop.SFX_Ishir_ShotgunPop"
local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local function name(o) return valid(o) and o:GetFName():ToString() or "none" end
local GPS
local function now()   -- world seconds, the same clock as the game's own timers
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local ok, t = pcall(function() return GPS:GetTimeSeconds(FindFirstOf("BP_MOBAInstance_C")) end)
    return ok and t or 0
end
local logf
local function log(msg)
    logf = logf or io.open("ishirsound.log", "a")
    logf:write(string.format("%s %8.2f %s\n", os.date("%H:%M:%S"), now(), msg)); logf:flush()
end

local function live(className)   -- live objects of a class (an object scan: test clients only)
    local n = 0
    for _, o in ipairs(FindAllOf(className) or {}) do
        if valid(o) and not o:GetFullName():find("Default__", 1, true) then n = n + 1 end
    end
    return n
end

function I.hook()
    if I.hooked then return "already hooked" end
    local ok, err = pcall(RegisterHook, "/Script/Engine.GameplayStatics:SpawnSoundAttached", function(ctx, sound, attach)
        local s, a = sound:get(), attach:get()
        log(string.format("SpawnSoundAttached(%s, attached to %s of %s)", name(s), name(a), valid(a) and name(a:GetOwner()) or "none"))
    end)
    I.hooked = ok
    return ok and "hooked SpawnSoundAttached" or ("hook failed: " .. tostring(err))
end

function I.watch(seconds)
    local stop, marks, seen = os.time() + seconds, -1, {}
    LoopInGameThreadWithDelay(100, function()
        if os.time() > stop then return end
        if not I.waveLogged then
            local w = StaticFindObject(SOUND)
            if valid(w) then
                I.waveLogged = true
                log(string.format("asset loaded: %s, %.3f s, %d channels, %d Hz", w:GetFullName(), w.Duration, w.NumChannels, w.SampleRate))
            end
        end
        local m = live("BP_GC_UltimateMark_C")
        if m ~= marks then log("mark cue actors: " .. m); marks = m end
        for _, c in ipairs(FindAllOf("AudioComponent") or {}) do
            if valid(c) and name(c.Sound) == "SFX_Ishir_ShotgunPop" and not seen[c:GetFullName()] then
                seen[c:GetFullName()] = true
                local parent = c:GetAttachParent()
                log(string.format("playing %s: IsPlaying %s, volume %.2f, attenuation %s, attached to %s of %s",
                    name(c), tostring(c:IsPlaying()), c.VolumeMultiplier, name(c.AttenuationSettings),
                    name(parent), valid(parent) and name(parent:GetOwner()) or "none"))
            end
        end
    end)
    return "watching Ishir's sound for " .. seconds .. " s"
end

local function heroNamed(n)   -- an object scan: a test step, once
    for _, p in ipairs(FindAllOf("BP_PlayerChar_C") or {}) do
        if valid(p) and not p:GetFullName():find("Default__", 1, true) then
            local ok, pn = pcall(function() return p.PlayerState:GetPlayerName():ToString() end)
            if ok and pn == n then return p end
        end
    end
end

local function loadClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    pcall(function() ksl:LoadAsset_Blocking(ksl:Conv_SoftObjPathToSoftObjRef(ksl:MakeSoftObjectPath(path))) end)
    c = StaticFindObject(path)
    return valid(c) and c or nil
end

-- Client: run the mark cue's OnRemove for a hero directly (on the cue's class default object): the function the patch
-- edits, as the end of a mark runs it.
function I.pop(n)
    local p = heroNamed(n)
    local cue = loadClass("/Game/Gameplay/Abilities/Player/BackStab/Skill3/BP_GC_UltimateMark.BP_GC_UltimateMark_C")
    if not (valid(p) and valid(cue)) then return "pop: no hero or cue class" end
    local cdo = StaticFindObject("/Game/Gameplay/Abilities/Player/BackStab/Skill3/BP_GC_UltimateMark.Default__BP_GC_UltimateMark_C")
    local ok, err = pcall(function() cdo:OnRemove(p, {}) end)
    return ok and ("pop: OnRemove ran for " .. n) or ("pop failed: " .. tostring(err))
end


-- Client: log every start and end of the mark cue on this client (its OnActive and OnRemove: the pop plays the shotgun
-- in OnRemove), with the marked hero. A mark the client predicted and then dropped shows as an extra OnRemove.
local CUE = "/Game/Gameplay/Abilities/Player/BackStab/Skill3/BP_GC_UltimateMark.BP_GC_UltimateMark_C"
function I.hookcue()
    if I.cueHooked then return "cue already hooked" end
    if not loadClass(CUE) then return "hookcue: cue class not loaded" end
    local out = {}
    for _, fn in ipairs({ "OnActive", "OnRemove" }) do
        local ok, err = pcall(RegisterHook, CUE .. ":" .. fn, function(ctx, target)
            local t = target:get()
            log(string.format("mark cue %s on %s", fn, valid(t) and name(t) or "none"))
        end)
        out[#out + 1] = fn .. (ok and " hooked" or (" not hooked: " .. tostring(err)))
    end
    I.cueHooked = true
    return "hookcue: " .. table.concat(out, ", ")
end

-- Client: press and release ability key n (1 LMB, 2 RMB, 3 Space, 4 Shift, 5 R, 6 E) through the input manager, as the
-- player controller does for a key, and log it.
function I.press(n)
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local p = GPS:GetPlayerController(FindFirstOf("BP_MOBAInstance_C"), 0).Pawn
    if not valid(p) then return "press: no pawn" end
    log("key " .. n .. " pressed")
    p.BP_AC_InputManager:QueueInput(n, true)
    ExecuteInGameThreadWithDelay(80, function() if valid(p) then p.BP_AC_InputManager:QueueInput(n, false) end end)
    return "press: key " .. n
end

