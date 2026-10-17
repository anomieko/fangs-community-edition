-- Rubber-band counter for a test client (tools/run/test_perf.sh loads it with FangsCtl: lua dofile("net_snaps.lua")).
-- Every frame it compares where each hero is with where its velocity said it would be:
--   own hero: the actor's position. A local player's movement is predicted, so a jump here is a correction from the
--     game server (the server snapping this player back): what the player feels as rubber-banding;
--   other heroes: their mesh, i.e. what this player sees of them after the game's smoothing. A jump here is another
--     player "teleporting" on this screen.
-- error = |position - (last position + mean velocity x frame time)| in the horizontal plane (jumps and falls don't
-- count). Over TELEPORT units is a respawn or a blink, counted apart.
-- net_snaps.log next to the exe, one line per second:
--   S <unix time> <frames> <own >20> <own >50> <own >100> <own teleports> <others >80> <others teleports> <own max error>
if NET_SNAPS then return "net_snaps: already running" end
local GPS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local out = io.open("net_snaps.log", "a")
local TELEPORT, OTHER = 800, 80
local fmt, sqrt = string.format, math.sqrt
local gi = FindFirstOf("BP_MOBAInstance_C")
local last = {}                 -- actor address -> { x, y, vx, vy }
local others, nextRefresh = {}, 0
local lastT
local sec = { t = os.clock(), frames = 0, o20 = 0, o50 = 0, o100 = 0, otele = 0, r80 = 0, rtele = 0, omax = 0 }

local function valid(o) return o ~= nil and o:IsValid() end

local function err(key, x, y, vx, vy, dt)
    local l = last[key]
    last[key] = { x, y, vx, vy }
    if not l then return nil end
    local ex = l[1] + (l[3] + vx) * 0.5 * dt
    local ey = l[2] + (l[4] + vy) * 0.5 * dt
    return sqrt((x - ex) ^ 2 + (y - ey) ^ 2)
end

local function tick()
    local pc = GPS:GetPlayerController(gi, 0)
    if not valid(pc) then return end
    local t = GPS:GetTimeSeconds(pc)
    if lastT == nil or t <= lastT then lastT = lastT or t; return end   -- once per frame
    local dt = t - lastT
    lastT = t
    sec.frames = sec.frames + 1
    local me = pc.Pawn
    if valid(me) then
        local p, v = me:K2_GetActorLocation(), me:GetVelocity()
        local e = err("me", p.X, p.Y, v.X, v.Y, dt)
        if e then
            if e > TELEPORT then sec.otele = sec.otele + 1
            else
                if e > 20 then sec.o20 = sec.o20 + 1 end
                if e > 50 then sec.o50 = sec.o50 + 1 end
                if e > 100 then sec.o100 = sec.o100 + 1 end
                if e > sec.omax then sec.omax = e end
            end
        end
    end
    if os.clock() >= nextRefresh then   -- the other heroes (an object scan: every 10 s only)
        nextRefresh = os.clock() + 10
        others = {}
        for _, h in ipairs(FindAllOf("BP_PlayerChar_C") or {}) do
            if valid(h) and not h:GetFullName():find("Default__", 1, true) and h:GetAddress() ~= (valid(me) and me:GetAddress() or 0) then
                others[#others + 1] = h
            end
        end
    end
    for _, h in ipairs(others) do
        if valid(h) and valid(h.Mesh) then
            local p, v = h.Mesh:K2_GetComponentLocation(), h:GetVelocity()
            local e = err(h:GetAddress(), p.X, p.Y, v.X, v.Y, dt)
            if e then
                if e > TELEPORT then sec.rtele = sec.rtele + 1 elseif e > OTHER then sec.r80 = sec.r80 + 1 end
            end
        end
    end
    if os.clock() - sec.t >= 1.0 then
        out:write(fmt("S %d %d %d %d %d %d %d %d %.0f\n", os.time(), sec.frames, sec.o20, sec.o50, sec.o100, sec.otele,
            sec.r80, sec.rtele, sec.omax))
        out:flush()
        sec = { t = os.clock(), frames = 0, o20 = 0, o50 = 0, o100 = 0, otele = 0, r80 = 0, rtele = 0, omax = 0 }
    end
end

NET_SNAPS = LoopInGameThreadWithDelay(2, function()
    local ok, e = pcall(tick)
    if not ok and out then out:write("E " .. tostring(e) .. "\n"); out:flush() end
end)
return "net_snaps: started"
