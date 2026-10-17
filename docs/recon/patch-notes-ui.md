# The PATCH NOTES tab: what the main menu's UI allows (Feb 2023 build)

Findings from building FangsBoot's `patchnotes.lua` (17 Oct 2026; headless GPU runs of `tools/run/test_patchnotes.sh`,
screenshots in `work/logs/patchnotes-shots/`). All from the **15 Feb 2023** build.

- **Root of `WB_MainMenu_C`** is a `CanvasPanel` (`menu.WidgetTree.RootWidget`): a panel added with `AddChildToCanvas`,
  centred anchors and `SetZOrder(50)` sits over the menu, the PLAYERS ONLINE column and the play buttons; the top bar
  and the social bar stay reachable.
- **Tab row**: `MainMenuTabPanel` (HorizontalBox) holds six `WB_MainMenuTab_C` (Play, Inventory, Career, Leaderboard,
  Battle Pass, Store; `ENUM_MainMenu` 0-5). The menu selects tabs by position (`SetSelected(index == tab)` over
  `GetAllChildren`) and binds `SelectMenuTab` of each child in `BindTabSelect`. A seventh tab appended at the end is
  never one of them (no enum value 6); its click (`BndEvt__TabBtn_…_0_OnButtonClicked…`) plays the menu click sound and
  broadcasts `SelectMenuTab(BtnOption)`, unbound for a tab added after construction.
- **A new `WB_MainMenuTab_C` looks selected** (teal underline, box, white label) until `SetSelected(false)`: the
  template has `TabSelected` visible and the menu only resets its own tabs. Construct only sets `TabSelected`'s brush
  from `SelectedImg` (copy it from `menu.LeaderboardTab`). Hover/unhover handle `TabHover` and the label colour.
- **Rich text**: a runtime `RichTextBlock` with `TextStyleSet = DT_LoginRichTypes`
  (`/Game/DataContent/DataTables/DT_LoginRichTypes`) and `AutoWrapText = true`, set before it is added, renders the
  privacy screen's styles in white on a dark panel: `RichText.Title`, `RichText.DateandSubtitle`,
  `RichText.HLGSubtitle`, `RichText.Useragreetxt` (Medium body) and the `Default` row (Heavy, used for bold).
  Non-ASCII text survives VaRest → Lua → `FText` (’ • » · “ ” − all render); the fonts have no "→".
- **ScrollBox** at runtime scrolls with the mouse wheel and `SetScrollOffset`/`ScrollToEnd`; its default scrollbar is
  a thin white bar.
- `WB_IconButton_Secondary_C` (the lobby's button look) works as the panel's CLOSE button, as in `lobbyui.lua`.
