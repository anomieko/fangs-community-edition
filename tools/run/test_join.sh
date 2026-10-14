#!/usr/bin/env bash
# Two players, one custom lobby, along the real UI paths (Aug 2022 build): alice creates a lobby; bob opens
# Custom -> Join with the mode button (whose lobby search is an internal Blueprint call), must see alice's
# lobby, clicks it and joins; alice launches; both pick a hero, lock in and must end up in the arena.
# Own backend data and host dir, so local play is untouched.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_join.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-join}
rm -rf work/run/$R-hosts work/run/$R-store.json
A=work/run/$R-alice/MOBA/Binaries/Win64/fangsctl_cmd.txt; B=work/run/$R-bob/MOBA/Binaries/Win64/fangsctl_cmd.txt
LOBBY='lua local gs=FindFirstOf("GS_Lobby_GameState_C"); if not (gs and gs:IsValid()) then return "lobby: not in a lobby" end'\
' local t={} gs.PlayerArray:ForEach(function(_, e) t[#t+1]=e:get():GetPlayerName():ToString() end)'\
' return "lobby: " .. #t .. " players (" .. table.concat(t, ", ") .. ")"'
WHERE='lua local gs=FindFirstOf("GameStateBase"); local p=FindFirstOf("BP_PlayerChar_C");'\
' return "map=" .. (gs:GetFullName():match("Maps/([%w_]+)") or "?") .. " pawn=" .. (p and p:IsValid() and p:GetFName():ToString() or "none")'
NET_SERVER='lua local out={} for _, d in ipairs(FindAllOf("IpNetDriver") or {}) do if d:IsValid() and not d:GetFullName():find("Default__",1,true) then'\
' local c={} pcall(function() d.ClientConnections:ForEach(function(_, e) c[#c+1]=tostring(e:get().CurrentNetSpeed) end) end)'\
' out[#out+1]=string.format("%s rate=%d/%d conns=[%s]", d.NetDriverName:ToString(), d.MaxClientRate, d.MaxInternetClientRate, table.concat(c, ",")) end end'\
' return "server net: " .. table.concat(out, " | ")'
NET_CLIENT='lua local lp=FindFirstOf("LocalPlayer"); local sc="none" for _, d in ipairs(FindAllOf("IpNetDriver") or {}) do'\
' if d:IsValid() and d.ServerConnection and d.ServerConnection:IsValid() then sc=tostring(d.ServerConnection.CurrentNetSpeed) end end'\
' return string.format("client net: configured=%d connection=%s", lp.ConfiguredInternetSpeed, sc)'
# Lock In along the UI: the button's own visibility check (whose turn it is in the draft), then its click
LOCKIN_BTN='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef; local gs=FindFirstOf("GS_Lobby_GameState_C");'\
' local vis=h:ShowSelectHeroBtn(); local seat=pc.PlayerState.ChosenSlot;'\
' if vis == 0 then h:BndEvt__ReadyBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() end'\
' return string.format("lock in button %s (seat %d, draft step %d, order %s)", vis == 0 and "VISIBLE, clicked" or "HIDDEN", seat, gs.GS_HeroSelectStep, gs.DraftOrderJSONStr:ToString():gsub("%s", ""))'
pick() {
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$2"'", false); pcall(function() pc:UpdateChosenHero("'"$2"'") end); return "clicked '"$2"'"' >> "$1"
}
(
  sleep 40
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:CreateLobbyAndJoin("Join Test", "Embersong", FText("LE_Arena02_Map"), 8); return "alice: create 8-slot lobby"' >> $A
  sleep 50
  # bob: mode chooser -> "Join a lobby", then PLAY - exactly what the menus do
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi:ShowChoseGameMode(); gi.WB_ChoseGameModeRef:SetJoinCustomMode(); return "bob: chose Join a lobby"' >> $B
  sleep 2
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); local pm=gi.WB_MainMenuRef.WB_PlayMenu;'\
' pm:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "bob: pressed PLAY (" .. pm.QueueDescTxt:GetText():ToString() .. ")"' >> $B
  for _ in 1 2 3 4 5 6; do sleep 1.5
    echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); local pm=gi.WB_MainMenuRef.WB_PlayMenu; return string.format("bob menu: search page %d, match page %d, GetSessions %s, finding %s, reconnect-check %s, zeuz %s, lan %s, msg %q, lobbies %d",'\
' pm.LobbyJoinSwitcher:GetActiveWidgetIndex(), pm.MatchSwitcher:GetActiveWidgetIndex(), tostring(pm.GetSessions), tostring(pm.IsFindingMatch), tostring(pm.CheckingReconnect),'\
' tostring(gi.UseZeuzIMSCustoms), tostring(gi.UseLAN), pm.ConnectionMsg:ToString(), pm.LobbyList:GetChildrenCount())' >> $B
  done
  sleep 1
  echo 'lua local pm=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu; local t={}'\
