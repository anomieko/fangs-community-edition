-- Helpers for tools/run/test_passives.sh (docs/recon/community-build-passives.md), loaded by FangsCtl (dofile) into the
-- game server after test_patch.lua. Whether each hero's passive ability is running, and what it gives (Wylde's ammo,
-- Fiorne's Bunny Stacks), through deaths, stuns and round changes.
--   watch()            server: every 250 ms, logs each hero's passive (running or not), ammo / stacks, the tags that
--                      block a passive's activation (LockCasts, Dead, Channeling) and the round state, when any of
--                      them changes, to passives.log in the game server's Win64 folder.
--   turret(name)       server: the hero stands in front of the enemy turret and dies there.
--   endround(team)     server: the round ends, won by team (1 = A, 2 = B), as the developers' QA tool does it.
--   lockin(item, slot) client: an item into a slot of the augment screen, then lock in (as a player does).
--   state(name)        server: one line like watch() writes.
FCE_PASSIVES = FCE_PASSIVES or {}
local P = FCE_PASSIVES

local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local KSL, GPS, ASL
local function loadClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(path))) end)
    c = StaticFindObject(path)
    return valid(c) and c or nil
end

local function heroes()
    local gi = FindFirstOf("BP_MOBAInstance_C")
    local gs = gi and gi:GetWorld().GameState
    local t = {}
    if not valid(gs) then return t end
    gs.PlayerArray:ForEach(function(_, e)
        local ps = e:get()
        local p = valid(ps) and ps.PawnPrivate
        if valid(p) then t[#t + 1] = { name = ps:GetPlayerName():ToString(), pawn = p } end
    end)
    return t
end
local function hero(name)
    for _, h in ipairs(heroes()) do if h.name == name then return h.pawn end end
end
local function now(ctx)
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    return GPS:GetTimeSeconds(ctx)
end
local function tagged(asc, tag)
    local ok, r = pcall(function() return asc:HasMatchingGameplayTag({ TagName = FName(tag) }) end)
    return ok and r or false
end

-- The hero's passive and the always-running helpers (Wylde's reload, Fiorne's stack system): running or not
-- (ActiveCount) and the spec handle (a new handle = the ability was granted again).
local WATCHED = { ["_P_C$"] = "passive", ["Gunslinger_Reload_C$"] = "reload", ["Lancer_Ammo_C$"] = "stacksys" }
local function abilitiesOf(p)
    local out, pname = {}, "?"
    pcall(function()
        p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e)
            local s = e:get()
            local ab = s.Ability
            if valid(ab) then
                local n = ab:GetClass():GetFName():ToString()
                for pat, label in pairs(WATCHED) do
                    if n:match(pat) then
                        if label == "passive" then pname = n:gsub("_C$", "") end
                        out[#out + 1] = string.format("%s=%d#%d", label, s.ActiveCount, s.Handle.Handle)
                    end
                end
            end
        end)
    end)
    table.sort(out)
    return pname, table.concat(out, " ")
end

local function effectStacks(p, wanted)
    local n = 0
    pcall(function()
        p.AbilitySystemComponent.ActiveGameplayEffects.GameplayEffects_Internal:ForEach(function(_, e)
            local ge = e:get()
            local d = ge.Spec.Def
            if valid(d) and wanted[d:GetClass():GetFName():ToString():gsub("_C$", "")] then
                n = n + math.max(ge.Spec.StackCount, 1)
            end
        end)
    end)
    return n
end
local AMMO = { BP_GE_Gunslinger_P_Bullets = true, BP_GE_Lancer_BunnyStacks = true, BP_GE_Lancer_MoreBunnyStacks = true }

local function roundState()
    local gi = FindFirstOf("BP_MOBAInstance_C")
    local gs = gi and gi:GetWorld().GameState
    if not valid(gs) then return "?" end
    local s = "?"
    pcall(function() s = string.format("round %d+%d", gs.TeamARoundsWon, gs.TeamBRoundsWon) end)
    pcall(function() if gs:IsAtItemSelection() then s = s .. " items" end end)
    pcall(function() if gs:IsAtKingSelection() then s = s .. " captain" end end)
    return s
end

