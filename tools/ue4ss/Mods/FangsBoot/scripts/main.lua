-- FangsBoot: get a FANGS client from boot to logged-in without the dead Epic/Steam services.
--  * skips the intro logo movie (it otherwise waits for a key press)
--  * with -TestUser=<name> -TestPass=<pw> on the command line, reports Epic login as successful so the
--    game falls through to its built-in AccelByte username login (served by our backend).
local UEHelpers = require("UEHelpers")
local function log(msg) print("[fangsboot] " .. tostring(msg) .. "\n") end

local function commandLine()
    local ok, cl = pcall(function() return UEHelpers.GetKismetSystemLibrary():GetCommandLine():ToString() end)
    return ok and cl or ""
end

local logoDone, loginDone = false, false
LoopAsync(500, function()
    ExecuteInGameThread(function()
        local gi = FindFirstOf("BP_MOBAInstance_C")
        if not gi or not gi:IsValid() then return end
        if not logoDone then
            local logo = gi.WB_LogoRef
            if logo and logo:IsValid() and logo:IsInViewport() and logo.bCanSkip then
                logo:EndMovie(); logoDone = true; log("skipped logo movie")
            end
        end
        if not loginDone then
            local menu = nil
            for _, w in ipairs(FindAllOf("WB_AccountMenu_C") or {}) do
                if w:IsValid() and not w:GetFullName():find("Default__", 1, true) then menu = w end
            end
            if menu then
                loginDone = true
                if commandLine():find("-TestUser=", 1, true) then
                    menu:OnEOSLoginDone(true, ""); log("faked EOS login -> username login")
                else
                    log("no -TestUser on command line; leaving login to the account menu")
                end
            end
        end
    end)
    return logoDone and loginDone
end)
log("loaded")