' for i=0, pm.LobbyList:GetChildrenCount()-1 do t[#t+1]=pm.LobbyList:GetChildAt(i).LobbyName:ToString() end'\
' return "bob sees " .. #t .. " lobbies: " .. table.concat(t, ", ") .. " (search page " .. pm.LobbyJoinSwitcher:GetActiveWidgetIndex() .. ", replay button visibility " .. tostring(pm.Button_477:GetVisibility()) .. ")"' >> $B
  echo 'lua local pm=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu; if pm.LobbyList:GetChildrenCount() == 0 then return "bob: nothing to click" end'\
' pm.LobbyList:GetChildAt(0):BndEvt__SelectSessionBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "bob: clicked the lobby"' >> $B
  sleep 30
  if [[ -n ${SLOTS:-} ]]; then   # sides/seats, e.g. SLOTS="4 6": nobody in seat 0, whose turn the game's draft starts with
    read -r sa sb <<< "$SLOTS"
    echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SelectTeamSlotOnServer('$sa'); return "alice: seat '$sa'"' >> $A
    echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SelectTeamSlotOnServer('$sb'); return "bob: seat '$sb'"' >> $B
  fi
  sleep 10
  echo "$LOBBY" >> $A; echo "$LOBBY" >> $B
  echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer(); return "alice: launch"' >> $A
  sleep 12; pick $A Lancer; pick $B Berserker
  sleep 4
  for f in $A $B; do echo "$LOCKIN_BTN" >> $f; done

  for _ in 1 2 3 4; do sleep 20; echo "$WHERE" >> $A; echo "$WHERE" >> $B; done
  if [[ -n ${PROBE:-} ]]; then   # live network rates, server frame times and CPU, mid-match
    for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "$NET_SERVER" >> $h/fangsctl_cmd.txt; done
    echo "$NET_CLIENT" >> $A; echo "$NET_CLIENT" >> $B
    for h in work/run/$R-hosts/host-*; do echo "probe $(basename $h): $(cat $h/MOBA/Binaries/Win64/fangshost_status.json)"; done
    for pid in $(pgrep -x GameThread); do   # CPU over 10 s of this run's game servers
      cwd=$(readlink /proc/$pid/cwd 2>/dev/null); [[ $cwd == *"/$R-hosts/"* ]] || continue
      t0=$(awk '{print $14+$15}' /proc/$pid/stat); sleep 10; t1=$(awk '{print $14+$15}' /proc/$pid/stat)
      echo "probe cpu $(basename "$(dirname "$(dirname "$(dirname "$cwd")")")"): $(( (t1 - t0) * 100 / 10 / $(getconf CLK_TCK) ))% of a core"
    done
  fi
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-300}" "${CLIENT_DIR:-clients/fangs-2022-08-26-b9396481}" \
  -- $R-alice:0:"-TestUser=alice -TestPass=x" -- $R-bob:3:"-TestUser=bob -TestPass=x" 2>&1 | grep -v Segmentation
wait
for n in alice bob; do grep -h 'lua \(ok\|error\)' work/run/$R-$n/MOBA/Binaries/Win64/fangsctl.log | sed "s/^/$n: /" | cut -c1-200; done
grep -h 'lobby:' work/run/$R-bob/MOBA/Binaries/Win64/fangsboot.log | sed 's/^/bob boot: /' | tail -4
grep -h 'lua \(ok\|error\): server net' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null | sed 's/^/host: /' | cut -c1-200
grep -h 'tick:' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangshost.log 2>/dev/null | sed 's/^/host: /'
