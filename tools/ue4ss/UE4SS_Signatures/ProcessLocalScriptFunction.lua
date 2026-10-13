-- UE4SS can't find UObject::ProcessLocalScriptFunction in this FANGS Development build by itself,
-- which disables Blueprint-function hooks (RegisterHook on /Game/... functions).
-- Pattern = prologue of the function at 0x142d5e4f0 in playtest main_v0_0_444 (contains the
-- "Infinite script recursion" guard); verified unique in .text.
function Register()
    return "40 55 53 56 57 41 57 48 8D AC 24 80 FE FF FF 48 81 EC 80 02 00 00 48 8B 05 ?? ?? ?? ?? 48 33 C4 48 89 85 60 01 00 00 48"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
