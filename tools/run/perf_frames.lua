-- Per-frame timing for a FANGS game server; tools/run/test_perf.sh loads it through FangsCtl
-- ("lua dofile('perf_frames.lua')"). Test use only: it calls GetFrameCount on every run of a 1 ms game-thread
-- loop, so it costs the server a little.
--
-- The loop runs at most once per millisecond, whenever the game thread executes a UFunction/Blueprint event, so:
--   frame time = time between the first runs of two consecutive frames (GetFrameCount changes);
--   gap        = time between two runs = time the game thread ran no event at all (a long native step: GC,
--                physics, net, a blocking wait - or the idle sleep between capped frames).
-- perf_frames.log next to the exe (os.clock() = seconds since process start, os.time() = Unix seconds):
--   S <clock> <time> <frames> <fps> <longest frame ms> <longest gap ms> <frames >33> <>50> <>100> <>200> <runs>
--   F <clock> <frame ms> <longest gap in it ms> <frame number>     every frame over 40 ms
if PERF_FRAMES then return "perf_frames: already running" end
local K = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
local out = io.open("perf_frames.log", "a")
local clock, fmt = os.clock, string.format

local lastFrame = K:GetFrameCount()
local frameStart = clock()     -- first run seen in the current frame
local lastRun = frameStart
local gapInFrame = 0
local sec = { t = frameStart, frames = lastFrame, maxFrame = 0, maxGap = 0, n33 = 0, n50 = 0, n100 = 0, n200 = 0, runs = 0 }

local function tick()
    local t = clock()
    local gap = t - lastRun
    lastRun = t
    sec.runs = sec.runs + 1
    if gap > sec.maxGap then sec.maxGap = gap end
    local frame = K:GetFrameCount()
    if frame ~= lastFrame then
        -- the previous frame(s) ended: time since the first run of the last frame we saw
        local ft = (t - frameStart) / (frame - lastFrame)
        if gap > gapInFrame then gapInFrame = gap end
        if ft > sec.maxFrame then sec.maxFrame = ft end
        if ft > 0.0333 then sec.n33 = sec.n33 + 1 end
        if ft > 0.050 then sec.n50 = sec.n50 + 1 end
        if ft > 0.100 then sec.n100 = sec.n100 + 1 end
        if ft > 0.200 then sec.n200 = sec.n200 + 1 end
        if ft > 0.040 then out:write(fmt("F %.3f %.0f %.0f %d\n", t, ft * 1000, gapInFrame * 1000, frame)); out:flush() end
        lastFrame, frameStart, gapInFrame = frame, t, 0
    elseif gap > gapInFrame then
        gapInFrame = gap
    end
    if t - sec.t >= 1.0 then
        local n = frame - sec.frames
        out:write(fmt("S %.3f %d %d %.1f %.0f %.0f %d %d %d %d %d\n", t, os.time(), n, n / (t - sec.t), sec.maxFrame * 1000,
            sec.maxGap * 1000, sec.n33, sec.n50, sec.n100, sec.n200, sec.runs))
        out:flush()
        sec = { t = t, frames = frame, maxFrame = 0, maxGap = 0, n33 = 0, n50 = 0, n100 = 0, n200 = 0, runs = 0 }
    end
end

PERF_FRAMES = LoopInGameThreadWithDelay(1, function()
    local ok, err = pcall(tick)
    if not ok and out then out:write("E " .. tostring(err) .. "\n"); out:flush() end
end)
return "perf_frames: started"
