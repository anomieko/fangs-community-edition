-- Test client: press and hold Space (ability key 3) for HOLD ms every EVERY ms, as a player charging a dash does
-- (Tufts' Wing Dive is a charged dash). tools/run/test_perf.sh loads it with DASH=1.
if NET_DASH then return "net_dash: already running" end
local EVERY, HOLD = 2500, 500
local GPS = StaticFindObject("/Script/Engine.Default__GameplayStatics")
local gi = FindFirstOf("BP_MOBAInstance_C")
NET_DASH = LoopInGameThreadWithDelay(EVERY, function()
    pcall(function()
        local p = GPS:GetPlayerController(gi, 0).Pawn
        if not (p and p:IsValid()) then return end
        p.BP_AC_InputManager:QueueInput(3, true)
        ExecuteInGameThreadWithDelay(HOLD, function() pcall(function() if p:IsValid() then p.BP_AC_InputManager:QueueInput(3, false) end end) end)
    end)
end)
return "net_dash: started"
