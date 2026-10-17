-- Helpers for tools/run/test_modes.sh (docs/recon/community-build-modes.md), loaded by FangsCtl (dofile) into the
-- client and the game server. Each returns one line for the test's log.
--   where()        both: map, game mode, players
--   phase()        server: the augment phase (ItemSelectStartTime 0 = held), the round state
--   hero()         both: each hero's augment-phase immunity, Effect.PreRoundUnlocked, health, Wylde's ammo, and its
--                  capsule's response to the base blockers' channel (GameTraceChannel12: 1 overlap, 2 block)
--   lockin()       client: lock in, as the button does
--   reopen()       client: P (WB_PreRoundSelection.ShowAugmentSelectAgain)
--   f6()           client: what FangsBoot's F6 sends
--   dummies()      both: dummies by tag, and training dummies (BP_AI_FireMage_C) alive
--   blockers()     both: BP_SpawnBlocker actors and their places
--   leave()        server: the hero teleported out of its base, towards the middle
--   enter()        server: the hero swept back towards its spawn: where it stops
--   save(json)     client: the preset panel's save (SaveHeroLoadouts)
FCE_MODES = FCE_MODES or {}
local T = FCE_MODES

local function valid(o) return type(o) == "userdata" and o.IsValid ~= nil and o:IsValid() end
local function gi() return FindFirstOf("BP_MOBAInstance_C") end
local function world() return gi():GetWorld() end
local function gs() return world().GameState end
local function f(v) return type(v) == "number" and string.format("%.1f", v) or tostring(v) end
local GPS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local function localPC() return GPS:GetPlayerController(gi(), 0) end
local function pawns()
    local out = {}
    gs().PlayerArray:ForEach(function(_, e)
        local ps = e:get()
        if valid(ps) and valid(ps.PawnPrivate) then out[#out + 1] = ps.PawnPrivate end
    end)
    return out
end
local function count(asc, path)
    local c = StaticFindObject(path)
    if not valid(c) then return "-" end
    return asc:GetGameplayEffectCount(c, nil, true)
end

function T.where()
    local g = gs()
    local n = 0
    g.PlayerArray:ForEach(function() n = n + 1 end)
    return string.format("map=%s gs=%s mode=%s playercount=%s players=%d", world():GetFullName():match("Maps/([%w_]+)") or "?",
        g:GetClass():GetFName():ToString(), f(gi().MapGameMode), f(gi().MapPlayerCount), n)
end

function T.phase()
    local g = gs()
    local okA, at = pcall(function() return g:IsAtItemSelection() end)
    return string.format("ItemSelectStartTime=%s firstMax=%s max=%s atItemSelection=%s round=%s", f(g.ItemSelectStartTime),
        f(g.ItemSelectFirstRoundMaxTime), f(g.ItemSelectMaxTime), okA and tostring(at) or "?", f(g.CurrentRound))
end

function T.hero()
    local out = {}
    for _, p in ipairs(pawns()) do
        local asc = p.AbilitySystemComponent
        local unlocked = asc:HasMatchingGameplayTag({ TagName = FName("Effect.PreRoundUnlocked") })
        local imm = count(asc, "/Game/Gameplay/Effects/Shared/BP_GE_Immunity_All.BP_GE_Immunity_All_C")
        local ammo = count(asc, "/Game/Gameplay/Abilities/Player/Gunslinger/Passive/BP_GE_Gunslinger_P_Bullets.BP_GE_Gunslinger_P_Bullets_C")
        local bounty = count(asc, "/Game/Gameplay/Abilities/Player/Gunslinger/E/Items/BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack.BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack_C")
        local okC, resp = pcall(function() return p.CapsuleComponent:GetCollisionResponseToChannel(25) end)
        local l = p:K2_GetActorLocation()
        out[#out + 1] = string.format("%s immunity=%s unlocked=%s health=%s ammo=%s bounty=%s blockerchannel=%s at=(%.0f,%.0f)",
            p:GetClass():GetFName():ToString(), f(imm), tostring(unlocked), f(p:GetHealth()), f(ammo), f(bounty),
            okC and f(resp) or "?", l.X, l.Y)
    end
    return table.concat(out, " | ")
end

function T.lockin()
    local pc = localPC()
    pc.PlayerState:ReportetFinishedItemSelectOnServer(false)
    pcall(function() pc:PlayerLockedIn() end)
    return "locked in"
end

function T.reopen()
    local pre = localPC().WB_HUDGamplayRef.PreRoundSelection
    pre:ShowAugmentSelectAgain()
    return "P: augment select again"
end

function T.f6()
    localPC():DebugSpawnBot(FName("FangsStartRound"), 0)
    return "F6 sent"
end

local function tagged(tag)
    local res = {}
    GPS:GetAllActorsWithTag(gs(), FName(tag), res)
    local n = 0
    local list = res.OutActors or res
    pcall(function() list:ForEach(function() n = n + 1 end) end)
    if n == 0 and type(list) == "table" then for _ in pairs(list) do n = n + 1 end end
    return n
end
function T.dummies()
    local alive = 0
    for _, d in ipairs(FindAllOf("BP_AI_FireMage_C") or {}) do
        if valid(d) and not d:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) then alive = alive + 1 end
    end
    return string.format("PreroundDummy=%d FangsKeptDummy=%d training dummies alive=%d", tagged("PreroundDummy"),
        tagged("FangsKeptDummy"), alive)
