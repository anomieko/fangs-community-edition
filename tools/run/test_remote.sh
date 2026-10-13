#!/usr/bin/env bash
# End-to-end test against a REAL server (e.g. the VPS): one GPU-rendered headless client (gamescope +
# DXVK, no network namespace) logs in with the join code, creates a 2-slot custom lobby, launches alone,
# picks Lancer, locks in and must end up in the arena. Cleans up only its own processes.
# Usage: SERVER=<host:port> JOIN_CODE=<code> tools/run/test_remote.sh   (MODE=queue: press PLAY instead)
set -u
cd "$(dirname "$0")/../.."
REPO=$PWD; : "${SERVER:?SERVER=<host:port>}"; : "${JOIN_CODE:?JOIN_CODE=<code>}"
client=$(realpath "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}")
name=remotetest; inst=$REPO/work/run/remote; pfx=$REPO/work/run/remote.prefix
bin=$inst/MOBA/Binaries/Win64; A=$bin/fangsctl_cmd.txt; secret_file=$REPO/work/run/remote.secret
rm -rf "$inst" "$pfx"; cp -a --reflink=always "$client" "$inst"; cp -a --reflink=auto "$REPO/work/wine/prefix-gpu" "$pfx"
find "$inst/MOBA/Content/Movies" -name '*.mp4' -delete
"$REPO/player/install-player-files.sh" "$inst" "$SERVER" >/dev/null
cp -r "$REPO/tools/ue4ss/Mods/FangsCtl" "$bin/ue4ss/Mods/"; printf 'FangsCtl : 1\nFangsBoot : 1\n' > "$bin/ue4ss/Mods/mods.txt"; : > "$A"
cfg=$pfx/drive_c/users/$USER/AppData/Local/MOBA/Saved/Config/WindowsNoEditor
mkdir -p "$cfg" && cp "$inst/MOBA/Saved/Config/WindowsNoEditor/Engine.ini" "$cfg/"
[[ -f $secret_file ]] || python3 -c 'import secrets; print(secrets.token_hex(16))' > "$secret_file"

STATUS='lua local gs=FindFirstOf("GameStateBase"); local p=FindFirstOf("BP_PlayerChar_C");'\
' return "map=" .. (gs:GetFullName():match("Maps/([%w_]+)") or "?") .. " pawn=" .. (p and p:IsValid() and p:GetFName():ToString() or "none")'
AUG='lua local gi=FindFirstOf("BP_MOBAInstance_C"); local p=FindFirstOf("BP_PlayerChar_C");'\
' if not (p and p:IsValid()) then return "augments: no pawn" end local n, total, offered = -1, 0, 0'\
' pcall(function() local c=0 gi.AugmentRevDetailMap:ForEach(function() c=c+1 end) n=c end)'\
' p.PossibleItems:ForEach(function(_, e) total=total+1 local ok, has=pcall(function() return gi.AugmentRevDetailMap:Contains(e:get()) end)'\
' if ok and has then offered=offered+1 end end)'\
' return string.format("augments: listed=%d possible=%d offered=%d", n, total, offered)'
# MODE=lobby (default): create a 2-slot lobby, launch alone, play. MODE=queue: press PLAY, accept, play.
# MODE=soak: everything players do in a row - create+leave, create+play+leave, again, then PLAY+play+leave.
cmd() { echo "$1" >> "$A"; }
create() {   # custom lobby, 2 slots
  cmd 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:CreateLobbyAndJoin("'"$1"'", "Embersong", FText("LE_Arena02_Map"), 2); return "create lobby '"$1"'"'
  sleep 75
  cmd 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); if not (pc and pc:IsValid()) then return "NOT in a lobby" end'\
' return "in lobby, slot " .. tostring(pc.PlayerState.ChosenSlot) .. ", owner " .. tostring(pc.PlayerState.IsLobbyOwner)'
}
launch() { cmd 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer(); return "launch pressed"'; sleep 12; }
queue() {
  cmd 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=2; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "pressed PLAY"'
  sleep 25; cmd 'lua FindFirstOf("BP_MOBAInstance_C").WB_AcceptMatchRef:BndEvt__OkBtn_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature(); return "accepted"'
  sleep 70
}
play() {     # hero select -> match; checks the arena, the pawn and the augments
  cmd 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("Lancer", false); pcall(function() pc:UpdateChosenHero("Lancer") end); return "clicked Lancer"'
  sleep 4; cmd 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SetChosenHero(); return "locked in"'
  for _ in $(seq "${1:-6}"); do sleep 20; cmd "$STATUS"; done
  cmd "$AUG"
}
leave() {    # what the in-game menu's Leave does
  cmd 'lua StaticFindObject("/Script/Engine.Default__GameplayStatics"):OpenLevel(FindFirstOf("PlayerController"), FName("LE_MainMenu_Map"), true, ""); return "left to the main menu"'
  sleep 30; cmd "$STATUS"
}
(
  sleep 45
  case ${MODE:-lobby} in
    queue) queue; play ;;
    soak)  create "Soak 1"; leave
           create "Soak 2"; launch; play 5; leave
           create "Soak 3"; launch; play 5; leave
           queue; play 5; leave ;;
    *)     create "Remote Test"; launch; play ;;
  esac
) &
driver=$!
export WINEPREFIX=$pfx WINEDEBUG=-all WINEDLLOVERRIDES="dwmapi,d3d11,dxgi,d3d10core=n,b"
export DXVK_FILTER_DEVICE_NAME="NVIDIA" DXVK_CONFIG="dxgi.syncInterval = 0" DXVK_LOG_LEVEL=warn
cd "$bin"
setsid gamescope --backend headless -r 60 -W 1920 -H 1080 -w 1280 -h 720 -- wine MOBA-Win64-Shipping.exe \
  -TestUser=$name -TestPass="$JOIN_CODE:$(cat "$secret_file")" -windowed -ResX=1280 -ResY=720 -d3d11 -nosound -unattended -nosplash \
  > "$REPO/work/logs/remote.stdout" 2>&1 &
game=$!
wait "$driver"; sleep 5
kill -TERM -- -"$game" 2>/dev/null; sleep 3; kill -KILL -- -"$game" 2>/dev/null
for pid in $(pgrep -u "$(id -u)" 2>/dev/null); do   # this run's Wine processes only (by prefix)
  { tr '\0' '\n' < /proc/$pid/environ; } 2>/dev/null | grep -qx "WINEPREFIX=$pfx" && kill -9 "$pid" 2>/dev/null
done
grep -h '' "$bin/fangsctl.log" "$bin/fangsboot.log" 2>/dev/null | grep -E 'lua (ok|error)|HUD|launch|Battle' | cut -c1-200
