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
(
  sleep 45
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; gi.WB_MainMenuRef.WB_PlayMenu.BP_MOBAInstanceRef=gi; return "ready"' >> "$A"
  if [[ ${MODE:-lobby} == queue ]]; then
    echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.WB_MainMenuRef.WB_PlayMenu:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "pressed PLAY"' >> "$A"
    sleep 25; echo 'lua FindFirstOf("BP_MOBAInstance_C").WB_AcceptMatchRef:BndEvt__OkBtn_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature(); return "accepted"' >> "$A"
    sleep 70
  else
    echo 'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Remote Test", "Embersong", FText("LE_Arena02_Map"), 2); return "create 2-slot lobby"' >> "$A"
    sleep 75; echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); return "in lobby, slot " .. tostring(pc.PlayerState.ChosenSlot) .. ", owner " .. tostring(pc.PlayerState.IsLobbyOwner)' >> "$A"
    echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer(); return "launch pressed"' >> "$A"
    sleep 12
  fi
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("Lancer", false); pcall(function() pc:UpdateChosenHero("Lancer") end); return "clicked Lancer"' >> "$A"
  sleep 4; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SetChosenHero(); return "locked in"' >> "$A"
  for i in 1 2 3 4 5 6; do sleep 20; echo "$STATUS" >> "$A"; done
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
