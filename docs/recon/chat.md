# Chat (Feb 2023 build, `clients/fangs-2023-02-15-b10554626`)

How the game's text chat works and what the backend must do for it. Addresses are in the Feb 2023 Shipping exe
(`tools/re/xref.py`, `tools/re/natives.py`; capstone is in `work/re/.venv`). Test: `tools/run/test_chat.sh`.

## Where you type

`BP_MOBAInstance.bUseAccelbyteChat` is on, so every screen uses the native `UChat` game-instance subsystem with the
`WB_ChatSocial_Accelbyte` / `WB_ChatWindow_Accelbyte` widgets: custom lobby (`WB_LobbyMenu`), hero select
(`WB_LobbyHeroSelect`) and the match HUD (`WB_ChatIngame`, opened with Enter). The older path (`WB_ChatIngame.InGameChat`,
server RPC `BP_PC_MOBA_PlayerController.GetChatMessage` → client RPC `UpdateChat` to every controller) is not used.

Enter calls `WB_ChatWindow_Accelbyte.HandleInputTrimming`, which runs `UChat::ExecuteChatCommand("<CurrentCommand>
<text>")`, or the typed line itself if it starts with `/`. `CurrentCommand` comes from `PrepareAll` / `PrepareTeam` /
`PrepareParty` / `PrepareWhisper` (the `CycleChatCommands` input cycles them). Screens set `UChat.ChatLocation`: main
menu 1, custom lobby 2, hero select 3, match 4.

## What each command sends (`UChat::ExecuteChatCommand`, 0x141347470)

| Command | Sent as | Where it works |
|---|---|---|
| `/w <name> <text>` (whisper) | `personalChatRequest` (lobby websocket) | anywhere |
| `/p <text>` (party) | `partyChatRequest` | anywhere, in a party ("Not in party" otherwise) |
| `/t`, `/team` (team) | one `signalingP2PNotif` per teammate in `UChat.LobbyUsers` (`bTeammate`), message `/t <text>` | custom lobby, hero select, match |
| `/a`, `/all` (all) | one `signalingP2PNotif` per player in `LobbyUsers`, message `/a <text>` | custom lobby, match ("Not in battle" in hero select) |
| `/mute`, `/muteall`, `/unmute` | local only | |

The AccelByte channel chat (`joinDefaultChannelRequest`, `sendChannelChatRequest`) is in the SDK but the game never
sends it.

## Who team/all chat goes to: `UChat.LobbyUsers`

`FChatLobbyUsers {DisplayName, UserId, bTeammate}`, filled with `AddOrUpdateLobbyMember` by the custom lobby's player
list (`WB_OnlinePlayer`) and by hero select (`WB_OnlineTeamMember`) for every other player, from
`PS_LobbyHero_PlayerState.AccelyteId` (the AccelByte user id); `bTeammate` = same seat parity (`ChosenSlot % 2`), which
is also the match's team. The list survives the travel to the arena and is cleared in the main menu and by the lobby's
close button. On our stack it is filled correctly (both clients list each other with the right id and team).

## Receiving (signaling handler, 0x14135ab10)

The same handler takes party member details (`ReportDetails<DisplayName>…`, `ReportSigil…`, `ReportLeaveQueueCommand`,
`ReportMatchmakerDetails…`, `ReportGameModeChangeCommand…`: looked for **anywhere** in the message) and, after those,
chat: a message starting with `/t` (any case) fires `OnTeamMessageReceived`, `/a` `OnEveryoneMessageReceived`, with
the text after the first 3 characters, **only if the sender's user id is in the receiver's own `LobbyUsers`** (its
display name comes from there). A stranger's team/all line is dropped by the receiving game.

## Our backend

`backend/social.py` relayed signaling only between friends and party mates (to keep party details private), so every
team/all line between players who weren't friends was dropped (`"signaling dropped"` in the backend log): lobby, hero
select and match chat only showed one's own lines (`work/logs/chat-base/`). Fix (branch `chat`): the relay passes chat
lines (starting with `/t` or `/a`) between any two online players (`LOBBY_CHAT` in `backend/social.py`); other
signaling stays friends/party only. Relayed chat lines get a zero-width space inside "Report", so a line like
"/a ReportLeaveQueueCommand" can't act as a party command on the receiver, and are escaped like other chat text
(`chat_text`).