end

function T.blockers()
    local out = {}
    for _, b in ipairs(FindAllOf("BP_SpawnBlocker_C") or {}) do
        if valid(b) then
            local l, s = b:K2_GetActorLocation(), b:GetActorScale3D()
            out[#out + 1] = string.format("(%.0f,%.0f,%.0f x%.1f)", l.X, l.Y, l.Z, s.X)
        end
    end
    return #out .. " blockers " .. table.concat(out, " ")
end

-- the hero's own base: the blocker nearest to it
local function base(p)
    local l, best, bd = p:K2_GetActorLocation(), nil, 1e12
    for _, b in ipairs(FindAllOf("BP_SpawnBlocker_C") or {}) do
        local c = b:K2_GetActorLocation()
        local d = (c.X - l.X) ^ 2 + (c.Y - l.Y) ^ 2
        if d < bd then best, bd = b, d end
    end
    return best
end
T.spawn = T.spawn or {}
function T.leave()
    local p = pawns()[1]
    local b = base(p)
    if not b then return "no blocker" end
    local l, c = p:K2_GetActorLocation(), b:K2_GetActorLocation()
    T.spawn = { X = l.X, Y = l.Y, Z = l.Z }
    local dir = c.Y > 0 and -1 or 1                 -- towards the middle of the map (y = 0)
    local r = 100 * b:GetActorScale3D().Y + 400       -- past the blocker's edge (meshes of radius 50 or 100)
    local dest = { X = c.X, Y = c.Y + dir * r, Z = l.Z }
    p:K2_SetActorLocation(dest, false, {}, true)
    return string.format("left the base: (%.0f,%.0f) -> (%.0f,%.0f)", l.X, l.Y, dest.X, dest.Y)
end
function T.enter()
    local p = pawns()[1]
    local from = p:K2_GetActorLocation()
    p:K2_SetActorLocation(T.spawn, true, {}, false)   -- sweep: stops at whatever blocks the capsule
    local l = p:K2_GetActorLocation()
    local moved = math.sqrt((l.X - from.X) ^ 2 + (l.Y - from.Y) ^ 2)
    local left = math.sqrt((l.X - T.spawn.X) ^ 2 + (l.Y - T.spawn.Y) ^ 2)
    return string.format("back towards the spawn: moved %.0f, %.0f short of it (%s)", moved, left,
        left > 100 and "blocked" or "got back in")
end

function T.save(json)
    localPC():SaveHeroLoadouts(json)
    return "preset saved (" .. #json .. " bytes)"
end
-- server: every 100 ms, log changes of the round event, the item-select fields and each player's lock-in (bSelectedItems)
-- to modeswatch.log in the game server's Win64 folder; also counts CanSkipItemSelect calls (a post-hook).
local EVENTS = { [0] = "None", "PreRoundStart", "PreRoundEnd", "ItemSelectStart", "ItemSelectEnd", "KingSelectStart",
                 "KingSelectEnd", "CountDownStart", "RoundStart_CoundownEnd", "KingSelected", "ObjectiveSelectStart" }
function T.watch()
    if T.watching then return "already watching" end
    T.watching, T.canskip = true, 0
    local logf = io.open("modeswatch.log", "a")
    local last = ""
    pcall(RegisterHook, "/Game/BluePrints/Gameplay/GS_MOBA_Battle.GS_MOBA_Battle_C:CanSkipItemSelect", function() T.canskip = T.canskip + 1 end)
    LoopInGameThreadWithDelay(100, function()
        local ok, line = pcall(function()
            local g = gs()
            if not (valid(g) and g:GetClass():GetFName():ToString():find("Battle")) then return "" end
            local sel = {}
            g.PlayerArray:ForEach(function(_, e) local ps = e:get(); sel[#sel + 1] = tostring(ps.bSelectedItems) end)
            local okA, at = pcall(function() return g:IsAtItemSelection() end)
            return string.format("event=%s start=%s first=%s max=%s at=%s selected=%s canskip>0=%s", EVENTS[g.CurrentRoundEvent] or f(g.CurrentRoundEvent),
                f(g.ItemSelectStartTime), f(g.ItemSelectFirstRoundMaxTime), f(g.ItemSelectMaxTime), okA and tostring(at) or "?",
                table.concat(sel, ","), tostring(T.canskip > 0))
        end)
        if ok and line ~= "" and line ~= last then
            last = line
            local t = 0
            pcall(function() t = GPS:GetTimeSeconds(gs()) end)
            logf:write(string.format("%8.2f %s\n", t, line)); logf:flush()
        end
    end)
    return "watching"
end
return "test_modes helpers"
