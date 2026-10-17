-- FangsHost: the community patch's game-mode changes (a community member's list, 16 Oct 2026; docs/recon/community-build-modes.md),
-- loaded by main.lua (Feb 2023 build). Everything here runs on the game server.
--   * Training (TRAINING tile, custom Solo lobbies): the augment phase lasts until the player presses F6 (FangsBoot sends
--     it), lock-in and P work in it, the player can take damage in it, and the dummies stay after the round starts.
--   * Wylde gets a full gun when the dummy phase starts; Bounty's Reward stacks earned on dummies go when they do.
--   * Presets: the in-match preset panel loads and saves through server CloudSave calls compiled out of this build.
--   * Base blockers (blockers.lua, also in FangsBoot): leave your base and you can't walk back in, as in Aug 2022.
return function(env)
    local log, every, readRecord, hook, later, gameInstance, gameState = env.log, env.every, env.readRecord, env.hook,
        env.later, env.gameInstance, env.gameState
    local GSB = "/Game/BluePrints/Gameplay/GS_MOBA_Battle.GS_MOBA_Battle_C"
    local PCM = "/Game/BluePrints/Gameplay/BP_PC_MOBA_PlayerController.BP_PC_MOBA_PlayerController_C"
    local placeBlockers = require("blockers")(log)
    local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
    local function str(p) local ok, v = pcall(function() return p:get():ToString() end); return ok and v or "" end

    -- TRAINING (MapGameMode 0) or a custom (4) lobby launched with one player
    local function solo()
        local gi = gameInstance()
        if not valid(gi) then return false end
        return gi.MapGameMode == 0 or (gi.MapGameMode == 4 and gi.MapPlayerCount == 1)
    end
    local function pawns(gs)
        local out = {}
        pcall(function()
            gs.PlayerArray:ForEach(function(_, e)
                local ps = e:get()
                if valid(ps) and valid(ps.PawnPrivate) then out[#out + 1] = ps.PawnPrivate end
            end)
        end)
        return out
    end
    local GPS = nil
    local function withTag(context, tag)   -- the world's actor list (GetAllActorsWithTag), not an object scan
        GPS = GPS or StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local res, out = {}, {}
        GPS:GetAllActorsWithTag(context, FName(tag), res)
        local list = res.OutActors
        if list == nil and res[1] ~= nil then list = res end
        local function add(o)
            if not valid(o) then pcall(function() o = o:get() end) end
            if valid(o) then out[#out + 1] = o end
        end
        if type(list) == "table" then for _, o in pairs(list) do add(o) end
        elseif list ~= nil then pcall(function() list:ForEach(function(_, e) add(e) end) end) end
        return out
    end
    local function className(o) local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end); return ok and n or "" end

    -- -------------------------------------------------------------------------------- Training: the augment phase
    -- The phase ends when CanSkipItemSelect (GS_MOBA_Battle, called every tick) is true: (time > max OR everyone locked
    -- in) AND ItemSelectStartTime > 0. The max time goes to 5999 s (the HUD's timer doesn't run out), and a post-hook on
    -- the lock-in RPC (MOBAPlayerState.ServerSetFinishedItemSelect, native) clears the player's bSelectedItems again in
    -- the same frame: the phase stays open through lock-in and P. F6 sets everyone's bSelectedItems, and the game ends
    -- the phase. (ItemSelectStartTime must stay as the game set it: at 0 or below the game ends the phase at once.)
    -- OFF until a lock-in can be kept from ending the phase (docs/recon/community-build-modes.md): with the hold on, the
    -- timer never runs out, but a lock-in still ends the phase (the RPC's native code sets a game-state flag at 0x621).
    local HOLD_PHASE = false
    local HOLD_MAX = 5999.0
    local phase = { holding = false, requested = false, gs = nil }
    local COUNTDOWN, ROUND = 7, 8   -- ENUM_RoundEvent CountDownStart, RoundStart_CoundownEnd (replicated round event)
    every(200, function()
        if not phase.holding then return end
        local gs = phase.gs
        if not valid(gs) then phase.holding = false; return end
        local ev = gs.CurrentRoundEvent
        if ev == COUNTDOWN or ev == ROUND then   -- the phase is over: the next round's pre-round holds again
            phase.holding = false
            gs.ItemSelectFirstRoundMaxTime, gs.ItemSelectMaxTime = HOLD_MAX, HOLD_MAX
            return
        end
    end)
    local keptLog = 0
    local function keepOpen(ps)   -- the lock-in RPC's post-hook: the phase stays open
        if not phase.holding or phase.requested or not valid(ps) then return end
        ps.bSelectedItems = false
        keptLog = keptLog + 1
        if keptLog <= 3 then log("training: lock-in kept the augment phase open") end
    end
    local function startRound(pc)
        local gs = phase.gs
        if not (phase.holding and valid(gs)) or phase.requested then return log("training: F6 outside the augment phase") end
        phase.requested = true
        pcall(function() gs.PlayerArray:ForEach(function(_, e) local ps = e:get(); if valid(ps) then ps.bSelectedItems = true end end) end)
        log("training: F6 - the round starts")
    end

    -- Training: hits count during the augment phase. The game gives every hero BP_GE_Immunity_All for it, which also
    -- carries the tag that lets abilities be used then (Effect.PreRoundUnlocked): swap it for an empty effect with
    -- that tag (the round start removes it like the game's own: RemoveActiveEffectsWithGrantedTags).
    local IMMUNITY = "/Game/Gameplay/Effects/Shared/BP_GE_Immunity_All.BP_GE_Immunity_All_C"
    local EMPTY = "/Game/Gameplay/Effects/Shared/BP_GE_EmptyDuration.BP_GE_EmptyDuration_C"
    local FL = "/Game/BluePrints/Library/BP_FL_MOBA_FunctionLibrary.Default__BP_FL_MOBA_FunctionLibrary_C"
    local AFL = "/Game/BluePrints/Library/BP_FL_MOBA_AbilitySystemFunctionLibrary.Default__BP_FL_MOBA_AbilitySystemFunctionLibrary_C"
    local function vulnerable(gs)
        local imm, empty = StaticFindObject(IMMUNITY), StaticFindObject(EMPTY)
        local fl, afl = StaticFindObject(FL), StaticFindObject(AFL)
        local asbl = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
        if not (valid(imm) and valid(empty) and valid(fl) and valid(afl) and valid(asbl)) then
            return log("training: immunity swap skipped (classes not loaded)")
        end
        for _, p in ipairs(pawns(gs)) do
            local ok, err = pcall(function()
                local asc = p.AbilitySystemComponent
                asc:RemoveActiveGameplayEffectBySourceEffect(imm, nil, -1)
                local spec = afl:SetSpecDuration(fl:MakeEffectSpec(p, empty, gs), 0.0, gs)
                spec = asbl:AddGrantedTag(spec, { TagName = FName("Effect.PreRoundUnlocked") })
                afl:ApplyEffectSpecToTarget(p, p, spec, gs)
            end)
            log("training: no augment-phase immunity for " .. p:GetFName():ToString() .. (ok and "" or (" - failed: " .. tostring(err))))
        end
    end

    -- Training: the dummies spawned for the augment phase (arena maps) stay after the round starts. The game destroys
    -- the actors tagged PreroundDummy at the round start: re-tag them, and replace the previous round's at the next spawn.
    local KEPT = "FangsKeptDummy"
    local kept = {}
    local function keepDummies(gs)
        for _, d in ipairs(kept) do if valid(d) then pcall(function() d:K2_DestroyActor() end) end end
        kept = {}
        for _, d in ipairs(withTag(gs, "PreroundDummy")) do
            pcall(function() d.Tags[1] = FName(KEPT) end)
            kept[#kept + 1] = d
        end
        log(string.format("training: %d dummies kept for the round", #kept))
    end

    -- -------------------------------------------------------------------------------- Wylde in the dummy phase
    -- His gun is loaded only when the round countdown ends (BP_GA_Gunslinger_P.ForceReloadRoundStart): load it when the
    -- dummies appear. Bounty's Reward (Fan the Hammers hits) stacks for the whole game: drop what was earned on dummies.
    local STACK = "/Game/Gameplay/Abilities/Player/Gunslinger/E/Items/BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack.BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack_C"
    local APPLIED = "/Game/Gameplay/Abilities/Player/Gunslinger/E/Items/BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseApplied.BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseApplied_C"
    local wylde = {}   -- pawn address -> { stacks, applied } at the dummies' spawn
    local function count(asc, path)
        local c = StaticFindObject(path)
        if not valid(c) then return 0, nil end
        local ok, n = pcall(function() return asc:GetGameplayEffectCount(c, nil, true) end)
        return ok and n or 0, c
    end
    local function wyldeLoad(gs)
        wylde = {}
        for _, p in ipairs(pawns(gs)) do
            if className(p) == "BP_Gunslinger_Char_C" then
                local ok, err = pcall(function()
                    local max = p["Modified MaxBullets"]
                    p["Add Loaded Bullets"](p, max)
                    p:SetUIAmmoMaxStacksOverride(max)
                    local asc = p.AbilitySystemComponent
                    wylde[p:GetAddress()] = { stacks = (count(asc, STACK)), applied = (count(asc, APPLIED)) > 0 }
                end)
                log("wylde: gun loaded for the dummy phase" .. (ok and "" or (" - failed: " .. tostring(err))))
            end
        end
    end
    local function wyldeUndo(gs)
        for _, p in ipairs(pawns(gs)) do
            local before = wylde[p:GetAddress()]
            if before then
                local ok, err = pcall(function()
                    local asc = p.AbilitySystemComponent
                    local now, stackClass = count(asc, STACK)
                    local gained = now - before.stacks
                    if gained > 0 then asc:RemoveActiveGameplayEffectBySourceEffect(stackClass, nil, gained) end
                    local applied, appliedClass = count(asc, APPLIED)
                    if applied > 0 and not before.applied then   -- the bonus bullet was earned on dummies: take it back
                        asc:RemoveActiveGameplayEffectBySourceEffect(appliedClass, nil, -1)
                        p["Modified MaxBullets"] = p["Modified MaxBullets"] - 1
                        p["Base Max Bullets"] = p["Base Max Bullets"] - 1
                        p:SetUIAmmoMaxStacksOverride(p["Modified MaxBullets"])
                    end
                    log(string.format("wylde: %d Bounty's Reward stacks from dummies removed%s", math.max(gained, 0),
                        (applied > 0 and not before.applied) and ", and its bonus bullet" or ""))
                end)
                if not ok then log("wylde: undo failed: " .. tostring(err)) end
            end
        end
        wylde = {}
    end

    -- -------------------------------------------------------------------------------- presets
    -- WB_LoadoutPresets asks the server (GetHeroLoadouts, SaveHeroLoadouts: server RPCs) and the server asks CloudSave
    -- (ServerRetrievePlayerRecord, ServerAddOrReplacePlayerRecord: compiled-out stubs here), so the panel never got its
    -- presets and saving fell back to standard build 1. Serve PROFILE_LOADOUT_KEY from the backend's exported records;
    -- hand a saved one to the backend as fangshost_loadout-<uid>-<n>.json (backend/hosts.py collects it).
    local saves = 0
    local function uidOf(pc)
        local ok, id = pcall(function() return pc.PCPlayfabId:ToString() end)
        id = ok and id or ""
        return id:match("^%x+$") and #id == 32 and id or nil   -- sent by the client: never a path
    end

    every(2000, function()
        local done = true
        done = hook(GSB .. ":PreRoundInvulAndSpawnTrapping", function(ctx)
            local gs = ctx:get()
            if not solo() then return end
            if HOLD_PHASE then
                phase.holding, phase.requested, phase.gs, keptLog = true, false, gs, 0
                gs.ItemSelectFirstRoundMaxTime, gs.ItemSelectMaxTime = HOLD_MAX, HOLD_MAX
                log("training: augment phase held until F6")
            end
            later(function() vulnerable(gs) end)
        end) and done
        done = hook("/Script/MOBA.MOBAPlayerState:ServerSetFinishedItemSelect", function(ctx) keepOpen(ctx:get()) end) and done
        done = hook(GSB .. ":Spawn Preround Dummies", function(ctx)
            local gs = ctx:get()
            later(function()
                wyldeLoad(gs)
                if solo() then keepDummies(gs) end
            end)
        end) and done
        done = hook(GSB .. ":Destroy Preround Dummies", function(ctx)
            local gs = ctx:get()
            later(function() wyldeUndo(gs) end)
        end) and done
        done = hook(PCM .. ":DebugSpawnBot", function(ctx, rowName)   -- a no-op RPC in Shipping builds: our F6 channel
            local ok, row = pcall(function() return rowName:get():ToString() end)
            if ok and row == "FangsStartRound" and solo() then startRound(ctx:get()) end
        end) and done
        done = hook(PCM .. ":GetHeroLoadouts", function(ctx)
            local pc = ctx:get()
            local uid = uidOf(pc)
            if not uid then return log("presets: no valid player id") end
            local json = readRecord("players/" .. uid .. "/PROFILE_LOADOUT_KEY") or ""
            later(function()
                if valid(pc) then pc:ControllerUpdateLoadouts(json); log("presets: served " .. uid .. " (" .. #json .. " bytes)") end
            end)
        end) and done
        done = hook(PCM .. ":SaveHeroLoadouts", function(ctx, loadouts)
            local pc, text = ctx:get(), str(loadouts)
            local uid = uidOf(pc)
            if not uid or text:sub(1, 1) ~= "{" or #text > 65536 then return log("presets: save refused") end
            saves = saves + 1
            local name = string.format("fangshost_loadout-%s-%d%03d.json", uid, os.time(), saves % 1000)
            local f = io.open(name .. ".tmp", "w")
            if not f then return log("presets: can't write " .. name) end
            f:write(text); f:close(); os.rename(name .. ".tmp", name)
            log("presets: saved " .. uid .. " (" .. #text .. " bytes)")
            later(function() if valid(pc) then pc:ControllerSavedLoadouts(true) end end)
        end) and done
        return done
    end)

    -- -------------------------------------------------------------------------------- arena start
    local blockersOn = nil   -- the address of the arena game state whose map got blockers
    RegisterBeginPlayPreHook(function(ctx)
        local gs = ctx:get()
        if not valid(gs) or not className(gs):find("^GS_MOBA_Battle") then return end   -- and its per-map subclasses
        local map = gs:GetFullName():match("Maps/([%w_]+)%.") or "?"
        blockersOn = nil
        ExecuteInGameThreadWithDelay(200, function()
            local ok, n = pcall(placeBlockers, gs, map)
            if not ok then log("base blockers: " .. tostring(n)) elseif n > 0 then blockersOn = gs:GetAddress() end
        end)
    end)

    -- Base blockers' safety net (docs/recon/base-blockers.md). A hero who spawns in a base gets spawn protection
    -- (BP_AC_SpawnBlocker.ApplyImmunity: BP_GE_Immunity_All, no end, Effect.SpawnBlocker, Systems.Input.LockAbilities);
    -- the game takes it off when the hero is seen leaving the blocker (OnActorEndOverlap) and at round start. Once a
    -- second, a hero who still has it while touching none of the map's blockers gets the component's own
    -- BlockSpawnServer (here) and BlockSpawnClient (on its player): protection off, the way back blocked, as if it had
    -- walked out. No object scans: GameState.PlayerArray and the component's own blocker list.
    local SPAWN_TAG, released = nil, 0
    every(1000, function()
        if not blockersOn then return end
        local gs = gameState()
        if not valid(gs) or gs:GetAddress() ~= blockersOn then return end
        SPAWN_TAG = SPAWN_TAG or { TagName = FName("Effect.SpawnBlocker") }
        for _, p in ipairs(pawns(gs)) do
            pcall(function()
                if not p.AbilitySystemComponent:HasMatchingGameplayTag(SPAWN_TAG) then return end
                local comp = p.BP_AC_SpawnBlocker
                if not valid(comp) then return end
                local inside, known = false, 0
                comp.SpawnBlockers:ForEach(function(_, e)
                    local b = e:get()
                    if valid(b) then
                        known = known + 1
                        if p:IsOverlappingActor(b) then inside = true end
                    end
                end)
                if inside or known == 0 then return end   -- no list (its component started before the blockers): leave it
                comp:BlockSpawnServer()
                comp:BlockSpawnClient()
                released = released + 1
                if released <= 20 then log("base blockers: released " .. p:GetFName():ToString() .. " (protected outside its base)") end
            end)
        end
    end)
end
