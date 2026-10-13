-- FangsCtl: remote control for (headless) FANGS instances.
-- Appends to <Win64>/fangsctl_cmd.txt are executed in order on the game thread:
--   <console command>      run as if typed into the local player's console
--   lua <code>             run Lua (UE4SS API available)
-- Output goes to UE4SS.log, prefixed with [fangsctl].
local UEHelpers = require("UEHelpers")
local CMD_FILE = "fangsctl_cmd.txt"
local done = 0

local function log(msg) print("[fangsctl] " .. tostring(msg) .. "\n") end

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

LoopAsync(500, function()
    local f = io.open(CMD_FILE, "r")
    if not f then return false end
    local lines = {}
    for l in f:lines() do lines[#lines + 1] = l end
    f:close()
    for i = done + 1, #lines do
        local line = lines[i]
        if line ~= "" then ExecuteInGameThread(function() run(line) end) end
    end
    done = #lines
    return false
end)

log("loaded")
