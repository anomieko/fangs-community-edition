#!/usr/bin/env bash
# PATCH NOTES test (FangsBoot patchnotes.lua, backend/patchnotes.py): two GPU-rendered headless clients of the same
# install, one after the other. The backend serves backend/patchnotes/ plus an older test update. The first start opens
# the newest notes by itself and keeps them as seen; then, through the widgets' own click handlers: CLOSE, the PATCH
# NOTES tab (the list), the older update, the newest again, scrolled down, and the PLAY tab (closes the panel). The
# second start gets the first one's patchnotes_seen.txt and must not open by itself. Screenshots in
# work/logs/patchnotes-shots/. Own backend data; local play is untouched.
# Usage: [CLIENT_DIR=clients/<build>] tools/run/test_patchnotes.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
R=patchnotes
CLIENT=${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}
rm -rf work/run/$R-hosts work/run/$R-store.json work/run/$R-notes; mkdir -p work/run/$R-notes
cp backend/patchnotes/*.json work/run/$R-notes/
cat > work/run/$R-notes/2026-10-10-1200.json <<'EOF'
{"tag": "deploy-2026-10-10-1200", "date": "2026-10-10", "title": "Patch notes: an older update (test)",
 "subtitle": "FANGS Community Edition · 10 October 2026",
 "intro": ["Only in the test: a second update, so the list has two entries."],
 "sections": [{"name": "General", "items": ["<b>Test:</b> 10 → 20 damage."]}], "outro": "The end."}
EOF
W=MOBA/Binaries/Win64
A=work/run/$R-first/$W/fangsctl_cmd.txt; B=work/run/$R-second/$W/fangsctl_cmd.txt
BOOT1=work/run/$R-first/$W/fangsboot.log; BOOT2=work/run/$R-second/$W/fangsboot.log
waitfor() { for _ in $(seq "$3"); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 1; done; echo "timeout waiting for '$2' in $1"; }
F='local function F(c, p) for _, w in ipairs(FindAllOf(c) or {}) do if w:IsValid() and w:GetFName():ToString():find(p) then return w end end end;'\
' local menu = FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef; local row = menu.MainMenuTabPanel; local tab = row:GetChildAt(row:GetChildrenCount() - 1);'
CLICK=BndEvt__TabBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature
BTN=BndEvt__WB_BattlePassBtn_Secondary_SecondaryBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature
STATE="lua $F"' local b = F("Border", "^FCE_PatchNotes%d+$"); local t = F("RichTextBlock", "^FCE_PatchNotesText"); local s = F("ScrollBox", "^FCE_PatchNotesScroll");'\
' local f = io.open("patchnotes_seen.txt"); local seen = f and f:read("l") or "none"; if f then f:close() end'\
' return string.format("state: panel visibility=%s text=%s bytes scroll=%s of %s seen=%s tabs=%d last tab=\"%s\"", b and tostring(b:GetVisibility()) or "not built",'\
' t and #t:GetText():ToString() or 0, s and string.format("%.0f", s:GetScrollOffset()) or "-", s and string.format("%.0f", s:GetScrollOffsetOfEnd()) or "-",'\
' seen, row:GetChildrenCount(), tab.TabBtnLbl:GetText():ToString())'
ENTRY="lua $F"' for _, w in ipairs(FindAllOf("WB_MainMenuTab_C") or {}) do local ok, t = pcall(function() return w.TabBtnLbl:GetText():ToString() end)'\
' if ok and t == "%s" then w:'$CLICK'() return "clicked %s" end end return "no entry %s"'
(
  waitfor "$BOOT1" 'patch notes: opened' 150; sleep 2
  echo "$STATE" >> $A; echo 'shot showui' >> $A; sleep 3                                      # 1: opened by itself
  echo "lua $F"' for _, w in ipairs(FindAllOf("WB_IconButton_Secondary_C") or {}) do if w:IsValid() and w.BtnText:ToString() == "CLOSE" then w:'$BTN'() return "CLOSE" end end return "no CLOSE"' >> $A
  sleep 2; echo "$STATE" >> $A; echo 'shot showui' >> $A; sleep 3                               # 2: the menu with the tab
  echo "lua $F tab:$CLICK() return \"PATCH NOTES tab\"" >> $A
  sleep 2; echo "$STATE" >> $A; echo 'shot showui' >> $A; sleep 3                               # 3: the list
  printf "$ENTRY\n" "An older update (test)" "older" "older" >> $A
  sleep 3; echo "$STATE" >> $A; echo 'shot showui' >> $A; sleep 3                               # 4: the older update
  printf "$ENTRY\n" "The Community Patch" "newest" "newest" >> $A
  sleep 3; echo "lua $F"' F("ScrollBox", "^FCE_PatchNotesScroll"):SetScrollOffset(1400) return "scrolled"' >> $A
  sleep 2; echo "$STATE" >> $A; echo 'shot showui' >> $A; sleep 3                               # 5: scrolled
  echo "lua $F"' F("ScrollBox", "^FCE_PatchNotesScroll"):ScrollToEnd() return "scrolled to the end"' >> $A
  sleep 2; echo "$STATE" >> $A; echo 'shot showui' >> $A; sleep 3                               # 6: the end
  echo "lua $F menu.HomeTab:$CLICK() return \"PLAY tab\"" >> $A
  sleep 2; echo "$STATE" >> $A; echo 'shot showui' >> $A                                        # 7: closed by PLAY
  # the second start of the same install: the first one's seen file, before it starts
  waitfor work/run/$R-first/$W/patchnotes_seen.txt . 10
  cp work/run/$R-first/$W/patchnotes_seen.txt work/run/$R-second/$W/ && echo "second start: seen $(cat work/run/$R-second/$W/patchnotes_seen.txt)"
  waitfor "$BOOT2" 'patch notes: tab added' 200; sleep 8
  echo "$STATE" >> $B; echo 'shot showui' >> $B                                                 # 8: not opened by itself
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts --patchnotes $PWD/work/run/$R-notes" \
  tools/run/headless.sh "${DURATION:-260}" "$CLIENT" \
  -- $R-first:0:"-TestUser=notes1 -TestPass=x" -- $R-second:140:"-TestUser=notes2 -TestPass=x" 2>&1 | grep -v Segmentation
wait
rm -rf work/logs/$R-shots; mkdir -p work/logs/$R-shots
for n in first second; do
  find work/run/$R-$n work/run/$R-$n.prefix -path '*Screenshots*' -name '*.png' 2>/dev/null | sort | while read -r f; do
    cp "$f" "work/logs/$R-shots/$n-$(basename "$f")"; done
done
ls work/logs/$R-shots
for n in first second; do grep -h 'lua \(ok\|error\)' work/run/$R-$n/$W/fangsctl.log 2>/dev/null | sed "s/^/$n: /" | cut -c1-300; done
for n in first second; do grep -h 'patch notes' work/run/$R-$n/$W/fangsboot.log 2>/dev/null | sed "s/^/$n boot: /" | cut -c1-200; done
if grep -q 'patch notes: opened (new update' "$BOOT2" 2>/dev/null; then echo "FAIL: the second start opened the notes by itself"
elif grep -q 'patch notes: opened (new update' "$BOOT1" 2>/dev/null; then echo "OK: opened by itself on the first start only"
else echo "FAIL: the first start didn't open the notes by itself"; fi