local function line(name, p)
    local asc = p.AbilitySystemComponent
    local pn, act = abilitiesOf(p)
    local set = asc.SpawnedAttributes[1]
    local blk = {}
    -- the passive's old start blockers, the base's spawn protection (base blockers), Fiorne's E block at 0 stacks and her
    -- stack cooldown (a running one adds a stack when it ends)
    for _, t in ipairs({ "Effect.LockCasts", "State.Dead", "State.Channeling", "Systems.Input.LockAbilities",
                         "Effect.SpawnBlocker", "Lancer.Skill4.CantCast", "Effect.Ammo.Cooldown.Skill1" }) do
        if tagged(asc, t) then blk[#blk + 1] = t end
    end
    return string.format("%s %s %s ammo/stacks=%d hp=%.0f block=%s", name, pn, act,
        effectStacks(p, AMMO), set.Health.CurrentValue, #blk > 0 and table.concat(blk, ",") or "-")
end

local logf
local function log(msg)
    logf = logf or io.open("passives.log", "a")
    logf:write(msg .. "\n"); logf:flush()
end

function P.state(name)
    local p = hero(name)
    if not valid(p) then return "state: no hero " .. name end
    local s = line(name, p)
    log(string.format("%8.2f   %s   [%s]", now(p), s, roundState()))
    return "state: " .. s
end

function P.watch()
    if P.watching then return "already watching" end
    P.watching = true
    local last = {}
    LoopInGameThreadWithDelay(250, function()
        local hs = heroes()
        for _, h in ipairs(hs) do
            local ok, s = pcall(line, h.name, h.pawn)
            if ok and last[h.name] ~= s then
                last[h.name] = s
                log(string.format("%8.2f   %s   [%s]", now(h.pawn), s, roundState()))
            end
        end
        local r = roundState()
        if last.__round ~= r then last.__round = r; log("         -- " .. r) end
    end)
    return "watching passives"
end

-- A real death: the hero stands in front of the enemy turret (it shoots heroes; the shards test does the same).
function P.turret(name)
    local p = hero(name)
    if not valid(p) then return "turret: no hero " .. name end
    local target
    for _, t in ipairs(FindAllOf("BP_Turret_C") or {}) do   -- test only: an object scan, once per call
        if valid(t) and t.Team ~= p.PlayerState.Team then target = t end
    end
    if not valid(target) then return "turret: none" end
    local l = target:K2_GetActorLocation()
    local dy = l.Y > 0 and -500 or 500
    p:K2_SetActorLocation({ X = l.X, Y = l.Y + dy, Z = l.Z + 100 }, false, {}, true)
    log(string.format("%8.2f   %s sent to the enemy turret", now(p), name))
    return "turret: " .. name
end

-- End the round as the developers' QA tool does (BP_AC_QATools EndRound): the winner, then the round-end celebration.
function P.endround(team)
    local gi = FindFirstOf("BP_MOBAInstance_C")
    local gs = gi and gi:GetWorld().GameState
    if not valid(gs) then return "endround: no game state" end
    local ok, err = pcall(function()
        gs:FlushNetDormancy()
        gs.WinningTeam = team
        gs:DoRoundEndCelebration(1, team, { X = 0, Y = 0, Z = 0 })
    end)
    log(string.format("%8.2f   round ended, team %d wins: %s", now(gs), team, ok and "ok" or tostring(err)))
    return "endround: " .. (ok and "ok" or tostring(err))
end

-- Client: put an item in a slot of the augment screen and lock in, as a player does (docs/recon/items.md).
-- slot: 1 artifact, 2 combat heirloom, 3 utility, 4 flex, 5 ultimate, 6 boon.
function P.lockin(itemPath, slot)
    local gi = FindFirstOf("BP_MOBAInstance_C")
    GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local pc = GPS:GetPlayerController(gi, 0)
    if not valid(pc) then return "lockin: no controller" end
    local item = StaticFindObject(itemPath)
    if not valid(item) then
        KSL = KSL or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        pcall(function() KSL:LoadAsset_Blocking(KSL:Conv_SoftObjPathToSoftObjRef(KSL:MakeSoftObjectPath(itemPath))) end)
        item = StaticFindObject(itemPath)
    end
    local ok, err = pcall(function()
        local hud = pc.WB_HUDGamplayRef
        local s = hud.PreRoundSelection["PlayerItem" .. slot]
        hud.SelectedSlot = s
        s:SetItem(item, true)
        pc.PlayerState:ReportetFinishedItemSelectOnServer(false)
        pc:PlayerLockedIn()
    end)
    return "lockin " .. tostring(valid(item) and item:GetFName():ToString() or itemPath) .. ": " .. (ok and "ok" or tostring(err))
end

-- What this process loaded: the passives' ActivationBlockedTags (the community-passives patch sets Ability.Passive).
function P.cdo()
    local out = {}
    for _, path in ipairs({
        "/Game/Gameplay/Abilities/Player/Gunslinger/Passive/BP_GA_Gunslinger_P.Default__BP_GA_Gunslinger_P_C",
        "/Game/Gameplay/Abilities/Player/Lancer/P/GA_Lancer_P.Default__GA_Lancer_P_C" }) do
        local o = StaticFindObject(path)
        local tags = {}
        if valid(o) then
            pcall(function() o.ActivationBlockedTags.GameplayTags:ForEach(function(_, t) tags[#tags + 1] = t:get().TagName:ToString() end) end)
        end
        out[#out + 1] = path:match("Default__(.-)_C$") .. "=[" .. (valid(o) and table.concat(tags, ",") or "not loaded") .. "]"
    end
    local s = table.concat(out, " ")
    log("         -- blocked tags: " .. s)
    return "cdo: " .. s
end

return "test_passives helpers"
