-- FangsCtl: remote control for (headless) FANGS instances.
-- Appends to <Win64>/fangsctl_cmd.txt are executed in order on the game thread:
--   <console command>      run as if typed into the local player's console
--   lua <code>             run Lua (UE4SS API available)
-- Output goes to UE4SS.log, prefixed with [fangsctl].
local UEHelpers = require("UEHelpers")
local CMD_FILE = "fangsctl_cmd.txt"
local done = 0

-- UE4SS.log is buffered (not readable live); also keep our own line-flushed log next to the exe
local logFile = io.open("fangsctl.log", "a")
local function log(msg)
    print("[fangsctl] " .. tostring(msg) .. "\n")
    if logFile then logFile:write(os.date("!%Y-%m-%d %H:%M:%S ") .. tostring(msg) .. "\n"); logFile:flush() end
end

-- Runs fn on the game thread every `ms` milliseconds until it returns true. (LoopAsync + ExecuteInGameThread
-- ran Lua on two threads at once, which now and then crashed the game inside UE4SS's Lua VM: exit code 3.)
local function every(ms, fn)
    local handle, failures = nil, 0
    handle = LoopInGameThreadWithDelay(ms, function()
        local ok, done = pcall(fn)   -- an error must not end the loop (objects vanish during map changes)
        if not ok then
            failures = failures + 1
            if failures <= 3 then log("loop error (" .. ms .. " ms loop): " .. tostring(done)) end
        elseif done == true and handle and IsValidDelayedActionHandle(handle) then
            CancelDelayedAction(handle)
        end
    end)
    return handle
end

local function run(line)
    if line:sub(1, 4) == "lua " then
        local chunk, err = load(line:sub(5))
        if not chunk then return log("lua compile error: " .. tostring(err)) end
        local ok, res = pcall(chunk)
        log("lua " .. (ok and "ok" or "error") .. ": " .. tostring(res))
    else
        local pc = UEHelpers.GetPlayerController()
        if not pc or not pc:IsValid() then return log("no player controller for: " .. line) end
        UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(pc, line, pc)
        log("exec: " .. line)
    end
end

every(500, function()
    local f = io.open(CMD_FILE, "r")
    if not f then return end
    local lines = {}
    for l in f:lines() do lines[#lines + 1] = l end
    f:close()
    for i = done + 1, #lines do
        local line = lines[i]
        if line ~= "" then run(line) end
    end
    done = #lines
end)

log("loaded")
